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
/// | import | Import Files or Folder… (`ShellActions.importDropped`; onto Folders: `importChosen`) |
/// | M3U | Import M3U… (preview sheet, `DropCenter`) |
/// | link | Add from Link… (`QuickAddRouter`) |
/// | library file | Open Library… (`MainWindowPresenter.openLibrary`) |
/// | cover | Choose Cover… (`ShellEdits.setCover`, undoable) |
/// | genre row | Info's Genre field (`GenreEdits.setGenre`, one undoable tag edit) |
/// | genre table | `Add to “‹Genre›”` on a suggestion (`GenreWorkbench.stage`) |
/// | Reels view | `Import…` / `Add from Link…` of Discover ▸ Reels (`ReelsModel.addDropped`, `addDroppedLink`) |
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
        case .addReels(let urls):
            ReelsDropRouter.shared.addFiles(urls)
        case .fetchReelLink(let url):
            ReelsDropRouter.shared.fetchLink(url)
        case .openLibraryFile(let url, let ignored):
            MainWindowPresenter.shared.openLibrary(url, launch: .shared)
            if ignored > 0 { statusBar?.post(DropWords.ignoredWithLibrary(ignored)) }
        case .setCover(let source, let playlistID, let name):
            Task {
                if let refusal = await edits?.setCover(source, ofPlaylist: playlistID, name: name) {
                    say(refusal)
                }
            }
        case .setAlbumCover(let source, let albumID, let name):
            let covers = AlbumCoverLoader.coversDirectory(container)
            Task {
                if let refusal = await edits?.setAlbumCover(source, albumID: albumID, name: name, coversDirectory: covers) {
                    say(refusal)
                }
            }
        case .addTracksToAlbum(let ids, let albumID, _):
            Task { _ = try? await edits?.addTracks(toAlbum: albumID, trackIDs: ids) }
        case .movePlaylistItems(let items, let folderID, let before):
            Task { await edits?.movePlaylistItems(items, into: folderID, before: before) }
        case .movePlaylistItemsToTop(let items):
            Task { await edits?.movePlaylistItemsToTop(items) }
        case .moveSyncProfiles(let ids, let before):
            Task { await edits?.moveSyncProfiles(ids, before: before) }
        case .newPlaylistInFolder(let ids, let folderID):
            Task { await edits?.newPlaylist(inFolder: folderID, trackIDs: ids) }
        case .importFilesAsNewPlaylistInFolder(let urls, let folderID):
            Task {
                guard let shell else { return }
                let ids = await shell.importDropped(urls)
                if !ids.isEmpty { await shell.edits.newPlaylist(inFolder: folderID, trackIDs: ids) }
            }
        case .importM3UInFolder(let url, let folderID):
            DropCenter.shared.requestM3UImport(url, droppedOnPlaylist: nil, inFolder: folderID)
        case .importFilesIntoLibrary(let urls, _):
            // `Import Files or Folder…`'s own path: copied into the library folder when they
            // come from elsewhere, imported where they are when inside it (W3-ADD).
            shell?.importChosen(urls)
        case .setGenre(let ids, let name):
            // Same as Info's Genre field on the selection: one undoable tag edit (W3-GEN).
            Task { _ = try? await GenreEdits.live(undo: undo, container: container)?.setGenre(of: ids, to: name) }
        case .stageForGenre(let ids, let key, _):
            // Same as `Add to “‹Genre›”` on the suggestions: staged until Save (W3-GEN).
            Task {
                guard let pool = container.databaseManager?.pool else { return }
                let tracks = (try? await TrackTagRepository(database: pool).fetchTracks(ids: ids)) ?? []
                GenreWorkbench.shared.stage(tracks, genreKey: key)
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
        // A folder of Folders that wasn't expanded (the Queue panel's own drop) carries no track.
        items.filter { !$0.isFolder }
            .map { QueueRowDrag(trackId: $0.trackId, sourcePlaylistId: $0.sourcePlaylistId, queueEntryId: $0.queueEntryId) }
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
        /// The playlist the tracks go into (dropped on it, or `Import M3U into This Playlist…`);
        /// nil = a new playlist named after the file (PP-PLAYLISTS-01: never chosen by the
        /// file's name).
        let playlistID: Int64?
        /// For a new playlist: the playlist folder it goes into (dropped on a folder).
        var folderID: Int64? = nil
    }

    var m3uImport: M3UImport?

    /// `Import M3U…` / `Import M3U into This Playlist…` asked for the file panel; the window's
    /// `.fileImporter` answers into `m3uChoice` (nil playlist = a new playlist).
    var isChoosingM3U = false
    private(set) var m3uChoicePlaylistID: Int64?

    /// Export ▸ Playlist as M3U…: the playlist whose file the window's `.fileExporter` writes.
    var m3uExport: M3UExportRequest?

    func requestM3UImport(_ url: URL, droppedOnPlaylist playlistID: Int64?, inFolder folderID: Int64? = nil) {
        m3uImport = M3UImport(url: url, playlistID: playlistID, folderID: folderID)
    }

    /// Opens the file panel for an M3U, whose tracks go into `playlistID` (nil = new playlist).
    func chooseM3U(into playlistID: Int64?) {
        m3uChoicePlaylistID = playlistID
        isChoosingM3U = true
    }

    /// The panel's answer: the preview sheet for the chosen file.
    func m3uChosen(_ url: URL) {
        requestM3UImport(url, droppedOnPlaylist: m3uChoicePlaylistID)
    }
}

/// A playlist to write as an M3U file.
struct M3UExportRequest: Identifiable, Equatable {
    let id = UUID()
    let playlistID: Int64
    let name: String
    let document: M3UDocument
    /// Tracks without a file, left out of the file (said in the status bar).
    let leftOut: Int

    static func == (lhs: M3UExportRequest, rhs: M3UExportRequest) -> Bool { lhs.id == rhs.id }
}
