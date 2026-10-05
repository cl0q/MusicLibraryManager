import Foundation
import GRDB
import Testing
@testable import MLM

/// Info's model (DEC-007, UC-TRAIL-03/04): none / one / many, `Mixed`, commits keyed to the
/// selection — PP-INSPECTOR-04 (an open edit saved into the *next* track) can't happen.
@Suite("InspectorModel")
@MainActor
struct InspectorModelTests {
    /// Every commit the model made: which value went to which tracks.
    final class Commits {
        var calls: [(value: TrackTagValue, field: TrackTagField, ids: [Int64])] = []
        var failNext: Error?
    }

    struct Env {
        let db: DatabaseQueue
        let repository: TrackTagRepository
        let model: InspectorModel
        let commits: Commits
        let failures: Failures
        let loads: Loads
    }

    final class Failures {
        var messages: [String] = []
    }

    /// Makes the next loads fail (S4).
    final class Loads {
        var fail = false
    }

    struct Busy: Error {}

    private func makeEnv() throws -> Env {
        let db = try DatabaseManager.inMemory()
        let repository = TrackTagRepository(database: db)
        let commits = Commits()
        let failures = Failures()
        let loads = Loads()
        let model = InspectorModel(dependencies: .init(
            loadTracks: { ids in
                if loads.fail { throw DatabaseError(resultCode: .SQLITE_BUSY) }
                return try await repository.fetchTracks(ids: ids)
            },
            commit: { value, field, ids, _ in
                if let error = commits.failNext {
                    commits.failNext = nil
                    throw error
                }
                commits.calls.append((value, field, ids))
                _ = try await repository.apply(value, to: field, trackIDs: ids, queueFileWrites: false)
            },
            reportFailure: { failures.messages.append($0) }
        ))
        return Env(db: db, repository: repository, model: model, commits: commits, failures: failures, loads: loads)
    }

    private func select(_ env: Env, _ ids: [Int64]) async {
        env.model.select(ids)
        await env.model.waitUntilIdle()
    }

    private func type(_ env: Env, _ text: String, _ field: TrackTagField) {
        env.model.setText(text, for: field, generation: env.model.generation)
    }

    // MARK: States

