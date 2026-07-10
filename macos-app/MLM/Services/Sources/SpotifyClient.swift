import Foundation

/// Spotify API client — OAuth 2.0 PKCE + liked songs/playlist sync.
///
/// Phase 8 — Ports the Tauri app's `src/sources/spotify.rs` to Swift.
///
/// ## OAuth Configuration
/// - Auth URL: `https://accounts.spotify.com/authorize`
/// - Token URL: `https://accounts.spotify.com/api/token`
/// - API Base: `https://api.spotify.com/v1`
/// - Scopes: `user-library-read`, `playlist-read-private`
/// - Redirect: `mlm://callback`
///
/// ## Sync Strategy
/// - Incremental sync: stops when hitting tracks older than last_sync_timestamp
/// - Page size: 50 (Spotify API max)
final class SpotifyClient {

    // MARK: - Configuration

    private let clientId: String
    private let clientSecret: String
    private let redirectURI = LoopbackOAuthServer.redirectURI

    private static let authURL = URL(string: "https://accounts.spotify.com/authorize")!
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    private static let apiBase = URL(string: "https://api.spotify.com/v1")!

    private let scopes = ["user-library-read", "playlist-read-private", "playlist-read-collaborative"]

    // MARK: - Dependencies

    private let tokenStorage: TokenStorage
    private let oauthManager: OAuthManager
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let playlistRepository: PlaylistRepository?

    // MARK: - Init

    init(
        tokenStorage: TokenStorage,
        oauthManager: OAuthManager,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        playlistRepository: PlaylistRepository? = nil,
        clientId: String? = nil,
        clientSecret: String? = nil
    ) {
        self.tokenStorage = tokenStorage
        self.oauthManager = oauthManager
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
        self.clientId = clientId ?? CredentialsLoader.credential(key: "SPOTIFY_CLIENT_ID") ?? ""
        self.clientSecret = clientSecret ?? CredentialsLoader.credential(key: "SPOTIFY_CLIENT_SECRET") ?? ""
    }

    // MARK: - OAuth

    /// Start the Spotify OAuth authorization flow.
    ///
    /// Opens the system browser, waits for the loopback callback,
    /// exchanges the code for tokens, and stores them in the Keychain.
    @MainActor
    func authorize() async throws {
        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            AppLogger.shared.error(
                "Spotify OAuth: missing credentials — add SPOTIFY_CLIENT_ID/SECRET to " +
                "~/Library/Application Support/MLM/.env",
                source: "spotify-oauth"
            )
            throw SpotifyError.missingCredentials
        }

        let code = try await oauthManager.authorizeWithLoopback(
            authorizationURL: Self.authURL,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes
        )

        let tokenResponse = try await oauthManager.exchangeCode(
            tokenURL: Self.tokenURL,
            code: code,
            clientId: clientId,
            clientSecret: clientSecret,
            redirectURI: redirectURI
        )

        if tokenResponse.accessToken.isEmpty {
            AppLogger.shared.error(
                "Spotify OAuth: token exchange returned empty access token",
                source: "spotify-oauth"
            )
            throw SpotifyError.tokenExchangeFailed
        }

        try tokenStorage.saveTokens(
            service: .spotify,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: tokenResponse.expiresIn
        )

