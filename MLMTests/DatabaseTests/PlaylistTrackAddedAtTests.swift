import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("PlaylistTrackAddedAt")
struct PlaylistTrackAddedAtTests {

    private func makeRepo() throws -> (DatabaseQueue, PlaylistRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = PlaylistRepository(database: db)
        return (db, repo)
    }

    private func seedTrack(in db: DatabaseQueue, id: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added)
                VALUES (?, 'A', 'A', 'Album', 'Track', 'mp3', ?, '2025-01-01T00:00:00Z')
            """, arguments: [id, "/tmp/t\(id).mp3"])
        }
    }

    private func readAddedAt(in db: DatabaseQueue, playlistId: Int64, trackId: Int64) async throws -> String? {
        try await db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT added_at FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?
            """, arguments: [playlistId, trackId])?["added_at"]
        }
    }

    private static let addedAtRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#)

    private func matchesFormat(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return Self.addedAtRegex.firstMatch(in: value, range: range) != nil
    }

    // MARK: - F8 headline

    @Test func addTrack_writesNonNullAddedAt() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 1)

        try await repo.addTrack(playlistId: pl.id!, trackId: 1, position: "0.5")

        let value = try await readAddedAt(in: db, playlistId: pl.id!, trackId: 1)
        #expect(value != nil)
    }

    @Test func addTrack_formatMatchesSQLiteCurrentTimestamp() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 1)

        try await repo.addTrack(playlistId: pl.id!, trackId: 1, position: "0.5")

        let value = try await readAddedAt(in: db, playlistId: pl.id!, trackId: 1)!
        #expect(matchesFormat(value),
                "added_at '\(value)' must be 'YYYY-MM-DD HH:MM:SS', not ISO 8601")
    }

    @Test func mixedFormatSort_newRowsSortAfterLegacy() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 1)
        try await seedTrack(in: db, id: 2)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at)
                VALUES (?, 1, 'a', '2026-05-05 14:47:32')
            """, arguments: [pl.id!])
        }

        try await repo.addTrack(playlistId: pl.id!, trackId: 2, position: "b")

        let trackIds: [Int64] = try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track_id FROM playlist_tracks WHERE playlist_id = ?
                ORDER BY added_at ASC
            """, arguments: [pl.id!])
            return rows.compactMap { $0["track_id"] as? Int64 }
        }
        #expect(trackIds == [1, 2])
    }

    // MARK: - All four sites

    @Test func addTracks_writesNonNullFormattedAddedAt() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 10)
        try await seedTrack(in: db, id: 20)
        try await seedTrack(in: db, id: 30)

        try await repo.addTracks(playlistId: pl.id!, trackIds: [10, 20, 30], startPosition: "a")

        for tid: Int64 in [10, 20, 30] {
            let value = try await readAddedAt(in: db, playlistId: pl.id!, trackId: tid)
            #expect(value != nil, "track \(tid) should have non-NULL added_at")
            #expect(matchesFormat(value!),
                    "track \(tid) format mismatch: '\(value!)'")
        }
    }

    @Test func placeTracks_insertsNewRowsWithNonNullAddedAt() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 40)
        try await seedTrack(in: db, id: 50)

        try await repo.placeTracks(playlistId: pl.id!, placements: [
            (trackId: 40, position: "a"),
            (trackId: 50, position: "b"),
        ])

        for tid: Int64 in [40, 50] {
            let value = try await readAddedAt(in: db, playlistId: pl.id!, trackId: tid)
            #expect(value != nil, "track \(tid) should have non-NULL added_at")
            #expect(matchesFormat(value!))
        }
    }

    @Test func replaceTrackList_writesNonNullFormattedAddedAt() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 60)
        try await seedTrack(in: db, id: 70)

        try await repo.replaceTrackList(playlistId: pl.id!, trackIds: [60, 70])

        for tid: Int64 in [60, 70] {
            let value = try await readAddedAt(in: db, playlistId: pl.id!, trackId: tid)
            #expect(value != nil, "track \(tid) should have non-NULL added_at")
            #expect(matchesFormat(value!))
        }
    }

    // MARK: - Conflict semantics

    @Test func addTrack_duplicateIsSilentlyIgnored() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Test")
        try await seedTrack(in: db, id: 1)

        try await repo.addTrack(playlistId: pl.id!, trackId: 1, position: "a")
        try await repo.addTrack(playlistId: pl.id!, trackId: 1, position: "b")

        let count = try await db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?
            """, arguments: [pl.id!, 1])!
        }
        #expect(count == 1)
    }

    // MARK: - F13

    @Test func findByName_matchesCaseInsensitively() async throws {
        let (_, repo) = try makeRepo()
        _ = try await repo.create(name: "My Mix")

        let found = try await repo.findByName("my mix")
        #expect(found != nil)
        #expect(found?.name == "My Mix")
    }

    @Test func findByName_returnsNilForNonexistent() async throws {
        let (_, repo) = try makeRepo()
        _ = try await repo.create(name: "Alpha")

        let found = try await repo.findByName("Zulu")
        #expect(found == nil)
    }

    @Test func findByName_returnsFullyPopulatedPlaylist() async throws {
        let (_, repo) = try makeRepo()
        let created = try await repo.create(name: "Test Playlist")

        let found = try await repo.findByName("test playlist")
        #expect(found != nil)
        #expect(found?.id == created.id)
        #expect(found?.name == "Test Playlist")
        #expect(found?.category == created.category)
    }
}
