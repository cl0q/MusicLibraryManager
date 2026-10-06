import Foundation
import GRDB
import Observation

// MARK: - Refresh from Sources (P-ADDMENU.N08, DEC-023, UC-TB-05)

/// What one source's refresh did.
struct SourceRefreshSummary: Equatable, Sendable {
    /// Tracks new to the library (added as `Not downloaded`).
    var newTracks = 0
    /// Linked playlists that got tracks.
    var playlistsUpdated = 0
    /// Linked playlists whose source list couldn't be read.
    var failedPlaylists: [String] = []
}

/// Refreshes one source for `Refresh from Sources`. Faked in tests (no network).
@MainActor
protocol SourceLibraryRefreshing: AnyObject {
    func refresh(_ service: TokenStorage.Service) async throws -> SourceRefreshSummary
}

/// The app's refresher (W3-ADD review H1): for one connected source it refreshes **only the
/// playlists the user linked to that source, add-only** — each through `PlaylistImporter` with
/// the playlist as target and no download, so tracks missing from the playlist are appended,
/// nothing is removed or reordered, no album is written, no playlist is created and no other
/// playlist is (re)linked. It never calls the clients' `syncPlaylists()` (which created a
/// playlist per account set, adopted same-named playlists and replaced track lists).
///
/// Likes are **not** part of it yet: the likes sync (`SoundCloudClient.syncLikes`) still
/// replaces the Liked playlist and writes an album; it joins here once the W3-PL fix round
/// makes it append-only (`// LIKES:` below). The Liked playlist keeps its own `Refresh from
/// ‹Source›` on the playlist page.
@MainActor
final class LinkedPlaylistsRefresher: SourceLibraryRefreshing {
    typealias ListTracks = @MainActor (Playlist, Source) async throws -> [RemotePlaylistTrack]

    private let queries: ImportLibraryQueries
    private let importer: PlaylistImporter
    private let listTracks: ListTracks

    init(database: any DatabaseWriter, listTracks: @escaping ListTracks, notificationCenter: NotificationCenter = .default) {
        queries = ImportLibraryQueries(database: database)
        importer = PlaylistImporter(database: database, downloads: NoPlaylistDownloads(), notificationCenter: notificationCenter)
        self.listTracks = listTracks
    }

    /// The real source lists: `PlaylistRefreshService.Remote.live(_:).listTracks` (W3-PL), as is.
    static func live(_ container: DependencyContainer) -> LinkedPlaylistsRefresher? {
        guard let database = container.databaseManager else { return nil }
        return LinkedPlaylistsRefresher(database: database.pool,
                                        listTracks: PlaylistRefreshService.Remote.live(container).listTracks)
    }

    func refresh(_ service: TokenStorage.Service) async throws -> SourceRefreshSummary {
        var summary = SourceRefreshSummary()
        guard let link = Self.linkSource(service) else { return summary }
        // LIKES: add the append-only likes refresh here (W3-PL fix round).
        for (playlist, source) in try await queries.linkedPlaylists(sourceName: link.storedName) {
            guard let playlistID = playlist.id, let sourceID = source.id, let externalID = playlist.externalId else { continue }
            do {
                let remote = try await listTracks(playlist, source)
                let preview = RemotePlaylistPreview(sourceName: link.rawValue, externalID: externalID,
                                                    title: playlist.name, tracks: remote)
                let request = PlaylistImportRequest(preview: preview, tracks: remote, source: link,
                                                    target: .existing(id: playlistID, name: playlist.name),
                                                    keepLinked: true, downloadNow: false)
                let outcome = try await importer.run(request, sourceRowID: { sourceID })
                summary.newTracks += outcome.addedToLibrary
                if outcome.addedToPlaylist > 0 { summary.playlistsUpdated += 1 }
            } catch where SourceSignInProblem.isRejectedSignIn(error) {
                throw error
            } catch {
                AppLogger.shared.error("Refreshing “\(playlist.name)” failed: \(error)", source: "Sources")
                summary.failedPlaylists.append(playlist.name)
            }
        }
        return summary
    }

    static func linkSource(_ service: TokenStorage.Service) -> LinkSource? {
        switch service {
        case .soundcloud: .soundcloud
        case .spotify: .spotify
        case .appleMusic: nil
        }
    }
}

/// A refresh never downloads (`Download new tracks automatically` is W3-SET's setting).
@MainActor
private final class NoPlaylistDownloads: PlaylistDownloadStarting {
    func startDownloads(_ tracks: [Track], preferredSource: DownloadOrchestrator.PreferredSource,
                        playlistID: Int64, playlistName: String) {}
}

/// What one source's refresh came to.
enum SourceRefreshOutcome: Equatable, Sendable {
    case refreshed(SourceRefreshSummary)
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
        guard let refresher = LinkedPlaylistsRefresher.live(container) else { return nil }
        return SourceRefreshService(refresher: refresher)
    }

    /// `6 new tracks · 2 playlists updated · 1 playlist couldn’t be read`.
    static func result(_ summary: SourceRefreshSummary) -> ActivityResult {
        var counts = [ActivityCount(.done, summary.newTracks, summary.newTracks == 1 ? "new track" : "new tracks")]
        if summary.playlistsUpdated > 0 {
            counts.append(ActivityCount(.done, summary.playlistsUpdated,
                                        summary.playlistsUpdated == 1 ? "playlist updated" : "playlists updated"))
        }
        var groups: [ActivityFailureGroup] = []
        if !summary.failedPlaylists.isEmpty {
            let n = summary.failedPlaylists.count
            counts.append(ActivityCount(.failed, n, n == 1 ? "playlist couldn’t be read" : "playlists couldn’t be read"))
            groups.append(ActivityFailureGroup(cause: "The source didn’t answer for “\(summary.failedPlaylists[0])”"
                                               + (n > 1 ? " and \(n - 1) more" : ""),
                                               count: n, fix: .runAgain, isRetryable: true))
        }
        return ActivityResult(counts: counts, failureGroups: groups)
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
            let summary = try await refresher.refresh(service)
            job.finish(Self.result(summary))
            if summary.newTracks > 0 {
                notificationCenter.post(name: .libraryDidImport, object: nil,
                                        userInfo: ["succeeded": summary.newTracks, "skipped": 0])
            }
            return .refreshed(summary)
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

    /// `SoundCloud didn’t answer` for transport failures; a plain cause otherwise — never
    /// database text (UC-COPY).
    static func plainCause(_ error: Error, source: String) -> String {
        if error is URLError { return "\(source) didn’t answer" }
        if let plain = error as? PlainCauseError { return plain.plainCause }
        if error is DatabaseError { return PlaylistImportError.libraryNotWritable.plainCause }
        return error.localizedDescription
    }
}
