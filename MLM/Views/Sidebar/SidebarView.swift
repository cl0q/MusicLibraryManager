import AppKit
import SwiftUI

/// The main window's sidebar (P-SIDEBAR, UC-SIDE-01…12): a system sidebar `List` with four
/// collapsible sections — Library · Inbox · Playlists · Sync — and the library footer.
///
/// No Sources, Queue, Settings or Search rows (DEC-004, DEC-006). Playlists are listed flat
/// in the repository's order until playlist folders and manual order arrive (W3-PL).
/// Rows are destinations of `NavigationModel`; ⌘1…⌘6 live in the Go menu.
struct SidebarView: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(SidebarModel.self) private var model
    @Environment(ShellActions.self) private var actions

    private enum RenameTarget: Hashable {
        case playlist(Int64)
        case syncProfile(Int64)
    }

    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var isCommittingRename = false
    @FocusState private var renameFocused: Bool

    /// The playlist waiting for the Delete Playlist confirmation, with its wording.
    @State private var pendingPlaylistDeletion: PendingPlaylistDeletion?
    @State private var pendingProfileDeletion: SyncProfile?
    @State private var deviceIngestProfile: SyncProfile?

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
                ForEach(model.playlists) { playlist in
                    playlistRow(playlist)
                }
            } header: {
                SidebarSectionHeader(title: SidebarSectionID.playlists.title) {
                    Menu {
                        Button("New Playlist") {
                            actions.newPlaylist()
                        }
                        Button("New Playlist Folder") {}
                            .disabled(true)
                            .help(AddMenu.Unavailable.playlistFolder)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .help("New Playlist")
                    .accessibilityLabel("Add Playlist")
                }
                // Tracks dropped on the header make a new playlist, named inline (IMP-018).
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
        }
        .listStyle(.sidebar)
        // The empty area below the rows: a new playlist from the drop (D-PL-SELECTION-TO-NEW).
        .dropTarget(.playlistsSection)
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
            model.refreshReachability(syncProfiles)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            // Cover regeneration posts are noise for the sidebar.
            guard note.userInfo?["coverRevalidation"] == nil else { return }
            Task { await reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewQueueDidChange)) { _ in
            Task { await reloadBadges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await reloadBadges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await reloadBadges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
            Task { await container.syncViewModel?.loadProfiles() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshReachability(syncProfiles)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshReachability(syncProfiles)
        }
        .onChange(of: model.renameRequest) { _, _ in
            beginRequestedRename()
        }
        .onChange(of: model.playlists.compactMap(\.id)) { _, _ in
            beginRequestedRename()
        }
        .onChange(of: syncProfiles.compactMap(\.id)) { old, new in
            model.refreshReachability(syncProfiles)
            for removed in Set(old).subtracting(new) {
                navigation.removeSyncProfile(removed)
            }
        }
        // A-PL-DELETE: asked because the playlist also leaves its sync profiles, and still
        // restorable with Undo until MLM quits (UC-UNDO-05, DEC-049). Cancel is the default.
        .alert(
            pendingPlaylistDeletion?.confirmation.title ?? "",
            isPresented: Binding(
                get: { pendingPlaylistDeletion != nil },
                set: { if !$0 { pendingPlaylistDeletion = nil } }
            ),
            presenting: pendingPlaylistDeletion
        ) { pending in
            Button(PlaylistDeletionConfirmation.confirmTitle, role: .destructive) {
                deletePlaylist(pending)
            }
            Button("Cancel", role: .cancel) {
                pendingPlaylistDeletion = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: { pending in
            Text(pending.confirmation.message)
        }
        // A-SYNC-DELETEPROFILE: not undoable, so confirmed (UC-UNDO-03). Cancel is the default.
        .alert(
            "Delete the sync profile “\(pendingProfileDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingProfileDeletion != nil },
                set: { if !$0 { pendingProfileDeletion = nil } }
            )
        ) {
            Button("Delete Sync Profile", role: .destructive) {
                deletePendingProfile()
            }
            Button("Cancel", role: .cancel) {
                pendingProfileDeletion = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("The profile, its plan and its sync history are removed. Music on the device and in your library is not touched.")
        }
        .sheet(item: $deviceIngestProfile) { profile in
            DeviceIngestResultsView(profile: profile)
        }
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
    private func playlistRow(_ playlist: Playlist) -> some View {
        if let id = playlist.id {
            let icon = playlist.isLiked == 1 ? "heart" : "music.note.list"
            if renaming == .playlist(id) {
                renameField(systemImage: icon)
                    .tag(SidebarDestination.playlist(id))
            } else {
                playlistLabel(playlist, systemImage: icon)
                    .help(playlist.name)
                    .tag(SidebarDestination.playlist(id))
                    .contextMenu {
                        Button("Rename") {
                            startRename(.playlist(id), currentName: playlist.name)
                        }
                        if playlist.isLiked == 0 {
                            Divider()
                            Button("Delete Playlist…", role: .destructive) {
                                askToDelete(playlist)
                            }
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

    /// One line when healthy; a second line only to state a condition (UC-SIDE-04/06).
    @ViewBuilder
    private func playlistLabel(_ playlist: Playlist, systemImage: String) -> some View {
        let condition = SidebarModel.playlistSecondLine(
            sourceName: playlist.sourceId.flatMap { model.sourceNames[$0] },
            unusableSignIns: container.tokenAccessStatus?.inaccessibleServices ?? []
        )
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let condition {
                    Text(condition)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    @ViewBuilder
    private func syncProfileRow(_ profile: SyncProfile) -> some View {
        if let id = profile.id {
            if renaming == .syncProfile(id) {
                renameField(systemImage: "externaldrive")
                    .tag(SidebarDestination.syncProfile(id))
            } else {
                let state = rowState(for: profile, id: id)
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(state.text())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        if let progress = state.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .controlSize(.mini)
                        }
                    }
                } icon: {
                    Image(systemName: "externaldrive")
                }
                .help(profile.outputFolder)
                .tag(SidebarDestination.syncProfile(id))
                .contextMenu {
                    syncProfileMenu(profile, id: id)
                }
                // Tracks and playlists add to the profile; the open page doesn't switch.
                .dropTarget(.syncProfile(id: id, name: profile.name))
            }
        }
    }

    @ViewBuilder
    private func syncProfileMenu(_ profile: SyncProfile, id: Int64) -> some View {
        Button("Rename") {
            startRename(.syncProfile(id), currentName: profile.name)
        }
        Button("Duplicate") {
            duplicate(profile)
        }
        Button("Read Playlist Changes from Device…") {
            deviceIngestProfile = profile
            Task { await container.syncViewModel?.scanDeviceForPlaylistChanges(profile: profile) }
        }
        Divider()
        Button("Delete Sync Profile…", role: .destructive) {
            pendingProfileDeletion = profile
        }
    }

    /// Duplicate makes the copy the selected profile in `SyncViewModel`; show it, so the
    /// page and the profile Sync Now acts on agree (B1).
    private func duplicate(_ profile: SyncProfile) {
        guard let vm = container.syncViewModel else { return }
        let before = Set(vm.profiles.compactMap(\.id))
        Task {
            await vm.duplicateProfile(profile)
            if let copy = vm.profiles.compactMap(\.id).first(where: { !before.contains($0) }) {
                navigation.select(.syncProfile(copy))
            }
        }
    }

    private func rowState(for profile: SyncProfile, id: Int64) -> SyncProfileRowState {
        guard let vm = container.syncViewModel else {
            return .make(isSyncing: false, processed: 0, total: 0,
                         isReachable: model.reachableProfileIDs.contains(id),
                         pendingAdds: nil, lastSynced: nil)
        }
        let isSelected = vm.selectedProfile?.id == id
        let pendingAdds: Int? = {
            guard isSelected, let preview = vm.preview, preview.isDeviceConnected else { return nil }
            return preview.filesToAdd.count
        }()
        return .make(
            isSyncing: isSelected && vm.isSyncing,
            processed: vm.syncProcessed,
            total: vm.syncTotal,
            isReachable: model.reachableProfileIDs.contains(id),
            pendingAdds: pendingAdds,
            lastSynced: vm.profileLastSynced[id]
        )
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

    /// A playlist just created (⌘N, New Playlist from Selection) gets its name edited inline
    /// once its row is listed (S-PL-NEWPLAYLIST).
    private func beginRequestedRename() {
        guard let playlist = model.takeRenameRequest(), let id = playlist.id else { return }
        startRename(.playlist(id), currentName: playlist.name)
    }

    // MARK: - Deleting

    private func askToDelete(_ playlist: Playlist) {
        Task {
            let confirmation = await actions.edits.deletionConfirmation(for: playlist)
            pendingPlaylistDeletion = PendingPlaylistDeletion(playlist: playlist, confirmation: confirmation)
        }
    }

    private func deletePlaylist(_ pending: PendingPlaylistDeletion) {
        pendingPlaylistDeletion = nil
        guard let id = pending.playlist.id else { return }
        Task { await actions.edits.deletePlaylist(id, name: pending.playlist.name) }
    }

    private func deletePendingProfile() {
        guard let profile = pendingProfileDeletion, let vm = container.syncViewModel else { return }
        pendingProfileDeletion = nil
        Task {
            await vm.deleteProfile(profile)
            if let id = profile.id { navigation.removeSyncProfile(id) }
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

/// A Delete Playlist question on screen.
private struct PendingPlaylistDeletion {
    let playlist: Playlist
    let confirmation: PlaylistDeletionConfirmation
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
