import AppKit
import Foundation

/// The commands behind the album menus (CM-ALB-CARD, CM-ALBD-MORE) and the page's buttons, shared
/// by the grid, the page's header and the keyboard (W4-2). Everything that works on an album's
/// tracks acts on its **listed** tracks in the album's own order (IMP-080); the shared track
/// commands (`TrackCommandActions`) do the rest, so an album behaves like its tracks.
@MainActor
struct AlbumActions {
    let container: DependencyContainer
    let shell: ShellActions?
    let navigation: NavigationModel?
    let statusBar: StatusBarCenter?
    let undo: UndoCenter?

    private var trackRepository: AlbumTrackRepository? {
        container.databaseManager.map { AlbumTrackRepository(database: $0.pool) }
    }

    /// The listed tracks of the albums, in each album's order, in the albums' order.
    func tracks(of albumIDs: [Int64]) async -> [Track] {
        guard let repository = trackRepository else { return [] }
        var result: [Track] = []
        var seen = Set<Int64>()
        for id in albumIDs {
            for track in (try? await repository.tracks(of: id)) ?? [] where track.id.map({ seen.insert($0).inserted }) ?? false {
                result.append(track)
            }
        }
        return result
    }

    // MARK: Playing (IMP-080)

    /// Play / Shuffle: from the first track that can play, the rest of the album as the queue
    /// context; tracks that can't play are passed over by the queue rules and the player's own
    /// sentence says how many. With the library's drive away it says why it doesn't (V-ALBD.N25).
    func play(_ albumIDs: [Int64], name: String, shuffled: Bool = false) {
        if let reason = TrackTableLiveState.drive(container).cantPlayReason {
            statusBar?.post(reason)
            return
        }
        Task {
            let rows = await tracks(of: albumIDs)
            let playable = rows.filter(\.isLocal)
            guard let first = playable.first else {
                statusBar?.post(rows.isEmpty
                    ? "Nothing to play — “\(name)” has no tracks in the library"
                    : "Nothing to play — no track of “\(name)” is downloaded")
                return
            }
            if let id = albumIDs.first, albumIDs.count == 1 {
                container.playbackViewModel?.willActivate(nil, from: PlaybackOrigin(
                    place: .albums, path: [.album(id)], listKey: "album", container: .album(id: id, name: name)))
            }
            if shuffled {
                await container.playbackViewModel?.playShuffled(playable)
            } else if let activate = shell?.activateTrack {
                activate(first, rows)
            } else {
                await container.playbackViewModel?.playTrack(first, queue: rows)
            }
        }
    }

    func playNext(_ albumIDs: [Int64]) {
        Task { TrackCommandActions.playNext(await tracks(of: albumIDs), undo: undo, container: container) }
    }

    func addToQueue(_ albumIDs: [Int64]) {
        Task { TrackCommandActions.addToQueue(await tracks(of: albumIDs), undo: undo, container: container) }
    }

    // MARK: Add to

    func addToPlaylist(_ playlistID: Int64, albumIDs: [Int64]) {
        Task { TrackCommandActions.addToPlaylist(playlistID, tracks: await tracks(of: albumIDs), shell: shell) }
    }

    func newPlaylist(albumIDs: [Int64]) {
        Task { TrackCommandActions.newPlaylistFromSelection(await tracks(of: albumIDs), shell: shell) }
    }

    func addToSyncProfile(_ profile: SyncProfile, albumIDs: [Int64]) {
        Task { TrackCommandActions.addToSyncProfile(profile, tracks: await tracks(of: albumIDs), shell: shell) }
    }

    func newSyncProfile(albumIDs: [Int64]) {
        Task { TrackCommandActions.newSyncProfileFromSelection(await tracks(of: albumIDs)) }
    }

    // MARK: Navigation

    func open(_ albumID: Int64) {
        navigation?.push(.album(albumID))
    }

    /// `Go to Artist`: All Tracks filtered by `artist: ‹album artist›` (the grid and the page).
    func goToArtist(_ artist: String, search: ToolbarSearchModel?) {
        search?.goToArtist(artist)
    }

    // MARK: Files

