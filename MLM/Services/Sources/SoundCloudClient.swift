import Foundation

// MARK: - Injectable Seams (SCDL-04)
//
// `OAuthManager` is `final class ... @unchecked Sendable` — it cannot be
// subclassed or faked, so deterministic 401->refresh->retry test coverage
// requires an explicit seam for the refresh call. Likewise `URLSession`
// can't be scripted without hitting the network, so requests go through an
// injectable HTTP seam too. Production defaults preserve existing behavior
// (forwarding to `URLSession.shared` / `OAuthManager.refreshAccessToken`).

/// Injectable seam for issuing HTTP requests — lets tests script exact
/// response sequences (e.g. 401 then 200) deterministically.
protocol SoundCloudHTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production seam — forwards to `URLSession.shared`.
struct URLSessionHTTPRequesting: SoundCloudHTTPRequesting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Injectable seam for refreshing the SoundCloud OAuth token.
///
/// `OAuthManager` is final and cannot be faked directly, so tests substitute
/// a `SoundCloudTokenRefreshing` instead of the concrete manager.
protocol SoundCloudTokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> OAuthManager.TokenResponse
}

/// Production seam — forwards to `OAuthManager.refreshAccessToken`, preserving
/// SoundCloud's `grant_type=refresh_token` / `client_id` / `client_secret` wire
/// format (SCDL-04).
struct ProductionTokenRefreshing: SoundCloudTokenRefreshing {
    let oauthManager: OAuthManager
    let clientId: String
    let clientSecret: String
    let tokenURL: URL

    func refresh(refreshToken: String) async throws -> OAuthManager.TokenResponse {
        try await oauthManager.refreshAccessToken(
            tokenURL: tokenURL,
            refreshToken: refreshToken,
            clientId: clientId,
            clientSecret: clientSecret
        )
    }
}

/// Injectable seam over `TokenStorage`'s SoundCloud-relevant operations.
///
/// `TokenStorage` is a concrete Keychain-backed class. This protocol exists
/// purely so tests can substitute a spy that records calls (e.g. to prove
/// `deleteCredentials` is never invoked on a transient 401) without touching
/// the real Keychain. `TokenStorage` already implements every requirement
/// below, so it conforms with zero changes to its own file.
protocol SoundCloudTokenStoring: Sendable {
    func getCredentials(service: TokenStorage.Service) throws -> TokenStorage.Credentials?
    func saveTokens(service: TokenStorage.Service, accessToken: String, refreshToken: String?, expiresIn: Int?) throws
    func updateAccessToken(service: TokenStorage.Service, accessToken: String, expiresIn: Int) throws
    func deleteCredentials(service: TokenStorage.Service) throws
}

extension TokenStorage: SoundCloudTokenStoring {}

/// SoundCloud API client — OAuth 2.1 PKCE + liked songs/playlist sync.
///
/// Phase 9 — Ports the Tauri app's `src/sources/soundcloud.rs` to Swift.
///
/// ## OAuth Flow
/// 1. Call `authorize()` → opens system browser for SoundCloud login
/// 2. User approves → redirect to `mlm://callback` with authorization code
/// 3. Call `exchangeCode()` → get access + refresh tokens
/// 4. Store tokens via `TokenStorage` (Keychain)
///
/// ## Sync Flow
/// - `syncLikes()` — Fetch all liked tracks, upsert into DB as remote tracks
/// - `syncPlaylists()` — Fetch all playlists, sync tracks + ordering
///
/// ## API Notes
/// - Base URL: `https://api.soundcloud.com`
/// - Auth: Bearer token in `Authorization` header
/// - Pagination: `linked_partitioning=1` returns `next_href` for cursor-based paging
/// - Date format (non-standard): `"2026/01/03 09:39:42 +0000"`
final class SoundCloudClient: Sendable {

    // MARK: - Configuration

    private let clientId: String
    private let clientSecret: String
    private let redirectURI = LoopbackOAuthServer.redirectURI

    private static let authURL = URL(string: "https://soundcloud.com/connect")!
    /// Not `private` — `DependencyContainer` needs this to `register()` the
    /// SoundCloud token refresh service at boot (SCDL-05).
    static let tokenURL = URL(string: "https://secure.soundcloud.com/oauth/token")!
    private static let apiBase = URL(string: "https://api.soundcloud.com")!

    // MARK: - Dependencies

