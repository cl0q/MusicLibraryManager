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
        let db_path = PathBuf::from("music_library.db");
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
        let db_path = PathBuf::from("music_library.db");
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
        let db_path = PathBuf::from("music_library.db");
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
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::sync::profile::delete_sync_profile(&conn, profile_id)
            .map_err(|e| format!("Failed to delete profile: {}", e))
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
        let db_path = PathBuf::from("music_library.db");
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
        let db_path = PathBuf::from("music_library.db");
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
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let filter_rule = rule.into();
        crate::sync::profile::add_rule(&conn, profile_id, filter_rule)
            .map(|_rule_id| ()) // add_rule returns i64 rule_id, discard it
            .map_err(|e| format!("Failed to add rule to profile: {}", e))
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
        let db_path = PathBuf::from("music_library.db");
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
///
/// # Returns
/// * `Ok(SyncResult)` - Counts of successful and failed operations
/// * `Err(String)` - If profile not found, insufficient space, or sync fails
#[tauri::command]
pub async fn execute_sync_cmd(profile_id: i64) -> Result<SyncResult, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        // Use default cache directory (could be made configurable in Phase 6)
        let cache_dir = PathBuf::from("transcode_cache");

        crate::sync::sync_profile_to_folder(&conn, profile_id, cache_dir)
            .map_err(|e| format!("Failed to execute sync: {}", e))
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
        let _f: fn(i64) -> _ = execute_sync_cmd;
    }
}
