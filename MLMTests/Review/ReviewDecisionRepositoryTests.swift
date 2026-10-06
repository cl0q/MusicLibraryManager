import Foundation
import GRDB
import Testing
@testable import MLM

/// Sticky Review decisions on temporary databases (W3-REV, IMP-051).
@Suite("ReviewDecisionRepositoryTests")
struct ReviewDecisionRepositoryTests {
    struct Fixture {
        let queue: DatabaseQueue
        let decisions: ReviewDecisionRepository
        let analysis: AnalysisRepository
        let ids: [Int64]
        let groupKey: String
    }

    static func makeFixture(members: Int = 3, pending: Bool = true) throws -> Fixture {
        let queue = try DatabaseManager.inMemory()
        var ids: [Int64] = []
        try queue.write { db in
            for index in 0..<members {
                var track = Track(artist: "Overmono", album: "Good Lies", title: "So U Kno",
                                  format: index == 0 ? "flac" : "mp3", originalPath: "/v\(index).x")
                track.bitrate = index == 0 ? 1411 : 320
                try track.insert(db)
                ids.append(track.id!)
            }
        }
        let key = DuplicateReviewGrouping.groupKey(for: ids)
        if pending {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                    VALUES ('fingerprint_dedup', ?, ?, ?, '{}', 'pending')
                    """, arguments: [key, ids[0], ids[1]])
            }
        }
        return Fixture(queue: queue, decisions: ReviewDecisionRepository(database: queue),
                       analysis: AnalysisRepository(database: queue), ids: ids, groupKey: key)
    }

    static func request(_ f: Fixture, action: ReviewDecisionAction = .keepRecommended, kept: Int? = 0,
                        mode: UnkeptMode = .hidden) -> ReviewDecisionRequest {
        ReviewDecisionRequest(groupKey: f.groupKey, kind: .duplicate, action: action, memberIDs: f.ids,
                              keptTrackID: kept.map { f.ids[$0] }, unkeptMode: mode)
    }

    static func addPlaylist(_ queue: DatabaseQueue, name: String, tracks: [Int64]) throws -> Int64 {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES (?, 'user')", arguments: [name])
            let id = db.lastInsertedRowID
            for (index, track) in tracks.enumerated() {
                try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES (?, ?, ?, '2026-10-01')",
                               arguments: [id, track, "a\(index)"])
            }
            return id
        }
    }

    private func playlistTracks(_ queue: DatabaseQueue, _ playlist: Int64) throws -> [Int64] {
        try queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", arguments: [playlist])
        }
    }

    @Test func keepRecommendedHidesTheOthersAndRepointsPlaylists() async throws {
        let f = try Self.makeFixture()
        let warm = try Self.addPlaylist(f.queue, name: "Warm-up", tracks: [f.ids[1]])
        let outcome = try await f.decisions.decide(Self.request(f))
        #expect(outcome.unkeptTrackIDs == [f.ids[1], f.ids[2]])
        #expect(outcome.hiddenCount == 2)
        #expect(outcome.keptFormat == "flac")
        #expect(try playlistTracks(f.queue, warm) == [f.ids[0]], "the entry now points at the kept version")
        let flags: [(Int, Int64?)] = try await f.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, is_duplicate, variant_of FROM tracks ORDER BY id")
                .map { ($0["is_duplicate"] as Int, $0["variant_of"] as Int64?) }
        }
        #expect(flags.map(\.0) == [0, 1, 1])
        #expect(flags.map(\.1) == [nil, f.ids[0], f.ids[0]])
        let status = try await f.queue.read { db in try String.fetchOne(db, sql: "SELECT status FROM review_queue") }
        #expect(status == "resolved")
        #expect(try await f.decisions.isDecided(group: f.ids))
    }

    @Test func keptAlreadyInThePlaylistDropsTheUnkeptEntryAndCountsIt() async throws {
        let f = try Self.makeFixture(members: 2)
        let both = try Self.addPlaylist(f.queue, name: "Both", tracks: [f.ids[0], f.ids[1]])
        let only = try Self.addPlaylist(f.queue, name: "Only", tracks: [f.ids[1]])
        let outcome = try await f.decisions.decide(Self.request(f))
        #expect(outcome.consequences.repointedPlaylistEntries == 2)
        #expect(try playlistTracks(f.queue, both) == [f.ids[0]], "no duplicate entry of the kept version")
        #expect(try playlistTracks(f.queue, only) == [f.ids[0]])
        let changes = outcome.consequences.playlistRows.map(\.change)
        #expect(changes.contains(.deleted) && changes.contains(.repointed))
    }

    @Test func syncProfileRowsAreRepointedLikewise() async throws {
        let f = try Self.makeFixture(members: 2)
        try await f.queue.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder) VALUES ('iPod', '/tmp/x'), ('Car', '/tmp/y')")
            try db.execute(sql: "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (1, ?), (2, ?), (2, ?)",
                           arguments: [f.ids[1], f.ids[0], f.ids[1]])
        }
        let outcome = try await f.decisions.decide(Self.request(f))
        #expect(outcome.consequences.repointedSyncRows == 2)
        let rows: [[Int64]] = try await f.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT profile_id, track_id FROM sync_profile_tracks ORDER BY profile_id, track_id")
                .map { [$0["profile_id"] as Int64, $0["track_id"] as Int64] }
        }
        #expect(rows == [[1, f.ids[0]], [2, f.ids[0]]])
    }

    @Test func undoRestoresEveryExactRowAndFlag() async throws {
        let f = try Self.makeFixture()
        let a = try Self.addPlaylist(f.queue, name: "A", tracks: [f.ids[0], f.ids[1]])
        let b = try Self.addPlaylist(f.queue, name: "B", tracks: [f.ids[2]])
        try await f.queue.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder) VALUES ('iPod', '/tmp/x')")
            try db.execute(sql: "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (1, ?), (1, ?)", arguments: [f.ids[0], f.ids[1]])
        }
        let before = try await f.queue.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM playlist_tracks ORDER BY id").map(\.description),
             try Row.fetchAll(db, sql: "SELECT * FROM sync_profile_tracks ORDER BY track_id").map(\.description),
             try Row.fetchAll(db, sql: "SELECT id, is_duplicate, variant_of FROM tracks ORDER BY id").map(\.description))
        }
        let outcome = try await f.decisions.decide(Self.request(f))
        #expect(try playlistTracks(f.queue, a) == [f.ids[0]])
        let record = try await f.decisions.undo(decisionID: outcome.decisionID)
        #expect(record.groupKey == f.groupKey)
        let after = try await f.queue.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM playlist_tracks ORDER BY id").map(\.description),
             try Row.fetchAll(db, sql: "SELECT * FROM sync_profile_tracks ORDER BY track_id").map(\.description),
             try Row.fetchAll(db, sql: "SELECT id, is_duplicate, variant_of FROM tracks ORDER BY id").map(\.description))
        }
        #expect(after.0 == before.0, "playlist rows are back exactly, ids and positions included")
        #expect(after.1 == before.1)
        #expect(after.2 == before.2)
        #expect(try playlistTracks(f.queue, b) == [f.ids[2]])
        let (status, pairs, decisions) = try await f.queue.read { db in
            (try String.fetchOne(db, sql: "SELECT status FROM review_queue"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_decided_pairs"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_decisions"))
        }
        #expect(status == "pending")
        #expect(pairs == 0)
        #expect(decisions == 0)
    }

    @Test func keepAllDecidesEveryPairWithoutChangingTracks() async throws {
        let f = try Self.makeFixture()
        try await f.queue.write { db in
            try db.execute(sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?", arguments: [f.ids[0], f.ids[2]])
        }
        let outcome = try await f.decisions.decide(Self.request(f, action: .keepAll, kept: nil))
        #expect(outcome.unkeptTrackIDs.isEmpty)
        let pairs = try await f.decisions.decidedPairs()
        #expect(pairs == Set(ReviewPair.pairs(of: f.ids)))
        #expect(pairs.count == 3)
        let hidden = try await f.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE is_duplicate = 1") }
        #expect(hidden == 0, "Not Duplicates: every version is listed")
        _ = try await f.decisions.undo(decisionID: outcome.decisionID)
        let restored = try await f.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE is_duplicate = 1") }
        #expect(restored == 1, "the earlier flag is back")
    }

    @Test func aGroupCannotBeDecidedTwice() async throws {
        let f = try Self.makeFixture()
        try await f.decisions.decide(Self.request(f))
        await #expect(throws: ReviewDecisionError.nothingPending) {
            try await f.decisions.decide(Self.request(f))
        }
    }

    @Test func keepNeedsAMemberOfTheGroup() async throws {
        let f = try Self.makeFixture()
        var request = Self.request(f)
        request.keptTrackID = 9_999
        await #expect(throws: ReviewDecisionError.invalidKeep) { try await f.decisions.decide(request) }
        let hidden = try await f.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE is_duplicate = 1") }
        #expect(hidden == 0, "nothing was written")
    }

    @Test func deletingATrackRemovesItsPairs() async throws {
        let f = try Self.makeFixture()
        try await f.decisions.decide(Self.request(f, action: .keepAll, kept: nil))
        try await TrackRepository(database: f.queue).delete(id: f.ids[2])
        let pairs = try await f.decisions.decidedPairs()
        #expect(pairs == [ReviewPair(f.ids[0], f.ids[1])])
    }

    @Test func recordedTrashFilesComeBackWithTheDecision() async throws {
        let f = try Self.makeFixture(members: 2)
        let outcome = try await f.decisions.decide(Self.request(f, mode: .trash))
        let trashed = ReviewDecisionConsequences.Trashed(trackId: f.ids[1], from: "/lib/a.mp3", trashURL: "/Trash/a.mp3")
        try await f.decisions.recordTrashed(decisionID: outcome.decisionID, trashed: [trashed], failures: 1)
        let record = try #require(try await f.decisions.decision(id: outcome.decisionID))
        #expect(record.unkeptMode == .trash)
        #expect(record.consequences.trashed == [trashed])
        #expect(record.consequences.trashFailures == 1)
    }

    // MARK: Rescan (PP-SOURCES-01)

    private func proposal(_ f: Fixture, ids: [Int64], type: String = "fingerprint_dedup") -> ReviewItem {
        ReviewItem(id: nil, actionType: type, groupKey: DuplicateReviewGrouping.groupKey(for: ids),
                   trackId: ids[0], relatedTrackId: ids[1],
                   details: (try? ReviewDetails(groupKey: DuplicateReviewGrouping.groupKey(for: ids),
                                                tracks: ids.map { ReviewTrackSnapshot(id: $0, title: "t", artist: "a") }).encodedJSON()) ?? "{}",
                   autoAction: nil, status: "pending", createdAt: nil, resolvedAt: nil)
    }

    @Test func aDecidedGroupIsNotProposedAgainAndResolvedHistoryStays() async throws {
        let f = try Self.makeFixture()
        try await f.decisions.decide(Self.request(f, action: .keepAll, kept: nil))
        let proposed = try await f.analysis.replacePendingScanReviewItems([proposal(f, ids: f.ids)])
        #expect(proposed.duplicates == 0)
        let (pending, resolved) = try await f.queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE status = 'pending'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE status = 'resolved'"))
        }
        #expect(pending == 0)
        #expect(resolved == 1, "the scan no longer deletes resolved history")
    }

    @Test func aGroupWithOneNewMemberIsProposed() async throws {
        let f = try Self.makeFixture()
        try await f.decisions.decide(Self.request(f, action: .keepAll, kept: nil))
        let newID: Int64 = try await f.queue.write { db in
            var track = Track(artist: "Overmono", album: "x", title: "So U Kno (new)", format: "m4a", originalPath: "/new.m4a")
            try track.insert(db)
            return track.id!
        }
        let grown = f.ids + [newID]
        let proposed = try await f.analysis.replacePendingScanReviewItems([proposal(f, ids: grown)])
        #expect(proposed.duplicates == 1)
    }

    @Test func aRestoredGroupIsProposedAgain() async throws {
        let f = try Self.makeFixture()
        let outcome = try await f.decisions.decide(Self.request(f, action: .keepAll, kept: nil))
        try await f.decisions.undo(decisionID: outcome.decisionID)
        let proposed = try await f.analysis.replacePendingScanReviewItems([proposal(f, ids: f.ids)])
        #expect(proposed.duplicates == 1)
    }

    @Test func conflictsAreCountedSeparately() async throws {
        let f = try Self.makeFixture(pending: false)
        let proposed = try await f.analysis.replacePendingScanReviewItems([proposal(f, ids: f.ids, type: "metadata_conflict")])
        #expect(proposed.conflicts == 1)
        #expect(proposed.duplicates == 0)
    }

    @Test func aGroupResolvedBeforeV48WithoutPairsStaysResolved() async throws {
        let f = try Self.makeFixture(pending: false)
        try await f.queue.write { db in
            try db.execute(sql: """
                INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                VALUES ('fingerprint_dedup', ?, ?, ?, '{}', 'resolved')
                """, arguments: [f.groupKey, f.ids[0], f.ids[1]])
        }
        let proposed = try await f.analysis.replacePendingScanReviewItems([proposal(f, ids: f.ids)])
        #expect(proposed.duplicates == 0)
    }
}
