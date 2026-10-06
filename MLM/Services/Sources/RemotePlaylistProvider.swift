import Foundation

/// How a remote-playlist browser presents its source.
enum RemotePlaylistBrowseMode: Sendable {
    case accountPlaylists          // list the user's playlists (Spotify)
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

/// Abstraction over a streaming source that can list and preview playlists. Fetching never
/// writes to the library; the commit is `PlaylistImporter` (W3-ADD).
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

    /// Return (or create) the `sources` row this provider's tracks and linked playlists belong
    /// to (YouTube: user `local`; SoundCloud / Spotify: the signed-in account).
    func sourceRowForLinking() async throws -> Source
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
    func sourceRowForLinking() async throws -> Source {
        throw RemotePlaylistProviderError.previewUnavailable
    }
}

enum RemotePlaylistProviderError: LocalizedError, Equatable {
    case previewUnavailable
    case playlistUnavailable
    case ytDlpUnavailable
    case notAPlaylistURL(String)
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .previewUnavailable, .playlistUnavailable:
            return "This playlist is private or no longer available"
        case .ytDlpUnavailable:
            return "yt-dlp not found"
        case .notAPlaylistURL:
            return "That link isn’t a playlist"
        case .emptyPlaylist:
            return "This playlist has no tracks"
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
    private let sourceRepository: SourceRepository
    private var cache: [String: SoundCloudPlaylist] = [:]

    /// `trackRepository` / `playlistRepository` are accepted for existing callers; the commit
    /// is `PlaylistImporter`'s.
    init(client: SoundCloudClient, trackRepository: TrackRepository? = nil, sourceRepository: SourceRepository,
         playlistRepository: PlaylistRepository? = nil) {
        self.client = client
        self.sourceRepository = sourceRepository
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
        let playlists = try await client.fetchPlaylists()
        cache = Dictionary(playlists.map { (String($0.id), $0) }, uniquingKeysWith: { first, _ in first })
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

    /// SoundCloud's source row is keyed by the signed-in user's numeric ID.
    func sourceRowForLinking() async throws -> Source {
        let user = try await client.fetchProfile()
        return try await sourceRepository.upsert(name: "soundcloud", userId: String(user.id))
    }

    private func makePreview(from playlist: SoundCloudPlaylist) async throws -> RemotePlaylistPreview {
        let sourceTracks: [SoundCloudTrack]
        if let embeddedTracks = playlist.tracks, !embeddedTracks.isEmpty {
            sourceTracks = embeddedTracks
        } else {
            sourceTracks = try await client.fetchPlaylistTracks(playlistId: playlist.id)
        }
        guard !sourceTracks.isEmpty else {
            throw RemotePlaylistProviderError.emptyPlaylist
        }
        return RemotePlaylistPreview(
            sourceName: displayName,
            externalID: String(playlist.id),
            title: playlist.title,
            tracks: sourceTracks.map { track in
                RemotePlaylistTrack(
                    externalID: String(track.id),
                    title: track.title,
                    artist: track.user?.username ?? "",
                    // SoundCloud has no albums; the source is the track's link, never a tag (DEC-013).
                    album: "",
                    durationSeconds: track.duration.map { $0 / 1000 },
                    format: "soundcloud",
                    originalPath: track.permalinkUrl ?? "soundcloud://\(track.id)"
                )
            }
        )
    }
}

// MARK: - Spotify

@MainActor
final class SpotifyPlaylistProvider: RemotePlaylistProvider {
    let displayName = "Spotify"
    // Spotify provides no downloadable audio — resolve via the search chain.
    let preferredSource: DownloadOrchestrator.PreferredSource = .auto
    var downloadNote: String? {
        "Spotify doesn’t provide audio files. MLM finds each track on SoundCloud or YouTube."
    }

    private let client: SpotifyClient
    private let sourceRepository: SourceRepository
    private var cache: [String: SpotifyPlaylistSimple] = [:]

    init(client: SpotifyClient, trackRepository: TrackRepository? = nil, sourceRepository: SourceRepository,
         playlistRepository: PlaylistRepository? = nil) {
        self.client = client
        self.sourceRepository = sourceRepository
    }

