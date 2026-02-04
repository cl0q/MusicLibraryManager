//! Device synchronization module.
//!
//! Handles synchronization profiles, transcode caching, device filesystem operations,
//! and M3U8 playlist generation for Rockbox-enabled devices.
//!
//! Module organization:
//! - `profile` - Sync profile management and content resolution
//! - `cache` - Transcode cache management (Plan 05-02: Complete)
//! - `device` - Rockbox device detection and filesystem operations (Plan 05-03: Complete)
//! - `playlist_gen` - M3U8 playlist file generation (Plan 05-03: Complete)
//! - `progress` - Sync progress tracking and incremental sync (Plan 05-04: Complete)

use anyhow::Result;
use rusqlite::Connection;
use std::path::PathBuf;

pub mod cache;
pub mod device;
pub mod playlist_gen;
pub mod profile;
pub mod progress;

// Public exports
pub use cache::TranscodeCache;
pub use device::{RockboxDevice, detect_rockbox_devices, get_available_space};
pub use playlist_gen::{generate_m3u8, write_playlist_file, write_profile_playlist};
pub use profile::SyncProfile;
pub use progress::{SyncPreview, SyncResult, compute_sync_preview, execute_sync};

/// Preview what would be synced without performing actual operations.
///
/// Computes files to add, remove, and space requirements for dry-run mode.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile to preview
/// * `cache_dir` - Path to transcode cache directory
/// * `device_space` - Available space on device (None for local-only)
///
/// # Returns
/// * `Ok(SyncPreview)` with detailed preview information
/// * `Err` if profile not found or database operation fails
pub fn preview_sync(
    conn: &Connection,
    profile_id: i64,
    cache_dir: PathBuf,
    device_space: Option<u64>,
) -> Result<SyncPreview> {
    let profile = profile::get_sync_profile(conn, profile_id)?;
    let cache = TranscodeCache::new(cache_dir)?;

    progress::compute_sync_preview(conn, &profile, &cache, device_space)
}

/// Execute full sync: files + playlists.
///
/// Performs complete sync workflow:
/// 1. Computes preview of changes
/// 2. Executes file sync (links from cache to profile folder)
/// 3. Generates M3U8 playlists for all playlists in profile
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile to execute
/// * `cache_dir` - Path to transcode cache directory
///
/// # Returns
/// * `Ok(SyncResult)` with counts of successful and failed operations
/// * `Err` if profile not found, insufficient space, or sync operation fails
pub fn sync_profile_to_folder(
    conn: &Connection,
    profile_id: i64,
    cache_dir: PathBuf,
) -> Result<SyncResult> {
    let profile = profile::get_sync_profile(conn, profile_id)?;
    let cache = TranscodeCache::new(cache_dir)?;

    // 1. Compute preview
    let preview = progress::compute_sync_preview(conn, &profile, &cache, None)?;

    // 2. Execute file sync
    let result = progress::execute_sync(conn, &profile, &cache, &preview)?;

    // 3. Generate M3U8 playlists for profile
    sync_playlists(conn, &profile)?;

    Ok(result)
}

