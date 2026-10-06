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
    /// A running operation without any progress or state change for this long is flagged
    /// `No progress for ‹n› min` (state stays Running). Not for queued, paused or drive waits.
    nonisolated let stallInterval: TimeInterval

    // MARK: Observable state

    /// Operations of this session that are visible (running, queued, paused and finished).
    private(set) var operations: [ActivityOperation] = []
    /// Finished operations restored from the stores (earlier sessions).
    private(set) var history: [ActivityOperation] = []
    /// Increments once per visible operation that ends — the Activity item's bounce value.
    private(set) var finishedCount = 0
    /// Every track of the library in the `Download failed` state now (`ActivityFailureSource`,
    /// the scope's own predicate); `nil` until the first check.
    private(set) var failingNow: Set<Int64>?
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
    /// Last progress or state change per operation (the stall watchdog).
    private(set) var lastChangeAt: [UUID: Date] = [:]
    /// Operations whose start is not written (their row appears with the result only).
    @ObservationIgnored private var noStartRecord: Set<UUID> = []
    /// History writes that arrive while a store is being attached (written after the close of
    /// interrupted rows, so this session's rows are never mistaken for interrupted ones).
    @ObservationIgnored private var heldWrites: [String: [@Sendable (any ActivityHistoryStore) async throws -> Void]] = [:]
    @ObservationIgnored private var attaching: Set<String> = []
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
                     graceInterval: TimeInterval = 2,
                     stallInterval: TimeInterval = 600) {
        self.scheduler = scheduler
        self.progressInterval = progressInterval
        self.graceInterval = graceInterval
        self.stallInterval = stallInterval
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
    ///   - appLevel: keep it in the app-level history, not the open library's (a restore that
    ///     replaces the library file, library adoption).
    ///   - recordsStart: write the running row at the start (so a quit mid-job is closed honestly
    ///     next launch). `false` for a job whose snapshot must not contain itself (a backup).
    ///   - id: a caller-chosen id (to claim resources under it before registering).
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
        persists: Bool = true,
        appLevel: Bool = false,
        recordsStart: Bool = true,
        id: UUID = UUID()
    ) -> ActivityOperationHandle {
        let startedAt = scheduler.now()
        perform { center in
            if !recordsStart { center.noStartRecord.insert(id) }
            center.register(
                id: id, kind: kind, title: title, subject: subject, progress: progress,
                itemNoun: itemNoun, messageName: messageName ?? kind.messageName, controls: controls,
                lane: lane, automatic: automatic, graceful: graceful, quiet: quiet,
                persists: persists, appLevel: appLevel, startedAt: startedAt
            )
        }
        return ActivityOperationHandle(id: id, center: self)
    }

    private func register(
        id: UUID, kind: ActivityKind, title: String, subject: ActivitySubject,
        progress: ActivityProgress, itemNoun: ActivityNoun, messageName: String,
        controls: ActivityControls, lane: ActivityLane?, automatic: Bool, graceful: Bool,
        quiet isQuiet: Bool, persists: Bool, appLevel: Bool, startedAt: Date
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
            isAutomatic: automatic, libraryID: appLevel ? nil : currentLibraryID, needsAttention: false,
            dismissedAt: nil, itemNoun: itemNoun, messageName: messageName, controls: controls,
            isFromHistory: false
        )
        if !automatic && !isQuiet { announce.insert(id) }
        if isQuiet { quiet.insert(id) }
        if persists { persistent.insert(id) }
        lastProgressAt[id] = startedAt
        lastChangeAt[id] = startedAt

        if graceful {
            hidden[id] = operation
            scheduler.schedule(after: graceInterval) { [weak self] in self?.reveal(id) }
        } else {
            operations.append(operation)
            if !noStartRecord.contains(id) { persist(operation) }
            if announce.contains(id), state == .running { postStart(operation) }
        }
        // Calls that raced ahead of this registration (another thread).
        for work in early.removeValue(forKey: id) ?? [] { work(self) }
        if state == .running, let waiter = turnWaiters.removeValue(forKey: id) { waiter.resume(returning: true) }
    }

    private func reveal(_ id: UUID) {
        guard let operation = hidden.removeValue(forKey: id) else { return }
        operations.append(operation)
        if !noStartRecord.contains(id) { persist(operation) }
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
        if progress != current.progress { lastChangeAt[id] = now }
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
        lastChangeAt[id] = scheduler.now()
        update(id) { operation in
            guard operation.state.isActive else { return }
            operation.state = state
            operation.wait = wait
        }
    }

    fileprivate func applyControls(_ id: UUID, _ controls: ActivityControls) {
        // A finished operation keeps only `Run Again` — never a Cancel that can't cancel.
        update(id) { operation in
            operation.controls = operation.state.isActive ? controls
                : ActivityControls(retry: controls.retry, runAgain: controls.runAgain)
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
        // A finished operation keeps only what still works: Retry (its failed tracks) and Run Again.
        ended.controls = ActivityControls(retry: current.controls.retry, runAgain: current.controls.runAgain)
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
        lastChangeAt[id] = nil
        noStartRecord.remove(id)
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
        // A cancel can overtake the registration of its operation (another thread): keep it.
        guard isKnown(id) || history.contains(where: { $0.id == id }) else {
            early[id, default: []].append { $0.cancel(id) }
            return
        }
        guard let current = operation(id: id) ?? hidden[id], current.state.isActive else { return }
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

    /// Retry the failed tracks of an operation: its own retry control (the batch's own source
    /// policy), else — restored from history — the app's handler with the source pin stored with
    /// the failure group (`nil` = `auto`).
    func retryFailed(_ id: UUID, trackIDs: [Int64]? = nil) {
        guard let op = operation(id: id) else { return }
        let ids = trackIDs ?? Array(stillFailing(op))
        guard !ids.isEmpty else { return }
        if let retry = op.controls.retry {
            retry(ids)
        } else {
            let pins = Dictionary(grouping: ids) { id in
                op.result?.failureGroups.first { $0.trackIDs.contains(id) }?.sourcePin
            }
            for (pin, group) in pins { retryHandler?(group, pin) }
        }
    }

    /// Retries failures that have no operation row (`Earlier downloads`): the full chain.
    func retryEarlier(_ trackIDs: [Int64]) {
        guard !trackIDs.isEmpty else { return }
        retryHandler?(trackIDs, nil)
    }

    /// Whether a retry of this operation's failed downloads can run now.
    func canRetry(_ op: ActivityOperation) -> Bool {
        op.controls.retry != nil || retryHandler != nil
    }

    /// Fallback retry for failed downloads without a live closure (from history, `Earlier
    /// downloads`): set by the app to `DownloadViewModel.retryAllFailed(trackIds:sourcePin:)`.
    @ObservationIgnored var retryHandler: (@Sendable ([Int64], String?) -> Void)?

    /// A short status-bar note without a button (`Already queued`).
    nonisolated func postNote(_ text: String) {
        perform { center in
            center.messageSink?(ActivityStatusMessage(text: text, operationID: UUID(), actionTitle: nil))
        }
    }

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

    /// `Dismiss` for failures that have no operation row (`Earlier downloads`): recorded as one
    /// dismissed operation, so they leave the toolbar text like any other dismissed group.
    func dismissEarlier(_ trackIDs: [Int64]) {
        guard !trackIDs.isEmpty else { return }
        let now = scheduler.now()
        let op = ActivityOperation(
            id: UUID(), kind: .download, title: "Earlier downloads", subject: .tracks(trackIDs), state: .completed,
            wait: nil, progress: .indeterminate,
            result: ActivityResult(counts: [ActivityCount(.failed, trackIDs.count, "failed")],
                                   failureGroups: [ActivityFailureGroup(cause: "Download failed earlier", count: trackIDs.count,
                                                                        fix: .retry, trackIDs: trackIDs)]),
            startedAt: now, endedAt: now, isAutomatic: true, libraryID: currentLibraryID, needsAttention: true,
            dismissedAt: now, itemNoun: .track, messageName: "Download", controls: .none, isFromHistory: false)
        operations.append(op)
        let record = ActivityOperationRecord(op)
        enqueueWrite(for: op.libraryID) { store in try await store.save(record) }
    }

    /// `Remove from History` (CM-OPS-ROW).
    func removeFromHistory(_ id: UUID) {
        guard let op = operation(id: id), op.state.isTerminal else { return }
        operations.removeAll { $0.id == id }
        history.removeAll { $0.id == id }
        enqueueWrite(for: op.libraryID) { store in try await store.delete(id: id) }
    }

    // MARK: - Persistence

    /// Attaches the open library's history: closes what a quit interrupted, flags missing
    /// subjects, prunes, loads, and refreshes which failures still fail.
    ///
    /// Interrupted rows are closed **once per launch, before** this session's rows reach the
    /// store: writes that arrive meanwhile are held and written after (S8).
    /// Marks `libraryID` as the open library at once — operations started from now on belong
    /// to it, their writes are held until `attachLibrary` has closed interrupted rows — so the
    /// attach itself can run in the background (N12).
    func beginAttaching(libraryID: String) {
        currentLibraryID = libraryID
        attaching.insert(libraryID)
    }

    func attachLibrary(id libraryID: String, store: any ActivityHistoryStore,
                       failureSource: (any ActivityFailureSource)?) async {
        currentLibraryID = libraryID
        self.failureSource = failureSource
        attaching.insert(libraryID)
        try? await store.closeInterrupted(at: scheduler.now())
        libraryStore = store
        releaseHeldWrites(key: libraryID, store: store)
        await loadHistory(from: store, libraryID: libraryID)
        await refreshFailing()
    }

    /// Attaches the app-level store (operations without a library).
    func attachAppLevel(store: any ActivityHistoryStore) async {
        attaching.insert(Self.appKey)
        try? await store.closeInterrupted(at: scheduler.now())
        appStore = store
        releaseHeldWrites(key: Self.appKey, store: store)
        await loadHistory(from: store, libraryID: nil)
    }

    private static let appKey = "\u{0}app"

    private func releaseHeldWrites(key: String, store: any ActivityHistoryStore) {
        attaching.remove(key)
        for write in heldWrites.removeValue(forKey: key) ?? [] {
            writer.enqueue {
                do { try await write(store) } catch {
                    AppLogger.shared.error("Couldn’t save an Activity result: \(error.localizedDescription)", source: "Activity")
                }
            }
        }
    }

    private func loadHistory(from store: any ActivityHistoryStore, libraryID: String?) async {
        let now = scheduler.now()
        let sessionIDs = Set(operations.map(\.id))
        do {
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

    /// Keeps the open library's history current: deleted playlists / sync profiles turn their
    /// links into plain text; downloads, retries and Locate File… update which failures still
    /// fail. Called once by the app after `attachLibrary`.
    func observeLibraryChanges(center notifications: NotificationCenter = .default) {
        guard libraryObservers.isEmpty else { return }
        for name in [Notification.Name.playlistDidChange, .syncProfileDidChange] {
            libraryObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; Task { await self.refreshSubjects() } }
            })
        }
        for name in [Notification.Name.downloadDidComplete, .trackAvailabilityDidChange] {
            libraryObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleFailingRefresh()
            })
        }
    }

    @ObservationIgnored private var libraryObservers: [NSObjectProtocol] = []

    /// Re-check subjects after something was deleted (playlist, sync profile).
    func refreshSubjects() async {
        guard let libraryStore else { return }
        let changed = (try? await libraryStore.markMissingSubjects()) ?? 0
        guard changed > 0, let currentLibraryID else { return }
        await loadHistory(from: libraryStore, libraryID: currentLibraryID)
        // This session's operations too: their rows were written when they started.
        let missing = Set(((try? await libraryStore.load(now: scheduler.now())) ?? [])
            .filter(\.subject.isMissing).map(\.id))
        for index in operations.indices where missing.contains(operations[index].id) {
            operations[index].subject.isMissing = true
        }
    }

    private func persist(_ operation: ActivityOperation) {
        guard persistent.contains(operation.id) else { return }
        let record = ActivityOperationRecord(operation)
        enqueueWrite(for: operation.libraryID) { store in try await store.save(record) }
    }

    private func enqueueWrite(for libraryID: String?,
                              _ write: @escaping @Sendable (any ActivityHistoryStore) async throws -> Void) {
        let key = libraryID ?? Self.appKey
        if attaching.contains(key) {
            heldWrites[key, default: []].append(write)
            return
        }
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

    /// At quit (`applicationWillTerminate`): waits — at most `timeout` — for the queued history
    /// writes, so end states and failure ids are not lost (S8).
    nonisolated func flushBeforeQuit(timeout: TimeInterval = 2) {
        let semaphore = DispatchSemaphore(value: 0)
        let writer = self.writer
        Task.detached { await writer.drain(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Per-item outcomes of an operation, from memory or — for history — from its store
    /// (items are not kept in memory for history rows, N12).
    func items(for op: ActivityOperation) async -> [ActivityItemOutcome] {
        if let items = op.result?.items, !items.isEmpty { return items }
        guard op.isFromHistory else { return [] }
        let store = op.libraryID == nil ? appStore : (op.libraryID == currentLibraryID ? libraryStore : nil)
        return (try? await store?.items(for: op.id)) ?? []
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

    /// Schedules `refreshFailing` from any thread (after a download batch, an edit).
    nonisolated func scheduleFailingRefresh(ids: [UUID]? = nil) {
        perform { center in Task { await center.refreshFailing() } }
    }

    /// Reads which tracks fail now (the `Download failed` scope's predicate) and lets every
    /// operation whose failures were all fixed leave Needs attention for good.
    func refreshFailing(ids: [UUID]? = nil) async {
        guard let failureSource else { return }
        guard let failing = try? await failureSource.allFailingTrackIDs() else { return }
        failingNow = failing
        let owners = failureOwners()
        for op in allOperations where op.needsAttention && op.state != .failed && !(op.result?.failedTrackIDs.isEmpty ?? true) {
            let still = op.result!.failedTrackIDs.contains { failing.contains($0) && owners[$0] == op.id }
            if !still { markFixed(op.id) }
        }
    }

    private func markFixed(_ id: UUID) {
        if let index = operations.firstIndex(where: { $0.id == id }) { operations[index].needsAttention = false }
        if let index = history.firstIndex(where: { $0.id == id }) { history[index].needsAttention = false }
        let libraryID = operation(id: id)?.libraryID
        enqueueWrite(for: libraryID) { store in try await store.clearAttention(id: id) }
    }

    /// Track id → the newest operation (by end) that recorded it as failed — each failing track
    /// belongs to exactly one operation, so it is counted and retried once (S4).
    func failureOwners() -> [Int64: UUID] {
        var owners: [Int64: UUID] = [:]
        let ordered = (operations + history).filter { $0.state.isTerminal }
            .sorted { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
        for op in ordered {
            for id in op.result?.failedTrackIDs ?? [] { owners[id] = op.id }
        }
        return owners
    }

    /// Failed tracks this operation owns that still fail (before the first check: the recorded
    /// ones it owns).
    func stillFailing(_ operation: ActivityOperation, owners: [Int64: UUID]? = nil) -> Set<Int64> {
        let owners = owners ?? failureOwners()
        let recorded = (operation.result?.failedTrackIDs ?? []).filter { owners[$0] == operation.id }
        guard let failingNow else { return Set(recorded) }
        return Set(recorded.filter(failingNow.contains))
    }

    /// Failing tracks no operation recorded (failures from before Activity kept history, or
    /// pruned): shown as `Earlier downloads` so the toolbar count equals the scope count.
    func earlierFailingTrackIDs(owners: [Int64: UUID]? = nil) -> [Int64] {
        guard let failingNow else { return [] }
        let owners = owners ?? failureOwners()
        return failingNow.filter { owners[$0] == nil }.sorted()
    }

    /// `No progress for ‹n› min` — a running operation without progress or state change for
    /// `stallInterval` (never queued, paused or drive waits); `nil` otherwise.
    func stalledMinutes(_ op: ActivityOperation) -> Int? {
        guard op.state == .running, let last = lastChangeAt[op.id] else { return nil }
        let quiet = scheduler.now().timeIntervalSince(last)
        guard quiet >= stallInterval else { return nil }
        return Int(quiet / 60)
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
            case .tracks: return Set(op.subject.trackIDs) == Set(subject.trackIDs)
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
        let recorded = last.result?.failedTrackIDs ?? []
        let failed = last.needsAttention && last.dismissedAt == nil
            ? (failingNow.map { now in recorded.filter(now.contains).count } ?? recorded.count) : 0
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