    private let tokenStorage: SoundCloudTokenStoring
    private let oauthManager: OAuthManager
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let playlistRepository: PlaylistRepository?
    private let httpRequesting: SoundCloudHTTPRequesting
    private let tokenRefreshing: SoundCloudTokenRefreshing

    // MARK: - Init

    init(
        tokenStorage: SoundCloudTokenStoring,
        oauthManager: OAuthManager,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        playlistRepository: PlaylistRepository? = nil,
        clientId: String? = nil,
        clientSecret: String? = nil,
        http: SoundCloudHTTPRequesting? = nil,
        refresher: SoundCloudTokenRefreshing? = nil
    ) {
        self.tokenStorage = tokenStorage
        self.oauthManager = oauthManager
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
        self.clientId = clientId ?? CredentialsLoader.credential(key: "SOUNDCLOUD_CLIENT_ID") ?? ""
        self.clientSecret = clientSecret ?? CredentialsLoader.credential(key: "SOUNDCLOUD_CLIENT_SECRET") ?? ""
        // Seams default to production adapters. Built here (not as a
        // self-referencing default parameter value, which Swift disallows)
        // so the defaults can bind the just-assigned instance state above.
        self.httpRequesting = http ?? URLSessionHTTPRequesting()
        self.tokenRefreshing = refresher ?? ProductionTokenRefreshing(
            oauthManager: oauthManager,
            clientId: self.clientId,
            clientSecret: self.clientSecret,
            tokenURL: Self.tokenURL
        )
    }

    // MARK: - OAuth Flow

    /// Start the OAuth authorization flow.
    ///
    /// Opens the system browser, starts a local loopback HTTP server on
    /// port 19823, waits for the callback, exchanges the code for tokens,
    /// and stores them in the Keychain.
    @MainActor
    func authorize() async throws {
        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            AppLogger.shared.error(
                "SC OAuth: missing credentials — add SOUNDCLOUD_CLIENT_ID/SECRET to " +
                "~/Library/Application Support/MLM/.env",
                source: "sc-oauth"
            )
            throw SoundCloudError.missingCredentials
        }

        // Step 1: Open browser + wait for loopback callback
        let code = try await oauthManager.authorizeWithLoopback(
            authorizationURL: Self.authURL,
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: ["non-expiring"]
        )

        // Step 2: Exchange code for tokens
        let tokenResponse = try await exchangeCode(code)

        // Step 3: Store tokens in Keychain
        try tokenStorage.saveTokens(
            service: .soundcloud,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: tokenResponse.expiresIn
        )

