import Foundation
import Observation

/// A queue several operations of one kind share: the second waits (`Queued · Starts after
/// “…”`) instead of being rejected (PP-ACTIVITY-05, UC-JOB-03).
struct ActivityLane: Hashable, Sendable {
    let name: String
    init(_ name: String) { self.name = name }

    /// Every download batch, recommendation and reel download (one download pipeline).
    static let downloads = ActivityLane("downloads")
}

/// A start or end message for the status bar (UC-JOB-08). The shell turns it into a
/// `StatusBarCenter` message with the button (`Show in Activity` / `Show`).
struct ActivityStatusMessage: Equatable, Sendable {
    let text: String
    let operationID: UUID
    /// `Show in Activity` (start) / `Show` (end); `nil` = no button.
    let actionTitle: String?
}

/// What the place that started a job shows (UC-JOB-07): the same words and numbers as
/// Activity. Owners format it for their spot — playlist header `Importing · 12 of 44`
/// (`ActivityEcho.playlistText`), sync profile `Syncing 86 of 214` (`toolbarText`), a settings
/// job row `9,412 of 12,935 analysed`.
struct ActivityEcho: Equatable, Sendable {
    let operationID: UUID
    let kind: ActivityKind
    let state: ActivityState
    /// `Downloading`, `Syncing` — or the title verb the job chose (`Importing`).
    let verb: String
    /// `12 of 44`, `212 waiting`, or `nil` while indeterminate.
    let progressText: String?
    /// 0…1 when determinate.
    let fraction: Double?
    /// Why a queued / paused operation doesn't move (`Starts after “…”`, `Waiting for “Lexxar”`).
    let waitText: String?
    /// Items of this subject that still fail after the operation (live, see `ActivityFailureSource`).
    let failedCount: Int
    /// The result sentence of the last finished operation (`35 downloaded · 9 failed`).
    let resultText: String?

    /// `Downloading 12 of 44` (toolbar, sync profile row/header).
    var toolbarText: String {
        if let waitText, state == .queued || state == .paused { return waitText }
        return progressText.map { "\(verb) \($0)" } ?? "\(verb)…"
    }

    /// `Importing · 12 of 44` (playlist header and sidebar row, §15.5).
    var playlistText: String {
        if let waitText, state == .queued || state == .paused { return "Queued · \(waitText)" }
        return progressText.map { "\(verb) · \($0)" } ?? "\(verb)…"
    }
}

/// Injectable time source and timer (coalescing, grace periods) — tests drive both by hand.
protocol ActivityScheduling: Sendable {
    func now() -> Date
    /// Run `work` on the main actor after `delay` seconds.
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void)
}

/// The app's scheduler: wall clock + `DispatchQueue.main`.
struct SystemActivityScheduler: ActivityScheduling {
    func now() -> Date { Date() }
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) {
            MainActor.assumeIsolated { work() }
        }
    }
}

/// Posts a system notification for a finished operation (UC-JOB-12; opt-in, off by default).
@MainActor
protocol ActivityFinishNotifying: AnyObject {
    func operationDidFinish(_ operation: ActivityOperation)
}

// MARK: - ActivityCenter

