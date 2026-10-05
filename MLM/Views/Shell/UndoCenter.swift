import Foundation
import GRDB
import Observation
import SwiftUI

// MARK: - Undo contract (DEC-041, DEC-016, DEC-049, UC-UNDO-01…09, UC-STATUS-04/05, P8)
//
// How to make an action undoable
// ------------------------------
// Read the center (`@Environment(UndoCenter.self)` in views, `@FocusedValue(\.undoCenter)` in
// `.commands`) and hand it the action and its inverse. The center registers the step on the
// window's `UndoManager` at once (named for Edit ▸ Undo), runs the action, and confirms in the
// status bar with `Undo` for 8 s:
//
//     // Simple: the action is its own redo.
//     try await undo.perform(
//         "Rename Playlist",                              // Edit ▸ Undo Rename Playlist
//         message: "Renamed “\(old)” to “\(new)”",        // status bar, with Undo, for 8 s
//         failure: nil,                                   // nil: the rename field shows it
//         do: { try await repo.rename(id: id, name: new) },
//         undo: { try await repo.rename(id: id, name: old) }
//     )
//
//     // With values: do → Done (what undo needs), undo → Undone (what redo needs), redo → Done.
//     try await undo.perform(
//         "Add to “\(name)”", failure: "Couldn’t add the tracks to “\(name)”",
//         do: { try await repo.appendTracksReturningEntries(playlistId: id, trackIds: ids) },
//         undo: { added in try await repo.removeEntries(added.entries) },
//         redo: { removed in PlaylistAppendResult(entries: try await repo.restoreEntries(removed), alreadyPresent: 0) },
//         message: { "Added \($0.entries.count) tracks to “\(name)”" })
//
// Semantics
// - One user gesture = one step (UC-UNDO-08); several undoable parts go through `performGroup`.
// - The step is registered when `perform` is called, before `do` runs. ⌘Z (or the status-bar
//   Undo) while `do` is still running undoes *this* action, queued behind its `do`. If `do`
//   throws or returns nil (nothing changed) the step is taken off the stacks again.
// - `do`, `undo` and `redo` of all steps run on one serial main-actor queue in the order the
//   user asked for them. Work the user triggered is never skipped because a newer step emptied
//   Redo; it is skipped only when its step failed, or the steps were dropped (library change).
// - `undo` restores the exact earlier state and `redo` the exact later one — reuse row ids and
//   positions (`PlaylistRepository.restore(_:)`, `restoreEntries(_:)`). Make each closure one
//   transaction where you can.
// - Failure: a throwing `do` registers nothing and posts `‹failure› — ‹cause› · Try Again`. A
//   throwing `undo` / `redo` drops that step *and every older step of the center* (their
//   inverses assumed a state that no longer holds), cancels their queued work and posts
//   `Couldn’t undo ‹action› — ‹cause›. Earlier changes can no longer be undone.` Throw
//   `UndoNothingLeft(note:)` when the things to undo are simply gone: only that step goes, with
//   the note. Word causes with `PlainCauseError`; raw errors go to the log only.
// - Re-entrancy: never call the center from inside one of its closures (it would wait for
//   itself). Debug builds stop at an assertion; release builds log and fail the inner call.
// - Confirmation: posted once per step, after `do`; undo and redo post nothing unless they
//   fail. Its `Undo` disappears as soon as the step is no longer the one ⌘Z would undo
//   (typing, another action, ⌘Z itself). Don't ask before an undoable action (UC-UNDO-04).
// - Lifetime: one center per open library (`UndoCenter.main`), so steps outlive the main window
//   and come back on the reopened window's undo manager — Delete Playlist stays restorable
//   until MLM quits (DEC-049). Steps are dropped when another library opens. At most
//   `levelsOfUndo` (100) steps are kept.
// - Already did the work synchronously (in-memory queue edits)? `record(…)` registers and
//   confirms without running anything.

/// The undo of the open library's main window: wraps the window's `UndoManager`
/// (UC-UNDO-01). In the environment (`@Environment(UndoCenter.self)`) and as
/// `@FocusedValue(\.undoCenter)`. See the contract above.
///
/// Edit ▸ Undo / Redo stay the system items: AppKit validates them through the responder
/// chain against the same `UndoManager` and titles them `Undo ‹action name›`
/// (`undoMenuItemTitle`), so a focused text field keeps its own typing undo.
@MainActor
@Observable
final class UndoCenter {
    /// The app's center: one library is open per process, and it outlives the main window.
    static let main = UndoCenter(statusBar: StatusBarCenter())

