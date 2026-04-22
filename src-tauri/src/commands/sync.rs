//! Tauri command handlers for sync operations.
//!
//! Exposes sync profile operations to the frontend via Tauri commands:
//! - Create/list/get/delete sync profiles
//! - Add tracks, playlists, and filter rules to profiles
//! - Detect Rockbox devices
//! - Preview sync operations (dry-run)
//! - Execute sync to device or folder
//!
//! # Frontend Usage (TypeScript)
//! ```typescript
//! import { invoke } from "@tauri-apps/api/tauri";
//!
//! // Create a sync profile
//! const profileId = await invoke<number>("create_sync_profile", {
//!   name: "My iPod",
//!   outputFolder: "/Volumes/IPOD"
//! });
//!
//! // List all profiles
//! const profiles = await invoke<SyncProfileDto[]>("list_sync_profiles");
//!
//! // Preview sync
//! const preview = await invoke<SyncPreview>("preview_sync_cmd", {
//!   profileId: 1,
//!   deviceSpace: 16_000_000_000
//! });
//!
//! // Execute sync
//! const result = await invoke<SyncResult>("execute_sync_cmd", {
//!   profileId: 1
//! });
//! ```

use std::path::PathBuf;

use crate::database::get_connection;
use crate::models::sync::{FilterRuleDto, SyncProfileDto};
use crate::sync::{detect_rockbox_devices, RockboxDevice, SyncPreview, SyncResult};
use tauri::Emitter;

