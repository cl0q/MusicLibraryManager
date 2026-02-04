//! Tauri command handlers for playlist operations.
//!
//! Exposes playlist database operations to the frontend via Tauri commands:
//! - Create playlists with tags
//! - Get all playlists
//! - Get playlist tracks with ordering
//! - Search tracks within a playlist
//! - Add/remove tracks from playlists
//! - Reorder tracks via drag-drop with fractional indexing
//!
//! # Frontend Usage (TypeScript)
//! ```typescript
//! import { invoke } from "@tauri-apps/api/tauri";
//!
//! // Create a new playlist
//! const playlistId = await invoke<number>("create_playlist_command", {
//!   name: "My Playlist",
//!   description: "A great playlist",
//!   tags: ["rock", "workout"]
//! });
//!
//! // Get all playlists
//! const playlists = await invoke<Playlist[]>("get_playlists_command");
//!
//! // Get tracks in a playlist
//! const tracks = await invoke<Track[]>("get_playlist_tracks_command", {
//!   playlistId: 1
//! });
//!
//! // Search tracks in a playlist
//! const results = await invoke<Track[]>("search_playlist_tracks_command", {
//!   playlistId: 1,
//!   query: "song title"
//! });
//!
//! // Reorder track via drag-drop
//! await invoke("reorder_playlist_track_command", {
//!   playlistId: 1,
//!   trackId: 42,
//!   afterTrackId: 10,
//!   beforeTrackId: 15
//! });
//! ```

use std::path::PathBuf;

use crate::database::get_connection;
use crate::models::playlist::{Playlist, PlaylistCategory};
use crate::models::track::Track;

