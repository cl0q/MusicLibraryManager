import Foundation
import GRDB

/// ViewModel for a single playlist's detail view — track list,
/// drag-and-drop reorder, add/remove tracks, import from M3U.
///
/// Phase 6 implementation. Uses fractional positioning (string-based)
/// for O(1) reorder without renumbering the entire list — matching the
/// Tauri app's `commands/playlist.rs` approach.
@Observable
final class PlaylistDetailViewModel {

    // MARK: - Published State

    /// The playlist being viewed.
    private(set) var playlist: Playlist

    /// Tracks in the playlist, ordered by position.
    private(set) var tracks: [Track] = []

    /// One root-backed availability snapshot shared by every detail action
    /// and the playlist table. It is rebuilt only after a complete track load.
    private(set) var availabilityByTrackID: [Int64: TrackAvailability] = [:]

    /// The authoritative external source for a linked playlist.
    private(set) var source: Source?

    /// Whether tracks are loading.
    private(set) var isLoading = false

    /// Error message from the last failed operation.
    private(set) var errorMessage: String?

    /// Search query for filtering tracks within the playlist.
    var searchQuery: String = "" {
        didSet { applyFilter() }
    }

    /// Filtered tracks based on search query.
    private(set) var displayedTracks: [Track] = []

    var downloadStatus: PlaylistDownloadStatus {
        PlaylistDownloadStatus(
            playlistID: playlist.id ?? -1,
            tracks: tracks,
            availabilityByTrackID: availabilityByTrackID
        )
    }

    var failedTracks: [Track] {
        tracks.filter {
            if case .failed = availability(for: $0) { return true }
            return false
        }
    }

    var notDownloadedTracks: [Track] {
        tracks.filter { availability(for: $0) == .notDownloaded }
    }

    var playableTracks: [Track] {
        tracks.filter { availability(for: $0) == .local }
    }

    var downloadPin: DownloadOrchestrator.PreferredSource {
        source?.playlistSourceIdentity.downloadPin ?? .auto
    }

    func availability(for track: Track) -> TrackAvailability {
        guard let trackID = track.id else { return track.availability() }
        return availabilityByTrackID[trackID] ?? track.availability()
    }

    /// Selected track IDs for multi-select operations.
    var selectedTrackIDs: Set<Int64> = []

    // MARK: - Dependencies

    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let configRepository: ConfigRepository?

    // MARK: - Init

    init(
        playlist: Playlist,
        playlistRepository: PlaylistRepository,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        configRepository: ConfigRepository? = nil
    ) {
        self.playlist = playlist
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.configRepository = configRepository
    }

    // MARK: - Load

