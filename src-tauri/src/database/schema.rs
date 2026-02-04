//! Database schema definitions for the music library.
//!
//! Defines the SQL schema for tracks table and provides initialization functions.
//! Supports schema versioning via PRAGMA user_version for safe migrations.

use rusqlite::Connection;

use crate::database::connection::Result;

/// Current schema version.
/// - Version 0: Initial state (no schema)
/// - Version 1: Phase 1 schema (tracks table)
/// - Version 2: Phase 3 schema (sources, track_sources, last_sync_timestamps, variant_of)
/// - Version 3: Phase 4 schema (playlists, playlist_tracks, playlist_tags)
/// - Version 4: Phase 5 schema (sync_profiles, sync_profile_tracks, sync_profile_playlists, sync_profile_rules, sync_state)
pub const CURRENT_SCHEMA_VERSION: i32 = 4;

/// SQL schema for the music library database (Phase 1 - base schema).
///
/// Contains:
/// - `tracks` table with all metadata fields (reference-in-place model)
/// - Indexes on artist, album, title, and is_duplicate for query performance
pub const SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    artist TEXT NOT NULL,
    album_artist TEXT NOT NULL,
    album TEXT NOT NULL,
    title TEXT NOT NULL,
    genre TEXT,
    year INTEGER,
    bitrate INTEGER,
    duration INTEGER,
    format TEXT NOT NULL,
    original_path TEXT NOT NULL UNIQUE,
    organized_path TEXT,
    is_duplicate INTEGER DEFAULT 0,
    date_added TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_artist ON tracks(artist);
CREATE INDEX IF NOT EXISTS idx_album ON tracks(album);
CREATE INDEX IF NOT EXISTS idx_title ON tracks(title);
CREATE INDEX IF NOT EXISTS idx_duplicate ON tracks(is_duplicate);
";

/// SQL schema for Phase 3 multi-source aggregation tables.
///
/// Contains:
/// - `sources` table: Track available music sources (Spotify, SoundCloud)
/// - `track_sources` table: Many-to-many relationship between tracks and sources
/// - `last_sync_timestamps` table: Track last sync time per source per user
pub const PHASE3_SCHEMA_SQL: &str = "
-- Sources table: Track available music sources (Spotify, SoundCloud)
CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,              -- 'spotify' | 'soundcloud'
    user_id TEXT NOT NULL,           -- User identifier for this source
    enabled INTEGER DEFAULT 1,       -- 1 = active, 0 = disabled
    UNIQUE(name, user_id)
);

