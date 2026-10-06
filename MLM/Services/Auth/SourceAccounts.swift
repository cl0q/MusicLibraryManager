import Foundation
import Observation

// MARK: - State words (UC §15.3)

/// The state of one source account — exactly three words (UC §15.3, DEC-043):
/// `Connected`, `Disconnected`, `Sign-in expired`. An unreadable keychain sign-in and a
/// refresh the provider rejected are `Sign-in expired`, each with its own sentence.
enum SourceAccountState: Equatable, Sendable {
    case connected
    case disconnected
    case signInExpired(SignInExpiredCause)

    /// The verbatim state word.
    var word: String {
        switch self {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .signInExpired: "Sign-in expired"
        }
    }

    var isSignInExpired: Bool {
        if case .signInExpired = self { return true }
        return false
    }
}

/// Why a sign-in can't be used.
enum SignInExpiredCause: String, Equatable, Sendable {
    /// The access token expired and there is no refresh token to renew it.
    case expired
    /// The provider rejected the refresh token (revoked access, changed password), or a request
    /// with the stored sign-in was refused.
    case refreshRejected
    /// The keychain item can't be read without asking (a changed app signature).
    case keychainLocked
}

/// What the keychain holds for one service, read without prompting.
enum StoredSignIn: Equatable, Sendable {
    case none
    case valid
    /// Expired and no refresh token — nothing can renew it.
    case expiredWithoutRefresh
    /// Present but unreadable without user interaction.
    case unreadable
}

/// What the import sheet (W3-ADD) and other places read; `SourceAccounts` is the one
/// implementation in the app.
@MainActor
protocol SourceAccountStateProviding: AnyObject {
    func state(for service: TokenStorage.Service) -> SourceAccountState
    /// Every service whose sign-in can't be used now (`Sign-in expired`).
    var unusableSignIns: Set<TokenStorage.Service> { get }
}

// MARK: - The one source of truth

/// The account state of every source on this Mac (accounts belong to the Mac, not to a library —
/// A0 D3). Settings ▸ Sources, the sidebar's `‹Source› sign-in expired` line (through
/// `TokenAccessStatus.inaccessibleServices`) and the import sheet all read this object, so they
/// can't disagree (fixes §11.1 #9).
///
/// Inputs:
/// - `reload(using:)` / `apply(_:)` — what the keychain holds (never prompts).
/// - `markKeychainLocked` / `markKeychainReadable` — `TokenRefreshService` and Reconnect.
/// - `recordRefreshRejected` / `recordRefreshSucceeded` — the token refresh, and a request the
///   provider refused with the stored sign-in. A rejection is remembered across launches until
///   the next successful refresh, Connect or Disconnect.
/// - `didConnect` / `didDisconnect` — the user's actions.
@MainActor
@Observable
final class SourceAccounts: SourceAccountStateProviding {
    static let shared = SourceAccounts()

    /// `UserDefaults` key of the remembered rejections (service raw values).
    static let rejectedKey = "sources.refreshRejected"

