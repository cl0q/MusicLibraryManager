//! Sync progress tracking and incremental sync logic.
//!
//! Provides:
//! - Sync preview computation (dry-run before actual sync)
//! - Incremental sync execution (only new/changed files)
//! - Sync state persistence for resumption
//! - Space validation with safety buffer

use std::collections::HashSet;
use std::path::Path;

use anyhow::{bail, Context, Result};
use rusqlite::Connection;
use serde::Serialize;

use crate::models::track::{Track, TrackMetadata};
use crate::sync::cache::TranscodeCache;
use crate::sync::profile::SyncProfile;

/// Preview of what would be synced without performing actual operations.
///
/// Used for dry-run mode to show user what will happen before committing.
#[derive(Debug, Serialize)]
pub struct SyncPreview {
    pub files_to_add: Vec<FilePreview>,
    pub files_to_remove: Vec<String>,
    pub total_new_size: u64,
    pub total_remove_size: u64,
    pub device_available_space: Option<u64>,
    pub has_sufficient_space: bool,
}

/// Preview information for a single file to be synced.
#[derive(Debug, Serialize)]
pub struct FilePreview {
    pub track_id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub size: u64,
    pub destination_path: String,
}

/// Result of a sync operation.
#[derive(Debug, Serialize)]
pub struct SyncResult {
    pub synced_count: usize,
    pub failed_count: usize,
    pub failed_tracks: Vec<(i64, String)>,
}

