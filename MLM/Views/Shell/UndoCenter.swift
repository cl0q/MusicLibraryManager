import Foundation
import GRDB
import Observation
import SwiftUI

// MARK: - Undo contract (DEC-041, DEC-016, UC-UNDO-01…09, UC-STATUS-04/05, P8)
//
// How to make an action undoable
// ------------------------------
// Read the window's center (`@Environment(UndoCenter.self)` in views,
// `@FocusedValue(\.undoCenter)` in `.commands`) and hand it the action and its inverse.
// The center runs the action, registers undo *and* redo as one step on the window's
// `UndoManager`, names it for Edit ▸ Undo, and confirms in the status bar with `Undo` for 8 s:
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
// Rules
// - One user gesture = one step (UC-UNDO-08). A gesture made of several undoable parts uses
//   `performGroup`, whose `UndoGroup` runs the parts and undoes them as one step.
// - Closures run on the main actor, one at a time, in the order the user asked for them
//   (do, undo and redo of all steps share one serial queue). Make each closure one
//   transaction where you can; never call the center from inside a closure (it would wait
//   for itself).
// - `undo` must restore the exact earlier state and `redo` the exact later one — reuse row
//   ids and positions (see `PlaylistRepository.restore(_:)`, `restoreEntries(_:)`), never
//   "do it again" when that would make new ids that later steps don't know.
// - Failure: a throwing `do` registers nothing and posts `‹failure› — ‹cause›`; a throwing
//   `undo` / `redo` removes that step from Undo and Redo and posts `Couldn’t undo ‹action›
//   — ‹cause›`. The cause comes from `UndoFailure.cause(of:)` (conform an error to
//   `PlainCauseError` to word it); the raw error goes to the log, never to the UI alone.
// - Don't post a second confirmation for an undoable action, and don't ask before it
//   (UC-UNDO-04). Undo and redo post nothing unless they fail.
// - Already did the work synchronously (in-memory queue edits)? `record(…)` registers and
//   confirms without running anything.
// - Lifetime: steps live until MLM quits (Delete Playlist stays restorable, DEC-049), and
//   are dropped when the main window closes or another library opens (`removeAllSteps()`).

/// The main window's undo: one per main window, wrapping the window's `UndoManager`
/// (UC-UNDO-01). In the environment (`@Environment(UndoCenter.self)`) and as
/// `@FocusedValue(\.undoCenter)`. See the contract above.
///
/// Edit ▸ Undo / Redo stay the system items: AppKit validates them through the responder
/// chain against this same `UndoManager` and titles them `Undo ‹action name›`
/// (`undoMenuItemTitle`), so a focused text field keeps its own typing undo.
@MainActor
@Observable
final class UndoCenter {
    /// The window's undo manager, attached by `.undoCenter(_:scope:)`; nil before the window
    /// exists (actions still run and confirm, without `Undo`).
    @ObservationIgnored private(set) var undoManager: UndoManager?
    @ObservationIgnored private let statusBar: StatusBarCenter
    @ObservationIgnored private let log: @MainActor (String) -> Void

    /// Steps that the undo manager may still call. The manager keeps only an unowned
    /// reference to a target, so the center keeps each step alive until it is removed from
    /// the manager (`removeAllActions(withTarget:)`).
    @ObservationIgnored private var liveSteps: [UndoStep] = []
    /// The step on top of the undo stack, as far as the center knows (nil: unknown).
    @ObservationIgnored private weak var topStep: UndoStep?

