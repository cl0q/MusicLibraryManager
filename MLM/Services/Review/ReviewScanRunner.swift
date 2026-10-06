import Foundation
import Observation

/// What the last finished duplicate scan found (`Last scan: ‹date› · ‹n› comparisons · ‹d›
/// duplicate groups · ‹c› conflicts`, V-REV.E03). Persisted in `app_config` (`review.lastScan.*`),
/// so `Nothing to review` can tell a clean library from one that was never scanned (V-REV.N10).
struct ReviewLastScan: Equatable, Sendable {
    var date: Date
    var comparisons: Int
    var duplicateGroups: Int
    var conflicts: Int

    static let keyDate = "review.lastScan.at"
    static let keyComparisons = "review.lastScan.comparisons"
    static let keyGroups = "review.lastScan.groups"
    static let keyConflicts = "review.lastScan.conflicts"

    /// `Last scan: Oct 3, 2026 at 5:02 PM · 131,400 comparisons · 14 duplicate groups · 8 conflicts`.
    var sentence: String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        let comparisonsText = comparisons == 1 ? "1 comparison" : "\(comparisons.formatted(.number)) comparisons"
        let groups = duplicateGroups == 1 ? "1 duplicate group" : "\(duplicateGroups.formatted(.number)) duplicate groups"
        let conflictText = conflicts == 1 ? "1 conflict" : "\(conflicts.formatted(.number)) conflicts"
        return "Last scan: \(when) · \(comparisonsText) · \(groups) · \(conflictText)"
    }

    static func load(from config: ConfigRepository?) async -> ReviewLastScan? {
        guard let config,
              let stamp = (try? await config.get(key: keyDate)) ?? nil,
              let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
        func number(_ key: String) async -> Int {
            ((try? await config.get(key: key)) ?? nil).flatMap(Int.init) ?? 0
        }
        return ReviewLastScan(date: date, comparisons: await number(keyComparisons),
                              duplicateGroups: await number(keyGroups), conflicts: await number(keyConflicts))
    }

    func save(to config: ConfigRepository?) async {
        guard let config else { return }
        try? await config.set(key: Self.keyDate, value: ISO8601DateFormatter().string(from: date))
        try? await config.set(key: Self.keyComparisons, value: String(comparisons))
        try? await config.set(key: Self.keyGroups, value: String(duplicateGroups))
        try? await config.set(key: Self.keyConflicts, value: String(conflicts))
    }
}

/// A scan that didn't finish: the plain sentence, and the raw text behind `Details` (V-REV.E04).
struct ReviewScanFailure: Equatable, Sendable {
    var headline: String
    var details: String
}

/// The duplicate scan as an Activity operation (UC-JOB-01/07, DEC-044): `Run Scan`, ⌘R and
/// Library ▸ Find Duplicates all start it here. It lives outside the Review view, so the scan
/// continues when you leave Review; the header echoes `ActivityCenter.echo(for: .review)`.
/// It joins the Maintenance lane (one analysis job at a time). Groups already found stay usable
/// while it runs; the queue is replaced only when the whole scan finished.
@MainActor
@Observable
final class ReviewScanRunner {
    static let shared = ReviewScanRunner()

    /// `scan(onProgress)` — the comparison itself; replaced in tests.
    typealias Scan = @Sendable (@escaping @Sendable (_ completed: Int, _ total: Int) -> Void) async throws -> DeepScanService.DeepScanResult

    private(set) var isActive = false
    private(set) var lastScan: ReviewLastScan?
    private(set) var failure: ReviewScanFailure?
    /// Set once the stored last scan was read (so `Nothing to review` doesn't flash `never scanned`).
    private(set) var hasLoadedLastScan = false
    /// Bumped when a scan ends; views reload their groups.
    private(set) var finishedCount = 0

    /// Where `Scan cancelled…` is said (set by the view / the start with confirmation).
    @ObservationIgnored var statusBar: StatusBarCenter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var handle: ActivityOperationHandle?
    @ObservationIgnored private let center: ActivityCenter
    @ObservationIgnored private let config: @MainActor () -> ConfigRepository?
    @ObservationIgnored private let makeScan: @MainActor () -> Scan?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let didChange: () -> Void