/// **The one home of every long job** (DEC-044, UC-JOB-01…12). Every background job of the app
/// registers here; the toolbar Activity item, the Activity popover, the Activity window, the
/// status-bar start/end messages and the inline echo all read from it. Finished results persist
/// per library (`activity_operations`, v46) or app-level (`ActivityAppLevelStore`).
///
/// ## How to register a job
///
/// ```swift
/// // Anywhere — any actor, any thread (the handle is Sendable).
/// let job = ActivityCenter.shared.begin(
///     .folderScan, title: "Scan “\(folder.lastPathComponent)”",
///     subject: .folder(folder), itemNoun: .file,
///     controls: ActivityControls(cancelStyle: .afterThisFile, cancel: { task.cancel() })
/// )
/// for (index, file) in files.enumerated() {          // progress is coalesced (≤ 4/s)
///     job.update(completed: index, total: files.count, currentItem: file.lastPathComponent)
///     …
/// }
/// if Task.isCancelled { job.cancelled(ActivityResult(counts: [.init(.done, done, "imported")])) }
/// else { job.finish(ActivityResult(counts: [.init(.done, done, "imported"),
///                                           .init(.failed, failed, "failed")])) }
/// // A job that can fail as a whole: job.fail(cause: "“Lexxar” was not connected", fix: .runAgain)
/// ```
///
/// Rules the center enforces so jobs don't each invent them:
/// - **Honest controls:** a Cancel / Pause button exists only when the job declared the closure.
/// - **Queueing:** jobs in one `ActivityLane` run one at a time; call `await job.waitForTurn()`
///   before doing the work (it returns `false` when the user cancelled while it was queued).
/// - **Drive waits:** `job.setWaiting(.drive(volumeName:))` — never a failure (UC-JOB-10).
/// - **Short jobs** (`graceful: true`) appear only if they outlive `graceInterval` (UC-JOB-01).
/// - **Messages:** user-started jobs get `‹Kind› started — ‹n› ‹items›` and `‹Kind› finished —
///   ‹results›` in the status bar; automatic ones don't.
/// - **Nothing navigates, opens or takes focus when a job ends** (UC-JOB-12, N16).
@MainActor
@Observable
final class ActivityCenter {
    /// The app's center. Created on first use; persistence attaches when a library opens.
    nonisolated static let shared = ActivityCenter()

    // MARK: Configuration

    nonisolated let scheduler: any ActivityScheduling
    /// Progress updates of one operation are applied at most this often (coalescing).
    nonisolated let progressInterval: TimeInterval
    /// Short jobs (`graceful: true`) stay invisible this long (UC-JOB-01 "~2 s").
    nonisolated let graceInterval: TimeInterval

    // MARK: Observable state

    /// Operations of this session that are visible (running, queued, paused and finished).
    private(set) var operations: [ActivityOperation] = []
    /// Finished operations restored from the stores (earlier sessions).
    private(set) var history: [ActivityOperation] = []
    /// Increments once per visible operation that ends — the Activity item's bounce value.
    private(set) var finishedCount = 0
    /// Track ids that still fail, per attention operation (from `ActivityFailureSource`).
    private(set) var liveFailing: [UUID: Set<Int64>] = [:]
    /// The open library's id; operations started without one are app-level.
    private(set) var currentLibraryID: String?
    /// History couldn't be read (P-ACTIVITY-OPS.N04).
    private(set) var historyLoadFailed = false
    private(set) var isHistoryLoaded = false

    /// The status bar of the main window (set by the shell). `nil` = no messages.
    @ObservationIgnored var messageSink: ((ActivityStatusMessage) -> Void)?
    @ObservationIgnored weak var finishNotifier: (any ActivityFinishNotifying)?

    // MARK: Internals

    @ObservationIgnored private var hidden: [UUID: ActivityOperation] = [:]
    @ObservationIgnored private var lanes: [ActivityLane: [UUID]] = [:]
    @ObservationIgnored private var laneOf: [UUID: ActivityLane] = [:]
    @ObservationIgnored private var turnWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var lastProgressAt: [UUID: Date] = [:]
    @ObservationIgnored private var pendingProgress: [UUID: ActivityProgress] = [:]
    @ObservationIgnored private var flushScheduled: Set<UUID> = []
    /// Updates that arrived (from another thread) before their `begin` was applied.
    @ObservationIgnored private var early: [UUID: [@MainActor (ActivityCenter) -> Void]] = [:]
    @ObservationIgnored private var announce: Set<UUID> = []
    @ObservationIgnored private var quiet: Set<UUID> = []
    @ObservationIgnored private var persistent: Set<UUID> = []
    @ObservationIgnored private var libraryStore: (any ActivityHistoryStore)?
    @ObservationIgnored private var appStore: (any ActivityHistoryStore)?
    @ObservationIgnored private var failureSource: (any ActivityFailureSource)?
    @ObservationIgnored private let writer = ActivityPersistenceWriter()

    nonisolated init(scheduler: any ActivityScheduling = SystemActivityScheduler(),
                     progressInterval: TimeInterval = 0.25,
                     graceInterval: TimeInterval = 2) {
        self.scheduler = scheduler
        self.progressInterval = progressInterval
        self.graceInterval = graceInterval
    }

