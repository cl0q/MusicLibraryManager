import Foundation
import Observation

/// The scopes of Discover (V-DISC.E02): `Recommendations · Reels`.
enum DiscoverScope: String, CaseIterable, Identifiable, Sendable {
    case recommendations, reels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommendations: "Recommendations"
        case .reels: "Reels"
        }
    }
}

/// The recommendations that came from one seed track (V-INBOX.E06d): `Because of “‹track›”`.
/// Rows without a seed (it was removed, or the download had none) are `Other recommendations`.
struct RecommendationGroup: Identifiable, Equatable, Sendable {
    var seedTrackID: Int64?
    var seedTitle: String?
    var items: [RecommendationRepository.Item]

    var id: String { seedTrackID.map { "seed:\($0)" } ?? "other" }

    var title: String {
        guard let seedTitle else { return "Other recommendations" }
        return "Because of “\(seedTitle)”"
    }

    var trackIDs: [Int64] { items.map(\.id) }
}

/// What Find Recommendations needs from the recommendation service (a fake in tests).
protocol SwarmRecommending: Sendable {
    func fetchRecommendations(for track: Track, source: SwarmRecommendationService.SwarmSource, limit: Int) async throws -> [SwarmRecommendation]
}

extension SwarmRecommendationService: SwarmRecommending {}

/// Discover ▸ Recommendations (V-INBOX, DEC-029): the downloaded recommendations held until the
/// user keeps or dismisses them — grouped by seed, filtered in place, with Keep and Dismiss as
/// one undo step each (IMP-053…056). Reels is W3-DISC-B's; this model only counts them.
@MainActor
@Observable
final class DiscoverModel {
    struct Dependencies {
        var recommendations: RecommendationRepository
        /// Reels waiting (`ImportedReelRecord` has no state yet, so this is the saved reels).
        var reelCount: @MainActor () async -> Int = { 0 }
        var libraryRoot: @MainActor () async -> String? = { nil }
        var consequences = ReviewConsequences()
        /// How closely `trackID` sounds like its seed, in percent (`nil` while either is unanalysed).
        var matchPercent: @MainActor (_ seedID: Int64, _ trackID: Int64) async -> Int? = { _, _ in nil }
        /// The lists reload: kept ones join All Tracks, the sidebar badge follows.
        var postChange: @MainActor () -> Void = {}
        /// Keep and Add to Playlist: put `trackIDs` into the playlist as a part of the same undo
        /// step; returns the playlist's name. `nil` = nothing added.
        var placeInPlaylist: @MainActor (_ group: UndoGroup, _ trackIDs: [Int64], _ playlistID: Int64) async throws -> String? = { _, _, _ in nil }
        var swarm: any SwarmRecommending
        /// Hand a recommendation to the download pipeline (held in Discover, lane `downloads`).
        var startDownload: @MainActor (_ recommendation: SwarmRecommendation, _ seed: Track) -> Void = { _, _ in }
        /// Whether the seed has been analysed (its embedding exists).
        var isAnalysed: @MainActor (_ trackID: Int64) async -> Bool = { _ in true }
        /// Start the existing analysis job for a track.
        var analyse: @MainActor (_ track: Track) async -> Void = { _ in }
        var fetchTrack: @MainActor (_ id: Int64) async -> Track? = { _ in nil }
        var playingTrack: @MainActor () -> Track? = { nil }
        /// A track of the library with this artist and title already exists.
        var isInLibrary: @MainActor (_ artist: String, _ title: String) async -> Bool = { _, _ in false }
    }

    // MARK: State

    private(set) var groups: [RecommendationGroup] = []
    /// Matches per track id (percent), for the `Match` column.
    private(set) var matches: [Int64: Int] = [:]
    private(set) var reelCount: Int?
    /// The first load has finished (placeholder rows only until then, V-INBOX.E04).
    private(set) var isLoaded = false
    /// `V-INBOX.N05`: the load failed — never shown as empty.
    private(set) var loadError: String?
    var filter: SearchFilter = .empty
    /// The library's disk (Dismiss moves files to the Trash and needs it).
    var drive = LibraryDriveState(volumeName: nil, isConnected: true)
    var statusBar: StatusBarCenter?
    var undo: UndoCenter?

    let dependencies: Dependencies
    @ObservationIgnored private let center: ActivityCenter

    init(dependencies: Dependencies, center: ActivityCenter? = nil) {
        self.dependencies = dependencies
        self.center = center ?? .shared
    }

    // MARK: Words

    static func waitingLine(_ count: Int) -> String {
        count == 1 ? "1 recommendation" : "\(count.formatted(.number)) recommendations"
    }

