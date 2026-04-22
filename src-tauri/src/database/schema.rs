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
/// - Version 5: Phase 7 schema (fingerprints, artwork, replaygain, review_queue)
/// - Version 6: Phase 8 schema (app_config table for library configuration)
/// - Version 7: Phase 9 schema (download_status column, idx_organized_path_null index)
/// - Version 8: Phase 10 schema (track_analysis table for caching ffprobe/fingerprint/spectrogram data)
/// - Version 9: Phase 11 fix (NULL out date_added for remote undownloaded tracks)
/// - Version 10: Backfill date_added from track_sources.added_at for remote tracks
/// - Version 11: Delete SoundCloud phantom tracks for clean re-sync with correct liked-at ordering
/// - Version 12: Strip absolute library root prefix from organized_path (enforce relative-only invariant)
/// - Version 13: Add playlist_path_prefix to sync_profiles
/// - Version 14: Phase 18 loudness columns (lufs_i, lufs_range, true_peak, energy_bucket) on tracks
pub const CURRENT_SCHEMA_VERSION: i32 = 14;

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
CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_name_category ON playlists(name, category);

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
SELECT id, artist, album, title, date_added, format, original_path
FROM tracks
WHERE date_added >= datetime('now', '-30 days')
ORDER BY date_added DESC;

-- Most Played: top 100 tracks by play count (populated in Phase 5 via Rockbox stats)
-- Note: track_stats table will be added in Phase 5; using placeholder view for now
CREATE VIEW IF NOT EXISTS smart_playlist_most_played AS
SELECT id, artist, album, title, date_added, format, original_path
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