    /// Undo groups the window's manager keeps (ours and others'); the center keeps at most as
    /// many of its own steps.
    static let levelsOfUndo = 100

    @ObservationIgnored private(set) var undoManager: UndoManager?
    @ObservationIgnored private(set) var statusBar: StatusBarCenter
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private let reentrancyFailure: @MainActor (String) -> Void

    /// Own steps Undo or Redo can reach, oldest first. The manager keeps only an unowned
    /// reference to a target, so these stay alive until removed from the manager.
    @ObservationIgnored private var liveSteps: [UndoStep] = []
    /// The step on top of the undo stack, as far as the center knows (nil: unknown).
    @ObservationIgnored private weak var topStep: UndoStep?
    /// The step whose confirmation was posted last.
    @ObservationIgnored private weak var confirmedStep: UndoStep?
    @ObservationIgnored private var nextSequence = 0
    /// Bumped when every step is dropped; queued work of an older generation is skipped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var scope: String?

    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var isDraining = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored private var isRegistering = false
    @ObservationIgnored private var isReplaying = false
    @ObservationIgnored private var expectsOuterClose = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(
        undoManager: UndoManager? = nil,
        statusBar: StatusBarCenter,
        log: @escaping @MainActor (String) -> Void = { AppLogger.shared.error($0, source: "Undo") },
        reentrancyFailure: @escaping @MainActor (String) -> Void = { assertionFailure($0) }
    ) {
        self.statusBar = statusBar
        self.log = log
        self.reentrancyFailure = reentrancyFailure
        attach(undoManager)
    }

    // MARK: Lifetime

    /// Use the main window's undo manager (and its status bar). The center's steps move from
    /// the previous manager to this one — both stacks, in order — so Edit ▸ Undo works again
    /// after the window is reopened. `nil` (window closed) keeps the steps for the next window.
    func attach(_ manager: UndoManager?, statusBar: StatusBarCenter? = nil) {
        if let statusBar { self.statusBar = statusBar }
        guard manager !== undoManager else { return }
        if let old = undoManager {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            for step in liveSteps { old.removeAllActions(withTarget: step) }
        }
        undoManager = manager
        topStep = nil
        guard let manager else { return }
        manager.levelsOfUndo = Self.levelsOfUndo
        observe(manager)
        replay(on: manager)
    }

    /// The open library. Another library drops every step (UC-UNDO-01: steps belong to it).
    func use(scope newScope: String?) {
        guard let newScope else { return }
        if let scope, scope != newScope { removeAllSteps() }
        scope = newScope
    }

    /// Drop every step of this center and skip its queued work. Undo actions of others — a
    /// text field's typing — stay.
    func removeAllSteps() {
        generation += 1
        for step in liveSteps { cancel(step) }
        liveSteps.removeAll()
        topStep = nil
        refreshConfirmation()
    }

    /// Number of own steps Undo or Redo can still reach.
    var stepCount: Int { liveSteps.count }