/// Compute preview of what would be synced.
///
/// Compares current profile content against sync_state to determine:
/// - Files to add (in profile but not synced, or checksum changed)
/// - Files to remove (synced but no longer in profile)
/// - Space requirements and validation
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile` - Sync profile to preview
/// * `cache` - Transcode cache for file lookups
/// * `device_space` - Available space on device (None for local-only profiles)
///
/// # Returns
/// * `Ok(SyncPreview)` with detailed preview information
/// * `Err` if database query or file access fails
pub fn compute_sync_preview(
    conn: &Connection,
    profile: &SyncProfile,
    cache: &TranscodeCache,
    device_space: Option<u64>,
) -> Result<SyncPreview> {
    // 1. Get all track IDs in profile via profile.get_all_track_ids()
    let profile_track_ids = profile.get_all_track_ids(conn)?;

    // 2. Get currently synced tracks from sync_state table
    let synced_tracks = get_synced_tracks(conn, profile.id)?;

    // 3. Compute files to add (in profile but not synced, or checksum changed)
    let mut files_to_add = Vec::new();
    let mut total_new_size = 0u64;

    for track_id in &profile_track_ids {
        // Check if already synced with same checksum
        if needs_sync(conn, profile.id, *track_id, cache)? {
            let track = get_track(conn, *track_id)?;
            let cache_path = cache.get_cache_path(*track_id, Path::new(&track.metadata.original_path));

            if cache_path.exists() {
                let size = std::fs::metadata(&cache_path)?.len();
                let dest_path = cache.build_profile_path(&profile.output_folder, &track)?;

                files_to_add.push(FilePreview {
                    track_id: *track_id,
                    title: track.metadata.title.clone(),
                    artist: track.metadata.artist.clone(),
                    album: track.metadata.album.clone(),
                    size,
                    destination_path: dest_path.display().to_string(),
                });

                total_new_size += size;
            }
        }
    }

    // 4. Compute files to remove (synced but no longer in profile)
    let to_remove: HashSet<_> = synced_tracks.difference(&profile_track_ids).collect();
    let mut files_to_remove = Vec::new();
    let mut total_remove_size = 0u64;

    for track_id in to_remove {
        if let Ok(track) = get_track(conn, *track_id) {
            let relative_path = format!(
                "{}/{}/{}.m4a",
                track.metadata.album_artist,
                track.metadata.album,
                track.metadata.title
            );
            files_to_remove.push(relative_path);

            // Estimate size from sync_state if available
            if let Ok(size) = get_synced_file_size(conn, profile.id, *track_id) {
                total_remove_size += size;
            } else {
                // Rough estimate if not in sync_state
                total_remove_size += 5_000_000; // 5MB average
            }
        }
    }

    // 5. Space validation: require 50MB buffer over needed space
    let has_sufficient_space = if let Some(available) = device_space {
        let needed = total_new_size.saturating_sub(total_remove_size);
        available >= needed + 50_000_000 // Require 50MB buffer
    } else {
        true // Local-only, assume sufficient
    };

    Ok(SyncPreview {
        files_to_add,
        files_to_remove,
        total_new_size,
        total_remove_size,
        device_available_space: device_space,
        has_sufficient_space,
    })
}

/// Execute sync operation based on preview.
///
/// Performs actual file operations:
/// - Removes stale files no longer in profile
/// - Links/copies new files from cache to profile folder
/// - Updates sync_state for each successful operation
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile` - Sync profile to execute
/// * `cache` - Transcode cache for file operations
/// * `preview` - Preview computed by compute_sync_preview
///
/// # Returns
/// * `Ok(SyncResult)` with counts of successful and failed operations
/// * `Err` if insufficient space or critical operation fails
pub fn execute_sync(
    conn: &Connection,
    profile: &SyncProfile,
    cache: &TranscodeCache,
    preview: &SyncPreview,
) -> Result<SyncResult> {
    // Block if insufficient space
    if !preview.has_sufficient_space {
        bail!("Insufficient device space for sync");
    }

    let mut synced_count = 0;
    let mut failed = Vec::new();

    // 1. Remove stale files (in sync_state but not in current profile)
    for file_path in &preview.files_to_remove {
        let full_path = profile.output_folder.join(file_path);
        if full_path.exists() {
            if let Err(e) = std::fs::remove_file(&full_path) {
                log::warn!("Failed to remove stale file {}: {}", full_path.display(), e);
            }
        }
    }

    // 2. Link/copy new files from cache to profile folder
    for file in &preview.files_to_add {
        let track = match get_track(conn, file.track_id) {
            Ok(t) => t,
            Err(e) => {
                failed.push((file.track_id, format!("Failed to get track: {}", e)));
                continue;
            }
        };

        let cache_path = cache.get_cache_path(file.track_id, Path::new(&track.metadata.original_path));

        if !cache_path.exists() {
            failed.push((file.track_id, "Cache file not found".to_string()));
            continue;
        }

        let dest_path = match cache.build_profile_path(&profile.output_folder, &track) {
            Ok(p) => p,
            Err(e) => {
                failed.push((file.track_id, format!("Failed to build path: {}", e)));
                continue;
            }
        };

        // Create parent directories
        if let Some(parent) = dest_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                failed.push((file.track_id, format!("Failed to create directories: {}", e)));
                continue;
            }
        }

        // Link from cache to profile folder
        match cache.link_to_profile(&cache_path, &dest_path) {
            Ok(_) => {
                // Write ReplayGain tags to synced copy (library originals stay pristine)
                // This is best-effort: if gain values haven't been calculated yet, skip silently
                if let Ok(Some(gain)) = crate::replaygain::analyzer::get_track_gain(conn, file.track_id) {
                    // Try to get album gain
                    let (album_gain, album_peak) = get_album_gain(conn, file.track_id);
                    if let Err(e) = crate::replaygain::tagger::write_gain_tags(
                        &dest_path,
                        gain.track_gain,
                        gain.track_peak,
                        album_gain,
                        album_peak,
                    ) {
                        log::warn!("Failed to write ReplayGain tags for track {}: {}", file.track_id, e);
                        // Non-fatal: sync succeeds even if RG tagging fails
                    }
                }

                // Update sync_state
                match update_sync_state(conn, profile.id, file.track_id, &cache_path, cache) {
                    Ok(_) => synced_count += 1,
                    Err(e) => {
                        failed.push((file.track_id, format!("Failed to update sync state: {}", e)));
                    }
                }
            }
            Err(e) => {
                failed.push((file.track_id, format!("Link failed: {}", e)));
            }
        }
    }

    // 3. Clean up sync_state for removed tracks
    let profile_track_ids = profile.get_all_track_ids(conn)?;
    clean_removed_tracks(conn, profile.id, &profile_track_ids)?;

    Ok(SyncResult {
        synced_count,
        failed_count: failed.len(),
        failed_tracks: failed,
    })
}

/// Update sync_state table after successful file sync.
///
/// Records checksum, size, and timestamp for change detection.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile
/// * `track_id` - ID of track that was synced
/// * `cache_path` - Path to cached file
/// * `cache` - TranscodeCache for checksum computation
///
/// # Returns
/// * `Ok(())` on success
/// * `Err` if database update or checksum computation fails
pub fn update_sync_state(
    conn: &Connection,
    profile_id: i64,
    track_id: i64,
    cache_path: &Path,
    cache: &TranscodeCache,
) -> Result<()> {
    let checksum = cache.compute_checksum(cache_path)?;
    let size = std::fs::metadata(cache_path)?.len() as i64;
    let timestamp = chrono::Utc::now().to_rfc3339();

    conn.execute(
        "INSERT OR REPLACE INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
         VALUES (?, ?, ?, ?, ?)",
        rusqlite::params![profile_id, track_id, checksum, size, timestamp],
    )?;

    Ok(())
}