    /// `3 recommendations — held here, not in All Tracks, until you keep them.` (V-INBOX.E02)
    static func headerLine(_ count: Int) -> String {
        "\(waitingLine(count)) — held here, not in All Tracks, until you keep them."
    }

    static func sourceWord(_ source: String) -> String {
        switch source.lowercased() {
        case "soundcloud": "SoundCloud"
        case "lastfm", "last.fm": "Last.fm"
        case "spotify": "Spotify"
        default: source.isEmpty ? "—" : source.prefix(1).uppercased() + source.dropFirst()
        }
    }

    // MARK: Counts and visible groups

    /// Every recommendation waiting (the filter doesn't change it).
    var waitingCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    var isEmpty: Bool { isLoaded && loadError == nil && groups.isEmpty }
    var isFiltering: Bool { !filter.isEmpty }

    var visibleGroups: [RecommendationGroup] {
        guard isFiltering else { return groups }
        return groups.compactMap { group in
            var group = group
            group.items = group.items.filter { filter.matchesName("\($0.track.title) \($0.track.artist)") }
            return group.items.isEmpty ? nil : group
        }
    }

    var visibleCount: Int { visibleGroups.reduce(0) { $0 + $1.items.count } }
    /// Something is typed and nothing matches.
    var hasNoMatches: Bool { isFiltering && waitingCount > 0 && visibleCount == 0 }

    func count(for scope: DiscoverScope) -> Int? {
        switch scope {
        case .recommendations: isLoaded ? waitingCount : nil
        case .reels: reelCount
        }
    }

    func item(for trackID: Int64) -> RecommendationRepository.Item? {
        groups.lazy.flatMap(\.items).first { $0.id == trackID }
    }

    func group(containing trackID: Int64) -> RecommendationGroup? {
        groups.first { $0.items.contains { $0.id == trackID } }
    }

    // MARK: Loading (V-INBOX.E04 / N05)

    /// First load shows placeholder rows; later loads update in place and show the status-bar
    /// spinner after 300 ms. A failed load keeps what is shown and reports (never "empty").
    func reload() async {
        let token = isLoaded ? statusBar?.beginLoading("Updating recommendations…") : nil
        defer { if let token { statusBar?.endLoading(token) } }
        do {
            let items = try await dependencies.recommendations.waiting()
            groups = Self.group(items)
            loadError = nil
            isLoaded = true
            var matches: [Int64: Int] = [:]
            for item in items {
                guard let seed = item.seedTrackID, item.isAnalysed else { continue }
                if let percent = await dependencies.matchPercent(seed, item.id) { matches[item.id] = percent }
            }
            self.matches = matches
        } catch {
            AppLogger.shared.error("Loading recommendations failed: \(error.localizedDescription)", source: "Discover")
            loadError = error.localizedDescription
            isLoaded = true
        }
        reelCount = await dependencies.reelCount()
    }

    /// Groups by seed, newest group first; `Other recommendations` last.
    nonisolated static func group(_ items: [RecommendationRepository.Item]) -> [RecommendationGroup] {
        var order: [Int64?] = []
        var buckets: [Int64?: RecommendationGroup] = [:]
        for item in items {
            let key = item.seedTitle == nil ? nil : item.seedTrackID
            if buckets[key] == nil {
                buckets[key] = RecommendationGroup(seedTrackID: key, seedTitle: key == nil ? nil : item.seedTitle, items: [])
                order.append(key)
            }
            buckets[key]?.items.append(item)
        }
        let seeded = order.compactMap { $0 == nil ? nil : buckets[$0] }
        let other = buckets[nil].map { [$0] } ?? []
        return seeded + other
    }

    // MARK: Keep (IMP-054, K)

    /// `Keep` / `Keep All`: the recommendations join the library — one undo step (UC-UNDO-08),
    /// confirmed in the status bar with `Undo` (UC-PRIM-10). With `playlistID`, the same step
    /// also adds them to that playlist (`Keep and Add to Playlist ▸`).
    func keep(_ trackIDs: [Int64], addTo playlistID: Int64? = nil) async {
        let waiting = waitingIDs(in: trackIDs)
        guard let undo, !waiting.isEmpty else { return }
        let title = waiting.count == 1 ? item(for: waiting[0])?.track.title : nil
        let recommendations = dependencies.recommendations
        let dependencies = self.dependencies
        let name = title.map { "Keep “\($0)”" } ?? "Keep \(waiting.count.formatted(.number)) Recommendations"
        do {
            _ = try await undo.performGroup(
                name, failure: "Couldn’t keep \(Self.waitingLine(waiting.count))",
                { group in
                    let kept = try await group.perform(
                        do: { try await recommendations.keep(ids: waiting) },
                        undo: { kept in try await recommendations.undoKeep(ids: kept); return kept },
                        redo: { kept in try await recommendations.keep(ids: kept) })
                    var playlist: String?
                    if let playlistID, !kept.isEmpty {
                        playlist = try await dependencies.placeInPlaylist(group, kept, playlistID)
                    }
                    return (kept, playlist)
                },
                message: { kept, playlist in
                    Self.keptMessage(count: kept.count, title: title, playlist: playlist)
                })
            dependencies.postChange()
            await reload()
        } catch {
            // Reported in the status bar by the center.
        }
    }

