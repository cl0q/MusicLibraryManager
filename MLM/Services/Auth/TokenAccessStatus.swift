import Foundation

/// Observable per-service keychain access state.
///
/// `TokenRefreshService` updates this on the main actor when a service's
/// token becomes (in)accessible; `SourcesViewModel` reads it so the Sources
/// cards can show a one-line amber notice.
@MainActor
@Observable
final class TokenAccessStatus {
    /// Services whose stored token currently needs user interaction to read.
    private(set) var inaccessibleServices: Set<TokenStorage.Service> = []

    func isInaccessible(_ service: TokenStorage.Service) -> Bool {
        inaccessibleServices.contains(service)
    }

    func markInaccessible(_ service: TokenStorage.Service) {
        inaccessibleServices.insert(service)
    }

    func markAccessible(_ service: TokenStorage.Service) {
        inaccessibleServices.remove(service)
    }
}
