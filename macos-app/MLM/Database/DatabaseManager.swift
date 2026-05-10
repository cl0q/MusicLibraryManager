import Foundation
import GRDB

/// Manages the GRDB connection pool and database migrations.
///
/// Opens the same SQLite database file as the Tauri app, ensuring
/// schema parity. Both apps can operate on the same library.
///
/// ## Database Location
///
/// The database is stored in the app's Application Support directory:
/// `~/Library/Application Support/com.mlm.music-library-manager/music_library.db`
///
/// This matches the Tauri app's data directory location.
final class DatabaseManager: Sendable {
    /// The database connection pool for concurrent reads + serialized writes.
    let pool: DatabasePool

    /// The path to the database file.
    let databasePath: URL

    /// Initialize the database manager.
    ///
    /// Creates the database file and directory if they don't exist,
    /// then runs all pending migrations to bring the schema up to date.
    ///
    /// - Throws: DatabaseError if the database cannot be opened or migrated
    init() throws {
        let databasePath = Self.defaultDatabasePath()

        // Ensure the parent directory exists
        let directory = databasePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.databasePath = databasePath

        // Open connection pool with WAL mode for concurrent reads
        var config = Configuration()
        config.foreignKeysEnabled = false
        config.prepareDatabase { db in
            try? db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        self.pool = try DatabasePool(path: databasePath.path, configuration: config)

        // Run all migrations
        try migrator.migrate(pool)

        // Clean up orphaned track_tags from v11 SoundCloud resync migration
        try? pool.write { db in
            try db.execute(sql: "DELETE FROM track_tags WHERE track_id NOT IN (SELECT id FROM tracks)")
        }
    }

    /// Initialize with a custom database path (for testing).
    init(path: URL) throws {
        self.databasePath = path

        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true

        self.pool = try DatabasePool(path: path.path, configuration: config)
        try migrator.migrate(pool)
    }

    /// Create an in-memory database for testing.
    static func inMemory() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true

        let queue = try DatabaseQueue(configuration: config)
        try Self.inMemoryMigrator.migrate(queue)
        return queue
    }

    // MARK: - Database Path