-- Track sources table: Many-to-many relationship between tracks and sources
-- source_id determines download priority (CONTEXT.md decision)
CREATE TABLE IF NOT EXISTS track_sources (
    track_id INTEGER NOT NULL,
    source_id INTEGER NOT NULL,
    external_id TEXT NOT NULL,       -- Source's ID for this track (Spotify URI, SoundCloud ID)
    added_at TEXT NOT NULL,          -- When track was added to source (ISO 8601)
    PRIMARY KEY (track_id, source_id),
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_external_id ON track_sources(external_id);

-- Last sync timestamps table: Track last sync time per source per user
CREATE TABLE IF NOT EXISTS last_sync_timestamps (
    user_id TEXT NOT NULL,
    source TEXT NOT NULL,            -- 'spotify' | 'soundcloud'
    timestamp TEXT NOT NULL,         -- ISO 8601 datetime
    PRIMARY KEY (user_id, source)
);
";

/// SQL schema for Phase 4 playlist management tables.
///
/// Contains:
/// - `playlists` table: User-created and synced playlists with categorization
/// - `playlist_tracks` table: Track membership in playlists with fractional indexing for ordering
/// - `playlist_tags` table: Flexible tagging system for playlist organization
pub const PHASE4_SCHEMA_SQL: &str = "
-- Playlists table: User-created and synced playlists
CREATE TABLE IF NOT EXISTS playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    category TEXT NOT NULL,          -- 'liked' | 'smart' | 'regular'
    is_liked INTEGER DEFAULT 0,      -- 1 if this is the Liked Songs playlist
    is_smart INTEGER DEFAULT 0,      -- 1 if this is a smart playlist with rules
    is_pinned INTEGER DEFAULT 0,     -- 1 if pinned to top of UI
    cover_image_path TEXT,           -- Local cover image path
    cover_image_url TEXT,            -- Remote cover image URL
    source_id INTEGER,               -- FK to sources.id if synced from external source
    external_id TEXT,                -- External playlist ID if mirrored from source
    date_created TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_playlist_category ON playlists(category);

-- Playlist tracks table: Track membership with fractional indexing
CREATE TABLE IF NOT EXISTS playlist_tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    position TEXT NOT NULL,          -- Fractional index for stable ordering
    added_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(playlist_id, track_id),   -- Prevent duplicate track references
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_playlist_position ON playlist_tracks(playlist_id, position);

-- Playlist tags table: Flexible tagging for organization
CREATE TABLE IF NOT EXISTS playlist_tags (
    playlist_id INTEGER NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (playlist_id, tag),
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tag ON playlist_tags(tag);

-- Smart playlist views for auto-generated playlists

-- Recently Added: tracks added in last 30 days, sorted newest first
CREATE VIEW IF NOT EXISTS smart_playlist_recently_added AS
SELECT id, artist, album, title, date_added
FROM tracks
WHERE date_added >= datetime('now', '-30 days')
ORDER BY date_added DESC;

-- Most Played: top 100 tracks by play count (populated in Phase 5 via Rockbox stats)
-- Note: track_stats table will be added in Phase 5; using placeholder view for now
CREATE VIEW IF NOT EXISTS smart_playlist_most_played AS
SELECT id, artist, album, title, 0 AS play_count
FROM tracks
ORDER BY id DESC
LIMIT 100;
";

/// SQL schema for Phase 5 device sync tables.
///
/// Contains:
/// - `sync_profiles` table: Device sync profiles with custom names and output folders
/// - `sync_profile_tracks` table: Manually added tracks to profiles
/// - `sync_profile_playlists` table: Entire playlists added to profiles
/// - `sync_profile_rules` table: Query rules for dynamic track selection
/// - `sync_state` table: Incremental sync state tracking per profile
pub const PHASE5_SCHEMA_SQL: &str = "
-- Sync profiles table: Device sync profiles with custom names
CREATE TABLE IF NOT EXISTS sync_profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,           -- Profile display name (e.g., 'iPod Classic', 'iPhone')
    output_folder TEXT NOT NULL,         -- Local staging folder path
    date_created TEXT DEFAULT CURRENT_TIMESTAMP,
    date_modified TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Sync profile tracks table: Manually added individual tracks
CREATE TABLE IF NOT EXISTS sync_profile_tracks (
    profile_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    PRIMARY KEY (profile_id, track_id),
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_profile_tracks_profile ON sync_profile_tracks(profile_id);

-- Sync profile playlists table: Include all tracks from selected playlists
CREATE TABLE IF NOT EXISTS sync_profile_playlists (
    profile_id INTEGER NOT NULL,
    playlist_id INTEGER NOT NULL,
    PRIMARY KEY (profile_id, playlist_id),
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_profile_playlists_profile ON sync_profile_playlists(profile_id);

-- Sync profile rules table: Query-based track selection
CREATE TABLE IF NOT EXISTS sync_profile_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id INTEGER NOT NULL,
    field TEXT NOT NULL,                 -- 'genre' | 'source' | 'date_added' | 'artist' | 'bitrate' | 'tag'
    operator TEXT NOT NULL,              -- 'eq' | 'ne' | 'gt' | 'lt' | 'contains' | 'in'
    value TEXT NOT NULL,                 -- Filter value
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_profile_rules_profile ON sync_profile_rules(profile_id);

-- Sync state table: Incremental sync state tracking
CREATE TABLE IF NOT EXISTS sync_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    synced_checksum TEXT,                -- SHA256 of transcoded file at sync time
    synced_size INTEGER,                 -- File size in bytes
    synced_timestamp TEXT,               -- ISO 8601 timestamp
    UNIQUE(profile_id, track_id),
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_state_profile ON sync_state(profile_id);
";

/// Get the current schema version from the database.
pub fn get_schema_version(conn: &Connection) -> Result<i32> {
    let version: i32 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    Ok(version)
}

/// Set the schema version in the database.
fn set_schema_version(conn: &Connection, version: i32) -> Result<()> {
    conn.execute_batch(&format!("PRAGMA user_version = {}", version))?;
    Ok(())
}

/// Check if a column exists in a table.
fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", table))?;
    let columns: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(|r| r.ok())
        .collect();
    Ok(columns.contains(&column.to_string()))
}

/// Run Phase 3 migrations: add variant_of column and create new tables.
fn migrate_to_v2(conn: &Connection) -> Result<()> {
    // Add variant_of column to tracks table if it doesn't exist
    if !column_exists(conn, "tracks", "variant_of")? {
        conn.execute_batch(
            "ALTER TABLE tracks ADD COLUMN variant_of INTEGER REFERENCES tracks(id) ON DELETE SET NULL;"
        )?;
    }

    // Create index on variant_of if it doesn't exist
    conn.execute_batch("CREATE INDEX IF NOT EXISTS idx_variant_of ON tracks(variant_of);")?;

    // Create Phase 3 tables (IF NOT EXISTS makes this safe to re-run)
    conn.execute_batch(PHASE3_SCHEMA_SQL)?;

    Ok(())
}

/// Run Phase 4 migrations: create playlist management tables.
fn migrate_to_v3(conn: &Connection) -> Result<()> {
    // Create Phase 4 tables (IF NOT EXISTS makes this safe to re-run)
    conn.execute_batch(PHASE4_SCHEMA_SQL)?;
    Ok(())
}

/// Run Phase 5 migrations: create device sync tables.
fn migrate_to_v4(conn: &Connection) -> Result<()> {
    // Create Phase 5 tables (IF NOT EXISTS makes this safe to re-run)
    conn.execute_batch(PHASE5_SCHEMA_SQL)?;
    Ok(())
}

/// Initialize the database schema with versioned migrations.
///
/// Creates all tables and indexes, applying migrations as needed.
/// Safe to call multiple times (idempotent via version tracking).
///
/// # Arguments
/// * `conn` - An open database connection
///
/// # Returns
/// * `Ok(())` if schema was created/migrated successfully
/// * `Err(DatabaseError)` if schema creation failed
pub fn initialize_schema(conn: &Connection) -> Result<()> {
    let current_version = get_schema_version(conn)?;

    // Apply base schema (Phase 1)
    conn.execute_batch(SCHEMA_SQL)?;

    // If this is a fresh database, set version to 1
    if current_version == 0 {
        set_schema_version(conn, 1)?;
    }

    // Apply Phase 3 migrations if needed
    if get_schema_version(conn)? < 2 {
        migrate_to_v2(conn)?;
        set_schema_version(conn, 2)?;
    }

    // Apply Phase 4 migrations if needed
    if get_schema_version(conn)? < 3 {
        migrate_to_v3(conn)?;
        set_schema_version(conn, 3)?;
    }

    // Apply Phase 5 migrations if needed
    if get_schema_version(conn)? < 4 {
        migrate_to_v4(conn)?;
        set_schema_version(conn, 4)?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn table_exists(conn: &Connection, name: &str) -> bool {
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                [name],
                |row| row.get(0),
            )
            .unwrap();
        count == 1
    }

    fn index_exists(conn: &Connection, name: &str) -> bool {
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?",
                [name],
                |row| row.get(0),
            )
            .unwrap();
        count == 1
    }

    #[test]
    fn test_schema_creates_tracks_table() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        assert!(table_exists(&conn, "tracks"));
    }

    #[test]
    fn test_schema_creates_indexes() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Verify Phase 1 indexes exist
        assert!(index_exists(&conn, "idx_artist"));
        assert!(index_exists(&conn, "idx_album"));
        assert!(index_exists(&conn, "idx_title"));
        assert!(index_exists(&conn, "idx_duplicate"));

        // Verify Phase 3 indexes exist
        assert!(index_exists(&conn, "idx_variant_of"));
        assert!(index_exists(&conn, "idx_external_id"));
    }

    #[test]
    fn test_schema_idempotent() {
        let conn = Connection::open_in_memory().unwrap();

        // Should be safe to call multiple times
        initialize_schema(&conn).unwrap();
        initialize_schema(&conn).unwrap();

        assert!(table_exists(&conn, "tracks"));
        assert_eq!(get_schema_version(&conn).unwrap(), CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn test_schema_version_tracking() {
        let conn = Connection::open_in_memory().unwrap();

        // Fresh database starts at version 0
        assert_eq!(get_schema_version(&conn).unwrap(), 0);

        initialize_schema(&conn).unwrap();

        // After initialization, should be at current version
        assert_eq!(get_schema_version(&conn).unwrap(), CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn test_phase3_sources_table() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        assert!(table_exists(&conn, "sources"));

        // Verify we can insert into sources
        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES (?, ?, ?)",
            ["spotify", "user123", "1"],
        )
        .unwrap();

        // Verify unique constraint on (name, user_id)
        let result = conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES (?, ?, ?)",
            ["spotify", "user123", "1"],
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_phase3_track_sources_table() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        assert!(table_exists(&conn, "track_sources"));

        // Insert a track and source first (for foreign key)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path) VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3"],
        ).unwrap();

        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES (?, ?, ?)",
            ["spotify", "user123", "1"],
        )
        .unwrap();

        // Now insert track_source relationship
        conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, ?)",
            ["1", "1", "spotify:track:abc123", "2026-02-03T12:00:00Z"],
        )
        .unwrap();

        // Verify composite primary key prevents duplicates
        let result = conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, ?)",
            ["1", "1", "spotify:track:xyz789", "2026-02-03T13:00:00Z"],
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_phase3_last_sync_timestamps_table() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        assert!(table_exists(&conn, "last_sync_timestamps"));

        // Insert a timestamp
        conn.execute(
            "INSERT INTO last_sync_timestamps (user_id, source, timestamp) VALUES (?, ?, ?)",
            ["user123", "spotify", "2026-02-03T12:00:00Z"],
        )
        .unwrap();

        // Verify composite primary key on (user_id, source)
        let result = conn.execute(
            "INSERT INTO last_sync_timestamps (user_id, source, timestamp) VALUES (?, ?, ?)",
            ["user123", "spotify", "2026-02-03T13:00:00Z"],
        );
        assert!(result.is_err());

        // But different source should work
        conn.execute(
            "INSERT INTO last_sync_timestamps (user_id, source, timestamp) VALUES (?, ?, ?)",
            ["user123", "soundcloud", "2026-02-03T12:00:00Z"],
        )
        .unwrap();
    }

    #[test]
    fn test_phase3_variant_of_column() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Verify variant_of column exists
        assert!(column_exists(&conn, "tracks", "variant_of").unwrap());

        // Insert original track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path) VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/original.mp3"],
        ).unwrap();

        // Insert variant with reference to original
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, variant_of) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track (Remix)", "mp3", "/path/to/remix.mp3", "1"],
        ).unwrap();

        // Verify the relationship
        let variant_of: Option<i64> = conn
            .query_row(
                "SELECT variant_of FROM tracks WHERE title = 'Track (Remix)'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(variant_of, Some(1));
    }

    #[test]
    fn test_track_sources_cascade_delete() {
        let conn = Connection::open_in_memory().unwrap();
        // Enable foreign keys for this test
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        initialize_schema(&conn).unwrap();

        // Insert track, source, and relationship
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path) VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3"],
        ).unwrap();

        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES (?, ?, ?)",
            ["spotify", "user123", "1"],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, ?)",
            ["1", "1", "spotify:track:abc123", "2026-02-03T12:00:00Z"],
        )
        .unwrap();

        // Delete the track
        conn.execute("DELETE FROM tracks WHERE id = 1", []).unwrap();

        // Verify track_source was also deleted (CASCADE)
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM track_sources WHERE track_id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn test_migration_from_v1_to_v2() {
        let conn = Connection::open_in_memory().unwrap();

        // Simulate a v1 database (only base schema)
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch("PRAGMA user_version = 1;").unwrap();

        // Insert some data before migration
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path) VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3"],
        ).unwrap();

        // Now run full initialization (should migrate)
        initialize_schema(&conn).unwrap();

        // Verify migration happened
        assert_eq!(get_schema_version(&conn).unwrap(), CURRENT_SCHEMA_VERSION);

        // Verify new tables exist
        assert!(table_exists(&conn, "sources"));
        assert!(table_exists(&conn, "track_sources"));
        assert!(table_exists(&conn, "last_sync_timestamps"));

        // Verify variant_of column was added
        assert!(column_exists(&conn, "tracks", "variant_of").unwrap());

        // Verify existing data is preserved
        let title: String = conn
            .query_row("SELECT title FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert_eq!(title, "Track");
    }
}
