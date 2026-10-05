import Foundation
import Observation

/// Runs a `DropDecision` through the commands that already exist — the same implementation as
/// the menu item that does the same thing (UC-A11Y: every drop has a menu equivalent):
///
/// | Decision | Same as |
/// |---|---|
/// | append / new playlist | Add to Playlist ▸ / New Playlist from Selection (`ShellEdits`) |
/// | sync profile | Add to Sync Profile ▸ (`ShellEdits.addTracks(_:toSyncProfile:)`, undoable) |
/// | Play Next | Play Next (`QueueEditCommands.dropOnPlayer`) |
/// | import | Import Files or Folder… (`ShellActions.importDropped`) |
/// | M3U | Import M3U… (preview sheet, `DropCenter`) |
/// | link | Add from Link… (`QuickAddRouter`) |
/// | library file | Open Library… (`MainWindowPresenter.openLibrary`) |
/// | cover | Choose Cover… (`ShellEdits.setCover`, undoable) |
///
/// Placements at a position (`placeTracks`, `placePlaylists`, `importFilesAndPlace`) need the
/// table's rows and are run by `PlaylistTable`; here they fall back to appending.
@MainActor
struct DropPerformer {
    var container: DependencyContainer = .shared
    var shell: ShellActions?
    var statusBar: StatusBarCenter?
    var undo: UndoCenter
    /// Where a refusal is said; nil = the status bar. Covers say it in place (UC-SURF-04).
    var sayRefusal: ((String) -> Void)?

    func perform(_ decision: DropDecision) {
        let edits = shell?.edits
        switch decision {
        case .appendTracks(let ids, let playlistID, _):
            Task { await edits?.addTracks(ids, toPlaylist: playlistID) }
        case .newPlaylist(let ids):
            shell?.newPlaylistFromSelection(trackIDs: ids)
        case .addTracksToSyncProfile(let ids, let profileID, let name):
            Task { await edits?.addTracks(ids, toSyncProfile: profileID, name: name) }
        case .addPlaylistsToSyncProfile(let ids, let profileID, let name):
            Task { await edits?.addPlaylists(ids, toSyncProfile: profileID, name: name) }
        case .appendPlaylists(let ids, let playlistID, _), .placePlaylists(let ids, let playlistID, _):
            Task {
                guard let edits else { return }
                let tracks = await edits.tracks(ofPlaylists: ids)
                await edits.addTracks(tracks, toPlaylist: playlistID)
            }
        case .placeTracks(let payload, let playlistID, _):
            Task { await edits?.addTracks(payload.trackIDs, toPlaylist: playlistID) }
        case .playNext(let payload):
            guard let playback = container.playbackViewModel else { return }
            QueueEditCommands.dropOnPlayer(payload.queueRows, playback: playback, undo: undo)
        case .playNextPlaylists(let ids):
            guard let playback = container.playbackViewModel else { return }
            Task {
                guard let edits else { return }
                let tracks = await edits.tracks(ofPlaylists: ids)
                QueueEditCommands.dropOnPlayer(tracks.map { QueueRowDrag(trackId: $0) }, playback: playback, undo: undo)
            }
        case .importFiles(let urls):
            Task { await shell?.importDropped(urls) }
        case .importFilesAndAdd(let urls, let playlistID, let name), .importFilesAndPlace(let urls, let playlistID, let name):
            Task {
                guard let shell else { return }
                let ids = await shell.importDropped(urls, intoPlaylist: name)
                if !ids.isEmpty { await shell.edits.addTracks(ids, toPlaylist: playlistID) }
            }
        case .importFilesAsNewPlaylist(let urls, let name):
            Task {
                guard let shell else { return }
                let ids = await shell.importDropped(urls)
                if !ids.isEmpty { await shell.edits.newPlaylist(named: name, fromTrackIDs: ids) }
            }
        case .importM3U(let url, let playlistID):
            DropCenter.shared.requestM3UImport(url, droppedOnPlaylist: playlistID)
        case .openLink(let url, _):
            // The playlist it was dropped on can't be preselected until W3-ADD's sheets exist.
            QuickAddRouter.shared.open(url: url.absoluteString)
        case .openLibraryFile(let url, let ignored):
            MainWindowPresenter.shared.openLibrary(url, launch: .shared)
            if ignored > 0 { statusBar?.post(DropWords.ignoredWithLibrary(ignored)) }
        case .setCover(let source, let playlistID, let name):
            Task {
                if let refusal = await edits?.setCover(source, ofPlaylist: playlistID, name: name) {
                    say(refusal)
                }
            }
        case .refuse(let message):
            if let message { say(message) }
        }
    }

    private func say(_ message: String) {
        if let sayRefusal { sayRefusal(message) } else { statusBar?.post(message) }
    }
}

extension TrackDragPayload {
    /// The queue's own drop type (`QueueEditCommands.drop` / `dropOnPlayer`): track ids, and the
    /// entry ids of rows dragged inside the Queue panel.
    var queueRows: [QueueRowDrag] {
        items.map { QueueRowDrag(trackId: $0.trackId, sourcePlaylistId: $0.sourcePlaylistId, queueEntryId: $0.queueEntryId) }
    }

    /// Items dropped on the Queue panel as the queue's drop type — none when they come from
    /// another library (the queue's entry point then does nothing).
    @MainActor
    static func queueRows(_ items: [TrackDragItem], container: DependencyContainer) -> [QueueRowDrag] {
        let payload = TrackDragPayload(items: items)
        guard !payload.crossesLibraries(current: container.activeLibrary?.libraryId) else { return [] }
        return payload.queueRows
    }
}

// MARK: - Window-level requests

/// What a drop asks the main window to present: the M3U preview sheet (S-PLD-M3U-PREVIEW) for
/// an `.m3u` dropped anywhere — the window hosts it, so a drop on a sidebar row never
/// navigates to show it.
@MainActor
@Observable
final class DropCenter {
    static let shared = DropCenter()

    struct M3UImport: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// The playlist it was dropped on (W3-PL's sheet imports into it; today's import engine
        /// chooses its playlist by the file name).
        let playlistID: Int64?
    }

    var m3uImport: M3UImport?

    func requestM3UImport(_ url: URL, droppedOnPlaylist playlistID: Int64?) {
        m3uImport = M3UImport(url: url, playlistID: playlistID)
    }
}