    // MARK: - Begin

    /// Registers a job and returns its handle. Callable from any thread or actor.
    ///
    /// - Parameters:
    ///   - lane: jobs in one lane run one at a time; the later ones are `Queued`.
    ///   - automatic: started by MLM, not the user (`Automatic`; no status-bar messages).
    ///   - graceful: a job that is usually done in under ~2 s — visible only if it outlives
    ///     `graceInterval`; a success within the grace period leaves no trace.
    ///   - quiet: no toolbar text and no status-bar messages (scheduled backup, file check);
    ///     it still appears in the popover, the window and the history.
    ///   - persists: write the result into the history (default `true`).
    nonisolated func begin(
        _ kind: ActivityKind,
        title: String,
        subject: ActivitySubject = .none,
        progress: ActivityProgress = .indeterminate,
        itemNoun: ActivityNoun = .item,
        messageName: String? = nil,
        controls: ActivityControls = .none,
        lane: ActivityLane? = nil,
        automatic: Bool = false,
        graceful: Bool = false,
        quiet: Bool = false,
        persists: Bool = true
    ) -> ActivityOperationHandle {
        let id = UUID()
        let startedAt = scheduler.now()
        perform { center in
            center.register(
                id: id, kind: kind, title: title, subject: subject, progress: progress,
                itemNoun: itemNoun, messageName: messageName ?? kind.messageName, controls: controls,
                lane: lane, automatic: automatic, graceful: graceful, quiet: quiet,
                persists: persists, startedAt: startedAt
            )
        }
        return ActivityOperationHandle(id: id, center: self)
    }

    private func register(
        id: UUID, kind: ActivityKind, title: String, subject: ActivitySubject,
        progress: ActivityProgress, itemNoun: ActivityNoun, messageName: String,
        controls: ActivityControls, lane: ActivityLane?, automatic: Bool, graceful: Bool,
        quiet isQuiet: Bool, persists: Bool, startedAt: Date
    ) {
        var state = ActivityState.running
        var wait: ActivityWait?
        if let lane {
            let ahead = lanes[lane, default: []]
            lanes[lane, default: []].append(id)
            laneOf[id] = lane
            if let headID = ahead.first, let head = operation(id: headID) ?? hidden[headID] {
                state = .queued
                wait = .turn(after: Self.turnName(head))
            }
        }
        let operation = ActivityOperation(
            id: id, kind: kind, title: title, subject: subject, state: state, wait: wait,
            progress: progress, result: nil, startedAt: startedAt, endedAt: nil,
            isAutomatic: automatic, libraryID: currentLibraryID, needsAttention: false,
            dismissedAt: nil, itemNoun: itemNoun, messageName: messageName, controls: controls,
            isFromHistory: false
        )
        if !automatic && !isQuiet { announce.insert(id) }
        if isQuiet { quiet.insert(id) }
        if persists { persistent.insert(id) }
        lastProgressAt[id] = startedAt

        if graceful {
            hidden[id] = operation
            scheduler.schedule(after: graceInterval) { [weak self] in self?.reveal(id) }
        } else {
            operations.append(operation)
            persist(operation)
            if announce.contains(id), state == .running { postStart(operation) }
        }
        // Calls that raced ahead of this registration (another thread).
        for work in early.removeValue(forKey: id) ?? [] { work(self) }
        if state == .running, let waiter = turnWaiters.removeValue(forKey: id) { waiter.resume(returning: true) }
    }

    private func reveal(_ id: UUID) {
        guard let operation = hidden.removeValue(forKey: id) else { return }
        operations.append(operation)
        persist(operation)
    }

    // MARK: - Lookup

    /// Live (this session) or historic operation by id.
    func operation(id: UUID) -> ActivityOperation? {
        operations.first { $0.id == id } ?? history.first { $0.id == id }
    }

    /// Is the operation registered but still inside its grace period?
    func isHidden(_ id: UUID) -> Bool { hidden[id] != nil }

    private func update(_ id: UUID, _ change: (inout ActivityOperation) -> Void) {
        if let index = operations.firstIndex(where: { $0.id == id }) {
            change(&operations[index])
        } else if hidden[id] != nil {
            change(&hidden[id]!)
        }
    }

