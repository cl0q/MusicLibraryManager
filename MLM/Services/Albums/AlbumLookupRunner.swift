import Foundation
import GRDB
import Observation

/// What a finished (or stopped) lookup says in the header: `Last lookup: Oct 3, 2026 at 5:02 PM`.
struct AlbumLastLookup: Equatable, Sendable {
    var date: Date

    static let keyDate = "albums.lookup.lastAt"

    var sentence: String {
        "Last lookup: \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func load(from config: ConfigRepository?) async -> AlbumLastLookup? {
        guard let config, let stamp = (try? await config.get(key: keyDate)) ?? nil,
              let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
        return AlbumLastLookup(date: date)
    }

    func save(to config: ConfigRepository?) async {
        try? await config?.set(key: Self.keyDate, value: ISO8601DateFormatter().string(from: date))
    }
}

/// `Look Up Albums` (IMP-083) as an Activity operation: asks the `AlbumSuggesting` provider about
/// every listed track without an album that has no row yet and files the answer in
/// `album_suggestions` (`pending`, or `no_match`). Every processed track has a row, so a
/// stopped run — cancelled, or MLM quit — resumes where it stopped on the next start; nothing
/// is looked up twice. It lives outside the view, so it continues when you leave Review.
@MainActor
@Observable
final class AlbumLookupRunner {
    static let shared = AlbumLookupRunner()

    private(set) var isActive = false
    private(set) var lastLookup: AlbumLastLookup?
    /// Set once the stored date was read (so the empty state does not flash `No album suggestions yet`).
    private(set) var hasLoadedLastLookup = false
    /// Bumped when a run ends; views reload.
    private(set) var finishedCount = 0
    /// How the last run ended, for the status bar of the view.
    private(set) var lastOutcome: Outcome?

    struct Outcome: Equatable, Sendable {
        var processed = 0
        var suggestions = 0
        var noMatch = 0
        var cancelled = false
    }

    /// Tracks per database write and progress step.
    static let batchSize = 50

    @ObservationIgnored var statusBar: StatusBarCenter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var handle: ActivityOperationHandle?
    @ObservationIgnored private let center: ActivityCenter
    @ObservationIgnored private let repository: @MainActor () -> AlbumSuggestionRepository?
    @ObservationIgnored private let libraryRoot: @MainActor () async -> String?
    @ObservationIgnored private let config: @MainActor () -> ConfigRepository?
    @ObservationIgnored private let suggester: any AlbumSuggesting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let didChange: () -> Void

    init(
        center: ActivityCenter = .shared,
        repository: @escaping @MainActor () -> AlbumSuggestionRepository? = AlbumLookupRunner.liveRepository,
        libraryRoot: @escaping @MainActor () async -> String? = { (try? await DependencyContainer.shared.configRepository?.getLibraryRoot()) ?? nil },
        config: @escaping @MainActor () -> ConfigRepository? = { DependencyContainer.shared.configRepository },
        suggester: any AlbumSuggesting = TagAlbumSuggester(),
        now: @escaping () -> Date = Date.init,
        didChange: @escaping () -> Void = { NotificationCenter.default.post(name: .reviewQueueDidChange, object: nil) }
    ) {
        self.center = center
        self.repository = repository
        self.libraryRoot = libraryRoot
        self.config = config
        self.suggester = suggester
        self.now = now
        self.didChange = didChange
    }

    static func liveRepository() -> AlbumSuggestionRepository? {
        DependencyContainer.shared.databaseManager.map { AlbumSuggestionRepository(database: $0.pool) }
    }

    /// Why `Look Up Albums` can't start now, or `nil`.
    var blockedReason: String? {
        if isActive { return "A lookup is running — see Activity." }
        if repository() == nil { return "No library is open." }
        return nil
    }

    func loadLastLookup() async {
        lastLookup = await AlbumLastLookup.load(from: config())
        hasLoadedLastLookup = true
    }

    /// Starts the lookup (a second start while one runs does nothing). Returns whether it started.
    @discardableResult
    func start() -> Bool {
        guard !isActive, let repository = repository() else { return false }
        isActive = true
        lastOutcome = nil
        let job = center.begin(
            .albumLookup, title: "Looking up albums", subject: .review, itemNoun: .track,
            controls: ActivityControls(cancel: { [weak self] in Task { @MainActor in self?.cancel() } }),
            lane: MaintenanceJobRunner.lane)
        handle = job
        task = Task { [weak self] in
            guard await job.waitForTurn() else {
                self?.ended(Outcome(cancelled: true))
                return
            }
            await self?.run(repository: repository, job: job)
        }
        return true
    }

