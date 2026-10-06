import Foundation
import Testing
import GRDB
@testable import MLM

@Suite("TrackRepository Batching")
struct TrackRepositoryBatchingTests {

    private func makeRepo() throws -> (DatabaseQueue, TrackRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        return (db, repo)
    }

    private func insertTrack(
        _ db: DatabaseQueue,
        title: String,
        organizedPath: String?
    ) async throws -> Int64 {
        try await db.write { db in
            var t = Track(artist: "A", album: "B", title: title, format: "mp3",
                          originalPath: "/\(title).mp3")
            t.organizedPath = organizedPath
            t.dateAdded = "2024-01-01T00:00:00Z"
            t.searchText = DatabaseManager.foldedSearchText(t.rawSearchText)
            try t.insert(db)
            return t.id!
        }
    }

    // MARK: - Seed batching

    @Test func discoveryInboxResolvesSeedsInBatch() async throws {
        let (db, repo) = try makeRepo()

        let seedId1 = try await insertTrack(db, title: "Seed1", organizedPath: "/s1.mp3")
        let seedId2 = try await insertTrack(db, title: "Seed2", organizedPath: "/s2.mp3")
        let discovered1 = try await insertTrack(db, title: "Disc1", organizedPath: "/d1.mp3")
        let discovered2 = try await insertTrack(db, title: "Disc2", organizedPath: "/d2.mp3")
        let discovered3 = try await insertTrack(db, title: "Disc3", organizedPath: "/d3.mp3")
        let discovered4 = try await insertTrack(db, title: "Disc4", organizedPath: "/d4.mp3")

        let t1 = Date(timeIntervalSince1970: 1_800_000_100)
        let t2 = Date(timeIntervalSince1970: 1_800_000_200)
        let t3 = Date(timeIntervalSince1970: 1_800_000_300)
        let t4 = Date(timeIntervalSince1970: 1_800_000_400)

        try await db.write { db in
            var r1 = TrackDiscoveryLog(discoveredTrackId: discovered1, seedTrackId: seedId1, discoverySource: "lastfm", status: "new")
            r1.dateAdded = t1
            try r1.insert(db, onConflict: .replace)

            var r2 = TrackDiscoveryLog(discoveredTrackId: discovered2, seedTrackId: seedId2, discoverySource: "spotify", status: "new")
            r2.dateAdded = t2
            try r2.insert(db, onConflict: .replace)

            var r3 = TrackDiscoveryLog(discoveredTrackId: discovered3, seedTrackId: nil, discoverySource: "lastfm", status: "new")
            r3.dateAdded = t3
            try r3.insert(db, onConflict: .replace)

            var r4 = TrackDiscoveryLog(discoveredTrackId: discovered4, seedTrackId: 999_999, discoverySource: "lastfm", status: "new")
            r4.dateAdded = t4
            try r4.insert(db, onConflict: .replace)

            let approvedId = try {
                var t = Track(artist: "A", album: "B", title: "Approved", format: "mp3", originalPath: "/Approved.mp3")
                t.organizedPath = "/ap.mp3"
                t.dateAdded = "2024-01-01T00:00:00Z"
                t.searchText = DatabaseManager.foldedSearchText(t.rawSearchText)
                try t.insert(db)
                return t.id!
            }()
            var rA = TrackDiscoveryLog(discoveredTrackId: approvedId, seedTrackId: seedId1, discoverySource: "lastfm", status: "approved")
            rA.dateAdded = t4.addingTimeInterval(60)
            try rA.insert(db, onConflict: .replace)
        }

        let inbox = try await repo.fetchDiscoveryInboxTracks()

        #expect(inbox.count == 4)

        #expect(inbox[0].track.id == discovered4)
        #expect(inbox[0].seedTrack == nil)

        #expect(inbox[1].track.id == discovered3)
        #expect(inbox[1].seedTrack == nil)

        #expect(inbox[2].track.id == discovered2)
        #expect(inbox[2].seedTrack?.id == seedId2)

        #expect(inbox[3].track.id == discovered1)
        #expect(inbox[3].seedTrack?.id == seedId1)
    }

    @Test func discoveryInboxEmptySetDoesNotCrash() async throws {
        let (_, repo) = try makeRepo()
        let inbox = try await repo.fetchDiscoveryInboxTracks()
        #expect(inbox.isEmpty)
    }
}
