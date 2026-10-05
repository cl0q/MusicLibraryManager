import Foundation
import Observation

extension Notification.Name {
    /// Posted (main thread) when waiting tag writes were added or written, so Info ▸ File
    /// refreshes its `Tag changes waiting for “‹Volume›”` echo.
    static let pendingTagWritesDidChange = Notification.Name("MLMPendingTagWritesDidChange")
}

/// Something that writes one file's tags (`TrackTagWriter`; fakes in tests).
protocol TagWriting: Sendable {
    func write(_ request: TagWriteRequest) async -> TagWriteOutcome
}

extension TrackTagWriter: TagWriting {}

/// What one flush did.
struct TagFlushReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Every waiting write was tried.
        case finished
        /// `Write tags to files` is off: nothing was touched.
        case disabled
        /// The library folder isn't reachable: nothing was tried.
        case unreachable
        /// The library folder went away during the run: it stopped; the rest waits.
        case rootLost
        case cancelled
    }

    var outcome: Outcome = .finished
    var written = 0
    /// Files that weren't there (the folder was): they stay queued.
    var missing = 0
    /// Failed writes by plain reason (`WAV isn’t supported`: 2).
    var failures: [String: Int] = [:]

    var failedCount: Int { failures.values.reduce(0, +) + missing }

    /// `Tags of 2 files couldn’t be written — WAV isn’t supported` (UC-STATUS-04 shape);
    /// nil when nothing failed.
    var failureMessage: String? {
        var reasons = failures
        if missing > 0 { reasons[TagWriteFailure.fileMissing.reason, default: 0] += missing }
        let total = reasons.values.reduce(0, +)
        guard total > 0 else { return nil }
        let ordered = reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        let files = total == 1 ? "1 file" : "\(total.formatted(.number)) files"
        return "Tags of \(files) couldn’t be written — \(ordered.joined(separator: ", "))"
    }
}

/// The queue of tag writes waiting for files (W2-E D, UC-JOB-10, migration v44). One per open
/// library (`TagWriteQueue.shared`, started by `DependencyContainer`).
///
/// Flush triggers: library open (after a short delay), `.libraryDriveDidMount` (also the
/// banner's `Try Again`), `.libraryRootDidChange`, and every tag edit or undo while the folder
/// is reachable (`requestFlush()`). `.libraryDriveDidUnmount` cancels a running flush.
///
/// Safety, like every file action: nothing runs while `Write tags to files` is off or the
/// library folder is unreachable; the folder is checked again before every file and the run
/// stops when it is gone (the rest waits); a missing file stays queued, is reported and never
/// blocks the others; rows of deleted tracks are removed first (manual cascade). The write
/// always takes the track's **current** database values for the stale fields.
@MainActor
@Observable
final class TagWriteQueue {
    static let shared = TagWriteQueue()

    struct Dependencies {
        var repository: @MainActor () -> TrackTagRepository?
        var libraryRoot: @MainActor () async -> String?
        var isEnabled: @MainActor () async -> Bool
        var writer: any TagWriting
        /// A write found the file missing while the folder was reachable (record it, DEC-014).
        var fileMissing: @MainActor (Int64) async -> Void
        /// The window's status bar (start/end of a run, failures).
        var statusBar: @MainActor () -> StatusBarCenter?

        /// The open library through `DependencyContainer.shared`.
        @MainActor
        static func live() -> Dependencies {
            Dependencies(
                repository: {
                    DependencyContainer.shared.databaseManager.map { TrackTagRepository(database: $0.pool) }
                },
                libraryRoot: { (try? await DependencyContainer.shared.configRepository?.getLibraryRoot()) ?? nil },
                isEnabled: { await TagWriteSetting.isEnabled(DependencyContainer.shared.configRepository) },
                writer: TrackTagWriter(),
                fileMissing: { id in
                    await DependencyContainer.shared.availabilityMonitor?.recordMissingAtUse(trackID: id)
                },
                statusBar: { ShellWindowModels.main.statusBar }
            )
        }
    }

    /// Writes waiting (blocked ones excluded) — the Activity echo `‹n› waiting for “Lexxar”`.
    private(set) var pendingCount = 0
    private(set) var isWriting = false
    private(set) var lastReport: TagFlushReport?

    /// Phase text while writing (UC-STATUS-06).
    static let loadingPhase = "Writing tags…"
    /// Rows read per batch.
    static let batchSize = 25

