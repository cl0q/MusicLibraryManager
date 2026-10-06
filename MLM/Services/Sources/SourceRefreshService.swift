import Foundation
import Observation

// MARK: - Refresh from Sources (P-ADDMENU.N08, DEC-023, UC-TB-05)

/// Pulls one source's new likes into All Tracks (as `Not downloaded`) and refreshes its linked
/// account playlists. Returns the number of new tracks. Faked in tests (no network).
@MainActor
protocol SourceLibraryRefreshing: AnyObject {
    func refresh(_ service: TokenStorage.Service) async throws -> Int
}

/// The app's refresher: the source clients' existing likes / playlists sync (moved here from
/// `SourcesViewModel.syncSource`, behaviour unchanged).
@MainActor
final class LiveSourceLibraryRefresher: SourceLibraryRefreshing {
    private let soundCloud: SoundCloudClient
    private let spotify: SpotifyClient
    private let appleMusic: AppleMusicClient

    init(tokenStorage: TokenStorage, oauthManager: OAuthManager, trackRepository: TrackRepository,
         sourceRepository: SourceRepository, playlistRepository: PlaylistRepository?) {
        soundCloud = SoundCloudClient(tokenStorage: tokenStorage, oauthManager: oauthManager,
                                      trackRepository: trackRepository, sourceRepository: sourceRepository,
                                      playlistRepository: playlistRepository)
        spotify = SpotifyClient(tokenStorage: tokenStorage, oauthManager: oauthManager,
                                trackRepository: trackRepository, sourceRepository: sourceRepository)
        appleMusic = AppleMusicClient(tokenStorage: tokenStorage, trackRepository: trackRepository,
                                      sourceRepository: sourceRepository)
    }

    func refresh(_ service: TokenStorage.Service) async throws -> Int {
        switch service {
        case .soundcloud:
            let new = try await soundCloud.syncLikes()
            _ = try await soundCloud.syncPlaylists()
            return new
        case .spotify:
            let new = try await spotify.syncLikedSongs()
            _ = try await spotify.syncPlaylists()
            return new
        case .appleMusic:
            let new = try await appleMusic.syncLibrary()
            _ = try await appleMusic.syncPlaylists()
            return new
        }
    }
}

/// What one source's refresh came to.
enum SourceRefreshOutcome: Equatable, Sendable {
    case refreshed(newTracks: Int)
    case signInExpired
    case failed(String)
    /// Already refreshing (a second request for the same source does nothing).
    case alreadyRunning
}

/// Runs `Refresh from Sources` and `Refresh from ‹Source›`: one Activity operation per source
/// (`Refresh from SoundCloud`, W3-ACT kind `.sourceRefresh`), its result in the status bar via
/// the center (UC-JOB-08). Never removes anything and never downloads. Callable from the Add
/// menu, the Library menu, Settings ▸ Sources and (later) a schedule.
@MainActor
@Observable
final class SourceRefreshService {
    /// Sources being refreshed now.
    private(set) var refreshing: Set<TokenStorage.Service> = []

    @ObservationIgnored private let refresher: any SourceLibraryRefreshing
    @ObservationIgnored private let activity: ActivityCenter
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// Told when a source's sign-in was rejected (the account reader shows `Sign-in expired`).
    @ObservationIgnored var onSignInExpired: (TokenStorage.Service) -> Void = { _ in }

    init(refresher: any SourceLibraryRefreshing, activity: ActivityCenter = .shared,
         notificationCenter: NotificationCenter = .default) {
        self.refresher = refresher
        self.activity = activity
        self.notificationCenter = notificationCenter
    }

    /// The app's service for the open library; `nil` before a library is open.
    static func live(_ container: DependencyContainer = .shared) -> SourceRefreshService? {
        guard let tokens = container.tokenStorage, let oauth = container.oauthManager,
              let tracks = container.trackRepository, let sources = container.sourceRepository else { return nil }
        return SourceRefreshService(refresher: LiveSourceLibraryRefresher(
            tokenStorage: tokens, oauthManager: oauth, trackRepository: tracks,
            sourceRepository: sources, playlistRepository: container.playlistRepository))
    }

    /// `Refresh from Sources`: every connected source, one after the other.
    @discardableResult
    func refreshAll(_ services: [TokenStorage.Service]) async -> [TokenStorage.Service: SourceRefreshOutcome] {
        var outcomes: [TokenStorage.Service: SourceRefreshOutcome] = [:]
        for service in services {
            outcomes[service] = await refresh(service)
        }
        return outcomes
    }

    /// `Refresh from ‹Source›` — one Activity operation.
    @discardableResult
    func refresh(_ service: TokenStorage.Service) async -> SourceRefreshOutcome {
        guard !refreshing.contains(service) else { return .alreadyRunning }
        refreshing.insert(service)
        defer { refreshing.remove(service) }

        let name = service.displayName
        let job = activity.begin(.sourceRefresh, title: "Refresh from \(name)",
                                 subject: .settings(.sources), messageName: "Refresh from \(name)")
        do {
            let newTracks = try await refresher.refresh(service)
            job.finish(ActivityResult(counts: [ActivityCount(.done, newTracks, newTracks == 1 ? "new track" : "new tracks")]))
            if newTracks > 0 {
                notificationCenter.post(name: .libraryDidImport, object: nil,
                                        userInfo: ["succeeded": newTracks, "skipped": 0])
            }
            return .refreshed(newTracks: newTracks)
        } catch where SourceSignInProblem.isRejectedSignIn(error) {
            onSignInExpired(service)
            job.fail(cause: "Sign-in expired (\(name))", fix: .reconnect(source: name))
            return .signInExpired
        } catch {
            let cause = SourceSignInProblem.plainCause(error, source: name)
            job.fail(cause: cause, fix: .runAgain)
            return .failed(cause)
        }
    }
}

/// Recognising a rejected sign-in among the source clients' errors, and plain causes.
enum SourceSignInProblem {
    static func isRejectedSignIn(_ error: Error) -> Bool {
        switch error {
        case SoundCloudClient.SoundCloudError.tokenExpired, SoundCloudClient.SoundCloudError.notAuthenticated:
            return true
        case SoundCloudClient.SoundCloudError.apiError(let status, _):
            return status == 401
        case SpotifyClient.SpotifyError.notAuthenticated:
            return true
        case SpotifyClient.SpotifyError.apiError(let status, _):
            return status == 401
        default:
            return false
        }
    }

    /// `SoundCloud didn’t answer` for transport failures; the error's own words otherwise.
    static func plainCause(_ error: Error, source: String) -> String {
        if error is URLError { return "\(source) didn’t answer" }
        return error.localizedDescription
    }
}
