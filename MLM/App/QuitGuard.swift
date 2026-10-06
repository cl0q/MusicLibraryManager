import AppKit
import Observation

/// Quit with work running (PP-SHELL-16, DEC-032): `Quit MLM?` lists what stops, from Activity,
/// with `Quit` / `Cancel` (Cancel is the default). Nothing runs → MLM quits at once. A relaunch
/// the user already confirmed (switch, restore) is let through without asking again.
///
/// `applicationShouldTerminate` answers `.terminateLater` while the alert is up; the answer
/// goes back through `reply`, so `applicationWillTerminate` (queue and Activity flushes) still
/// runs on Quit.
@MainActor
@Observable
final class QuitGuard {
    static let shared = QuitGuard()

    /// The work that stops; the alert shows while this is set.
    private(set) var pending: RunningWorkSummary?

    @ObservationIgnored private var allowsNextTermination = false
    @ObservationIgnored var activeOperations: @MainActor () -> [ActivityOperation] = {
        ActivityCenter.shared.activeOperations
    }
    @ObservationIgnored var reply: @MainActor (Bool) -> Void = { quit in
        NSApp.reply(toApplicationShouldTerminate: quit)
    }
    /// The alert lives in the main window: bring it forward (reopening it after ⌘W).
    @ObservationIgnored var presentWindow: @MainActor () -> Void = { MainWindowPresenter.shared.show() }

    init() {}

    /// The answer for `applicationShouldTerminate(_:)`.
    func shouldTerminate() -> NSApplication.TerminateReply {
        if allowsNextTermination {
            allowsNextTermination = false
            return .terminateNow
        }
        // Already asking: the open alert answers.
        guard pending == nil else { return .terminateCancel }
        let summary = RunningWorkSummary(operations: activeOperations())
        guard !summary.isEmpty else { return .terminateNow }
        pending = summary
        presentWindow()
        return .terminateLater
    }

    /// `Quit`.
    func confirm() {
        guard pending != nil else { return }
        pending = nil
        reply(true)
    }

    /// `Cancel` / Esc.
    func cancel() {
        guard pending != nil else { return }
        pending = nil
        reply(false)
    }

    /// The next termination was confirmed elsewhere (a relaunch).
    func allowNextTermination() {
        allowsNextTermination = true
    }
}