/// Get album gain values for a track from the database.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID
///
/// # Returns
/// * `(Some(album_gain), Some(album_peak))` - If album gain exists
/// * `(None, None)` - If album gain not analyzed yet
fn get_album_gain(conn: &Connection, track_id: i64) -> (Option<f64>, Option<f64>) {
    let result = conn.query_row(
        "SELECT album_gain, album_peak FROM replaygain WHERE track_id = ?",
        [track_id],
        |row| {
            let gain: Option<f64> = row.get(0).ok();
            let peak: Option<f64> = row.get(1).ok();
            Ok((gain, peak))
        },
    );

    match result {
        Ok((gain, peak)) => (gain, peak),
        Err(_) => (None, None), // Track not analyzed or no album gain
    }
}

/// Get set of track IDs currently synced for a profile.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile
///
/// # Returns
/// * `Ok(HashSet<i64>)` - Set of synced track IDs
/// * `Err` if database query fails
fn get_synced_tracks(conn: &Connection, profile_id: i64) -> Result<HashSet<i64>> {
    let mut stmt = conn.prepare("SELECT track_id FROM sync_state WHERE profile_id = ?")?;

    let ids: HashSet<i64> = stmt
        .query_map([profile_id], |row| row.get(0))?
        .filter_map(|r| r.ok())
        .collect();

    Ok(ids)
}

/// Check if a track needs to be synced.
///
/// Returns true if:
/// - Track has never been synced
/// - Track checksum has changed since last sync
/// - Cached file doesn't exist
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile
/// * `track_id` - ID of track to check
/// * `cache` - TranscodeCache for checksum computation
///
/// # Returns
/// * `Ok(true)` if track needs sync
/// * `Ok(false)` if track is already synced with matching checksum
/// * `Err` if database query or file access fails
fn needs_sync(
    conn: &Connection,
    profile_id: i64,
    track_id: i64,
    cache: &TranscodeCache,
) -> Result<bool> {
    // Check sync_state for existing entry
    let mut stmt = conn.prepare(
        "SELECT synced_checksum FROM sync_state WHERE profile_id = ? AND track_id = ?",
    )?;

    let existing_checksum: Option<String> =
        stmt.query_row([profile_id, track_id], |row| row.get(0)).ok();

    if let Some(old_checksum) = existing_checksum {
        // Compute current checksum and compare
        let track = get_track(conn, track_id)?;
        let cache_path = cache.get_cache_path(track_id, Path::new(&track.metadata.original_path));

        if cache_path.exists() {
            let current_checksum = cache.compute_checksum(&cache_path)?;
            Ok(current_checksum != old_checksum)
        } else {
            Ok(true) // Cache file missing, need to transcode
        }
    } else {
        Ok(true) // Never synced before
    }
}

/// Get synced file size from sync_state table.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile
/// * `track_id` - ID of track
///
/// # Returns
/// * `Ok(u64)` - File size in bytes
/// * `Err` if not found in sync_state
fn get_synced_file_size(conn: &Connection, profile_id: i64, track_id: i64) -> Result<u64> {
    let mut stmt = conn.prepare(
        "SELECT synced_size FROM sync_state WHERE profile_id = ? AND track_id = ?",
    )?;

    let size: i64 = stmt
        .query_row([profile_id, track_id], |row| row.get(0))
        .context("Track not found in sync_state")?;

    Ok(size as u64)
}

/// Get track from database by ID.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - ID of track to retrieve
///
/// # Returns
/// * `Ok(Track)` with full metadata
/// * `Err` if track not found or database query fails
fn get_track(conn: &Connection, track_id: i64) -> Result<Track> {
    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, album, title, genre, year, bitrate, duration, format,
                original_path, COALESCE(organized_path, '') as organized_path, is_duplicate, date_added
         FROM tracks WHERE id = ?",
    )?;

    stmt.query_row([track_id], |row| {
        let metadata = TrackMetadata::new(
            row.get(1)?,  // artist
            row.get(2)?,  // album_artist
            row.get(3)?,  // album
            row.get(4)?,  // title
            row.get(5)?,  // genre
            row.get(6)?,  // year
            row.get(7)?,  // bitrate
            row.get(8)?,  // duration
            row.get(9)?,  // format
            row.get(10)?, // original_path
        );

        Ok(Track {
            id: Some(row.get(0)?),
            metadata,
            organized_path: row.get(11)?,
            is_duplicate: row.get(12)?,
            date_added: row.get(13)?,
        })
    })
    .context("Track not found")
}

