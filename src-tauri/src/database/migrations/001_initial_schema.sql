-- Migration 001: Initial schema (consolidates all tables through schema v13)
--
-- This is the complete database schema for a brand-new database.
-- Existing databases (PRAGMA user_version >= 13) skip this migration
-- since the schema is already up to date.

--------------------------------------------------------------------------------
-- Phase 1: Core tracks table
--------------------------------------------------------------------------------

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
    date_added TEXT DEFAULT CURRENT_TIMESTAMP,
    variant_of INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    download_status TEXT
);

CREATE INDEX IF NOT EXISTS idx_artist ON tracks(artist);
CREATE INDEX IF NOT EXISTS idx_album ON tracks(album);
CREATE INDEX IF NOT EXISTS idx_title ON tracks(title);
CREATE INDEX IF NOT EXISTS idx_duplicate ON tracks(is_duplicate);
CREATE INDEX IF NOT EXISTS idx_variant_of ON tracks(variant_of);
CREATE INDEX IF NOT EXISTS idx_organized_path_null ON tracks(organized_path) WHERE organized_path IS NULL;

--------------------------------------------------------------------------------
-- Phase 3: Multi-source aggregation
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    user_id TEXT NOT NULL,
    enabled INTEGER DEFAULT 1,
    UNIQUE(name, user_id)
);

CREATE TABLE IF NOT EXISTS track_sources (
    track_id INTEGER NOT NULL,
    source_id INTEGER NOT NULL,
    external_id TEXT NOT NULL,
    added_at TEXT NOT NULL,
    PRIMARY KEY (track_id, source_id),
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_external_id ON track_sources(external_id);

CREATE TABLE IF NOT EXISTS last_sync_timestamps (
    user_id TEXT NOT NULL,
    source TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    PRIMARY KEY (user_id, source)
);

--------------------------------------------------------------------------------
-- Phase 4: Playlist management
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    category TEXT NOT NULL,
    is_liked INTEGER DEFAULT 0,
    is_smart INTEGER DEFAULT 0,
    is_pinned INTEGER DEFAULT 0,
    cover_image_path TEXT,
    cover_image_url TEXT,
    source_id INTEGER,
    external_id TEXT,
    date_created TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_playlist_category ON playlists(category);
CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_name_category ON playlists(name, category);

CREATE TABLE IF NOT EXISTS playlist_tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    position TEXT NOT NULL,
    added_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(playlist_id, track_id),
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_playlist_position ON playlist_tracks(playlist_id, position);

CREATE TABLE IF NOT EXISTS playlist_tags (
    playlist_id INTEGER NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (playlist_id, tag),
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tag ON playlist_tags(tag);

-- Smart playlist views
CREATE VIEW IF NOT EXISTS smart_playlist_recently_added AS
SELECT id, artist, album, title, date_added, format, original_path
FROM tracks
WHERE date_added >= datetime('now', '-30 days')
ORDER BY date_added DESC;

CREATE VIEW IF NOT EXISTS smart_playlist_most_played AS
SELECT id, artist, album, title, date_added, format, original_path
FROM tracks
ORDER BY id DESC
LIMIT 100;

--------------------------------------------------------------------------------
-- Phase 5: Device sync
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sync_profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    output_folder TEXT NOT NULL,
    playlist_path_prefix TEXT NOT NULL DEFAULT '',
    date_created TEXT DEFAULT CURRENT_TIMESTAMP,
    date_modified TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sync_profile_tracks (
    profile_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    PRIMARY KEY (profile_id, track_id),
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_profile_tracks_profile ON sync_profile_tracks(profile_id);

CREATE TABLE IF NOT EXISTS sync_profile_playlists (
    profile_id INTEGER NOT NULL,
    playlist_id INTEGER NOT NULL,
    PRIMARY KEY (profile_id, playlist_id),
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_profile_playlists_profile ON sync_profile_playlists(profile_id);

CREATE TABLE IF NOT EXISTS sync_profile_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id INTEGER NOT NULL,
    field TEXT NOT NULL,
    operator TEXT NOT NULL,
    value TEXT NOT NULL,
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_profile_rules_profile ON sync_profile_rules(profile_id);

CREATE TABLE IF NOT EXISTS sync_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    synced_checksum TEXT,
    synced_size INTEGER,
    synced_timestamp TEXT,
    UNIQUE(profile_id, track_id),
    FOREIGN KEY (profile_id) REFERENCES sync_profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sync_state_profile ON sync_state(profile_id);

--------------------------------------------------------------------------------
-- Phase 7: Enhancements (fingerprints, artwork, replaygain, review queue)
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS fingerprints (
    track_id INTEGER PRIMARY KEY,
    fingerprint BLOB NOT NULL,
    duration_seconds INTEGER NOT NULL,
    acoustid TEXT,
    musicbrainz_recording_id TEXT,
    fingerprinted_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS artwork (
    track_id INTEGER PRIMARY KEY,
    artwork_path TEXT,
    source TEXT,
    musicbrainz_release_group_id TEXT,
    resolution TEXT,
    fetched_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS replaygain (
    track_id INTEGER PRIMARY KEY,
    track_gain REAL NOT NULL,
    track_peak REAL NOT NULL,
    album_gain REAL,
    album_peak REAL,
    analyzed_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS review_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action_type TEXT NOT NULL,
    track_id INTEGER NOT NULL,
    related_track_id INTEGER,
    details TEXT NOT NULL,
    auto_action TEXT,
    status TEXT DEFAULT 'pending',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    resolved_at TEXT,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_review_status ON review_queue(status);
CREATE INDEX IF NOT EXISTS idx_review_type ON review_queue(action_type);

--------------------------------------------------------------------------------
-- Phase 8: App configuration
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);

--------------------------------------------------------------------------------
-- Phase 10: Track analysis cache
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS track_analysis (
    track_id INTEGER PRIMARY KEY,
    ffprobe_output TEXT,
    fingerprint TEXT,
    spectrogram_path TEXT,
    analysis_timestamp TEXT NOT NULL,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