    @Test func noneOneAndManyWithMixed() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 3)
        #expect(env.model.isEmpty)
        await select(env, [ids[0]])
        #expect(!env.model.isEmpty && !env.model.isMultiple)
        #expect(env.model.editableFields.first == .title)
        #expect(env.model.text(for: .title) == "Title 0")
        await select(env, ids)
        #expect(env.model.isMultiple)
        #expect(!env.model.editableFields.contains(.title), "Title is left out for several tracks")
        #expect(env.model.isMixed(.artist))
        #expect(env.model.text(for: .artist) == "")
        #expect(env.model.placeholder(for: .artist) == "Mixed")
        _ = try await env.repository.apply(.text("Same"), to: .genre, trackIDs: ids, queueFileWrites: false)
        env.model.reload()
        await env.model.waitUntilIdle()
        #expect(!env.model.isMixed(.genre))
        #expect(env.model.text(for: .genre) == "Same")
        await select(env, [])
        #expect(env.model.isEmpty)
    }

    @Test func loadsFromTheDatabaseByIDInSelectionOrder() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 3)
        await select(env, [ids[2], ids[0]])
        #expect(env.model.tracks.map(\.id) == [ids[2], ids[0]])
        // Changed elsewhere: a reload shows the stored value, never a stale copy.
        _ = try await env.repository.apply(.text("Elsewhere"), to: .title, trackIDs: [ids[2]], queueFileWrites: false)
        env.model.reload()
        await env.model.waitUntilIdle()
        #expect(env.model.tracks.first?.title == "Elsewhere")
    }

    // MARK: PP-INSPECTOR-04

    /// A title typed for track A, then the selection moves to B before Return: the text goes
    /// to A (the track it was typed for) and B is untouched — also when the field's late
    /// write and its focus-loss commit arrive after the selection changed.
    @Test func anOpenEditIsNeverSavedIntoTheNextSelection() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        let (a, b) = (ids[0], ids[1])
        await select(env, [a])
        let fieldGeneration = env.model.generation
        type(env, "Typed for A", .title)

        env.model.select([b]) // the user clicked the next row (or the queue advanced — Info never follows it)
        // The text field of A, being torn down, writes once more and loses focus.
        env.model.setText("Typed for A!", for: .title, generation: fieldGeneration)
        env.model.commit(.title)
        await env.model.waitUntilIdle()

        let tracks = try await env.repository.fetchTracks(ids: [a, b])
        #expect(tracks[0].title == "Typed for A", "committed to the track it was typed for")
        #expect(tracks[1].title == "Title 1", "the next track is untouched")
        #expect(env.commits.calls.map(\.ids) == [[a]])
        #expect(env.model.drafts.isEmpty)
        #expect(env.model.text(for: .title) == "Title 1")
    }

    @Test func aDraftForManyGoesToExactlyThoseTracks() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 4)
        await select(env, [ids[0], ids[1], ids[2]])
        type(env, "Dub", .genre)
        env.model.select([ids[3]])
        await env.model.waitUntilIdle()
        #expect(env.commits.calls.map(\.ids) == [[ids[0], ids[1], ids[2]]])
        #expect(try await env.repository.fetchTracks(ids: [ids[3]]).first?.genre != "Dub")
    }

    @Test func anInvalidDraftIsDroppedOnSelectionChange() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        await select(env, [ids[0]])
        type(env, "nineteen", .year)
        env.model.select([ids[1]])
        await env.model.waitUntilIdle()
        #expect(env.commits.calls.isEmpty)
        #expect(env.model.issues.isEmpty)
        #expect(env.failures.messages == ["Year wasn’t changed — year is a number, like 2019"], "said once in the status bar")
    }

    // MARK: Review S4

    @Test func aFailedLoadNeverLeavesTheOldSelectionToTypeInto() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        await select(env, [ids[0]])
        env.loads.fail = true
        await select(env, [ids[1]])
        #expect(env.model.tracks.isEmpty, "the previous selection's tracks are gone")
        #expect(env.model.loadError == "Couldn’t read the selected tracks — the library database is busy.")
        #expect(!env.model.canEdit && !env.model.isEmpty)
        type(env, "Into B?", .genre)
        #expect(env.model.drafts.isEmpty)
        #expect(await env.model.commitNow(.genre) == .nothingToCommit)
        env.loads.fail = false
        env.model.reload()
        await env.model.waitUntilIdle()
        #expect(env.model.canEdit && env.model.tracks.map(\.id) == [ids[1]])
    }

    @Test func aDraftCapturesOnlySelectedIdsThatWereLoaded() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        await select(env, [ids[0], 999_999, ids[1]]) // one id no longer exists
        type(env, "Dub", .genre)
        #expect(env.model.drafts[.genre]?.trackIDs == [ids[0], ids[1]])
    }

    @Test func anotherLibraryResetsInfo() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        await select(env, ids)
        type(env, "Dub", .genre)
        env.model.reset()
        #expect(env.model.isEmpty && env.model.drafts.isEmpty && env.model.tracks.isEmpty)
        let request = InfoTrackRequest()
        request.show([1], over: [])
        request.clear()
        #expect(request.trackIDs == nil)
    }

    // MARK: Commit, revert, errors

    @Test func returnCommitsAndReloads() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        await select(env, ids)
        type(env, "Techno", .genre)
        #expect(await env.model.commitNow(.genre) == .saved)
        await env.model.waitUntilIdle()
        #expect(env.model.drafts.isEmpty)
        #expect(env.model.text(for: .genre) == "Techno")
        #expect(env.commits.calls.count == 1)
    }

    @Test func untouchedOrUnchangedFieldsCommitNothing() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 3)
        await select(env, ids)
        #expect(await env.model.commitNow(.artist) == .nothingToCommit, "focus in and out of a Mixed field")
        type(env, "x", .artist)
        type(env, "", .artist)
        #expect(await env.model.commitNow(.artist) == .unchanged, "typing back to Mixed changes nothing for all")
        #expect(env.commits.calls.isEmpty)
    }

    @Test func escRevertsTheField() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        await select(env, ids)
        type(env, "Oops", .title)
        #expect(env.model.text(for: .title) == "Oops")
        env.model.revert(.title)
        #expect(env.model.text(for: .title) == "Title 0")
        #expect(await env.model.commitNow(.title) == .nothingToCommit)
    }

    @Test func anInvalidValueKeepsTheFieldOpenWithTheReason() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        await select(env, ids)
        type(env, "", .title)
        #expect(await env.model.commitNow(.title) == .invalid)
        #expect(env.model.issues[.title] == .init(kind: .invalid, message: "A track needs a title. Press Esc to restore the old one."))
        #expect(env.model.text(for: .title) == "", "the typed text stays")
        type(env, "Fixed", .title)
        #expect(env.model.issues[.title] == nil, "typing clears the reason")
        #expect(await env.model.commitNow(.title) == .saved)
    }

    @Test func aSaveFailureShowsUnderTheFieldWithTryAgain() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        await select(env, ids)
        type(env, "Techno", .genre)
        env.commits.failNext = DatabaseError(resultCode: .SQLITE_BUSY)
        #expect(await env.model.commitNow(.genre) == .failed)
        #expect(env.model.issues[.genre] == .init(kind: .saveFailed, message: "Couldn’t save this change — the library database is busy."))
        #expect(env.model.text(for: .genre) == "Techno", "the typed text stays")
        env.model.retry(.genre)
        await env.model.waitUntilIdle()
        #expect(env.model.issues[.genre] == nil)
        #expect(try await env.repository.fetchTracks(ids: ids).first?.genre == "Techno")
    }

    @Test func aFailureAfterTheSelectionMovedOnGoesToTheStatusBar() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        await select(env, [ids[0]])
        type(env, "Techno", .genre)
        env.commits.failNext = DatabaseError(resultCode: .SQLITE_BUSY)
        env.model.select([ids[1]])
        await env.model.waitUntilIdle()
        #expect(env.failures.messages == ["Couldn’t save the genre of “Title 0” — the library database is busy"])
        #expect(env.model.issues.isEmpty)
    }

    @Test func textFromAnEarlierSelectionIsIgnored() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        await select(env, [ids[0]])
        let old = env.model.generation
        await select(env, [ids[1]])
        env.model.setText("Stale", for: .genre, generation: old)
        #expect(env.model.drafts.isEmpty)
    }

    @Test func noTypingWhileANewSelectionLoads() async throws {
        let env = try makeEnv()
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        await select(env, [ids[0]])
        env.model.select([ids[1]])
        // Still showing A's values while B loads: typing can't attach A's text to B.
        env.model.setText("x", for: .genre, generation: env.model.generation)
        #expect(env.model.drafts.isEmpty)
        await env.model.waitUntilIdle()
    }

    // MARK: Show Details of an unselected track

    @Test func aDetailsRequestLastsUntilTheSelectionChanges() {
        let request = InfoTrackRequest()
        #expect(request.effectiveSelection([1, 2]) == [1, 2])
        request.show([9], over: [1, 2])
        #expect(request.effectiveSelection([1, 2]) == [9])
        #expect(request.effectiveSelection([3]) == [3], "a new selection wins at once")
        request.selectionDidChange([3])
        #expect(request.trackIDs == nil)
        #expect(request.effectiveSelection([1, 2]) == [1, 2])
    }
}
