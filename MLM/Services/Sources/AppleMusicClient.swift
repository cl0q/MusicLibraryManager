import Foundation

/// Apple Music client using MusicKit framework.
///
/// Phase 10 — Uses native MusicKit (no webview scraping like the Tauri app).
///
/// ## Architecture
/// - Authorization via `MusicAuthorization.request()`
/// - Library access via `MusicLibrary` / `MusicCatalogSearchRequest`
/// - No OAuth tokens needed — uses system-level Apple Music authorization
///
/// ## Note
/// MusicKit requires:
/// - Apple Music entitlement in the app
/// - User has Apple Music subscription
/// - macOS 12+ (Monterey)
final class AppleMusicClient {

    // MARK: - Dependencies

    private let tokenStorage: TokenStorage
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository

    // MARK: - Init

    init(
        tokenStorage: TokenStorage,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository
    ) {
        self.tokenStorage = tokenStorage
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
    }

    // MARK: - Authorization

    /// Request Apple Music authorization.
    ///
    /// Uses MusicKit's `MusicAuthorization.request()` which shows
    /// the system authorization dialog.
    @MainActor
    func authorize() async throws {
        // MusicKit authorization will be implemented here
        // For now, this is a stub
        throw AppleMusicError.notImplemented
    }

    /// Check if Apple Music is authorized.
    var isAuthorized: Bool {
        // Will check MusicAuthorization.currentStatus
        false
    }

    /// Disconnect Apple Music.
    func disconnect() throws {
        try tokenStorage.deleteCredentials(service: .appleMusic)
    }

    // MARK: - Sync

    /// Sync library songs from Apple Music.
    @discardableResult
    func syncLibrary() async throws -> Int {
        // Stub — will use MusicLibrary to fetch user's songs
        print("[AppleMusic] syncLibrary not yet implemented")
        return 0
    }

    /// Sync playlists from Apple Music.
    @discardableResult
    func syncPlaylists() async throws -> Int {
        print("[AppleMusic] syncPlaylists not yet implemented")
        return 0
    }

    // MARK: - Errors

    enum AppleMusicError: LocalizedError {
        case notImplemented
        case notAuthorized
        case noSubscription

        var errorDescription: String? {
            switch self {
            case .notImplemented: "Apple Music integration not yet implemented (Phase 10)"
            case .notAuthorized: "Apple Music not authorized"
            case .noSubscription: "Apple Music subscription required"
            }
        }
    }
}
