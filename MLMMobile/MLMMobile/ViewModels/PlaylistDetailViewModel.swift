import Foundation
import Combine

/// Drives the playlist detail view: ordered entries, reorder, remove, add-from-library.
@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published var entries: [PlaylistEntry] = []
    @Published var entryTracks: [IndexedTrack?] = []
    @Published var isEditing = false
    @Published var likedUUIDs: Set<String> = []
    @Published var loadError: String?

    let playlist: LocalPlaylist
    private let engine: PlaylistEngine
    private let indexer: LibraryIndexer
    private let likesService: LikesService

    init(playlist: LocalPlaylist, engine: PlaylistEngine, indexer: LibraryIndexer, likesService: LikesService) {
        self.playlist = playlist
        self.engine = engine
        self.indexer = indexer
        self.likesService = likesService
    }

    /// Load entries and resolve tracks from the indexed library.
    func load() {
        do {
            entries = try engine.fetchEntries(playlistID: playlist.id!)
            likedUUIDs = try likesService.fetchLikedUUIDs()
            entryTracks = entries.map { entry in
                try? indexer.dbQueue.read { db -> IndexedTrack? in
                    try IndexedTrack.fetchOne(db, key: ["uuid": entry.trackUUID])
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Remove an entry at the given index.
    func removeEntry(at index: Int) {
        guard index < entries.count else { return }
        let entry = entries[index]
        do {
            try engine.removeEntry(entryID: entry.id!)
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Move entries (for reorder in edit mode).
    func moveEntries(from source: IndexSet, to destination: Int) {
        var orderedIDs = entries.map { $0.id! }
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        do {
            try engine.reorderEntries(playlistID: playlist.id!, entryIDs: orderedIDs)
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Add a track from the library to this playlist.
    func addTrack(_ track: IndexedTrack) {
        do {
            try engine.addEntry(playlistID: playlist.id!, trackUUID: track.uuid, relativePath: track.path)
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Toggle like on a track.
    func toggleLike(trackUUID: String) {
        do {
            _ = try likesService.toggleLike(trackUUID: trackUUID)
            likedUUIDs = try likesService.fetchLikedUUIDs()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Write the playlist back to the sync folder.
    func writeBack(to directory: URL) {
        do {
            try engine.writeBack(playlist: playlist, to: directory)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
