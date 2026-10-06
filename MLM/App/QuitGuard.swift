import AppKit
import Observation

/// Quit with work running (PP-SHELL-16, DEC-032): `Quit MLM?` lists what stops, from Activity,
/// with `Quit` / `Cancel` (Cancel is the default). Nothing runs → MLM quits at once. While a
/// restore, a library file setup or a path migration runs, Quit is refused with one sentence
/// and `OK` (W3-LAUNCH review S4). A relaunch the user already confirmed (switch, restore)
/// passes without asking again — once, within a few seconds.
///
/// `applicationShouldTerminate` answers `.terminateLater` while `Quit MLM?` is up; the answer
/// goes back through `reply`, so `applicationWillTerminate` (queue and Activity flushes) still
/// runs on Quit.
@MainActor
@Observable
final class QuitGuard {
    static let shared = QuitGuard()

    enum Question: Equatable {
        /// `Quit MLM?` with the work that stops; `libraryName` = where it continues (nil: none open).
        case confirm(RunningWorkSummary, libraryName: String?)
        /// `MLM can’t quit while …` — `OK` only; termination was already cancelled.
        case refuse(String)
    }

    /// The alert shows while this is set.
    private(set) var question: Question?

    /// The work that stops (for `Quit MLM?`).
    var pending: RunningWorkSummary? {
        if case .confirm(let summary, _)? = question { return summary }
        return nil
    }

    /// How long a confirmed relaunch may take to reach `applicationShouldTerminate`
    /// (`BackupService.relaunchApp` gives up after 5 s too).
    static let allowanceInterval: TimeInterval = 5

    @ObservationIgnored private var allowanceDeadline: Date?
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored var activeOperations: @MainActor () -> [ActivityOperation] = {
        ActivityCenter.shared.activeOperations
    }
    /// The library the running work belongs to (`nil` when none is open).
    @ObservationIgnored var libraryName: @MainActor () -> String? = {
        LibraryLaunchCoordinator.shared.workSubjectName
    }
    @ObservationIgnored var reply: @MainActor (Bool) -> Void = { quit in
        NSApp.reply(toApplicationShouldTerminate: quit)
    }
    /// The alert lives in the main window: bring it forward (reopening it after ⌘W).
    @ObservationIgnored var presentWindow: @MainActor () -> Void = { MainWindowPresenter.shared.show() }

    init() {}

    /// The answer for `applicationShouldTerminate(_:)`.
    func shouldTerminate() -> NSApplication.TerminateReply {
        if let deadline = allowanceDeadline {
            allowanceDeadline = nil
            if now() < deadline { return .terminateNow }
        }
        switch question {
        case .confirm?:
            // A second ⌘Q while `Quit MLM?` is up: the open alert answers it. The header only
            // says that a `.terminateLater` must be answered with one
            // `replyToApplicationShouldTerminate:`; AppKit keeps the termination pending until
            // then, so the same alert's one reply answers (N7) — no second alert.
            return .terminateLater
        case .refuse?:
            return .terminateCancel
        case nil:
            break
        }
        let summary = RunningWorkSummary(operations: activeOperations())
        if let refusal = summary.refusal(libraryName: libraryName()) {
            question = .refuse(refusal)
            presentWindow()
            return .terminateCancel
        }
        guard !summary.isEmpty else { return .terminateNow }
        question = .confirm(summary, libraryName: libraryName())
        presentWindow()
        return .terminateLater
    }

    /// `Quit`.
    func confirm() {
        guard case .confirm? = question else { return }
        question = nil
        reply(true)
    }

    /// `Cancel` / Esc on `Quit MLM?`, `OK` on the refusal.
    func cancel() {
        switch question {
        case .confirm?:
            question = nil
            reply(false)
        case .refuse?:
            question = nil
        case nil:
            break
        }
    }

    /// The next termination was confirmed elsewhere (a relaunch): it passes once, within
    /// `allowanceInterval`.
    func allowNextTermination() {
        allowanceDeadline = now().addingTimeInterval(Self.allowanceInterval)
    }

    /// The confirmed relaunch didn't happen (its termination was cancelled): the next Quit
    /// asks again (S5).
    func terminationWasCancelled() {
        allowanceDeadline = nil
    }
}
