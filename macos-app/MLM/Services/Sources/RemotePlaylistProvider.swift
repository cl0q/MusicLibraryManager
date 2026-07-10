import Foundation

/// A lightweight, source-agnostic summary of a remote playlist for browsing.
struct RemotePlaylistSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let trackCount: Int
}

/// Abstraction over a streaming source that can list and import playlists.
///
/// Implementations map their native playlist API into `RemotePlaylistSummary`
/// values and persist a chosen playlist into the local library, returning the
/// local playlist ID so the browser can preview + download its tracks.
@MainActor
protocol RemotePlaylistProvider: AnyObject {
    /// Human-readable source name.
    var displayName: String { get }
    /// Which source downloads from this provider should be pinned to.
    var preferredSource: DownloadOrchestrator.PreferredSource { get }
    /// Whether the source is browsed by pasting a playlist URL (YouTube)
    /// rather than listing the user's own playlists (SoundCloud/Spotify).
    var allowsURLImport: Bool { get }
    /// Optional note shown in the UI (e.g. Spotify has no downloadable audio).
    var downloadNote: String? { get }

    /// List the user's playlists for browsing.
    func fetchPlaylists() async throws -> [RemotePlaylistSummary]
    /// Import a listed playlist; returns the local playlist ID.
    func importPlaylist(_ summary: RemotePlaylistSummary) async throws -> Int64?
    /// Import a playlist from a pasted URL; returns the local playlist ID.
    func importPlaylist(fromURL url: String) async throws -> Int64?
}

extension RemotePlaylistProvider {
    var allowsURLImport: Bool { false }
    var downloadNote: String? { nil }
    func fetchPlaylists() async throws -> [RemotePlaylistSummary] { [] }
    func importPlaylist(_ summary: RemotePlaylistSummary) async throws -> Int64? { nil }
    func importPlaylist(fromURL url: String) async throws -> Int64? { nil }
}

// MARK: - SoundCloud

@MainActor
final class SoundCloudPlaylistProvider: RemotePlaylistProvider {
    let displayName = "SoundCloud"
    let preferredSource: DownloadOrchestrator.PreferredSource = .soundcloud

    private let client: SoundCloudClient
    private var cache: [String: SoundCloudPlaylist] = [:]

    init(client: SoundCloudClient) {
        self.client = client
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
        let playlists = try await client.fetchPlaylists()
        cache = Dictionary(uniqueKeysWithValues: playlists.map { (String($0.id), $0) })
        return playlists.map {
            RemotePlaylistSummary(id: String($0.id), title: $0.title, trackCount: $0.trackCount ?? 0)
        }
    }

    func importPlaylist(_ summary: RemotePlaylistSummary) async throws -> Int64? {
        guard let playlist = cache[summary.id] else { return nil }
        return try await client.importPlaylist(playlist)
    }
}

// MARK: - Spotify

@MainActor
final class SpotifyPlaylistProvider: RemotePlaylistProvider {
    let displayName = "Spotify"
    // Spotify provides no downloadable audio — resolve via the search chain.
    let preferredSource: DownloadOrchestrator.PreferredSource = .auto
    var downloadNote: String? {
        "Spotify liefert keine Audiodateien — Titel werden über SoundCloud/YouTube gesucht."
    }

    private let client: SpotifyClient
    private var cache: [String: SpotifyPlaylistSimple] = [:]

    init(client: SpotifyClient) {
        self.client = client
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
        let playlists = try await client.fetchPlaylists()
        cache = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        return playlists.map {
            RemotePlaylistSummary(id: $0.id, title: $0.name, trackCount: $0.tracksInfo?.total ?? 0)
        }
    }

    func importPlaylist(_ summary: RemotePlaylistSummary) async throws -> Int64? {
        guard let playlist = cache[summary.id] else { return nil }
        return try await client.importPlaylist(playlist)
    }
}

// MARK: - YouTube

@MainActor
final class YouTubePlaylistProvider: RemotePlaylistProvider {
    let displayName = "YouTube"
    let preferredSource: DownloadOrchestrator.PreferredSource = .youtube
    let allowsURLImport = true

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

    func importPlaylist(fromURL url: String) async throws -> Int64? {
        let entries = try await downloader.listPlaylist(url: url)
        guard !entries.isEmpty else { return nil }

        let source = try await sourceRepository.upsert(name: "youtube", userId: "local")
        guard let sourceId = source.id else { return nil }

        var orderedIds: [Int64] = []
        for entry in entries {
            if let existing = try? await trackRepository.fetchTrackByExternalId(entry.id, sourceName: "youtube"),
               let id = existing.id {
                orderedIds.append(id)
                continue
            }
            let track = Track(
                artist: entry.uploader ?? "Unknown",
                album: "YouTube",
                title: entry.title,
                format: "youtube",
                originalPath: entry.url
            )
            let inserted = try await trackRepository.insert(track)
            if let id = inserted.id {
                try await sourceRepository.linkTrackToSource(
                    trackId: id,
                    sourceId: sourceId,
                    externalId: entry.id
                )
                orderedIds.append(id)
            }
        }

        let dbPlaylist = try await playlistRepository.findOrCreateSourcePlaylist(
            name: "YouTube Playlist",
            sourceId: sourceId,
            externalId: url
        )
        if let pid = dbPlaylist.id {
            try await playlistRepository.replaceTrackList(playlistId: pid, trackIds: orderedIds)
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        }
        return dbPlaylist.id
    }
}
