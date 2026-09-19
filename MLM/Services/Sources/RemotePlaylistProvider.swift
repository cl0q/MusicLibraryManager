import Foundation

/// How a remote-playlist browser presents its source.
enum RemotePlaylistBrowseMode: Sendable {
    case accountPlaylists          // list the user's playlists only (Spotify)
    case urlOnly                   // paste a URL only (YouTube)
    case accountPlaylistsAndURL    // both at once (SoundCloud)
}

/// A lightweight, source-agnostic summary of a remote playlist for browsing.
struct RemotePlaylistSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let trackCount: Int
    var isPrivate: Bool = false
}

/// Abstraction over a streaming source that can list, preview, and explicitly
/// commit playlists. Fetching a preview must never mutate the local library.
@MainActor
protocol RemotePlaylistProvider: AnyObject {
    /// Human-readable source name.
    var displayName: String { get }
    /// Which source downloads from this provider should be pinned to.
    var preferredSource: DownloadOrchestrator.PreferredSource { get }
    /// How the browser presents this source (account list, URL field, or both).
    var browseMode: RemotePlaylistBrowseMode { get }
    /// Optional note shown in the UI (e.g. Spotify has no downloadable audio).
    var downloadNote: String? { get }

    /// List the user's playlists for browsing.
    func fetchPlaylists() async throws -> [RemotePlaylistSummary]
    /// Fetch a listed playlist's full metadata without writing local records.
    func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview
    /// Fetch a pasted playlist URL's metadata without writing local records.
    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview
    /// Persist exactly the reviewed remote references selected by the user.
    func persist(
        preview: RemotePlaylistPreview,
        selectedTracks: [RemotePlaylistTrack]
    ) async throws -> RemotePlaylistPersistence
}

extension RemotePlaylistProvider {
    var browseMode: RemotePlaylistBrowseMode { .accountPlaylists }
    var downloadNote: String? { nil }
    func fetchPlaylists() async throws -> [RemotePlaylistSummary] { [] }
    func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview {
        throw RemotePlaylistProviderError.previewUnavailable
    }
    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
        throw RemotePlaylistProviderError.previewUnavailable
    }
}

enum RemotePlaylistProviderError: LocalizedError {
    case previewUnavailable
    case playlistUnavailable
    case ytDlpUnavailable
    case notAPlaylistURL(String)

    var errorDescription: String? {
        switch self {
        case .previewUnavailable, .playlistUnavailable:
            return "Video unavailable"
        case .ytDlpUnavailable:
            return "yt-dlp not installed — open Settings"
        case .notAPlaylistURL:
            return "That link is not a SoundCloud playlist"
        }
    }
}

// MARK: - SoundCloud

@MainActor
final class SoundCloudPlaylistProvider: RemotePlaylistProvider {
    let displayName = "SoundCloud"
    let preferredSource: DownloadOrchestrator.PreferredSource = .soundcloud
    let browseMode: RemotePlaylistBrowseMode = .accountPlaylistsAndURL

    private let client: SoundCloudClient
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let playlistRepository: PlaylistRepository
    private var cache: [String: SoundCloudPlaylist] = [:]

    init(
        client: SoundCloudClient,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        playlistRepository: PlaylistRepository
    ) {
        self.client = client
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
        let playlists = try await client.fetchPlaylists()
        cache = Dictionary(uniqueKeysWithValues: playlists.map { (String($0.id), $0) })
        return playlists.map {
            RemotePlaylistSummary(
                id: String($0.id),
                title: $0.title,
                trackCount: $0.trackCount ?? 0,
                isPrivate: $0.isPrivate
            )
        }
    }

