import Foundation
import SwiftUI
import Combine

/// Drives the library browsing UI: loads the manifest, indexes it, and exposes
/// filtered/searched track and playlist lists.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var tracks: [IndexedTrack] = []
    @Published var playlists: [IndexedPlaylist] = []
    @Published var localPlaylists: [LocalPlaylist] = []
    @Published var likedUUIDs: Set<String> = []
    @Published var selectedTrack: IndexedTrack?
    @Published var selectedEnergyBucket: Int?
    @Published var searchQuery: String = ""
    @Published var isLoading = false
    @Published var isEmpty = true
    @Published var loadError: String?

    var indexer: LibraryIndexer?
    var playlistEngine: PlaylistEngine?
    var likesService: LikesService?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // React to search/filter changes.
        Publishers.CombineLatest($searchQuery, $selectedEnergyBucket)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] query, bucket in
                Task { @MainActor in
                    await self?.reloadFilteredTracks(query: query, bucket: bucket)
                }
            }
            .store(in: &cancellables)
    }

    /// Initialize the indexer and load the manifest from the sync folder.
    func load(syncFolder: SyncFolder) async {
        isLoading = true
        loadError = nil

        do {
            if indexer == nil {
                indexer = try LibraryIndexer.makeDefault()
                if let dbQueue = indexer?.dbQueue {
                    playlistEngine = PlaylistEngine(dbQueue: dbQueue)
                    likesService = LikesService(dbQueue: dbQueue, engine: playlistEngine!)
                }
            }

            guard let manifestURL = syncFolder.manifestURL else {
                isEmpty = true
                isLoading = false
                return
            }

            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                isEmpty = true
                isLoading = false
                return
            }

            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)

            guard manifest.schema == 1 else {
                loadError = "Unsupported manifest schema: \(manifest.schema)"
                isLoading = false
                return
            }

            _ = try indexer?.index(manifest: manifest)
            await reloadFilteredTracks(query: searchQuery, bucket: selectedEnergyBucket)
            playlists = (try? indexer?.fetchAllPlaylists()) ?? []
            localPlaylists = (try? playlistEngine?.fetchAllPlaylists()) ?? []
            likedUUIDs = (try? likesService?.fetchLikedUUIDs()) ?? []
            isEmpty = tracks.isEmpty && playlists.isEmpty && localPlaylists.isEmpty
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    /// Sync playlists from a specific directory.
    func syncPlaylists(from directory: URL) {
        guard let playlistEngine else { return }
        do {
            _ = try playlistEngine.syncFromFolder(playlistsDirectory: directory)
            localPlaylists = try playlistEngine.fetchAllPlaylists()
            likedUUIDs = (try? likesService?.fetchLikedUUIDs()) ?? []
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Toggle like on a track and update state.
    func toggleLike(trackUUID: String) {
        guard let likesService else { return }
        do {
            _ = try likesService.toggleLike(trackUUID: trackUUID)
            likedUUIDs = try likesService.fetchLikedUUIDs()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Create a PlaylistDetailViewModel for a given playlist.
    func makePlaylistDetailViewModel(for playlist: LocalPlaylist) -> PlaylistDetailViewModel? {
        guard let playlistEngine, let indexer, let likesService else { return nil }
        return PlaylistDetailViewModel(
            playlist: playlist,
            engine: playlistEngine,
            indexer: indexer,
            likesService: likesService
        )
    }

    /// Reload tracks with current search and energy filter applied.
    func reloadFilteredTracks(query: String, bucket: Int?) async {
        guard let indexer else { return }
        do {
            if let bucket {
                var filtered = try indexer.fetchTracks(energyBucket: bucket)
                if !query.isEmpty {
                    filtered = filtered.filter { track in
                        track.title.localizedCaseInsensitiveContains(query) ||
                        track.artist.localizedCaseInsensitiveContains(query) ||
                        track.album.localizedCaseInsensitiveContains(query)
                    }
                }
                tracks = filtered
            } else if !query.isEmpty {
                tracks = try indexer.searchTracks(query: query)
            } else {
                tracks = try indexer.fetchAllTracks()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Select a track (no playback in WP5 — just selection).
    func selectTrack(_ track: IndexedTrack) {
        selectedTrack = track
    }
}