    /// Suspends until every queued do / undo / redo has finished.
    func waitUntilIdle() async {
        guard isDraining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Perform

    /// Run an action whose redo is the action itself, register its undo, confirm it.
    ///
    /// - Parameters:
    ///   - actionName: Title Case verb phrase with the real object (UC-UNDO-07):
    ///     `Rename Playlist`, `Add to “Warm-up”`. Edit ▸ Undo shows `Undo ‹actionName›`.
    ///   - message: the status-bar sentence fragment (UC-STATUS-05), shown with `Undo`.
    ///   - failure: `Couldn’t …` sentence start for the status bar if `do` throws (offered with
    ///     `Try Again`); nil when the caller shows the failure where it happened (UC-SHEET-17).
    /// - Throws: the error of `do`; `UndoCenterError` when the call was refused or dropped.
    func perform(
        _ actionName: String,
        message: String,
        failure: String?,
        do work: @escaping @MainActor () async throws -> Void,
        undo inverse: @escaping @MainActor () async throws -> Void
    ) async throws {
        _ = try await perform(
            actionName,
            failure: failure,
            do: { try await work(); return () },
            undo: { _ in try await inverse() },
            redo: { _ in try await work() },
            message: { _ in message }
        )
    }

    /// Run an action, register undo and redo with the values each needs, confirm it.
    ///
    /// `do` returns what `undo` needs (`Done`), `undo` returns what `redo` needs (`Undone`),
    /// `redo` returns a new `Done` for the next undo. Return nil from `do` when nothing
    /// changed: the step is taken off the stacks and nothing is posted.
    ///
    /// - Returns: the value of `do`, or nil when nothing changed.
    @discardableResult
    func perform<Done: Sendable, Undone: Sendable>(
        _ actionName: String,
        failure: String?,
        do work: @escaping @MainActor () async throws -> Done?,
        undo inverse: @escaping @MainActor (Done) async throws -> Undone,
        redo again: @escaping @MainActor (Undone) async throws -> Done,
        message: @escaping @MainActor (Done) -> String
    ) async throws -> Done? {
        guard admitsCall("perform") else { throw UndoCenterError.reentrant }
        let typed = TypedWork(do: work, undo: inverse, redo: again)
        let step = makeStep(actionName, work: typed)
        register(step)
        let retry: @MainActor () -> Void = { [weak self] in
            Task { _ = try? await self?.perform(actionName, failure: failure, do: work, undo: inverse, redo: again, message: message) }
        }
        return try await runQueued(.perform, step: step) { [self] in
            let done: Done?
            do {
                done = try await Self.inside { try await typed.runDo() }
            } catch {
                discard(step)
                report(error, as: failure, retry: retry)
                throw error
            }
            guard let done else {
                discard(step)
                return nil
            }
            confirm(step, message(done))
            return done
        }
    }

    /// One user gesture made of several undoable parts (UC-UNDO-08): `body` runs the parts
    /// through the `UndoGroup`; they are one step that undoes them newest first and redoes them
    /// in order. If `body` throws, the parts already done are undone again (newest first) and
    /// the step goes. No parts: no step, no message.
    @discardableResult
    func performGroup<Result: Sendable>(
        _ actionName: String,
        failure: String?,
        _ body: @escaping @MainActor (UndoGroup) async throws -> Result,
        message: @escaping @MainActor (Result) -> String
    ) async throws -> Result {
        guard admitsCall("performGroup") else { throw UndoCenterError.reentrant }
        let group = UndoGroup(log: log)
        let step = makeStep(actionName, work: group.work)
        register(step)
        let retry: @MainActor () -> Void = { [weak self] in
            Task { _ = try? await self?.performGroup(actionName, failure: failure, body, message: message) }
        }
        return try await runQueued(.perform, step: step) { [self] in
            let result: Result
            do {
                result = try await Self.inside { try await body(group) }
            } catch {
                let stuck = await group.work.rollBack()
                discard(step)
                report(error, as: failure, retry: retry, stuckParts: stuck)
                throw error
            }
            if group.work.parts.isEmpty {
                discard(step)
            } else {
                group.work.markDone()
                confirm(step, message(result))
            }
            return result
        }
    }

    /// Register an action that already happened (synchronous in-memory edits) and confirm it.
    /// Runs nothing now; `undo` / `redo` run later on the serial queue.
    func record<Done: Sendable, Undone: Sendable>(
        _ actionName: String,
        message: String,
        done: Done,
        undo inverse: @escaping @MainActor (Done) async throws -> Undone,
        redo again: @escaping @MainActor (Undone) async throws -> Done
    ) {
        guard admitsCall("record") else { return }
        let step = makeStep(actionName, work: TypedWork(done: done, undo: inverse, redo: again))
        register(step)
        confirm(step, message)
    }

    // MARK: Status bar

    /// The status bar's `Undo` (UC-UNDO-09): the same single undo as ⌘Z, and only while this
    /// step is the one ⌘Z would undo.
    func undoFromStatusBar(_ step: UndoStep) {
        guard isTop(step), let manager = undoManager, !manager.isUndoing, !manager.isRedoing else { return }
        manager.undo()
    }

    private func isTop(_ step: UndoStep) -> Bool {
        guard step.phase == .done, !step.cancelled, topStep === step, let manager = undoManager else { return false }
        return manager.canUndo && manager.undoActionName == step.actionName
    }

    private func confirm(_ step: UndoStep, _ text: String) {
        // Already cancelled, or already undone by a quick ⌘Z: nothing to confirm.
        guard !step.cancelled, step.phase == .done else { return }
        let actions: [StatusAction] = isTop(step)
            ? [.undo { [weak self, weak step] in
                guard let self, let step else { return }
                self.undoFromStatusBar(step)
            }]
            : []
        step.messageID = statusBar.post(text, actions: actions)
        confirmedStep = step
    }

    /// Take `Undo` off the showing confirmation once its step is no longer on top (S3).
    private func refreshConfirmation() {
        guard let step = confirmedStep, let id = step.messageID, let message = statusBar.message,
              message.id == id, !message.actions.isEmpty, !isTop(step) else { return }
        statusBar.replaceActions(of: id, with: [])
    }

    // MARK: Registration

    private func makeStep(_ actionName: String, work: any UndoableWork) -> UndoStep {
        nextSequence += 1
        return UndoStep(sequence: nextSequence, actionName: actionName, work: work)
    }

    private func register(_ step: UndoStep) {
        liveSteps.append(step)
        guard let manager = undoManager else { return }
        registerUndoAction(step, on: manager)
        // A new step empties Redo: those steps can't be reached any more. Their queued work
        // (an undo the user already asked for) still runs.
        liveSteps.removeAll { $0.phase == .undone }
        topStep = step
        trimToLevels(manager)
        refreshConfirmation()
    }

    /// One undo group per step. With `groupsByEvent` an explicit group at level 0 would sit in
    /// an automatic event group that stays open until the run loop turns, so two steps
    /// registered in one turn would merge; the center opens its own top-level group instead.
    private func registerUndoAction(_ step: UndoStep, on manager: UndoManager) {
        let level = manager.groupingLevel
        let groupsByEvent = manager.groupsByEvent
        if level == 0 {
            manager.groupsByEvent = false
        } else {
            expectsOuterClose = true // nested in someone's open group: that close is ours too
        }
        isRegistering = true
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: step) { [weak self] step in self?.undoInvoked(step) }
        manager.setActionName(step.actionName)
        manager.endUndoGrouping()
        isRegistering = false
        if level == 0 { manager.groupsByEvent = groupsByEvent }
    }