    func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview {
        guard let playlist = cache[summary.id] else {
            throw RemotePlaylistProviderError.previewUnavailable
        }
        return try await makePreview(from: playlist)
    }

    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
        let playlist: SoundCloudPlaylist
        do {
            playlist = try await client.resolvePlaylist(url: url)
        } catch SoundCloudClient.SoundCloudError.notAPlaylistURL {
            throw RemotePlaylistProviderError.notAPlaylistURL(url)
        }
        cache[String(playlist.id)] = playlist
        return try await makePreview(from: playlist)
    }

    func persist(
        preview: RemotePlaylistPreview,
        selectedTracks: [RemotePlaylistTrack]
    ) async throws -> RemotePlaylistPersistence {
        let user = try await client.fetchProfile()
        let source = try await sourceRepository.upsert(
            name: "soundcloud",
            userId: String(user.id)
        )
        guard let sourceID = source.id else {
            throw SoundCloudClient.SoundCloudError.noSourceId
        }

        let persistedTracks = try await persistTracks(selectedTracks, sourceID: sourceID)
        let playlist = try await playlistRepository.createSourcePlaylistPreservingExisting(
            name: preview.title,
            sourceId: sourceID,
            externalId: preview.externalID
        )
        guard let playlistID = playlist.id else {
            throw RemotePlaylistProviderError.previewUnavailable
        }
        try await playlistRepository.replaceTrackList(
            playlistId: playlistID,
            trackIds: persistedTracks.compactMap(\.id)
        )
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistID]
        )
        return RemotePlaylistPersistence(playlistID: playlistID, tracks: persistedTracks)
    }

    private func makePreview(from playlist: SoundCloudPlaylist) async throws -> RemotePlaylistPreview {
        let sourceTracks: [SoundCloudTrack]
        if let embeddedTracks = playlist.tracks, !embeddedTracks.isEmpty {
            sourceTracks = embeddedTracks
        } else {
            sourceTracks = try await client.fetchPlaylistTracks(playlistId: playlist.id)
        }
        guard !sourceTracks.isEmpty else {
            throw RemotePlaylistProviderError.playlistUnavailable
        }
        return RemotePlaylistPreview(
            sourceName: displayName,
            externalID: String(playlist.id),
            title: playlist.title,
            tracks: sourceTracks.map { track in
                RemotePlaylistTrack(
                    externalID: String(track.id),
                    title: track.title,
                    artist: track.user?.username ?? "Unknown",
                    album: "SoundCloud",
                    durationSeconds: track.duration.map { $0 / 1000 },
                    format: "soundcloud",
                    originalPath: track.permalinkUrl ?? "soundcloud://\(track.id)"
                )
            }
        )
    }

    private func persistTracks(
        _ selectedTracks: [RemotePlaylistTrack],
        sourceID: Int64
    ) async throws -> [Track] {
        var persistedTracks: [Track] = []
        persistedTracks.reserveCapacity(selectedTracks.count)
        for remoteTrack in selectedTracks {
            if let existing = try await trackRepository.fetchTrackByExternalId(
                remoteTrack.externalID,
                sourceName: "soundcloud"
            ) {
                persistedTracks.append(existing)
                continue
            }
            let inserted = try await trackRepository.insert(remoteTrack.unresolvedTrack())
            if let trackID = inserted.id {
                try await sourceRepository.linkTrackToSource(
                    trackId: trackID,
                    sourceId: sourceID,
                    externalId: remoteTrack.externalID
                )
            }
            persistedTracks.append(inserted)
        }
        return persistedTracks
    }
}

// MARK: - Spotify

@MainActor
final class SpotifyPlaylistProvider: RemotePlaylistProvider {
    let displayName = "Spotify"
    // Spotify provides no downloadable audio — resolve via the search chain.
    let preferredSource: DownloadOrchestrator.PreferredSource = .auto
    var downloadNote: String? {
        "Spotify does not provide audio files — tracks are found through SoundCloud or YouTube."
    }

    private let client: SpotifyClient
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let playlistRepository: PlaylistRepository
    private var cache: [String: SpotifyPlaylistSimple] = [:]

    init(
        client: SpotifyClient,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        playlistRepository: PlaylistRepository
    ) {
        self.client = client
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
        let playlists = try await client.fetchPlaylists()
        cache = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        return playlists.map {
            RemotePlaylistSummary(id: $0.id, title: $0.name, trackCount: $0.tracksInfo?.total ?? 0)
        }
    }

    func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview {
        guard let playlist = cache[summary.id] else {
            throw RemotePlaylistProviderError.previewUnavailable
        }
        let sourceTracks = try await client.fetchPlaylistTracks(playlistId: playlist.id)
        guard !sourceTracks.isEmpty else {
            throw RemotePlaylistProviderError.playlistUnavailable
        }
        return RemotePlaylistPreview(
            sourceName: displayName,
            externalID: playlist.id,
            title: playlist.name,
            tracks: sourceTracks.map { track in
                RemotePlaylistTrack(
                    externalID: track.id,
                    title: track.name,
                    artist: track.artists.first?.name ?? "Unknown",
                    album: track.album?.name ?? "Unknown",
                    durationSeconds: track.durationMs / 1000,
                    format: "spotify",
                    originalPath: "spotify://track/\(track.id)"
                )
            }
        )
    }

