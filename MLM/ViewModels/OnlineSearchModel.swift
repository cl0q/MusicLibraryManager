import Foundation
import Observation

// MARK: - The Online scope (UC-SEARCH-02/03, V-SEARCH.N08–N13, E05/E08)

/// A source the Online scope asks.
enum OnlineSource: String, CaseIterable, Identifiable, Sendable {
    case soundcloud, youtube, spotify, dab

    var id: String { rawValue }

    var name: String {
        switch self {
        case .soundcloud: "SoundCloud"
        case .youtube: "YouTube"
        case .spotify: "Spotify"
        case .dab: "DAB"
        }
    }
}

/// Why a source has no results, in the UC error shape: a sentence and one fix (UC-COPY-11,
/// `search.html` V-SEARCH.E08/N13).
enum OnlineSourceFailure: Error, Equatable, Sendable {
    /// The account's sign-in no longer works.
    case signInExpired
    /// yt-dlp isn't installed (YouTube).
    case toolMissing
    /// No connection to the internet.
    case offline
    /// The source failed for another reason; `details` = the raw text (help only).
    case noAnswer(details: String)

    enum Fix: Equatable, Sendable {
        /// `Reconnect` → Settings ▸ Sources.
        case reconnect
        /// `Open Settings ▸ Sources`.
        case openSettings
        /// `Try Again` → ask this source again.
        case tryAgain

        var title: String {
            switch self {
            case .reconnect: "Reconnect"
            case .openSettings: "Open Settings ▸ Sources"
            case .tryAgain: "Try Again"
            }
        }
    }

    /// `Sign-in expired`, `yt-dlp not found`, `SoundCloud didn’t answer`, `SoundCloud didn’t
    /// answer — no internet connection`.
    func sentence(for source: OnlineSource) -> String {
        switch self {
        case .signInExpired: "Sign-in expired"
        case .toolMissing: "yt-dlp not found"
        case .offline: "\(source.name) didn’t answer — no internet connection"
        case .noAnswer: "\(source.name) didn’t answer"
        }
    }

    var fix: Fix {
        switch self {
        case .signInExpired: .reconnect
        case .toolMissing: .openSettings
        case .offline, .noAnswer: .tryAgain
        }
    }

    var details: String? {
        if case .noAnswer(let details) = self, !details.isEmpty { return details }
        return nil
    }
}

/// One source the Online scope can ask. Implemented over the real clients
/// (`LiveOnlineSearchProviders`) and faked in tests — no test hits the network.
protocol OnlineSearchProviding: Sendable {
    var source: OnlineSource { get }
    /// A problem known without asking (yt-dlp missing); `nil` when the source can be asked.
    var unavailableReason: OnlineSourceFailure? { get }
    /// Results for `query`; throws `OnlineSourceFailure` (other errors count as `noAnswer`).
    func search(_ query: String) async throws -> [RemoteSearchResult]
}

/// One online result row. Transient: it exists in this list only (UC-SEARCH-03).
struct OnlineResultRow: Identifiable, Equatable, Sendable {
    let result: RemoteSearchResult
    /// The library track it already is (`In library`), or the one its download created.
    var libraryTrackID: Int64?

    var id: String { result.id }
}

/// A source's section.
struct OnlineSection: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// `Searching ‹Source›…` (its own line, never a full-pane spinner).
        case searching
        case results([OnlineResultRow])
        case failed(OnlineSourceFailure)
    }

    let source: OnlineSource
    var state: State

    var id: String { source.id }
}

/// The Online scope's state: one section per source in the order they answered, each with its
/// own progress and error. Requests start only on Return (`searchNow`) or after the typing
/// pause (`queryChanged`, `pause`, injectable sleep); a newer query cancels the older one.
/// Nothing here writes to the library — `Download` goes through `SearchDownloadService`.
@MainActor
@Observable
final class OnlineSearchModel {
    /// The query of the sections on screen.
    private(set) var query = ""
    private(set) var sections: [OnlineSection] = []
    /// Results whose download was started here (`Downloading…` while the pipeline runs).
    private(set) var startedDownloads: [String: Int64] = [:]

