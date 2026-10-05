import SwiftUI

/// The track menu (CM-TRACK) — one builder for the table's context menu and, later, the More
/// (•••) menus and the selection bar's More (UC-CM-02). Renders a `TrackMenuModel` in
/// sections (DEC-039 group order); shortcuts are shown next to items (UC-CM-06); only Play
/// and Download carry a glyph.
struct TrackMenu: View {
    let model: TrackMenuModel
    let rows: [TrackRow]
    let actions: TrackListActions
    /// Playlists offered in Add to Playlist ▸ (the current one already left out, UC-CM-08).
    let playlists: [Playlist]
    let syncProfiles: [SyncProfile]
    /// Help of the items disabled while the library's disk is away (UC-CM-05).
    let offlineHelp: String?

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
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!enabled)
            .help(enabled ? "" : (offlineHelp ?? ""))
        case .playNext:
            Button("Play Next") { actions.playNext(rows) }
                .keyboardShortcut(.return, modifiers: .option)
        case .addToPlaylist:
            Menu("Add to Playlist") {
                Button("New Playlist…") { actions.newPlaylist(rows) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                if !playlists.isEmpty {
                    Divider()
                    ForEach(playlists) { playlist in
                        Button(playlist.name) {
                            if let id = playlist.id { actions.addToPlaylist(id, rows) }
                        }
                    }
                }
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
            Button("Get Info") { actions.getInfo(rows) }
                .keyboardShortcut("i", modifiers: .command)
        case .download(let title):
            Button {
                actions.download(rows)
            } label: {
                Label(title, systemImage: "arrow.down.circle")
            }
            .keyboardShortcut("d", modifiers: .command)
        case .downloadAgain:
            Button("Download Again") { actions.downloadAgain(rows) }
        case .showInFinder(let enabled):
            Button("Show in Finder") { actions.showInFinder(rows) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!enabled)
                .help(enabled ? "" : (offlineHelp ?? ""))
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
            Button(title) { actions.removeFromContainer(rows) }
                .keyboardShortcut(.delete, modifiers: [])
        case .removeFromLibrary(let enabled):
            Button("Remove from Library…", role: .destructive) { actions.removeFromLibrary(rows) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!enabled)
                .help(enabled ? "" : (offlineHelp ?? ""))
        }
    }
}
