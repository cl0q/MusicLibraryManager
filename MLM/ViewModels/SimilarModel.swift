import Foundation
import Observation

/// `Similar to “‹track›”` (V-SIMILAR, DEC-030): the tracks of the library that sound like the seed,
/// and the suggestions SoundCloud or Last.fm have for it. Nothing here removes a track from the
/// library (V-SIMILAR.N07, PP-INSPECTOR-21): suggestions are only ever added — `Download` holds
/// them in Discover ▸ Recommendations (flag set), `Keep` downloads them straight into the library.
@MainActor
@Observable
final class SimilarModel {
    struct Dependencies {
        var fetchTrack: @MainActor (_ id: Int64) async -> Track?
        /// The ranked library matches with their score (0…1); held and hidden tracks excluded.
        var similarInLibrary: @MainActor (_ seedID: Int64, _ limit: Int) async -> [(track: Track, score: Float)]
        var isAnalysed: @MainActor (_ trackID: Int64) async -> Bool
        var analyse: @MainActor (_ track: Track) async -> Void
        var swarm: any SwarmRecommending
        /// Hand a suggestion to the download pipeline: `hold` = wait in Discover until kept.
        var startDownload: @MainActor (_ recommendation: SwarmRecommendation, _ seed: Track, _ hold: Bool) -> Void
        /// The pipeline's own state of a suggestion (`Queued` · `Downloading…`).
        var pipelineStatus: @MainActor (_ recommendation: SwarmRecommendation) -> DownloadViewModel.DiscoveryStatus?
        /// Where a suggestion already is: held in Discover, or in the library.
        var placement: @MainActor (_ recommendation: SwarmRecommendation, _ seedID: Int64) async -> OnlineRow.Placement?
    }

    // MARK: Library section

    enum SeedState: Equatable {
        case loading
        case missing
        case notAnalysed
        case ready
    }

    private(set) var seed: Track?
    private(set) var seedState: SeedState = .loading
    /// The library matches in rank order with their `Match` percentage.
    private(set) var inLibrary: [Track] = []
    private(set) var matches: [Int64: Int] = [:]
    private(set) var isLoadingLibrary = false
    /// `Top 12 by sound`.
    static let libraryLimit = 12
    /// Info ▸ Audio shows the five nearest (P-INSPECTOR-SIMILAR); `Show All` opens this view.
    nonisolated static let inspectorLimit = 5

    /// `Match` percentage of a 0…1 score.
    nonisolated static func matchPercent(_ score: Float) -> Int { Int((max(0, min(1, score)) * 100).rounded()) }

    /// The nearest in-library matches for Info: the same query as `loadLibrary` (no network),
    /// the first `limit` in rank order with their `Match` percentage; none for a track that
    /// isn't analysed (its score would mean nothing).
    static func nearest(to seedID: Int64, limit: Int = inspectorLimit,
                        dependencies: Dependencies) async -> [(track: Track, match: Int)] {
        guard await dependencies.isAnalysed(seedID) else { return [] }
        let ranked = await dependencies.similarInLibrary(seedID, limit)
        return ranked.prefix(limit).map { ($0.track, matchPercent($0.score)) }
    }

    // MARK: Online section

    struct OnlineRow: Identifiable, Equatable, Sendable {
        enum Placement: Equatable, Sendable {
            case held
            case library
        }
        var recommendation: SwarmRecommendation
        var placement: Placement?
        /// The pipeline's state while it works on it.
        var pipeline: DownloadViewModel.DiscoveryStatus?

        var id: String { recommendation.scDownloadUrl ?? "\(recommendation.artist) - \(recommendation.title)" }

        /// `Queued` → `Downloading…` → `In library` / `In Recommendations` (V-SIMILAR.E04).
        var stateWord: String? {
            switch pipeline {
            case .queued: return "Queued"
            case .downloading: return "Downloading…"
            case .failed: return "Download failed"
            case .downloaded, nil:
                switch placement {
                case .held: return "In Recommendations"
                case .library: return "In library"
                case nil: return nil
                }
            }
        }