        let profile = try await fetchProfile()
        try await sourceRepository.upsert(name: "spotify", userId: profile.id)
    }

    /// Disconnect Spotify.
    func disconnect() throws {
        try tokenStorage.deleteCredentials(service: .spotify)
    }

    // MARK: - API

    /// Make an authenticated Spotify API request.
    private func apiRequest<T: Decodable>(endpoint: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let credentials = try tokenStorage.getCredentials(service: .spotify) else {
            throw SpotifyError.notAuthenticated
        }

        var components = URLComponents(url: Self.apiBase.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw SpotifyError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.invalidResponse
        }

        // 429 rate limit
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) } ?? 5.0
            try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            return try await apiRequest(endpoint: endpoint, queryItems: queryItems)
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError.apiError(statusCode: http.statusCode, body: body)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Profile

    /// Fetch the current user's profile.
    func fetchProfile() async throws -> SpotifyUser {
        try await apiRequest(endpoint: "me")
    }

    // MARK: - Sync

    /// Sync liked songs from Spotify.
    ///
    /// Incremental: stops when encountering tracks older than last sync timestamp.
    /// Page size: 50 (Spotify API max).
    @discardableResult
    func syncLikedSongs() async throws -> Int {
        // Get source record
        let profile = try await fetchProfile()
        let source = try await sourceRepository.upsert(name: "spotify", userId: profile.id)

        // Get last sync timestamp for incremental sync
        let lastSync = try await sourceRepository.getLastSync(sourceId: source.id!, syncType: "liked_songs")

        var totalSynced = 0
        var offset = 0
        let pageSize = 50
        var reachedOldTracks = false

        while !reachedOldTracks {
            let response: SpotifyPaginatedResponse<SpotifySavedTrack> = try await apiRequest(
                endpoint: "me/tracks",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)")
                ]
            )

            if response.items.isEmpty { break }

            for savedTrack in response.items {
                // Check if this track was added before our last sync
                if let lastSync, savedTrack.addedAt <= lastSync {
                    reachedOldTracks = true
                    break
                }

                // Check for existing track (deduplicate by title/artist)
                let artist = savedTrack.track.artists.first?.name ?? "Unknown"
                let title = savedTrack.track.name
                let album = savedTrack.track.album?.name ?? "Unknown"

                let existingTracks = try await trackRepository.search(query: title)
                let isDuplicate = existingTracks.contains { existing in
                    existing.title.lowercased() == title.lowercased() &&
                    existing.artist.lowercased() == artist.lowercased()
                }

                if !isDuplicate {
                    // Insert new remote track
                    var track = Track(
                        artist: artist,
                        albumArtist: artist,
                        album: album,
                        title: title,
                        format: "spotify",
                        originalPath: "spotify://track/\(savedTrack.track.id)"
                    )
                    track.duration = savedTrack.track.durationMs / 1000
                    track.dateAdded = savedTrack.addedAt

                    // Extract year from release date
                    if let releaseDate = savedTrack.track.album?.releaseDate,
                       releaseDate.count >= 4,
                       let year = Int(String(releaseDate.prefix(4))) {
                        track.year = year
                    }

                    let inserted = try await trackRepository.insert(track)

                    // Link to source
                    if let trackId = inserted.id {
                        try await sourceRepository.linkTrackToSource(
                            trackId: trackId,
                            sourceId: source.id!,
                            externalId: savedTrack.track.id
                        )
                    }

                    totalSynced += 1
                }
            }

            offset += pageSize
            if response.next == nil { break }
        }

        // Update last sync timestamp
        try await sourceRepository.updateLastSync(
            sourceId: source.id!,
            syncType: "liked_songs",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        AppLogger.shared.log("Spotify: synced \(totalSynced) liked songs", source: "Spotify")
        return totalSynced
    }

    /// Sync playlists from Spotify.
    @discardableResult
    func syncPlaylists() async throws -> Int {
        let profile = try await fetchProfile()
        let source = try await sourceRepository.upsert(name: "spotify", userId: profile.id)
        var totalSynced = 0
        var offset = 0
        let pageSize = 50

        // Fetch user's playlists
        while true {
            let response: SpotifyPaginatedResponse<SpotifyPlaylistSimple> = try await apiRequest(
                endpoint: "me/playlists",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)")
                ]
            )

            if response.items.isEmpty { break }

            for playlist in response.items {
                // Create or update playlist in DB
                let dbPlaylist = try await syncSinglePlaylist(
                    spotifyPlaylist: playlist,
                    sourceId: source.id!
                )
                if dbPlaylist != nil { totalSynced += 1 }
            }

            offset += pageSize
            if response.next == nil { break }
        }

        try await sourceRepository.updateLastSync(
            sourceId: source.id!,
            syncType: "playlists",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        AppLogger.shared.log("Spotify: synced \(totalSynced) playlists", source: "Spotify")
        return totalSynced
    }

    /// Sync a single Spotify playlist to the local database.
    private func syncSinglePlaylist(
        spotifyPlaylist: SpotifyPlaylistSimple,
        sourceId: Int64
    ) async throws -> Playlist? {
        // Create the playlist if it doesn't exist
        let existingPlaylists = try await PlaylistRepository(database: sourceRepository.databasePool)
            .fetchAll()
        let existing = existingPlaylists.first { $0.name == spotifyPlaylist.name }

        // For now, just track the playlist metadata — full track sync deferred
        if existing != nil {
            return existing
        }

        // Playlist.createNative creates via PlaylistRepository
        // For spotify playlists, we just note them
        return nil
    }

    // MARK: - Playlist Browsing

    /// Fetch the user's playlists for browsing.
    func fetchPlaylists() async throws -> [SpotifyPlaylistSimple] {
        var all: [SpotifyPlaylistSimple] = []
        var offset = 0
        let pageSize = 50
        while true {
            let response: SpotifyPaginatedResponse<SpotifyPlaylistSimple> = try await apiRequest(
                endpoint: "me/playlists",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)")
                ]
            )
            all.append(contentsOf: response.items)
            if response.next == nil || response.items.isEmpty { break }
            offset += pageSize
        }
        return all
    }

    /// Fetch the ordered track list of a playlist (metadata only — Spotify
    /// provides no downloadable audio).
    func fetchPlaylistTracks(playlistId: String) async throws -> [SpotifyTrackObject] {
        var tracks: [SpotifyTrackObject] = []
        var offset = 0
        let pageSize = 100
        while true {
            let response: SpotifyPaginatedResponse<SpotifyPlaylistTrackItem> = try await apiRequest(
                endpoint: "playlists/\(playlistId)/tracks",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)")
                ]
            )
            tracks.append(contentsOf: response.items.compactMap { $0.track })
            if response.next == nil || response.items.isEmpty { break }
            offset += pageSize
        }
        return tracks
    }

    /// Import a playlist into the local library (tracks as remote metadata +
    /// a source-linked playlist), returning its local playlist ID.
    @discardableResult
    func importPlaylist(_ playlist: SpotifyPlaylistSimple) async throws -> Int64? {
        let profile = try await fetchProfile()
        let source = try await sourceRepository.upsert(name: "spotify", userId: profile.id)
        guard let sourceId = source.id else { return nil }
        guard let playlistRepo = playlistRepository else { return nil }

        let scTracks = try await fetchPlaylistTracks(playlistId: playlist.id)

        var orderedIds: [Int64] = []
        for spTrack in scTracks {
            let artist = spTrack.artists.first?.name ?? "Unknown"
            let title = spTrack.name
            let album = spTrack.album?.name ?? "Unknown"
            let externalId = spTrack.id

            // Reuse an existing track linked by external_id, else insert.
            if let existing = try? await trackRepository.fetchTrackByExternalId(externalId, sourceName: "spotify"),
               let id = existing.id {
                orderedIds.append(id)
                continue
            }

            var track = Track(
                artist: artist,
                albumArtist: artist,
                album: album,
                title: title,
                format: "spotify",
                originalPath: "spotify://track/\(externalId)"
            )
            track.duration = spTrack.durationMs / 1000
            if let releaseDate = spTrack.album?.releaseDate,
               releaseDate.count >= 4,
               let year = Int(String(releaseDate.prefix(4))) {
                track.year = year
            }
            let inserted = try await trackRepository.insert(track)
            if let id = inserted.id {
                try await sourceRepository.linkTrackToSource(
                    trackId: id,
                    sourceId: sourceId,
                    externalId: externalId
                )
                orderedIds.append(id)
            }
        }

        let dbPlaylist = try await playlistRepo.findOrCreateSourcePlaylist(
            name: playlist.name,
            sourceId: sourceId,
            externalId: playlist.id
        )
        if let playlistId = dbPlaylist.id {
            try await playlistRepo.replaceTrackList(playlistId: playlistId, trackIds: orderedIds)
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        }
        return dbPlaylist.id
    }

    // MARK: - Search

    /// Search Spotify tracks by free-text query.
    func search(query: String, limit: Int = 25) async throws -> [RemoteSearchResult] {
        let response: SpotifySearchResponse = try await apiRequest(
            endpoint: "search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ]
        )
        return response.tracks.items.map { t in
            RemoteSearchResult(
                id: "sp-\(t.id)",
                source: .spotify,
                artist: t.artists.first?.name ?? "Unknown",
                title: t.name,
                durationSeconds: t.durationMs / 1000,
                externalId: t.id,
                sourceURL: nil
            )
        }
    }

    // MARK: - Errors

    enum SpotifyError: LocalizedError {
        case notAuthenticated
        case missingCredentials
        case tokenExchangeFailed
        case invalidURL(String)
        case invalidResponse
        case apiError(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: "Not authenticated — connect Spotify first"
            case .missingCredentials:
                "Spotify credentials missing — add SPOTIFY_CLIENT_ID and " +
                "SPOTIFY_CLIENT_SECRET to ~/Library/Application Support/MLM/.env"
            case .tokenExchangeFailed: "Spotify token exchange returned an empty access token"
            case .invalidURL(let ep): "Invalid URL: \(ep)"
            case .invalidResponse: "Invalid response"
            case .apiError(let code, let body): "Spotify API error (\(code)): \(body)"
            }
        }
    }
}