/// Create a new playlist with optional description and tags.
///
/// Uses spawn_blocking pattern to handle rusqlite's !Send Connection
/// in async context. Calls database::playlist::create_playlist internally.
///
/// # Arguments
/// * `name` - Playlist name
/// * `description` - Optional description
/// * `tags` - Vector of tag strings for organization
///
/// # Returns
/// * `Ok(playlist_id)` - ID of created playlist
/// * `Err(String)` - If database operation fails
#[tauri::command]
pub async fn create_playlist_command(
    name: String,
    description: Option<String>,
    tags: Vec<String>,
) -> Result<i64, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::database::playlist::create_playlist(
            &conn,
            name,
            description,
            tags,
            PlaylistCategory::Regular,
        )
        .map_err(|e| format!("Failed to create playlist: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get all playlists ordered by pinned status, category, then name.
///
/// Returns playlists grouped naturally for UI display:
/// - Pinned playlists first (liked and smart playlists)
/// - Then by category (liked, smart, regular)
/// - Then alphabetically by name
///
/// # Returns
/// * `Ok(Vec<Playlist>)` - All playlists in display order
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn get_playlists_command() -> Result<Vec<Playlist>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let mut stmt = conn
            .prepare(
                "SELECT id, name, description, category, is_liked, is_smart, is_pinned,
                        cover_image_path, cover_image_url, source_id, external_id, date_created
                 FROM playlists
                 ORDER BY is_pinned DESC, category, name",
            )
            .map_err(|e| format!("Query error: {}", e))?;

        let playlists = stmt
            .query_map([], |row| {
                let category_str: String = row.get(3)?;
                let category = PlaylistCategory::from_str(&category_str)
                    .ok_or_else(|| rusqlite::Error::InvalidQuery)?;

                Ok(Playlist {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    category,
                    is_liked: row.get::<_, i32>(4)? != 0,
                    is_smart: row.get::<_, i32>(5)? != 0,
                    is_pinned: row.get::<_, i32>(6)? != 0,
                    cover_image_path: row.get(7)?,
                    cover_image_url: row.get(8)?,
                    source_id: row.get(9)?,
                    external_id: row.get(10)?,
                    date_created: row.get(11)?,
                })
            })
            .map_err(|e| format!("Query error: {}", e))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Row mapping error: {}", e))?;

        Ok(playlists)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get all tracks in a playlist, ordered by position.
///
/// Uses fractional indexing positions to maintain track order.
/// Joins with tracks table to return full track data.
///
/// # Arguments
/// * `playlist_id` - ID of playlist
///
/// # Returns
/// * `Ok(Vec<Track>)` - Tracks in playlist order
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn get_playlist_tracks_command(playlist_id: i64) -> Result<Vec<Track>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::database::playlist::get_playlist_tracks(&conn, playlist_id)
            .map_err(|e| format!("Failed to get playlist tracks: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Search for tracks within a playlist using fuzzy matching.
///
/// Searches track title, artist, and album fields using SQL LIKE queries.
/// Case-insensitive search with wildcards.
///
/// # Arguments
/// * `playlist_id` - ID of playlist to search within
/// * `query` - Search query string
///
/// # Returns
/// * `Ok(Vec<Track>)` - Matching tracks in playlist order
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn search_playlist_tracks_command(
    playlist_id: i64,
    query: String,
) -> Result<Vec<Track>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::database::playlist::search_playlist_tracks(&conn, playlist_id, &query)
            .map_err(|e| format!("Failed to search playlist tracks: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Add a track to a playlist.
///
/// Appends track to end of playlist using fractional indexing.
/// Prevents duplicate additions via database UNIQUE constraint.
///
/// # Arguments
/// * `playlist_id` - ID of playlist
/// * `track_id` - ID of track to add
///
/// # Returns
/// * `Ok(())` - Track added successfully
/// * `Err(String)` - If track already in playlist or database error
#[tauri::command]
pub async fn add_track_to_playlist_command(
    playlist_id: i64,
    track_id: i64,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::database::playlist::add_track_to_playlist(&conn, playlist_id, track_id)
            .map_err(|e| format!("Failed to add track to playlist: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Remove a track from a playlist.
///
/// Deletes the playlist_tracks entry. Does not update other track positions
/// (fractional indexing advantage).
///
/// # Arguments
/// * `playlist_id` - ID of playlist
/// * `track_id` - ID of track to remove
///
/// # Returns
/// * `Ok(())` - Track removed successfully
/// * `Err(String)` - If database operation fails
#[tauri::command]
pub async fn remove_track_from_playlist_command(
    playlist_id: i64,
    track_id: i64,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::database::playlist::remove_track_from_playlist(&conn, playlist_id, track_id)
            .map_err(|e| format!("Failed to remove track from playlist: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Reorder a track within a playlist via drag-drop.
///
/// Updates only the moved track's position using fractional indexing (O(1) operation).
/// Computes new position between after_track and before_track.
///
/// # Arguments
/// * `playlist_id` - ID of playlist
/// * `track_id` - ID of track to reorder
/// * `after_track_id` - Optional ID of track to insert after (None = beginning)
/// * `before_track_id` - Optional ID of track to insert before (None = end)
///
/// # Returns
/// * `Ok(())` - Track reordered successfully
/// * `Err(String)` - If database operation fails
#[tauri::command]
pub async fn reorder_playlist_track_command(
    playlist_id: i64,
    track_id: i64,
    after_track_id: Option<i64>,
    before_track_id: Option<i64>,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::database::playlist::reorder_playlist_track(
            &conn,
            playlist_id,
            track_id,
            after_track_id,
            before_track_id,
        )
        .map_err(|e| format!("Failed to reorder track: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_playlist_command_signature() {
        // Compile-time check that command signature matches expected pattern
        let _f: fn(String, Option<String>, Vec<String>) -> _ = create_playlist_command;
    }

    #[test]
    fn test_get_playlists_command_signature() {
        let _f: fn() -> _ = get_playlists_command;
    }

    #[test]
    fn test_get_playlist_tracks_command_signature() {
        let _f: fn(i64) -> _ = get_playlist_tracks_command;
    }

    #[test]
    fn test_search_playlist_tracks_command_signature() {
        let _f: fn(i64, String) -> _ = search_playlist_tracks_command;
    }

    #[test]
    fn test_add_track_to_playlist_command_signature() {
        let _f: fn(i64, i64) -> _ = add_track_to_playlist_command;
    }

    #[test]
    fn test_remove_track_from_playlist_command_signature() {
        let _f: fn(i64, i64) -> _ = remove_track_from_playlist_command;
    }

    #[test]
    fn test_reorder_playlist_track_command_signature() {
        let _f: fn(i64, i64, Option<i64>, Option<i64>) -> _ = reorder_playlist_track_command;
    }
}