    init(
        center: ActivityCenter = .shared,
        config: @escaping @MainActor () -> ConfigRepository? = { DependencyContainer.shared.configRepository },
        scan: @escaping @MainActor () -> Scan? = ReviewScanRunner.liveScan,
        now: @escaping () -> Date = Date.init,
        didChange: @escaping () -> Void = { NotificationCenter.default.post(name: .reviewQueueDidChange, object: nil) }
    ) {
        self.center = center
        self.config = config
        self.makeScan = scan
        self.now = now
        self.didChange = didChange
    }

    /// The real scan over the open library.
    static func liveScan() -> Scan? {
        let container = DependencyContainer.shared
        guard let tracks = container.trackRepository, let analysis = container.analysisRepository else { return nil }
        let service = DeepScanService(trackRepository: tracks, analysisRepository: analysis)
        return { onProgress in
            try await service.deepScan(turboMode: false) { state in onProgress(state.current, state.total) }
        }
    }

    /// Why `Run Scan` can't start now, or `nil`.
    var blockedReason: String? {
        if isActive { return "A scan is running — see Activity." }
        if makeScan() == nil { return "No library is open." }
        return nil
    }

    func loadLastScan() async {
        lastScan = await ReviewLastScan.load(from: config())
        hasLoadedLastScan = true
    }

    /// Starts the scan (a second start while one runs does nothing). Returns whether it started.
    @discardableResult
    func start() -> Bool {
        guard !isActive, let scan = makeScan() else { return false }
        isActive = true
        failure = nil
        let job = center.begin(
            .duplicateScan, title: "Scan for duplicates", subject: .review, itemNoun: .item,
            controls: ActivityControls(cancel: { [weak self] in Task { @MainActor in self?.cancel() } }),
            lane: MaintenanceJobRunner.lane)
        handle = job
        task = Task { [weak self] in
            guard await job.waitForTurn() else {
                self?.statusBar?.post(ReviewPresentation.scanCancelled)
                self?.ended()
                return
            }
            await self?.run(scan, job: job)
        }
        return true
    }

    /// `Run Scan` from the header, ⌘R or Library ▸ Find Duplicates: starts the scan and says so
    /// in the status bar (never navigates, P3).
    func startWithConfirmation(statusBar: StatusBarCenter?) {
        self.statusBar = statusBar ?? self.statusBar
        guard start() else { return }
        statusBar?.post("Scan started — it continues in the background", actions: [
            StatusAction("Show in Activity") { ActivityRouter.shared.showPopover() },
        ])
    }

    func cancel() {
        task?.cancel()
        // Still queued behind another job: it ends at once.
        if let handle, center.operation(id: handle.id)?.state == .queued { center.cancel(handle.id) }
    }

    /// Waits for the running scan (tests).
    func waitUntilIdle() async {
        await task?.value
    }

    private func run(_ scan: Scan, job: ActivityOperationHandle) async {
        do {
            let result = try await scan { completed, total in
                job.update(completed: completed, total: total, currentItem: nil)
            }
            if Task.isCancelled {
                job.cancelled()
                statusBar?.post(ReviewPresentation.scanCancelled)
            } else {
                let found = ReviewLastScan(date: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)), comparisons: result.pairsCompared,
                                           duplicateGroups: result.duplicatesFound, conflicts: result.conflictsFlagged)
                await found.save(to: config())
                lastScan = found
                job.finish(ActivityResult(counts: [
                    ActivityCount(.done, result.duplicatesFound, result.duplicatesFound == 1 ? "duplicate group" : "duplicate groups"),
                    ActivityCount(.done, result.conflictsFlagged, result.conflictsFlagged == 1 ? "conflict" : "conflicts"),
                ]))
            }
        } catch is CancellationError {
            job.cancelled()
            statusBar?.post(ReviewPresentation.scanCancelled)
        } catch {
            AppLogger.shared.error("Duplicate scan failed: \(error.localizedDescription)", source: "Dedup")
            failure = ReviewScanFailure(headline: "The last scan didn’t finish.", details: error.localizedDescription)
            job.fail(cause: "The scan couldn’t read the library", fix: .runAgain)
        }
        ended()
        didChange()
    }

    private func ended() {
        isActive = false
        handle = nil
        task = nil
        finishedCount += 1
    }
}
