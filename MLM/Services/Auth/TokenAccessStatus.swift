import Foundation

/// Observable per-service keychain access state.
///
/// `TokenRefreshService` updates this on the main actor when a service's token becomes
/// (in)accessible or a refresh is rejected; `SourcesViewModel` reads it so the Sources cards
/// can show a one-line notice.
///
/// W3-SET: when attached to `SourceAccounts` (the app does that), every change is forwarded to
/// that one source of truth, and `inaccessibleServices` answers with its `unusableSignIns` —
/// so the sidebar's `‹Source› sign-in expired` line also covers a rejected refresh.
@MainActor
@Observable
final class TokenAccessStatus {
    /// Services whose stored token currently needs user interaction to read.
    private(set) var keychainLockedServices: Set<TokenStorage.Service> = []

    @ObservationIgnored let accounts: SourceAccounts?

    init(accounts: SourceAccounts? = nil) {
        self.accounts = accounts
    }

    /// Services whose sign-in can't be used now: an unreadable keychain item, and — with
    /// `SourceAccounts` attached — a refresh the provider rejected or an expired sign-in.
    var inaccessibleServices: Set<TokenStorage.Service> {
        accounts?.unusableSignIns ?? keychainLockedServices
    }

    /// Whether the keychain item needs user interaction to read.
    func isInaccessible(_ service: TokenStorage.Service) -> Bool {
        keychainLockedServices.contains(service)
    }

    func markInaccessible(_ service: TokenStorage.Service) {
        keychainLockedServices.insert(service)
        accounts?.markKeychainLocked(service)
    }

    func markAccessible(_ service: TokenStorage.Service) {
        keychainLockedServices.remove(service)
        accounts?.markKeychainReadable(service)
    }

    /// The provider refused the refresh token (W3-SET): `Sign-in expired` until a refresh
    /// succeeds or the user reconnects.
    func recordRefreshRejected(_ service: TokenStorage.Service) {
        accounts?.recordRefreshRejected(service)
    }

    func recordRefreshSucceeded(_ service: TokenStorage.Service) {
        accounts?.recordRefreshSucceeded(service)
    }
}
