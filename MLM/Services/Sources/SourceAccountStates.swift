import Foundation
import Observation

// MARK: - A source account's state, as the Add menu and the import sheets read it (§15.3)

/// One word per state of a source account (UC-STATE-03, §15.3). `keychainLocked` is a
/// `Sign-in expired` with its own sentence: the saved sign-in exists but macOS asks before
/// MLM may read it (A-SRC-KEYCHAIN).
enum SourceAccountState: Equatable, Sendable {
    case connected(account: String?)
    case disconnected
    case signInExpired
    case keychainLocked
    /// Apple Music: listed, nothing to connect yet.
    case notAvailable

    /// The state word (`Connected`, `Disconnected`, `Sign-in expired`, `Not available yet`).
    var word: String {
        switch self {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .signInExpired, .keychainLocked: "Sign-in expired"
        case .notAvailable: "Not available yet"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// A sign-in the user can repair in place (`Reconnect`, `Allow…`).
    var needsSignIn: Bool { self == .signInExpired || self == .keychainLocked }
}

/// Where the Add menu and the import sheets read source accounts from.
///
/// W3-SET: the states come from the one account-state model, `SourceAccounts`;
/// `SourcesViewModelAccountStates` adds the sheets' actions (sign-in, keychain access) on top.
@MainActor
protocol SourceAccountStateReading: AnyObject {
    func state(of service: TokenStorage.Service) -> SourceAccountState
    /// Re-reads the accounts (after a sign-in, a disconnect elsewhere, app activation).
    func reload() async
    /// A request found the sign-in rejected (expired token, HTTP 401): show `Sign-in expired`
    /// until the next successful sign-in.
    func markSignInExpired(_ service: TokenStorage.Service)
    /// Runs the browser sign-in (S-SRC-OAUTH) for `service`; throws on failure or cancel.
    func signIn(_ service: TokenStorage.Service) async throws
    /// One interactive keychain read (A-SRC-KEYCHAIN). `false` = denied: the state becomes
    /// `Sign-in expired` and `Reconnect` (browser sign-in) is offered.
    func allowKeychainAccess(_ service: TokenStorage.Service) async -> Bool
}

extension SourceAccountStateReading {
    /// At least one source can be refreshed (`Refresh from Sources`, UC-TB-05).
    var anyConnected: Bool {
        TokenStorage.Service.allCases.contains { state(of: $0).isConnected }
    }
}

/// The interim reader over `SourcesViewModel` (connection = stored credentials; keychain
/// inaccessibility from `TokenAccessStatus`). Observable so the Add menu and the sheets follow.
@MainActor
@Observable
final class SourcesViewModelAccountStates: SourceAccountStateReading {
    @ObservationIgnored private let viewModel: SourcesViewModel
    @ObservationIgnored private let tokenStorage: TokenStorage?
    @ObservationIgnored private let tokenAccessStatus: TokenAccessStatus?
    @ObservationIgnored private let tokenRefreshService: TokenRefreshService?
    /// Sources a request found rejected, or whose keychain read was denied.
    private var expired: Set<TokenStorage.Service> = []
    /// Bumped on every reload so observers re-read `state(of:)`.
    private(set) var generation = 0

    init(viewModel: SourcesViewModel, tokenStorage: TokenStorage?, tokenAccessStatus: TokenAccessStatus?,
         tokenRefreshService: TokenRefreshService?) {
        self.viewModel = viewModel
        self.tokenStorage = tokenStorage
        self.tokenAccessStatus = tokenAccessStatus
        self.tokenRefreshService = tokenRefreshService
    }

    /// W3-SET: the one account-state model (`SourceAccounts`) answers, so the sheets, Settings ▸
    /// Sources and the sidebar can't disagree (§11.1 #9).
    private var accounts: SourceAccounts { tokenAccessStatus?.accounts ?? .shared }

    func state(of service: TokenStorage.Service) -> SourceAccountState {
        _ = generation
        if service == .appleMusic { return .notAvailable }
        return accounts.state(for: service)
    }

    func reload() async {
        await viewModel.loadSources()
        generation += 1
    }

    func markSignInExpired(_ service: TokenStorage.Service) {
        expired.insert(service)
        accounts.recordRefreshRejected(service)
        generation += 1
    }

    func signIn(_ service: TokenStorage.Service) async throws {
        try await viewModel.signIn(service)
        expired.remove(service)
        accounts.didConnect(service)
        tokenAccessStatus?.markAccessible(service)
        await tokenRefreshService?.clearBackoff(service: service)
        await reload()
    }

    func allowKeychainAccess(_ service: TokenStorage.Service) async -> Bool {
        guard let tokenStorage,
              (try? tokenStorage.getCredentials(service: service, interactive: true)) != nil else {
            expired.insert(service)
            // A denied prompt isn't a refusal by the provider (review S1).
            accounts.recordKeychainDenied(service)
            generation += 1
            return false
        }
        tokenAccessStatus?.markAccessible(service)
        await tokenRefreshService?.clearBackoff(service: service)
        await reload()
        return true
    }
}