    func persist(
        preview: RemotePlaylistPreview,
        selectedTracks: [RemotePlaylistTrack]
    ) async throws -> RemotePlaylistPersistence {
        let profile = try await client.fetchProfile()
        let source = try await sourceRepository.upsert(name: "spotify", userId: profile.id)
        guard let sourceID = source.id else {
            throw RemotePlaylistProviderError.previewUnavailable
        }

        var persistedTracks: [Track] = []
        persistedTracks.reserveCapacity(selectedTracks.count)
        for remoteTrack in selectedTracks {
            if let existing = try await trackRepository.fetchTrackByExternalId(
                remoteTrack.externalID,
                sourceName: "spotify"
            ) {
                persistedTracks.append(existing)
                continue
            }
            let inserted = try await trackRepository.insert(remoteTrack.unresolvedTrack())
            if let trackID = inserted.id {
                try await sourceRepository.linkTrackToSource(
                    trackId: trackID,
                    sourceId: sourceID,
                    externalId: remoteTrack.externalID
                )
            }
            persistedTracks.append(inserted)
        }

        let playlist = try await playlistRepository.findOrCreateSourcePlaylist(
            name: preview.title,
            sourceId: sourceID,
            externalId: preview.externalID
        )
        guard let playlistID = playlist.id else {
            throw RemotePlaylistProviderError.previewUnavailable
        }
        try await playlistRepository.replaceTrackList(
            playlistId: playlistID,
            trackIds: persistedTracks.compactMap(\.id)
        )
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistID]
        )
        return RemotePlaylistPersistence(playlistID: playlistID, tracks: persistedTracks)
    }
}

// MARK: - YouTube

@MainActor
final class YouTubePlaylistProvider: RemotePlaylistProvider {
    let displayName = "YouTube"
    let preferredSource: DownloadOrchestrator.PreferredSource = .youtube
    let browseMode: RemotePlaylistBrowseMode = .urlOnly

    private let downloader: YouTubeDownloader
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let playlistRepository: PlaylistRepository

    init(
        downloader: YouTubeDownloader,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        playlistRepository: PlaylistRepository
    ) {
        self.downloader = downloader
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
    }

    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
        guard downloader.isAvailable else {
            throw RemotePlaylistProviderError.ytDlpUnavailable
        }
        let listing = try await downloader.listPlaylist(url: url)
        let entries = listing.entries
        guard !entries.isEmpty else {
            throw RemotePlaylistProviderError.playlistUnavailable
        }

        // Prefer the real playlist title; fall back to a URL-derived name so
        // the browser never shows a generic "YouTube Playlist" for two
        // different playlists (which would also collide on name+category).
        let playlistName = listing.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (playlistName?.isEmpty == false)
            ? playlistName!
            : "YouTube Playlist \(url.suffix(11))"

        return RemotePlaylistPreview(
            sourceName: displayName,
            externalID: url,
            title: resolvedName,
            tracks: entries.map { entry in
                RemotePlaylistTrack(
                    externalID: entry.id,
                    title: entry.title,
                    artist: entry.uploader ?? "Unknown",
                    album: "YouTube",
                    durationSeconds: entry.durationSeconds,
                    format: "youtube",
                    originalPath: entry.url
                )
            }
        )
    }

    func persist(
        preview: RemotePlaylistPreview,
        selectedTracks: [RemotePlaylistTrack]
    ) async throws -> RemotePlaylistPersistence {
        let source = try await sourceRepository.upsert(name: "youtube", userId: "local")
        guard let sourceID = source.id else {
            throw RemotePlaylistProviderError.previewUnavailable
        }

        var persistedTracks: [Track] = []
        persistedTracks.reserveCapacity(selectedTracks.count)
        for remoteTrack in selectedTracks {
            if let existing = try await trackRepository.fetchTrackByExternalId(
                remoteTrack.externalID,
                sourceName: "youtube"
            ) {
                persistedTracks.append(existing)
                continue
            }
            let inserted = try await trackRepository.insert(remoteTrack.unresolvedTrack())
            if let trackID = inserted.id {
                try await sourceRepository.linkTrackToSource(
                    trackId: trackID,
                    sourceId: sourceID,
                    externalId: remoteTrack.externalID
                )
            }
            persistedTracks.append(inserted)
        }

        let playlist = try await playlistRepository.findOrCreateSourcePlaylist(
            name: preview.title,
            sourceId: sourceID,
            externalId: preview.externalID
        )
        guard let playlistID = playlist.id else {
            throw RemotePlaylistProviderError.previewUnavailable
        }
        try await playlistRepository.replaceTrackList(
            playlistId: playlistID,
            trackIds: persistedTracks.compactMap(\.id)
        )
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistID]
        )
        return RemotePlaylistPersistence(playlistID: playlistID, tracks: persistedTracks)
    }
}