    /// Load all tracks for this playlist, ordered by position.
    @MainActor
    func loadTracks() async {
        guard let playlistId = playlist.id else { return }

        isLoading = true
        errorMessage = nil

        do {
            // Re-fetch playlist metadata from the database to update stale columns (e.g. sourceId after reauth)
            if let freshPlaylist = try await playlistRepository.fetch(id: playlistId) {
                self.playlist = freshPlaylist
            }

            if let sourceID = playlist.sourceId {
                source = try await sourceRepository.fetch(id: sourceID)
            } else {
                source = nil
            }

            let libraryRoot = await libraryRootSnapshot()
            let loadedTracks = try await playlistRepository.fetchTracks(playlistId: playlistId)
            let availability = TrackPresentationAvailability.map(
                tracks: loadedTracks,
                libraryRoot: libraryRoot,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )

            tracks = loadedTracks
            availabilityByTrackID = availability
            applyFilter()
        } catch {
            errorMessage = "Failed to load tracks: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Refresh tracks (after external changes).
    @MainActor
    func refresh() async {
        await loadTracks()
    }

    /// Revalidates the existing rows after the configured library root changes
    /// without issuing another playlist-track query.
    @MainActor
    func refreshAvailabilitySnapshot() async {
        let libraryRoot = await libraryRootSnapshot()
        availabilityByTrackID = TrackPresentationAvailability.map(
            tracks: tracks,
            libraryRoot: libraryRoot,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    // MARK: - Source Synchronization

    /// Whether this playlist supports synchronization from an external source.
    var canSync: Bool {
        playlist.isLiked == 1 && playlist.sourceId != nil
    }

    /// Whether the playlist is currently syncing.
    private(set) var isSyncingSource = false

    /// Trigger synchronization with the upstream source (e.g. SoundCloud Likes).
    @MainActor
    func syncSource() async {
        guard let playlistId = playlist.id else { return }

        isSyncingSource = true
        errorMessage = nil

        do {
            // 1. Fetch fresh playlist from DB to update any stale in-memory fields (e.g. from reauth)
            if let freshPlaylist = try await playlistRepository.fetch(id: playlistId) {
                self.playlist = freshPlaylist
            }

            // After refresh, double check if we can actually sync
            guard canSync else {
                throw NSError(domain: "PlaylistDetailViewModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "This playlist does not support source synchronization"])
            }

            guard let sourceId = playlist.sourceId else {
                throw NSError(domain: "PlaylistDetailViewModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "Source ID is missing"])
            }

            let container = DependencyContainer.shared
            guard let sourceRepo = container.sourceRepository else {
                throw NSError(domain: "PlaylistDetailViewModel", code: 500, userInfo: [NSLocalizedDescriptionKey: "Source repository is unavailable"])
            }

            // 2. Fetch the source
            var source = try await sourceRepo.fetch(id: sourceId)

            // 3. Robust Self-Healing Fallback
            if source == nil {
                var expectedSourceName: String? = nil
                let lowerName = playlist.name.lowercased()
                if lowerName.contains("soundcloud") {
                    expectedSourceName = "soundcloud"
                } else if lowerName.contains("spotify") {
                    expectedSourceName = "spotify"
                } else if lowerName.contains("apple music") || lowerName.contains("applemusic") {
                    expectedSourceName = "apple_music"
                }

                if let sourceName = expectedSourceName {
                    let allSources = try await sourceRepo.fetchAll()
                    if let matchingSource = allSources.first(where: { $0.name == sourceName }) {
                        if let freshSourceId = matchingSource.id {
                            // Update the sourceId in DB
                            try await playlistRepository.updateSourceId(id: playlistId, sourceId: freshSourceId)
                            // Refetch fresh playlist
                            if let freshPlaylist = try await playlistRepository.fetch(id: playlistId) {
                                self.playlist = freshPlaylist
                            }
                            source = matchingSource
                            AppLogger.shared.info(
                                "PlaylistDetailViewModel: healed stale source reference for '\(playlist.name)' to source id \(freshSourceId)",
                                source: "PlaylistDetailViewModel"
                            )
                        }
                    }
                }
            }

            // 4. If we still don't have a source, throw the error
            guard let activeSource = source else {
                throw NSError(domain: "PlaylistDetailViewModel", code: 404, userInfo: [NSLocalizedDescriptionKey: "Linked source not found"])
            }

            let sourceType = activeSource.sourceType
            var newTracks = 0

            switch sourceType {
            case .soundcloud:
                guard let tokenStorage = container.tokenStorage,
                      let oauthManager = container.oauthManager,
                      let trackRepo = container.trackRepository,
                      let plRepo = container.playlistRepository else {
                    throw NSError(domain: "PlaylistDetailViewModel", code: 500, userInfo: [NSLocalizedDescriptionKey: "Missing dependencies for SoundCloud sync"])
                }
                let client = SoundCloudClient(
                    tokenStorage: tokenStorage,
                    oauthManager: oauthManager,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo,
                    playlistRepository: plRepo
                )
                newTracks = try await client.syncLikes()

            case .spotify:
                guard let tokenStorage = container.tokenStorage,
                      let oauthManager = container.oauthManager,
                      let trackRepo = container.trackRepository else {
                    throw NSError(domain: "PlaylistDetailViewModel", code: 500, userInfo: [NSLocalizedDescriptionKey: "Missing dependencies for Spotify sync"])
                }
                let client = SpotifyClient(
                    tokenStorage: tokenStorage,
                    oauthManager: oauthManager,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo
                )
                newTracks = try await client.syncLikedSongs()

            case .appleMusic:
                guard let tokenStorage = container.tokenStorage,
                      let trackRepo = container.trackRepository else {
                    throw NSError(domain: "PlaylistDetailViewModel", code: 500, userInfo: [NSLocalizedDescriptionKey: "Missing dependencies for Apple Music sync"])
                }
                let client = AppleMusicClient(
                    tokenStorage: tokenStorage,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo
                )
                newTracks = try await client.syncLibrary()

            case .unknown:
                throw NSError(domain: "PlaylistDetailViewModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported source sync"])
            }

            // Reload the tracks in this playlist
            await loadTracks()

            if newTracks > 0 {
                // Post notification to refresh library
                NotificationCenter.default.post(
                    name: .libraryDidImport,
                    object: nil,
                    userInfo: ["succeeded": newTracks, "skipped": 0]
                )
            }

            // Post notification that playlist changed so covers can regenerate if needed
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )

        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }

        isSyncingSource = false
    }

    // MARK: - Add Tracks

    /// Add tracks to the playlist at the end.
    ///
    /// Generates fractional positions after the last track.
    ///
    /// - Parameter trackIds: IDs of tracks to add
    @MainActor
    func addTracks(_ trackIds: [Int64]) async {
        guard let playlistId = playlist.id else { return }

        // Generate position after the last track
        let nextPosition = generateNextPosition()

        do {
            try await playlistRepository.addTracks(
                playlistId: playlistId,
                trackIds: trackIds,
                startPosition: nextPosition
            )
            await loadTracks()

            // D-04 Re-Generate-Trigger: userInfo lets PlaylistCoverService regenerate.
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        } catch {
            errorMessage = "Failed to add tracks: \(error.localizedDescription)"
        }
    }

    /// Add tracks to the playlist at a specific index.
    ///
    /// Generates fractional positions for the new tracks.
    ///
    /// - Parameters:
    ///   - trackIds: IDs of tracks to add
    ///   - index: Target insertion index
    @MainActor
    func addTracks(_ trackIds: [Int64], at index: Int) async {
        guard let playlistId = playlist.id else { return }
        guard !trackIds.isEmpty else { return }

        let targetPos: String
        if tracks.isEmpty {
            targetPos = FractionalIndexer.positionBetween(left: nil, right: nil)
        } else {
            targetPos = fractionalPosition(insertingAt: index, excluding: -1)
        }

        do {
            try await playlistRepository.addTracks(
                playlistId: playlistId,
                trackIds: trackIds,
                startPosition: targetPos
            )
            await loadTracks()

            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        } catch {
            errorMessage = "Failed to add tracks: \(error.localizedDescription)"
        }
    }


    // MARK: - Remove Tracks

    /// Remove selected tracks from the playlist.
    @MainActor
    func removeSelectedTracks() async {
        guard let playlistId = playlist.id else { return }

        do {
            for trackId in selectedTrackIDs {
                try await playlistRepository.removeTrack(
                    playlistId: playlistId,
                    trackId: trackId
                )
            }

            selectedTrackIDs.removeAll()
            await loadTracks()

            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        } catch {
            errorMessage = "Failed to remove tracks: \(error.localizedDescription)"
        }
    }

    /// Remove a single track from the playlist.
    @MainActor
    func removeTrack(_ trackId: Int64) async {
        guard let playlistId = playlist.id else { return }

        do {
            try await playlistRepository.removeTrack(playlistId: playlistId, trackId: trackId)
            await loadTracks()

            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        } catch {
            errorMessage = "Failed to remove track: \(error.localizedDescription)"
        }
    }

    /// Removes several tracks from this playlist without deleting library files.
    @MainActor
    func removeTracks(_ trackIDs: Set<Int64>) async {
        guard !trackIDs.isEmpty else { return }
        selectedTrackIDs = trackIDs
        await removeSelectedTracks()
    }

    // MARK: - Reorder (Drag & Drop)

    /// Move a track to a new position via drag-and-drop.
    ///
    /// Uses fractional positioning: the new position is the midpoint between
    /// the surrounding tracks, avoiding a full renumber of the playlist.
    ///
    /// - Parameters:
    ///   - sourceIndex: Index of the track being moved (in `tracks` array)
    ///   - destinationIndex: Target index to insert before
    @MainActor
    func moveTrack(from sourceIndex: Int, to destinationIndex: Int) async {
        guard let playlistId = playlist.id else { return }
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0,
              sourceIndex < tracks.count else { return }

        let track = tracks[sourceIndex]
        guard let trackId = track.id else { return }

        // Calculate new position
        let newPosition = fractionalPosition(
            insertingAt: destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex,
            excluding: sourceIndex
        )

        do {
            try await playlistRepository.reorderTrack(
                playlistId: playlistId,
                trackId: trackId,
                newPosition: newPosition
            )
            await loadTracks()

            // Phase 36 / D-04 Re-Generate-Trigger: cover must regenerate
            // when reordering touches the top-4 tracks. The userInfo payload
            // lets Plan 02's PlaylistCoverService regenerate just one playlist
            // instead of refreshing all on every reorder.
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        } catch {
            errorMessage = "Failed to reorder: \(error.localizedDescription)"
        }
    }

    // MARK: - M3U Import

    /// Import tracks from an M3U file into this playlist.
    ///
    /// Reads the M3U file, resolves each line as a relative or
    /// absolute file path, looks up matching tracks in the database,
    /// and adds them to the playlist.
    ///
    /// - Parameter url: URL of the M3U/M3U8 file
    @MainActor
    func importM3U(_ url: URL) async {
        guard let playlistId = playlist.id else { return }
        errorMessage = nil

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            guard !lines.isEmpty else {
                errorMessage = "M3U file is empty or contains no tracks"
                return
            }

            // Resolve lines to track IDs by matching original_path or organized_path
            var matchedIds: [Int64] = []
            for line in lines {
                if let track = try await findTrackByPath(line) {
                    if let id = track.id, !matchedIds.contains(id) {
                        matchedIds.append(id)
                    }
                }
            }

            guard !matchedIds.isEmpty else {
                errorMessage = "No matching tracks found in library for M3U entries"
                return
            }

            let nextPosition = generateNextPosition()
            try await playlistRepository.addTracks(
                playlistId: playlistId,
                trackIds: matchedIds,
                startPosition: nextPosition
            )

            await loadTracks()
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        } catch {
            errorMessage = "Failed to import M3U: \(error.localizedDescription)"
        }
    }

    // MARK: - Filtering

    private func libraryRootSnapshot() async -> URL? {
        guard let configRepository else {
            return nil
        }

        guard let path = try? await configRepository.getLibraryRoot(),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func applyFilter() {
        if searchQuery.isEmpty {
            displayedTracks = tracks
        } else {
            displayedTracks = tracks.filter { $0.matches(searchQuery: searchQuery) }
        }
    }

    // MARK: - Position Helpers

    /// Generate a position string after the last track.
    ///
    /// Uses FractionalIndexer to generate a valid base-62 position after the last track.
    private func generateNextPosition() -> String {
        let lastPos = tracks.last?.playlistPosition
        return FractionalIndexer.positionBetween(left: lastPos, right: nil)
    }

    /// Calculate a fractional position for inserting at a given index.
    ///
    /// Uses FractionalIndexer to compute a base-62 midpoint between surrounding tracks.
    ///
    /// - Parameters:
    ///   - index: Target insertion index
    ///   - excludedIndex: Index of the track being moved (to skip)
    /// - Returns: Position string for the new location
    private func fractionalPosition(insertingAt index: Int, excluding excludedIndex: Int) -> String {
        // Build list without the moving item
        var filteredTracks: [Track] = []
        for i in 0..<tracks.count {
            if i != excludedIndex {
                filteredTracks.append(tracks[i])
            }
        }

        // Insert position between neighbors
        let clampedIndex = min(max(index, 0), filteredTracks.count)

        let leftPos: String?
        let rightPos: String?

        if clampedIndex == 0 {
            // Before first
            leftPos = nil
            rightPos = filteredTracks.first?.playlistPosition
        } else if clampedIndex >= filteredTracks.count {
            // After last
            leftPos = filteredTracks.last?.playlistPosition
            rightPos = nil
        } else {
            // Between two items
            leftPos = filteredTracks[clampedIndex - 1].playlistPosition
            rightPos = filteredTracks[clampedIndex].playlistPosition
        }

        return FractionalIndexer.positionBetween(left: leftPos, right: rightPos)
    }

    // MARK: - Track Lookup

    /// Find a track by file path (searches by filename in original_path or organized_path).
    ///
    /// M3U lines can be relative or absolute paths. We extract the filename
    /// and search the library for a matching track.
    private func findTrackByPath(_ path: String) async throws -> Track? {
        let filename = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()

        guard !filename.isEmpty else { return nil }

        // Use search to find potential matches by filename
        let candidates = try await trackRepository.search(query: filename)
        return candidates.first { track in
            // Match by original_path ending or organized_path ending
            let originalMatch = track.originalPath.lowercased().hasSuffix(
                URL(fileURLWithPath: path).lastPathComponent.lowercased()
            )
            let organizedMatch = track.organizedPath?.lowercased().hasSuffix(
                URL(fileURLWithPath: path).lastPathComponent.lowercased()
            ) ?? false
            return originalMatch || organizedMatch
        }
    }
}