/// SQL schema for Phase 7 enhancements tables.
///
/// Contains:
/// - `fingerprints` table: Audio fingerprints for acoustic identification
/// - `artwork` table: Album/track artwork metadata and paths
/// - `replaygain` table: ReplayGain loudness normalization data
/// - `review_queue` table: User review queue for duplicate detection and metadata conflicts
pub const PHASE7_SCHEMA_SQL: &str = "
-- Fingerprints table: Audio fingerprints for acoustic identification
CREATE TABLE IF NOT EXISTS fingerprints (
    track_id INTEGER PRIMARY KEY,
    fingerprint BLOB NOT NULL,               -- Chromaprint raw fingerprint data
    duration_seconds INTEGER NOT NULL,       -- Track duration for fingerprint validation
    acoustid TEXT,                           -- AcoustID from MusicBrainz lookup
    musicbrainz_recording_id TEXT,           -- MusicBrainz recording ID from AcoustID
    fingerprinted_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- Artwork table: Album/track artwork metadata
CREATE TABLE IF NOT EXISTS artwork (
    track_id INTEGER PRIMARY KEY,
    artwork_path TEXT,                       -- Local path to artwork file
    source TEXT,                             -- 'embedded' | 'musicbrainz' | 'manual'
    musicbrainz_release_group_id TEXT,       -- MusicBrainz release group ID
    resolution TEXT,                         -- Image dimensions (e.g., '500x500')
    fetched_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- ReplayGain table: Loudness normalization data
CREATE TABLE IF NOT EXISTS replaygain (
    track_id INTEGER PRIMARY KEY,
    track_gain REAL NOT NULL,                -- Track gain in dB
    track_peak REAL NOT NULL,                -- Track peak amplitude (0.0-1.0)
    album_gain REAL,                         -- Album gain in dB (NULL if not analyzed)
    album_peak REAL,                         -- Album peak amplitude (NULL if not analyzed)
    analyzed_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- Review queue table: User review queue for conflicts and duplicates
CREATE TABLE IF NOT EXISTS review_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action_type TEXT NOT NULL,               -- 'duplicate' | 'metadata_conflict' | 'missing_artwork'
    track_id INTEGER NOT NULL,
    related_track_id INTEGER,                -- For duplicate actions: the other track
    details TEXT NOT NULL,                   -- JSON details for the review action
    auto_action TEXT,                        -- Suggested automatic action
    status TEXT DEFAULT 'pending',           -- 'pending' | 'resolved' | 'dismissed'
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    resolved_at TEXT,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- Indexes for review queue queries
CREATE INDEX IF NOT EXISTS idx_review_status ON review_queue(status);
CREATE INDEX IF NOT EXISTS idx_review_type ON review_queue(action_type);
";

/// SQL schema for Phase 8 library configuration table.
///
/// Contains:
/// - `app_config` table: Key-value configuration storage for library settings
pub const PHASE8_SCHEMA_SQL: &str = "
-- App configuration table: Key-value configuration storage
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
";

/// SQL schema for Phase 9 library/remote separation.
///
/// Contains:
/// - Adds download_status column to tracks table (NULL for never-downloaded, ISO 8601 timestamp when downloaded)
/// - Creates partial index idx_organized_path_null for remote view query optimization
pub const PHASE9_SCHEMA_SQL: &str = "
-- Partial index on organized_path IS NULL for remote tracks query optimization
CREATE INDEX IF NOT EXISTS idx_organized_path_null ON tracks(organized_path) WHERE organized_path IS NULL;
";

/// SQL schema for Phase 10 track analysis.
///
/// Contains:
/// - `track_analysis` table: Cache for ffprobe metadata, fingerprints, and spectrogram paths
pub const PHASE10_SCHEMA_SQL: &str = "
-- Track analysis table: Cache for technical metadata and analysis data
CREATE TABLE IF NOT EXISTS track_analysis (
    track_id INTEGER PRIMARY KEY,
    ffprobe_output TEXT,                     -- FFprobe JSON output
    fingerprint TEXT,                         -- Acoustic fingerprint (future use)
    spectrogram_path TEXT,                    -- Path to generated spectrogram image
    analysis_timestamp TEXT NOT NULL,         -- ISO 8601 timestamp of last analysis
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
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

/// Run Phase 7 migrations: create enhancements tables.
fn migrate_to_v5(conn: &Connection) -> Result<()> {
    // Create Phase 7 tables (IF NOT EXISTS makes this safe to re-run)
    conn.execute_batch(PHASE7_SCHEMA_SQL)?;
    Ok(())
}

/// Run Phase 8 migrations: create app configuration table.
fn migrate_to_v6(conn: &Connection) -> Result<()> {
    // Create Phase 8 tables (IF NOT EXISTS makes this safe to re-run)
    conn.execute_batch(PHASE8_SCHEMA_SQL)?;
    Ok(())
}

/// Run Phase 9 migrations: add download_status column and create partial index.
fn migrate_to_v7(conn: &Connection) -> Result<()> {
    // Add download_status column to tracks table if it doesn't exist
    // NULL = local import or not-yet-downloaded remote track
    // ISO 8601 timestamp = when streaming track was downloaded (for audit/tracking)
    if !column_exists(conn, "tracks", "download_status")? {
        conn.execute_batch(
            "ALTER TABLE tracks ADD COLUMN download_status TEXT;"
        )?;
    }

    // Create partial index for remote tracks query optimization
    conn.execute_batch(PHASE9_SCHEMA_SQL)?;

    Ok(())
}

/// Run Phase 10 migrations: create track_analysis table.
fn migrate_to_v8(conn: &Connection) -> Result<()> {
    // Create Phase 10 tables (IF NOT EXISTS makes this safe to re-run)
    conn.execute_batch(PHASE10_SCHEMA_SQL)?;
    Ok(())
}

/// Run Phase 11 fix migration: NULL out date_added for remote undownloaded tracks.
///
/// Remote tracks (synced from Spotify/SoundCloud but not downloaded) should show "-"
/// for date_added. Only downloaded tracks should have a date_added value.
fn migrate_to_v9(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "UPDATE tracks SET date_added = NULL WHERE organized_path IS NULL AND download_status IS NULL;"
    )?;
    Ok(())
}

/// Delete remote SoundCloud tracks so next sync re-creates them with correct liked-at ordering.
///
/// The v1 API only returns tracks in liked-at order without timestamps, so track_sources.added_at
/// previously stored the upload date (wrong). Deleting forces a clean re-sync.
fn migrate_to_v11(conn: &Connection) -> Result<()> {
    // Delete track_sources for soundcloud tracks, then delete orphaned phantom tracks
    conn.execute_batch(
        "DELETE FROM track_sources WHERE source_id IN (SELECT id FROM sources WHERE name = 'soundcloud');
         DELETE FROM tracks WHERE organized_path IS NULL AND download_status IS NULL
           AND format = 'soundcloud'
           AND id NOT IN (SELECT track_id FROM track_sources);"
    )?;
    Ok(())
}

/// Migration v12: Strip absolute library root prefix from organized_path values.
///
/// Affects tracks where organized_path starts with the library root path stored in app_config.
/// Example: '/Volumes/Lexxar/Music/00_Artists/track.m4a' -> '00_Artists/track.m4a'
///
/// The LENGTH(...) + 2 formula: root_len + 1 to skip the trailing '/' + 1 because SUBSTR is
/// 1-indexed. So for root '/Volumes/Lexxar/Music' (22 chars), SUBSTR starts at position 24,
/// yielding the string after '/Volumes/Lexxar/Music/'.
///
/// No-op if app_config table doesn't exist or has no library_root key.
fn migrate_to_v12(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "UPDATE tracks
         SET organized_path = SUBSTR(
             organized_path,
             LENGTH((SELECT value FROM app_config WHERE key = 'library_root')) + 2
         )
         WHERE organized_path IS NOT NULL
           AND organized_path LIKE (SELECT value || '/%' FROM app_config WHERE key = 'library_root');"
    )?;
    Ok(())
}

/// Migration v13: Add playlist_path_prefix to sync_profiles.
///
/// Allows per-profile path prefix for m3u8 playlist entries (e.g. "HDD0/" for Rockbox).
fn migrate_to_v13(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "ALTER TABLE sync_profiles ADD COLUMN playlist_path_prefix TEXT NOT NULL DEFAULT '';"
    )?;
    Ok(())
}

/// Migration v14 (Phase 18): Add loudness + energy columns to tracks.
///
/// - `lufs_i` REAL: EBU R128 integrated loudness (negative dBFS, e.g. -14.2).
/// - `lufs_range` REAL: Loudness range (LU).
/// - `true_peak` REAL: True peak in dBFS (e.g. -0.3).
/// - `energy_bucket` INTEGER: Derived 1..5 bucket (LUFS-I + spectral centroid).
///
/// All nullable — NULL means "not yet analyzed". Backfill via
/// `analyze_loudness_all` Tauri command.
fn migrate_to_v14(conn: &Connection) -> Result<()> {
    if !column_exists(conn, "tracks", "lufs_i")? {
        conn.execute_batch("ALTER TABLE tracks ADD COLUMN lufs_i REAL;")?;
    }
    if !column_exists(conn, "tracks", "lufs_range")? {
        conn.execute_batch("ALTER TABLE tracks ADD COLUMN lufs_range REAL;")?;
    }
    if !column_exists(conn, "tracks", "true_peak")? {
        conn.execute_batch("ALTER TABLE tracks ADD COLUMN true_peak REAL;")?;
    }
    if !column_exists(conn, "tracks", "energy_bucket")? {
        conn.execute_batch("ALTER TABLE tracks ADD COLUMN energy_bucket INTEGER;")?;
    }
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

    // Apply Phase 7 migrations if needed
    if get_schema_version(conn)? < 5 {
        migrate_to_v5(conn)?;
        set_schema_version(conn, 5)?;
    }

    // Apply Phase 8 migrations if needed
    if get_schema_version(conn)? < 6 {
        migrate_to_v6(conn)?;
        set_schema_version(conn, 6)?;
    }

    // Apply Phase 9 migrations if needed
    if get_schema_version(conn)? < 7 {
        migrate_to_v7(conn)?;
        set_schema_version(conn, 7)?;
    }

    // Apply Phase 10 migrations if needed
    if get_schema_version(conn)? < 8 {
        migrate_to_v8(conn)?;
        set_schema_version(conn, 8)?;
    }

    // Apply Phase 11 fix migrations if needed
    if get_schema_version(conn)? < 9 {
        migrate_to_v9(conn)?;
        set_schema_version(conn, 9)?;
    }

    // Backfill date_added from track_sources.added_at for remote tracks (now superseded by v11)
    if get_schema_version(conn)? < 10 {
        // v10 is now a no-op; v11 does the proper cleanup
        set_schema_version(conn, 10)?;
    }

    // Delete SoundCloud phantom tracks for clean re-sync with correct liked-at ordering
    if get_schema_version(conn)? < 11 {
        migrate_to_v11(conn)?;
        set_schema_version(conn, 11)?;
    }

    // Strip absolute library root prefix from organized_path (enforce relative-only invariant)
    if get_schema_version(conn)? < 12 {
        migrate_to_v12(conn)?;
        set_schema_version(conn, 12)?;
    }

    // Add playlist_path_prefix to sync_profiles
    if get_schema_version(conn)? < 13 {
        migrate_to_v13(conn)?;
        set_schema_version(conn, 13)?;
    }

    // Phase 18: loudness + energy columns on tracks
    if get_schema_version(conn)? < 14 {
        migrate_to_v14(conn)?;
        set_schema_version(conn, 14)?;
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

    #[test]
    fn test_phase7_tables_exist() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Verify Phase 7 tables exist
        assert!(table_exists(&conn, "fingerprints"));
        assert!(table_exists(&conn, "artwork"));
        assert!(table_exists(&conn, "replaygain"));
        assert!(table_exists(&conn, "review_queue"));
    }

    #[test]
    fn test_migration_from_v4_to_v5() {
        let conn = Connection::open_in_memory().unwrap();

        // Simulate a v4 database (Phase 1-5 schemas)
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(PHASE3_SCHEMA_SQL).unwrap();
        conn.execute_batch(PHASE4_SCHEMA_SQL).unwrap();
        conn.execute_batch(PHASE5_SCHEMA_SQL).unwrap();
        conn.execute_batch("PRAGMA user_version = 4;").unwrap();

        // Verify we're at v4
        assert_eq!(get_schema_version(&conn).unwrap(), 4);

        // Now run full initialization (should migrate to current version)
        initialize_schema(&conn).unwrap();

        // Verify migration happened to current version
        assert_eq!(get_schema_version(&conn).unwrap(), CURRENT_SCHEMA_VERSION);

        // Verify Phase 7 tables exist
        assert!(table_exists(&conn, "fingerprints"));
        assert!(table_exists(&conn, "artwork"));
        assert!(table_exists(&conn, "replaygain"));
        assert!(table_exists(&conn, "review_queue"));

        // Verify Phase 8 tables exist
        assert!(table_exists(&conn, "app_config"));
    }

    #[test]
    fn test_review_queue_indexes() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Verify review queue indexes exist
        assert!(index_exists(&conn, "idx_review_status"));
        assert!(index_exists(&conn, "idx_review_type"));
    }

    #[test]
    fn test_schema_v12_strips_absolute_organized_paths() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Set library root in app_config
        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value) VALUES ('library_root', '/Volumes/Lexxar/Music')",
            [],
        ).unwrap();

        // Insert a track with an absolute organized_path (simulating the bug)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            rusqlite::params![
                "Artist", "Artist", "Album", "Track", "aac",
                "/original/path.mp3",
                "/Volumes/Lexxar/Music/00_Artists/Artist/Album/track.m4a"
            ],
        ).unwrap();

        // Also insert a track that is already relative (should be untouched)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            rusqlite::params![
                "Artist2", "Artist2", "Album2", "Track2", "aac",
                "/original/path2.mp3",
                "00_Artists/Artist2/Album2/track2.m4a"
            ],
        ).unwrap();

        // Run migration directly
        migrate_to_v12(&conn).unwrap();

        // Absolute path should now be relative
        let org_path: String = conn
            .query_row("SELECT organized_path FROM tracks WHERE title = 'Track'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(org_path, "00_Artists/Artist/Album/track.m4a");

        // Already-relative path should be unchanged
        let org_path2: String = conn
            .query_row("SELECT organized_path FROM tracks WHERE title = 'Track2'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(org_path2, "00_Artists/Artist2/Album2/track2.m4a");
    }

    #[test]
    fn test_schema_v12_is_applied_in_initialize() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();
        assert_eq!(get_schema_version(&conn).unwrap(), CURRENT_SCHEMA_VERSION);
        assert_eq!(CURRENT_SCHEMA_VERSION, 14);
    }

    #[test]
    fn test_phase18_loudness_columns_exist() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        assert!(column_exists(&conn, "tracks", "lufs_i").unwrap());
        assert!(column_exists(&conn, "tracks", "lufs_range").unwrap());
        assert!(column_exists(&conn, "tracks", "true_peak").unwrap());
        assert!(column_exists(&conn, "tracks", "energy_bucket").unwrap());

        // All nullable — insert a track without any loudness values and verify
        // the columns round-trip as NULL.
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "T", "flac", "/p.flac"],
        ).unwrap();

        let (lufs, lra, peak, energy): (Option<f64>, Option<f64>, Option<f64>, Option<i64>) = conn
            .query_row(
                "SELECT lufs_i, lufs_range, true_peak, energy_bucket FROM tracks LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert!(lufs.is_none() && lra.is_none() && peak.is_none() && energy.is_none());
    }

    #[test]
    fn test_phase9_download_status_column() {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Verify download_status column exists
        assert!(column_exists(&conn, "tracks", "download_status").unwrap());

        // Verify partial index for remote tracks exists
        assert!(index_exists(&conn, "idx_organized_path_null"));

        // Insert test track and verify column is accessible
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, download_status) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3", "2026-02-07T12:00:00Z"],
        ).unwrap();

        let download_status: Option<String> = conn
            .query_row(
                "SELECT download_status FROM tracks WHERE title = 'Track'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(download_status, Some("2026-02-07T12:00:00Z".to_string()));

        // Verify existing data is preserved during migration (simulate v6 -> v7)
        // The test above implicitly verifies this since initialize_schema applies all migrations
    }
}

