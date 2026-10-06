import AppKit
import SwiftUI

/// The main window's sidebar (P-SIDEBAR, UC-SIDE-01…12): a system sidebar `List` with four
/// collapsible sections — Library · Inbox · Playlists · Sync — and the library footer.
///
/// No Sources, Queue, Settings or Search rows (DEC-004, DEC-006). The Playlists section lists
/// `All Playlists`, then playlist folders (`DisclosureGroup`) and playlists in the user's
/// order (DEC-003, W3-PL); a playlist row has a second line only when it isn't healthy, in the
/// §15.5 words. Rows are destinations of `NavigationModel`; ⌘1…⌘6 live in the Go menu.
struct SidebarView: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(SidebarModel.self) private var model
    @Environment(ShellActions.self) private var actions
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?

    private enum RenameTarget: Hashable {
        case playlist(Int64)
        case folder(Int64)
        case syncProfile(Int64)
    }

    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var isCommittingRename = false
    @FocusState private var renameFocused: Bool

    private var syncProfiles: [SyncProfile] { container.syncViewModel?.profiles ?? [] }

    var body: some View {
        List(selection: selectionBinding) {
            Section(isExpanded: expansion(.library)) {
                ForEach(SidebarDestination.librarySection, id: \.self) { destination in
                    fixedRow(destination)
                }
            } header: {
                Text(SidebarSectionID.library.title)
            }

            Section(isExpanded: expansion(.inbox)) {
                fixedRow(.discover)
                    .badge(badgeText(model.discoverCount))
                fixedRow(.review)
                    .badge(badgeText(model.reviewCount))
            } header: {
                Text(SidebarSectionID.inbox.title)
            }

            Section(isExpanded: expansion(.playlists)) {
                fixedRow(.allPlaylists)
                // Playlist folders and playlists in the user's order (UC-SIDE-01/08); a drag
                // between the rows reorders (D-PL-CARD-REORDER), one undo step.
                ForEach(model.tree.nodes) { node in
                    playlistNode(node)
                }
                .onInsert(of: [.draggedPlaylist]) { index, providers in
                    let nodes = model.tree.nodes
                    reorder(providers, folderID: nil, before: index < nodes.count ? nodes[index].id : nil)
                }
            } header: {
                SidebarSectionHeader(title: SidebarSectionID.playlists.title) {
                    // P-SIDEBAR.E03/add: New Playlist ⌘N · New Playlist Folder ⌥⌘N.
                    Menu {
                        Button("New Playlist") {
                            actions.newPlaylist()
                        }
                        Button("New Playlist Folder") {
                            Task { await actions.edits.newPlaylistFolder() }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .help("New Playlist or Playlist Folder")
                    .accessibilityLabel("Add Playlist or Playlist Folder")
                }
                // Tracks dropped on the header make a new playlist, named inline (IMP-018);
                // playlists dropped here move to the top level.
                .dropTarget(.playlistsSection)
            }

            Section(isExpanded: expansion(.sync)) {
                ForEach(syncProfiles) { profile in
                    syncProfileRow(profile)
                }
                if syncProfiles.isEmpty {
                    // UC-EMPTY-01: the section says what fills it.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No sync profiles yet.")
                            .foregroundStyle(.secondary)
                        Button("New Sync Profile…") {
                            actions.newSyncProfile()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.subheadline)
                    .selectionDisabled()
                }
            } header: {
                SidebarSectionHeader(title: SidebarSectionID.sync.title, alwaysShowsAccessory: syncProfiles.isEmpty) {
                    Button {
                        actions.newSyncProfile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Sync Profile…")
                    .accessibilityLabel("New Sync Profile")
                }
            }

            // The empty area below the last row: a new playlist from the drop
            // (D-PL-SELECTION-TO-NEW). Only here, the Playlists header and All Playlists — the
            // Library, Inbox and Sync headers take no tracks.
            SidebarEmptyDropArea()
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryFooter()
        }
        .task {
            model.useLibrary(id: container.activeLibrary?.libraryId)
            await model.reloadSources(container.sourceRepository)
            await reloadPlaylists()
            // A playlist created while the sidebar wasn't on screen still gets its name edited.
            beginRequestedRename()
            await reloadBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            // Cover regeneration posts are noise for the sidebar.
            guard note.userInfo?["coverRevalidation"] == nil, (note.userInfo?["origin"] as? String) != "coverService" else { return }
            Task { await reloadPlaylists() }
        }
        // The rows' second lines follow downloads and file checks (one aggregate query).
        .onReceive(NotificationCenter.default.publisher(for: .downloadStateDidChange)) { _ in
            Task { await model.reloadSummaries(container.playlistRepository) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in
            Task { await model.reloadSummaries(container.playlistRepository) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewQueueDidChange)) { _ in
            Task { await reloadBadges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await reloadBadges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task {
                await reloadBadges()
                await model.reloadSummaries(container.playlistRepository)
            }
        }
        // Sync profiles, their destinations and plans are watched by `SyncViewModel` (W3-SYNC).
        .onChange(of: container.syncViewModel?.presenter.renameRequest) { _, request in
            guard let id = request, let profile = syncProfiles.first(where: { $0.id == id }) else { return }
            container.syncViewModel?.presenter.renameRequest = nil
            startRename(.syncProfile(id), currentName: profile.name)
        }
        .onChange(of: model.renameRequest) { _, _ in
            beginRequestedRename()
        }
        .onChange(of: model.folderRenameRequest) { _, _ in
            beginRequestedRename()
        }
        .onChange(of: model.playlists.compactMap(\.id)) { _, _ in
            beginRequestedRename()
        }
        .onChange(of: model.folders.compactMap(\.id)) { _, _ in
            beginRequestedRename()
        }
        .onChange(of: syncProfiles.compactMap(\.id)) { old, new in
            for removed in Set(old).subtracting(new) {
                navigation.removeSyncProfile(removed)
            }
        }
        // Delete Sync Profile… (A-SYNC-DELETEPROFILE), Change Destination…, Add…, Read Playlist
        // Changes from Device… — shared with the profile pages (W3-SYNC).
        .syncProfileSheets()
    }

    // MARK: - Selection and expansion

    private var selectionBinding: Binding<SidebarDestination?> {
        Binding(
            get: { navigation.selection },
            set: { newValue in
                if let newValue { navigation.select(newValue) }
            }
        )
    }

    private func expansion(_ section: SidebarSectionID) -> Binding<Bool> {
        Binding(
            get: { model.isExpanded(section) },
            set: { model.setExpanded(section, $0) }
        )
    }

    private func folderExpansion(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { model.isFolderExpanded(id) },
            set: { model.setFolderExpanded(id, $0) }
        )
    }

    private func badgeText(_ count: Int) -> Text? {
        count > 0 ? Text(count.formatted(.number)) : nil
    }

    // MARK: - Rows

    private func fixedRow(_ destination: SidebarDestination) -> some View {
        Label(destination.fixedTitle, systemImage: destination.systemImage)
            .tag(destination)
            // Views, not containers: no ring for tracks; Finder files import (UC-SIDE-11).
            // All Playlists stands for the Playlists section: a drop there makes a playlist.
            .dropTarget(destination == .allPlaylists ? .playlistsSection : .fixedRow)
    }

    /// Spring-loading opens a playlist row while a track drag rests on it (offered, never
    /// required — the row takes the drop itself, UC-DND-04); on the row that is already
    /// selected it does nothing (re-selecting would pop that place's pushed details mid-drag).
    private func springLoad(_ destination: SidebarDestination) {
        guard destination != navigation.selection else { return }
        navigation.select(destination)
    }

    @ViewBuilder
    private func playlistNode(_ node: PlaylistSidebarTree.Node) -> some View {
        switch node {
        case .playlist(let playlist):
            playlistRow(playlist)
        case .folder(let folder, let children):
            if let id = folder.id {
                DisclosureGroup(isExpanded: folderExpansion(id)) {
                    ForEach(children) { child in
                        playlistRow(child)
                    }
                    .onInsert(of: [.draggedPlaylist]) { index, providers in
                        reorder(providers, folderID: id, before: index < children.count ? children[index].id.map(PlaylistSidebarItemID.playlist) : nil)
                    }
                } label: {
                    folderLabel(folder, id: id)
                }
            }
        }
    }

    @ViewBuilder
    private func folderLabel(_ folder: PlaylistFolder, id: Int64) -> some View {
        if renaming == .folder(id) {
            renameField(systemImage: "folder")
        } else {
            Label(folder.name, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(folder.name)
                .contextMenu {
                    PlaylistFolderMenu(folder: folder) {
                        startRename(.folder(id), currentName: folder.name)
                    }
                }
                // Playlists move into it; tracks, Finder files and M3U files make a new
                // playlist inside (UC-SIDE-08, UC-DND matrix).
                .dropTarget(.playlistFolder(id: id, name: folder.name))
                .draggable(PlaylistDragItem.folder(id, libraryId: container.activeLibrary?.libraryId))
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        if let id = playlist.id {
            let icon = playlist.isLiked == 1 ? "heart" : "music.note.list"
            if renaming == .playlist(id) {
                renameField(systemImage: icon)
                    .tag(SidebarDestination.playlist(id))
            } else {
                playlistLabel(playlist, id: id, systemImage: icon)
                    .help(playlist.name)
                    .tag(SidebarDestination.playlist(id))
                    // CM-SIDEBAR-PINNED, the one playlist-menu builder (UC-CM-02).
                    .contextMenu {
                        PlaylistMenu(playlists: [playlist], place: .sidebarRow) {
                            startRename(.playlist(id), currentName: playlist.name)
                        }
                    }
                    // A playlist row takes tracks, playlists, Finder files, M3U files and links
                    // directly (UC-DND-04) and drags as the playlist (UC-DND-01).
                    .dropTarget(
                        .sidebarPlaylist(id: id, name: playlist.name),
                        isShown: navigation.selection == .playlist(id),
                        springLoad: { springLoad(.playlist(id)) }
                    )
                    .draggable(PlaylistDragItem(playlistId: id, libraryId: container.activeLibrary?.libraryId))
            }
        }
    }

    /// One line when healthy; a second line only to state a condition (UC-SIDE-04/06), in the
    /// §15.5 words from the one aggregate query and Activity's echo.
    @ViewBuilder
    private func playlistLabel(_ playlist: Playlist, id: Int64, systemImage: String) -> some View {
        let status = PlaylistStatus.make(
            summary: model.summaries[id],
            echo: ActivityCenter.shared.echo(for: .playlist(id, name: playlist.name)),
            expiredSignIn: PlaylistStatus.expiredSignIn(
                sourceName: playlist.sourceId.flatMap { model.sourceNames[$0] },
                unusable: container.tokenAccessStatus?.inaccessibleServices ?? []
            )
        )
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let condition = status.text {
                    Text(condition)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// UC-SIDE-07: always a second line with this profile's own state (§15.8) — whichever
    /// profile is open (W3-SYNC); a thin bar while it syncs.
    @ViewBuilder
    private func syncProfileRow(_ profile: SyncProfile) -> some View {
        if let id = profile.id {
            let icon = SyncDestination.volumePath(for: profile.outputFolder) == nil ? "folder" : "externaldrive"
            if renaming == .syncProfile(id) {
                renameField(systemImage: icon)
                    .tag(SidebarDestination.syncProfile(id))
            } else {
                let state = container.syncViewModel?.state(for: profile)
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let state {
                            Text(state.sidebarText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                            if let progress = state.sidebarProgress {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .controlSize(.mini)
                            }
                        }
                    }
                } icon: {
                    Image(systemName: icon)
                }
                .help(profile.outputFolder)
                .tag(SidebarDestination.syncProfile(id))
                // CM-SYNC-PROFILE: the one builder, also the page's More (UC-CM-02).
                .contextMenu {
                    SyncProfileMenu(profile: profile, place: .contextMenu)
                }
                // Tracks and playlists add to the profile; the open page doesn't switch.
                .dropTarget(.syncProfile(id: id, name: profile.name))
            }
        }
    }

    // MARK: - Reorder by drag (D-PL-CARD-REORDER, between rows)

    private func reorder(_ providers: [NSItemProvider], folderID: Int64?, before: PlaylistSidebarItemID?) {
        let performer = DropPerformer(container: container, shell: actions, statusBar: statusBar, undo: undo ?? .main)
        let target = DropTarget.playlistOrder(folderID: folderID, before: before)
        Task { @MainActor in
            guard let content = await DropLoader.load(providers) else { return }
            performer.perform(DropRules.decide(content, onto: target, context: DropContext.current(container)))
        }
    }

    // MARK: - Inline rename (UC-SIDE-09)

    private func renameField(systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onAppear { renameFocused = true }
                    .onChange(of: renameFocused) { _, focused in
                        // Clicking elsewhere commits, like Finder (UC-SIDE-09).
                        if !focused, renaming != nil, !isCommittingRename { commitRename() }
                    }
            }
            if let renameError {
                Text(renameError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startRename(_ target: RenameTarget, currentName: String) {
        renameError = nil
        renameText = currentName
        renaming = target
    }

    private func cancelRename() {
        isCommittingRename = false
        renaming = nil
        renameText = ""
        renameError = nil
        renameFocused = false
    }

    private func commitRename() {
        guard let target = renaming, !isCommittingRename else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            // An empty name keeps the old one (UC-KEY-20).
            cancelRename()
            return
        }
        isCommittingRename = true
        Task {
            defer { isCommittingRename = false }
            switch target {
            case .playlist(let id):
                // Esc and an unchanged name keep the name: nothing to undo (UC §23 C6).
                guard let oldName = model.playlistName(id), name != oldName else { return cancelRename() }
                do {
                    try await actions.edits.renamePlaylist(id, from: oldName, to: name)
                    cancelRename()
                } catch {
                    renameError = ShellEdits.renameFailure(error, kind: "playlist")
                    renameFocused = true
                }
            case .folder(let id):
                guard let oldName = model.folderName(id), name != oldName else { return cancelRename() }
                do {
                    try await actions.edits.renamePlaylistFolder(id, from: oldName, to: name)
                    cancelRename()
                } catch {
                    renameError = ShellEdits.renameFailure(error, kind: "playlist folder")
                    renameFocused = true
                }
            case .syncProfile(let id):
                guard let profile = syncProfiles.first(where: { $0.id == id }),
                      name != profile.name else { return cancelRename() }
                do {
                    try await actions.edits.renameSyncProfile(id, from: profile.name, to: name)
                    cancelRename()
                } catch {
                    renameError = ShellEdits.renameFailure(error, kind: "sync profile")
                    renameFocused = true
                }
            }
        }
    }

    /// A playlist or folder just created (⌘N, ⌥⌘N, New Playlist from Selection) gets its name
    /// edited inline once its row is listed (S-PL-NEWPLAYLIST, S-PLFOLDER-NEW).
    private func beginRequestedRename() {
        if let playlist = model.takeRenameRequest(), let id = playlist.id {
            model.reveal(playlist: id)
            startRename(.playlist(id), currentName: playlist.name)
        } else if let folder = model.takeFolderRenameRequest(), let id = folder.id {
            startRename(.folder(id), currentName: folder.name)
        }
    }

    // MARK: - Loading

    private func reloadPlaylists() async {
        for removed in await model.reloadPlaylists(container.playlistRepository) {
            navigation.removePlaylist(removed)
        }
    }

    private func reloadBadges() async {
        await model.reloadBadges(
            trackRepository: container.trackRepository,
            analysisRepository: container.analysisRepository
        )
    }
}

/// The space below the sidebar's last row as a drop target (new playlist). Not a row: it can't
/// be selected, has no background and is hidden from VoiceOver (New Playlist from Selection
/// ⇧⌘N is the same without dragging).
private struct SidebarEmptyDropArea: View {
    static let height: CGFloat = 60

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .contentShape(Rectangle())
            .dropTarget(.playlistsSection)
            .selectionDisabled()
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
    }
}

/// System section header with a ＋ that appears on hover (UC-SIDE-03). The header text stays
/// the system style (UC-TYPE-02); the button stays reachable for VoiceOver and keyboard.
private struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    var alwaysShowsAccessory = false
    @ViewBuilder let accessory: () -> Accessory

    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            accessory()
                .opacity(isHovering || alwaysShowsAccessory ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
