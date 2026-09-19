import Foundation

protocol TokenRefreshConfiguring: Sendable {
    func register(
        service: TokenStorage.Service,
        tokenURL: URL,
        clientId: String,
        clientSecret: String?
    ) async

    func start() async
}

/// Exponential retry schedule for a service whose keychain token is
/// currently inaccessible (readable only after user interaction).
///
/// Progression: 60s → 2min → 5min → 10min, then capped at 30min.
struct InaccessibleBackoff: Sendable, Equatable {
    static let intervals: [TimeInterval] = [60, 120, 300, 600]
    static let cappedInterval: TimeInterval = 1800

    /// Number of consecutive inaccessible reads.
    private(set) var failures = 0

    /// Interval to wait before the next check, given the current failure count.
    var nextInterval: TimeInterval {
        guard failures > 0 else { return Self.intervals[0] }
        let index = failures - 1
        return index < Self.intervals.count ? Self.intervals[index] : Self.cappedInterval
    }

    /// Record another consecutive inaccessible read.
    mutating func recordFailure() {
        failures += 1
    }

    /// Reset after a successful (readable) result.
    mutating func reset() {
        failures = 0
    }
}

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
    private let accessStatus: TokenAccessStatus
    private var registrations: [TokenStorage.Service: Registration] = [:]
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false

    /// Interval between refresh checks (60 seconds).
    private let checkInterval: TimeInterval = 60

    /// Per-service backoff state for inaccessible tokens.
    private var inaccessibleBackoff: [TokenStorage.Service: InaccessibleBackoff] = [:]
    /// Next time each backed-off service is eligible for a check.
    private var nextCheckDate: [TokenStorage.Service: Date] = [:]

    // MARK: - Observability (SCDL-05)
    //
    // Narrow, read-only signals for boot-wiring tests. Deliberately exposes
    // no internal timers, mutable state, or the OAuthManager — just enough
    // to prove `register()`/`start()` were called during app initialization
    // without depending on the live 60s network refresh loop actually firing.

    /// Snapshot of currently registered services.
    var registeredServices: Set<TokenStorage.Service> {
        Set(registrations.keys)
    }

    /// Whether the background refresh loop has been started.
    var isRefreshLoopRunning: Bool {
        isRunning
    }

    // MARK: - Init

    init(tokenStorage: TokenStorage, oauthManager: OAuthManager, accessStatus: TokenAccessStatus) {
        self.tokenStorage = tokenStorage
        self.oauthManager = oauthManager
        self.accessStatus = accessStatus
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
    ///
    /// Services whose tokens are inaccessible are skipped until their
    /// backoff's next-due time (see `InaccessibleBackoff`).
    private func checkAllTokens() async {
        let now = Date()
        for (service, registration) in registrations {
            if let nextDue = nextCheckDate[service], now < nextDue {
                continue
            }
            await checkService(service: service, registration: registration, now: now)
        }
    }

    private func checkService(
        service: TokenStorage.Service,
        registration: Registration,
        now: Date
    ) async {
        do {
            let credentials = try tokenStorage.getCredentials(service: service)

            // A readable result clears any inaccessibility state.
            await resetInaccessibleState(for: service)

            if let credentials, credentials.needsRefresh, let refreshToken = credentials.refreshToken {
                try await performRefresh(
                    registration: registration,
                    refreshToken: refreshToken
                )
            }
        } catch TokenStorage.KeychainError.itemInaccessible(let status) {
            await recordInaccessible(service: service, status: status, now: now)
        } catch {
            AppLogger.shared.warn(
                "Failed to check \(service.displayName) token: \(error.localizedDescription)",
                source: "TokenRefresh"
            )
        }
    }

    /// Mark a service's token as inaccessible and schedule its next check
    /// with exponential backoff.
    private func recordInaccessible(
        service: TokenStorage.Service,
        status: OSStatus,
        now: Date
    ) async {
        var backoff = inaccessibleBackoff[service, default: InaccessibleBackoff()]
        backoff.recordFailure()
        inaccessibleBackoff[service] = backoff

        let interval = backoff.nextInterval
        nextCheckDate[service] = now.addingTimeInterval(interval)

        if backoff.failures == 1 {
            await accessStatus.markInaccessible(service)
            AppLogger.shared.warn(
                "\(service.displayName) token inaccessible (keychain status \(status)) — " +
                "background checks will back off (next in \(Int(interval))s)",
                source: "TokenRefresh"
            )
        } else {
            AppLogger.shared.info(
                "\(service.displayName) token still inaccessible — next check in \(Int(interval))s",
                source: "TokenRefresh"
            )
        }
    }

    /// Clear a service's inaccessibility state after a readable result.
    private func resetInaccessibleState(for service: TokenStorage.Service) async {
        let hadBackoff = inaccessibleBackoff.removeValue(forKey: service) != nil
        let hadNextCheck = nextCheckDate.removeValue(forKey: service) != nil
        let wasInaccessible = await accessStatus.isInaccessible(service)

        guard hadBackoff || hadNextCheck || wasInaccessible else { return }

        if wasInaccessible {
            await accessStatus.markAccessible(service)
        }
        AppLogger.shared.info(
            "\(service.displayName) token accessible again",
            source: "TokenRefresh"
        )
    }

    /// Clear a service's inaccessibility backoff (e.g. after a
    /// user-initiated reconnect made the token readable again).
    func clearBackoff(service: TokenStorage.Service) async {
        inaccessibleBackoff.removeValue(forKey: service)
        nextCheckDate.removeValue(forKey: service)
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

        AppLogger.shared.info(
            "Refreshed \(registration.service.displayName) token",
            source: "TokenRefresh"
        )
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

extension TokenRefreshService: TokenRefreshConfiguring {}
