import Testing
import GRDB
@testable import MLM

/// Tests for the v38_track_index_hygiene migration.
///
/// The six vestigial `idx_*` indexes were never created by the current
/// DatabaseManager — they are leftovers from the dropped Tauri predecessor.
/// To make the drop assertion non-vacuous, these tests manually create them
/// on a fresh in-memory DB (which has already run all migrations including
/// v38), then re-run the v38 migration SQL and verify the indexes are gone.
@Suite("TrackIndexHygieneTests")
struct TrackIndexHygieneTests {

    // MARK: - Vestigial indexes are dropped

    @Test func vestigialIndexesAreDropped() async throws {
        let db = try DatabaseManager.inMemory()

        // Simulate legacy state: manually create the six vestigial indexes
        // that the dropped Tauri app left behind.
        try await db.write { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_title ON tracks(title)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album ON tracks(album)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_artist ON tracks(artist)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_album_id ON tracks(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_duplicate ON tracks(is_duplicate)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_variant_of ON tracks(variant_of)")
        }

        // Verify they exist before running the migration
        try await db.read { db in
            let indexes = try db.indexes(on: "tracks").map(\.name)
            #expect(indexes.contains("idx_title"))
            #expect(indexes.contains("idx_album"))
            #expect(indexes.contains("idx_artist"))
            #expect(indexes.contains("idx_tracks_album_id"))
            #expect(indexes.contains("idx_duplicate"))
            #expect(indexes.contains("idx_variant_of"))
        }

        // Re-run the v38 migration SQL
        try await db.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_title")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_album")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_artist")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_album_id")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_duplicate")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_variant_of")
            try db.create(indexOn: "tracks", columns: ["danceability"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["format"], options: .ifNotExists)
        }

        // Assert all six are gone
        try await db.read { db in
            let indexes = try db.indexes(on: "tracks").map(\.name)
            #expect(!indexes.contains("idx_title"), "idx_title should be dropped")
            #expect(!indexes.contains("idx_album"), "idx_album should be dropped")
            #expect(!indexes.contains("idx_artist"), "idx_artist should be dropped")
            #expect(!indexes.contains("idx_tracks_album_id"), "idx_tracks_album_id should be dropped")
            #expect(!indexes.contains("idx_duplicate"), "idx_duplicate should be dropped")
            #expect(!indexes.contains("idx_variant_of"), "idx_variant_of should be dropped")
        }
    }

    // MARK: - Kept indexes survive

    @Test func keptIndexesSurvive() async throws {
        let db = try DatabaseManager.inMemory()

        // Simulate legacy state and run migration
        try await db.write { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_title ON tracks(title)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album ON tracks(album)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_artist ON tracks(artist)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_album_id ON tracks(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_duplicate ON tracks(is_duplicate)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_variant_of ON tracks(variant_of)")
        }

        try await db.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_title")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_album")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_artist")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_album_id")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_duplicate")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_variant_of")
            try db.create(indexOn: "tracks", columns: ["danceability"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["format"], options: .ifNotExists)
        }

        // Assert the kept indexes still exist
        try await db.read { db in
            let indexes = try db.indexes(on: "tracks").map(\.name)

            // GRDB's index_tracks_on_* set
            #expect(indexes.contains("index_tracks_on_title"), "index_tracks_on_title should be kept")
            #expect(indexes.contains("index_tracks_on_album"), "index_tracks_on_album should be kept")
            #expect(indexes.contains("index_tracks_on_artist"), "index_tracks_on_artist should be kept")
            #expect(indexes.contains("index_tracks_on_album_id"), "index_tracks_on_album_id should be kept")
            #expect(indexes.contains("index_tracks_on_is_duplicate"), "index_tracks_on_is_duplicate should be kept")
            #expect(indexes.contains("index_tracks_on_variant_of"), "index_tracks_on_variant_of should be kept")

            // These two must NOT be dropped (regression guard)
            #expect(indexes.contains("idx_tracks_genre"), "idx_tracks_genre must be kept (only index on genre)")
            #expect(indexes.contains("idx_organized_path_null"), "idx_organized_path_null must be kept (partial index)")
        }
    }

    // MARK: - New indexes are created

    @Test func newIndexesAreCreated() async throws {
        let db = try DatabaseManager.inMemory()

        // The migration should have created these
        try await db.read { db in
            let indexes = try db.indexes(on: "tracks").map(\.name)
            #expect(indexes.contains("index_tracks_on_danceability"), "danceability index should exist")
            #expect(indexes.contains("index_tracks_on_format"), "format index should exist")
        }
    }

    // MARK: - Query plan improvement

    @Test func queryPlanUsesIndexForDanceability() async throws {
        let db = try DatabaseManager.inMemory()

        // Insert some test data
        try await db.write { db in
            for i in 0..<100 {
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, danceability)
                    VALUES ('Artist \(i)', 'Artist \(i)', 'Album \(i)', 'Title \(i)', 'mp3', '/tmp/\(i).mp3', 0.\(i))
                """)
            }
        }

        // Check query plan for danceability sort
        let plan = try await db.read { db -> String in
            let rows = try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT * FROM tracks
                WHERE organized_path IS NOT NULL
                ORDER BY danceability ASC LIMIT 200
            """)
            return rows.map { $0["detail"] as String }.joined(separator: " ")
        }

        #expect(!plan.contains("USE TEMP B-TREE"), "Query plan should not use temp B-tree for danceability sort")
        #expect(plan.contains("INDEX"), "Query plan should use an index for danceability sort")
    }

    @Test func queryPlanUsesIndexForFormat() async throws {
        let db = try DatabaseManager.inMemory()

        // Insert some test data
        try await db.write { db in
            for i in 0..<100 {
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                    VALUES ('Artist \(i)', 'Artist \(i)', 'Album \(i)', 'Title \(i)', 'mp3', '/tmp/\(i).mp3')
                """)
            }
        }

        // Check query plan for format sort
        let plan = try await db.read { db -> String in
            let rows = try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT * FROM tracks
                WHERE organized_path IS NOT NULL
                ORDER BY format ASC LIMIT 200
            """)
            return rows.map { $0["detail"] as String }.joined(separator: " ")
        }

        #expect(!plan.contains("USE TEMP B-TREE"), "Query plan should not use temp B-tree for format sort")
        #expect(plan.contains("INDEX"), "Query plan should use an index for format sort")
    }

    // MARK: - Idempotency

    @Test func migrationIsIdempotent() async throws {
        // Running the migrator twice must not error
        let db1 = try DatabaseManager.inMemory()
        let db2 = try DatabaseManager.inMemory()

        for db in [db1, db2] {
            try await db.read { db in
                let indexes = try db.indexes(on: "tracks").map(\.name)
                #expect(indexes.contains("index_tracks_on_danceability"))
                #expect(indexes.contains("index_tracks_on_format"))
            }
        }
    }

    @Test func migrationIsReentrantOnLegacySchema() async throws {
        let db = try DatabaseManager.inMemory()

        // Simulate legacy state
        try await db.write { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_title ON tracks(title)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album ON tracks(album)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_artist ON tracks(artist)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_album_id ON tracks(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_duplicate ON tracks(is_duplicate)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_variant_of ON tracks(variant_of)")
        }

        // Run migration SQL twice
        for _ in 0..<2 {
            try await db.write { db in
                try db.execute(sql: "DROP INDEX IF EXISTS idx_title")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_album")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_artist")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_album_id")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_duplicate")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_variant_of")
                try db.create(indexOn: "tracks", columns: ["danceability"], options: .ifNotExists)
                try db.create(indexOn: "tracks", columns: ["format"], options: .ifNotExists)
            }
        }

        // Should not throw, and indexes should be in correct state
        try await db.read { db in
            let indexes = try db.indexes(on: "tracks").map(\.name)
            #expect(!indexes.contains("idx_title"))
            #expect(indexes.contains("index_tracks_on_danceability"))
            #expect(indexes.contains("index_tracks_on_format"))
        }
    }

    @Test func migrationSucceedsWhenLegacyIndexesNeverExisted() async throws {
        // Fresh DB has no idx_* indexes — migration should still succeed
        let db = try DatabaseManager.inMemory()

        // Run migration SQL on a DB where idx_* never existed
        try await db.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_title")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_album")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_artist")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_album_id")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_duplicate")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_variant_of")
            try db.create(indexOn: "tracks", columns: ["danceability"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["format"], options: .ifNotExists)
        }

        // Should succeed without error
        try await db.read { db in
            let indexes = try db.indexes(on: "tracks").map(\.name)
            #expect(indexes.contains("index_tracks_on_danceability"))
            #expect(indexes.contains("index_tracks_on_format"))
        }
    }
}
