import SwiftUI

/// The track menu (CM-TRACK) — one builder for the table's context menu, the selection bar's
/// More (W2-G) and, later, the header More (•••) menus (UC-CM-02). Renders a `TrackMenuModel`
/// in sections (DEC-039 group order); shortcuts are shown next to items (UC-CM-06); only Play
/// and Download carry a glyph.
struct TrackMenu: View {
    let model: TrackMenuModel
    let rows: [TrackRow]
    /// A track table's actions (`TrackListActions`) or the Queue panel's (W2-D).
    let actions: any TrackMenuActions
    /// Playlists offered in Add to Playlist ▸ (the current one already left out, UC-CM-08).
    let playlists: [Playlist]
    let syncProfiles: [SyncProfile]
    /// The library's disk while it is away — the reason of the disabled file actions
    /// (UC-CM-05, UC-COPY-13); `nil` while connected.
    let offlineVolumeName: String?
    /// Key equivalents next to the items (UC-CM-06). Only for a menu that exists while it is
    /// open (the context menu): a `Menu` that stays in the window (the selection bar's More)
    /// would keep them live and take the menu bar's keys — even from a text field (UC-KEY-36).
    var showsKeyEquivalents = true

    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    var body: some View {
        ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
            Section {
                ForEach(section, id: \.self) { item in
                    view(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for item: TrackMenuItem) -> some View {
        switch item {
        case .countHeader(let count):
            Text(StatusBarText.tracks(count))
        case .driveHeader(let name):
            Text("“\(name)” is not connected")
        case .play(let enabled):
            Button {
                actions.play(rows)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!enabled, reason: offlineVolumeName.map(TrackPrimaryAction.driveNotConnectedHelp))
        case .preview(let enabled):
            // Space is the focused list's key, never a key equivalent here (UC-KEY-37,
            // IMP-023): it would fire instead of the highlighted item while the menu is open.
            Button("Preview") { actions.preview(rows) }
                .disabled(!enabled, reason: offlineVolumeName.map { "Can’t preview — “\($0)” is not connected" })
        case .playNext:
            let item = Button("Play Next") { actions.playNext(rows) }
            if showsKeyEquivalents {
                item
                    .keyboardShortcut(.return, modifiers: .option)
            } else {
                item
            }
        case .addToQueue:
            let item = Button("Add to Queue") { actions.addToQueue(rows) }
            if showsKeyEquivalents {
                item
                    .keyboardShortcut(.return, modifiers: [.option, .shift])
            } else {
                item
            }
        case .moveToEndOfQueue:
            Button("Move to End of Queue") { actions.moveToEndOfQueue(rows) }
        case .showInContext(let name):
            Button("Show in \(name)") { actions.showInContext(rows) }
        case .clearHistory:
            Button("Clear History") { actions.clearHistory() }
        case .addToPlaylist:
            Menu("Add to Playlist") {
                AddToPlaylistMenuItems(
                    playlists: playlists,
                    showsKeyEquivalents: showsKeyEquivalents,
                    newPlaylist: { actions.newPlaylist(rows) },
                    add: { actions.addToPlaylist($0, rows) }
                )
            }
        case .addToSyncProfile:
            Menu("Add to Sync Profile") {
                ForEach(syncProfiles) { profile in
                    Button(profile.name) { actions.addToSyncProfile(profile, rows) }
                }
                if !syncProfiles.isEmpty { Divider() }
                Button("New Sync Profile…") { actions.newSyncProfile(rows) }
            }
        case .getInfo:
            let item = Button("Get Info") { actions.getInfo(rows) }
            if showsKeyEquivalents {
                item
                    .keyboardShortcut("i", modifiers: .command)
            } else {
                item
            }
        case .goToArtist(let artist):
            // Navigates (the verb says so, UC-CM-09): All Tracks with `artist: ‹name›` (W2-I).
            Button("Go to Artist") { search?.goToArtist(artist) }
                .disabled(search == nil)
        case .download(let title):
            let item = Button {
                actions.download(rows)
            } label: {
                Label(title, systemImage: "arrow.down.circle")
            }
            if showsKeyEquivalents {
                item
                    .keyboardShortcut("d", modifiers: .command)
            } else {
                item
            }
        case .downloadAgain:
            Button("Download Again") { actions.downloadAgain(rows) }
        case .locateFile:
            Button("Locate File…") { actions.locateFile(rows) }
        case .showInFinder(let enabled):
            let item = Button("Show in Finder") { actions.showInFinder(rows) }
                .disabled(!enabled, reason: offlineVolumeName.map(TrackMenu.notConnectedHelp))
            if showsKeyEquivalents {
                item
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                item
            }
        case .copy(let filePath, let link):
            Menu("Copy") {
                Button("Title — Artist") { actions.copyTitleAndArtist(rows) }
                if filePath {
                    Button("File Path") { actions.copyFilePaths(rows) }
                }
                if link {
                    Button("Link") { actions.copyLinks(rows) }
                }
            }
        case .removeFromContainer(let title):
            // Shown without a key: a plain ⌫ equivalent could fire while the menu is open
            // instead of the highlighted item; ⌫ belongs to the focused list (IMP-014).
            Button(title) { actions.removeFromContainer(rows) }
        case .removeFromLibrary(let enabled):
            let item = Button("Remove from Library…", role: .destructive) { actions.removeFromLibrary(rows) }
                .disabled(!enabled, reason: offlineVolumeName.map(TrackMenu.notConnectedHelp))
            if showsKeyEquivalents {
                item
                    .keyboardShortcut(.delete, modifiers: .command)
            } else {
                item
            }
        case .extra(let extra):
            Button(extra.title) { actions.performExtra(extra.id, rows) }
                .disabled(!extra.isEnabled)
        }
    }
}

/// Add to Playlist ▸ (CM-SUB-PLAYLIST, UC-CM-11) — one builder for the track context menu, the
/// Track menu and the selection bar: `New Playlist…` — `Recent` (the three playlists tracks
/// were added to last) — the sidebar structure (playlist folders as submenus, playlists in
/// sidebar order, W3-PL). `playlists` are the ones offered (the current one is already left
/// out by the caller, UC-CM-08); the structure comes from `tree` or the window's sidebar.
struct AddToPlaylistMenuItems: View {
    let playlists: [Playlist]
    /// `⇧⌘N` next to `New Playlist…` (see `TrackMenu.showsKeyEquivalents`).
    var showsKeyEquivalents = true
    /// The sidebar's structure and recent playlists (the Track menu passes them; views read
    /// the window's `SidebarModel`).
    var tree: PlaylistSidebarTree? = nil
    var recent: [Playlist]? = nil
    let newPlaylist: () -> Void
    let add: (Int64) -> Void

    @Environment(SidebarModel.self) private var sidebar: SidebarModel?

    var body: some View {
        let item = Button("New Playlist…", action: newPlaylist)
        if showsKeyEquivalents {
            item
                .keyboardShortcut("n", modifiers: [.command, .shift])
        } else {
            item
        }
        let offered = Set(playlists.compactMap(\.id))
        let recentOffered = (recent ?? sidebar?.recentPlaylists() ?? []).filter { $0.id.map(offered.contains) ?? false }
        if !recentOffered.isEmpty {
            Divider()
            Section("Recent") {
                ForEach(recentOffered) { playlistButton($0) }
            }
        }
        if !playlists.isEmpty {
            Divider()
            let structure = tree ?? sidebar?.tree
            if let nodes = structure?.nodes, !nodes.isEmpty {
                ForEach(nodes) { node in
                    switch node {
                    case .playlist(let playlist):
                        if playlist.id.map(offered.contains) ?? false { playlistButton(playlist) }
                    case .folder(let folder, let children):
                        let inside = children.filter { $0.id.map(offered.contains) ?? false }
                        if !inside.isEmpty {
                            Menu(folder.name) {
                                ForEach(inside) { playlistButton($0) }
                            }
                        }
                    }
                }
            } else {
                ForEach(playlists) { playlistButton($0) }
            }
        }
    }

    private func playlistButton(_ playlist: Playlist) -> some View {
        Button(playlist.name) {
            if let id = playlist.id { add(id) }
        }
    }
}

/// What the track menu's items do — a track table's `TrackListActions`, or the Queue panel's
/// actions (W2-D), which act on queue entries rather than on rows of a list.
@MainActor
protocol TrackMenuActions {
    func play(_ rows: [TrackRow])
    func preview(_ rows: [TrackRow]?)
    func playNext(_ rows: [TrackRow])
    func addToQueue(_ rows: [TrackRow])
    func addToPlaylist(_ playlistID: Int64, _ rows: [TrackRow])
    func newPlaylist(_ rows: [TrackRow])
    func addToSyncProfile(_ profile: SyncProfile, _ rows: [TrackRow])
    func newSyncProfile(_ rows: [TrackRow])
    func getInfo(_ rows: [TrackRow])
    func download(_ rows: [TrackRow])
    func downloadAgain(_ rows: [TrackRow])
    func locateFile(_ rows: [TrackRow])
    func showInFinder(_ rows: [TrackRow])
    func copyTitleAndArtist(_ rows: [TrackRow])
    func copyFilePaths(_ rows: [TrackRow])
    func copyLinks(_ rows: [TrackRow])
    func removeFromContainer(_ rows: [TrackRow])
    func removeFromLibrary(_ rows: [TrackRow])
    // The Queue panel's own items (CM-QUEUE); a track table never offers them.
    func moveToEndOfQueue(_ rows: [TrackRow])
    func showInContext(_ rows: [TrackRow])
    func clearHistory()
    /// A place's own item (`TrackMenuItem.extra`, W3-GEN).
    func performExtra(_ id: String, _ rows: [TrackRow])
}

extension TrackMenuActions {
    func moveToEndOfQueue(_ rows: [TrackRow]) {}
    func showInContext(_ rows: [TrackRow]) {}
    func clearHistory() {}
    func performExtra(_ id: String, _ rows: [TrackRow]) {}
}

extension TrackListActions: TrackMenuActions {}

extension TrackMenu {
    /// Help of file actions (other than playback) disabled while the disk is away:
    /// `“Lexxar” is not connected`.
    static func notConnectedHelp(_ volumeName: String) -> String {
        "“\(volumeName)” is not connected"
    }
}

private extension View {
    /// Disabled with its reason as help text; enabled items carry no help.
    @ViewBuilder
    func disabled(_ isDisabled: Bool, reason: String?) -> some View {
        if isDisabled, let reason {
            self.disabled(true).help(reason)
        } else {
            self.disabled(isDisabled)
        }
    }
}
