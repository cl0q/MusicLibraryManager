import Foundation

/// Background token refresh service.
///
/// Monitors stored OAuth tokens and proactively refreshes them
/// before they expire. Runs a periodic check every 60 seconds.
///
/// ## Design
/// - Each service that needs token refresh registers its refresh handler.
/// - The timer checks all services and triggers refresh when `needsRefresh` is true.
/// - Thread-safe via actor isolation.
actor TokenRefreshService {

    // MARK: - Types

    /// A registered service with its refresh logic.
    struct Registration {
        let service: TokenStorage.Service
        let tokenURL: URL
        let clientId: String
        let clientSecret: String?
    }

    // MARK: - State

    private let tokenStorage: TokenStorage
    private let oauthManager: OAuthManager
    private var registrations: [TokenStorage.Service: Registration] = [:]
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false

    /// Interval between refresh checks (60 seconds).
    private let checkInterval: TimeInterval = 60

    // MARK: - Init

    init(tokenStorage: TokenStorage, oauthManager: OAuthManager) {
        self.tokenStorage = tokenStorage
        self.oauthManager = oauthManager
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Registration

    /// Register a service for automatic token refresh.
    ///
    /// - Parameters:
    ///   - service: The token storage service key.
    ///   - tokenURL: The OAuth token endpoint for refreshing.
    ///   - clientId: The OAuth client ID.
    ///   - clientSecret: The OAuth client secret (if required).
    func register(
        service: TokenStorage.Service,
        tokenURL: URL,
        clientId: String,
        clientSecret: String? = nil
    ) {
        registrations[service] = Registration(
            service: service,
            tokenURL: tokenURL,
            clientId: clientId,
            clientSecret: clientSecret
        )
    }

    /// Unregister a service from automatic token refresh.
    func unregister(service: TokenStorage.Service) {
        registrations.removeValue(forKey: service)
    }

    // MARK: - Start/Stop

    /// Start the background refresh loop.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAllTokens()
                try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
            }
        }
    }

    /// Stop the background refresh loop.
    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Refresh Logic

    /// Check all registered services and refresh tokens that are expiring soon.
    private func checkAllTokens() async {
        for (_, registration) in registrations {
            do {
                guard let credentials = try tokenStorage.getCredentials(
                    service: registration.service
                ) else {
                    continue
                }

                if credentials.needsRefresh, let refreshToken = credentials.refreshToken {
                    try await performRefresh(
                        registration: registration,
                        refreshToken: refreshToken
                    )
                }
            } catch {
                print("[TokenRefresh] Failed to refresh \(registration.service.displayName): \(error)")
            }
        }
    }

    /// Refresh a single service's token.
    private func performRefresh(
        registration: Registration,
        refreshToken: String
    ) async throws {
        let response = try await oauthManager.refreshAccessToken(
            tokenURL: registration.tokenURL,
            refreshToken: refreshToken,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret
        )

        try tokenStorage.updateAccessToken(
            service: registration.service,
            accessToken: response.accessToken,
            expiresIn: response.expiresIn ?? 3600
        )

        // If a new refresh token was returned, save it too
        if let newRefreshToken = response.refreshToken {
            try tokenStorage.saveTokens(
                service: registration.service,
                accessToken: response.accessToken,
                refreshToken: newRefreshToken,
                expiresIn: response.expiresIn
            )
        }

        print("[TokenRefresh] Refreshed \(registration.service.displayName) token")
    }

    /// Force refresh a specific service's token (e.g., on 401 response).
    func forceRefresh(service: TokenStorage.Service) async throws {
        guard let registration = registrations[service] else {
            return
        }

        guard let credentials = try tokenStorage.getCredentials(service: service),
              let refreshToken = credentials.refreshToken else {
            return
        }

        try await performRefresh(registration: registration, refreshToken: refreshToken)
    }
}
