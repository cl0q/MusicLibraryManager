import Foundation

/// ViewModel for the Sources view — manages connection status,
/// sync state, and OAuth flows for streaming services.
///
/// Phase 8/9/10 — Unified VM for Spotify, SoundCloud, and Apple Music.
@Observable
final class SourcesViewModel {

    // MARK: - Per-source state

    /// Connection status per service.
    private var connectionStatus: [TokenStorage.Service: Bool] = [:]

    /// Sync in-progress per service.
    private var syncingServices: Set<TokenStorage.Service> = []

    /// Track counts per service.
    private var trackCounts: [TokenStorage.Service: Int] = [:]

    /// Last sync timestamps per service.
    private var lastSyncTimestamps: [TokenStorage.Service: String] = [:]

    /// Errors per service.
    private var errors: [TokenStorage.Service: String] = [:]

    /// Reconnect in progress per service.
    private var reconnectingServices: Set<TokenStorage.Service> = []

    /// Whether loading is in progress.
    private(set) var isLoading = false
    /// A repository-load failure is distinct from a source being disconnected.
    private(set) var loadError: String?

    // MARK: - Dependencies

    private let tokenStorage: TokenStorage
    private let sourceRepository: SourceRepository
    private let oauthManager: OAuthManager?
    private let tokenAccessStatus: TokenAccessStatus?
    private let tokenRefreshService: TokenRefreshService?
    /// The one account-state model (W3-SET), reached through the shared access status.
    @MainActor private var accounts: SourceAccounts? { tokenAccessStatus?.accounts }

    // Source clients (lazy-initialized)
    private var soundCloudClient: SoundCloudClient?
    private var spotifyClient: SpotifyClient?
    private var appleMusicClient: AppleMusicClient?

    // MARK: - Init

    init(
        tokenStorage: TokenStorage,
        sourceRepository: SourceRepository,
        oauthManager: OAuthManager?,
        trackRepository: TrackRepository? = nil,
        playlistRepository: PlaylistRepository? = nil,
        tokenAccessStatus: TokenAccessStatus? = nil,
        tokenRefreshService: TokenRefreshService? = nil
    ) {
        self.tokenStorage = tokenStorage
        self.sourceRepository = sourceRepository
        self.oauthManager = oauthManager
        self.tokenAccessStatus = tokenAccessStatus
        self.tokenRefreshService = tokenRefreshService

        // Initialize source clients if dependencies are available
        if let oauth = oauthManager, let trackRepo = trackRepository {
            self.soundCloudClient = SoundCloudClient(
                tokenStorage: tokenStorage,
                oauthManager: oauth,
                trackRepository: trackRepo,
                sourceRepository: sourceRepository,
                playlistRepository: playlistRepository
            )
            self.spotifyClient = SpotifyClient(
                tokenStorage: tokenStorage,
                oauthManager: oauth,
                trackRepository: trackRepo,
                sourceRepository: sourceRepository
            )
            self.appleMusicClient = AppleMusicClient(
                tokenStorage: tokenStorage,
                trackRepository: trackRepo,
                sourceRepository: sourceRepository
            )
        }
    }

    // MARK: - State Accessors

    /// Whether a source is connected.
    func isConnected(_ service: TokenStorage.Service) -> Bool {
        connectionStatus[service] ?? false
    }

    /// Whether OAuth credentials exist for the service.
    func hasCredentials(for service: TokenStorage.Service) -> Bool {
        CredentialsLoader.hasCredentials(for: service)
    }

    /// Hint shown when credentials are missing (nil when credentials are present).
    func credentialHint(for service: TokenStorage.Service) -> String? {
        guard !hasCredentials(for: service) else { return nil }
        return "Add credentials to ~/Library/Application Support/MLM/.env"
    }

    /// Whether a source is currently syncing.
    func isSyncing(_ service: TokenStorage.Service) -> Bool {
        syncingServices.contains(service)
    }

    /// Track count for a source.
    func trackCount(for service: TokenStorage.Service) -> Int {
        trackCounts[service] ?? 0
    }

    /// Last sync display string.
    func lastSyncDisplay(for service: TokenStorage.Service) -> String {
        guard let timestamp = lastSyncTimestamps[service] else {
            return "Never"
        }

        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            let display = RelativeDateTimeFormatter()
            display.unitsStyle = .abbreviated
            return display.localizedString(for: date, relativeTo: Date())
        }