    private func isKnown(_ id: UUID) -> Bool {
        hidden[id] != nil || operations.contains { $0.id == id }
    }

    /// Runs `work` for `id` now, or when its `begin` arrives (calls from another thread may
    /// overtake the registration).
    fileprivate func whenKnown(_ id: UUID, _ work: @escaping @MainActor (ActivityCenter) -> Void) {
        if isKnown(id) { work(self) } else { early[id, default: []].append(work) }
    }

    // MARK: - Handle operations (main actor)

    fileprivate func applyProgress(_ id: UUID, _ progress: ActivityProgress) {
        guard let current = operation(id: id) ?? hidden[id], current.state.isActive else { return }
        let now = scheduler.now()
        let last = lastProgressAt[id] ?? .distantPast
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= progressInterval {
            pendingProgress[id] = nil
            lastProgressAt[id] = now
            update(id) { $0.progress = progress }
            return
        }
        pendingProgress[id] = progress
        guard !flushScheduled.contains(id) else { return }
        flushScheduled.insert(id)
        scheduler.schedule(after: progressInterval - elapsed) { [weak self] in
            self?.flushProgress(id)
        }
    }

    private func flushProgress(_ id: UUID) {
        flushScheduled.remove(id)
        guard let progress = pendingProgress.removeValue(forKey: id) else { return }
        guard let current = operation(id: id) ?? hidden[id], current.state.isActive else { return }
        lastProgressAt[id] = scheduler.now()
        update(id) { $0.progress = progress }
    }

    fileprivate func applyState(_ id: UUID, _ state: ActivityState, wait: ActivityWait?) {
        guard state.isActive else { return }
        update(id) { operation in
            guard operation.state.isActive else { return }
            operation.state = state
            operation.wait = wait
        }
    }

    fileprivate func applyControls(_ id: UUID, _ controls: ActivityControls) {
        // A finished operation keeps only `Run Again` — never a Cancel that can't cancel.
        update(id) { operation in
            operation.controls = operation.state.isActive ? controls : ActivityControls(runAgain: controls.runAgain)
        }
    }

    fileprivate func applyTitle(_ id: UUID, _ title: String, subject: ActivitySubject?) {
        update(id) { operation in
            operation.title = title
            if let subject { operation.subject = subject }
        }
    }

    /// Ends an operation (idempotent: a second end is ignored).
    fileprivate func end(_ id: UUID, state: ActivityState, result: ActivityResult) {
        guard state.isTerminal else { return }
        let wasHidden = hidden[id] != nil
        guard let current = operation(id: id) ?? hidden[id], current.state.isActive else { return }
        pendingProgress[id] = nil
        let needsAttention = state == .failed || result.failedCount > 0 || !result.failureGroups.isEmpty
        var ended = current
        ended.state = state
        ended.wait = nil
        ended.result = result
        ended.endedAt = scheduler.now()
        ended.needsAttention = needsAttention
        ended.controls = ActivityControls(runAgain: current.controls.runAgain)
        if let total = ended.progress.total, state == .completed { ended.progress.completed = total }

        leaveLane(id, title: current.title)
        if let waiter = turnWaiters.removeValue(forKey: id) { waiter.resume(returning: false) }

        if wasHidden {
            hidden[id] = nil
            // A short job that went fine leaves no trace (UC-JOB-01); a failure always does.
            guard state == .failed || needsAttention else {
                forget(id)
                return
            }
            operations.append(ended)
        } else if let index = operations.firstIndex(where: { $0.id == id }) {
            operations[index] = ended
        }
        finishedCount += 1
        persist(ended)
        if announce.contains(id) || (wasHidden && !quiet.contains(id) && !ended.isAutomatic) {
            postEnd(ended)
        }
        if needsAttention { scheduleFailingRefresh(ids: [id]) }
        finishNotifier?.operationDidFinish(ended)
        forget(id)
        trimSessionOperations()
    }