    /// Default database path in Application Support.
    ///
    /// Matches the Tauri app's data directory so both apps share the same DB.
    private static func defaultDatabasePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.musiclibrary.app")
        return appDir.appendingPathComponent("music_library.db")
    }

    // MARK: - Database Migrator

    /// The GRDB migrator with all schema versions.
    ///
    /// Ports all 17 migration versions from the Tauri app's Rust schema.
    /// Each migration is idempotent — safe to re-run.
    private var migrator: DatabaseMigrator {
        Self.buildMigrator()
    }

    /// In-memory migrator (same migrations, for testing).
    private static var inMemoryMigrator: DatabaseMigrator {
        buildMigrator()
    }

    private static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Disable deferred foreign key checks during migration
        migrator.eraseDatabaseOnSchemaChange = false

        // ──────────────────────────────────────────────────────────────
        // Migration v1: Core tracks table (Phase 1)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v1_core_tracks") { db in
            try db.create(table: "tracks", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artist", .text).notNull()
                t.column("album_artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("title", .text).notNull()
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("bitrate", .integer)
                t.column("duration", .integer)
                t.column("format", .text).notNull()
                t.column("original_path", .text).notNull().unique()
                t.column("organized_path", .text)
                t.column("is_duplicate", .integer).defaults(to: 0)
                t.column("date_added", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(indexOn: "tracks", columns: ["artist"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["album"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["title"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["is_duplicate"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v2: variant_of column + sources tables (Phase 3)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v2_sources_and_variant") { db in
            // Add variant_of to tracks
            if try !db.columns(in: "tracks").contains(where: { $0.name == "variant_of" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "variant_of", .integer)
                        .references("tracks", onDelete: .setNull)
                }
            }
            try db.create(indexOn: "tracks", columns: ["variant_of"], options: .ifNotExists)

            // Sources table
            try db.create(table: "sources", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("user_id", .text).notNull()
                t.column("enabled", .integer).defaults(to: 1)
                t.uniqueKey(["name", "user_id"])
            }

            // Track sources (many-to-many)
            try db.create(table: "track_sources", options: .ifNotExists) { t in
                t.column("track_id", .integer).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("source_id", .integer).notNull()
                    .references("sources", onDelete: .cascade)
                t.column("external_id", .text).notNull()
                t.column("added_at", .text).notNull()
                t.primaryKey(["track_id", "source_id"])
            }
            try db.create(indexOn: "track_sources", columns: ["external_id"], options: .ifNotExists)

            // Last sync timestamps
            try db.create(table: "last_sync_timestamps", options: .ifNotExists) { t in
                t.column("user_id", .text).notNull()
                t.column("source", .text).notNull()
                t.column("timestamp", .text).notNull()
                t.primaryKey(["user_id", "source"])
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v3: Playlist tables (Phase 4)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v3_playlists") { db in
            try db.create(table: "playlists", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("category", .text).notNull()
                t.column("is_liked", .integer).defaults(to: 0)
                t.column("is_smart", .integer).defaults(to: 0)
                t.column("is_pinned", .integer).defaults(to: 0)
                t.column("cover_image_path", .text)
                t.column("cover_image_url", .text)
                t.column("source_id", .integer)
                    .references("sources", onDelete: .setNull)
                t.column("external_id", .text)
                t.column("date_created", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(indexOn: "playlists", columns: ["category"], options: .ifNotExists)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_name_category
                ON playlists(name, category)
            """)

            try db.create(table: "playlist_tracks", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlist_id", .integer).notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("track_id", .integer).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("position", .text).notNull()
                t.column("added_at", .text).defaults(sql: "CURRENT_TIMESTAMP")
                t.uniqueKey(["playlist_id", "track_id"])
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_playlist_position
                ON playlist_tracks(playlist_id, position)
            """)

            try db.create(table: "playlist_tags", options: .ifNotExists) { t in
                t.column("playlist_id", .integer).notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["playlist_id", "tag"])
            }
            try db.create(indexOn: "playlist_tags", columns: ["tag"], options: .ifNotExists)

            // Smart playlist views
            try db.execute(sql: """
                CREATE VIEW IF NOT EXISTS smart_playlist_recently_added AS
                SELECT id, artist, album, title, date_added, format, original_path
                FROM tracks
                WHERE date_added >= datetime('now', '-30 days')
                ORDER BY date_added DESC
            """)

            try db.execute(sql: """
                CREATE VIEW IF NOT EXISTS smart_playlist_most_played AS
                SELECT id, artist, album, title, date_added, format, original_path
                FROM tracks
                ORDER BY id DESC
                LIMIT 100
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v4: Sync profiles (Phase 5)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v4_sync_profiles") { db in
            try db.create(table: "sync_profiles", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("output_folder", .text).notNull()
                t.column("playlist_path_prefix", .text).notNull().defaults(to: "")
                t.column("date_created", .text).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("date_modified", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "sync_profile_tracks", options: .ifNotExists) { t in
                t.column("profile_id", .integer).notNull()
                    .references("sync_profiles", onDelete: .cascade)
                t.column("track_id", .integer).notNull()
                    .references("tracks", onDelete: .cascade)
                t.primaryKey(["profile_id", "track_id"])
            }
            try db.create(indexOn: "sync_profile_tracks", columns: ["profile_id"], options: .ifNotExists)

            try db.create(table: "sync_profile_playlists", options: .ifNotExists) { t in
                t.column("profile_id", .integer).notNull()
                    .references("sync_profiles", onDelete: .cascade)
                t.column("playlist_id", .integer).notNull()
                    .references("playlists", onDelete: .cascade)
                t.primaryKey(["profile_id", "playlist_id"])
            }
            try db.create(indexOn: "sync_profile_playlists", columns: ["profile_id"], options: .ifNotExists)

            try db.create(table: "sync_profile_rules", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profile_id", .integer).notNull()
                    .references("sync_profiles", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("operator", .text).notNull()
                t.column("value", .text).notNull()
            }
            try db.create(indexOn: "sync_profile_rules", columns: ["profile_id"], options: .ifNotExists)

            try db.create(table: "sync_state", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profile_id", .integer).notNull()
                    .references("sync_profiles", onDelete: .cascade)
                t.column("track_id", .integer).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("synced_checksum", .text)
                t.column("synced_size", .integer)
                t.column("synced_timestamp", .text)
                t.uniqueKey(["profile_id", "track_id"])
            }
            try db.create(indexOn: "sync_state", columns: ["profile_id"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v5: Enhancement tables (Phase 7)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v5_enhancements") { db in
            try db.create(table: "fingerprints", options: .ifNotExists) { t in
                t.primaryKey("track_id", .integer)
                    .references("tracks", onDelete: .cascade)
                t.column("fingerprint", .blob).notNull()
                t.column("duration_seconds", .integer).notNull()
                t.column("acoustid", .text)
                t.column("musicbrainz_recording_id", .text)
                t.column("fingerprinted_at", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "artwork", options: .ifNotExists) { t in
                t.primaryKey("track_id", .integer)
                    .references("tracks", onDelete: .cascade)
                t.column("artwork_path", .text)
                t.column("source", .text)
                t.column("musicbrainz_release_group_id", .text)
                t.column("resolution", .text)
                t.column("fetched_at", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "replaygain", options: .ifNotExists) { t in
                t.primaryKey("track_id", .integer)
                    .references("tracks", onDelete: .cascade)
                t.column("track_gain", .double).notNull()
                t.column("track_peak", .double).notNull()
                t.column("album_gain", .double)
                t.column("album_peak", .double)
                t.column("analyzed_at", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "review_queue", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("action_type", .text).notNull()
                t.column("track_id", .integer).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("related_track_id", .integer)
                t.column("details", .text).notNull()
                t.column("auto_action", .text)
                t.column("status", .text).defaults(to: "pending")
                t.column("created_at", .text).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("resolved_at", .text)
            }
            try db.create(indexOn: "review_queue", columns: ["status"], options: .ifNotExists)
            try db.create(indexOn: "review_queue", columns: ["action_type"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v6: App config (Phase 8)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v6_app_config") { db in
            try db.create(table: "app_config", options: .ifNotExists) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updated_at", .text).defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v7: download_status + partial index (Phase 9)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v7_download_status") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "download_status" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "download_status", .text)
                }
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_organized_path_null
                ON tracks(organized_path) WHERE organized_path IS NULL
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v8: Track analysis cache (Phase 10)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v8_track_analysis") { db in
            try db.create(table: "track_analysis", options: .ifNotExists) { t in
                t.primaryKey("track_id", .integer)
                    .references("tracks", onDelete: .cascade)
                t.column("ffprobe_output", .text)
                t.column("fingerprint", .text)
                t.column("spectrogram_path", .text)
                t.column("analysis_timestamp", .text).notNull()
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v9–v13: Data cleanup migrations
        // These are data-level fixes, not structural schema changes.
        // For a fresh macOS database, they are no-ops.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v9_null_remote_dates") { db in
            try db.execute(sql: """
                UPDATE tracks SET date_added = NULL
                WHERE organized_path IS NULL AND download_status IS NULL
            """)
        }

        migrator.registerMigration("v10_noop") { _ in
            // v10 was superseded by v11 in the Tauri app
        }

        migrator.registerMigration("v11_clear_soundcloud_for_resync") { db in
            try db.execute(sql: """
                DELETE FROM track_sources
                WHERE source_id IN (SELECT id FROM sources WHERE name = 'soundcloud')
            """)
            try db.execute(sql: """
                DELETE FROM tracks
                WHERE organized_path IS NULL AND download_status IS NULL
                  AND format = 'soundcloud'
                  AND id NOT IN (SELECT track_id FROM track_sources)
            """)
        }

        migrator.registerMigration("v12_strip_absolute_paths") { db in
            try db.execute(sql: """
                UPDATE tracks
                SET organized_path = SUBSTR(
                    organized_path,
                    LENGTH((SELECT value FROM app_config WHERE key = 'library_root')) + 2
                )
                WHERE organized_path IS NOT NULL
                  AND organized_path LIKE (SELECT value || '/%' FROM app_config WHERE key = 'library_root')
            """)
        }

        migrator.registerMigration("v13_playlist_path_prefix") { db in
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "playlist_path_prefix" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "playlist_path_prefix", .text).notNull().defaults(to: "")
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v14: LUFS loudness columns (Phase 18)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v14_lufs_columns") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "lufs_i" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "lufs_i", .double)
                }
            }
            if try !db.columns(in: "tracks").contains(where: { $0.name == "lufs_range" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "lufs_range", .double)
                }
            }
            if try !db.columns(in: "tracks").contains(where: { $0.name == "true_peak" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "true_peak", .double)
                }
            }
            if try !db.columns(in: "tracks").contains(where: { $0.name == "energy_bucket" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "energy_bucket", .integer)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v15: Track tags (Phase 20)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v15_track_tags") { db in
            try db.create(table: "track_tags", options: .ifNotExists) { t in
                t.column("track_id", .integer).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("tag_key", .text).notNull()
                t.column("tag_value", .text).notNull()
                t.primaryKey(["track_id", "tag_key", "tag_value"])
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_track_tags_key_value
                ON track_tags(tag_key, tag_value)
            """)
            try db.create(indexOn: "track_tags", columns: ["tag_key"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v16: Albums + variant prefs + tracks.album_id (Phase 21)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v16_albums") { db in
            try db.create(table: "albums", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artist", .text).notNull()
                t.column("album_artist", .text).notNull()
                t.column("title", .text).notNull()
                t.column("title_normalized", .text).notNull()
                t.column("year", .integer)
                t.column("cover_path", .text)
                t.column("variant_of", .integer)
                    .references("albums", onDelete: .setNull)
                t.column("variant_kind", .text)
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_albums_unique_stem
                ON albums(album_artist, title_normalized, COALESCE(variant_kind, ''))
            """)
            try db.create(indexOn: "albums", columns: ["variant_of"], options: .ifNotExists)
            try db.create(indexOn: "albums", columns: ["album_artist"], options: .ifNotExists)

            try db.create(table: "user_album_variant_pref", options: .ifNotExists) { t in
                t.column("user_id", .text).notNull()
                t.column("base_album_id", .integer).notNull()
                    .references("albums", onDelete: .cascade)
                t.column("selected_album_id", .integer).notNull()
                    .references("albums", onDelete: .cascade)
                t.column("updated_at", .text).notNull()
                t.primaryKey(["user_id", "base_album_id"])
            }
            try db.create(indexOn: "user_album_variant_pref", columns: ["user_id"], options: .ifNotExists)

            // Add album_id FK to tracks
            if try !db.columns(in: "tracks").contains(where: { $0.name == "album_id" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "album_id", .integer)
                        .references("albums", onDelete: .setNull)
                }
            }
            try db.create(indexOn: "tracks", columns: ["album_id"], options: .ifNotExists)

            // Backfill albums from existing tracks data
            try db.execute(sql: """
                INSERT OR IGNORE INTO albums (artist, album_artist, title, title_normalized, year)
                SELECT DISTINCT
                    artist,
                    album_artist,
                    album,
                    LOWER(REPLACE(REPLACE(REPLACE(album, ' ', ''), '-', ''), '_', '')),
                    MAX(year)
                FROM tracks
                WHERE album != ''
                GROUP BY LOWER(album_artist), LOWER(REPLACE(REPLACE(REPLACE(album, ' ', ''), '-', ''), '_', ''))
            """)

            // Link tracks to albums
            try db.execute(sql: """
                UPDATE tracks SET album_id = (
                    SELECT albums.id FROM albums
                    WHERE LOWER(albums.album_artist) = LOWER(tracks.album_artist)
                      AND albums.title_normalized = LOWER(REPLACE(REPLACE(REPLACE(tracks.album, ' ', ''), '-', ''), '_', ''))
                    LIMIT 1
                )
                WHERE album_id IS NULL AND album != ''
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v17: Album remediation (Phase 21.1)
        // Case-insensitive unique index, merge case-dupes
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v17_album_remediation") { db in
            // Replace case-sensitive index with case-insensitive one
            try db.execute(sql: "DROP INDEX IF EXISTS idx_albums_unique_stem")
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS albums_artist_stem_kind_ci
                ON albums (LOWER(album_artist), title_normalized, IFNULL(variant_kind, ''))
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration: organized_path index (Phase 30)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v_organized_path_index") { db in
            try db.create(indexOn: "tracks", columns: ["organized_path"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration: sort-column indexes for SQL-side library sort
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v_sort_indexes") { db in
            try db.create(indexOn: "tracks", columns: ["date_added"],    options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["duration"],      options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["bitrate"],       options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["year"],          options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["energy_bucket"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration: _migrations tracking table parity
        // Ensures the Tauri app's _migrations table exists for compat
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v_migrations_tracking") { db in
            try db.create(table: "_migrations", options: .ifNotExists) { t in
                t.primaryKey("version", .integer)
                t.column("name", .text).notNull()
                t.column("applied_at", .text).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        return migrator
    }
}