        return String(timestamp.prefix(10))
    }

    /// When the source was last refreshed (Settings ▸ Sources: `last refreshed today, 09:14`).
    func lastSyncDate(for service: TokenStorage.Service) -> Date? {
        lastSyncTimestamps[service].flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Error message for a source.
    func error(for service: TokenStorage.Service) -> String? {
        errors[service]
    }

    /// Whether the source's keychain token currently needs user interaction
    /// to read (surfaces the amber notice in the Sources card).
    @MainActor
    func isTokenInaccessible(_ service: TokenStorage.Service) -> Bool {
        tokenAccessStatus?.isInaccessible(service) ?? false
    }

    /// Whether a reconnect is in progress for a source.
    @MainActor
    func isReconnecting(_ service: TokenStorage.Service) -> Bool {
        reconnectingServices.contains(service)
    }

    // MARK: - Load

    /// Load connection status and track counts from Keychain + database.
    @MainActor
    func loadSources() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Check Keychain for stored credentials, and keep the shared access
        // state in sync (also covers services not registered with the
        // background refresh loop).
        var readings: [TokenStorage.Service: StoredSignIn] = [:]
        for service in TokenStorage.Service.allCases {
            connectionStatus[service] = tokenStorage.hasCredentials(service: service)
            do {
                _ = try tokenStorage.getCredentials(service: service)
                tokenAccessStatus?.markAccessible(service)
            } catch TokenStorage.KeychainError.itemInaccessible {
                tokenAccessStatus?.markInaccessible(service)
            } catch {
                // Unreadable for another reason — hasCredentials above
                // already answered the UI question.
            }
            readings[service] = SourceAccounts.reading(tokenStorage, service: service)
        }
        // W3-SET: the one account-state model gets the same reading.
        accounts?.apply(readings)

        // Load track counts from sources table
        do {
            let sources = try await sourceRepository.fetchAll()
            for source in sources {
                if let service = mapSourceType(source.sourceType) {
                    let count = try await sourceRepository.countTracks(sourceId: source.id!)
                    trackCounts[service] = count

                    // Get last sync timestamp
                    if let timestamp = try await sourceRepository.getLastSync(
                        sourceId: source.id!,
                        syncType: "liked_songs"
                    ) {
                        lastSyncTimestamps[service] = timestamp
                    }
                }
            }
        } catch {
            loadError = "Could not load source details. \(error.localizedDescription)"
            AppLogger.shared.error(
                "Error loading source details: \(error.localizedDescription)",
                source: "Sources"
            )
        }
    }

    // MARK: - Connect

    /// Connect a streaming source via OAuth.
    @MainActor
    func connectSource(_ service: TokenStorage.Service) async {
        errors.removeValue(forKey: service)

        do {
            switch service {
            case .soundcloud:
                guard let client = soundCloudClient else {
                    errors[service] = "SoundCloud client not initialized"
                    return
                }
                try await client.authorize()

            case .spotify:
                guard let client = spotifyClient else {
                    errors[service] = "Spotify client not initialized"
                    return
                }
                try await client.authorize()

            case .appleMusic:
                guard let client = appleMusicClient else {
                    errors[service] = "Apple Music client not initialized"
                    return
                }
                try await client.authorize()
            }

            connectionStatus[service] = true
            accounts?.didConnect(service)
        } catch {
            errors[service] = error.localizedDescription
            AppLogger.shared.error(
                "\(service.displayName) OAuth failed: \(error.localizedDescription)",
                source: "sources"
            )
        }
    }

    /// The browser sign-in (S-SRC-OAUTH) — the one entry point for `Connect` / `Reconnect` in
    /// the import sheets and Settings ▸ Sources. Throws the failure (`CancellationError` when
    /// the caller's task was cancelled); on success the source is connected.
    @MainActor
    func signIn(_ service: TokenStorage.Service) async throws {
        switch service {
        case .soundcloud:
            guard let client = soundCloudClient else { throw SoundCloudClient.SoundCloudError.notAuthenticated }
            try await client.authorize()
        case .spotify:
            guard let client = spotifyClient else { throw SpotifyClient.SpotifyError.notAuthenticated }
            try await client.authorize()
        case .appleMusic:
            guard let client = appleMusicClient else { throw SpotifyClient.SpotifyError.notAuthenticated }
            try await client.authorize()
        }
        connectionStatus[service] = true
        errors.removeValue(forKey: service)
        accounts?.didConnect(service)
    }

    // MARK: - Reconnect

    /// Reconnect a source whose keychain token is currently inaccessible.
    ///
    /// Tries one interactive keychain read first (the user is right here, so a
    /// single prompt is acceptable); falls back to the full OAuth flow.
    @MainActor
    func reconnectSource(_ service: TokenStorage.Service) async {
        guard !reconnectingServices.contains(service) else { return }
        reconnectingServices.insert(service)
        defer { reconnectingServices.remove(service) }

        errors.removeValue(forKey: service)

        if (try? tokenStorage.getCredentials(service: service, interactive: true)) != nil {
            connectionStatus[service] = true
            tokenAccessStatus?.markAccessible(service)
            await tokenRefreshService?.clearBackoff(service: service)
            AppLogger.shared.info(
                "\(service.displayName) token readable again after interactive keychain read",
                source: "Sources"
            )
            return
        }

        await connectSource(service)
        guard errors[service] == nil else { return }
        tokenAccessStatus?.markAccessible(service)
        await tokenRefreshService?.clearBackoff(service: service)
    }

    // MARK: - Disconnect

    /// Disconnect a streaming source — delete tokens.
    @MainActor
    func disconnectSource(_ service: TokenStorage.Service) async {
        errors.removeValue(forKey: service)

        do {
            try tokenStorage.deleteCredentials(service: service)
            connectionStatus[service] = false
            trackCounts.removeValue(forKey: service)
            lastSyncTimestamps.removeValue(forKey: service)
            tokenAccessStatus?.markAccessible(service)
            accounts?.didDisconnect(service)
        } catch {
            errors[service] = error.localizedDescription
        }
    }

    // `Refresh from ‹Source›` lives in `SourceRefreshService` (W3-ADD; the Add menu's `Refresh from
    // Sources`): linked playlists, add-only.

    // MARK: - Helpers

    /// Map a source_type string from the DB to a TokenStorage.Service.
    private func mapSourceType(_ type: SourceType) -> TokenStorage.Service? {
        switch type {
        case .spotify:     .spotify
        case .soundcloud:  .soundcloud
        case .appleMusic:  .appleMusic
        case .unknown:     nil
        }
    }
}
