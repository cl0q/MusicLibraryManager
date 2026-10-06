import Foundation

// MARK: - Downloads started from search (UC-SEARCH-03, DEC-013, fixes PP-MAIN-04)

/// The one way something found by search becomes a library track: the user pressed
/// `Download` (an online result) or took a link's action. Until then nothing is written. The
/// new track keeps an **empty album** unless real metadata provides one — never the source
/// name (DEC-013, UC-TABLE-11).
enum SearchDownloadOutcome: Equatable, Sendable {
    /// The track row exists and its download was handed to the pipeline.
    case started(trackID: Int64, title: String)
    /// The link is already a library track (nothing was written).
    case alreadyInLibrary(trackID: Int64)
    /// Another download batch is running (nothing was written).
    case busy
    /// The track couldn't be written; the cause in plain words.
    case failed(String)
}

/// Hands one track to the existing download pipeline.
@MainActor
protocol TrackDownloadStarting {
    /// A batch is running; the pipeline would reject another one.
    var isBusy: Bool { get }
    func start(_ track: Track, preferredSource: DownloadOrchestrator.PreferredSource, artworkURL: String?)
}

/// The app's starter: `DownloadViewModel.downloadTracks` (the orchestrator's chain).
@MainActor
struct LiveTrackDownloadStarter: TrackDownloadStarting {
    var container: DependencyContainer = .shared

    /// Never busy since W3-ACT: a download requested while another runs queues behind it in
    /// the download lane (PP-ACTIVITY-05, IMP-039); `nil` = no library is open.
    var isBusy: Bool { container.downloadViewModel == nil }

    /// One Activity operation `Download “‹title›”` with the track as subject (W3-ADD).
    func start(_ track: Track, preferredSource: DownloadOrchestrator.PreferredSource, artworkURL: String?) {
        guard let downloads = container.downloadViewModel else { return }
        let context = DownloadActivityContext(title: "Download “\(track.title)”",
                                              subject: track.id.map { .tracks([$0]) })
        Task { await downloads.downloadTracks([track], preferredSource: preferredSource, artworkURL: artworkURL,
                                              context: context) }
    }
}

/// Writes the track row for an explicit download (and only then).
protocol SearchTrackWriting: Sendable {
    func existingTrackID(forLink url: String) async throws -> Int64?
    /// A not-downloaded track for a link, linked to its source.
    func insertLinkedTrack(url: String, source: LinkSource, metadata: LinkMetadata?) async throws -> Track
    /// The canonical track of an online result (provider identity), created if absent.
    func materialize(_ result: RemoteSearchResult) async throws -> Track?
}

/// The app's writer over the repositories.
struct LiveSearchTrackWriter: SearchTrackWriting {
    let trackRepository: TrackRepository
    let sourceRepository: SourceRepository
    let queries: TrackSearchQueries?

    func existingTrackID(forLink url: String) async throws -> Int64? {
        try await queries?.trackID(forLink: url)
    }

    func insertLinkedTrack(url: String, source: LinkSource, metadata: LinkMetadata?) async throws -> Track {
        let track = SearchDownloadService.linkedTrack(url: url, source: source, metadata: metadata)
        let inserted = try await trackRepository.insert(track)
        if let trackID = inserted.id {
            let row = try await sourceRepository.upsert(name: source.storedName, userId: "link")
            if let sourceID = row.id {
                try await sourceRepository.linkTrackToSource(trackId: trackID, sourceId: sourceID, externalId: url)
            }
        }
        return inserted
    }

    func materialize(_ result: RemoteSearchResult) async throws -> Track? {
        try await RemoteTrackMaterializer(trackRepository: trackRepository, sourceRepository: sourceRepository)
            .materialize([result]).first
    }
}

/// Download a link or one online result through the existing pipeline. Ported from the
/// universal search panel's handler (`handleUniversalDownload`, removed with
/// S-SEARCH-UNIVERSAL) — minus its source-as-album write.
@MainActor
final class SearchDownloadService {
    private let writer: any SearchTrackWriting
    private let starter: any TrackDownloadStarting

    init(writer: any SearchTrackWriting, starter: any TrackDownloadStarting) {
        self.writer = writer
        self.starter = starter
    }

    /// The app's service for the open library; `nil` before a library is open.
    static func live(_ container: DependencyContainer = .shared) -> SearchDownloadService? {
        guard let tracks = container.trackRepository, let sources = container.sourceRepository else { return nil }
        return SearchDownloadService(
            writer: LiveSearchTrackWriter(trackRepository: tracks, sourceRepository: sources,
                                          queries: TrackSearchQueries.current(container)),
            starter: LiveTrackDownloadStarter(container: container)
        )
    }

    /// `Download started — “‹title›”` (UC-STATUS-05 shape).
    static func startedMessage(_ title: String) -> String { "Download started — “\(title)”" }

    /// `“‹title›” is already in your library`.
    static func alreadyInLibraryMessage(_ title: String) -> String { "“\(title)” is already in your library" }

    /// `Couldn’t add the track — ‹cause›`.
    static func failedMessage(_ cause: String) -> String { "Couldn’t add the track — \(cause)" }

    /// The status-bar line for an outcome (`title` = what the user saw).
    static func message(for outcome: SearchDownloadOutcome, title: String) -> String {
        switch outcome {
        case .started(_, let title): startedMessage(title)
        case .alreadyInLibrary: alreadyInLibraryMessage(title)
        case .busy: TrackCommandState.downloadBusyReason
        case .failed(let cause): failedMessage(cause)
        }
    }

    /// The row a link becomes: not downloaded, album empty, format = the source word (the
    /// importers' convention until the file arrives), the link as original path.
    nonisolated static func linkedTrack(url: String, source: LinkSource, metadata: LinkMetadata?) -> Track {
        let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var track = Track(
            artist: metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            album: "",
            title: (title?.isEmpty == false ? title : nil) ?? LinkSuggestion.shortURL(url),
            format: source.storedName,
            originalPath: url
        )
        track.duration = metadata?.durationSeconds
        return track
    }

    /// A link's track download (YouTube video, SoundCloud track).
    func download(_ link: LinkSuggestion, metadata: LinkMetadata?) async -> SearchDownloadOutcome {
        guard case .track(let source, let url) = link else {
            return .failed("this link isn’t a single track")
        }
        do {
            if let existing = try await writer.existingTrackID(forLink: url) {
                return .alreadyInLibrary(trackID: existing)
            }
            guard !starter.isBusy else { return .busy }
            let track = try await writer.insertLinkedTrack(url: url, source: source, metadata: metadata)
            guard let id = track.id else { return .failed("the library didn’t take the track") }
            starter.start(track, preferredSource: source.preferredDownloadSource, artworkURL: metadata?.artworkURL)
            return .started(trackID: id, title: track.title)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `Download` on an online result.
    func download(_ result: RemoteSearchResult) async -> SearchDownloadOutcome {
        guard !starter.isBusy else { return .busy }
        do {
            guard let track = try await writer.materialize(result), let id = track.id else {
                return .failed("the result has no source identity")
            }
            guard track.isRemote else { return .alreadyInLibrary(trackID: id) }
            starter.start(track, preferredSource: result.source.preferredSource, artworkURL: nil)
            return .started(trackID: id, title: track.title)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