// MARK: - Spotify API Models

struct SpotifyUser: Codable {
    let id: String
    let displayName: String?
    let email: String?
    let images: [SpotifyImage]?

    enum CodingKeys: String, CodingKey {
        case id, email, images
        case displayName = "display_name"
    }
}

struct SpotifyImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

struct SpotifyPaginatedResponse<T: Codable>: Codable {
    let items: [T]
    let total: Int
    let limit: Int
    let offset: Int
    let next: String?
    let previous: String?
}

struct SpotifySavedTrack: Codable {
    let addedAt: String
    let track: SpotifyTrackObject

    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case track
    }
}

struct SpotifyTrackObject: Codable {
    let id: String
    let name: String
    let durationMs: Int
    let album: SpotifyAlbum?
    let artists: [SpotifyArtist]

    enum CodingKeys: String, CodingKey {
        case id, name, album, artists
        case durationMs = "duration_ms"
    }
}

struct SpotifyAlbum: Codable {
    let id: String
    let name: String
    let images: [SpotifyImage]?
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, images
        case releaseDate = "release_date"
    }
}

struct SpotifyArtist: Codable {
    let id: String
    let name: String
}

struct SpotifyPlaylistSimple: Codable {
    let id: String
    let name: String
    let description: String?
    let images: [SpotifyImage]?
    let tracksInfo: SpotifyPlaylistTracksRef?
    let owner: SpotifyUser?

    enum CodingKeys: String, CodingKey {
        case id, name, description, images, owner
        case tracksInfo = "tracks"
    }
}

struct SpotifyPlaylistTracksRef: Codable {
    let total: Int
    let href: String
}

/// A single item from `playlists/{id}/tracks` — the wrapped track can be
/// null (e.g. removed/unavailable tracks), so it's optional.
struct SpotifyPlaylistTrackItem: Codable {
    let track: SpotifyTrackObject?
}

/// Response wrapper for `GET /search?type=track`.
struct SpotifySearchResponse: Codable {
    let tracks: SpotifyTracksPage

    struct SpotifyTracksPage: Codable {
        let items: [SpotifyTrackObject]
    }
}
