import Foundation
import GRDB

/// Manages the GRDB connection pool and database migrations.
///
/// ## Database Location
///
/// Since A3 the database lives inside a library file (`<name>.mlibm/music_library.db`).
/// Before adoption it is still at the legacy location
/// `~/Library/Application Support/com.musiclibrary.app/music_library.db`.
final class DatabaseManager: Sendable {
    /// The database connection pool for concurrent reads + serialized writes.
    let pool: DatabasePool

    /// The path to the database file.
    let databasePath: URL

    /// Open the database at the legacy location (pre-A3 layout).
    convenience init() throws {
        try self.init(databaseURL: Self.legacyDatabaseURL)
    }

    /// Open the production database at `databaseURL` — a library file's database or the
    /// legacy one.
    ///
    /// Creates the database file and directory if they don't exist, enables WAL, backs up
    /// if migrations are pending, then runs all pending migrations.
    ///
    /// - Parameters:
    ///   - backupsRoot: root of the default backup folders (injected by tests).
    ///   - progress: the phases for the loading screen (`Backing up before update…`,
    ///     `Updating the library… 3 of 5`, W3-LAUNCH); reporting changes nothing that is done.
    /// - Throws: DatabaseError if the database cannot be opened or migrated
    init(
        databaseURL databasePath: URL,
        backupsRoot: URL = BackupService.defaultBackupsRoot,
        progress: LibraryOpenProgress? = nil
    ) throws {
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

        // Each step's errors carry the step (`LibraryOpenError`), so the launch failure says
        // what is true (W3-LAUNCH review S7). What each step does is unchanged.
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: databasePath.path, configuration: config)
            // Readable at all? (The backup check below reads the same thing.)
            _ = try pool.read { db in try Self.buildMigrator().appliedIdentifiers(db) }
        } catch {
            throw LibraryOpenError(stage: .opening, underlying: error)
        }
        self.pool = pool

        // Pre-migration backup: if any migrations are pending, back up before running them.
        // Failure aborts startup — migrations must never run unprotected.
        do {
            _ = try BackupService.performPreMigrationBackupIfNeeded(
                pool: pool,
                databasePath: databasePath,
                coversDirectory: Self.playlistCoversDirectory(forDatabaseAt: databasePath),
                backupsRoot: backupsRoot,
                willBackUp: progress.map { report in
                    { report(.backingUp(bytes: Self.fileSize(of: databasePath))) }
                }
            )
        } catch {
            throw LibraryOpenError(stage: .backingUp, underlying: error)
        }

        // Run all migrations (one by one when the loading screen counts them).
        do {
            try DatabaseMigrationSteps.migrate(migrator, pool, progress: progress)
        } catch {
            throw LibraryOpenError(stage: .updating, underlying: error)
        }

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
        config.foreignKeysEnabled = false

        self.pool = try DatabasePool(path: path.path, configuration: config)
        try migrator.migrate(pool)
    }

    /// Create an in-memory database for testing.
    static func inMemory() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false

        let queue = try DatabaseQueue(configuration: config)
        try Self.inMemoryMigrator.migrate(queue)
        return queue
    }

    // MARK: - Database Path

    /// Pre-A3 database location in Application Support. Only the launch resolver and the
    /// adoption of an old-style install look here.
    static var legacyDatabaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.musiclibrary.app")
        return appDir.appendingPathComponent("music_library.db")
    }

    /// Size of the database and its WAL, for `Backing up before update…` (nil if unreadable).
    static func fileSize(of databasePath: URL) -> Int64? {
        let paths = [databasePath.path, databasePath.path + "-wal"]
        let sizes = paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int64 }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    // MARK: - Playlist Covers

    /// Name of the playlist covers folder. Stored cover paths are relative to the
    /// database's folder (`playlist-covers/<id>.png`).
    static let playlistCoversFolderName = "playlist-covers"

    /// Playlist covers always live next to the database.
    static func playlistCoversDirectory(forDatabaseAt databasePath: URL) -> URL {
        databasePath.deletingLastPathComponent().appendingPathComponent(playlistCoversFolderName)
    }

    /// Covers folder of this database.
    var playlistCoversDirectory: URL {
        Self.playlistCoversDirectory(forDatabaseAt: databasePath)
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

    /// Build the migrator with all registered migrations.
    ///
    /// Internal so `BackupService` can detect pending migrations for the pre-migration hook.
    static func buildMigrator() -> DatabaseMigrator {
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

        // ──────────────────────────────────────────────────────────────
        // Migration v20: playlist cover lock flag (Phase 36)
        // Adds cover_is_custom column so PlaylistCoverService can skip
        // auto-regenerate when the user has set their own cover.
        // Registered inside buildMigrator() so both production migrator
        // and inMemoryMigrator (Self.inMemoryMigrator) pick it up.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v20_playlist_cover_custom") { db in
            if try !db.columns(in: "playlists").contains(where: { $0.name == "cover_is_custom" }) {
                try db.alter(table: "playlists") { t in
                    t.add(column: "cover_is_custom", .integer).notNull().defaults(to: 0)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v21_sync_profile_toggles: 4 toggle columns on sync_profiles (Phase 38)
        // Adds generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v21_sync_profile_toggles") { db in
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "generate_m3u8" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "generate_m3u8", .integer).notNull().defaults(to: 0)
                }
            }
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "transcode_mode" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "transcode_mode", .text).notNull().defaults(to: "keep_originals")
                }
            }
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "fat32_safe_paths" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "fat32_safe_paths", .integer).notNull().defaults(to: 1)
                }
            }
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "cleanup_removed_files" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "cleanup_removed_files", .integer).notNull().defaults(to: 1)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v_search_text_column: pre-computed normalized search
        // Enables diacritic-insensitive search (e.g. "on the line" finds "Ön Thë Linë")
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v_search_text_column") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "search_text", .text)
            }
            try db.create(indexOn: "tracks", columns: ["search_text"], options: .ifNotExists)

            let rows = try Row.fetchAll(db, sql: "SELECT id, artist, album, title FROM tracks")
            for row in rows {
                guard let rowId = row["id"] as? Int64 else { continue }
                let combined = ((row["artist"] as? String) ?? "") + " " +
                               ((row["album"] as? String) ?? "") + " " +
                               ((row["title"] as? String) ?? "")
                let normalized = Self.foldedSearchText(combined)
                try db.execute(
                    sql: "UPDATE tracks SET search_text = ? WHERE id = ?",
                    arguments: [normalized, rowId]
                )
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v_sync_toggles: Phase 38 — explicit folder/device toggles
        // Adds 4 columns to sync_profiles for D-01:
        //   generate_m3u8         — emit M3U8 playlists on sync (Rockbox)
        //   transcode_mode        — 'keep_originals' | 'aac_248' | 'aac_320'
        //   fat32_safe_paths      — apply PathSanitizer to dest paths
        //   cleanup_removed_files — actually unlink m4a files on remove
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v_sync_toggles") { db in
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "generate_m3u8" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "generate_m3u8", .integer).notNull().defaults(to: 0)
                }
            }
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "transcode_mode" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "transcode_mode", .text).notNull().defaults(to: "keep_originals")
                }
            }
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "fat32_safe_paths" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "fat32_safe_paths", .integer).notNull().defaults(to: 1)
                }
            }
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "cleanup_removed_files" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "cleanup_removed_files", .integer).notNull().defaults(to: 1)
                }
            }
        }

        migrator.registerMigration("v22_danceability") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "danceability" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "danceability", .double)
                }
            }
        }

        migrator.registerMigration("v23_playlist_format") { db in
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "playlist_format" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "playlist_format", .text).notNull().defaults(to: "rockbox")
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v24_normalize_loudness: apply EBU R128 gain on export
        // Adds normalize_loudness toggle to sync_profiles. When enabled and
        // transcoding to AAC, the measured per-track LUFS is used to bake a
        // loudness gain into the exported audio (not just RG tags) so that
        // phone players without ReplayGain support still play at even volume.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v24_normalize_loudness") { db in
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "normalize_loudness" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "normalize_loudness", .integer).notNull().defaults(to: 0)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v25_bpm: estimated tempo per track
        // Populated by DanceabilityAnalyzer alongside danceability.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v25_bpm") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "bpm" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "bpm", .integer)
                }
            }
            try db.create(indexOn: "tracks", columns: ["bpm"], options: .ifNotExists)
        }

        migrator.registerMigration("v26_enhanced_search_text") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, artist, album_artist, album, title, genre, format FROM tracks")
            for row in rows {
                guard let rowId = row["id"] as? Int64 else { continue }
                let artist = (row["artist"] as? String) ?? ""
                let albumArtist = (row["album_artist"] as? String) ?? ""
                let album = (row["album"] as? String) ?? ""
                let title = (row["title"] as? String) ?? ""
                let genre = (row["genre"] as? String) ?? ""
                let format = (row["format"] as? String) ?? ""

                let combined = "\(artist) \(albumArtist) \(album) \(title) \(genre) \(format)"
                let normalized = Self.foldedSearchText(combined)
                try db.execute(
                    sql: "UPDATE tracks SET search_text = ? WHERE id = ?",
                    arguments: [normalized, rowId]
                )
            }
        }

        migrator.registerMigration("v27_smart_embeddings") { db in
            try db.create(table: "track_embeddings", options: .ifNotExists) { t in
                t.column("track_id", .integer).primaryKey().references("tracks", column: "id", onDelete: .cascade)
                t.column("master_embedding", .blob).notNull()
                t.column("drop_offset", .double).notNull()
                t.column("mix_category", .text)
            }
            
            try db.create(table: "track_segment_embeddings", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("track_id", .integer).notNull().references("tracks", column: "id", onDelete: .cascade)
                t.column("offset_seconds", .double).notNull()
                t.column("segment_embedding", .blob).notNull()
            }
            try db.create(index: "idx_segment_track", on: "track_segment_embeddings", columns: ["track_id"], options: .ifNotExists)

            try db.create(table: "track_similarity_feedback", options: .ifNotExists) { t in
                t.column("seed_track_id", .integer).notNull().references("tracks", column: "id", onDelete: .cascade)
                t.column("target_track_id", .integer).notNull().references("tracks", column: "id", onDelete: .cascade)
                t.column("feedback_value", .integer).notNull()
                t.column("date_created", .datetime).notNull().defaults(to: Date())
                t.primaryKey(["seed_track_id", "target_track_id"])
            }
        }

        migrator.registerMigration("v28_track_discovery_log") { db in
            try db.create(table: "track_discovery_log", options: .ifNotExists) { t in
                t.column("discovered_track_id", .integer).primaryKey().references("tracks", column: "id", onDelete: .cascade)
                t.column("seed_track_id", .integer).references("tracks", column: "id", onDelete: .setNull)
                t.column("discovery_source", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "new")
                t.column("date_added", .datetime).notNull().defaults(to: Date())
            }
        }

        migrator.registerMigration("v29_genre_index") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_genre ON tracks(genre)")
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v30_date_added_library: split "added" into two dates.
        // `date_added`         → when the track was added at its REMOTE
        //                        source (e.g. liked on SoundCloud). Managed
        //                        by remote sync; drives the Remote tab order.
        // `date_added_library` → when the local file landed on disk
        //                        (download/import). Drives the Local tab
        //                        order. NULL for remote-only tracks.
        // Backfill existing local rows so their library date isn't empty.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v30_date_added_library") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "date_added_library" }) {
                try db.alter(table: "tracks") { t in
                    t.add(column: "date_added_library", .text)
                }
            }
            try db.execute(sql: """
                UPDATE tracks
                SET date_added_library = date_added
                WHERE organized_path IS NOT NULL AND date_added_library IS NULL
            """)
            try db.create(indexOn: "tracks", columns: ["date_added_library"], options: .ifNotExists)
        }

        migrator.registerMigration("v31_artwork_remote_url") { db in
            if try !db.columns(in: "artwork").contains(where: { $0.name == "remote_url" }) {
                try db.alter(table: "artwork") { table in
                    table.add(column: "remote_url", .text)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v32: structured download failure details
        // This stays additive so shared legacy Tauri databases remain safe.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v32_download_failure") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "download_failure" }) {
                try db.alter(table: "tracks") { table in
                    table.add(column: "download_failure", .text)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v33: review queue group identity
        // Shared databases may already contain pair-only review rows, so this
        // is strictly additive. Grouping is handled by the review domain.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v33_review_queue_group_key") { db in
            if try !db.columns(in: "review_queue").contains(where: { $0.name == "group_key" }) {
                try db.alter(table: "review_queue") { table in
                    table.add(column: "group_key", .text)
                }
            }
            try db.create(index: "idx_review_queue_group_key", on: "review_queue", columns: ["group_key"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v35: stable UUID identity for iOS sidecar sync
        // Adds nullable `mlm_uuid TEXT` to `tracks` and `playlists`.
        // UUIDs are lazily generated (UUIDv4 uppercase) on first sync/export
        // if unset; uniqueness enforced in code, not at the DB level.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v35_mlm_uuid") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "mlm_uuid" }) {
                try db.alter(table: "tracks") { table in
                    table.add(column: "mlm_uuid", .text)
                }
            }
            if try !db.columns(in: "playlists").contains(where: { $0.name == "mlm_uuid" }) {
                try db.alter(table: "playlists") { table in
                    table.add(column: "mlm_uuid", .text)
                }
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v36: playlist sync snapshots for iOS ingest diff (WP3)
        // Stores the last-exported (or last-applied) ordered track list per
        // (profile, playlist) so PlaylistIngestService can compute a 3-way
        // diff (added / removed / reordered) against an incoming m3u8.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v36_playlist_sync_snapshots") { db in
            try db.create(table: "playlist_sync_snapshots", options: .ifNotExists) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("profile_id", .integer).notNull()
                table.column("playlist_id", .integer).notNull()
                table.column("playlist_uuid", .text)
                table.column("snapshot_json", .text).notNull()
                table.column("written_at", .datetime).notNull().defaults(to: Date())
            }
            try db.create(
                index: "idx_pss_profile_playlist",
                on: "playlist_sync_snapshots",
                columns: ["profile_id", "playlist_id"],
                options: .ifNotExists
            )
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v37_artwork_mode: per-profile artwork resize (WP-B)
        // Adds artwork_mode TEXT to sync_profiles. When set to 'resize_250'
        // AAC transcode downscales embedded cover art to fit a 250×250 box
        // for low-RAM players (e.g. iPod Video 5th gen running Rockbox).
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v37_artwork_mode") { db in
            if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "artwork_mode" }) {
                try db.alter(table: "sync_profiles") { t in
                    t.add(column: "artwork_mode", .text).notNull().defaults(to: "keep_original")
                }
            }
        }

        // Reels are a resumable identification queue. This table is isolated
        // from tracks because importing a video must not create a music row.
        migrator.registerMigration("v34_imported_reels") { db in
            try db.create(table: "imported_reels", options: .ifNotExists) { table in
                table.column("id", .text).primaryKey()
                table.column("file_path", .text).notNull().unique()
                table.column("title", .text).notNull().defaults(to: "")
                table.column("artist", .text).notNull().defaults(to: "")
                table.column("created_at", .datetime).notNull().defaults(to: Date())
                table.column("updated_at", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_imported_reels_updated_at", on: "imported_reels", columns: ["updated_at"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v38_track_index_hygiene: remove vestigial duplicate
        // indexes left by the dropped Tauri predecessor and add missing
        // indexes for SortColumn.danceability and SortColumn.format.
        // Keeps idx_tracks_genre (only index on genre) and
        // idx_organized_path_null (partial index, not a duplicate).
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v38_track_index_hygiene") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_title")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_album")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_artist")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_album_id")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_duplicate")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_variant_of")
            try db.create(indexOn: "tracks", columns: ["danceability"], options: .ifNotExists)
            try db.create(indexOn: "tracks", columns: ["format"], options: .ifNotExists)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v39_sync_orphan_cleanup: remove child rows whose
        // profile_id references a deleted sync_profile. These orphans
        // accumulated because foreign-key enforcement was disabled on
        // every connection, leaving ON DELETE CASCADE inert.
        // Also cleans playlist_sync_snapshots (no FK declared but
        // treated as profile-scoped by SyncRepository.delete).
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v39_sync_orphan_cleanup") { db in
            let tables = [
                "sync_state",
                "sync_profile_tracks",
                "sync_profile_playlists",
                "sync_profile_rules",
                "playlist_sync_snapshots",
            ]
            var totalDeleted: Int = 0
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table) WHERE profile_id NOT IN (SELECT id FROM sync_profiles)")
                let changes = db.changesCount
                totalDeleted += changes
            }
            if totalDeleted > 0 {
                AppLogger.shared.info("v39_sync_orphan_cleanup: removed \(totalDeleted) orphan sync rows", source: "Database")
            }
        }

        // Foreign keys remain disabled for shared-database compatibility.
        // Remove historical children that were left behind before repositories
        // began applying their own transactional cascades.
        migrator.registerMigration("v40_track_playlist_orphan_cleanup") { db in
            let trackTables = [
                "track_sources", "playlist_tracks", "sync_profile_tracks", "sync_state",
                "fingerprints", "artwork", "replaygain", "track_analysis", "track_tags",
                "review_queue", "track_embeddings", "track_segment_embeddings",
            ]
            for table in trackTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE track_id NOT IN (SELECT id FROM tracks)")
            }
            try db.execute(sql: """
                DELETE FROM track_similarity_feedback
                WHERE seed_track_id NOT IN (SELECT id FROM tracks)
                   OR target_track_id NOT IN (SELECT id FROM tracks)
            """)
            // track_discovery_log has no `track_id` column: a discovered row is
            // deleted when its discovered track is gone, and its seed reference
            // is nulled when the seed track is gone (mirrors TrackRepository.delete).
            try db.execute(sql: "DELETE FROM track_discovery_log WHERE discovered_track_id NOT IN (SELECT id FROM tracks)")
            try db.execute(sql: "UPDATE track_discovery_log SET seed_track_id = NULL WHERE seed_track_id NOT IN (SELECT id FROM tracks)")
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id NOT IN (SELECT id FROM playlists)")
            try db.execute(sql: "DELETE FROM playlist_tags WHERE playlist_id NOT IN (SELECT id FROM playlists)")
            try db.execute(sql: "DELETE FROM sync_profile_playlists WHERE playlist_id NOT IN (SELECT id FROM playlists)")
            try db.execute(sql: "DELETE FROM playlist_sync_snapshots WHERE playlist_id NOT IN (SELECT id FROM playlists)")
        }

        // A remote provider's external ID identifies exactly one linked track.
        // Merge legacy duplicates into the oldest row before applying the
        // unique index, including membership/reference rows that otherwise
        // would be orphaned with foreign keys disabled.
        migrator.registerMigration("v41_remote_provider_identity") { db in
            try db.execute(sql: """
                CREATE TEMP TABLE remote_track_duplicates AS
                SELECT duplicate_id, MIN(canonical_id) AS canonical_id FROM (
                    SELECT
                        track_id AS duplicate_id,
                        MIN(track_id) OVER (
                            PARTITION BY source_id, external_id
                        ) AS canonical_id
                    FROM track_sources
                )
                WHERE duplicate_id != canonical_id
                GROUP BY duplicate_id
            """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position, added_at)
                SELECT pt.playlist_id, d.canonical_id, pt.position, pt.added_at
                FROM playlist_tracks pt
                INNER JOIN remote_track_duplicates d ON d.duplicate_id = pt.track_id
            """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO sync_profile_tracks (profile_id, track_id)
                SELECT spt.profile_id, d.canonical_id
                FROM sync_profile_tracks spt
                INNER JOIN remote_track_duplicates d ON d.duplicate_id = spt.track_id
            """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                SELECT ss.profile_id, d.canonical_id, ss.synced_checksum, ss.synced_size, ss.synced_timestamp
                FROM sync_state ss
                INNER JOIN remote_track_duplicates d ON d.duplicate_id = ss.track_id
            """)
            for table in [
                "fingerprints", "artwork", "replaygain", "track_analysis",
                "track_embeddings", "track_segment_embeddings", "track_tags",
            ] {
                try db.execute(sql: """
                    UPDATE OR IGNORE \(table)
                    SET track_id = (
                        SELECT canonical_id FROM remote_track_duplicates
                        WHERE duplicate_id = \(table).track_id
                    )
                    WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)
                """)
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at)
                SELECT d.canonical_id, ts.source_id, ts.external_id, ts.added_at
                FROM track_sources ts
                INNER JOIN remote_track_duplicates d ON d.duplicate_id = ts.track_id
            """)
            try db.execute(sql: """
                UPDATE track_discovery_log
                SET seed_track_id = (
                    SELECT canonical_id FROM remote_track_duplicates
                    WHERE duplicate_id = track_discovery_log.seed_track_id
                )
                WHERE seed_track_id IN (SELECT duplicate_id FROM remote_track_duplicates)
            """)
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM sync_profile_tracks WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM sync_state WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_sources WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM fingerprints WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM artwork WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM replaygain WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_analysis WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_embeddings WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_segment_embeddings WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_tags WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM review_queue WHERE track_id IN (SELECT duplicate_id FROM remote_track_duplicates) OR related_track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_similarity_feedback WHERE seed_track_id IN (SELECT duplicate_id FROM remote_track_duplicates) OR target_track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM track_discovery_log WHERE discovered_track_id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: "DELETE FROM tracks WHERE id IN (SELECT duplicate_id FROM remote_track_duplicates)")
            try db.execute(sql: """
                DELETE FROM track_sources
                WHERE rowid NOT IN (
                    SELECT MIN(rowid)
                    FROM track_sources
                    GROUP BY source_id, external_id
                )
            """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_track_sources_provider_identity
                ON track_sources(source_id, external_id)
            """)
            try db.execute(sql: "DROP TABLE remote_track_duplicates")
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v42_track_availability (W2-A, UC-TABLE-20, DEC-014):
        // persisted file presence, so no row ever probes the disk.
        // `file_missing_since` = ISO 8601 time a reconciliation (or a
        // use-time miss) found the file absent *while the library folder
        // was reachable*. NULL = present / never found missing.
        // Backfill: none — every existing row starts as present; nothing is
        // ever flagged missing because the drive is away.
        // The partial index serves the File missing scope and its count.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v42_track_availability") { db in
            if try !db.columns(in: "tracks").contains(where: { $0.name == "file_missing_since" }) {
                try db.alter(table: "tracks") { table in
                    table.add(column: "file_missing_since", .text)
                }
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_tracks_file_missing_since
                ON tracks(file_missing_since)
                WHERE file_missing_since IS NOT NULL
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v44_pending_tag_writes (W2-E, THOUGHTS §10 Q7, UC-JOB-10):
        // tag edits are written to the audio files by default; while the
        // library folder is unreachable (or a file is missing) the write
        // waits here. One row per track = "this track's file tags are stale
        // since ‹stale_since› for these fields"; the write always takes the
        // track's *current* database values. `revision` is bumped by every
        // new edit, so a write only clears the row it read. `blocked` = the
        // last failure won't go away by retrying (unsupported format, a
        // rewrite that couldn't be verified) until the next edit.
        // No foreign key (foreign keys stay disabled); orphans are removed by
        // `TrackTagRepository.removeOrphanedPendingWrites` before each flush.
        // (v43 is reserved for W2-D; numbers need not be contiguous.)
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v44_pending_tag_writes") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pending_tag_writes (
                    track_id INTEGER PRIMARY KEY NOT NULL,
                    fields TEXT NOT NULL,
                    stale_since TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT,
                    last_error TEXT,
                    blocked INTEGER NOT NULL DEFAULT 0
                )
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v53_tag_write_originals (W2-E review B1): what each file
        // should carry per field, so a file only ever receives a value the
        // user typed or — on undo — the exact value it had before MLM's
        // first write. `intent` 'typed' (typed_value, NULL = cleared) or
        // 'original'; `original_state` 'unknown' (not captured yet),
        // 'absent' or 'present' (original_value). Captured from the file
        // itself right before MLM's first write of that field. Never derived
        // from an import-normalised column. No foreign key (foreign keys
        // stay disabled); orphans go with `removeOrphanedPendingWrites`.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v53_tag_write_originals") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tag_write_fields (
                    track_id INTEGER NOT NULL,
                    field TEXT NOT NULL,
                    intent TEXT NOT NULL,
                    typed_value TEXT,
                    original_state TEXT NOT NULL DEFAULT 'unknown',
                    original_value TEXT,
                    original_captured_at TEXT,
                    PRIMARY KEY (track_id, field)
                )
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v43_playback_queue (W2-D, UC-TRAIL-05, DEC-006): the
        // queue survives quitting — "MLM reopens with this queue, paused."
        // Registered after v53 (numbers are reserved, not ordered; GRDB runs
        // in registration order). Kept in the library's own database, so each
        // library has its own queue.
        // `playback_queue_entries`: one row per queued item; `lane` is
        // 'play_next' · 'context' · 'cycle' (Repeat All pass) · 'history';
        // `position` orders a lane; `entry_id` (UUID) is the entry's own
        // identity — the same track can be queued twice. No foreign key
        // (foreign keys stay disabled): `PlaybackQueueRepository` removes the
        // entries of deleted tracks and cleans up orphans on load.
        // `playback_queue_state`: one row (id = 1) — the playing entry, its
        // position in seconds, the context's origin (JSON), saved_at.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v43_playback_queue") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playback_queue_entries (
                    lane TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    entry_id TEXT NOT NULL,
                    track_id INTEGER NOT NULL,
                    PRIMARY KEY (lane, position)
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_playback_queue_entries_track
                ON playback_queue_entries(track_id)
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playback_queue_state (
                    id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                    current_entry_id TEXT,
                    position REAL NOT NULL DEFAULT 0,
                    origin TEXT,
                    saved_at TEXT NOT NULL
                )
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v46_activity_operations (W3-ACT, DEC-044, UC-JOB-02):
        // finished / failed / cancelled Activity operations of this library
        // and their results (counts, failures grouped by cause, per-item
        // outcomes as one JSON column), kept across relaunch. Retention: the
        // last 200 finished operations or 30 days, whichever is smaller;
        // undismissed failures stay until dismissed or fixed. Running rows
        // are closed as interrupted at the next launch. Per-track failure
        // state stays in `tracks.download_failure`. No foreign keys (they
        // stay disabled): missing subjects are flagged by
        // `ActivityOperationRepository.markMissingSubjects`.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v46_activity_operations") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS activity_operations (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    subject_kind TEXT NOT NULL DEFAULT 'none',
                    subject_id INTEGER,
                    subject_name TEXT,
                    subject_detail TEXT,
                    subject_track_ids TEXT,
                    subject_missing INTEGER NOT NULL DEFAULT 0,
                    state TEXT NOT NULL,
                    is_automatic INTEGER NOT NULL DEFAULT 0,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    result TEXT,
                    needs_attention INTEGER NOT NULL DEFAULT 0,
                    dismissed_at TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_activity_operations_ended_at
                    ON activity_operations(ended_at);
                CREATE INDEX IF NOT EXISTS idx_activity_operations_attention
                    ON activity_operations(needs_attention) WHERE needs_attention = 1;
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v45_playlist_folders (W3-PL, DEC-003, UC-SIDE-08):
        // playlist folders and the user's own playlist order. Registered
        // after v46 (numbers are reserved, not ordered).
        // `playlist_folders`: one row per folder; `parent_id` is reserved
        // (folders hold playlists only — one level, enforced by
        // `PlaylistFolderRepository`), `position` orders folders together
        // with the top-level playlists. Expanded/collapsed is UI state
        // (UserDefaults per library), not stored here.
        // `playlists.folder_id` (NULL = top level) and `playlists.position`
        // (fractional index, like `playlist_tracks.position`).
        // Backfill: every playlist gets a position in the order the sidebar
        // showed until now (`is_pinned DESC, name`, then id), so nothing
        // visibly reorders; `is_pinned` itself is left untouched (DEC-003
        // retires pinning; columns are never dropped). No foreign keys
        // (they stay disabled): a folder's deletion moves its playlists to
        // the top level in code, and readers treat a dangling `folder_id`
        // as the top level.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v45_playlist_folders") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist_folders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    parent_id INTEGER,
                    position TEXT,
                    date_created TEXT DEFAULT CURRENT_TIMESTAMP
                )
            """)
            let columns = try db.columns(in: "playlists").map(\.name)
            if !columns.contains("folder_id") {
                try db.alter(table: "playlists") { table in table.add(column: "folder_id", .integer) }
            }
            if !columns.contains("position") {
                try db.alter(table: "playlists") { table in table.add(column: "position", .text) }
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_playlists_folder_position
                ON playlists(folder_id, position)
            """)
            // Only rows without a position (idempotent: a re-run or a hand-made column keeps
            // what is already placed), after any that already have one.
            let unplaced = try Int64.fetchAll(db, sql: """
                SELECT id FROM playlists WHERE position IS NULL
                ORDER BY COALESCE(is_pinned, 0) DESC, name, id
            """)
            let placedTail = try String.fetchOne(db, sql: """
                SELECT MAX(position) FROM playlists WHERE position IS NOT NULL AND folder_id IS NULL
            """)
            let keys = Self.v45BackfillKeys(count: unplaced.count, after: placedTail)
            for (id, key) in zip(unplaced, keys) {
                try db.execute(sql: "UPDATE playlists SET position = ? WHERE id = ?", arguments: [key, id])
            }
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v47_sync_profile_results (W3-SYNC, DEC-027, PP-SYNC-02):
        // the last sync of each profile, kept across relaunch and never
        // shared between profiles. One row per profile (`profile_id` is the
        // key; a new run replaces the row, Retry Failed updates it).
        // `outcome`: running · interrupted (the device was removed; the run
        // waits and resumes copying only what is missing) · completed ·
        // cancelled · failed. `planned_count` = files the run had to copy,
        // `copied_count` = copied so far (written while running, so a
        // removal or a quit leaves an honest `‹n› of ‹m› copied`).
        // `failures` / `skipped`: JSON arrays with per-track reason (and the
        // device path for failures); `plan_summary`: JSON of the plan the run
        // started from. `last_connected_at`: when the destination was last
        // seen connected (header `Not connected · last connected ‹date›`).
        // No backfill (the old results lived only in memory). No foreign
        // keys (they stay disabled): `SyncRepository.delete` removes the row.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v47_sync_profile_results") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_profile_results (
                    profile_id INTEGER PRIMARY KEY NOT NULL,
                    started_at TEXT,
                    ended_at TEXT,
                    outcome TEXT NOT NULL DEFAULT 'none',
                    planned_count INTEGER NOT NULL DEFAULT 0,
                    copied_count INTEGER NOT NULL DEFAULT 0,
                    removed_count INTEGER NOT NULL DEFAULT 0,
                    failed_count INTEGER NOT NULL DEFAULT 0,
                    skipped_count INTEGER NOT NULL DEFAULT 0,
                    failures TEXT,
                    skipped TEXT,
                    plan_summary TEXT,
                    failure_cause TEXT,
                    operation_id TEXT,
                    last_interrupted_at TEXT,
                    last_connected_at TEXT
                )
            """)
        }

        // ──────────────────────────────────────────────────────────────
        // Migration v48_review_decisions (W3-REV, DEC-028, DEC-041, PP-SOURCES-01):
        // sticky Review decisions. `review_decisions` holds one live row per
        // decided group (`group_key`; Restore deletes it): what was decided
        // (`decision`), which version was kept, what happened to the others
        // (`unkept_mode`: hidden · trash) and the exact consequences as JSON
        // (flags, playlist and sync rows that were re-pointed or dropped, files
        // moved to the Trash with their Trash URL, tag values before a merge)
        // so Undo and Restore can put everything back. `review_decided_pairs`
        // holds every unordered pair of track ids (`track_a < track_b`) a
        // decision covers: a rescan proposes a group only while it has an
        // undecided pair. No backfill (earlier decisions never recorded
        // their consequences; their Restore stays disabled). No foreign keys:
        // `TrackRepository.delete` removes a deleted track's pairs and
        // `ReviewDecisionRepository` removes a decision's pairs.
        // ──────────────────────────────────────────────────────────────
        migrator.registerMigration("v48_review_decisions") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS review_decisions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    group_key TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    kept_track_id INTEGER,
                    unkept_mode TEXT,
                    consequences_json TEXT NOT NULL,
                    decided_at TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS review_decided_pairs (
                    track_a INTEGER NOT NULL,
                    track_b INTEGER NOT NULL,
                    decision_id INTEGER NOT NULL,
                    PRIMARY KEY (track_a, track_b)
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_review_decided_pairs_decision
                ON review_decided_pairs(decision_id)
            """)
        }

        return migrator
    }

    // MARK: - v45 backfill keys (frozen with the migration)

    /// `count` ascending position keys for the v45 backfill: `a` + base-62 digits, evenly spread
    /// (the same keys `FractionalIndexer.evenlySpaced` makes today — copied so a later change of
    /// the indexer never changes what this migration writes). After `tail` when some rows were
    /// already placed.
    static func v45BackfillKeys(count: Int, after tail: String?) -> [String] {
        guard count > 0 else { return [] }
        let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var width = 2
        var capacity = digits.count * digits.count
        while capacity <= count {
            width += 1
            capacity *= digits.count
        }
        let step = capacity / (count + 1)
        return (1...count).map { index in
            var value = index * step
            var key = [Character](repeating: digits[0], count: width)
            for slot in stride(from: width - 1, through: 0, by: -1) {
                key[slot] = digits[value % digits.count]
                value /= digits.count
            }
            let spaced = "a" + String(key)
            return tail.map { "\($0)|\(spaced)" } ?? spaced
        }
    }

    // MARK: - Search Text Folding

    static func foldedSearchText(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