    /// `Look Up Albums` from the header: starts it and says so in the status bar (never navigates, P3).
    func startWithConfirmation(statusBar: StatusBarCenter?) {
        self.statusBar = statusBar ?? self.statusBar
        guard start() else { return }
        statusBar?.post("Lookup started — it continues in the background", actions: [
            StatusAction("Show in Activity") { ActivityRouter.shared.showPopover() },
        ])
    }

    /// Stops after the track in hand; the rows already written stay, the next start resumes.
    func cancel() {
        task?.cancel()
        if let handle, center.operation(id: handle.id)?.state == .queued { center.cancel(handle.id) }
    }

    /// Waits for the running lookup (tests).
    func waitUntilIdle() async {
        await task?.value
    }

    private func run(repository: AlbumSuggestionRepository, job: ActivityOperationHandle) async {
        let root = await libraryRoot()
        let suggester = suggester
        var outcome = Outcome()
        do {
            let total = try await repository.candidateCount()
            job.update(completed: 0, total: total, currentItem: nil)
            let index = try await Self.buildIndex(repository)
            let context = AlbumSuggestionContext(libraryRoot: root, index: index)
            outcome = try await Self.process(repository: repository, suggester: suggester, context: context, total: total) { done in
                job.update(completed: done, total: total, currentItem: nil)
            }
            if outcome.cancelled {
                job.cancelled(Self.result(outcome))
            } else {
                job.finish(Self.result(outcome))
            }
            if outcome.processed > 0 {
                let found = AlbumLastLookup(date: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)))
                let configuration = config()
                await Task.detached { await found.save(to: configuration) }.value   // survives a cancelled run
                lastLookup = found
            }
        } catch {
            AppLogger.shared.error("Album lookup failed: \(error.localizedDescription)", source: "Albums")
            job.fail(cause: "The lookup couldn’t read the library", fix: .runAgain, result: Self.result(outcome))
        }
        ended(outcome)
        didChange()
    }

    private static func result(_ outcome: Outcome) -> ActivityResult {
        ActivityResult(counts: [
            ActivityCount(.done, outcome.suggestions, outcome.suggestions == 1 ? "suggestion" : "suggestions"),
            ActivityCount(.skipped, outcome.noMatch, "no match"),
        ])
    }

    private func ended(_ outcome: Outcome) {
        isActive = false
        handle = nil
        task = nil
        lastOutcome = outcome
        finishedCount += 1
    }

    // MARK: Work (off the main actor)

    /// The albums every artist already has (tracks with a real album text).
    nonisolated static func buildIndex(_ repository: AlbumSuggestionRepository) async throws -> ArtistAlbumIndex {
        let rows: [(artist: String, albumArtist: String, album: String, year: Int?)] = try await repository.database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT artist, album_artist, album, year FROM tracks
                WHERE TRIM(COALESCE(album, '')) <> '' AND NOT (\(TrackSearchSQL.noAlbumText))
                """).map { (artist: $0["artist"], albumArtist: $0["album_artist"], album: $0["album"], year: $0["year"]) }
        }
        return ArtistAlbumIndex(tracks: rows)
    }

    /// Looks up the candidates in batches; each batch is written before the next starts, so
    /// cancelling keeps everything done so far.
    nonisolated static func process(
        repository: AlbumSuggestionRepository, suggester: any AlbumSuggesting, context: AlbumSuggestionContext,
        total: Int, progress: @Sendable (Int) -> Void
    ) async throws -> Outcome {
        var outcome = Outcome()
        while true {
            if Task.isCancelled { outcome.cancelled = true; return outcome }
            let batch = try await repository.candidatesForLookup(limit: batchSize)
            if batch.isEmpty { return outcome }
            var rows: [AlbumSuggestionRow] = []
            for track in batch {
                if Task.isCancelled { outcome.cancelled = true; break }
                guard let id = track.id else { continue }
                // A provider that fails for one track leaves it without a row (looked up again next time).
                guard let found = try? await suggester.suggest(for: track, context: context) else { continue }
                let row = AlbumSuggestionRow.looked(up: id, candidates: found)
                rows.append(row)
                if row.status == .noMatch { outcome.noMatch += 1 } else { outcome.suggestions += 1 }
            }
            // GRDB's async writes throw once the task is cancelled; the rows done so far must
            // still be kept, so they are written from a task that is not.
            let written = rows
            try await Task.detached { try await repository.upsert(written) }.value
            outcome.processed += rows.count
            progress(outcome.processed)
            if outcome.cancelled { return outcome }
            // Nothing written for a whole batch (every call failed): stop instead of looping forever.
            if rows.isEmpty { return outcome }
        }
    }
}
