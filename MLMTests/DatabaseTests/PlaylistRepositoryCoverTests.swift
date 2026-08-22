import Testing
import GRDB
@testable import MLM

/// Tests for the cover_is_custom column (migration v20) and the
/// `PlaylistRepository.setCoverPath(id:path:isCustom:)` setter plus the
/// deterministic `fetchTracks` tie-breaker.
///
/// Phase 36, Plan 01.
struct PlaylistRepositoryCoverTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, PlaylistRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = PlaylistRepository(database: db)
        return (db, repo)
    }

    // MARK: - Schema (migration v20)

    @Test func playlistsTableHasCoverIsCustomColumn() async throws {
        let (db, _) = try makeRepo()
        try await db.read { db in
            let columns = try db.columns(in: "playlists").map(\.name)
            #expect(columns.contains("cover_is_custom"),
                    "Migration v20 failed to add cover_is_custom column")
        }
    }

    @Test func defaultValueIsZeroOnRawInsert() async throws {
        let (db, _) = try makeRepo()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO playlists (name, category) VALUES ('Test', 'regular')
            """)
            let value = try Int.fetchOne(db, sql:
                "SELECT cover_is_custom FROM playlists WHERE name = 'Test'")
            #expect(value == 0, "DEFAULT 0 did not materialize on raw INSERT")
        }
    }

    // MARK: - setCoverPath setter

    @Test func setCoverPath_writesPathAndCustomFlag() async throws {
        let (_, repo) = try makeRepo()
        let pl = try await repo.create(name: "Cover Test")
        let id = pl.id!
        try await repo.setCoverPath(id: id, path: "playlist-covers/42.png", isCustom: true)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched?.coverImagePath == "playlist-covers/42.png")
        #expect(fetched?.coverIsCustom == 1)
    }

    @Test func setCoverPath_resetToAutoClearsBoth() async throws {
        let (_, repo) = try makeRepo()
        let pl = try await repo.create(name: "Reset Test")
        let id = pl.id!
        try await repo.setCoverPath(id: id, path: "playlist-covers/99.png", isCustom: true)
        try await repo.setCoverPath(id: id, path: nil, isCustom: false)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched?.coverImagePath == nil)
        #expect(fetched?.coverIsCustom == 0)
    }

    // MARK: - fetchTracks tie-breaker (position ASC, added_at ASC)

    @Test func fetchTracks_tieBreaksByAddedAtAsc() async throws {
        let (db, repo) = try makeRepo()
        let pl = try await repo.create(name: "Tie Test")
        let pid = pl.id!

        // Seed three tracks with identical position but different added_at.
        // Schema requires artist, album_artist, album, title, format, original_path (all NOT NULL).
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added) VALUES
                    (1, 'A', 'A', 'AlbumA', 'First',  'mp3', '/tmp/a.mp3', '2025-01-01T00:00:00Z'),
                    (2, 'B', 'B', 'AlbumB', 'Second', 'mp3', '/tmp/b.mp3', '2025-01-01T00:00:00Z'),
                    (3, 'C', 'C', 'AlbumC', 'Third',  'mp3', '/tmp/c.mp3', '2025-01-01T00:00:00Z')
            """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES
                    (?, 1, '0.5', '2025-01-03T00:00:00Z'),
                    (?, 2, '0.5', '2025-01-01T00:00:00Z'),
                    (?, 3, '0.5', '2025-01-02T00:00:00Z')
            """, arguments: [pid, pid, pid])
        }

        let tracks = try await repo.fetchTracks(playlistId: pid)
        #expect(tracks.map(\.title) == ["Second", "Third", "First"],
                "fetchTracks tie-breaker must order identical positions by added_at ASC")
    }
}