/// Create a new sync profile.
///
/// Uses spawn_blocking pattern to handle rusqlite's !Send Connection
/// in async context.
///
/// # Arguments
/// * `name` - Profile name
/// * `output_folder` - Path to sync destination (device mount point or folder)
///
/// # Returns
/// * `Ok(profile_id)` - ID of created profile
/// * `Err(String)` - If database operation fails
#[tauri::command]
pub async fn create_sync_profile(name: String, output_folder: String) -> Result<i64, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let output_path = PathBuf::from(output_folder);
        crate::sync::profile::create_sync_profile(&conn, name, output_path)
            .map_err(|e| format!("Failed to create sync profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// List all sync profiles with computed statistics.
///
/// Returns profiles with track counts, playlist counts, and rule counts.
///
/// # Returns
/// * `Ok(Vec<SyncProfileDto>)` - All profiles with statistics
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn list_sync_profiles() -> Result<Vec<SyncProfileDto>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let profiles = crate::sync::profile::list_sync_profiles(&conn)
            .map_err(|e| format!("Failed to list profiles: {}", e))?;

        let mut dtos = Vec::new();
        for profile in profiles {
            let dto = SyncProfileDto::from_profile(profile, &conn)
                .map_err(|e| format!("Failed to convert profile: {}", e))?;
            dtos.push(dto);
        }

        Ok(dtos)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get a single sync profile by ID with computed statistics.
///
/// # Arguments
/// * `profile_id` - ID of profile to retrieve
///
/// # Returns
/// * `Ok(SyncProfileDto)` - Profile with statistics
/// * `Err(String)` - If profile not found or database error
#[tauri::command]
pub async fn get_sync_profile(profile_id: i64) -> Result<SyncProfileDto, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let profile = crate::sync::profile::get_sync_profile(&conn, profile_id)
            .map_err(|e| format!("Failed to get profile: {}", e))?;

        SyncProfileDto::from_profile(profile, &conn)
            .map_err(|e| format!("Failed to convert profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Delete a sync profile.
///
/// Cascades deletion to all associated tracks, playlists, rules, and sync state.
///
/// # Arguments
/// * `profile_id` - ID of profile to delete
///
/// # Returns
/// * `Ok(())` - Profile deleted successfully
/// * `Err(String)` - If database operation fails
#[tauri::command]
pub async fn delete_sync_profile(profile_id: i64) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::delete_sync_profile(&conn, profile_id)
            .map_err(|e| format!("Failed to delete profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Update sync profile settings (playlist path prefix).
#[tauri::command]
pub async fn update_sync_profile_settings(
    profile_id: i64,
    playlist_path_prefix: String,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::update_sync_profile_settings(&conn, profile_id, &playlist_path_prefix)
            .map_err(|e| format!("Failed to update profile settings: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Add a track to a sync profile (manual track selection).
///
/// # Arguments
/// * `profile_id` - ID of profile
/// * `track_id` - ID of track to add
///
/// # Returns
/// * `Ok(())` - Track added successfully
/// * `Err(String)` - If track already in profile or database error
#[tauri::command]
pub async fn add_track_to_profile(profile_id: i64, track_id: i64) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::add_manual_track(&conn, profile_id, track_id)
            .map_err(|e| format!("Failed to add track to profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Add a playlist to a sync profile.
///
/// All tracks in the playlist will be included in the sync.
///
/// # Arguments
/// * `profile_id` - ID of profile
/// * `playlist_id` - ID of playlist to add
///
/// # Returns
/// * `Ok(())` - Playlist added successfully
/// * `Err(String)` - If playlist already in profile or database error
#[tauri::command]
pub async fn add_playlist_to_profile(profile_id: i64, playlist_id: i64) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::add_playlist(&conn, profile_id, playlist_id)
            .map_err(|e| format!("Failed to add playlist to profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Add a filter rule to a sync profile.
///
/// Filter rules query the track database to select tracks dynamically.
///
/// # Arguments
/// * `profile_id` - ID of profile
/// * `rule` - Filter rule (field, operator, value)
///
/// # Returns
/// * `Ok(())` - Rule added successfully
/// * `Err(String)` - If database operation fails
#[tauri::command]
pub async fn add_rule_to_profile(profile_id: i64, rule: FilterRuleDto) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let filter_rule = rule.into();
        crate::sync::profile::add_rule(&conn, profile_id, filter_rule)
            .map(|_rule_id| ()) // add_rule returns i64 rule_id, discard it
            .map_err(|e| format!("Failed to add rule to profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Remove a playlist from a sync profile.
#[tauri::command]
pub async fn remove_playlist_from_profile(profile_id: i64, playlist_id: i64) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::remove_playlist(&conn, profile_id, playlist_id)
            .map_err(|e| format!("Failed to remove playlist from profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Remove a manual track from a sync profile.
#[tauri::command]
pub async fn remove_track_from_profile(profile_id: i64, track_id: i64) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::remove_manual_track(&conn, profile_id, track_id)
            .map_err(|e| format!("Failed to remove track from profile: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get playlist IDs and names attached to a sync profile.
#[tauri::command]
pub async fn get_profile_playlists(profile_id: i64) -> Result<Vec<serde_json::Value>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let mut stmt = conn.prepare(
            "SELECT p.id, p.name, p.category,
                    (SELECT COUNT(*) FROM playlist_tracks pt WHERE pt.playlist_id = p.id) as track_count
             FROM sync_profile_playlists spp
             JOIN playlists p ON spp.playlist_id = p.id
             WHERE spp.profile_id = ?1"
        ).map_err(|e| format!("Query error: {}", e))?;

        let rows = stmt.query_map([profile_id], |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, i64>(0)?,
                "name": row.get::<_, String>(1)?,
                "category": row.get::<_, String>(2)?,
                "track_count": row.get::<_, i64>(3)?
            }))
        }).map_err(|e| format!("Query error: {}", e))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Row error: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Detect Rockbox-enabled devices connected to the system.
///
/// Scans platform-specific mount points for .rockbox directory marker.
/// Returns empty vector if no devices found (not an error).
///
/// # Returns
/// * `Ok(Vec<RockboxDevice>)` - List of detected devices with mount points and space
/// * `Err(String)` - If filesystem scan fails
#[tauri::command]
pub async fn detect_rockbox_devices_cmd() -> Result<Vec<RockboxDevice>, String> {
    tokio::task::spawn_blocking(move || {
        detect_rockbox_devices().map_err(|e| format!("Failed to detect devices: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Preview what would be synced without performing actual operations.
///
/// Computes files to add, remove, and space requirements for dry-run mode.
///
/// # Arguments
/// * `profile_id` - ID of sync profile to preview
/// * `device_space` - Available space on device (None for local-only)
///
/// # Returns
/// * `Ok(SyncPreview)` - Detailed preview with file lists and space validation
/// * `Err(String)` - If profile not found or database error
#[tauri::command]
pub async fn preview_sync_cmd(
    profile_id: i64,
    device_space: Option<u64>,
) -> Result<SyncPreview, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        // Use default cache directory (could be made configurable in Phase 6)
        let cache_dir = PathBuf::from("transcode_cache");

        crate::sync::preview_sync(&conn, profile_id, cache_dir, device_space)
            .map_err(|e| format!("Failed to preview sync: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Execute full sync: files + playlists.
///
/// Performs complete sync workflow:
/// 1. Computes preview of changes
/// 2. Executes file sync (links from cache to profile folder)
/// 3. Generates M3U8 playlists for all playlists in profile
///
/// # Arguments
/// * `profile_id` - ID of sync profile to execute
/// * `app` - Tauri AppHandle for event emission
///
/// # Returns
/// * `Ok(SyncResult)` - Counts of successful and failed operations
/// * `Err(String)` - If profile not found, insufficient space, or sync fails
#[tauri::command]
pub async fn execute_sync_cmd(profile_id: i64, app: tauri::AppHandle) -> Result<SyncResult, String> {
    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
            let cache_dir = PathBuf::from("transcode_cache");

            // Step 1: Transcode missing cache files
            let profile = crate::sync::profile::get_sync_profile(&conn, profile_id)
                .map_err(|e| format!("Profile error: {}", e))?;
            let all_track_ids = profile.get_all_track_ids(&conn)
                .map_err(|e| format!("Track ID error: {}", e))?;
            let cache = crate::sync::TranscodeCache::new(cache_dir.clone())
                .map_err(|e| format!("Cache error: {}", e))?;

            // Load library config for path resolution
            let lib_config = crate::config::LibraryConfig::load(&conn)
                .map_err(|e| format!("Config error: {}", e))?;
            let library_root = lib_config.root_path
                .ok_or_else(|| "Library root not configured".to_string())?;

            // Find tracks needing transcode
            let mut to_transcode: Vec<(i64, PathBuf)> = Vec::new();
            for track_id in &all_track_ids {
                let (original_path, organized_path): (String, Option<String>) = conn.query_row(
                    "SELECT original_path, organized_path FROM tracks WHERE id = ?",
                    [track_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                ).map_err(|e| format!("DB error: {}", e))?;

                // Resolve source file: try organized_path against library root first
                // (works for downloaded tracks), then fall back to original_path
                // (works for scanned tracks with absolute paths on disk).
                let src = organized_path
                    .as_deref()
                    .filter(|p| !p.is_empty())
                    .and_then(|op| {
                        // Try direct join
                        let direct = library_root.join(op);
                        if direct.exists() { return Some(direct); }
                        // Try scan folders
                        for folder in &lib_config.scan_folders {
                            let c = library_root.join(folder).join(op);
                            if c.exists() { return Some(c); }
                        }
                        None
                    })
                    .or_else(|| {
                        // Fall back to original_path if it's a real file path (not a URL)
                        if !original_path.starts_with("http") {
                            let p = PathBuf::from(&original_path);
                            if p.exists() { return Some(p); }
                        }
                        None
                    });

                let src = match src {
                    Some(p) => p,
                    None => {
                        log::warn!("Track {}: source file not found (organized={:?}, original={})",
                            track_id, organized_path, original_path);
                        continue;
                    }
                };

                let cache_path = cache.get_cache_path(*track_id, &src);
                if !cache_path.exists() {
                    to_transcode.push((*track_id, src));
                }
            }

            if !to_transcode.is_empty() {
                log::info!("Transcoding {} tracks to cache before sync", to_transcode.len());
                let _ = app.emit("sync:transcode_started", serde_json::json!({
                    "profile_id": profile_id,
                    "total": to_transcode.len()
                }));

                let total = to_transcode.len();
                for (i, (track_id, abs_source)) in to_transcode.iter().enumerate() {
                    let src = abs_source.as_path();
                    let cache_path = cache.get_cache_path(*track_id, src);

                    // Get track info for logging
                    let (artist, title) = conn.query_row(
                        "SELECT artist, title FROM tracks WHERE id = ?",
                        [track_id],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                    ).unwrap_or_else(|_| ("".to_string(), "".to_string()));

                    log::info!(
                        "[{}/{}] Transcoding {} - {} ({})",
                        i + 1, total, artist, title, src.display()
                    );

                    let _ = app.emit("sync:transcode_progress", serde_json::json!({
                        "current": i + 1,
                        "total": total,
                        "artist": artist,
                        "title": title
                    }));

                    match crate::transcode::transcode_audio(src, &cache_dir).await {
                        Ok(crate::transcode::TranscodeResult::Transcoded(out)) => {
                            // transcode_audio writes to {cache_dir}/{stem}.m4a
                            // but cache expects {cache_dir}/{track_id}.m4a
                            if out != cache_path {
                                if let Err(e) = std::fs::rename(&out, &cache_path) {
                                    log::warn!("Failed to rename {} -> {}: {}", out.display(), cache_path.display(), e);
                                    // Try copy + delete as fallback
                                    let _ = std::fs::copy(&out, &cache_path);
                                    let _ = std::fs::remove_file(&out);
                                }
                            }
                            log::info!("  Cached as {}", cache_path.display());
                        }
                        Ok(crate::transcode::TranscodeResult::Skipped(reason)) => {
                            // Copy original to cache for sync
                            log::info!("  Transcode skipped ({}), copying original", reason);
                            if let Err(e) = std::fs::copy(src, &cache_path) {
                                log::warn!("  Failed to copy to cache: {}", e);
                            }
                        }
                        Ok(crate::transcode::TranscodeResult::Failed(e)) => {
                            log::warn!("  Transcode failed: {}", e);
                        }
                        Err(e) => {
                            log::warn!("  Transcode error: {}", e);
                        }
                    }
                }

                let _ = app.emit("sync:transcode_completed", serde_json::json!({
                    "profile_id": profile_id,
                    "transcoded": total
                }));
            }

            // Step 2: Run sync
            crate::sync::sync_profile_to_folder(&conn, profile_id, cache_dir, Some(&app))
                .map_err(|e| format!("Failed to execute sync: {}", e))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Clean sync: clear sync state for a profile, then execute a full resync.
///
/// Deletes all `sync_state` entries for the given profile so the next sync
/// treats every track as new. Then delegates to `execute_sync_cmd`.
#[tauri::command]
pub async fn clean_sync_cmd(profile_id: i64, app: tauri::AppHandle) -> Result<SyncResult, String> {
    // Clear sync state first
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        conn.execute("DELETE FROM sync_state WHERE profile_id = ?", [profile_id])
            .map_err(|e| format!("Failed to clear sync state: {}", e))?;
        log::info!("Cleared sync state for profile {}", profile_id);
        Ok::<_, String>(())
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))??;

    // Now run normal sync
    execute_sync_cmd(profile_id, app).await
}

/// Get set of track IDs that have a transcode cache file.
#[tauri::command]
pub async fn get_cached_track_ids() -> Result<Vec<i64>, String> {
    tokio::task::spawn_blocking(move || {
        let cache_dir = PathBuf::from("transcode_cache");
        if !cache_dir.exists() {
            return Ok(vec![]);
        }
        let mut ids = Vec::new();
        let entries = std::fs::read_dir(&cache_dir)
            .map_err(|e| format!("Failed to read cache dir: {}", e))?;
        for entry in entries.flatten() {
            if let Some(stem) = entry.path().file_stem().and_then(|s| s.to_str()) {
                if let Ok(id) = stem.parse::<i64>() {
                    // Only include non-empty files
                    if entry.metadata().map(|m| m.len() > 0).unwrap_or(false) {
                        ids.push(id);
                    }
                }
            }
        }
        Ok(ids)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get the most recent sync timestamp across all sync profiles.
///
/// Queries sync_state table for latest synced_timestamp.
///
/// # Returns
/// * `Ok(Some(String))` - ISO 8601 timestamp of most recent sync
/// * `Ok(None)` - If no syncs have been performed yet
/// * `Err(String)` - If database query fails
///
/// # Example (TypeScript)
/// ```typescript
/// const lastSync = await invoke("get_last_sync_time");
/// if (lastSync) {
///     console.log(`Last synced: ${new Date(lastSync).toLocaleDateString()}`);
/// } else {
///     console.log("Never synced");
/// }
/// ```
#[tauri::command]
pub async fn get_last_sync_time() -> Result<Option<String>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let result: Result<String, rusqlite::Error> = conn.query_row(
            "SELECT synced_timestamp FROM sync_state
             WHERE synced_timestamp IS NOT NULL
             ORDER BY synced_timestamp DESC
             LIMIT 1",
            [],
            |row| row.get(0),
        );

        match result {
            Ok(timestamp) => Ok(Some(timestamp)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to query last sync time: {}", e)),
        }
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_sync_profile_signature() {
        // Compile-time check that command signature matches expected pattern
        let _f: fn(String, String) -> _ = create_sync_profile;
    }

    #[test]
    fn test_list_sync_profiles_signature() {
        let _f: fn() -> _ = list_sync_profiles;
    }

    #[test]
    fn test_get_sync_profile_signature() {
        let _f: fn(i64) -> _ = get_sync_profile;
    }

    #[test]
    fn test_delete_sync_profile_signature() {
        let _f: fn(i64) -> _ = delete_sync_profile;
    }

    #[test]
    fn test_add_track_to_profile_signature() {
        let _f: fn(i64, i64) -> _ = add_track_to_profile;
    }

    #[test]
    fn test_add_playlist_to_profile_signature() {
        let _f: fn(i64, i64) -> _ = add_playlist_to_profile;
    }

    #[test]
    fn test_add_rule_to_profile_signature() {
        let _f: fn(i64, FilterRuleDto) -> _ = add_rule_to_profile;
    }

    #[test]
    fn test_detect_rockbox_devices_cmd_signature() {
        let _f: fn() -> _ = detect_rockbox_devices_cmd;
    }

    #[test]
    fn test_preview_sync_cmd_signature() {
        let _f: fn(i64, Option<u64>) -> _ = preview_sync_cmd;
    }

    #[test]
    fn test_execute_sync_cmd_signature() {
        let _f: fn(i64, tauri::AppHandle) -> _ = execute_sync_cmd;
    }
}
