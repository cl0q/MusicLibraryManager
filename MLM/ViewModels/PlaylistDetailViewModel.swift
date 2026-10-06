import Foundation
import GRDB

/// The playlist page's data (V-PLD): the playlist row, its tracks in playlist order with their
/// persisted availability (never a disk probe, UC-TABLE-20), when each was added to the
/// playlist (UC-TABLE-19), its source, and the SQL aggregate for the facts line and the status
/// sentence (UC-TABLE-21). Refresh from ‹Source›, Link Source… and the M3U import live in
/// `PlaylistActions` / `PlaylistRefreshService` / the sheets (W3-PL).
///
/// Reorder uses fractional positions (string-based) — no renumbering.
@Observable
final class PlaylistDetailViewModel {

    // MARK: - State

    /// The playlist being viewed.
    private(set) var playlist: Playlist

    /// Tracks in the playlist, ordered by position.
    private(set) var tracks: [Track] = []

    /// One availability snapshot shared by the header and the table, rebuilt after each load.
    private(set) var availabilityByTrackID: [Int64: TrackAvailability] = [:]

    /// When each track was added to this playlist (`playlist_tracks.added_at`, UC-TABLE-19).
    private(set) var addedAtByTrackID: [Int64: String] = [:]

    /// The authoritative external source for a linked playlist.
    private(set) var source: Source?

    /// Counts and total duration from one SQL aggregate (facts line, status, scope counts).
    private(set) var summary: PlaylistSummary

    /// The first load is running (placeholder rows only then, UC-TABLE-09).
    private(set) var isLoading = false
    /// The first load has finished.
    private(set) var hasLoaded = false

    /// The last load failed; the page says so in its header (UC-SHEET-21).
    private(set) var errorMessage: String?

    /// The playlist no longer exists (deleted elsewhere, creation undone — V-PLD.N03).
    private(set) var isMissing = false

    /// The toolbar field's filter for this playlist — text and tokens, in memory (W2-I).
    var searchFilter = SearchFilter() {
        didSet {
            guard oldValue != searchFilter else { return }
            applyFilter()
        }
    }

    /// The filter's text alone (older callers and tests).
    var searchQuery: String {
        get { searchFilter.text }
        set { searchFilter = SearchFilter(text: newValue, tokens: searchFilter.tokens) }
    }

    /// Filtered tracks based on search query.
    private(set) var displayedTracks: [Track] = []

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

    /// `SoundCloud`, `YouTube`, … of a linked playlist.
    var sourceDisplayName: String? {
        source?.playlistSourceIdentity.displayName
    }

    func availability(for track: Track) -> TrackAvailability {
        guard let trackID = track.id else { return track.availability() }
        return availabilityByTrackID[trackID] ?? track.availability()
    }

    /// Selected track IDs (mirrored from the table).
    var selectedTrackIDs: Set<Int64> = []