/// Clean sync_state entries for tracks no longer in profile.
///
/// Removes database entries for tracks that have been removed from the profile.
/// Corresponding files should already be deleted.
///
/// # Arguments
/// * `conn` - Database connection
/// * `profile_id` - ID of sync profile
/// * `current_track_ids` - Set of track IDs currently in profile
///
/// # Returns
/// * `Ok(usize)` - Number of entries removed
/// * `Err` if database operation fails
fn clean_removed_tracks(
    conn: &Connection,
    profile_id: i64,
    current_track_ids: &HashSet<i64>,
) -> Result<usize> {
    if current_track_ids.is_empty() {
        // Delete all sync_state entries for this profile
        let count = conn.execute("DELETE FROM sync_state WHERE profile_id = ?", [profile_id])?;
        return Ok(count);
    }

    // Build IN clause for current tracks
    let placeholders: Vec<String> = current_track_ids.iter().map(|_| "?".to_string()).collect();
    let in_clause = placeholders.join(", ");

    let sql = format!(
        "DELETE FROM sync_state WHERE profile_id = ? AND track_id NOT IN ({})",
        in_clause
    );

    let mut params: Vec<rusqlite::types::Value> = vec![rusqlite::types::Value::Integer(profile_id)];
    params.extend(
        current_track_ids
            .iter()
            .map(|id| rusqlite::types::Value::Integer(*id)),
    );

    let count = conn.execute(&sql, rusqlite::params_from_iter(params))?;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::{connection::get_memory_connection, schema::initialize_schema};
    use crate::sync::profile::{add_manual_track, create_sync_profile};
    use std::fs;
    use std::path::PathBuf;
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
    fn test_compute_sync_preview_new_profile() {
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

        // Add track to profile
        let track_id = create_test_track(&conn, "Track 1");
        add_manual_track(&conn, profile_id, track_id).unwrap();

        // Create cache with file
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();
        let cache_path = cache.get_cache_path(track_id, Path::new("/test/track.flac"));
        fs::write(&cache_path, b"test audio data").unwrap();

        // Get profile
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();

        // Compute preview
        let preview = compute_sync_preview(&conn, &profile, &cache, Some(100_000_000)).unwrap();

        // Empty sync_state = all tracks need sync
        assert_eq!(preview.files_to_add.len(), 1);
        assert_eq!(preview.files_to_remove.len(), 0);
        assert!(preview.has_sufficient_space);
    }

    #[test]
    fn test_compute_sync_preview_incremental() {
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

        // Add two tracks
        let track1_id = create_test_track(&conn, "Track 1");
        let track2_id = create_test_track(&conn, "Track 2");
        add_manual_track(&conn, profile_id, track1_id).unwrap();
        add_manual_track(&conn, profile_id, track2_id).unwrap();

        // Create cache
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();

        // Create cache files
        let cache1 = cache.get_cache_path(track1_id, Path::new("/test/track1.flac"));
        let cache2 = cache.get_cache_path(track2_id, Path::new("/test/track2.flac"));
        fs::write(&cache1, b"audio 1").unwrap();
        fs::write(&cache2, b"audio 2").unwrap();

        // Mark track1 as already synced
        let checksum1 = cache.compute_checksum(&cache1).unwrap();
        conn.execute(
            "INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
             VALUES (?, ?, ?, ?, ?)",
            rusqlite::params![profile_id, track1_id, checksum1, 7, "2024-01-01T00:00:00Z"],
        )
        .unwrap();

        // Get profile
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();

        // Compute preview
        let preview = compute_sync_preview(&conn, &profile, &cache, Some(100_000_000)).unwrap();

        // Only track2 should need sync (track1 already synced)
        assert_eq!(preview.files_to_add.len(), 1);
        assert_eq!(preview.files_to_add[0].track_id, track2_id);
        assert_eq!(preview.files_to_remove.len(), 0);
    }

    #[test]
    fn test_space_validation_blocks_insufficient() {
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

        // Add track
        let track_id = create_test_track(&conn, "Track 1");
        add_manual_track(&conn, profile_id, track_id).unwrap();

        // Create cache with file
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();
        let cache_path = cache.get_cache_path(track_id, Path::new("/test/track.flac"));
        fs::write(&cache_path, b"test audio data").unwrap();

        // Get profile
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();

        // Compute preview with insufficient space (less than file size + 50MB buffer)
        let preview = compute_sync_preview(&conn, &profile, &cache, Some(1_000_000)).unwrap();

        // Should have insufficient space
        assert!(!preview.has_sufficient_space);
    }

    #[test]
    fn test_execute_sync_blocks_insufficient_space() {
        let preview = SyncPreview {
            files_to_add: vec![],
            files_to_remove: vec![],
            total_new_size: 0,
            total_remove_size: 0,
            device_available_space: Some(1_000_000),
            has_sufficient_space: false,
        };

        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();
        let temp_dir = TempDir::new().unwrap();

        let profile_id = create_sync_profile(
            &conn,
            "Test".to_string(),
            temp_dir.path().join("profile"),
        )
        .unwrap();
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();

        let cache = TranscodeCache::new(temp_dir.path().join("cache")).unwrap();

        // Should fail with insufficient space
        let result = execute_sync(&conn, &profile, &cache, &preview);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Insufficient"));
    }

    #[test]
    fn test_execute_sync_links_files() {
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

        // Add track to profile
        let track_id = create_test_track(&conn, "Track 1");
        add_manual_track(&conn, profile_id, track_id).unwrap();

        // Create cache with file
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();
        let cache_path = cache.get_cache_path(track_id, Path::new("/test/Track_1.flac"));
        fs::write(&cache_path, b"test audio data").unwrap();

        // Get profile
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();

        // Compute preview
        let preview = compute_sync_preview(&conn, &profile, &cache, Some(100_000_000)).unwrap();

        // Execute sync
        let result = execute_sync(&conn, &profile, &cache, &preview).unwrap();

        // Should have synced 1 file
        assert_eq!(result.synced_count, 1);
        assert_eq!(result.failed_count, 0);

        // Verify file was linked to profile folder
        let track = get_track(&conn, track_id).unwrap();
        let dest_path = cache.build_profile_path(&profile.output_folder, &track).unwrap();
        assert!(dest_path.exists());
    }

    #[test]
    fn test_execute_sync_updates_state() {
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

        // Add track
        let track_id = create_test_track(&conn, "Track 1");
        add_manual_track(&conn, profile_id, track_id).unwrap();

        // Create cache
        let cache_dir = temp_dir.path().join("cache");
        let cache = TranscodeCache::new(cache_dir.clone()).unwrap();
        let cache_path = cache.get_cache_path(track_id, Path::new("/test/Track_1.flac"));
        fs::write(&cache_path, b"test audio data").unwrap();

        // Get profile
        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id).unwrap();

        // Compute and execute sync
        let preview = compute_sync_preview(&conn, &profile, &cache, Some(100_000_000)).unwrap();
        execute_sync(&conn, &profile, &cache, &preview).unwrap();

        // Verify sync_state was updated
        let synced = get_synced_tracks(&conn, profile_id).unwrap();
        assert_eq!(synced.len(), 1);
        assert!(synced.contains(&track_id));

        // Verify checksum was stored
        let mut stmt = conn
            .prepare("SELECT synced_checksum FROM sync_state WHERE profile_id = ? AND track_id = ?")
            .unwrap();
        let checksum: String = stmt
            .query_row([profile_id, track_id], |row| row.get(0))
            .unwrap();
        assert!(!checksum.is_empty());
        assert_eq!(checksum.len(), 64); // SHA256 is 64 hex chars
    }

    #[test]
    fn test_clean_removed_tracks() {
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

        // Create tracks
        let track1_id = create_test_track(&conn, "Track 1");
        let track2_id = create_test_track(&conn, "Track 2");
        let track3_id = create_test_track(&conn, "Track 3");

        // Add all three to sync_state
        for track_id in &[track1_id, track2_id, track3_id] {
            conn.execute(
                "INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                 VALUES (?, ?, ?, ?, ?)",
                rusqlite::params![profile_id, track_id, "checksum", 1000, "2024-01-01T00:00:00Z"],
            )
            .unwrap();
        }

        // Current profile only has track1 and track2
        let mut current_tracks = HashSet::new();
        current_tracks.insert(track1_id);
        current_tracks.insert(track2_id);

        // Clean removed tracks
        let removed = clean_removed_tracks(&conn, profile_id, &current_tracks).unwrap();

        // Should have removed track3
        assert_eq!(removed, 1);

        // Verify sync_state
        let synced = get_synced_tracks(&conn, profile_id).unwrap();
        assert_eq!(synced.len(), 2);
        assert!(synced.contains(&track1_id));
        assert!(synced.contains(&track2_id));
        assert!(!synced.contains(&track3_id));
    }
}
