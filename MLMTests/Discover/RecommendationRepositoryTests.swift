import Foundation
import GRDB
import Testing
@testable import MLM

/// Held recommendations and their verdicts on a temporary database (IMP-053…055).
@Suite("RecommendationRepositoryTests")
struct RecommendationRepositoryTests {
    struct Env {
        let db: DatabaseQueue
        let tracks: TrackRepository
        let recs: RecommendationRepository
        let seed: Int64
        let held: [Int64]
        let plain: Int64
    }

    static func make(held count: Int = 3) async throws -> Env {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        let recs = RecommendationRepository(database: db)
        func track(_ title: String, path: String?) async throws -> Int64 {
            var t = Track(artist: "Artist", album: "", title: title, format: "m4a", originalPath: "/o/\(title).m4a")
            t.organizedPath = path
            return try #require(try await tracks.insert(t).id)
        }
        let seed = try await track("Seed", path: "Seed.m4a")
        let plain = try await track("Plain", path: "Plain.m4a")
        var held: [Int64] = []
        for index in 0..<count {
            let id = try await track("Held \(index)", path: "Neighbors/Held \(index).m4a")
            try await recs.markHeld(trackID: id, seedTrackID: seed, source: index == 0 ? "lastfm" : "soundcloud")
            held.append(id)
        }
        return Env(db: db, tracks: tracks, recs: recs, seed: seed, held: held, plain: plain)
    }

    private func listed(_ env: Env) async throws -> Set<Int64> {
        Set(try await env.tracks.fetchTracks(scope: .all).compactMap(\.id))
    }

    @Test func aHeldTrackIsNotListedButIsWaiting() async throws {
        let env = try await Self.make()
        #expect(try await listed(env) == [env.seed, env.plain])
        let searched = try await TrackSearchQueries(database: env.db)
            .fetchTracks(scope: .all, filter: SearchFilter(text: "Held"))
        #expect(searched.isEmpty)
        let waiting = try await env.recs.waiting()
        #expect(Set(waiting.map(\.id)) == Set(env.held))
        #expect(waiting.allSatisfy { $0.seedTitle == "Seed" })
        let inbox = try await env.tracks.fetchDiscoveryInboxTracks()
        #expect(Set(inbox.compactMap(\.track.id)) == Set(env.held))
    }

    @Test func keepJoinsTheLibraryAndUndoRestoresTheRows() async throws {
        let env = try await Self.make()
        let kept = try await env.recs.keep(ids: [env.held[0], env.held[0], env.plain])
        #expect(kept == [env.held[0]], "only waiting ones change, once")
        #expect(try await listed(env).contains(env.held[0]))
        #expect(try await env.recs.waiting().count == 2)
        #expect(try await env.recs.statuses(for: kept)[env.held[0]] == "kept")
        try await env.recs.undoKeep(ids: kept)
        #expect(!(try await listed(env)).contains(env.held[0]))
        #expect(try await env.recs.waiting().count == 3)
    }

    @Test func dismissKeepsTheFlagRecordsTrashAndUndoRestoresWaiting() async throws {
        let env = try await Self.make()
        let dismissed = try await env.recs.dismiss(ids: [env.held[1]])
        #expect(dismissed == [.init(trackID: env.held[1], organizedPath: "Neighbors/Held 1.m4a")])
        #expect(try await env.recs.waiting().count == 2)
        #expect(!(try await listed(env)).contains(env.held[1]), "stays out of every list")
        try await env.recs.recordTrash(trackID: env.held[1], url: "/Trash/Held 1.m4a")
        #expect(try await env.recs.trashURLs(for: [env.held[1]]) == [env.held[1]: "/Trash/Held 1.m4a"])
        try await env.recs.undoDismiss(ids: [env.held[1]])
        #expect(try await env.recs.waiting().count == 3)
        #expect(try await env.recs.trashURLs(for: [env.held[1]]).isEmpty)
    }

    @Test func purgeRemovesOnlyDismissedRowsAndTheirDependentRows() async throws {
        let env = try await Self.make()
        let dismissedID = env.held[1]
        try await env.db.write { db in
            try db.execute(sql: "INSERT INTO artwork (track_id, source) VALUES (?, 'x')", arguments: [dismissedID])
        }
        _ = try await env.recs.dismiss(ids: [dismissedID])
        #expect(try await env.recs.purgeDismissed() == 1)
        let (trackRows, logRows, art) = try await env.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE id = ?", arguments: [dismissedID]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_discovery_log WHERE discovered_track_id = ?", arguments: [dismissedID]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artwork WHERE track_id = ?", arguments: [dismissedID]))
        }
        #expect(trackRows == 0 && logRows == 0 && art == 0)
        #expect(try await env.recs.waiting().count == 2)
        #expect(try await env.recs.purgeDismissed() == 0)
    }

    @Test func insertWritesTrackFlagAndLogInOneStep() async throws {
        let env = try await Self.make(held: 0)
        let held = try await env.recs.insert(
            Track(artist: "B", album: "", title: "New", format: "m4a", originalPath: "/o/new.m4a"),
            hold: true, seedTrackID: env.seed, source: "soundcloud")
        let free = try await env.recs.insert(
            Track(artist: "C", album: "", title: "Direct", format: "m4a", originalPath: "/o/d.m4a"),
            hold: false, seedTrackID: env.seed, source: "soundcloud")
        let heldID = try #require(held.id)
        let freeID = try #require(free.id)
        let all = try await listed(env)
        #expect(!all.contains(heldID))
        #expect(all.contains(freeID))
        let statuses = try await env.recs.statuses(for: [heldID, freeID])
        #expect(statuses[heldID] == "new" && statuses[freeID] == "kept")
    }
}