    private func trimToLevels(_ manager: UndoManager) {
        let done = liveSteps.filter { $0.phase == .done }
        guard done.count > Self.levelsOfUndo else { return }
        for step in done.prefix(done.count - Self.levelsOfUndo) {
            manager.removeAllActions(withTarget: step)
            liveSteps.removeAll { $0 === step }
        }
    }

    /// Put the steps on a (new) manager: done steps as undo actions, oldest first; undone steps
    /// registered after them and undone again, so Redo holds them in the right order.
    private func replay(on manager: UndoManager) {
        let done = liveSteps.filter { $0.phase == .done }
        let undone = liveSteps.filter { $0.phase == .undone }
        guard !done.isEmpty || !undone.isEmpty else { return }
        isReplaying = true
        for step in done + undone { registerUndoAction(step, on: manager) }
        for _ in undone { manager.undo() }
        isReplaying = false
        topStep = done.last
    }

    /// Called by the manager inside `undo()`: registers the redo at once (it must be registered
    /// while the manager is undoing), then queues the inverse.
    private func undoInvoked(_ step: UndoStep) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: step) { [weak self] step in self?.redoInvoked(step) }
        manager.setActionName(step.actionName)
        guard !isReplaying, !step.cancelled else { return }
        step.phase = .undone
        if topStep === step { topStep = nil }
        if let id = step.messageID {
            // Its Undo was just used (here or by ⌘Z): the confirmation goes, nothing new comes.
            statusBar.dismiss(id)
            step.messageID = nil
        }
        enqueue(Job(kind: .undo, step: step, generation: generation, run: { [weak self] in
            await self?.runInverse(of: step, undoing: true)
        }, skip: {}))
    }

    private func redoInvoked(_ step: UndoStep) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: step) { [weak self] step in self?.undoInvoked(step) }
        manager.setActionName(step.actionName)
        guard !isReplaying, !step.cancelled else { return }
        step.phase = .done
        topStep = step
        enqueue(Job(kind: .redo, step: step, generation: generation, run: { [weak self] in
            await self?.runInverse(of: step, undoing: false)
        }, skip: {}))
    }

    private func runInverse(of step: UndoStep, undoing: Bool) async {
        do {
            try await Self.inside {
                if undoing { try await step.work.undo() } else { try await step.work.redo() }
            }
        } catch let nothing as UndoNothingLeft {
            cancel(step)
            statusBar.post(nothing.note)
        } catch {
            fail(step, error, verb: undoing ? "undo" : "redo")
        }
    }

    /// An undo or redo failed: that step and every older own step go (their inverses assumed a
    /// state that no longer holds), with their queued work.
    private func fail(_ step: UndoStep, _ error: Error, verb: String) {
        let older = liveSteps.filter { $0.sequence < step.sequence }
        cancel(step)
        older.forEach(cancel)
        log("Couldn’t \(verb) \(step.actionName): \(error)")
        var text = UndoFailure.sentence("Couldn’t \(verb) \(step.actionName)", error)
        if !older.isEmpty { text += ". Earlier changes can no longer be undone." }
        statusBar.post(text)
    }

    /// `do` failed or changed nothing: take the step off the stacks.
    private func discard(_ step: UndoStep) {
        cancel(step)
        refreshConfirmation()
    }

    private func cancel(_ step: UndoStep) {
        step.cancelled = true
        undoManager?.removeAllActions(withTarget: step)
        liveSteps.removeAll { $0 === step }
        if topStep === step { topStep = nil }
    }

    private func report(_ error: Error, as failure: String?, retry: @escaping @MainActor () -> Void, stuckParts: Int = 0) {
        log("\(failure ?? "Undoable action failed"): \(error)")
        guard let failure else { return }
        var text = UndoFailure.sentence(failure, error)
        if stuckParts > 0 {
            text += ". \(stuckParts.formatted(.number)) \(stuckParts == 1 ? "change" : "changes") couldn’t be taken back."
        }
        statusBar.post(text, actions: [StatusAction("Try Again", perform: retry)])
    }

    // MARK: Watching the manager

    private func observe(_ manager: UndoManager) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.groupDidClose() }
            },
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshConfirmation() }
            },
            center.addObserver(forName: .NSUndoManagerDidRedoChange, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshConfirmation() }
            },
        ]
    }

    /// Someone else's undo group closed (typing, another undo client): it may be on top now, and
    /// it emptied Redo.
    private func groupDidClose() {
        guard !isRegistering, !isReplaying, let manager = undoManager, !manager.isUndoing, !manager.isRedoing else { return }
        if expectsOuterClose {
            expectsOuterClose = false
            return
        }
        if let top = topStep, !(manager.canUndo && manager.undoActionName == top.actionName) {
            topStep = nil
        }
        if !manager.canRedo {
            liveSteps.removeAll { $0.phase == .undone }
        }
        refreshConfirmation()
    }

    // MARK: Re-entrancy

    private func admitsCall(_ api: String) -> Bool {
        guard UndoClosureContext.isInside else { return true }
        let text = "UndoCenter.\(api) was called from inside an undo closure; it would wait for itself"
        log(text)
        reentrancyFailure(text)
        return false
    }

    private static func inside<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        try await UndoClosureContext.$isInside.withValue(true) { try await body() }
    }

    // MARK: Serial queue

    private struct Job {
        enum Kind { case perform, undo, redo }
        let kind: Kind
        let step: UndoStep
        let generation: Int
        let run: @MainActor () async -> Void
        /// Called instead of `run` when the job is skipped.
        let skip: @MainActor () -> Void
    }

    private func enqueue(_ job: Job) {
        jobs.append(job)
        guard !isDraining else { return }
        isDraining = true
        UndoClosureContext.$isInside.withValue(false) {
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            if job.generation != generation {
                log("Skipped queued “\(job.step.actionName)” work: its steps were dropped")
                job.skip()
            } else if job.kind != .perform, job.step.cancelled {
                job.skip()
            } else {
                await job.run()
            }
        }
        isDraining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func runQueued<T: Sendable>(
        _ kind: Job.Kind,
        step: UndoStep,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let generation = self.generation
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(Job(kind: kind, step: step, generation: generation, run: {
                do {
                    continuation.resume(returning: try await body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }, skip: { [weak self] in
                self?.cancel(step)
                continuation.resume(throwing: UndoCenterError.dropped)
            }))
        }
    }
}

/// Whether the current task runs inside one of the center's closures (re-entrancy guard).
enum UndoClosureContext {
    @TaskLocal static var isInside = false
}

// MARK: - Steps

/// One undo step: the registration target on the window's undo manager.
@MainActor
final class UndoStep {
    enum Phase { case done, undone }

    let sequence: Int
    let actionName: String
    fileprivate let work: any UndoableWork
    /// Where the step sits: on the undo stack (`done`, also while its `do` runs) or on Redo.
    fileprivate(set) var phase: Phase = .done
    /// Off both stacks for good; its queued work is skipped.
    fileprivate(set) var cancelled = false
    fileprivate var messageID: StatusMessage.ID?

    fileprivate init(sequence: Int, actionName: String, work: any UndoableWork) {
        self.sequence = sequence
        self.actionName = actionName
        self.work = work
    }
}

/// Something that can be undone and redone, holding the values each direction needs.
@MainActor
protocol UndoableWork: AnyObject {
    func undo() async throws
    func redo() async throws
}

/// A step's work with typed values: `Done` (what undo needs) ⇄ `Undone` (what redo needs).
@MainActor
final class TypedWork<Done: Sendable, Undone: Sendable>: UndoableWork {
    private enum State {
        case pending
        case done(Done)
        case undone(Undone)
    }

    private var state: State
    private let initial: (@MainActor () async throws -> Done?)?
    private let inverse: @MainActor (Done) async throws -> Undone
    private let again: @MainActor (Undone) async throws -> Done

    /// Work that still has to run (`runDo`).
    init(
        do initial: @escaping @MainActor () async throws -> Done?,
        undo: @escaping @MainActor (Done) async throws -> Undone,
        redo: @escaping @MainActor (Undone) async throws -> Done
    ) {
        state = .pending
        self.initial = initial
        inverse = undo
        again = redo
    }

    /// Work that already happened.
    init(
        done: Done,
        undo: @escaping @MainActor (Done) async throws -> Undone,
        redo: @escaping @MainActor (Undone) async throws -> Done
    ) {
        state = .done(done)
        initial = nil
        inverse = undo
        again = redo
    }

    func runDo() async throws -> Done? {
        guard case .pending = state, let initial else { throw UndoCenterError.outOfOrder }
        guard let done = try await initial() else { return nil }
        state = .done(done)
        return done
    }

    func undo() async throws {
        guard case .done(let value) = state else { throw UndoCenterError.outOfOrder }
        state = .undone(try await inverse(value))
    }

    func redo() async throws {
        guard case .undone(let value) = state else { throw UndoCenterError.outOfOrder }
        state = .done(try await again(value))
    }
}

/// The parts of one gesture (`UndoCenter.performGroup`).
@MainActor
final class UndoGroup {
    fileprivate let work: GroupWork

    fileprivate init(log: @escaping @MainActor (String) -> Void) {
        work = GroupWork(log: log)
    }

    /// Run a part whose redo is the part itself.
    func perform(
        do work: @escaping @MainActor () async throws -> Void,
        undo inverse: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await perform(do: { try await work(); return () }, undo: { _ in try await inverse() }, redo: { _ in try await work() })
    }

    /// Run a part with typed values (see `UndoCenter.perform(_:failure:do:undo:redo:message:)`).
    @discardableResult
    func perform<Done: Sendable, Undone: Sendable>(
        do work: @escaping @MainActor () async throws -> Done,
        undo inverse: @escaping @MainActor (Done) async throws -> Undone,
        redo again: @escaping @MainActor (Undone) async throws -> Done
    ) async throws -> Done {
        let done = try await work()
        self.work.parts.append(TypedWork(done: done, undo: inverse, redo: again))
        return done
    }

    /// Number of parts done so far.
    var count: Int { work.parts.count }
}

/// Parts undone newest first and redone oldest first. A failing part puts the parts it already
/// reversed back, so the group stays all-done or all-undone where it can; what can't be put
/// back is logged.
@MainActor
final class GroupWork: UndoableWork {
    fileprivate(set) var parts: [any UndoableWork] = []
    private var isDone = false
    private let log: @MainActor (String) -> Void

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    fileprivate func markDone() { isDone = true }

    func undo() async throws {
        guard isDone else { throw UndoCenterError.outOfOrder }
        var reversed: [any UndoableWork] = []
        for part in parts.reversed() {
            do {
                try await part.undo()
                reversed.append(part)
            } catch {
                for done in reversed.reversed() {
                    do { try await done.redo() } catch { log("A group part stayed undone after a failed undo: \(error)") }
                }
                throw error
            }
        }
        isDone = false
    }

    func redo() async throws {
        guard !isDone else { throw UndoCenterError.outOfOrder }
        var redone: [any UndoableWork] = []
        for part in parts {
            do {
                try await part.redo()
                redone.append(part)
            } catch {
                for done in redone.reversed() {
                    do { try await done.undo() } catch { log("A group part stayed redone after a failed redo: \(error)") }
                }
                throw error
            }
        }
        isDone = true
    }

    /// `performGroup`'s body failed: undo what it did, newest first.
    /// - Returns: how many parts couldn't be undone (they stay applied).
    fileprivate func rollBack() async -> Int {
        var stuck = 0
        for part in parts.reversed() {
            do {
                try await part.undo()
            } catch {
                stuck += 1
                log("Rolling back a failed group left a part applied: \(error)")
            }
        }
        parts.removeAll()
        return stuck
    }
}

enum UndoCenterError: Error {
    /// Undo of a step that isn't done, or redo of one that isn't undone.
    case outOfOrder
    /// The center was called from inside one of its own closures.
    case reentrant
    /// The steps were dropped (another library) before this work ran.
    case dropped
}

/// Thrown by an undo or redo closure when what it would change is simply gone (rows already
/// removed elsewhere): the step leaves the stacks without a failure, and `note` is posted.
struct UndoNothingLeft: Error {
    /// Status-bar sentence fragment, e.g. `Nothing to undo — the tracks are no longer in “Warm-up”`.
    let note: String
}

// MARK: - Failure wording (UC-COPY-11, UC-SHEET-19)

/// An error that can name its cause in plain words for a status-bar or field sentence.
protocol PlainCauseError: Error {
    /// Lower-case clause without a final period, e.g. `“Warm-up” no longer exists`.
    var plainCause: String { get }
}

/// The thing an undo or redo should change is gone (deleted by something not undoable).
struct UndoTargetMissing: PlainCauseError {
    /// Already quoted name, e.g. `“Warm-up”`.
    let quotedName: String
    var plainCause: String { "\(quotedName) no longer exists" }
}

enum UndoFailure {
    /// The cause of a failed change in plain words. Never the raw error text, and never a
    /// guess: an error MLM can't word says that the details are in the log.
    static func cause(of error: Error) -> String {
        if let plain = error as? PlainCauseError { return plain.plainCause }
        if let database = error as? DatabaseError {
            switch database.resultCode {
            case .SQLITE_BUSY, .SQLITE_LOCKED:
                return "the library database is busy"
            case .SQLITE_FULL:
                return "the disk with the library file is full"
            case .SQLITE_READONLY:
                return "the library file can’t be changed"
            default:
                return "the library file didn’t accept the change"
            }
        }
        return "something went wrong (the details are in the log)"
    }

    /// `‹failure› — ‹cause›` (UC-COPY-08: the dash joins what failed and why).
    static func sentence(_ failure: String, _ error: Error) -> String {
        "\(failure) — \(cause(of: error))"
    }
}

// MARK: - Window wiring

extension FocusedValues {
    /// The open library's undo center (menu commands that make undoable changes).
    @Entry var undoCenter: UndoCenter?
}

extension View {
    /// Attach `center` to this window's `UndoManager` and status bar. Its steps leave the
    /// manager when the view leaves the window and come back on the next window; they are
    /// dropped when `scope` (the open library) changes.
    func undoCenter(_ center: UndoCenter, statusBar: StatusBarCenter, scope: String?) -> some View {
        modifier(UndoCenterBinding(center: center, statusBar: statusBar, scope: scope))
    }
}

private struct UndoCenterBinding: ViewModifier {
    let center: UndoCenter
    let statusBar: StatusBarCenter
    let scope: String?
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onAppear {
                center.use(scope: scope)
                center.attach(undoManager, statusBar: statusBar)
            }
            .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in
                center.attach(undoManager, statusBar: statusBar)
            }
            .onChange(of: scope) { _, newScope in center.use(scope: newScope) }
            .onDisappear { center.attach(nil) }
    }
}