    /// Removes an operation that turned out to do nothing (a scheduled backup that wasn't due):
    /// no result, no history row, no message.
    fileprivate func discard(_ id: UUID) {
        guard let current = operation(id: id) ?? hidden[id], current.state.isActive else { return }
        let wasPersisted = persistent.contains(id) && hidden[id] == nil
        pendingProgress[id] = nil
        leaveLane(id, title: current.title)
        if let waiter = turnWaiters.removeValue(forKey: id) { waiter.resume(returning: false) }
        hidden[id] = nil
        operations.removeAll { $0.id == id }
        if wasPersisted {
            enqueueWrite(for: current.libraryID) { store in try await store.delete(id: id) }
        }
        forget(id)
    }

    private func forget(_ id: UUID) {
        lastProgressAt[id] = nil
        flushScheduled.remove(id)
        announce.remove(id)
        quiet.remove(id)
        persistent.remove(id)
    }

    // MARK: - Lanes

    fileprivate func waitForTurn(_ id: UUID) async -> Bool {
        if let current = operation(id: id) ?? hidden[id] {
            if current.state.isTerminal { return false }
            guard let lane = laneOf[id] else { return true }
            if lanes[lane]?.first == id { return true }
        }
        return await withCheckedContinuation { continuation in
            turnWaiters[id] = continuation
        }
    }

    /// How a queued operation names the one it waits for: `“Liked on SoundCloud”` (its
    /// subject) or its title.
    static func turnName(_ operation: ActivityOperation) -> String {
        if let name = operation.subject.name, operation.subject.kind != .none { return "“\(name)”" }
        return operation.title
    }

    private func leaveLane(_ id: UUID, title: String) {
        guard let lane = laneOf.removeValue(forKey: id) else { return }
        let wasHead = lanes[lane]?.first == id
        lanes[lane]?.removeAll { $0 == id }
        guard wasHead, let next = lanes[lane]?.first else { return }
        update(next) { operation in
            if operation.state == .queued { operation.state = .running; operation.wait = nil }
        }
        if let started = operation(id: next), announce.contains(next) { postStart(started) }
        // The ones behind now wait for the new head.
        if let head = operation(id: next) ?? hidden[next] {
            let headTitle = Self.turnName(head)
            for waiting in (lanes[lane] ?? []).dropFirst() {
                update(waiting) { operation in
                    if operation.state == .queued { operation.wait = .turn(after: headTitle) }
                }
            }
        }
        if let waiter = turnWaiters.removeValue(forKey: next) { waiter.resume(returning: true) }
    }

    // MARK: - User actions

    /// `Cancel` / `Cancel After This Track`. A queued operation in a lane is cancelled by the
    /// center (it never started); a running one calls the job's own cancel.
    func cancel(_ id: UUID) {
        guard let current = operation(id: id), current.state.isActive else { return }
        if current.state == .queued, laneOf[id] != nil, lanes[laneOf[id]!]?.first != id {
            end(id, state: .cancelled, result: ActivityResult(summary: "Cancelled before it started"))
            return
        }
        current.controls.cancel?()
    }

    func pause(_ id: UUID) {
        guard let current = operation(id: id), current.state == .running, current.controls.canPause else { return }
        current.controls.pause?()
        applyState(id, .paused, wait: .user)
    }

    func resume(_ id: UUID) {
        guard let current = operation(id: id), current.state == .paused, current.controls.canPause else { return }
        current.controls.resume?()
        applyState(id, .running, wait: nil)
    }

    /// Retry the failed tracks of an operation through its own retry control.
    func retryFailed(_ id: UUID, trackIDs: [Int64]? = nil) {
        guard let op = operation(id: id) else { return }
        let ids = trackIDs ?? Array(stillFailing(op))
        guard !ids.isEmpty else { return }
        (op.controls.retry ?? retryHandler)?(ids)
    }

    /// Fallback retry for failed downloads of operations restored from history (no closure of
    /// their own): set by the app to `DownloadViewModel.retryAllFailed`.
    @ObservationIgnored var retryHandler: (@Sendable ([Int64]) -> Void)?

