import Foundation
import Testing
@testable import MLM

/// Pure tests of the undo contract (W2-F, UC-UNDO-01…09, UC-STATUS-04/05) on a private
/// `UndoManager` and a status bar whose messages never expire.
@Suite("Undo center")
@MainActor
struct UndoCenterTests {
    @MainActor
    final class Recorder {
        var calls: [String] = []
        var announced: [String] = []
        var logged: [String] = []
        var reentrancy: [String] = []
        /// Foreign undo targets: the manager holds them unowned, so the test keeps them.
        var keep: [AnyObject] = []
    }

    /// A gate a closure waits on until the test opens it.
    @MainActor
    final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { waiter = $0 }
            isWaiting = false
        }

        func open() {
            waiter?.resume()
            waiter = nil
        }
    }

    private func until(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    struct Boom: Error {}

    struct Gone: PlainCauseError {
        var plainCause: String { "“Warm-up” no longer exists" }
    }

    /// A foreign undo target, standing in for a text field's typing.
    final class Foreign {}

    @MainActor
    struct Env {
        let manager: UndoManager
        let status: StatusBarCenter
        let center: UndoCenter
        let recorder: Recorder
    }

    private let sleeper = ManualSleeper()

    private func makeEnv(attached: Bool = true, groupsByEvent: Bool = false) -> Env {
        let manager = UndoManager()
        manager.groupsByEvent = groupsByEvent
        let recorder = Recorder()
        let sleeper = self.sleeper
        let status = StatusBarCenter(
            sleep: { duration in await sleeper.sleep(duration) },
            announce: { recorder.announced.append($0) }
        )
        let center = UndoCenter(
            undoManager: attached ? manager : nil,
            statusBar: status,
            log: { recorder.logged.append($0) },
            reentrancyFailure: { recorder.reentrancy.append($0) }
        )
        return Env(manager: manager, status: status, center: center, recorder: recorder)
    }

    private func perform(_ env: Env, _ name: String = "Rename Playlist", tag: String = "") async throws {
        let recorder = env.recorder
        try await env.center.perform(
            name,
            message: "Renamed “A” to “B”\(tag)",
            failure: "Couldn’t rename “A”",
            do: { recorder.calls.append("do\(tag)") },
            undo: { recorder.calls.append("undo\(tag)") }
        )
    }

    private func registerForeign(_ manager: UndoManager, name: String = "Typing", flag: Recorder) -> Foreign {
        let foreign = Foreign()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: foreign) { _ in MainActor.assumeIsolated { flag.calls.append("foreign undo") } }
        manager.setActionName(name)
        manager.endUndoGrouping()
        flag.keep.append(foreign)
        return foreign
    }

    // MARK: Order and names

    @Test func doUndoRedoRunInOrderAndNameEditUndoAndRedo() async throws {
        let env = makeEnv()
        try await perform(env)
        #expect(env.recorder.calls == ["do"])
        #expect(env.manager.canUndo)
        #expect(env.manager.undoActionName == "Rename Playlist")
        #expect(env.manager.undoMenuItemTitle == "Undo Rename Playlist")

        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do", "undo"])
        #expect(!env.manager.canUndo)
        #expect(env.manager.canRedo)
        #expect(env.manager.redoMenuItemTitle == "Redo Rename Playlist")

        env.manager.redo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do", "undo", "do"])
        #expect(env.manager.canUndo)
        #expect(!env.manager.canRedo)
        #expect(env.manager.undoMenuItemTitle == "Undo Rename Playlist")
    }

    @Test func actionNamesCarryTheObjectWithTypographicQuotes() async throws {
        let env = makeEnv()
        try await perform(env, "Add to “Warm-up”")
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “Warm-up”")
    }

    @Test func undoAndRedoReceiveTheValuesTheOtherDirectionReturned() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        var nextRow: Int64 = 10
        let done = try await env.center.perform(
            "Add to “Warm-up”",
            failure: nil,
            do: { () async throws -> [Int64]? in [1, 2] },
            undo: { (rows: [Int64]) in
                recorder.calls.append("undo \(rows)")
                return "removed \(rows.count)"
            },
            redo: { (note: String) in
                recorder.calls.append("redo \(note)")
                nextRow += 1
                return [nextRow]
            },
            message: { "Added \($0.count) tracks to “Warm-up”" }
        )
        #expect(done == [1, 2])
        env.manager.undo()
        await env.center.waitUntilIdle()
        env.manager.redo()
        await env.center.waitUntilIdle()
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["undo [1, 2]", "redo removed 2", "undo [11]"])
    }

    @Test func nothingChangedRegistersNothingAndPostsNothing() async throws {
        let env = makeEnv()
        let result = try await env.center.perform(
            "Add to “Warm-up”",
            failure: "Couldn’t add",
            do: { () async throws -> Int? in nil },
            undo: { (_: Int) in () },
            redo: { (_: Void) in 1 },
            message: { _ in "Added" }
        )
        #expect(result == nil)
        #expect(!env.manager.canUndo)
        #expect(env.status.message == nil)
        #expect(env.center.stepCount == 0)
    }

    @Test func recordRegistersAnActionThatAlreadyHappened() async {
        let env = makeEnv()
        let recorder = env.recorder
        env.center.record(
            "Remove from Queue",
            message: "Removed 2 tracks from the queue",
            done: 2,
            undo: { (n: Int) in recorder.calls.append("undo \(n)") },
            redo: { (_: Void) in
                recorder.calls.append("redo")
                return 2
            }
        )
        #expect(recorder.calls.isEmpty)
        #expect(env.status.message?.text == "Removed 2 tracks from the queue")
        env.manager.undo()
        await env.center.waitUntilIdle()
        env.manager.redo()
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["undo 2", "redo"])
    }

    // MARK: One gesture = one step (UC-UNDO-08)

    @Test func aGroupIsOneStepUndoneNewestFirstAndRedoneInOrder() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        try await env.center.performGroup("Edit Tags", failure: nil, { group in
            for n in 1...3 {
                try await group.perform(do: { recorder.calls.append("do\(n)") },
                                        undo: { recorder.calls.append("undo\(n)") })
            }
            return group.count
        }, message: { "Changed the tags of \($0) tracks" })

        #expect(env.status.message?.text == "Changed the tags of 3 tracks")
        #expect(env.manager.undoMenuItemTitle == "Undo Edit Tags")
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(!env.manager.canUndo)
        #expect(recorder.calls == ["do1", "do2", "do3", "undo3", "undo2", "undo1"])
        env.manager.redo()
        await env.center.waitUntilIdle()
        #expect(recorder.calls.suffix(3) == ["do1", "do2", "do3"])
        #expect(env.manager.canUndo && !env.manager.canRedo)
    }

    @Test func aFailingPartRollsBackTheGroupAndRegistersNothing() async {
        let env = makeEnv()
        let recorder = env.recorder
        await #expect(throws: Boom.self) {
            try await env.center.performGroup("Edit Tags", failure: "Couldn’t change the tags", { group in
                try await group.perform(do: { recorder.calls.append("do1") }, undo: { recorder.calls.append("undo1") })
                try await group.perform(do: { recorder.calls.append("do2") }, undo: { recorder.calls.append("undo2") })
                try await group.perform(do: { throw Boom() }, undo: { recorder.calls.append("undo3") })
            }, message: { "Changed" })
        }
        #expect(recorder.calls == ["do1", "do2", "undo2", "undo1"])
        #expect(!env.manager.canUndo)
        #expect(env.status.message?.text == "Couldn’t change the tags — something went wrong (the details are in the log)")
    }

    @Test func aGroupWhoseUndoFailsHalfWayPutsTheUndonePartsBack() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        try await env.center.performGroup("Merge Genres", failure: nil, { group in
            try await group.perform(do: { recorder.calls.append("do1") }, undo: { throw Boom() })
            try await group.perform(do: { recorder.calls.append("do2") }, undo: { recorder.calls.append("undo2") })
        }, message: { "Merged" })
        env.manager.undo()
        await env.center.waitUntilIdle()
        // Part 2 was undone, part 1 failed: part 2 is redone so the group stays all-done.
        #expect(recorder.calls == ["do1", "do2", "undo2", "do2"])
        #expect(!env.manager.canUndo && !env.manager.canRedo)
        #expect(env.status.message?.text == "Couldn’t undo Merge Genres — something went wrong (the details are in the log)")
    }

    // MARK: Status bar (UC-STATUS-04, UC-UNDO-09)

    @Test func theConfirmationIsPostedOnceWithUndoAndNeverAgainOnUndoOrRedo() async throws {
        let env = makeEnv()
        try await perform(env)
        #expect(env.recorder.announced == ["Renamed “A” to “B”"])
        #expect(env.status.message?.actions.map(\.title) == ["Undo"])

        env.manager.undo()
        await env.center.waitUntilIdle()
        env.manager.redo()
        await env.center.waitUntilIdle()
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.announced == ["Renamed “A” to “B”"])
    }

    @Test func theStatusBarUndoIsTheSameSingleUndoAsCommandZ() async throws {
        let env = makeEnv()
        try await perform(env)
        let undo = try #require(env.status.message?.actions.first)
        env.status.perform(undo)
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do", "undo"])
        #expect(env.status.message == nil)
        #expect(env.manager.canRedo)
        #expect(env.manager.redoMenuItemTitle == "Redo Rename Playlist")
    }

    @Test func pressingUndoAfterCommandZAlreadyUndidTheStepDoesNothing() async throws {
        let env = makeEnv()
        try await perform(env, tag: "1")
        try await perform(env, tag: "2")
        let undo = try #require(env.status.message?.actions.first)

        env.manager.undo() // ⌘Z undoes step 2 and removes its confirmation
        await env.center.waitUntilIdle()
        #expect(env.status.message == nil)

        undo.perform() // a stale button: must not undo step 1
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do1", "do2", "undo2"])
        #expect(env.manager.canUndo) // step 1 still there
        #expect(env.manager.canRedo) // step 2 still redoable
    }

    @Test func theStatusBarUndoNeverUndoesSomethingNewerSuchAsTyping() async throws {
        let env = makeEnv()
        try await perform(env)
        let undo = try #require(env.status.message?.actions.first)
        _ = registerForeign(env.manager, flag: env.recorder)
        // The button is taken off at once; the text stays for its remaining time (S3).
        #expect(env.status.message?.text == "Renamed “A” to “B”")
        #expect(env.status.message?.actions.isEmpty == true)

        env.status.perform(undo)
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do"])
        #expect(env.manager.undoActionName == "Typing")
    }

    @Test func undoingAStepWhileANewerMessageShowsLeavesThatMessage() async throws {
        let env = makeEnv()
        try await perform(env)
        env.status.post("Import started — “Sets”")
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do", "undo"])
        #expect(env.status.message?.text == "Import started — “Sets”")
        #expect(env.recorder.announced == ["Renamed “A” to “B”", "Import started — “Sets”"])
    }

    @Test func undoingAStepTakesItsOwnConfirmationAway() async throws {
        let env = makeEnv()
        try await perform(env)
        env.manager.undo()
        #expect(env.status.message == nil)
        await env.center.waitUntilIdle()
    }

    // MARK: Failures

    @Test func aFailingActionRegistersNothingAndSaysWhatFailed() async {
        let env = makeEnv()
        await #expect(throws: Boom.self) {
            try await env.center.perform("Rename Playlist", message: "Renamed", failure: "Couldn’t rename “A”",
                                         do: { throw Boom() }, undo: {})
        }
        #expect(!env.manager.canUndo)
        #expect(env.center.stepCount == 0)
        #expect(env.status.message?.text == "Couldn’t rename “A” — something went wrong (the details are in the log)")
        #expect(env.status.message?.actions.map(\.title) == ["Try Again"])
        #expect(env.recorder.logged.count == 1)
    }

    @Test func aFailureTheCallerShowsItselfIsNotPosted() async {
        let env = makeEnv()
        await #expect(throws: Gone.self) {
            try await env.center.perform("Rename Playlist", message: "Renamed", failure: nil,
                                         do: { throw Gone() }, undo: {})
        }
        #expect(env.status.message == nil)
    }

    @Test func aFailingUndoDropsTheStepAndEveryOlderOne() async throws {
        let env = makeEnv()
        try await perform(env, tag: "1")
        try await env.center.perform("Delete “Warm-up”", message: "Deleted", failure: nil,
                                     do: {}, undo: { throw Gone() })
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.status.message?.text
            == "Couldn’t undo Delete “Warm-up” — “Warm-up” no longer exists. Earlier changes can no longer be undone.")
        #expect(!env.manager.canRedo) // not left as if undone
        #expect(!env.manager.canUndo) // the older step assumed a state that no longer holds
        #expect(env.center.stepCount == 0)
        #expect(env.recorder.calls == ["do1"])
    }

    @Test func aFailingUndoWithNothingOlderSaysOnlyWhatFailed() async throws {
        let env = makeEnv()
        try await env.center.perform("Delete “Warm-up”", message: "Deleted", failure: nil, do: {}, undo: { throw Gone() })
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.status.message?.text == "Couldn’t undo Delete “Warm-up” — “Warm-up” no longer exists")
    }

    @Test func twoQuickUndosWhereTheNewerFailsCancelTheOlderUndo() async throws {
        let env = makeEnv()
        try await perform(env, tag: "1")
        try await env.center.perform("Delete “Warm-up”", message: "Deleted", failure: nil,
                                     do: {}, undo: { throw Gone() })
        env.manager.undo()
        env.manager.undo() // queued behind the failing one
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do1"]) // the older undo never ran against the stale state
        #expect(!env.manager.canUndo && !env.manager.canRedo)
        #expect(env.status.message?.text
            == "Couldn’t undo Delete “Warm-up” — “Warm-up” no longer exists. Earlier changes can no longer be undone.")
    }

    @Test func undoWithNothingLeftDropsOnlyThatStepWithANote() async throws {
        let env = makeEnv()
        try await perform(env, tag: "1")
        try await env.center.perform("Add to “Warm-up”", message: "Added", failure: nil, do: {}, undo: {
            throw UndoNothingLeft(note: "Nothing to undo — the tracks are no longer in “Warm-up”")
        })
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.status.message?.text == "Nothing to undo — the tracks are no longer in “Warm-up”")
        #expect(!env.manager.canRedo) // no empty redo step
        #expect(env.manager.undoActionName == "Rename Playlist")
        #expect(env.center.stepCount == 1)
    }

    @Test func aFailingRedoDropsTheStep() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        var attempts = 0
        try await env.center.perform("Rename Playlist", message: "Renamed", failure: nil, do: {
            attempts += 1
            if attempts > 1 { throw Boom() }
            recorder.calls.append("do")
        }, undo: { recorder.calls.append("undo") })
        env.manager.undo()
        await env.center.waitUntilIdle()
        env.manager.redo()
        await env.center.waitUntilIdle()
        #expect(!env.manager.canUndo && !env.manager.canRedo)
        #expect(env.status.message?.text == "Couldn’t redo Rename Playlist — something went wrong (the details are in the log)")
        #expect(env.center.stepCount == 0)
    }

    @Test func databaseCausesAreWordedPlainly() {
        #expect(UndoFailure.cause(of: Boom()) == "something went wrong (the details are in the log)")
        #expect(UndoFailure.cause(of: UndoTargetMissing(quotedName: "“Warm-up”")) == "“Warm-up” no longer exists")
        #expect(UndoFailure.sentence("Couldn’t delete “Warm-up”", Gone()) == "Couldn’t delete “Warm-up” — “Warm-up” no longer exists")
    }

    // MARK: Ordering and lifetime

    @Test func quickUndoRedoUndoRunsStrictlyInOrder() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        try await env.center.perform("Rename Playlist", message: "Renamed", failure: nil, do: {
            await Task.yield()
            recorder.calls.append("do")
        }, undo: {
            await Task.yield()
            recorder.calls.append("undo")
        })
        env.manager.undo()
        env.manager.redo()
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["do", "undo", "do", "undo"])
        #expect(env.manager.canRedo && !env.manager.canUndo)
    }

    @Test func aNewStepEmptiesRedoAndForgetsTheUndoneSteps() async throws {
        let env = makeEnv()
        try await perform(env, tag: "1")
        env.manager.undo()
        await env.center.waitUntilIdle()
        try await perform(env, tag: "2")
        #expect(!env.manager.canRedo)
        #expect(env.center.stepCount == 1)
    }

    @Test func removingAllStepsKeepsATextFieldsTypingUndo() async throws {
        let env = makeEnv()
        _ = registerForeign(env.manager, flag: env.recorder)
        try await perform(env)
        env.center.removeAllSteps()
        #expect(env.center.stepCount == 0)
        #expect(env.manager.canUndo)
        #expect(env.manager.undoActionName == "Typing")
    }

    @Test func stepsMoveToTheReopenedWindowsManagerWithBothStacksInOrder() async throws {
        let env = makeEnv()
        try await perform(env, "Step 1", tag: "1")
        try await perform(env, "Step 2", tag: "2")
        try await perform(env, "Step 3", tag: "3")
        env.manager.undo()
        await env.center.waitUntilIdle()

        env.center.attach(nil) // the main window closes; MLM keeps running
        #expect(!env.manager.canUndo && !env.manager.canRedo)
        #expect(env.center.stepCount == 3)

        let reopened = UndoManager()
        env.center.attach(reopened)
        #expect(reopened.undoActionName == "Step 2")
        #expect(reopened.redoActionName == "Step 3")
        #expect(reopened.levelsOfUndo == UndoCenter.levelsOfUndo)

        reopened.undo()
        await env.center.waitUntilIdle()
        reopened.undo()
        await env.center.waitUntilIdle()
        #expect(!reopened.canUndo)
        reopened.redo()
        reopened.redo()
        reopened.redo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do1", "do2", "do3", "undo3", "undo2", "undo1", "do1", "do2", "do3"])
        #expect(reopened.undoActionName == "Step 3" && !reopened.canRedo)
    }

    @Test func withoutAWindowTheActionRunsAndBecomesUndoableOnceAWindowAttaches() async throws {
        let env = makeEnv(attached: false)
        try await perform(env)
        #expect(env.recorder.calls == ["do"])
        #expect(env.status.message?.text == "Renamed “A” to “B”")
        #expect(env.status.message?.actions.isEmpty == true)
        env.center.attach(env.manager)
        #expect(env.manager.undoMenuItemTitle == "Undo Rename Playlist")
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do", "undo"])
    }

    @Test func anotherLibraryDropsTheStepsTheSameLibraryKeepsThem() async throws {
        let env = makeEnv()
        env.center.use(scope: "library-1")
        try await perform(env)
        env.center.use(scope: "library-1")
        #expect(env.center.stepCount == 1)
        env.center.use(scope: "library-2")
        #expect(env.center.stepCount == 0)
        #expect(!env.manager.canUndo)
    }

    // MARK: Actions in flight (⌘Z while `do` runs)

    @Test func commandZWhileAnActionRunsUndoesThatActionAfterIt() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        let gate = Gate()
        try await perform(env, tag: "R") // Rename, done
        let add = Task {
            try await env.center.perform("Add to “Warm-up”", message: "Added", failure: nil, do: {
                await gate.wait()
                recorder.calls.append("add")
            }, undo: { recorder.calls.append("unadd") })
        }
        await until { gate.isWaiting }
        // Registered before `do` finished: ⌘Z names it, and the Rename's Undo button is gone.
        #expect(env.manager.undoActionName == "Add to “Warm-up”")
        #expect(env.status.message?.actions.isEmpty == true)

        env.manager.undo()
        gate.open()
        try await add.value
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["doR", "add", "unadd"])
        #expect(env.manager.undoActionName == "Rename Playlist") // the Rename is untouched
        #expect(env.manager.redoActionName == "Add to “Warm-up”")
        #expect(env.recorder.announced == ["Renamed “A” to “B”R"]) // no confirmation for the undone Add
    }

    @Test func anActionInFlightThatFailsAfterCommandZLeavesBothStacksClean() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        let gate = Gate()
        try await perform(env, tag: "R")
        let add = Task {
            try await env.center.perform("Add to “Warm-up”", message: "Added", failure: nil, do: {
                await gate.wait()
                throw Boom()
            }, undo: { recorder.calls.append("unadd") })
        }
        await until { gate.isWaiting }
        env.manager.undo()
        gate.open()
        await #expect(throws: Boom.self) { try await add.value }
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["doR"])
        #expect(env.manager.undoActionName == "Rename Playlist")
        #expect(!env.manager.canRedo)
    }

    @Test func recordWhileAnUndoIsQueuedStillRunsThatUndo() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        try await perform(env, tag: "A")
        env.manager.undo() // queued, not run yet
        env.center.record("Remove from Queue", message: "Removed", done: 1,
                          undo: { (_: Int) in recorder.calls.append("unremove") },
                          redo: { (_: Void) in 1 })
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["doA", "undoA"])
        #expect(env.manager.undoActionName == "Remove from Queue")
        #expect(!env.manager.canRedo) // the new step emptied Redo
        #expect(env.center.stepCount == 1)
    }

    @Test func droppingTheStepsSkipsTheirQueuedWork() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        let gate = Gate()
        try await perform(env, tag: "A")
        env.manager.undo() // queued
        let slow = Task {
            try await env.center.perform("Slow", message: "Slow", failure: nil, do: {
                await gate.wait()
                recorder.calls.append("slow")
            }, undo: {})
        }
        let queued = Task {
            try await env.center.perform("Queued", message: "Queued", failure: nil, do: {
                recorder.calls.append("queued")
            }, undo: {})
        }
        await until { gate.isWaiting && env.center.stepCount == 2 }
        env.center.removeAllSteps() // another library opened
        gate.open()
        try await slow.value // already running: it finishes, but registers nothing
        await #expect(throws: UndoCenterError.self) { try await queued.value }
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["doA", "undoA", "slow"])
        #expect(!env.manager.canUndo && !env.manager.canRedo)
        #expect(env.recorder.logged.contains { $0.hasPrefix("Skipped queued “Queued”") })
    }

    // MARK: Re-entrancy, levels, retry

    @Test func callingTheCenterFromInsideAClosureFailsInsteadOfDeadlocking() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        let center = env.center
        try await center.perform("Outer", message: "Outer", failure: nil, do: {
            do {
                try await center.perform("Inner", message: "Inner", failure: nil, do: {}, undo: {})
            } catch UndoCenterError.reentrant {
                recorder.calls.append("refused")
            }
        }, undo: {})
        #expect(recorder.calls == ["refused"])
        #expect(recorder.reentrancy.count == 1)
        #expect(env.manager.undoActionName == "Outer")
        #expect(center.stepCount == 1)
    }

    @Test func atMostOneHundredStepsAreKept() async {
        let env = makeEnv()
        #expect(env.manager.levelsOfUndo == 100)
        for n in 1...101 {
            env.center.record("Step \(n)", message: "Step \(n)", done: n,
                              undo: { (_: Int) in () }, redo: { (_: Void) in n })
        }
        #expect(env.center.stepCount == 100)
    }

    @Test func tryAgainRunsAFailedActionOnceMore() async throws {
        let env = makeEnv()
        let recorder = env.recorder
        var attempts = 0
        await #expect(throws: Boom.self) {
            try await env.center.perform("Rename Playlist", message: "Renamed", failure: "Couldn’t rename “A”", do: {
                attempts += 1
                if attempts == 1 { throw Boom() }
                recorder.calls.append("do")
            }, undo: {})
        }
        let tryAgain = try #require(env.status.message?.actions.first)
        #expect(tryAgain.title == "Try Again")
        env.status.perform(tryAgain)
        await until { env.center.stepCount == 1 }
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["do"])
        #expect(env.status.message?.text == "Renamed")
        #expect(env.manager.undoActionName == "Rename Playlist")
    }

    @Test func aGroupThatCannotBeRolledBackFullySaysSo() async {
        let env = makeEnv()
        await #expect(throws: Boom.self) {
            try await env.center.performGroup("Edit Tags", failure: "Couldn’t change the tags", { group in
                try await group.perform(do: {}, undo: {})
                try await group.perform(do: {}, undo: { throw Boom() })
                try await group.perform(do: { throw Boom() }, undo: {})
            }, message: { "Changed" })
        }
        #expect(env.status.message?.text == "Couldn’t change the tags — \(Self.neutral). 1 change couldn’t be taken back.")
        #expect(env.recorder.logged.contains { $0.hasPrefix("Rolling back a failed group") })
    }

    static let neutral = "something went wrong (the details are in the log)"

    // MARK: The window manager's real configuration (groupsByEvent)

    @Test func withEventGroupingEachStepStaysItsOwnUndoStep() async throws {
        let env = makeEnv(groupsByEvent: true)
        let recorder = env.recorder
        // Two steps registered in the same run-loop turn must not merge into one event group.
        for n in 1...2 {
            env.center.record("Step \(n)", message: "Step \(n)", done: n,
                              undo: { (k: Int) in recorder.calls.append("undo\(k)") },
                              redo: { (_: Void) in n })
        }
        #expect(env.manager.groupingLevel == 0)
        try await perform(env, tag: "3") // and one registered from a task
        #expect(env.manager.groupingLevel == 0)
        env.manager.undo()
        await env.center.waitUntilIdle()
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(recorder.calls == ["do3", "undo3", "undo2"])
        #expect(env.manager.undoActionName == "Step 1")
        #expect(env.manager.groupsByEvent) // left as the window had it
    }

    @Test func withEventGroupingTheStatusBarUndoUndoesExactlyItsStep() async throws {
        let env = makeEnv(groupsByEvent: true)
        try await perform(env, tag: "1")
        try await perform(env, tag: "2")
        let undo = try #require(env.status.message?.actions.first)
        env.status.perform(undo)
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do1", "do2", "undo2"])
        #expect(env.manager.canUndo)
    }
}
