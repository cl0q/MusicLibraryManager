import Foundation
import Observation

extension Notification.Name {
    /// Posted (main thread) when waiting tag writes were added or written, so Info ▸ File
    /// refreshes its `Tag changes waiting for “‹Volume›”` echo.
    static let pendingTagWritesDidChange = Notification.Name("MLMPendingTagWritesDidChange")
}

/// Something that writes one file's tags (`TrackTagWriter`; fakes in tests).
protocol TagWriting: Sendable {
    /// Write `request`; `captureOriginals` receives the file's own values of
    /// `request.needOriginals` before anything is written.
    func write(_ request: TagWriteRequest, captureOriginals: @escaping TagOriginalsCapture) async -> TagWriteOutcome
}

extension TrackTagWriter: TagWriting {}

/// What one flush did.
struct TagFlushReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Every waiting write was tried.
        case finished
        /// `Write tags to files` is off: nothing was touched (or the run stopped when it was
        /// turned off).
        case disabled
        /// The library folder isn't reachable: nothing was tried.
        case unreachable
        /// The library folder changed and its file check hasn't completed yet (S2).
        case waitingForFileCheck
        /// The library folder went away during the run: it stopped; the rest waits.
        case rootLost
        /// ffmpeg / ffprobe aren't installed: the run stopped, nothing was counted (S1).
        case toolMissing
        case cancelled
    }

    var outcome: Outcome = .finished
    var written = 0
    /// Files that weren't found (the folder was there): they stay queued (S3).
    var missing = 0
    /// Writes put off because the file is playing (S11).
    var deferred = 0
    /// Failed writes by plain reason (`WAV isn’t supported`: 2).
    var failures: [String: Int] = [:]

    var failedCount: Int { failures.values.reduce(0, +) + missing }

    /// `Tags of 2 files couldn’t be written — WAV isn’t supported` (UC-STATUS-04 shape);
    /// nil when nothing failed.
    var failureMessage: String? {
        if outcome == .toolMissing { return "Tag changes are waiting — \(TagWriteFailure.toolMissing.reason)" }
        var reasons = failures
        if missing > 0 { reasons[TagWriteFailure.fileMissing.reason, default: 0] += missing }
        let total = reasons.values.reduce(0, +)
        guard total > 0 else { return nil }
        let ordered = reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        let files = total == 1 ? "1 file" : "\(total.formatted(.number)) files"
        return "Tags of \(files) couldn’t be written — \(ordered.joined(separator: ", "))"
    }
}

/// The queue of tag writes waiting for files (W2-E, UC-JOB-10, migrations v44 and v53). One per
/// open library (`TagWriteQueue.shared`, started by `DependencyContainer`).
///
/// Flush triggers: library open (after a delay), `.libraryDriveDidMount` (also the banner's
/// `Try Again`), a tag edit or undo while the folder is reachable (debounced), the setting
/// turned on, `Try Again` in Info ▸ File. **Not** `.libraryRootDidChange`: after the folder
/// changes, waiting writes hold until the availability monitor's next file check *completed*
/// (not aborted as suspicious) — another disk at the same path must not get these tags (S2).
/// `.libraryDriveDidUnmount` cancels a running flush.
///
/// One file at a time at utility priority, cancellable; the playing track's file is put off
/// (S11). Nothing runs while `Write tags to files` is off (re-checked before every file) or
/// the folder is unreachable (re-checked before every file; the run stops when it's gone). A
/// file that isn't found stays queued as `file not found` without touching the track's
/// availability — the monitor's file checks decide that (S3). Rows of deleted tracks are
/// removed first (manual cascade). A file only ever receives a typed value or its own pre-MLM
/// value (`TagFieldState`, B1).
@MainActor
@Observable
final class TagWriteQueue {
    static let shared = TagWriteQueue()