    @ObservationIgnored var providers: @MainActor () -> [any OnlineSearchProviding] = { [] }
    /// Which results the library already has (`TrackSearchQueries.libraryTrackIDs`); reads only.
    @ObservationIgnored var libraryMatches: @Sendable ([RemoteSearchResult]) async -> [String: Int64] = { _ in [:] }
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private(set) var pauseTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingQuery = ""

    /// How long typing must pause before the sources are asked.
    static let pause: Duration = .milliseconds(800)

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// No source can be asked at all (none connected, no tool): one sentence + Settings.
    var hasNoSources: Bool { providers().isEmpty }

    /// The query changed while `Online` shows: ask after the pause.
    func queryChanged(_ newQuery: String) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        pauseTask?.cancel()
        guard trimmed != query || sections.isEmpty else { return }
        pendingQuery = trimmed
        guard !trimmed.isEmpty else {
            cancel()
            return
        }
        let sleep = self.sleep
        pauseTask = Task { [weak self] in
            do { try await sleep(Self.pause) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.run(trimmed)
        }
    }

    /// Return in the field: ask now.
    func searchNow(_ newQuery: String) {
        pauseTask?.cancel()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel()
            return
        }
        run(trimmed)
    }

    /// `Try Again` in one source's section.
    func retry(_ source: OnlineSource) {
        guard !query.isEmpty, let provider = providers().first(where: { $0.source == source }) else { return }
        update(source, .searching)
        let generation = self.generation
        let query = self.query
        let matches = libraryMatches
        Task { [weak self] in
            let state = await Self.ask(provider, query: query, matches: matches)
            guard let self, self.generation == generation else { return }
            self.update(source, state)
        }
    }

    /// Stop everything (scope left, field cleared).
    func cancel() {
        pauseTask?.cancel()
        searchTask?.cancel()
        generation += 1
        query = ""
        sections = []
    }

    /// `Download` on a row was taken by the pipeline.
    func downloadStarted(resultID: String, trackID: Int64) {
        startedDownloads[resultID] = trackID
        for index in sections.indices {
            guard case .results(var rows) = sections[index].state,
                  let row = rows.firstIndex(where: { $0.id == resultID }) else { continue }
            rows[row].libraryTrackID = trackID
            sections[index].state = .results(rows)
        }
    }

    // MARK: Running

    private func run(_ query: String) {
        searchTask?.cancel()
        generation += 1
        let generation = self.generation
        self.query = query
        let providers = self.providers()
        sections = providers.map { provider in
            OnlineSection(source: provider.source, state: provider.unavailableReason.map(OnlineSection.State.failed) ?? .searching)
        }
        let askable = providers.filter { $0.unavailableReason == nil }
        let matches = libraryMatches
        searchTask = Task { [weak self] in
            await withTaskGroup(of: (OnlineSource, OnlineSection.State).self) { group in
                for provider in askable {
                    group.addTask {
                        (provider.source, await Self.ask(provider, query: query, matches: matches))
                    }
                }
                for await (source, state) in group {
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.answer(source, state)
                }
            }
        }
    }

    nonisolated private static func ask(
        _ provider: any OnlineSearchProviding,
        query: String,
        matches: @Sendable ([RemoteSearchResult]) async -> [String: Int64]
    ) async -> OnlineSection.State {
        do {
            let results = try await provider.search(query)
            let known = await matches(results)
            return .results(results.map { OnlineResultRow(result: $0, libraryTrackID: known[$0.id]) })
        } catch let failure as OnlineSourceFailure {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(.noAnswer(details: ""))
        } catch {
            return .failed(.noAnswer(details: error.localizedDescription))
        }
    }

    /// A source answered: its section moves up behind the sources that answered before it.
    private func answer(_ source: OnlineSource, _ state: OnlineSection.State) {
        guard let index = sections.firstIndex(where: { $0.source == source }) else { return }
        var section = sections.remove(at: index)
        section.state = state
        let answered = sections.firstIndex { $0.state == .searching } ?? sections.count
        sections.insert(section, at: answered)
    }

    private func update(_ source: OnlineSource, _ state: OnlineSection.State) {
        guard let index = sections.firstIndex(where: { $0.source == source }) else { return }
        sections[index].state = state
    }
}