    nonisolated static func keptMessage(count: Int, title: String?, playlist: String?) -> String {
        let what = count == 1 && title != nil ? "“\(title ?? "")”" : "\(count.formatted(.number)) tracks"
        let base = "Added \(what) to the library"
        guard let playlist else { return base }
        return "\(base) and to “\(playlist)”"
    }

    /// `Keep All` on a seed group — one step for the group.
    func keepAll(in group: RecommendationGroup) async { await keep(group.trackIDs) }

    // MARK: Dismiss (IMP-055, ⌫)

    /// Why Dismiss can't run now (UC-CM-05): the files can't go to the Trash while the library's
    /// drive is away.
    var dismissRefusal: String? {
        guard drive.isOffline, let name = drive.volumeName else { return nil }
        return "“\(name)” is not connected"
    }

    /// What a dismissed batch did to files, for Undo.
    struct Dismissal: Sendable {
        var ids: [Int64]
        var trashed: [ReviewDecisionConsequences.Trashed]
    }

    /// `Dismiss` / `Dismiss All`: no alert. One transaction marks the rows dismissed; after it
    /// commits the files move to the Trash (each its own try). A file that can't move leaves its
    /// row waiting and says so. Undo moves files back from the Trash while they are there.
    func dismiss(_ trackIDs: [Int64]) async {
        let waiting = waitingIDs(in: trackIDs)
        guard let undo, !waiting.isEmpty else { return }
        if let refusal = dismissRefusal {
            statusBar?.post("Can’t dismiss — \(refusal)")
            return
        }
        let title = waiting.count == 1 ? item(for: waiting[0])?.track.title : nil
        let name = title.map { "Dismiss “\($0)”" } ?? "Dismiss \(waiting.count.formatted(.number)) Recommendations"
        let dependencies = self.dependencies
        let statusBar = self.statusBar
        do {
            let done = try await undo.perform(
                name, failure: "Couldn’t dismiss \(Self.waitingLine(waiting.count))",
                do: { () async throws -> Dismissal? in
                    let dismissal = try await Self.runDismiss(waiting, dependencies: dependencies, statusBar: statusBar)
                    return dismissal.ids.isEmpty ? nil : dismissal
                },
                undo: { dismissal in try await Self.runUndoDismiss(dismissal, dependencies: dependencies, statusBar: statusBar) },
                redo: { dismissal in try await Self.runDismiss(dismissal.ids, dependencies: dependencies, statusBar: statusBar) },
                message: { dismissal in
                    let what = dismissal.ids.count == 1 && title != nil ? "“\(title ?? "")”" : "\(dismissal.ids.count.formatted(.number)) recommendations"
                    return "Dismissed \(what) — moved to the Trash"
                })
            _ = done
            dependencies.postChange()
            await reload()
        } catch {
            // Reported in the status bar by the center.
        }
    }

    func dismissAll(in group: RecommendationGroup) async { await dismiss(group.trackIDs) }

