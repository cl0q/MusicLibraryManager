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
        didSet {
            guard oldValue != searchQuery else { return }
            applyFilter()
        }
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
    private let tableCache: PlaylistTableCache?

    // MARK: - Init

    init(
        playlist: Playlist,
        playlistRepository: PlaylistRepository,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        configRepository: ConfigRepository? = nil,
        tableCache: PlaylistTableCache? = nil
    ) {
        self.playlist = playlist
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.configRepository = configRepository
        self.tableCache = tableCache
    }

    /// Deterministic construction path for static UI fixtures. It preloads
    /// table state without starting the normal repository loading task.
    init(
        playlist: Playlist,
        playlistRepository: PlaylistRepository,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        preloadedTracks: [Track],
        availabilityByTrackID: [Int64: TrackAvailability] = [:]
    ) {
        self.playlist = playlist
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.configRepository = nil
        self.tableCache = nil
        self.tracks = preloadedTracks
        self.displayedTracks = preloadedTracks
        self.availabilityByTrackID = availabilityByTrackID
    }

    // MARK: - Load

    /// Load all tracks for this playlist, ordered by position.
    ///
    /// Cache integration: on a cache hit the rows render instantly without
    /// setting `isLoading`. On a miss (or after `refresh()`) the SQL fetch
    /// runs and the result is stored for next time.
    @MainActor
    func loadTracks() async {
        await loadTracksInternal(useCache: true)
    }

    /// Refresh tracks (after external changes). Bypasses the cache so the
    /// latest data is always fetched from SQLite.
    @MainActor
    func refresh() async {
        await loadTracksInternal(useCache: false)
    }

    @MainActor
    private func loadTracksInternal(useCache: Bool) async {
        guard let playlistId = playlist.id else { return }

        // Cache hit → populate instantly, no spinner.
        if useCache, let cached = tableCache?.entry(for: playlistId) {
            playlist = cached.playlist
            source = cached.source
            tracks = cached.tracks
            availabilityByTrackID = cached.availabilityByTrackID
            applyFilter()
            return
        }

        // Only show the loading indicator when there are no rows yet —
        // subsequent refreshes (notifications, cover revalidation) update
        // in place so the table never blanks.
        let showLoading = tracks.isEmpty
        if showLoading { isLoading = true }
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
                fileExists: { url in
                    return FileManager.default.fileExists(atPath: url.path)
                }
            )

            tracks = loadedTracks
            availabilityByTrackID = availability
            applyFilter()

            // Store in LRU cache for instant re-entry.
            tableCache?.store(PlaylistTableCache.Entry(
                playlistId: playlistId,
                playlistName: playlist.name,
                playlist: playlist,
                source: source,
                tracks: loadedTracks,
                availabilityByTrackID: availability,
                fetchedAt: Date()
            ))
        } catch {
            errorMessage = "Failed to load tracks: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Revalidates the existing rows after the configured library root changes
    /// without issuing another playlist-track query.
    @MainActor
    func refreshAvailabilitySnapshot() async {
        let libraryRoot = await libraryRootSnapshot()
        availabilityByTrackID = TrackPresentationAvailability.map(
            tracks: tracks,
            libraryRoot: libraryRoot,
            fileExists: { url in
                return FileManager.default.fileExists(atPath: url.path)
            }
        )
    }

    // MARK: - Source Synchronization

    /// Whether this playlist supports synchronization from an external source.
    /// Covers liked playlists (SoundCloud, Spotify, Apple Music) and any
    /// remote playlist with an externalId that can be re-fetched (e.g. YouTube
    /// playlists where externalId is the playlist URL).
    var canSync: Bool {
        if playlist.isLiked == 1 && playlist.sourceId != nil { return true }
        // Remote playlists with a URL-based externalId (YouTube)
        if playlist.sourceId != nil,
           let extId = playlist.externalId,
           extId.hasPrefix("http://") || extId.hasPrefix("https://") {
            return true
        }
        return false
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
                // Check if this is a YouTube playlist (source name = "youtube")
                if activeSource.name == "youtube", let externalId = playlist.externalId {
                    newTracks = try await syncYouTubePlaylist(url: externalId, sourceId: activeSource.id!)
                } else {
                    throw NSError(domain: "PlaylistDetailViewModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported source sync"])
                }
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

    /// Sync a YouTube playlist by re-fetching its entries, diffing against
    /// local tracks, inserting new ones, and returning the count of new tracks.
    private func syncYouTubePlaylist(url: String, sourceId: Int64) async throws -> Int {
        let container = DependencyContainer.shared
        guard let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository,
              let plRepo = container.playlistRepository,
              let playlistId = playlist.id else {
            throw NSError(domain: "PlaylistDetailViewModel", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Missing dependencies for YouTube sync"])
        }

        let downloader = YouTubeDownloader()
        guard downloader.isAvailable else {
            throw NSError(domain: "PlaylistDetailViewModel", code: 503,
                          userInfo: [NSLocalizedDescriptionKey: "yt-dlp not installed"])
        }

        // 1. Fetch remote playlist entries
        let listing = try await downloader.listPlaylist(url: url)
        guard !listing.entries.isEmpty else { return 0 }

        // 2. For each remote entry, check if it already exists locally by external ID
        var newEntries: [(id: String, title: String, uploader: String?, url: String)] = []
        for entry in listing.entries {
            let existing = try await trackRepo.fetchTrackByExternalId(entry.id, sourceName: "youtube")
            if existing == nil {
                newEntries.append((id: entry.id, title: entry.title, uploader: entry.uploader, url: entry.url))
            }
        }
        guard !newEntries.isEmpty else { return 0 }

        // 3. Insert new tracks and link to source
        var insertedIds: [Int64] = []
        for entry in newEntries {
            let track = Track(
                artist: entry.uploader ?? "Unknown",
                album: "YouTube",
                title: entry.title,
                format: "youtube",
                originalPath: entry.url
            )
            let inserted = try await trackRepo.insert(track)
            guard let trackId = inserted.id else { continue }
            try await sourceRepo.linkTrackToSource(
                trackId: trackId,
                sourceId: sourceId,
                externalId: entry.id
            )
            insertedIds.append(trackId)
        }

        // 4. Append new tracks to the playlist
        if !insertedIds.isEmpty {
            let nextPosition = generateNextPosition()
            try await plRepo.addTracks(
                playlistId: playlistId,
                trackIds: insertedIds,
                startPosition: nextPosition
            )
        }

        return newEntries.count
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

    /// Place one or more tracks at a given insertion index.
    ///
    /// Handles internal reorders, external inserts, and mixed drops uniformly.
    /// The `trackIDs` end up at `insertionIndex` (an index into the full
    /// `tracks` array meaning "insert before the track currently there"),
    /// in the order given.
    ///
    /// On success the in-memory state is updated optimistically — no
    /// `loadTracks()` round-trip, so the UI never flickers.
    @MainActor
    func placeTracks(_ trackIDs: [Int64], at insertionIndex: Int) async {
        guard let playlistId = playlist.id else { return }
        guard !trackIDs.isEmpty else { return }

        var seen = Set<Int64>()
        let uniqueIDs = trackIDs.filter { seen.insert($0).inserted }

        let memberIDSet = Set(tracks.compactMap(\.id)).intersection(uniqueIDs)
        let nonMemberIDs = uniqueIDs.filter { !memberIDSet.contains($0) }

        // Materialise non-member tracks from the library so we can assign
        // them positions and update the in-memory array.
        var fetchedNonMembers: [Track] = []
        if !nonMemberIDs.isEmpty {
            do {
                let fetched = try await trackRepository.fetchTracks(ids: Set(nonMemberIDs))
                // Reorder to match the drag order.
                let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id!, $0) })
                fetchedNonMembers = nonMemberIDs.compactMap { byID[$0] }
            } catch {
                errorMessage = "Failed to reorder: \(error.localizedDescription)"
                await refresh()
                return
            }
        }

        // Remove members from the working array; non-members were never in it.
        let remaining = tracks.filter { !memberIDSet.contains($0.id ?? -1) }

        // Compute the insert point inside `remaining`. The raw `insertionIndex`
        // is an index into the original `tracks` array, so count how many of
        // the tracks before that index are NOT being removed.
        let clampedInput = min(max(insertionIndex, 0), tracks.count)
        let insertAt = min(
            tracks.prefix(clampedInput).filter { !memberIDSet.contains($0.id ?? -1) }.count,
            remaining.count
        )

        let left = insertAt > 0 ? remaining[insertAt - 1].playlistPosition : nil
        let right = insertAt < remaining.count ? remaining[insertAt].playlistPosition : nil

        // Assign sequential positions so the group stays bounded between
        // left and right.
        var placements: [(trackId: Int64, position: String)] = []
        var previousPosition: String? = left
        // Resolved in drag order so a multi-row drop keeps the order the user dragged.
        let memberTrackByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in track.id.map { ($0, track) } })
        let nonMemberByID = Dictionary(uniqueKeysWithValues: fetchedNonMembers.compactMap { track in track.id.map { ($0, track) } })
        var resolvedTracks: [Track] = []
        for id in uniqueIDs {
            if let t = memberTrackByID[id] ?? nonMemberByID[id] {
                resolvedTracks.append(t)
            }
        }

        for track in resolvedTracks {
            guard let id = track.id else { continue }
            let pos = FractionalIndexer.positionBetween(left: previousPosition, right: right)
            placements.append((trackId: id, position: pos))
            previousPosition = pos
        }

        guard !placements.isEmpty else { return }

        do {
            try await playlistRepository.placeTracks(playlistId: playlistId, placements: placements)
        } catch {
            errorMessage = "Failed to reorder: \(error.localizedDescription)"
            await refresh()
            return
        }

        // Assign positions on the in-memory tracks.
        let positionByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.trackId, $0.position) })
        for i in resolvedTracks.indices {
            if let id = resolvedTracks[i].id, let pos = positionByID[id] {
                resolvedTracks[i].playlistPosition = pos
            }
        }

        // Optimistic in-memory update — no loadTracks() call.
        var updated = remaining
        updated.insert(contentsOf: resolvedTracks, at: insertAt)
        tracks = updated
        applyFilter()

        if !nonMemberIDs.isEmpty {
            await refreshAvailabilitySnapshot()
        }

        // Refresh the table cache so a later hit is truthful.
        if let cache = tableCache {
            cache.store(PlaylistTableCache.Entry(
                playlistId: playlistId,
                playlistName: playlist.name,
                playlist: playlist,
                source: source,
                tracks: tracks,
                availabilityByTrackID: availabilityByTrackID,
                fetchedAt: Date()
            ))
        }

        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistId]
        )
    }

    // MARK: - M3U Import

    /// Set an error message (used by the view when ingest preview fails).
    @MainActor
    func setErrorMessage(_ message: String) {
        errorMessage = message
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

    // MARK: - Source Linking

    /// Phase of the "Link Source" sheet: idle until the user hits Check,
    /// checking while the remote playlist is fetched, failed with a
    /// user-facing message, or validated with the remote title/count/diff.
    enum LinkCheckPhase: Equatable {
        case idle
        case checking
        case failed(String)
        case validated(remoteTitle: String, remoteTrackCount: Int, diff: PlaylistLinkDiff)
    }

    /// Current phase of the link-source sheet.
    private(set) var linkCheckPhase: LinkCheckPhase = .idle

    /// Preview and provider captured at `.validated` so `commitPendingLink`
    /// can write the source row without re-fetching.
    private var pendingLinkPreview: RemotePlaylistPreview?
    private var pendingLinkProvider: (any RemotePlaylistProvider)?

    /// Linking only makes sense for regular (non-liked, non-smart) playlists.
    /// Liked playlists already have a fixed source identity; smart playlists
    /// have no upstream at all.
    var canLinkSource: Bool {
        playlist.isLiked == 0 && playlist.isSmart == 0
    }

    /// The URL to prefill the link sheet with, derived from `externalId`
    /// when it looks like a URL. Returns nil otherwise.
    var linkedSourceURL: String? {
        guard let extId = playlist.externalId else { return nil }
        if extId.hasPrefix("http://") || extId.hasPrefix("https://") {
            return extId
        }
        return nil
    }

    /// Validate a pasted playlist URL without writing anything to the library.
    ///
    /// Sets `linkCheckPhase` through its lifecycle: `.checking` → either
    /// `.failed(message)` or `.validated(title, count, diff)`. On success the
    /// preview and provider are stashed in `pendingLinkPreview`/
    /// `pendingLinkProvider` for `commitPendingLink()` to consume.
    @MainActor
    func checkPlaylistLink(url: String) async {
        linkCheckPhase = .checking
        pendingLinkPreview = nil
        pendingLinkProvider = nil

        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            linkCheckPhase = .failed("Enter a playlist URL.")
            return
        }
        let normalized = URLDetector.normalize(trimmed)

        let provider: any RemotePlaylistProvider
        switch URLDetector.classify(trimmed) {
        case .youtubePlaylist:
            provider = YouTubePlaylistProvider(
                downloader: YouTubeDownloader(),
                trackRepository: trackRepository,
                sourceRepository: sourceRepository,
                playlistRepository: playlistRepository
            )
        case .soundcloudPlaylist:
            let container = DependencyContainer.shared
            guard let tokenStorage = container.tokenStorage,
                  let oauthManager = container.oauthManager else {
                linkCheckPhase = .failed("SoundCloud is not connected — sign in in Settings first.")
                return
            }
            let client = SoundCloudClient(
                tokenStorage: tokenStorage,
                oauthManager: oauthManager,
                trackRepository: trackRepository,
                sourceRepository: sourceRepository,
                playlistRepository: playlistRepository
            )
            provider = SoundCloudPlaylistProvider(
                client: client,
                trackRepository: trackRepository,
                sourceRepository: sourceRepository,
                playlistRepository: playlistRepository
            )
        default:
            linkCheckPhase = .failed("That doesn't look like a YouTube or SoundCloud playlist link.")
            return
        }

        let preview: RemotePlaylistPreview
        do {
            preview = try await provider.fetchPreview(fromURL: normalized)
        } catch let error as RemotePlaylistProviderError {
            linkCheckPhase = .failed(error.errorDescription ?? "Could not load that playlist.")
            return
        } catch {
            linkCheckPhase = .failed(error.localizedDescription)
            return
        }

        let remoteEntries = preview.tracks.map {
            PlaylistDifferRemoteEntry(
                externalID: $0.externalID,
                title: $0.title,
                artist: $0.artist,
                originalPath: $0.originalPath
            )
        }

        let ids = Set(tracks.compactMap { $0.id })
        let externalIDsByTrack: [Int64: [String]]
        do {
            externalIDsByTrack = try await sourceRepository.fetchExternalIDs(trackIds: ids)
        } catch {
            externalIDsByTrack = [:]
        }
        let localEntries = tracks.map { track in
            PlaylistDifferLocalTrack(
                id: track.id ?? -1,
                title: track.title,
                artist: track.artist,
                originalPath: track.originalPath,
                externalIDs: externalIDsByTrack[track.id ?? -1] ?? []
            )
        }

        let diff = PlaylistLinkDiffComputer.compute(remote: remoteEntries, local: localEntries)
        pendingLinkPreview = preview
        pendingLinkProvider = provider
        linkCheckPhase = .validated(
            remoteTitle: preview.title,
            remoteTrackCount: preview.tracks.count,
            diff: diff
        )
    }

    /// Commit the validated link: write `source_id` + `external_id` onto the
    /// playlist row. Does NOT import tracks, does NOT call `persist()`.
    ///
    /// Returns true on success (caller dismisses the sheet and shows a
    /// success alert); false on failure (caller stays on the sheet with
    /// `linkCheckPhase` set to `.failed`).
    @MainActor
    func commitPendingLink() async -> Bool {
        guard let preview = pendingLinkPreview,
              let provider = pendingLinkProvider,
              let playlistId = playlist.id else {
            linkCheckPhase = .failed("Nothing to commit.")
            return false
        }

        do {
            let sourceRow = try await provider.sourceRowForLinking()
            guard let sourceId = sourceRow.id else {
                throw RemotePlaylistProviderError.previewUnavailable
            }
            try await playlistRepository.updateSourceLink(
                id: playlistId,
                sourceId: sourceId,
                externalId: preview.externalID
            )
            errorMessage = nil
            linkCheckPhase = .idle
            pendingLinkPreview = nil
            pendingLinkProvider = nil
            await refresh()
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
            return true
        } catch {
            linkCheckPhase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Reset the link-check state (user cancelled or edited the URL).
    func cancelLinkCheck() {
        linkCheckPhase = .idle
        pendingLinkPreview = nil
        pendingLinkProvider = nil
    }

}