        var isBusy: Bool { pipeline == .queued || pipeline == .downloading }
        /// Nothing more to offer: it is here already.
        var isPlaced: Bool { placement != nil }
    }

    /// What went wrong asking a source, in words (V-SIMILAR.N05/N06).
    struct OnlineFailure: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case offline, noSource, noAnswer }
        var kind: Kind
        var headline: String
        var details: String
    }

    enum OnlineState: Equatable {
        case idle
        case loading
        case results
        case empty
        case failed(OnlineFailure)
    }

    private(set) var onlineState: OnlineState = .idle
    private(set) var onlineRows: [OnlineRow] = []
    var source: SwarmRecommendationService.SwarmSource = .soundcloud
    private(set) var onlineLimit = 10

    let trackID: Int64
    let dependencies: Dependencies
    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    var drive = LibraryDriveState(volumeName: nil, isConnected: true)

    init(trackID: Int64, dependencies: Dependencies) {
        self.trackID = trackID
        self.dependencies = dependencies
    }

    // MARK: Words

    nonisolated static func sourceName(_ source: SwarmRecommendationService.SwarmSource) -> String {
        source == .soundcloud ? "SoundCloud" : "Last.fm"
    }

    static let notAnalysedHeadline = "This track isn’t analysed yet"
    static let noSimilarHeadline = "No similar tracks in your library yet"
    static let noDeleteNote = "Nothing in this view can remove a track from your library. Downloaded suggestions are kept or dismissed in Recommendations."

    static func analyseSentence(_ title: String) -> String {
        "MLM compares tracks by their sound. Analysing “\(title)” takes about 20 seconds."
    }

    /// `Can’t analyse — “Lexxar” is not connected.` — the Analyse button is disabled with this
    /// (V-SIMILAR.N02): not downloaded, file missing, or the drive away.
    var analyseRefusal: String? {
        guard let seed else { return nil }
        if drive.isOffline, let name = drive.volumeName, seed.availability().hasFile {
            return "Can’t analyse — “\(name)” is not connected."
        }
        switch seed.availability() {
        case .local: return nil
        case .fileMissing: return "Can’t analyse — the file is missing."
        default: return "Can’t analyse — download the track first."
        }
    }

    static func onlineLoadingLine(_ source: SwarmRecommendationService.SwarmSource, _ title: String) -> String {
        "Asking \(sourceName(source)) for tracks related to “\(title)”…"
    }

    static func noSuggestionsLine(_ source: SwarmRecommendationService.SwarmSource, _ title: String) -> String {
        "\(sourceName(source)) has no related tracks for “\(title)”."
    }

    // MARK: Loading

    /// Load the seed and, when it is analysed, the library matches; then ask the source.
    func load() async {
        seedState = .loading
        guard let track = await dependencies.fetchTrack(trackID) else {
            seed = nil
            seedState = .missing
            return
        }
        seed = track
        await loadLibrary()
        refreshOnline()
    }

    /// `Refresh` (V-SIMILAR.N03): read both sections again.
    func refresh() async {
        guard seed != nil else { return await load() }
        await loadLibrary()
        onlineLimit = 10
        refreshOnline()
    }

    func loadLibrary() async {
        guard let seed, let id = seed.id else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        guard await dependencies.isAnalysed(id) else {
            seedState = .notAnalysed
            inLibrary = []
            matches = [:]
            return
        }
        let ranked = await dependencies.similarInLibrary(id, Self.libraryLimit)
        inLibrary = ranked.map(\.track)
        matches = Dictionary(ranked.compactMap { item in
            item.track.id.map { ($0, Self.matchPercent(item.score)) }
        }, uniquingKeysWith: { first, _ in first })
        seedState = .ready
    }

    /// `Analyse` for a seed that isn't analysed: the existing analysis job (an Activity operation).
    func analyseSeed() async {
        guard let seed, analyseRefusal == nil else { return }
        await dependencies.analyse(seed)
    }

    // MARK: Online

    func setSource(_ newSource: SwarmRecommendationService.SwarmSource) {
        guard newSource != source else { return }
        source = newSource
        onlineLimit = 10
        refreshOnline()
    }

    func loadMore() {
        onlineLimit += 10
        refreshOnline(keepingRows: true)
    }

    func cancelOnline() {
        onlineTask?.cancel()
        generation += 1
        onlineState = onlineRows.isEmpty ? .idle : .results
    }

    /// Ask the chosen source for related tracks. A newer ask replaces an older one.
    func refreshOnline(keepingRows: Bool = false) {
        guard let seed else { return }
        onlineTask?.cancel()
        generation += 1
        let current = generation
        if !keepingRows { onlineRows = [] }
        onlineState = .loading
        let limit = onlineLimit
        let source = self.source
        let dependencies = self.dependencies
        onlineTask = Task { [weak self] in
            do {
                let found = try await dependencies.swarm.fetchRecommendations(for: seed, source: source, limit: limit)
                guard !Task.isCancelled else { return }
                var rows: [OnlineRow] = []
                for recommendation in found {
                    var row = OnlineRow(recommendation: recommendation)
                    row.placement = await dependencies.placement(recommendation, seed.id ?? 0)
                    row.pipeline = dependencies.pipelineStatus(recommendation)
                    rows.append(row)
                }
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.onlineRows = rows
                self.onlineState = rows.isEmpty ? .empty : .results
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.onlineRows = []
                self.onlineState = .failed(Self.failure(error, source: source))
            }
        }
    }

    /// Wait for the running online ask (tests).
    func waitForOnline() async {
        await onlineTask?.value
    }

    /// Words for what went wrong (V-SIMILAR.N05, N06).
    nonisolated static func failure(_ error: Error, source: SwarmRecommendationService.SwarmSource) -> OnlineFailure {
        let name = sourceName(source)
        if let swarm = error as? SwarmError {
            switch swarm {
            case .soundCloudClientIdMissing, .lastFmApiKeyMissing:
                return OnlineFailure(kind: .noSource, headline: "\(name) isn’t set up for suggestions",
                                     details: source == .soundcloud
                                        ? "MLM needs a connected SoundCloud account to ask for similar tracks."
                                        : "MLM needs a Last.fm API key to ask for similar tracks.")
            case .soundCloudNetworkError(let underlying), .lastFmNetworkError(let underlying):
                if (underlying as? URLError)?.code == .notConnectedToInternet {
                    return OnlineFailure(kind: .offline, headline: "Can’t load online suggestions — this Mac is offline",
                                         details: "The matches from your library above don’t need a connection.")
                }
            default:
                break
            }
            return OnlineFailure(kind: .noAnswer, headline: "\(name) didn’t answer",
                                 details: "\(swarm.errorDescription ?? "The request failed.") This is on \(name)’s side; your library is not affected.")
        }
        if (error as? URLError)?.code == .notConnectedToInternet {
            return OnlineFailure(kind: .offline, headline: "Can’t load online suggestions — this Mac is offline",
                                 details: "The matches from your library above don’t need a connection.")
        }
        return OnlineFailure(kind: .noAnswer, headline: "\(name) didn’t answer",
                             details: "\(error.localizedDescription) This is on \(name)’s side; your library is not affected.")
    }

    // MARK: Download and Keep

    /// `Download`: fetch it and hold it in Discover ▸ Recommendations until it is kept.
    func download(_ row: OnlineRow) {
        start(row, hold: true)
    }

    /// `Keep`: download it straight into the library.
    func keep(_ row: OnlineRow) {
        start(row, hold: false)
    }

    private func start(_ row: OnlineRow, hold: Bool) {
        guard let seed, !row.isBusy, !row.isPlaced else { return }
        dependencies.startDownload(row.recommendation, seed, hold)
    }

    /// Re-read where each suggestion is (the pipeline moved on, a download finished).
    func refreshPlacements() async {
        guard let seedID = seed?.id else { return }
        var rows = onlineRows
        for index in rows.indices {
            rows[index].pipeline = dependencies.pipelineStatus(rows[index].recommendation)
            rows[index].placement = await dependencies.placement(rows[index].recommendation, seedID)
        }
        if rows != onlineRows { onlineRows = rows }
    }
}