    /// The database step, then the files. Returns what was dismissed (failed moves are back to
    /// waiting and counted in the status bar).
    private static func runDismiss(
        _ ids: [Int64], dependencies: Dependencies, statusBar: StatusBarCenter?
    ) async throws -> Dismissal {
        let recommendations = dependencies.recommendations
        let dismissed = try await recommendations.dismiss(ids: ids)
        guard !dismissed.isEmpty else { return Dismissal(ids: [], trashed: []) }
        let root = await dependencies.libraryRoot()
        let files = dismissed.map { (id: $0.trackID, url: ReviewConsequences.fileURL(organizedPath: $0.organizedPath, libraryRoot: root)) }
        let report = dependencies.consequences.trash(files)
        for item in report.trashed where !item.trashURL.isEmpty {
            try await recommendations.recordTrash(trackID: item.trackId, url: item.trashURL)
        }
        if report.failures > 0 {
            // The rows whose file couldn't move stay waiting: find them (they have a file but no Trash record).
            let moved = Set(report.trashed.map(\.trackId))
            let failed = files.filter { $0.url != nil && !moved.contains($0.id) && dependencies.consequences.files.fileExists(atPath: $0.url?.path ?? "") }
                .map(\.id)
            try await recommendations.undoDismiss(ids: failed)
            statusBar?.post(
                report.failures == 1 ? "Couldn’t move 1 file to the Trash" : "Couldn’t move \(report.failures) files to the Trash",
                actions: [StatusAction("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }])
            let failedSet = Set(failed)
            return Dismissal(ids: dismissed.map(\.trackID).filter { !failedSet.contains($0) }, trashed: report.trashed)
        }
        return Dismissal(ids: dismissed.map(\.trackID), trashed: report.trashed)
    }

    /// Undo of a dismissal: files come back from the Trash while they are there; rows whose file
    /// is gone stay dismissed (purged next launch) and the status bar says so.
    private static func runUndoDismiss(
        _ dismissal: Dismissal, dependencies: Dependencies, statusBar: StatusBarCenter?
    ) async throws -> Dismissal {
        let recommendations = dependencies.recommendations
        let report = dependencies.consequences.putBack(dismissal.trashed)
        let trashedIDs = Set(dismissal.trashed.map(\.trackId))
        let filelessIDs = dismissal.ids.filter { !trashedIDs.contains($0) }
        // Which trashed files came back: those no longer in the Trash but at their old place.
        let restoredIDs = dismissal.trashed.filter { dependencies.consequences.files.fileExists(atPath: $0.from) }.map(\.trackId)
        try await recommendations.undoDismiss(ids: filelessIDs + restoredIDs)
        if report.gone > 0 {
            throw UndoNothingLeft(note: report.gone == 1
                ? "Can’t undo — 1 file is no longer in the Trash"
                : "Can’t undo — \(report.gone) files are no longer in the Trash")
        }
        return dismissal
    }

    private func waitingIDs(in ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { id in item(for: id) != nil && seen.insert(id).inserted }
    }

    // MARK: Find Recommendations… (IMP-056)

    /// The status-bar sentences of a refused search.
    static let noSeedSentence = "Select a track or play one to find recommendations from"
    static func notAnalysedSentence(_ title: String) -> String { "“\(title)” isn’t analysed yet" }

    /// The seed: the selected recommendation's seed track, else the playing track.
    func seedTrack(selected ids: Set<Int64>) async -> Track? {
        for id in ids {
            if let seedID = item(for: id)?.seedTrackID, let track = await dependencies.fetchTrack(seedID) { return track }
        }
        return dependencies.playingTrack()
    }

    /// Run the recommendation search as an Activity operation and hand what it finds to the
    /// download pipeline (held here until kept). Nothing navigates (P3). Returns the number of
    /// downloads started, or `nil` when the search was refused or failed.
    @discardableResult
    func findRecommendations(selected ids: Set<Int64>) async -> Int? {
        guard let seed = await seedTrack(selected: ids), let seedID = seed.id else {
            statusBar?.post(Self.noSeedSentence)
            return nil
        }
        guard await dependencies.isAnalysed(seedID) else {
            statusBar?.post(Self.notAnalysedSentence(seed.title), actions: [
                StatusAction("Analyse") { [dependencies] in Task { await dependencies.analyse(seed) } },
            ])
            return nil
        }
        let job = center.begin(.recommendationDownload, title: "Find recommendations for “\(seed.title)”",
                               subject: .tracks([seedID]), itemNoun: .track, lane: nil)
        do {
            let found = try await fetch(for: seed)
            var started = 0
            for recommendation in found {
                if await dependencies.isInLibrary(recommendation.artist, recommendation.title) { continue }
                dependencies.startDownload(recommendation, seed)
                started += 1
            }
            job.finish(ActivityResult(counts: [ActivityCount(.done, started, started == 1 ? "recommendation queued" : "recommendations queued")]))
            statusBar?.post(started == 0 ? "No new recommendations found for “\(seed.title)”"
                                          : "Finding recommendations for “\(seed.title)” — \(started) queued")
            return started
        } catch {
            let cause = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            job.fail(cause: cause)
            statusBar?.post("Couldn’t find recommendations — \(cause)",
                            actions: [StatusAction("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }])
            return nil
        }
    }

    private func fetch(for seed: Track) async throws -> [SwarmRecommendation] {
        do {
            return try await dependencies.swarm.fetchRecommendations(for: seed, source: .soundcloud, limit: 10)
        } catch SwarmError.soundCloudClientIdMissing {
            return try await dependencies.swarm.fetchRecommendations(for: seed, source: .lastfm, limit: 10)
        }
    }
}
