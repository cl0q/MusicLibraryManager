import Foundation
import GRDB
import Testing
@testable import MLM

/// `ReviewModel` over temporary databases, an undo center and a fake Trash (W3-REV).
@Suite("ReviewModelTests", .serialized)
@MainActor
struct ReviewModelTests {
    private let flacMp3: [(format: String, bitrate: Int)] = [("flac", 1411), ("mp3", 320)]

    private func undoStep(_ env: ReviewEnv) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    private func hiddenCount(_ env: ReviewEnv) async throws -> Int {
        try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE is_duplicate = 1") ?? 0 }
    }

    // MARK: Tabs and counts

    @Test func tabsCountGroupsAndAlbumsNeverShows() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "So U Kno", versions: flacMp3)
        try await env.addGroup(title: "Arpo", versions: flacMp3)
        try await env.addGroup(title: "Tangerine", versions: flacMp3, conflict: true, albums: ["A", "B"])
        try await env.addGroup(title: "Old", versions: flacMp3, status: "resolved")
        await env.model.reload()
        #expect(env.model.count(for: .duplicates) == 2)
        #expect(env.model.count(for: .conflicts) == 1)
        #expect(env.model.count(for: .resolved) == 1)
        #expect(env.model.waitingCount == 3, "the sidebar badge adds groups and conflicts")
        #expect(env.model.count(for: .albums) == nil)
        let items = ReviewTab.allCases.map {
            ScopeBarItem(id: $0, title: $0.title, count: env.model.count(for: $0), hidesWhenEmpty: $0 == .albums)
        }
        #expect(ScopeBarRules.visibleItems(items, selection: .duplicates).map(\.id) == [.duplicates, .conflicts, .resolved])
    }

    @Test func countIsNilBeforeTheFirstLoad() throws {
        let env = try ReviewEnv.make()
        #expect(env.model.count(for: .duplicates) == nil)
        #expect(!env.model.isNothingToReview)
    }

    @Test func emptyQueueIsNothingToReviewAndTheLastScanDistinguishesNeverScanned() async throws {
        let env = try ReviewEnv.make()
        await env.model.reload()
        #expect(env.model.isNothingToReview)
        await env.runner.loadLastScan()
        #expect(env.model.lastScan == nil, "never scanned")
        await ReviewLastScan(date: Date(timeIntervalSince1970: 1_790_000_000), comparisons: 9, duplicateGroups: 1, conflicts: 2)
            .save(to: env.config)
        await env.runner.loadLastScan()
        #expect(env.model.lastScan?.comparisons == 9)
        #expect(env.model.lastScan?.sentence.contains("9 comparisons · 1 duplicate group · 2 conflicts") == true)
    }

    // MARK: Filter

    @Test func theFilterMatchesTitleAndArtistOfTheGroup() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "So U Kno", artist: "Overmono", versions: flacMp3)
        try await env.addGroup(title: "Arpo", artist: "Floating Points", versions: flacMp3)
        await env.model.reload()
        env.model.filter = SearchFilter(text: "arpo")
        #expect(env.model.visibleDuplicates.map(\.title) == ["Arpo"])
        env.model.filter = SearchFilter(text: "overmono")
        #expect(env.model.visibleDuplicates.map(\.title) == ["So U Kno"])
        #expect(env.model.duplicateCount == 2, "the count is of everything waiting")
    }

    // MARK: Deciding as one undo step

    @Test func keepRecommendedIsOneStepWithItsConfirmationAndUndoRestoresIt() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        let applied = await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version",
                                            undo: env.undo)
        #expect(applied)
        #expect(env.undo.stepCount == 1)
        #expect(env.manager.undoActionName == "Keep Recommended Version")
        #expect(env.status.message?.text == "Kept the FLAC version of “So U Kno” · 1 version hidden from lists")
        #expect(env.status.message?.actions.map(\.title) == ["Undo"])
        #expect(try await hiddenCount(env) == 1)
        #expect(env.model.duplicateCount == 0)
        #expect(env.model.resolvedCount == 1)
        await undoStep(env)
        #expect(try await hiddenCount(env) == 0)
        #expect(env.model.duplicateCount == 1, "the group is pending again")
        #expect(try await env.decisions.decidedPairs().isEmpty)
        #expect(group.ids.count == 2)
    }

    @Test func bulkApplyRespectsTheFilterAndIsOneUndoStep() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "Alpha", versions: flacMp3)
        try await env.addGroup(title: "Alpine", versions: flacMp3)
        try await env.addGroup(title: "Zebra", versions: flacMp3)
        await env.model.reload()
        env.model.filter = SearchFilter(text: "alp")
        let plans = env.model.visibleDuplicates.map { env.model.plan(keepRecommendedIn: $0) }
        #expect(plans.count == 2)
        await env.model.apply(plans, actionName: "Keep Recommended Versions", undo: env.undo)
        #expect(env.undo.stepCount == 1, "one step for the whole bulk decision")
        #expect(env.status.message?.text == "Kept the recommended version in 2 groups · 2 versions hidden from lists · 0 playlist entries re-pointed")
        #expect(env.model.duplicates.map(\.title) == ["Zebra"], "the group outside the filter stays")
        #expect(try await hiddenCount(env) == 2)
        await undoStep(env)
        #expect(try await hiddenCount(env) == 0)
        #expect(env.model.duplicateCount == 3)
    }

    @Test func keepSelectedKeepsThePickedVersion() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        #expect(!env.model.canKeepSelected(item), "pick = recommended")
        env.model.setPick(group.ids[1], in: item)
        #expect(env.model.canKeepSelected(item))
        await env.model.apply([env.model.plan(keepSelectedIn: item)], actionName: "Keep Selected Version", undo: env.undo)
        let flags = try await env.db.read { db in try Int.fetchAll(db, sql: "SELECT is_duplicate FROM tracks ORDER BY id") }
        #expect(flags == [1, 0])
        #expect(env.status.message?.text.hasPrefix("Kept the MP3 version of “So U Kno”") == true)
    }

    @Test func keepAllDecidesPairsAndNeverProposesAgain() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keepAllIn: item)], actionName: "Keep All Versions", undo: env.undo)
        #expect(env.status.message?.text == "Kept all 2 versions of “So U Kno” — not duplicates")
        #expect(try await env.decisions.decidedPairs() == [ReviewPair(group.ids[0], group.ids[1])])
        let proposed = try await AnalysisRepository(database: env.db).replacePendingScanReviewItems([
            ReviewItem(id: nil, actionType: "fingerprint_dedup", groupKey: group.key, trackId: group.ids[0], relatedTrackId: group.ids[1],
                       details: "{}", autoAction: nil, status: "pending", createdAt: nil, resolvedAt: nil),
        ])
        #expect(proposed.duplicates == 0)
    }

    // MARK: Session choice and Trash

    @Test func theSessionChoiceStartsHiddenAndResetsWithANewModel() throws {
        let first = try ReviewEnv.make()
        #expect(first.model.unkeptMode == .hidden)
        first.model.setUnkeptMode(.trash)
        #expect(first.model.unkeptMode == .trash)
        let second = try ReviewEnv.make()
        #expect(second.model.unkeptMode == .hidden, "resets at launch: kept in the model, never stored")
    }

    @Test func trashIsRefusedWhileTheDriveIsAway() throws {
        let env = try ReviewEnv.make()
        env.model.drive = LibraryDriveState(volumeName: "Lexxar", isConnected: false)
        #expect(env.model.trashRefusal == "“Lexxar” is not connected")
        env.model.setUnkeptMode(.trash)
        #expect(env.model.unkeptMode == .hidden)
        #expect(env.model.effectiveMode == .hidden)
        // The drive goes away while Trash is chosen: the mode falls back to hidden.
        env.model.drive = LibraryDriveState(volumeName: "Lexxar", isConnected: true)
        env.model.setUnkeptMode(.trash)
        #expect(env.model.unkeptMode == .trash)
        env.model.drive = LibraryDriveState(volumeName: "Lexxar", isConnected: false)
        #expect(env.model.unkeptMode == .hidden)
    }

    @Test func trashModeMovesTheFilesAfterTheCommitAndUndoPutsThemBack() async throws {
        let env = try ReviewEnv.make(existingFiles: ["/lib/Overmono/So U Kno-0.flac", "/lib/Overmono/So U Kno-1.mp3"])
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        env.model.setUnkeptMode(.trash)
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version", undo: env.undo)
        #expect(env.files.trashed == ["/lib/Overmono/So U Kno-1.mp3"], "only the unkept version's file")
        #expect(env.files.fileExists(atPath: "/lib/Overmono/So U Kno-0.flac"))
        #expect(env.status.message?.text == "Kept the FLAC version of “So U Kno” · 1 version moved to the Trash")
        let record = try #require(try await env.decisions.decisions()[group.key])
        #expect(record.unkeptMode == .trash)
        #expect(record.consequences.trashed.map(\.trackId) == [group.ids[1]])
        #expect(env.changes.files == 1, "a file check follows")
        await undoStep(env)
        #expect(env.files.fileExists(atPath: "/lib/Overmono/So U Kno-1.mp3"), "moved back from its Trash URL")
        #expect(try await hiddenCount(env) == 0)
    }

    @Test func aFailedMoveIsCountedAndTheDatabaseStaysDecided() async throws {
        let env = try ReviewEnv.make(existingFiles: ["/lib/Overmono/So U Kno-0.flac", "/lib/Overmono/So U Kno-1.mp3"])
        env.files.failing = ["/lib/Overmono/So U Kno-1.mp3"]
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        env.model.setUnkeptMode(.trash)
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version", undo: env.undo)
        #expect(env.status.message?.text.hasSuffix("Couldn’t move 1 file to the Trash") == true)
        #expect(env.status.message?.actions.map(\.title) == ["Undo", "Show Logs"])
        #expect(try await hiddenCount(env) == 1, "decided all the same")
        #expect(try await env.decisions.decisions()[group.key]?.consequences.trashFailures == 1)
    }

    @Test func undoReportsFilesThatLeftTheTrash() async throws {
        let env = try ReviewEnv.make(existingFiles: ["/lib/Overmono/So U Kno-0.flac", "/lib/Overmono/So U Kno-1.mp3"])
        try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        env.model.setUnkeptMode(.trash)
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version", undo: env.undo)
        env.files.removeFromTrash("So U Kno-1.mp3")
        await undoStep(env)
        #expect(env.status.message?.text == "Can’t undo the Trash move — 1 file is no longer in the Trash")
        #expect(try await hiddenCount(env) == 0, "the database is restored")
        #expect(!env.files.fileExists(atPath: "/lib/Overmono/So U Kno-1.mp3"))
    }

    // MARK: Conflicts

    @Test func conflictGridCoversEveryVersionAndMergeWritesToAllOfThem() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "Tangerine", versions: [("flac", 1411), ("m4a", 256), ("mp3", 320)],
                                           conflict: true, albums: ["Tangerine", "Tangerine (Deluxe)", ""])
        await env.model.reload()
        let item = try #require(env.model.conflicts.first)
        #expect(item.members.count == 3, "all versions, not the first two")
        #expect(env.model.differingFields(item) == [.album])
        env.model.useAll(from: group.ids[1], in: item)
        #expect(env.model.mergedValues(item).map(\.text) == ["Tangerine (Deluxe)"])
        await env.model.apply([env.model.plan(mergeIn: item)], actionName: "Merge Tags", undo: env.undo)
        let albums = try await env.db.read { db in try String.fetchAll(db, sql: "SELECT album FROM tracks ORDER BY id") }
        #expect(albums == ["Tangerine (Deluxe)", "Tangerine (Deluxe)", "Tangerine (Deluxe)"])
        #expect(env.status.message?.text == "Merged tags of “Tangerine” · 2 files updated")
        #expect(try await env.decisions.decidedPairs().count == 3)
        await undoStep(env)
        let restored = try await env.db.read { db in try String.fetchAll(db, sql: "SELECT album FROM tracks ORDER BY id") }
        #expect(restored == ["Tangerine", "Tangerine (Deluxe)", ""])
        #expect(env.model.conflictCount == 1)
    }

    @Test func differentVersionsKeepBothChangesNoTags() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "Tangerine", versions: flacMp3, conflict: true, albums: ["A", "B"])
        await env.model.reload()
        let item = try #require(env.model.conflicts.first)
        await env.model.apply([env.model.plan(keepAllIn: item)], actionName: "Keep Different Versions", undo: env.undo)
        #expect(env.status.message?.text == "Kept “Tangerine” as different versions")
        let albums = try await env.db.read { db in try String.fetchAll(db, sql: "SELECT album FROM tracks ORDER BY id") }
        #expect(albums == ["A", "B"])
    }

    // MARK: Playlists

    @Test func playlistEntriesAreRepointedAndCountedInTheConfirmation() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "So U Kno", versions: flacMp3)
        let playlist = try ReviewDecisionRepositoryTests.addPlaylist(env.db, name: "Warm-up", tracks: [group.ids[1]])
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        #expect(item.usedIn[group.ids[1]] == 1)
        await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version", undo: env.undo)
        #expect(env.status.message?.text == "Kept the FLAC version of “So U Kno” · 1 version hidden from lists · 1 playlist entry re-pointed")
        #expect(env.changes.playlists == 1)
        let tracks = try await env.db.read { db in
            try Int64.fetchAll(db, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlist])
        }
        #expect(tracks == [group.ids[0]])
    }

    // MARK: Resolved and Restore

    @Test func restoreIsDisabledWithoutADecisionAndWorksWithOne() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "Old", versions: flacMp3, status: "resolved")
        try await env.addGroup(title: "So U Kno", versions: flacMp3)
        await env.model.reload()
        let legacy = try #require(env.model.resolved.first)
        #expect(!legacy.canRestore)
        #expect(legacy.outcome == "Decided in an earlier version of MLM")
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keepRecommendedIn: item)], actionName: "Keep Recommended Version", undo: env.undo)
        let row = try #require(env.model.resolved.first { $0.title == "So U Kno" })
        #expect(row.canRestore)
        #expect(row.outcome == "FLAC kept · 1 version hidden from lists")
        let restored = await env.model.restore(row, statusBar: env.status)
        #expect(restored)
        #expect(env.status.message?.text == "Restored “So U Kno” — it is back in its tab")
        #expect(env.model.duplicateCount == 1)
        #expect(try await hiddenCount(env) == 0)
    }
}
