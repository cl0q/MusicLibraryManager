import Foundation
import GRDB
import Testing
@testable import MLM

/// F6: the smaller fixes (W3-REV fixes).
@Suite("ReviewDetailFixTests", .serialized)
@MainActor
struct ReviewDetailFixTests {
    private typealias Repo = ReviewDecisionRepositoryTests

    @Test func foldersShowTheStandardColumnsNeverContextColumns() {
        #expect(FolderOutlineTable.columns == TrackColumnID.standardColumns)
        #expect(!FolderOutlineTable.columns.contains(.number))
        #expect(!FolderOutlineTable.columns.contains(.version))
        #expect(!FolderOutlineTable.columns.contains(.match))
    }

    @Test func aLikesRefreshKeepsTheKeptVersionAndNeverResurrectsAHiddenOne() async throws {
        let f = try Repo.makeFixture(members: 3)
        let playlist = try Repo.addPlaylist(f.queue, name: "Likes", tracks: [])
        try await f.decisions.decide(Repo.request(f))
        let repository = PlaylistRepository(database: f.queue)
        // Upstream still lists the hidden versions (and the kept one again).
        try await repository.replaceTrackList(playlistId: playlist, trackIds: [f.ids[1], f.ids[2], f.ids[0]])
        let stored = try await f.queue.read {
            try Int64.fetchAll($0, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", arguments: [playlist])
        }
        #expect(stored == [f.ids[0]], "mapped to the kept version, once")
    }

    @Test func aTrackWithAnOldDuplicateFlagIsStillAddedToLikes() async throws {
        let f = try Repo.makeFixture(members: 2)
        let playlist = try Repo.addPlaylist(f.queue, name: "Likes", tracks: [])
        try await f.queue.write { db in try db.execute(sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?", arguments: [f.ids[0], f.ids[1]]) }
        try await PlaylistRepository(database: f.queue).replaceTrackList(playlistId: playlist, trackIds: [f.ids[1]])
        let stored = try await f.queue.read { try Int64.fetchAll($0, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlist]) }
        #expect(stored == [f.ids[1]], "only a Review decision maps")
    }

    @Test func restoringADecisionThatANewerOneCoversIsRefused() async throws {
        let env = try ReviewEnv.make()
        let first = try await env.addGroup(title: "So U Kno", versions: [("flac", 1411), ("mp3", 320)])
        await env.model.reload()
        let item = try #require(env.model.duplicates.first)
        await env.model.apply([env.model.plan(keepAllIn: item)], actionName: "Keep All Versions", undo: env.undo)
        // A newer decision over the same versions (a bigger group that contains them).
        let record = try #require(try await env.decisions.decisions()[first.key])
        try await env.db.write { db in
            try db.execute(sql: """
                INSERT INTO review_decisions (group_key, kind, decision, consequences_json, decided_at)
                VALUES ('duplicate:newer', 'duplicate', 'keep_all', ?, '2026-10-05T10:00:00Z')
                """, arguments: [String(decoding: try JSONEncoder().encode(record.consequences), as: UTF8.self)])
        }
        await env.model.reload()
        let row = try #require(env.model.resolved.first { $0.key == first.key })
        let restored = await env.model.restore(row, statusBar: env.status)
        #expect(!restored)
        #expect(env.status.message?.text == "Can’t restore — a newer decision covers these versions")
        #expect(try await env.decisions.decisions()[first.key] != nil, "the decision stays")
    }

    @Test func anUnreadableDecisionRecordIsKeptAndUndoRefuses() async throws {
        let f = try Repo.makeFixture(members: 2)
        let outcome = try await f.decisions.decide(Repo.request(f))
        try await f.queue.write { db in
            try db.execute(sql: "UPDATE review_decisions SET consequences_json = 'not json' WHERE id = ?", arguments: [outcome.decisionID])
        }
        await #expect(throws: ReviewDecisionError.unreadableRecord) {
            try await f.decisions.undo(decisionID: outcome.decisionID)
        }
        #expect(ReviewDecisionError.unreadableRecord.localizedDescription == "Can’t undo — the decision record is unreadable")
        let rows = try await f.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_decisions") }
        #expect(rows == 1, "the row isn't deleted")
        let hidden = try await f.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1") }
        #expect(hidden == 1, "nothing was put back either")
    }

    @Test func aCancelledScanSaysWhatIsKept() async throws {
        let gate = ReviewScanRunnerTests.Gate()
        let env = try ReviewEnv.make()
        let runner = ReviewScanRunner(center: env.center, config: { env.config }, scan: {
            { progress in
                progress(1, 10)
                await gate.wait()
                try Task.checkCancellation()
                return .init(pairsCompared: 1, duplicatesFound: 0, conflictsFlagged: 0)
            }
        }, didChange: {})
        runner.statusBar = env.status
        #expect(runner.start())
        runner.cancel()
        gate.release()
        await runner.waitUntilIdle()
        #expect(env.status.message?.text == "Scan cancelled. Your decisions and the groups found so far are kept.")
    }

    @Test func suggestionCountsLeaveHiddenVersionsOut() async throws {
        let f = try Repo.makeFixture(members: 3)
        try await f.decisions.decide(Repo.request(f))
        let queries = TrackSearchQueries(database: f.queue)
        let artists = try await queries.valueSuggestions(kind: .artist, partial: "Over")
        #expect(artists.first?.count == 1, "only the kept version is counted")
        let counts = try await queries.availabilityCounts()
        #expect(counts.values.max() == 1, "one listed track, not three")
    }
}