    /// `Download ‹n› Missing`: the tracks without a file that aren't downloading (not downloaded
    /// and failed), through the download pipeline; Activity reports.
    func downloadMissing(_ albumIDs: [Int64]) {
        Task {
            let missing = await tracks(of: albumIDs).filter { track in
                switch track.availability() {
                case .failed, .notDownloaded: true
                default: false
                }
            }
            guard !missing.isEmpty else { return }
            TrackCommandActions.download(missing, container: container)
            statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: missing.count))
        }
    }

    /// `Show in Finder`: the album's files that can be found.
    func showInFinder(_ albumIDs: [Int64]) {
        Task { TrackCommandActions.showInFinder(await tracks(of: albumIDs), container: container) }
    }

    // MARK: Remove from Library… (IMP-079, A-ALB-REMOVE)

    /// Asks, in numbers, then — only on Move to Trash — runs the track path
    /// (`TrackLibraryRemoval`) on the albums' listed tracks. Not undoable (UC-UNDO-03). Each
    /// album that lost its last track goes with it.
    func askToRemove(_ albums: [(id: Int64, title: String)]) {
        guard let repository = container.albumRepository else { return }
        Task {
            guard let impact = try? await repository.removalImpact(albumIDs: albums.map(\.id)), !impact.trackIDs.isEmpty else { return }
            let all = await tracks(of: albums.map(\.id))
            let confirmation = AlbumRemoval.confirmation(
                titles: albums.map(\.title), trackCount: all.count, fileCount: all.filter(\.isLocal).count,
                playlists: impact.playlists, syncProfiles: impact.syncProfiles)
            LibraryRemovalCenter.shared.ask(all, confirmation: confirmation) { _ in
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
            }
        }
    }
}

// MARK: - The question (A-ALB-REMOVE)

enum AlbumRemoval {
    /// `Remove “Low Season” from the library?` · `Its 10 tracks are removed from the library, from
    /// 3 playlists and 1 sync profile, and their files move to the Trash. You can put the files
    /// back from the Trash.` Pure, so the wording is unit-tested.
    static func confirmation(titles: [String], trackCount: Int, fileCount: Int, playlists: Int, syncProfiles: Int) -> LibraryRemovalConfirmation {
        let subject = titles.count == 1 ? "“\(titles[0])”" : StatusBarText.count(titles.count, "album", "albums")
        let title = "Remove \(subject) from the library?"
        let one = trackCount == 1
        var places: [String] = []
        if playlists > 0 { places.append(StatusBarText.count(playlists, "playlist", "playlists")) }
        if syncProfiles > 0 { places.append(StatusBarText.count(syncProfiles, "sync profile", "sync profiles")) }
        let from = "from the library" + (places.isEmpty ? "" : ", from " + places.joined(separator: " and "))
        let tracks = titles.count == 1
            ? (one ? "Its 1 track is" : "Its \(trackCount.formatted(.number)) tracks are")
            : (one ? "Its 1 track is" : "Their \(trackCount.formatted(.number)) tracks are")
        if fileCount == 0 {
            return LibraryRemovalConfirmation(title: title, message: "\(tracks) removed \(from). Nothing moves to the Trash — they have no files.",
                                              confirmTitle: "Remove from Library")
        }
        let files: String
        if fileCount == trackCount {
            files = one ? "its file moves to the Trash. You can put the file back from the Trash."
                : "their files move to the Trash. You can put the files back from the Trash."
        } else {
            files = "the files of \(StatusBarText.count(fileCount, "track", "tracks")) move to the Trash. You can put the files back from the Trash."
        }
        return LibraryRemovalConfirmation(title: title, message: "\(tracks) removed \(from), and \(files)", confirmTitle: "Move to Trash")
    }
}

// MARK: - Dragging an album

/// A dragged album card becomes its tracks when it is dropped (`DropLoader`): one item per listed
/// track, in album order, from the same library. Items of another library stay as they are (the
/// target refuses them).
@MainActor
enum AlbumDragExpansion {
    static func expand(_ items: [TrackDragItem], container: DependencyContainer = .shared) async -> [TrackDragItem] {
        let libraryID = container.activeLibrary?.libraryId
        let repository = container.databaseManager.map { AlbumTrackRepository(database: $0.pool) }
        var result: [TrackDragItem] = []
        for item in items {
            guard let albumID = item.albumId else {
                result.append(item)
                continue
            }
            if let itemLibrary = item.libraryId, let libraryID, itemLibrary != libraryID {
                result.append(item)
                continue
            }
            guard let repository else { continue }
            let tracks = (try? await repository.tracks(of: albumID)) ?? []
            let context = TrackDragContext.current(container)
            result += tracks.compactMap { track in
                context.item(for: track) ?? track.id.map { TrackDragItem(trackId: $0, libraryId: libraryID) }
            }
        }
        return result
    }
}