    /// Keychain readings; a service missing here was never read this session.
    private(set) var stored: [TokenStorage.Service: StoredSignIn] = [:]
    private(set) var keychainLocked: Set<TokenStorage.Service> = []
    private(set) var refreshRejected: Set<TokenStorage.Service>
    /// Whether the keychain was read at least once.
    private(set) var hasLoaded = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.stringArray(forKey: Self.rejectedKey) ?? []
        self.refreshRejected = Set(raw.compactMap(TokenStorage.Service.init(rawValue:)))
    }

    // MARK: Output

    func state(for service: TokenStorage.Service) -> SourceAccountState {
        if refreshRejected.contains(service) { return .signInExpired(.refreshRejected) }
        if keychainLocked.contains(service) { return .signInExpired(.keychainLocked) }
        switch stored[service] ?? .none {
        case .none: return .disconnected
        case .valid: return .connected
        case .expiredWithoutRefresh: return .signInExpired(.expired)
        case .unreadable: return .signInExpired(.keychainLocked)
        }
    }

    var unusableSignIns: Set<TokenStorage.Service> {
        Set(TokenStorage.Service.allCases.filter { state(for: $0).isSignInExpired })
    }

    /// The sentence after the state word in Settings ▸ Sources (UC §15.3).
    ///
    /// - Parameter lastRefreshed: when the source was last refreshed (`last refreshed today, 09:14`).
    static func detail(for state: SourceAccountState, service: TokenStorage.Service,
                       lastRefreshed: String? = nil) -> String {
        switch state {
        case .connected:
            return lastRefreshed.map { "last refreshed \($0)" } ?? ""
        case .disconnected:
            return "imports and refreshes from \(service.displayName) need a sign-in"
        case .signInExpired(.keychainLocked):
            return "MLM can’t read the saved sign-in. Reconnect asks once for permission"
        case .signInExpired(.refreshRejected):
            return "\(service.displayName) refused the saved sign-in · imports and refreshes from \(service.displayName) are paused"
        case .signInExpired(.expired):
            return "imports and refreshes from \(service.displayName) are paused"
        }
    }

    // MARK: Input

    /// Applies keychain readings (from `reload(using:)` or `SourcesViewModel.loadSources()`).
    func apply(_ readings: [TokenStorage.Service: StoredSignIn]) {
        for (service, reading) in readings {
            stored[service] = reading
            if reading == .unreadable {
                keychainLocked.insert(service)
            } else {
                keychainLocked.remove(service)
            }
        }
        hasLoaded = true
    }

    func markKeychainLocked(_ service: TokenStorage.Service) {
        keychainLocked.insert(service)
    }

    func markKeychainReadable(_ service: TokenStorage.Service) {
        keychainLocked.remove(service)
        if stored[service] == .unreadable { stored[service] = .valid }
    }

    func recordRefreshRejected(_ service: TokenStorage.Service) {
        guard refreshRejected.insert(service).inserted else { return }
        persistRejected()
    }

    func recordRefreshSucceeded(_ service: TokenStorage.Service) {
        stored[service] = .valid
        keychainLocked.remove(service)
        guard refreshRejected.remove(service) != nil else { return }
        persistRejected()
    }

    func didConnect(_ service: TokenStorage.Service) {
        recordRefreshSucceeded(service)
    }

    func didDisconnect(_ service: TokenStorage.Service) {
        stored[service] = StoredSignIn.none
        keychainLocked.remove(service)
        if refreshRejected.remove(service) != nil { persistRejected() }
    }

    /// Re-reads every service from the keychain off the main actor. Never prompts.
    func reload(using storage: TokenStorage, now: @escaping @Sendable () -> Date = { Date() }) async {
        let readings = await Task.detached(priority: .utility) {
            var readings: [TokenStorage.Service: StoredSignIn] = [:]
            for service in TokenStorage.Service.allCases {
                readings[service] = Self.reading(storage, service: service, now: now())
            }
            return readings
        }.value
        apply(readings)
    }

    /// One service's keychain state, without prompting.
    nonisolated static func reading(_ storage: TokenStorage, service: TokenStorage.Service, now: Date = Date()) -> StoredSignIn {
        do {
            guard let credentials = try storage.getCredentials(service: service) else { return .none }
            return classify(expiresAt: credentials.expiryDate, hasRefreshToken: credentials.refreshToken != nil, now: now)
        } catch TokenStorage.KeychainError.itemInaccessible {
            return .unreadable
        } catch {
            return .none
        }
    }

    /// An expired token with a refresh token is still usable (the refresh renews it).
    nonisolated static func classify(expiresAt: Date?, hasRefreshToken: Bool, now: Date) -> StoredSignIn {
        guard let expiresAt, expiresAt <= now else { return .valid }
        return hasRefreshToken ? .valid : .expiredWithoutRefresh
    }

    private func persistRejected() {
        defaults.set(refreshRejected.map(\.rawValue).sorted(), forKey: Self.rejectedKey)
    }
}
