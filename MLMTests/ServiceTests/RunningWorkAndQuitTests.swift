import Testing
import AppKit
@testable import MLM

/// W3-LAUNCH (DEC-032, PP-SHELL-16): switching and quitting list the work that will stop,
/// read from Activity; nothing running → no question at Quit.
@Suite("Running work at switch and quit (W3-LAUNCH)")
@MainActor
struct RunningWorkAndQuitTests {

    private func operation(
        _ kind: ActivityKind, _ title: String, state: ActivityState = .running, progress: ActivityProgress = .indeterminate,
        wait: ActivityWait? = nil, startedAt: TimeInterval = 0
    ) -> ActivityOperation {
        ActivityOperation(
            id: UUID(), kind: kind, title: title, subject: .none, state: state, wait: wait, progress: progress,
            result: nil, startedAt: Date(timeIntervalSince1970: 1_000 + startedAt), endedAt: nil,
            isAutomatic: false, libraryID: "lib", needsAttention: false, dismissedAt: nil, itemNoun: .item,
            messageName: kind.messageName, controls: .none, isFromHistory: false)
    }

    @Test func listsWhatStopsByKindOldestFirst() {
        let summary = RunningWorkSummary(operations: [
            operation(.sync, "Sync “iPod Classic”", progress: ActivityProgress(completed: 85, total: 214), startedAt: 3),
            operation(.download, "Import “Liked on SoundCloud”", progress: ActivityProgress(completed: 11, total: 44), startedAt: 1),
            operation(.download, "Download “Rev8617”", state: .queued, startedAt: 2),
            operation(.backup, "Back Up Now", state: .completed, startedAt: 4),
        ])
        #expect(summary.headline == "2 downloads and 1 sync will stop:")
        #expect(summary.lines == [
            "Import “Liked on SoundCloud” — 12 of 44",
            "Download “Rev8617”",
            "Sync “iPod Classic” — 86 of 214",
        ])
        #expect(summary.message(continuingIn: "Main Library") == """
            2 downloads and 1 sync will stop:
            • Import “Liked on SoundCloud” — 12 of 44
            • Download “Rev8617”
            • Sync “iPod Classic” — 86 of 214

            They continue the next time you open “Main Library”.
            """)
    }

    @Test func workWaitingForTheDriveIsNotListed() {
        let summary = RunningWorkSummary(operations: [
            operation(.tagWrite, "Write tags to files", state: .queued, wait: .drive(volumeName: "Lexxar")),
        ])
        #expect(summary.isEmpty)
        #expect(summary.message(continuingIn: "Main Library") == nil)
    }

    @Test func oneOperationAndALongList() {
        let one = RunningWorkSummary(operations: [operation(.folderScan, "Scan “Music”")])
        #expect(one.headline == "1 scan will stop:")
        #expect(one.message(continuingIn: "A")?.hasSuffix("It continues the next time you open “A”.") == true)
        let many = RunningWorkSummary(operations: (0..<7).map { operation(.download, "D\($0)", startedAt: Double($0)) })
        #expect(many.lines.count == RunningWorkSummary.maxLines)
        #expect(many.moreCount == 2)
        #expect(many.message(continuingIn: "A")?.contains("• and 2 more") == true)
        #expect(RunningWorkSummary.joined(["a", "b", "c"]) == "a, b and c")
    }

    // MARK: Quit

    private func quitGuard(_ operations: [ActivityOperation]) -> (QuitGuard, replies: () -> [Bool], presented: () -> Int) {
        let guardian = QuitGuard()
        var replies: [Bool] = []
        var presented = 0
        guardian.activeOperations = { operations }
        guardian.reply = { replies.append($0) }
        guardian.presentWindow = { presented += 1 }
        guardian.libraryName = { "Main Library" }
        return (guardian, { replies }, { presented })
    }

    @Test func quitWithNothingRunningIsImmediate() {
        let (guardian, replies, presented) = quitGuard([])
        #expect(guardian.shouldTerminate() == .terminateNow)
        #expect(guardian.pending == nil)
        #expect(replies().isEmpty && presented() == 0)
    }

    @Test func quitWithRunningWorkAsksAndAnswersLater() {
        let (guardian, replies, presented) = quitGuard([operation(.download, "Download “Rev8617”")])
        #expect(guardian.shouldTerminate() == .terminateLater)
        #expect(guardian.pending?.headline == "1 download will stop:")
        #expect(presented() == 1)
        // N7: a second ⌘Q while the question is up: still pending, no second alert.
        #expect(guardian.shouldTerminate() == .terminateLater, "the open question answers")
        #expect(presented() == 1)
        guardian.cancel()
        #expect(replies() == [false])
        #expect(guardian.pending == nil)

        #expect(guardian.shouldTerminate() == .terminateLater)
        guardian.confirm()
        #expect(replies() == [false, true])
    }

    @Test func aConfirmedRelaunchIsNotAskedAgain() {
        let (guardian, replies, _) = quitGuard([operation(.download, "Download “Rev8617”")])
        guardian.allowNextTermination()
        #expect(guardian.shouldTerminate() == .terminateNow)
        #expect(guardian.shouldTerminate() == .terminateLater, "only the next one")
        #expect(replies().isEmpty)
    }

    /// S5: the allowance expires with the relaunch timer and is cleared when the relaunch's
    /// termination was cancelled.
    @Test func theRelaunchAllowanceExpiresAndIsCleared() {
        let (guardian, _, _) = quitGuard([operation(.download, "Download “Rev8617”")])
        var clock = Date(timeIntervalSince1970: 1_000)
        guardian.now = { clock }
        guardian.allowNextTermination()
        clock = clock.addingTimeInterval(QuitGuard.allowanceInterval + 1)
        #expect(guardian.shouldTerminate() == .terminateLater, "an expired allowance asks again")
        guardian.cancel()

        guardian.allowNextTermination()
        guardian.terminationWasCancelled()
        #expect(guardian.shouldTerminate() == .terminateLater, "a cancelled relaunch asks again")
    }

    /// S4: Quit is refused (OK only) while a restore, a library file setup or a path migration runs.
    @Test func quitIsRefusedWhileWorkMustNotBeCutOff() {
        for (kind, sentence) in [
            (ActivityKind.restore, "MLM can’t quit while “Main Library” is being restored."),
            (.libraryAdoption, "MLM can’t quit while the library file “Main Library” is being set up."),
            (.pathMigration, "MLM can’t quit while the files of “Main Library” are being moved."),
        ] {
            let (guardian, replies, presented) = quitGuard([
                operation(.download, "Download “Rev8617”"), operation(kind, "Work", startedAt: 1),
            ])
            #expect(guardian.shouldTerminate() == .terminateCancel)
            #expect(guardian.question == .refuse(sentence))
            #expect(presented() == 1)
            guardian.cancel()   // OK
            #expect(guardian.question == nil)
            #expect(replies().isEmpty, "termination was cancelled already; nothing to answer")
        }
        // Queued (not running yet): not a blocker.
        let queued = RunningWorkSummary(operations: [operation(.restore, "Restore", state: .queued)])
        #expect(queued.blocker == nil)
        // No library open: `MLM`'s own words only.
        #expect(RunningWorkSummary(operations: [operation(.restore, "Restore")]).refusal(libraryName: nil)
                == "MLM can’t quit while a library is being restored.")
    }

    /// S4: work that can't continue later is listed without the continuation promise.
    @Test func onlyContinuingWorkIsPromisedToContinue() {
        let backupOnly = RunningWorkSummary(operations: [operation(.backup, "Back Up Now")])
        #expect(backupOnly.message(continuingIn: "Main Library") == "1 backup will stop:\n• Back Up Now")
        let mixed = RunningWorkSummary(operations: [
            operation(.download, "Download “A”"), operation(.download, "Download “B”", startedAt: 1),
            operation(.transcodeCacheMove, "Move transcode cache", startedAt: 2),
        ])
        #expect(mixed.headline == "2 downloads and 1 cache move will stop:")
        #expect(mixed.message(continuingIn: "Main Library")?.hasSuffix("\n\n2 downloads continue the next time you open “Main Library”.") == true)
        // No library open: nothing is promised.
        let noLibrary = RunningWorkSummary(operations: [operation(.download, "Download “A”")])
        #expect(noLibrary.message(continuingIn: nil) == "1 download will stop:\n• Download “A”")
    }
}
