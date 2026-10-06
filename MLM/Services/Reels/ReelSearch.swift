import Foundation
import Network

// MARK: - Results per source (V-REELS.E20, N07, N08)

/// The sources the unified search asks, in the order the groups are listed.
enum ReelSource: String, CaseIterable, Identifiable, Sendable {
    case soundCloud, youtube, dab, qobuz

    var id: String { rawValue }

    var word: String {
        switch self {
        case .soundCloud: "SoundCloud"
        case .youtube: "YouTube"
        case .dab: "DAB"
        case .qobuz: "Qobuz"
        }
    }

    /// `SoundCloud, YouTube, DAB and Qobuz` — the sources a search asks (V-REELS.E19).
    static var sentenceList: String {
        let words = allCases.map(\.word)
        return words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }
}

/// One online match. Plain data: the live downloader turns it into a library track.
struct ReelSearchResult: Identifiable, Equatable, Hashable, Sendable {
    let source: ReelSource
    /// The id within the source (track id, video id).
    let externalID: String
    let artist: String
    let title: String
    let durationSeconds: Int?
    /// A page or permalink when the source gives one.
    let sourceURL: String?

    var id: String { "\(source.rawValue)-\(externalID)" }

    /// `Fred again.. · 4:12`.
    var detailLine: String {
        guard let durationSeconds else { return artist }
        let hours = durationSeconds / 3600
        let time = hours > 0
            ? String(format: "%d:%02d:%02d", hours, durationSeconds % 3600 / 60, durationSeconds % 60)
            : String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
        return "\(artist) · \(time)"
    }
}

/// A source's results; with none the group says `No matches` instead of vanishing.
struct ReelSearchGroup: Identifiable, Equatable, Sendable {
    let source: ReelSource
    var results: [ReelSearchResult]

    var id: String { source.rawValue }
    var countWord: String { results.isEmpty ? "No matches" : "\(results.count)" }
}

enum ReelSearchOutcome: Equatable, Sendable {
    /// One group per source, always all of them.
    case groups([ReelSearchGroup])
    /// This Mac is offline (V-REELS.N08) — not "no results".
    case offline

    var hasMatches: Bool {
        if case .groups(let groups) = self { return groups.contains { !$0.results.isEmpty } }
        return false
    }
}

protocol ReelSearching: Sendable {
    func search(artist: String, title: String) async -> ReelSearchOutcome
}

enum ReelSearch {
    /// `Fred again.. Delilah` — the query text of the two fields.
    static func query(artist: String, title: String) -> String {
        [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The unified search's four lists as one group per source, in `ReelSource` order.
    static func groups(from results: UnifiedSearchResults) -> [ReelSearchGroup] {
        let soundCloud = results.soundCloudTracks.map { track in
            ReelSearchResult(source: .soundCloud, externalID: String(track.id), artist: track.user?.username ?? "Unknown",
                             title: track.title, durationSeconds: track.duration.map { $0 / 1000 }, sourceURL: track.permalinkUrl)
        }
        let youtube = results.youtubeTracks.map { track in
            ReelSearchResult(source: .youtube, externalID: track.id, artist: track.uploader ?? "Unknown",
                             title: track.title, durationSeconds: track.duration.map { Int($0) }, sourceURL: track.watchUrl)
        }
        let dab = results.dabTracks.map { track in
            ReelSearchResult(source: .dab, externalID: String(track.id), artist: track.artist, title: track.title,
                             durationSeconds: track.duration.map { Int($0) }, sourceURL: nil)
        }
        let qobuz = results.squidTracks.map { track in
            ReelSearchResult(source: .qobuz, externalID: track.id, artist: track.artist, title: track.title,
                             durationSeconds: track.durationSec, sourceURL: nil)
        }
        return [
            ReelSearchGroup(source: .soundCloud, results: soundCloud),
            ReelSearchGroup(source: .youtube, results: youtube),
            ReelSearchGroup(source: .dab, results: dab),
            ReelSearchGroup(source: .qobuz, results: qobuz),
        ]
    }

    /// `Searching SoundCloud, YouTube, DAB and Qobuz for “‹query›”…` (V-REELS, mockup `doSearch`).
    static func searchingSentence(_ query: String) -> String {
        "Searching \(ReelSource.sentenceList) for “\(query)”…"
    }
}

/// Network reachability, answered once.
enum NetworkReachability {
    static func isOnline() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "mlm.reels.reachability")
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.take() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}

/// The unified search over the four sources; offline is told apart before searching.
struct LiveReelSearch: ReelSearching {
    /// Runs the search for a query (`UnifiedSearchService.search` in the app).
    var run: @Sendable (String) async -> UnifiedSearchResults
    var isOnline: @Sendable () async -> Bool = { await NetworkReachability.isOnline() }

    init(service: UnifiedSearchService, isOnline: @escaping @Sendable () async -> Bool = { await NetworkReachability.isOnline() }) {
        self.run = { await service.search(query: $0) }
        self.isOnline = isOnline
    }

    init(run: @escaping @Sendable (String) async -> UnifiedSearchResults,
         isOnline: @escaping @Sendable () async -> Bool = { await NetworkReachability.isOnline() }) {
        self.run = run
        self.isOnline = isOnline
    }

    func search(artist: String, title: String) async -> ReelSearchOutcome {
        guard await isOnline() else { return .offline }
        return .groups(ReelSearch.groups(from: await run(ReelSearch.query(artist: artist, title: title))))
    }
}
