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

    private func makeEnv(attached: Bool = true) -> Env {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let recorder = Recorder()
        let sleeper = self.sleeper
        let status = StatusBarCenter(
            sleep: { duration in await sleeper.sleep(duration) },
            announce: { recorder.announced.append($0) }
        )
        let center = UndoCenter(
            undoManager: attached ? manager : nil,
            statusBar: status,
            log: { recorder.logged.append($0) }
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
        #expect(env.status.message?.text == "Couldn’t change the tags — the library file didn’t accept the change")
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
        #expect(env.status.message?.text == "Couldn’t undo Merge Genres — the library file didn’t accept the change")
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
        #expect(env.status.message?.text == "Couldn’t rename “A” — the library file didn’t accept the change")
        #expect(env.status.message?.actions.isEmpty == true)
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

    @Test func aFailingUndoDropsTheStepAndNamesTheCause() async throws {
        let env = makeEnv()
        try await perform(env, tag: "1")
        try await env.center.perform("Rename Playlist", message: "Renamed again", failure: nil,
                                     do: {}, undo: { throw Gone() })
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.status.message?.text == "Couldn’t undo Rename Playlist — “Warm-up” no longer exists")
        #expect(!env.manager.canRedo) // not left as if undone
        #expect(env.manager.canUndo) // the step below is untouched
        #expect(env.center.stepCount == 1)
        env.manager.undo()
        await env.center.waitUntilIdle()
        #expect(env.recorder.calls == ["do1", "undo1"])
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
        #expect(env.status.message?.text == "Couldn’t redo Rename Playlist — the library file didn’t accept the change")
        #expect(env.center.stepCount == 0)
    }

    @Test func databaseCausesAreWordedPlainly() {
        #expect(UndoFailure.cause(of: Boom()) == "the library file didn’t accept the change")
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

    @Test func attachingAnotherWindowsManagerDropsTheOldSteps() async throws {
        let env = makeEnv()
        try await perform(env)
        let other = UndoManager()
        env.center.attach(other)
        #expect(!env.manager.canUndo)
        #expect(env.center.undoManager === other)
        env.center.attach(nil)
        #expect(env.center.undoManager == nil)
    }

    @Test func withoutAWindowTheActionStillRunsAndConfirmsWithoutUndo() async throws {
        let env = makeEnv(attached: false)
        try await perform(env)
        #expect(env.recorder.calls == ["do"])
        #expect(env.status.message?.text == "Renamed “A” to “B”")
        #expect(env.status.message?.actions.isEmpty == true)
        #expect(env.center.stepCount == 0)
    }
}
