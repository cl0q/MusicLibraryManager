import Testing
import GRDB
@testable import MLM

/// Tests for the v35_mlm_uuid migration and the UUID generation helpers.
@Suite("MlmUuidMigrationTests")
struct MlmUuidMigrationTests {

    // MARK: - Migration

    @Test func migrationAddsMlmUuidColumns() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let trackColumns = try db.columns(in: "tracks").map(\.name)
            let playlistColumns = try db.columns(in: "playlists").map(\.name)
            #expect(trackColumns.contains("mlm_uuid"), "tracks table should have mlm_uuid column")
            #expect(playlistColumns.contains("mlm_uuid"), "playlists table should have mlm_uuid column")
        }
    }

    @Test func migrationIsIdempotent() async throws {
        // Running the migrator twice (via two inMemory() calls) must not error.
        let db1 = try DatabaseManager.inMemory()
        let db2 = try DatabaseManager.inMemory()

        for db in [db1, db2] {
            try await db.read { db in
                let trackColumns = try db.columns(in: "tracks").map(\.name)
                let playlistColumns = try db.columns(in: "playlists").map(\.name)
                #expect(trackColumns.contains("mlm_uuid"))
                #expect(playlistColumns.contains("mlm_uuid"))
            }
        }
    }

    @Test func mlmUuidColumnsAreNullable() async throws {
        let db = try DatabaseManager.inMemory()
        // Insert a track and a playlist without mlm_uuid — should succeed.
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (artist, album_artist, album, title, format, original_path, is_duplicate)
                VALUES ('A', 'A', 'B', 'T', 'mp3', '/tmp/x.mp3', 0)
            """)
            try db.execute(sql: """
                INSERT INTO playlists (name, category, is_liked, is_smart, is_pinned)
                VALUES ('P', 'regular', 0, 0, 0)
            """)
        }
        try await db.read { db in
            let uuid = try String.fetchOne(db, sql: "SELECT mlm_uuid FROM tracks LIMIT 1")
            #expect(uuid == nil)
            let pUuid = try String.fetchOne(db, sql: "SELECT mlm_uuid FROM playlists LIMIT 1")
            #expect(pUuid == nil)
        }
    }

    // MARK: - UUID generation

    @Test func generateMlmUuidIsUppercasedUUIDv4Format() {
        let uuid = Track.generateMlmUuid()
        // UUID v4 format: 8-4-4-4-12 uppercase hex
        let pattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        #expect(uuid.range(of: pattern, options: .regularExpression) != nil,
                "UUID '\(uuid)' should match uppercase UUIDv4 format")
    }

    @Test func generateMlmUuidProducesUniqueValues() {
        let uuids = (0..<100).map { _ in Track.generateMlmUuid() }
        #expect(Set(uuids).count == 100, "100 generated UUIDs should all be unique")
    }

    @Test func playlistGenerateMlmUuidMatchesFormat() {
        let uuid = Playlist.generateMlmUuid()
        let pattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        #expect(uuid.range(of: pattern, options: .regularExpression) != nil)
    }

    // MARK: - ensureMlmUuid

    @Test func ensureUuidFillsMissingOnly() {
        var track = Track(artist: "A", album: "B", title: "T", format: "mp3", originalPath: "/x.mp3")
        #expect(track.mlmUuid == nil)

        let filled = track.ensureMlmUuid()
        #expect(filled == true)
        #expect(track.mlmUuid != nil)
        let firstUuid = track.mlmUuid!

        // Calling again should NOT overwrite
        let filled2 = track.ensureMlmUuid()
        #expect(filled2 == false)
        #expect(track.mlmUuid == firstUuid)
    }

    @Test func playlistEnsureUuidFillsMissingOnly() {
        var playlist = Playlist.createNative(name: "Test")
        #expect(playlist.mlmUuid == nil)

        let filled = playlist.ensureMlmUuid()
        #expect(filled == true)
        #expect(playlist.mlmUuid != nil)
        let firstUuid = playlist.mlmUuid!

        let filled2 = playlist.ensureMlmUuid()
        #expect(filled2 == false)
        #expect(playlist.mlmUuid == firstUuid)
    }

    // MARK: - Roundtrip through DB

    @Test func trackMlmUuidRoundtrip() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)

        var track = Track(artist: "A", album: "B", title: "T", format: "mp3", originalPath: "/x.mp3")
        _ = track.ensureMlmUuid()
        let inserted = try await repo.insert(track)

        let fetched = try await repo.fetchTrack(id: inserted.id!)
        #expect(fetched?.mlmUuid == inserted.mlmUuid)
    }
}