        // Step 4: Get user profile and create/update source record
        let user = try await fetchProfile()
        try await sourceRepository.upsert(name: "soundcloud", userId: String(user.id))
    }

    /// Exchange authorization code for tokens.
    ///
    /// SoundCloud uses POST body credentials (not HTTP Basic).
    private func exchangeCode(_ code: String) async throws -> OAuthManager.TokenResponse {
        guard let verifier = oauthManager.codeVerifier else {
            throw SoundCloudError.noCodeVerifier
        }

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "client_secret": clientSecret,
            "code_verifier": verifier,
        ]

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = body.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $1)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            AppLogger.shared.error(
                "SC OAuth: token exchange failed: HTTP \(status) — \(body.prefix(200))",
                source: "sc-oauth"
            )
            throw SoundCloudError.tokenExchangeFailed(body)
        }

        return try JSONDecoder().decode(OAuthManager.TokenResponse.self, from: data)
    }

    /// Disconnect — remove tokens from Keychain.
    func disconnect() throws {
        try tokenStorage.deleteCredentials(service: .soundcloud)
    }

    // MARK: - API Requests

    /// Make an authenticated API request.
    ///
    /// On 401: refresh the access token exactly once via the injected
    /// tokenRefreshing seam and retry exactly once. Never deletes stored
    /// credentials automatically -- the only credential deletion is the
    /// user-initiated disconnect() (SCDL-04).
    private func apiRequest<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem] = [],
        type: T.Type,
        didRetryAfterRefresh: Bool = false
    ) async throws -> T {
        guard let credentials = try tokenStorage.getCredentials(service: .soundcloud) else {
            throw SoundCloudError.notAuthenticated
        }

        var components = URLComponents(url: Self.apiBase.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SoundCloudError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await httpRequesting.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SoundCloudError.invalidResponse
        }

        // Handle rate limiting
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) } ?? 5.0
            try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            return try await apiRequest(endpoint: endpoint, queryItems: queryItems, type: type, didRetryAfterRefresh: didRetryAfterRefresh)
        }

        if http.statusCode == 401 {
            guard !didRetryAfterRefresh, let refreshToken = credentials.refreshToken else {
                AppLogger.shared.error(
                    "SC API: 401 Unauthorized on \(endpoint)" +
                    (didRetryAfterRefresh ? " after refresh+retry" : " -- no refresh token stored") +
                    " -- credentials left intact, re-auth required",
                    source: "sc-api"
                )
                throw SoundCloudError.tokenExpired
            }
            try await refreshSoundCloudToken(refreshToken: refreshToken, context: endpoint)
            return try await apiRequest(endpoint: endpoint, queryItems: queryItems, type: type, didRetryAfterRefresh: true)
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SoundCloudError.apiError(statusCode: http.statusCode, body: body)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    /// Make an authenticated request to a full URL (for pagination `next_href`).
    private func apiRequestURL<T: Decodable>(
        url: URL,
        type: T.Type,
        didRetryAfterRefresh: Bool = false
    ) async throws -> T {
        guard let credentials = try tokenStorage.getCredentials(service: .soundcloud) else {
            throw SoundCloudError.notAuthenticated
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await httpRequesting.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            guard !didRetryAfterRefresh, let refreshToken = credentials.refreshToken else {
                AppLogger.shared.error(
                    "SC API (paged): 401 Unauthorized on \(url)" +
                    (didRetryAfterRefresh ? " after refresh+retry" : " -- no refresh token stored") +
                    " -- credentials left intact, re-auth required",
                    source: "sc-api"
                )
                throw SoundCloudError.tokenExpired
            }
            try await refreshSoundCloudToken(refreshToken: refreshToken, context: url.absoluteString)
            return try await apiRequestURL(url: url, type: type, didRetryAfterRefresh: true)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SoundCloudError.apiError(statusCode: status, body: body)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    /// Refresh the SoundCloud access token via the injected seam (SCDL-04).
    ///
    /// Persists the refreshed access token (and new refresh token if one is
    /// returned) via the existing token-storage path. Throws
    /// `SoundCloudError.tokenExpired` -- WITHOUT deleting stored credentials --
    /// if the refresh itself fails. The caller is responsible for retrying
    /// the original request exactly once afterward.
    private func refreshSoundCloudToken(refreshToken: String, context: String) async throws {
        do {
            let refreshed = try await tokenRefreshing.refresh(refreshToken: refreshToken)
            try tokenStorage.updateAccessToken(
                service: .soundcloud,
                accessToken: refreshed.accessToken,
                expiresIn: refreshed.expiresIn ?? 3600
            )
            if let newRefreshToken = refreshed.refreshToken {
                try tokenStorage.saveTokens(
                    service: .soundcloud,
                    accessToken: refreshed.accessToken,
                    refreshToken: newRefreshToken,
                    expiresIn: refreshed.expiresIn
                )
            }
        } catch {
            AppLogger.shared.error(
                "SC API: 401 on \(context) -- refresh failed (\(error.localizedDescription)); " +
                "credentials left intact for manual re-auth",
                source: "sc-api"
            )
            throw SoundCloudError.tokenExpired
        }
    }

    // MARK: - Profile

    /// Fetch the authenticated user's profile.
    func fetchProfile() async throws -> SoundCloudUser {
        try await apiRequest(endpoint: "me", type: SoundCloudUser.self)
    }

    // MARK: - Search

    /// Search SoundCloud tracks using the `/tracks` API endpoint.
    ///
    /// - Parameters:
    ///   - query: Free-text search query
    ///   - limit: Maximum number of tracks to return (default is 3)
    /// - Returns: List of tracks from SoundCloud matching the query
    func searchTracks(query: String, limit: Int = 3) async throws -> [SoundCloudTrack] {
        let items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "linked_partitioning", value: "1")
        ]
        let collection: SoundCloudCollection<SoundCloudTrack> = try await apiRequest(
            endpoint: "tracks",
            queryItems: items,
            type: SoundCloudCollection<SoundCloudTrack>.self
        )
        return Array(collection.collection.prefix(limit))
    }

    // MARK: - Sync Likes

    /// Sync all liked tracks from SoundCloud into the database.
    ///
    /// Uses cursor-based pagination via `linked_partitioning`.
    /// Each liked track is upserted as a remote track (organized_path = NULL).
    ///
    /// - Returns: Number of new tracks added.
    @discardableResult
    func syncLikes() async throws -> Int {
        let user = try await fetchProfile()
        let source = try await sourceRepository.upsert(name: "soundcloud", userId: String(user.id))
        guard let sourceId = source.id else {
            throw SoundCloudError.noSourceId
        }

        var newCount = 0
        var nextURL: URL?
        let baseTime = Date()
        var trackIndex = 0
        // Track IDs in SoundCloud-like-order (newest first). Drives the
        // local "Liked from SoundCloud" playlist replacement at the end.
        var orderedTrackIds: [Int64] = []

        AppLogger.shared.info(
            "SoundCloud: syncLikes starting (user=\(user.username))",
            source: "SoundCloud"
        )

        // First page
        let firstPage: SoundCloudCollection<SoundCloudTrack> = try await apiRequest(
            endpoint: "me/favorites",
            queryItems: [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "linked_partitioning", value: "1"),
            ],
            type: SoundCloudCollection<SoundCloudTrack>.self
        )

        newCount += try await processLikedTracks(
            firstPage.collection,
            sourceId: sourceId,
            baseTime: baseTime,
            startIndex: &trackIndex,
            collectedIds: &orderedTrackIds
        )
        nextURL = firstPage.nextHref.flatMap { URL(string: $0) }

        // Subsequent pages
        while let url = nextURL {
            let page: SoundCloudCollection<SoundCloudTrack> = try await apiRequestURL(
                url: url,
                type: SoundCloudCollection<SoundCloudTrack>.self
            )

            newCount += try await processLikedTracks(
                page.collection,
                sourceId: sourceId,
                baseTime: baseTime,
                startIndex: &trackIndex,
                collectedIds: &orderedTrackIds
            )
            nextURL = page.nextHref.flatMap { URL(string: $0) }
        }

        // Mirror the API order into the local "Liked from SoundCloud"
        // playlist. Replace-in-place: a removed Like upstream disappears
        // locally on the next sync, a new Like appears at the top.
        //
        // We intentionally drop remote-only tracks here — the playlist is
        // meant to be the *playable* slice of likes. Remote-only items
        // would just be greyed-out clutter inside it.
        if let playlistRepo = playlistRepository {
            do {
                let localIds = try await trackRepository.filterLocalIds(orderedTrackIds)
                let playable = orderedTrackIds.filter { localIds.contains($0) }
                AppLogger.shared.info(
                    "SoundCloud: filterLocalIds → \(playable.count) playable of \(orderedTrackIds.count) collected",
                    source: "SoundCloud"
                )
                let playlist = try await playlistRepo.findOrCreateLikedPlaylist(
                    name: "Liked from SoundCloud",
                    sourceId: sourceId,
                    externalId: String(user.id),
                    // Very specific so user-created playlists like "SoundCloud
                    // Daily Mix" don't get accidentally hijacked.
                    legacyNameMatches: [
                        "soundcloud likes",
                        "soundcloud liked",
                        "liked from soundcloud",
                        "soundcloud favorites"
                    ]
                )
                if let playlistId = playlist.id {
                    // Reconcile duplicate likes playlists (a previous
                    // sync may have created a second row before
                    // findOrCreate matched name-based). Find every
                    // other is_liked=1 row whose name matches the
                    // legacy patterns and merge its tracks into ours.
                    let duplicates = try await playlistRepo.findDuplicateLikedPlaylists(
                        survivorId: playlistId,
                        legacyNameMatches: [
                            "soundcloud likes",
                            "soundcloud liked",
                            "liked from soundcloud",
                            "soundcloud favorites"
                        ]
                    )
                    for dup in duplicates {
                        if let dupId = dup.id {
                            try await playlistRepo.mergePlaylists(survivorId: playlistId, victimId: dupId)
                            AppLogger.shared.info(
                                "SoundCloud: merged duplicate liked playlist '\(dup.name)' (id=\(dupId)) into survivor id=\(playlistId)",
                                source: "SoundCloud"
                            )
                        }
                    }

                    try await playlistRepo.replaceTrackList(
                        playlistId: playlistId,
                        trackIds: playable
                    )
                    AppLogger.shared.info(
                        "SoundCloud: liked playlist refreshed (\(playable.count) playable of \(orderedTrackIds.count) likes)",
                        source: "SoundCloud"
                    )
                    NotificationCenter.default.post(name: .playlistDidChange, object: nil)
                }
            } catch {
                AppLogger.shared.warn(
                    "SoundCloud: liked-playlist update failed: \(error.localizedDescription)",
                    source: "SoundCloud"
                )
            }
        } else {
            AppLogger.shared.warn(
                "SoundCloud: no playlistRepository wired — liked playlist not refreshed",
                source: "SoundCloud"
            )
        }

        // Update last sync timestamp
        try await sourceRepository.setLastSyncTimestamp(
            userId: String(user.id),
            source: "soundcloud",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        AppLogger.shared.info(
            "SoundCloud: syncLikes done (new=\(newCount), total=\(orderedTrackIds.count))",
            source: "SoundCloud"
        )

        return newCount
    }

    /// Process a batch of liked tracks — deduplicate, insert new ones,
    /// and append the resulting track ID to `collectedIds` in API order.
    private func processLikedTracks(
        _ tracks: [SoundCloudTrack],
        sourceId: Int64,
        baseTime: Date,
        startIndex: inout Int,
        collectedIds: inout [Int64]
    ) async throws -> Int {
        var newCount = 0

        for scTrack in tracks {
            let externalId = String(scTrack.id)

            // Generate synthetic timestamp to preserve ordering
            let likedAt = baseTime.addingTimeInterval(-TimeInterval(startIndex) * 60)
            let isoDate = ISO8601DateFormatter().string(from: likedAt)

            // Build the track record
            var track = Track(
                artist: scTrack.user?.username ?? "Unknown",
                album: "SoundCloud Likes",
                title: scTrack.title,
                format: "soundcloud",
                originalPath: scTrack.permalinkUrl ?? "soundcloud://\(scTrack.id)"
            )
            track.duration = scTrack.duration.map { $0 / 1000 }  // SC uses milliseconds
            track.genre = scTrack.genre
            track.dateAdded = isoDate

            // Try to find existing track by external_id in track_sources
            let existing = try await findExistingTrack(
                externalId: externalId,
                permalink: track.originalPath,
                title: track.title,
                artist: track.artist
            )

            let resolvedTrackId: Int64?
            if let existingTrack = existing, let trackId = existingTrack.id {
                try await sourceRepository.linkTrackToSource(
                    trackId: trackId,
                    sourceId: sourceId,
                    externalId: externalId,
                    addedAt: isoDate
                )
                resolvedTrackId = trackId
            } else {
                // New track — insert and link
                let inserted = try await trackRepository.insert(track)
                if let trackId = inserted.id {
                    try await sourceRepository.linkTrackToSource(
                        trackId: trackId,
                        sourceId: sourceId,
                        externalId: externalId,
                        addedAt: isoDate
                    )
                    newCount += 1
                    resolvedTrackId = trackId
                } else {
                    resolvedTrackId = nil
                }
            }

            if let id = resolvedTrackId {
                if let artworkURL = scTrack.artworkUrl?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !artworkURL.isEmpty {
                    do {
                        try await trackRepository.setRemoteArtworkURL(
                            trackId: id,
                            url: artworkURL
                        )
                    } catch {
                        AppLogger.shared.warn(
                            "SoundCloud: could not retain artwork URL for track \(id): \(error.localizedDescription)",
                            source: "SoundCloud"
                        )
                    }
                }
                collectedIds.append(id)
            }

            startIndex += 1
        }

        return newCount
    }

    /// Find an existing track by external ID or fuzzy title/artist matching.
    private func findExistingTrack(
        externalId: String,
        permalink: String?,
        title: String,
        artist: String
    ) async throws -> Track? {
        // 1. Try to find by track_sources link (external_id + "soundcloud" source)
        if let track = try? await trackRepository.fetchTrackByExternalId(externalId, sourceName: "soundcloud") {
            return track
        }
        
        // 2. Try to find by original_path schemes/permalink
        if let track = try? await trackRepository.fetchTrackBySoundCloudPath(externalId: externalId, permalink: permalink) {
            return track
        }
        
        // 3. Fallback: Search by title + artist (fuzzy / exact text match)
        let results = try? await trackRepository.search(query: title)
        return results?.first { track in
            track.title.lowercased() == title.lowercased() &&
            track.artist.lowercased() == artist.lowercased()
        }
    }

    // MARK: - Sync Playlists

    /// Sync all playlists from SoundCloud.
    ///
    /// - Returns: Number of playlists synced.
    @discardableResult
    func syncPlaylists() async throws -> Int {
        let user = try await fetchProfile()
        let source = try await sourceRepository.upsert(name: "soundcloud", userId: String(user.id))
        guard let sourceId = source.id else {
            throw SoundCloudError.noSourceId
        }

        let playlistsPage: SoundCloudCollection<SoundCloudPlaylist> = try await apiRequest(
            endpoint: "me/playlists",
            queryItems: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "linked_partitioning", value: "1"),
            ],
            type: SoundCloudCollection<SoundCloudPlaylist>.self
        )

        // Process each playlist
        for scPlaylist in playlistsPage.collection {
            try await syncSinglePlaylist(scPlaylist, sourceId: sourceId)
        }

        return playlistsPage.collection.count
    }

    /// Sync a single SoundCloud playlist.
    private func syncSinglePlaylist(_ scPlaylist: SoundCloudPlaylist, sourceId: Int64) async throws {
        AppLogger.shared.info(
            "SoundCloud: syncing playlist '\(scPlaylist.title)' (\(scPlaylist.trackCount ?? 0) tracks)",
            source: "SoundCloud"
        )

        guard let playlistRepo = playlistRepository else {
            AppLogger.shared.warn(
                "SoundCloud: no playlistRepository wired — playlist '\(scPlaylist.title)' skipped",
                source: "SoundCloud"
            )
            return
        }

        // 1. Pull the ordered track list (may already be embedded).
        let scTracks: [SoundCloudTrack]
        if let embedded = scPlaylist.tracks, !embedded.isEmpty {
            scTracks = embedded
        } else {
            scTracks = try await fetchPlaylistTracks(playlistId: scPlaylist.id)
        }

        // 2. Upsert every track as a remote track, preserving API order.
        let baseTime = Date()
        var orderedTrackIds: [Int64] = []
        var index = 0
        _ = try await processLikedTracks(
            scTracks,
            sourceId: sourceId,
            baseTime: baseTime,
            startIndex: &index,
            collectedIds: &orderedTrackIds
        )

        // 3. Create/refresh the local source-linked playlist and mirror order.
        let playlist = try await playlistRepo.findOrCreateSourcePlaylist(
            name: scPlaylist.title,
            sourceId: sourceId,
            externalId: String(scPlaylist.id)
        )
        if let playlistId = playlist.id {
            try await playlistRepo.replaceTrackList(
                playlistId: playlistId,
                trackIds: orderedTrackIds
            )
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        }

        AppLogger.shared.info(
            "SoundCloud: playlist '\(scPlaylist.title)' synced (\(orderedTrackIds.count) tracks)",
            source: "SoundCloud"
        )
    }

    /// Fetch a lightweight list of the user's playlists (no track bodies)
    /// for browsing. Returns the API playlist objects directly.
    func fetchPlaylists() async throws -> [SoundCloudPlaylist] {
        let page: SoundCloudCollection<SoundCloudPlaylist> = try await apiRequest(
            endpoint: "me/playlists",
            queryItems: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "linked_partitioning", value: "1"),
            ],
            type: SoundCloudCollection<SoundCloudPlaylist>.self
        )
        return page.collection
    }

    /// Fetch the full, ordered track list for a playlist, following
    /// `next_href` cursor pagination.
    func fetchPlaylistTracks(playlistId: Int) async throws -> [SoundCloudTrack] {
        var tracks: [SoundCloudTrack] = []

        let firstPage: SoundCloudCollection<SoundCloudTrack> = try await apiRequest(
            endpoint: "playlists/\(playlistId)/tracks",
            queryItems: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "linked_partitioning", value: "1"),
            ],
            type: SoundCloudCollection<SoundCloudTrack>.self
        )
        tracks.append(contentsOf: firstPage.collection)
        var nextURL = firstPage.nextHref.flatMap { URL(string: $0) }

        while let url = nextURL {
            let page: SoundCloudCollection<SoundCloudTrack> = try await apiRequestURL(
                url: url,
                type: SoundCloudCollection<SoundCloudTrack>.self
            )
            tracks.append(contentsOf: page.collection)
            nextURL = page.nextHref.flatMap { URL(string: $0) }
        }

        return tracks
    }


    /// Import a single playlist into the local library (persist tracks +
    /// create/refresh the source-linked playlist) and return its local
    /// playlist ID. Used by the remote-playlist browser before download.
    @discardableResult
    func importPlaylist(_ scPlaylist: SoundCloudPlaylist) async throws -> Int64? {
        let user = try await fetchProfile()
        let source = try await sourceRepository.upsert(name: "soundcloud", userId: String(user.id))
        guard let sourceId = source.id else {
            throw SoundCloudError.noSourceId
        }
        try await syncSinglePlaylist(scPlaylist, sourceId: sourceId)
        guard let playlistRepo = playlistRepository else { return nil }
        let playlist = try await playlistRepo.findOrCreateSourcePlaylist(
            name: scPlaylist.title,
            sourceId: sourceId,
            externalId: String(scPlaylist.id)
        )
        return playlist.id
    }

    // MARK: - Search

    /// Search SoundCloud tracks by free-text query.
    func search(query: String, limit: Int = 25) async throws -> [RemoteSearchResult] {
        let page: SoundCloudCollection<SoundCloudTrack> = try await apiRequest(
            endpoint: "tracks",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "linked_partitioning", value: "1"),
            ],
            type: SoundCloudCollection<SoundCloudTrack>.self
        )
        return page.collection.map { t in
            RemoteSearchResult(
                id: "sc-\(t.id)",
                source: .soundcloud,
                artist: t.user?.username ?? "Unknown",
                title: t.title,
                durationSeconds: t.duration.map { $0 / 1000 },
                externalId: String(t.id),
                sourceURL: t.permalinkUrl
            )
        }
    }

    // MARK: - Errors

    enum SoundCloudError: LocalizedError {
        case notAuthenticated
        case noCodeVerifier
        case noSourceId
        case missingCredentials
        case invalidURL(String)
        case invalidResponse
        case tokenExpired
        case tokenExchangeFailed(String)
        case apiError(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: "Not authenticated — connect SoundCloud first"
            case .noCodeVerifier: "OAuth error: no PKCE code verifier"
            case .noSourceId: "Failed to create source record"
            case .missingCredentials:
                "SoundCloud credentials missing — add SOUNDCLOUD_CLIENT_ID and " +
                "SOUNDCLOUD_CLIENT_SECRET to ~/Library/Application Support/MLM/.env"
            case .invalidURL(let endpoint): "Invalid API URL: \(endpoint)"
            case .invalidResponse: "Invalid HTTP response"
            case .tokenExpired: "SoundCloud session expired — click Connect to re-authenticate"
            case .tokenExchangeFailed(let body): "Token exchange failed: \(body)"
            case .apiError(let code, let body): "API error (\(code)): \(body)"
            }
        }
    }
}