    func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
        let playlists = try await client.fetchPlaylists()
        cache = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlists.map {
            RemotePlaylistSummary(id: $0.id, title: $0.name, trackCount: $0.tracksInfo?.total ?? 0)
        }
    }

    func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview {
        try await makePreview(id: summary.id, title: cache[summary.id]?.name ?? summary.title)
    }

    /// A pasted `open.spotify.com/playlist/‹id›` link (W3-ADD: Spotify playlist links open the
    /// import at the preview step). The title comes from the account's playlists when it is
    /// one of them.
    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
        guard let id = Self.playlistID(fromURL: url) else { throw RemotePlaylistProviderError.notAPlaylistURL(url) }
        if cache[id] == nil, let playlists = try? await client.fetchPlaylists() {
            for playlist in playlists where cache[playlist.id] == nil { cache[playlist.id] = playlist }
        }
        return try await makePreview(id: id, title: cache[id]?.name ?? "Spotify Playlist")
    }

    nonisolated static func playlistID(fromURL url: String) -> String? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.host?.lowercased() == "open.spotify.com" else { return nil }
        let parts = parsed.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "playlist"), index + 1 < parts.count, !parts[index + 1].isEmpty else { return nil }
        return parts[index + 1]
    }

    /// Spotify's source row is keyed by the signed-in account's id.
    func sourceRowForLinking() async throws -> Source {
        let profile = try await client.fetchProfile()
        return try await sourceRepository.upsert(name: "spotify", userId: profile.id)
    }

    private func makePreview(id: String, title: String) async throws -> RemotePlaylistPreview {
        let sourceTracks = try await client.fetchPlaylistTracks(playlistId: id)
        guard !sourceTracks.isEmpty else {
            throw RemotePlaylistProviderError.emptyPlaylist
        }
        return RemotePlaylistPreview(
            sourceName: displayName,
            externalID: id,
            title: title,
            tracks: sourceTracks.map { track in
                RemotePlaylistTrack(
                    externalID: track.id,
                    title: track.name,
                    artist: track.artists.first?.name ?? "",
                    // Spotify knows the real album; nothing when it doesn't (DEC-013).
                    album: track.album?.name ?? "",
                    durationSeconds: track.durationMs / 1000,
                    format: "spotify",
                    originalPath: "spotify://track/\(track.id)"
                )
            }
        )
    }
}

// MARK: - YouTube

@MainActor
final class YouTubePlaylistProvider: RemotePlaylistProvider {
    let displayName = "YouTube"
    let preferredSource: DownloadOrchestrator.PreferredSource = .youtube
    let browseMode: RemotePlaylistBrowseMode = .urlOnly

    private let downloader: YouTubeDownloader
    private let sourceRepository: SourceRepository

    init(downloader: YouTubeDownloader, trackRepository: TrackRepository? = nil, sourceRepository: SourceRepository,
         playlistRepository: PlaylistRepository? = nil) {
        self.downloader = downloader
        self.sourceRepository = sourceRepository
    }

    func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
        guard downloader.isAvailable else {
            throw RemotePlaylistProviderError.ytDlpUnavailable
        }
        let listing = try await downloader.listPlaylist(url: url)
        let entries = listing.entries
        guard !entries.isEmpty else {
            throw RemotePlaylistProviderError.emptyPlaylist
        }

        // Prefer the real playlist title; fall back to a URL-derived name so two different
        // playlists never share a generic name.
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
                    artist: entry.uploader ?? "",
                    // Mixes and videos import without an album (DEC-013).
                    album: "",
                    durationSeconds: entry.durationSeconds,
                    format: "youtube",
                    originalPath: entry.url
                )
            }
        )
    }

    /// YouTube's source row is userId "local" — playlist URLs are public.
    func sourceRowForLinking() async throws -> Source {
        let source = try await sourceRepository.upsert(name: "youtube", userId: "local")
        guard source.id != nil else {
            throw RemotePlaylistProviderError.previewUnavailable
        }
        return source
    }
}