    // MARK: - Dependencies

    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
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
        self.tableCache = tableCache
        self.summary = PlaylistSummary(playlistID: playlist.id ?? -1)
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
        self.tableCache = nil
        self.tracks = preloadedTracks
        self.displayedTracks = preloadedTracks
        self.availabilityByTrackID = availabilityByTrackID
        self.summary = PlaylistSummary(playlistID: playlist.id ?? -1, totalTracks: preloadedTracks.count)
        self.hasLoaded = true
    }

    // MARK: - Load

    /// Load all tracks for this playlist, ordered by position. A cache hit renders at once.
    @MainActor
    func loadTracks() async {
        await loadTracksInternal(useCache: true)
    }

    /// Refresh tracks (after external changes), bypassing the cache; rows update in place.
    @MainActor
    func refresh() async {
        await loadTracksInternal(useCache: false)
    }

    @MainActor
    private func loadTracksInternal(useCache: Bool) async {
        guard let playlistId = playlist.id else { return }

        if useCache, let cached = tableCache?.entry(for: playlistId) {
            playlist = cached.playlist
            source = cached.source
            tracks = cached.tracks
            availabilityByTrackID = cached.availabilityByTrackID
            applyFilter()
            hasLoaded = true
            summary = (try? await playlistRepository.fetchSummary(playlistID: playlistId)) ?? summary
            return
        }

        if !hasLoaded { isLoading = true }
        defer { isLoading = false }

        do {
            guard let freshPlaylist = try await playlistRepository.fetch(id: playlistId) else {
                isMissing = true
                return
            }
            playlist = freshPlaylist
            isMissing = false
            source = try await playlist.sourceId.asyncMap { try await sourceRepository.fetch(id: $0) } ?? nil

            let loadedTracks = try await playlistRepository.fetchTracks(playlistId: playlistId)
            let availability = TrackAvailability.byTrackID(loadedTracks)
            addedAtByTrackID = (try? await trackRepository.fetchPlaylistAddedDates(playlistId: playlistId)) ?? [:]
            summary = try await playlistRepository.fetchSummary(playlistID: playlistId)

            tracks = loadedTracks
            availabilityByTrackID = availability
            applyFilter()
            errorMessage = nil
            hasLoaded = true

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
            errorMessage = "The library database didn’t answer. Your music is not affected."
        }
    }

    /// Persisted availability changed (a file check, a download): reload the rows in place.
    @MainActor
    func refreshAvailabilitySnapshot() async {
        await refresh()
    }

    // MARK: - Reorder (Drag & Drop)

    /// Place one or more tracks at a given insertion index (an index into `tracks`).
    ///
    /// Not undoable: drops on the playlist table go through `ShellEdits.placeTracks` (W2-H),
    /// one undo step with exact positions; this stays for callers without an undo center.
    @MainActor
    func placeTracks(_ trackIDs: [Int64], at insertionIndex: Int) async {
        guard let playlistId = playlist.id, !trackIDs.isEmpty else { return }

        var seen = Set<Int64>()
        let uniqueIDs = trackIDs.filter { seen.insert($0).inserted }
        let memberIDSet = Set(tracks.compactMap(\.id)).intersection(uniqueIDs)
        let nonMemberIDs = uniqueIDs.filter { !memberIDSet.contains($0) }

        var fetchedNonMembers: [Track] = []
        if !nonMemberIDs.isEmpty {
            do {
                let fetched = try await trackRepository.fetchTracks(ids: Set(nonMemberIDs))
                let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { track in track.id.map { ($0, track) } })
                fetchedNonMembers = nonMemberIDs.compactMap { byID[$0] }
            } catch {
                await refresh()
                return
            }
        }

        let remaining = tracks.filter { !memberIDSet.contains($0.id ?? -1) }
        let clampedInput = min(max(insertionIndex, 0), tracks.count)
        let insertAt = min(
            tracks.prefix(clampedInput).filter { !memberIDSet.contains($0.id ?? -1) }.count,
            remaining.count
        )
        let left = insertAt > 0 ? remaining[insertAt - 1].playlistPosition : nil
        let right = insertAt < remaining.count ? remaining[insertAt].playlistPosition : nil

        let memberTrackByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in track.id.map { ($0, track) } })
        let nonMemberByID = Dictionary(uniqueKeysWithValues: fetchedNonMembers.compactMap { track in track.id.map { ($0, track) } })
        var resolvedTracks = uniqueIDs.compactMap { memberTrackByID[$0] ?? nonMemberByID[$0] }

        var placements: [(trackId: Int64, position: String)] = []
        var previousPosition: String? = left
        for track in resolvedTracks {
            guard let id = track.id else { continue }
            let pos = PlaylistPlacement.strictlyBetween(previousPosition, right)
            placements.append((trackId: id, position: pos))
            previousPosition = pos
        }
        guard !placements.isEmpty else { return }

        do {
            try await playlistRepository.placeTracks(playlistId: playlistId, placements: placements)
        } catch {
            await refresh()
            return
        }

        let positionByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.trackId, $0.position) })
        for i in resolvedTracks.indices {
            if let id = resolvedTracks[i].id, let pos = positionByID[id] {
                resolvedTracks[i].playlistPosition = pos
            }
        }
        var updated = remaining
        updated.insert(contentsOf: resolvedTracks, at: insertAt)
        tracks = updated
        applyFilter()

        if !nonMemberIDs.isEmpty {
            await refreshAvailabilitySnapshot()
        }
        tableCache?.store(PlaylistTableCache.Entry(
            playlistId: playlistId,
            playlistName: playlist.name,
            playlist: playlist,
            source: source,
            tracks: tracks,
            availabilityByTrackID: availabilityByTrackID,
            fetchedAt: Date()
        ))
        NotificationCenter.default.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": playlistId])
    }

    // MARK: - Filtering

    private func applyFilter() {
        if searchFilter.isEmpty {
            displayedTracks = tracks
        } else {
            // Every row here is in a playlist (`is: in no playlist` matches none).
            displayedTracks = tracks.filter { searchFilter.matches($0, isInAnyPlaylist: { _ in true }) }
        }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
