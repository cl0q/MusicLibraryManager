import Foundation
import GRDB
import Testing
@testable import MLM

/// F4: Undo survives re-added rows and deleted members (W3-REV fixes).
@Suite("ReviewUndoRobustnessTests")
struct ReviewUndoRobustnessTests {
    private typealias Repo = ReviewDecisionRepositoryTests

    private func playlistTracks(_ queue: DatabaseQueue, _ playlist: Int64) throws -> [Int64] {
        try queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", arguments: [playlist])
        }
    }

    @Test func undoDoesNotDuplicateAnOldVersionTheUserAddedAgain() async throws {
        let f = try Repo.makeFixture(members: 2)
        let playlist = try Repo.addPlaylist(f.queue, name: "Warm-up", tracks: [f.ids[1]])
        let outcome = try await f.decisions.decide(Repo.request(f))
        #expect(try playlistTracks(f.queue, playlist) == [f.ids[0]])
        try await f.queue.write { db in
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES (?, ?, 'b', '2026-10-02')",
                           arguments: [playlist, f.ids[1]])
        }
        try await f.decisions.undo(decisionID: outcome.decisionID)
        let tracks = try playlistTracks(f.queue, playlist)
        #expect(tracks == [f.ids[1]], "one entry of the old version, the re-pointed one is dropped")
    }

    @Test func undoDoesNotDuplicateASyncRowEither() async throws {
        let f = try Repo.makeFixture(members: 2)
        try await f.queue.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder) VALUES ('iPod', '/tmp/x')")
            try db.execute(sql: "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (1, ?)", arguments: [f.ids[1]])
        }
        let outcome = try await f.decisions.decide(Repo.request(f))
        try await f.queue.write { db in
            try db.execute(sql: "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (1, ?)", arguments: [f.ids[1]])
        }
        try await f.decisions.undo(decisionID: outcome.decisionID)
        let rows = try await f.queue.read { try Int64.fetchAll($0, sql: "SELECT track_id FROM sync_profile_tracks WHERE profile_id = 1") }
        #expect(rows == [f.ids[1]])
    }

    @Test func undoSkipsRowsOfADeletedVersionOrPlaylist() async throws {
        let f = try Repo.makeFixture(members: 3)
        let both = try Repo.addPlaylist(f.queue, name: "Both", tracks: [f.ids[0], f.ids[1]])
        let gone = try Repo.addPlaylist(f.queue, name: "Gone", tracks: [f.ids[0], f.ids[2]])
        let outcome = try await f.decisions.decide(Repo.request(f))
        #expect(outcome.consequences.playlistRows.filter { $0.change == .deleted }.count == 2)
        try await TrackRepository(database: f.queue).delete(ids: [f.ids[1]])
        try await f.queue.write { db in
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [gone])
            try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [gone])
        }
        try await f.decisions.undo(decisionID: outcome.decisionID)
        #expect(try playlistTracks(f.queue, both) == [f.ids[0]], "no row for the deleted version")
        let orphans = try await f.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?", arguments: [gone])
        }
        #expect(orphans == 0, "nothing re-inserted into a deleted playlist")
    }

    @Test func deletingTheKeptVersionBringsTheOthersBack() async throws {
        let f = try Repo.makeFixture(members: 3)
        try await f.decisions.decide(Repo.request(f))
        let hiddenBefore = try await f.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1") }
        #expect(hiddenBefore == 2)
        try await TrackRepository(database: f.queue).delete(id: f.ids[0])
        let rows = try await f.queue.read { try Row.fetchAll($0, sql: "SELECT hidden_by_review, is_duplicate, variant_of FROM tracks") }
        #expect(rows.count == 2)
        for row in rows {
            #expect((row["hidden_by_review"] as Int) == 0)
            #expect((row["is_duplicate"] as Int) == 0)
            #expect((row["variant_of"] as Int64?) == nil)
        }
        let listed = try await TrackRepository(database: f.queue).fetchTracks(scope: .all)
        #expect(listed.count == 2, "the song stays findable")
    }

    @Test func decideRefusesAKeptVersionThatNoLongerExists() async throws {
        let f = try Repo.makeFixture(members: 2)
        try await f.queue.write { db in try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [f.ids[0]]) }
        await #expect(throws: ReviewDecisionError.invalidKeep) {
            try await f.decisions.decide(Repo.request(f))
        }
        let hidden = try await f.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1") }
        #expect(hidden == 0)
    }
}