    @ObservationIgnored private var dependencies: Dependencies?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running: Task<TagFlushReport, Never>?
    @ObservationIgnored private var flushRequestedWhileRunning = false

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies
    }

    // MARK: Lifetime

    /// Start for the open library: observe the triggers and flush once after `initialDelay`.
    func start(_ dependencies: Dependencies, initialDelay: Duration = .seconds(5)) {
        stop()
        self.dependencies = dependencies
        let center = NotificationCenter.default
        for name in [Notification.Name.libraryDriveDidMount, .libraryRootDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestFlush(after: .seconds(2)) }
            })
        }
        observers.append(center.addObserver(forName: .libraryDriveDidUnmount, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        Task { await refreshCount() }
        requestFlush(after: initialDelay)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cancel()
    }

    /// Stop the running flush (finished files stay written; the rest waits).
    func cancel() {
        scheduled?.cancel()
        scheduled = nil
        running?.cancel()
    }

    // MARK: Flushing

    /// Ask for a flush; requests within `delay` merge, one during a run queues one more.
    func requestFlush(after delay: Duration = .milliseconds(300)) {
        guard dependencies != nil else { return }
        if running != nil {
            flushRequestedWhileRunning = true
            return
        }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            _ = await self?.flushNow()
        }
    }

    /// Run a flush now and wait for it (tests; the scheduled path uses it too).
    @discardableResult
    func flushNow() async -> TagFlushReport {
        if let running { _ = await running.value }
        guard let dependencies else { return TagFlushReport(outcome: .disabled) }
        let task = Task { await Self.flush(dependencies) }
        running = task
        isWriting = true
        let report = await task.value
        running = nil
        isWriting = false
        lastReport = report
        await refreshCount()
        NotificationCenter.default.post(name: .pendingTagWritesDidChange, object: nil)
        if let message = report.failureMessage { dependencies.statusBar()?.post(message) }
        if flushRequestedWhileRunning {
            flushRequestedWhileRunning = false
            if report.outcome == .finished { requestFlush() }
        }
        return report
    }

    func refreshCount() async {
        pendingCount = (try? await dependencies?.repository()?.pendingCount()) ?? 0
    }

    /// Whether the library folder can be written now (IMP-024: its volume is mounted and the
    /// folder exists).
    nonisolated static func isReachable(_ root: String?) -> Bool {
        guard let root, !root.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func flush(_ deps: Dependencies) async -> TagFlushReport {
        var report = TagFlushReport()
        guard await deps.isEnabled() else { return TagFlushReport(outcome: .disabled) }
        guard let repository = deps.repository() else { return TagFlushReport(outcome: .unreachable) }
        let root = await deps.libraryRoot()
        guard let root, isReachable(root) else { return TagFlushReport(outcome: .unreachable) }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        _ = try? await repository.removeOrphanedPendingWrites()

        // W3-ACT: register this flush as an Activity operation (`Write tags`, Automatic) with
        // `written of total` progress, per-file outcomes and the persisted result; until then the
        // status bar's loading phase is the only progress.
        let token = deps.statusBar()?.beginLoading(loadingPhase)
        defer { if let token { deps.statusBar()?.endLoading(token) } }

        var tried: Set<Int64> = []
        while true {
            guard !Task.isCancelled else { report.outcome = .cancelled; return report }
            guard let batch = try? await repository.pendingWrites(limit: batchSize, excluding: tried), !batch.isEmpty else { break }
            for pending in batch {
                tried.insert(pending.trackID)
                guard !Task.isCancelled else { report.outcome = .cancelled; return report }
                // Same rule as every file action: stop the moment the folder is gone.
                guard isReachable(root) else { report.outcome = .rootLost; return report }
                guard let track = try? await repository.fetchTracks(ids: [pending.trackID]).first else { continue }
                guard let organized = track.organizedPath, !organized.isEmpty else {
                    // The track has no file (any more): nothing to write.
                    _ = try? await repository.completeWrite(trackID: pending.trackID, revision: pending.revision)
                    continue
                }
                let fileURL = (organized as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: organized)
                    : rootURL.appendingPathComponent(organized)
                let request = TagWriteRequest(
                    fileURL: fileURL,
                    libraryRoot: rootURL,
                    values: TrackTagWriter.values(for: track, fields: pending.fields)
                )
                switch await deps.writer.write(request) {
                case .written, .nothingToWrite:
                    _ = try? await repository.completeWrite(trackID: pending.trackID, revision: pending.revision)
                    report.written += 1
                case .failed(.libraryFolderUnreachable):
                    report.outcome = .rootLost
                    return report
                case .failed(.fileMissing):
                    // The folder is there, the file isn't: record it, keep the write waiting.
                    guard isReachable(root) else { report.outcome = .rootLost; return report }
                    try? await repository.recordFailure(trackID: pending.trackID, revision: pending.revision,
                                                        reason: TagWriteFailure.fileMissing.reason, blocked: false)
                    await deps.fileMissing(pending.trackID)
                    report.missing += 1
                case .failed(let failure):
                    let blocked = failure.isPermanent || pending.attempts + 1 >= 3
                    try? await repository.recordFailure(trackID: pending.trackID, revision: pending.revision,
                                                        reason: failure.reason, blocked: blocked)
                    AppLogger.shared.warn("Tag write failed for track \(pending.trackID): \(failure.detail)", source: "Tags")
                    report.failures[failure.reason, default: 0] += 1
                }
            }
        }
        if report.written > 0 {
            AppLogger.shared.info("Wrote tags to \(report.written) files", source: "Tags")
        }
        return report
    }
}