    /// `Dismiss` in Needs attention: the groups leave the toolbar text and the list; the tracks
    /// keep their `Download failed` state and stay retryable from All Tracks.
    func dismiss(_ ids: [UUID]) {
        let now = scheduler.now()
        var stored: [UUID] = []
        for id in ids {
            if let index = operations.firstIndex(where: { $0.id == id }) {
                operations[index].dismissedAt = now
                stored.append(id)
            } else if let index = history.firstIndex(where: { $0.id == id }) {
                history[index].dismissedAt = now
                stored.append(id)
            }
        }
        for id in stored {
            let libraryID = operation(id: id)?.libraryID
            enqueueWrite(for: libraryID) { store in try await store.markDismissed(ids: [id], at: now) }
        }
    }

    /// `Remove from History` (CM-OPS-ROW).
    func removeFromHistory(_ id: UUID) {
        guard let op = operation(id: id), op.state.isTerminal else { return }
        operations.removeAll { $0.id == id }
        history.removeAll { $0.id == id }
        liveFailing[id] = nil
        enqueueWrite(for: op.libraryID) { store in try await store.delete(id: id) }
    }

    // MARK: - Persistence

    /// Attaches the open library's history: closes what a quit interrupted, flags missing
    /// subjects, prunes, loads, and refreshes which failures still fail.
    func attachLibrary(id libraryID: String, store: any ActivityHistoryStore,
                       failureSource: (any ActivityFailureSource)?) async {
        currentLibraryID = libraryID
        libraryStore = store
        self.failureSource = failureSource
        await loadHistory(from: store, libraryID: libraryID)
        await refreshFailing()
    }

    /// Attaches the app-level store (operations without a library).
    func attachAppLevel(store: any ActivityHistoryStore) async {
        appStore = store
        await loadHistory(from: store, libraryID: nil)
    }