    struct Dependencies {
        var repository: @MainActor () -> TrackTagRepository?
        var libraryRoot: @MainActor () async -> String?
        var isEnabled: @MainActor () async -> Bool
        var writer: any TagWriting
        /// The window's status bar (start/end of a run, failures).
        var statusBar: @MainActor () -> StatusBarCenter?
        /// The track whose file is playing now (its write is put off; S11).
        var playingTrackID: @MainActor () -> Int64? = { nil }
        /// Calls back after every file check of the availability monitor with whether it
        /// completed (S2). Registered once in `start`.
        var observeFileChecks: @MainActor (_ onFinish: @escaping @MainActor (_ completed: Bool) -> Void) -> Void = { _ in }

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
                statusBar: { ShellWindowModels.main.statusBar },
                playingTrackID: { DependencyContainer.shared.playbackViewModel?.currentTrack?.id },
                observeFileChecks: { onFinish in
                    @MainActor func watch() {
                        guard let monitor = DependencyContainer.shared.availabilityMonitor else { return }
                        withObservationTracking {
                            _ = monitor.lastReport
                        } onChange: {
                            Task { @MainActor in
                                onFinish(monitor.lastReport?.outcome == .completed)
                                watch()
                            }
                        }
                    }
                    watch()
                }
            )
        }
    }

    /// Writes waiting (blocked ones excluded) — the Activity echo `‹n› waiting for “Lexxar”`.
    private(set) var pendingCount = 0
    private(set) var isWriting = false
    private(set) var lastReport: TagFlushReport?
    /// The library folder changed; writes hold until a file check completed (S2).
    private(set) var awaitingFileCheck = false

    /// Phase text while writing (UC-STATUS-06).
    static let loadingPhase = "Writing tags…"
    /// Rows read per batch.
    static let batchSize = 25
    /// Debounce after an edit: a 500-track edit doesn't start rewriting while the user works.
    nonisolated static let editDelay: Duration = .seconds(3)
    /// Retry of writes put off because their file was playing.
    nonisolated static let deferredRetry: Duration = .seconds(60)

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
        awaitingFileCheck = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .libraryDriveDidMount, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestFlush(after: .seconds(2)) }
        })
        observers.append(center.addObserver(forName: .libraryRootDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryRootDidChange() }
        })
        observers.append(center.addObserver(forName: .libraryDriveDidUnmount, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        dependencies.observeFileChecks { [weak self] completed in self?.fileCheckDidFinish(completed: completed) }
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

    /// The library folder was changed (S2): stop, and hold every write until its file check
    /// completed.
    func libraryRootDidChange() {
        awaitingFileCheck = true
        cancel()
    }

    /// A file check finished: a completed one releases the writes held after a folder change.
    func fileCheckDidFinish(completed: Bool) {
        guard awaitingFileCheck, completed else { return }
        awaitingFileCheck = false
        requestFlush()
    }

    // MARK: Flushing

    /// Ask for a flush; requests within `delay` merge, one during a run queues one more.
    func requestFlush(after delay: Duration = TagWriteQueue.editDelay) {
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
        guard !awaitingFileCheck else { return TagFlushReport(outcome: .waitingForFileCheck) }
        let task = Task(priority: .utility) { await Self.flush(dependencies) }
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
            // Also after a cancelled run: a library just opened must not lose its first flush.
            flushRequestedWhileRunning = false
            requestFlush(after: .milliseconds(300))
        } else if report.deferred > 0, report.outcome == .finished {
            requestFlush(after: Self.deferredRetry)
        }
        return report
    }

    func refreshCount() async {
        pendingCount = (try? await dependencies?.repository()?.pendingCount()) ?? 0
    }

    /// `Try Again` on a write that was refused or failed for good: one more attempt.
    func retry(trackID: Int64) async {
        do {
            try await dependencies?.repository()?.unblock(trackID: trackID)
        } catch {
            AppLogger.shared.error("Couldn’t unblock the tag write of track \(trackID): \(error)", source: "Tags")
        }
        NotificationCenter.default.post(name: .pendingTagWritesDidChange, object: nil)
        requestFlush(after: .milliseconds(300))
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

        let activityJob = TagWriteActivity.begin()  // W3-ACT: `Write tags to files`, Automatic
        defer { TagWriteActivity.end(activityJob, with: report) }
        let token = deps.statusBar()?.beginLoading(loadingPhase)
        defer { if let token { deps.statusBar()?.endLoading(token) } }

        do {
            try await repository.removeOrphanedPendingWrites()
            try await writeAll(&report, deps: deps, repository: repository, root: root, rootURL: rootURL)
        } catch {
            AppLogger.shared.error("Tag writes stopped: \(error)", source: "Tags")
            report.outcome = .cancelled
        }
        if report.written > 0 {
            AppLogger.shared.info("Wrote tags to \(report.written) files", source: "Tags")
        }
        return report
    }

    private static func writeAll(
        _ report: inout TagFlushReport,
        deps: Dependencies,
        repository: TrackTagRepository,
        root: String,
        rootURL: URL
    ) async throws {
        var after: Int64?
        while true {
            guard !Task.isCancelled else { report.outcome = .cancelled; return }
            let batch = try await repository.pendingWrites(limit: batchSize, afterTrackID: after)
            guard !batch.isEmpty else { break }
            for pending in batch {
                after = pending.trackID
                guard !Task.isCancelled else { report.outcome = .cancelled; return }
                // Turned off meanwhile: stop before the next file.
                guard await deps.isEnabled() else { report.outcome = .disabled; return }
                // Same rule as every file action: stop the moment the folder is gone.
                guard isReachable(root) else { report.outcome = .rootLost; return }
                // Never rewrite the file that is playing; try again later.
                if deps.playingTrackID() == pending.trackID {
                    report.deferred += 1
                    continue
                }
                guard let track = try await repository.fetchTracks(ids: [pending.trackID]).first else { continue }
                guard let organized = track.organizedPath, !organized.isEmpty else {
                    // The track has no file (any more): nothing to write.
                    try await repository.completeWrite(trackID: pending.trackID, revision: pending.revision)
                    continue
                }
                let fileURL = (organized as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: organized)
                    : rootURL.appendingPathComponent(organized)
                let plan = try await Self.plan(pending, repository: repository)
                guard !plan.targets.isEmpty else {
                    // Only undone edits MLM never wrote: the file stays as it is.
                    try await repository.forgetRestoredFields(trackID: pending.trackID, fields: plan.restored)
                    try await repository.completeWrite(trackID: pending.trackID, revision: pending.revision)
                    continue
                }
                var request = TagWriteRequest(fileURL: fileURL, libraryRoot: rootURL, targets: plan.targets, needOriginals: plan.needOriginals)
                request.expectedDuration = track.duration
                request.expectedFormat = track.format
                let trackID = pending.trackID
                let outcome = await deps.writer.write(request) { originals in
                    try await repository.recordOriginals(trackID: trackID, values: originals)
                }
                switch outcome {
                case .written, .nothingToWrite:
                    try await repository.forgetRestoredFields(trackID: pending.trackID, fields: plan.restored)
                    try await repository.completeWrite(trackID: pending.trackID, revision: pending.revision)
                    report.written += 1
                case .failed(.libraryFolderUnreachable):
                    report.outcome = .rootLost
                    return
                case .failed(.cancelled):
                    report.outcome = .cancelled
                    return
                case .failed(.toolMissing):
                    // Nothing is counted: every waiting write waits for ffmpeg (S1).
                    report.outcome = .toolMissing
                    return
                case .failed(.fileMissing):
                    // The folder is there, the file isn't: it stays queued. Whether the track is
                    // `File missing` is the file checks' decision, not this queue's (S3).
                    try await repository.recordFailure(trackID: pending.trackID, revision: pending.revision,
                                                       reason: TagWriteFailure.fileMissing.reason, blocked: false)
                    report.missing += 1
                case .failed(let failure):
                    try await repository.recordFailure(trackID: pending.trackID, revision: pending.revision,
                                                       reason: failure.reason, blocked: failure.isPermanent)
                    AppLogger.shared.warn("Tag write failed for track \(pending.trackID): \(failure.detail)", source: "Tags")
                    report.failures[failure.reason, default: 0] += 1
                }
            }
        }
    }

    /// What a pending track's file gets: typed values (capturing the file's originals on the
    /// first write) and captured originals for undone fields; undone fields MLM never wrote
    /// are dropped without touching the file.
    struct Plan: Equatable {
        var targets: [TrackTagField: TagFileTarget] = [:]
        var needOriginals: Set<TrackTagField> = []
        /// Fields back at `.original`: forgotten once the file carries its own value again.
        var restored: Set<TrackTagField> = []
    }

    static func plan(_ pending: PendingTagWrite, repository: TrackTagRepository) async throws -> Plan {
        let states = try await repository.fieldStates(trackID: pending.trackID)
        var plan = Plan()
        for field in pending.fields {
            guard let state = states[field] else { continue }
            switch state.intent {
            case .typed(let value):
                plan.targets[field] = .typed(value)
                if state.original == nil { plan.needOriginals.insert(field) }
                // A typed year that is the year of the file's own full date keeps that date.
                if field == .year, let value, let original = state.original?.value, original.hasPrefix(value + "-") {
                    plan.targets[field] = .restore(original)
                }
            case .original:
                plan.restored.insert(field)
                if let original = state.original { plan.targets[field] = .restore(original.value) }
            }
        }
        return plan
    }
}