/// Generate M3U8 playlists for all playlists in profile.
///
/// Queries sync_profile_playlists to get playlist IDs, then generates
/// M3U8 files in profile_folder/Playlists/ directory.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile` - Sync profile with playlists to generate
///
/// # Returns
/// * `Ok(())` if all playlists generated successfully
/// * `Err` if database query or file write fails
fn sync_playlists(conn: &Connection, profile: &SyncProfile) -> Result<()> {
    // Query sync_profile_playlists to get playlist IDs
    let mut stmt = conn.prepare(
        "SELECT playlist_id FROM sync_profile_playlists WHERE profile_id = ?",
    )?;

    let playlist_ids: Vec<i64> = stmt
        .query_map([profile.id], |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<i64>>>()?;

    for playlist_id in playlist_ids {
        // Get playlist details
        let mut stmt = conn.prepare(
            "SELECT name FROM playlists WHERE id = ?",
        )?;
        let playlist_name: String = stmt.query_row([playlist_id], |row| row.get(0))?;

        // Get tracks in playlist
        let tracks = crate::database::playlist::get_playlist_tracks(conn, playlist_id)?;

        // Generate M3U8
        playlist_gen::write_profile_playlist(
            &profile.output_folder,
            &playlist_name,
            &tracks,
        )?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::{connection::get_memory_connection, schema::initialize_schema};
    use crate::sync::profile::{add_manual_track, add_playlist, create_sync_profile};
    use std::fs;
    use tempfile::TempDir;

    fn create_test_track(conn: &Connection, title: &str) -> i64 {
        let path = format!("/test/{}.flac", title.replace(" ", "_"));
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", title, "flac", path],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    #[test]
    fn test_preview_sync_returns_accurate_counts() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();
        let temp_dir = TempDir::new().unwrap();

        // Create profile
        let profile_id = create_sync_profile(
            &conn,
            "Test".to_string(),
            temp_dir.path().join("profile"),
        )
        .unwrap();

        // Add tracks to profile
        let track1_id = create_test_track(&conn, "Track 1");
        let track2_id = create_test_track(&conn, "Track 2");
        add_manual_track(&conn, profile_id, track1_id).unwrap();
        add_manual_track(&conn, profile_id, track2_id).unwrap();

        // Create cache with files
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();
        let cache1 = cache.get_cache_path(track1_id, std::path::Path::new("/test/Track_1.flac"));
        let cache2 = cache.get_cache_path(track2_id, std::path::Path::new("/test/Track_2.flac"));
        fs::write(&cache1, b"audio 1").unwrap();
        fs::write(&cache2, b"audio 2").unwrap();

        // Preview sync
        let preview = preview_sync(&conn, profile_id, cache_dir, Some(100_000_000)).unwrap();

        // Should show 2 files to add
        assert_eq!(preview.files_to_add.len(), 2);
        assert_eq!(preview.files_to_remove.len(), 0);
        assert!(preview.has_sufficient_space);
    }

    #[test]
    fn test_sync_profile_to_folder_complete_workflow() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();
        let temp_dir = TempDir::new().unwrap();

        // Create profile
        let profile_id = create_sync_profile(
            &conn,
            "Test".to_string(),
            temp_dir.path().join("profile"),
        )
        .unwrap();

        // Create playlist
        conn.execute(
            "INSERT INTO playlists (name, category) VALUES (?, ?)",
            rusqlite::params!["Test Playlist", "regular"],
        )
        .unwrap();
        let playlist_id = conn.last_insert_rowid();

        // Add tracks
        let track1_id = create_test_track(&conn, "Track 1");
        let track2_id = create_test_track(&conn, "Track 2");

        // Add tracks to playlist
        conn.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
            rusqlite::params![playlist_id, track1_id, "a0"],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
            rusqlite::params![playlist_id, track2_id, "a1"],
        )
        .unwrap();

        // Add playlist to profile
        add_playlist(&conn, profile_id, playlist_id).unwrap();

        // Create cache with files
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();
        let cache1 = cache.get_cache_path(track1_id, std::path::Path::new("/test/Track_1.flac"));
        let cache2 = cache.get_cache_path(track2_id, std::path::Path::new("/test/Track_2.flac"));
        fs::write(&cache1, b"audio 1").unwrap();
        fs::write(&cache2, b"audio 2").unwrap();

        // Execute sync
        let result = sync_profile_to_folder(&conn, profile_id, cache_dir).unwrap();

        // Verify files synced
        assert_eq!(result.synced_count, 2);
        assert_eq!(result.failed_count, 0);

        // Verify M3U8 playlist created
        let playlists_dir = temp_dir.path().join("profile").join("Playlists");
        assert!(playlists_dir.exists());

        let playlist_file = playlists_dir.join("Test Playlist.m3u8");
        assert!(playlist_file.exists());

        // Verify M3U8 content
        let content = fs::read_to_string(&playlist_file).unwrap();
        assert!(content.starts_with("#EXTM3U"));
        assert!(content.contains("Track 1"));
        assert!(content.contains("Track 2"));
    }
}