    private func loadHistory(from store: any ActivityHistoryStore, libraryID: String?) async {
        let now = scheduler.now()
        let sessionIDs = Set(operations.map(\.id))
        do {
            try await store.closeInterrupted(at: now)
            try await store.markMissingSubjects()
            try await store.prune(now: now)
            let records = try await store.load(now: now)
            let restored = records
                .filter { !sessionIDs.contains($0.id) }
                .map { $0.operation(libraryID: libraryID) }
            history.removeAll { $0.libraryID == libraryID }
            history.append(contentsOf: restored)
            history.sort { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            historyLoadFailed = false
        } catch {
            historyLoadFailed = true
            AppLogger.shared.error("Couldn’t load the Activity history: \(error.localizedDescription)", source: "Activity")
        }
        isHistoryLoaded = true
    }

    /// Reload the history (window `Try Again`, P-ACTIVITY-OPS.N04).
    func reloadHistory() async {
        if let libraryStore, let currentLibraryID { await loadHistory(from: libraryStore, libraryID: currentLibraryID) }
        if let appStore { await loadHistory(from: appStore, libraryID: nil) }
        await refreshFailing()
    }

    /// Re-check subjects after something was deleted (playlist, sync profile).
    func refreshSubjects() async {
        guard let libraryStore else { return }
        let changed = (try? await libraryStore.markMissingSubjects()) ?? 0
        if changed > 0, let currentLibraryID { await loadHistory(from: libraryStore, libraryID: currentLibraryID) }
    }

    private func persist(_ operation: ActivityOperation) {
        guard persistent.contains(operation.id) else { return }
        let record = ActivityOperationRecord(operation)
        enqueueWrite(for: operation.libraryID) { store in try await store.save(record) }
    }

    private func enqueueWrite(for libraryID: String?,
                              _ write: @escaping @Sendable (any ActivityHistoryStore) async throws -> Void) {
        let store: (any ActivityHistoryStore)?
        if let libraryID {
            store = libraryID == currentLibraryID ? libraryStore : nil
        } else {
            store = appStore
        }
        guard let store else { return }
        writer.enqueue {
            do { try await write(store) } catch {
                AppLogger.shared.error("Couldn’t save an Activity result: \(error.localizedDescription)", source: "Activity")
            }
        }
    }

    /// Waits until every queued history write has finished (tests, quit).
    func flushPersistence() async {
        await writer.drain()
    }

    /// Keep the session's finished operations within the retention count.
    private func trimSessionOperations() {
        let finished = operations.filter { $0.state.isTerminal }
        guard finished.count > ActivityRetention.maxCount else { return }
        let keep = Set(finished.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            .prefix(ActivityRetention.maxCount).map(\.id))
        operations.removeAll { $0.state.isTerminal && !keep.contains($0.id) && !$0.needsAttention }
    }

    // MARK: - Live failures (the `‹n› failed` agreement)

    /// Asks the failure source which named tracks still fail (call after downloads and edits).
    /// An operation whose tracks were all fixed leaves Needs attention for good.
    /// Schedules `refreshFailing` from any thread (after a download batch, an edit).
    nonisolated func scheduleFailingRefresh(ids: [UUID]? = nil) {
        perform { center in Task { await center.refreshFailing(ids: ids) } }
    }

    func refreshFailing(ids: [UUID]? = nil) async {
        guard let failureSource else { return }
        let candidates = allOperations.filter { op in
            op.needsAttention && !(op.result?.failedTrackIDs.isEmpty ?? true) && (ids?.contains(op.id) ?? true)
        }
        for op in candidates {
            guard let failing = try? await failureSource.failingTrackIDs(in: op.result?.failedTrackIDs ?? []) else { continue }
            liveFailing[op.id] = failing
            if failing.isEmpty, op.state != .failed {
                markFixed(op.id)
            }
        }
    }

    private func markFixed(_ id: UUID) {
        if let index = operations.firstIndex(where: { $0.id == id }) { operations[index].needsAttention = false }
        if let index = history.firstIndex(where: { $0.id == id }) { history[index].needsAttention = false }
        let libraryID = operation(id: id)?.libraryID
        enqueueWrite(for: libraryID) { store in try await store.clearAttention(id: id) }
    }

    /// Failed tracks of an operation that still fail (falls back to the recorded ids before the
    /// first check).
    func stillFailing(_ operation: ActivityOperation) -> Set<Int64> {
        let recorded = Set(operation.result?.failedTrackIDs ?? [])
        guard let live = liveFailing[operation.id] else { return recorded }
        return recorded.intersection(live)
    }

    // MARK: - Reading

    /// Session and history together, newest start first.
    var allOperations: [ActivityOperation] {
        (operations + history).sorted { $0.startedAt > $1.startedAt }
    }

    /// Queued, running and paused operations, oldest first.
    var activeOperations: [ActivityOperation] {
        operations.filter { $0.state.isActive }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Finished operations, newest end first.
    var finishedOperations: [ActivityOperation] {
        (operations.filter { $0.state.isTerminal } + history)
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
    }

    func isQuiet(_ id: UUID) -> Bool { quiet.contains(id) }

    /// The inline echo for a subject (UC-JOB-07): the active operation for it, else the last
    /// finished one that still has failures. `nil` when there is nothing to say.
    func echo(for subject: ActivitySubject) -> ActivityEcho? {
        func matches(_ op: ActivityOperation) -> Bool {
            guard op.subject.kind == subject.kind, subject.kind != .none else { return false }
            switch subject.kind {
            case .playlist, .syncProfile: return op.subject.id == subject.id
            case .settings, .folder: return op.subject.detail == subject.detail
            default: return true
            }
        }
        if let active = activeOperations.first(where: matches) {
            return ActivityEcho(
                operationID: active.id, kind: active.kind, state: active.state,
                verb: ActivityPresentation.verb(for: active),
                progressText: ActivityPresentation.progressText(active.progress),
                fraction: active.progress.fraction,
                waitText: active.wait?.sentence,
                failedCount: 0,
                resultText: nil
            )
        }
        guard let last = finishedOperations.first(where: matches) else { return nil }
        let failed = last.needsAttention && last.dismissedAt == nil ? stillFailing(last).count : 0
        return ActivityEcho(
            operationID: last.id, kind: last.kind, state: last.state,
            verb: ActivityPresentation.verb(for: last), progressText: nil, fraction: nil,
            waitText: nil, failedCount: failed, resultText: last.result?.sentence
        )
    }

    // MARK: - Status-bar messages (UC-JOB-08)

    private func postStart(_ operation: ActivityOperation) {
        guard let sink = messageSink else { return }
        sink(ActivityStatusMessage(text: ActivityPresentation.startMessage(operation),
                                   operationID: operation.id, actionTitle: "Show in Activity"))
    }

    private func postEnd(_ operation: ActivityOperation) {
        guard let sink = messageSink else { return }
        sink(ActivityStatusMessage(text: ActivityPresentation.endMessage(operation),
                                   operationID: operation.id, actionTitle: "Show"))
    }

    // MARK: - Thread hop

    /// Runs `work` on the main actor: at once when already on the main thread, else queued in
    /// FIFO order on the main queue (the order of calls from one thread is kept).
    nonisolated func perform(_ work: @escaping @MainActor @Sendable (ActivityCenter) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(self) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work(self) }
            }
        }
    }
}