// MARK: - SoundCloud API Models

/// SoundCloud paginated collection response.
struct SoundCloudCollection<T: Codable & Sendable>: Codable, Sendable {
    let collection: [T]
    let nextHref: String?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

/// SoundCloud user profile.
struct SoundCloudUser: Codable, Sendable {
    let id: Int
    let username: String
    let avatarUrl: String?
    let fullName: String?
    let permalink: String?

    /// String ID for database compatibility.
    var stringId: String { String(id) }

    // Use stringId for the database operations
    var id_s: String { String(id) }

    enum CodingKeys: String, CodingKey {
        case id, username, permalink
        case avatarUrl = "avatar_url"
        case fullName = "full_name"
    }
}

/// SoundCloud track from the API.
struct SoundCloudTrack: Codable, Sendable {
    let id: Int
    let title: String
    let duration: Int?        // milliseconds
    let genre: String?
    let permalinkUrl: String?
    let streamUrl: String?
    let artworkUrl: String?
    let user: SoundCloudUser?
    let createdAt: String?    // non-standard format

    enum CodingKeys: String, CodingKey {
        case id, title, duration, genre, user
        case permalinkUrl = "permalink_url"
        case streamUrl = "stream_url"
        case artworkUrl = "artwork_url"
        case createdAt = "created_at"
    }
}

/// SoundCloud playlist from the API.
struct SoundCloudPlaylist: Codable, Sendable {
    let id: Int
    let title: String
    let trackCount: Int?
    let description: String?
    let permalinkUrl: String?
    let artworkUrl: String?
    let tracks: [SoundCloudTrack]?

    enum CodingKeys: String, CodingKey {
        case id, title, description, tracks
        case trackCount = "track_count"
        case permalinkUrl = "permalink_url"
        case artworkUrl = "artwork_url"
    }
}