    @ObservationIgnored private var jobs: [@MainActor () async -> Void] = []
    @ObservationIgnored private var isDraining = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        undoManager: UndoManager? = nil,
        statusBar: StatusBarCenter,
        log: @escaping @MainActor (String) -> Void = { AppLogger.shared.error($0, source: "Undo") }
    ) {
        self.undoManager = undoManager
        self.statusBar = statusBar
        self.log = log
    }

    // MARK: Lifetime

    /// Use the window's undo manager. Steps registered on a previous manager are removed
    /// from it (the window they belonged to is gone).
    func attach(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        removeAllSteps()
        undoManager = manager
    }

    /// Drop every step this center registered (library switched, window closed). Undo
    /// actions of others — a text field's typing — stay.
    func removeAllSteps() {
        for step in liveSteps {
            step.phase = .dropped
            undoManager?.removeAllActions(withTarget: step)
        }
        liveSteps.removeAll()
        topStep = nil
    }

    /// Number of steps that Undo or Redo can still reach (for tests and diagnostics).
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
    ///   - failure: `Couldn’t …` sentence start for the status bar if `do` throws; nil when
    ///     the caller shows the failure where it happened (a text field, UC-SHEET-17).
    /// - Throws: the error of `do` (after reporting it when `failure` is set).
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
    /// changed: then no step is registered and nothing is posted.
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
        try await serially { [self] in
            let done: Done
            do {
                guard let value = try await work() else { return nil }
                done = value
            } catch {
                report(error, as: failure)
                throw error
            }
            let step = UndoStep(actionName: actionName, work: TypedWork(done: done, undo: inverse, redo: again))
            register(step, message: message(done))
            return done
        }
    }

    /// One user gesture made of several undoable parts (UC-UNDO-08): `body` runs the parts
    /// through the `UndoGroup`; they become one step that undoes them in reverse order and
    /// redoes them in order. If `body` throws, the parts already done are undone again
    /// (newest first) and nothing is registered. No parts: no step, no message.
    @discardableResult
    func performGroup<Result: Sendable>(
        _ actionName: String,
        failure: String?,
        _ body: @escaping @MainActor (UndoGroup) async throws -> Result,
        message: @escaping @MainActor (Result) -> String
    ) async throws -> Result {
        try await serially { [self] in
            let group = UndoGroup()
            let result: Result
            do {
                result = try await body(group)
            } catch {
                await group.work.rollBack(log: log)
                report(error, as: failure)
                throw error
            }
            if !group.work.parts.isEmpty {
                register(UndoStep(actionName: actionName, work: group.work), message: message(result))
            }
            return result
        }
    }

    /// Register an action that already happened (synchronous in-memory edits) and confirm
    /// it. Runs nothing now; `undo` / `redo` run later on the serial queue.
    func record<Done: Sendable, Undone: Sendable>(
        _ actionName: String,
        message: String,
        done: Done,
        undo inverse: @escaping @MainActor (Done) async throws -> Undone,
        redo again: @escaping @MainActor (Undone) async throws -> Done
    ) {
        register(UndoStep(actionName: actionName, work: TypedWork(done: done, undo: inverse, redo: again)), message: message)
    }

    // MARK: Registration

    private func register(_ step: UndoStep, message: String) {
        if let manager = undoManager {
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: step) { [weak self] step in self?.undoInvoked(step) }
            manager.setActionName(step.actionName)
            manager.endUndoGrouping()
            // A new step empties Redo: steps waiting there can't be reached any more.
            for undone in liveSteps where undone.phase == .undone {
                undone.phase = .dropped
                manager.removeAllActions(withTarget: undone)
            }
            liveSteps.removeAll { $0.phase == .dropped }
            liveSteps.append(step)
            topStep = step
            step.phase = .done
            step.messageID = statusBar.post(message, actions: [.undo { [weak self, weak step] in
                guard let self, let step else { return }
                self.undoFromStatusBar(step)
            }])
        } else {
            // No window yet: the action happened; say so, without an Undo that can't work.
            log("No undo manager attached; “\(step.actionName)” can’t be undone")
            step.phase = .dropped
            statusBar.post(message)
        }
    }

    /// The status bar's `Undo` (UC-UNDO-09): the same single undo as ⌘Z, and only while this
    /// step is the one ⌘Z would undo — after ⌘Z (or anything newer on the stack) it does nothing.
    func undoFromStatusBar(_ step: UndoStep) {
        guard step.phase == .done, topStep === step, let manager = undoManager,
              !manager.isUndoing, !manager.isRedoing, manager.canUndo,
              manager.undoActionName == step.actionName else { return }
        manager.undo()
    }

    /// Called by the undo manager inside `undo()`: registers the redo at once (it must be
    /// registered while the manager is undoing), then runs the inverse on the queue.
    private func undoInvoked(_ step: UndoStep) {
        guard step.phase == .done, let manager = undoManager else { return }
        manager.registerUndo(withTarget: step) { [weak self] step in self?.redoInvoked(step) }
        manager.setActionName(step.actionName)
        step.phase = .undone
        if topStep === step { topStep = nil }
        if let id = step.messageID {
            // Its Undo was just used (here or by ⌘Z): the confirmation goes, nothing new comes.
            statusBar.dismiss(id)
            step.messageID = nil
        }
        enqueue { [weak self] in
            // Not `phase == .undone`: a quick Redo may already have flipped the phase; the
            // queue runs this undo and that redo in the order they were asked for.
            guard let self, step.phase != .dropped else { return }
            do {
                try await step.work.undo()
            } catch {
                self.drop(step)
                self.report(error, as: "Couldn’t undo \(step.actionName)")
            }
        }
    }

    private func redoInvoked(_ step: UndoStep) {
        guard step.phase == .undone, let manager = undoManager else { return }
        manager.registerUndo(withTarget: step) { [weak self] step in self?.undoInvoked(step) }
        manager.setActionName(step.actionName)
        step.phase = .done
        topStep = step
        enqueue { [weak self] in
            guard let self, step.phase != .dropped else { return }
            do {
                try await step.work.redo()
            } catch {
                self.drop(step)
                self.report(error, as: "Couldn’t redo \(step.actionName)")
            }
        }
    }

    /// Remove a step whose undo or redo failed from both stacks.
    private func drop(_ step: UndoStep) {
        step.phase = .dropped
        undoManager?.removeAllActions(withTarget: step)
        liveSteps.removeAll { $0 === step }
        if topStep === step { topStep = nil }
    }

    private func report(_ error: Error, as failure: String?) {
        log("\(failure ?? "Undoable action failed"): \(error)")
        guard let failure else { return }
        statusBar.post(UndoFailure.sentence(failure, error))
    }

    // MARK: Serial queue

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        jobs.append(job)
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            await job()
        }
        isDraining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func serially<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    continuation.resume(returning: try await body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Steps

/// One undo step: the registration target on the window's undo manager.
@MainActor
final class UndoStep {
    enum Phase { case pending, done, undone, dropped }

    let actionName: String
    fileprivate let work: any UndoableWork
    fileprivate(set) var phase: Phase = .pending
    fileprivate var messageID: StatusMessage.ID?

    fileprivate init(actionName: String, work: any UndoableWork) {
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
        case done(Done)
        case undone(Undone)
    }

    private var state: State
    private let inverse: @MainActor (Done) async throws -> Undone
    private let again: @MainActor (Undone) async throws -> Done

    init(
        done: Done,
        undo: @escaping @MainActor (Done) async throws -> Undone,
        redo: @escaping @MainActor (Undone) async throws -> Done
    ) {
        state = .done(done)
        inverse = undo
        again = redo
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
    fileprivate let work = GroupWork()

    fileprivate init() {}

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

/// Parts undone newest first and redone oldest first. A failing part puts the parts it
/// already reversed back, so the group stays all-done or all-undone where it can.
@MainActor
final class GroupWork: UndoableWork {
    fileprivate(set) var parts: [any UndoableWork] = []

    func undo() async throws {
        var reversed: [any UndoableWork] = []
        for part in parts.reversed() {
            do {
                try await part.undo()
                reversed.append(part)
            } catch {
                for done in reversed.reversed() { try? await done.redo() }
                throw error
            }
        }
    }

    func redo() async throws {
        var redone: [any UndoableWork] = []
        for part in parts {
            do {
                try await part.redo()
                redone.append(part)
            } catch {
                for done in redone.reversed() { try? await done.undo() }
                throw error
            }
        }
    }

    /// `performGroup`'s body failed: undo what it did, newest first.
    fileprivate func rollBack(log: @MainActor (String) -> Void) async {
        for part in parts.reversed() {
            do {
                try await part.undo()
            } catch {
                log("Rolling back a failed group left a part done: \(error)")
            }
        }
        parts.removeAll()
    }
}

enum UndoCenterError: Error {
    /// Undo of a step that isn't done, or redo of one that isn't undone.
    case outOfOrder
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
    /// The cause of a failed change in plain words. Never the raw error text.
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
        return "the library file didn’t accept the change"
    }

    /// `‹failure› — ‹cause›` (UC-COPY-08: the dash joins what failed and why).
    static func sentence(_ failure: String, _ error: Error) -> String {
        "\(failure) — \(cause(of: error))"
    }
}

// MARK: - Window wiring

extension FocusedValues {
    /// The main window's undo center (menu commands that make undoable changes).
    @Entry var undoCenter: UndoCenter?
}

extension View {
    /// Attach `center` to this window's `UndoManager`. Its steps are dropped when `scope`
    /// changes (another library) and when the view leaves the window.
    func undoCenter(_ center: UndoCenter, scope: String?) -> some View {
        modifier(UndoCenterBinding(center: center, scope: scope))
    }
}

private struct UndoCenterBinding: ViewModifier {
    let center: UndoCenter
    let scope: String?
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onAppear { center.attach(undoManager) }
            .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in center.attach(undoManager) }
            .onChange(of: scope) { _, _ in center.removeAllSteps() }
            .onDisappear { center.attach(nil) }
    }
}