// MARK: - Handle

/// A job's handle to its operation. `Sendable`: use it from any task, thread or actor. Every
/// call is applied on the main actor in call order; calls after the end are ignored.
struct ActivityOperationHandle: Sendable, Hashable {
    let id: UUID
    let center: ActivityCenter

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Progress (coalesced: at most every `progressInterval`; the last value always lands).
    func update(_ progress: ActivityProgress) {
        let id = id
        center.perform { center in center.whenKnown(id) { $0.applyProgress(id, progress) } }
    }

    func update(completed: Int, total: Int?, currentItem: String? = nil, currentFraction: Double = 0,
                detail: String? = nil) {
        update(ActivityProgress(completed: completed, total: total, currentFraction: currentFraction,
                                currentItem: currentItem, detail: detail))
    }

    /// Running ↔ Paused ↔ Queued, with the reason in words.
    func setState(_ state: ActivityState, wait: ActivityWait? = nil) {
        let id = id
        center.perform { center in center.whenKnown(id) { $0.applyState(id, state, wait: wait) } }
    }

    /// `nil` = running again; `.drive(volumeName:)` = waits for the drive (UC-JOB-10), never a
    /// failure.
    func setWaiting(_ wait: ActivityWait?) {
        setState(wait == nil ? .running : .queued, wait: wait)
    }

    func setControls(_ controls: ActivityControls) {
        let id = id
        center.perform { center in center.whenKnown(id) { $0.applyControls(id, controls) } }
    }

    func setTitle(_ title: String, subject: ActivitySubject? = nil) {
        let id = id
        center.perform { center in center.whenKnown(id) { $0.applyTitle(id, title, subject: subject) } }
    }

    /// Completed (the result may carry failures: `35 downloaded · 9 failed`).
    func finish(_ result: ActivityResult = .empty) {
        end(.completed, result)
    }

    /// Failed — nothing was achieved. `cause` in plain words, with the one fix.
    func fail(cause: String, fix: ActivityFix? = nil, result: ActivityResult = .empty) {
        var result = result
        result.failureCause = cause
        if result.failureGroups.isEmpty {
            result.failureGroups = [ActivityFailureGroup(cause: cause, count: 1, fix: fix, isRetryable: fix != nil)]
        }
        end(.failed, result)
    }

    /// Cancelled by the user (or stopped by a quit / a disconnect); done work is kept.
    func cancelled(_ result: ActivityResult = .empty) {
        end(.cancelled, result)
    }

    /// The job turned out to have nothing to do: the operation disappears without a trace.
    func discard() {
        let id = id
        center.perform { center in center.whenKnown(id) { $0.discard(id) } }
    }

    private func end(_ state: ActivityState, _ result: ActivityResult) {
        let id = id
        center.perform { center in center.whenKnown(id) { $0.end(id, state: state, result: result) } }
    }

    /// For jobs in a lane: suspends while earlier jobs of the lane run. `false` = the user
    /// cancelled it while it was queued — don't start the work.
    func waitForTurn() async -> Bool {
        await center.waitForTurn(id)
    }
}

// MARK: - Ordered history writes

/// One task drains the history writes in the order they were queued.
final class ActivityPersistenceWriter: @unchecked Sendable {
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.continuation = continuation
        Task.detached(priority: .utility) {
            for await job in stream { await job() }
        }
    }

    func enqueue(_ job: @escaping @Sendable () async -> Void) {
        continuation.yield(job)
    }

    /// Returns once every job queued before this call has run.
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            continuation.yield { done.resume() }
        }
    }
}
