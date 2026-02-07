//! Search command handler for Tauri frontend integration.
//!
//! Provides the search_library command that can be invoked from the UI
//! to search tracks with fuzzy matching.
//!
//! # Frontend Usage (TypeScript)
//! ```typescript
//! import { invoke } from "@tauri-apps/api/tauri";
//!
//! interface SearchResult {
//!     track: Track;
//!     score: number;
//! }
//!
//! const results = await invoke<SearchResult[]>("search_library", {
//!     query: "daft punk"
//! });
//!
//! results.forEach(r => console.log(`${r.track.metadata.title} (${r.score})`));
//! ```

use std::path::PathBuf;

use crate::database::get_connection;
use crate::models::track::Track;
use crate::search::query;
use crate::search::query::{get_all_tracks, search_tracks, SearchResult};

/// Search the music library with fuzzy matching.
///
/// Searches across artist, album, and title fields using Jaro-Winkler
/// and Levenshtein algorithms for typo tolerance.
///
/// # Arguments
/// * `query` - Search query string
///
/// # Returns
/// * `Ok(Vec<SearchResult>)` - Matched tracks sorted by score descending
/// * `Err(String)` - Error message if search failed
///
/// # Errors
/// - Database connection failed
/// - Query execution failed
///
/// # Example (TypeScript)
/// ```typescript
/// // Search with typo tolerance
/// const results = await invoke("search_library", {
///     query: "beatls"  // Will match "Beatles"
/// });
/// ```
#[tauri::command]
pub async fn search_library(query: String) -> Result<Vec<SearchResult>, String> {
    // TODO: Phase 6 will make database path configurable
    // For now, use default path in current working directory
    let db_path = PathBuf::from("music_library.db");

    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    let results = search_tracks(&conn, &query).map_err(|e| format!("Search error: {}", e))?;

    log::info!("Search '{}' returned {} results", query, results.len());

    Ok(results)
}

/// Get all tracks in the library.
///
/// Returns all tracks sorted by date_added descending (newest first).
/// Use this for displaying the full library when no search query is active.
///
/// # Returns
/// * `Ok(Vec<Track>)` - All tracks in the library
/// * `Err(String)` - Error message if query failed
///
/// # Example (TypeScript)
/// ```typescript
/// const tracks = await invoke("get_library_tracks");
/// tracks.forEach(t => console.log(`${t.metadata.artist} - ${t.metadata.title}`));
/// ```
#[tauri::command]
pub async fn get_library_tracks() -> Result<Vec<Track>, String> {
    let db_path = PathBuf::from("music_library.db");

    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    let tracks = get_all_tracks(&conn).map_err(|e| format!("Query error: {}", e))?;

    log::info!("get_library_tracks returned {} tracks", tracks.len());

    Ok(tracks)
}

/// Get only tracks that exist locally on disk (organized_path IS NOT NULL).
///
/// Returns local library tracks, excluding undownloaded streaming tracks.
/// This is used for the Library view in Phase 9.
///
/// # Returns
/// * `Ok(Vec<Track>)` - Local tracks sorted by date_added descending
/// * `Err(String)` - Error message if query failed
///
/// # Example (TypeScript)
/// ```typescript
/// const libraryTracks = await invoke("get_library_tracks_only");
/// console.log(`Library has ${libraryTracks.length} local tracks`);
/// ```
#[tauri::command]
pub async fn get_library_tracks_only() -> Result<Vec<Track>, String> {
    let db_path = PathBuf::from("music_library.db");

    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    let tracks = query::get_library_tracks_only(&conn).map_err(|e| format!("Query error: {}", e))?;

    log::info!("get_library_tracks_only returned {} tracks", tracks.len());

    Ok(tracks)
}

/// Get only streaming tracks not yet downloaded (organized_path IS NULL with track_sources).
///
/// Returns remote tracks that have streaming source associations but haven't been downloaded.
/// This is used for the Remote view in Phase 9.
///
/// # Returns
/// * `Ok(Vec<Track>)` - Remote tracks sorted by date_added descending
/// * `Err(String)` - Error message if query failed
///
/// # Example (TypeScript)
/// ```typescript
/// const remoteTracks = await invoke("get_remote_tracks_only");
/// console.log(`${remoteTracks.length} tracks waiting to be downloaded`);
/// ```
#[tauri::command]
pub async fn get_remote_tracks_only() -> Result<Vec<Track>, String> {
    let db_path = PathBuf::from("music_library.db");

    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    let tracks = query::get_remote_tracks_only(&conn).map_err(|e| format!("Query error: {}", e))?;

    log::info!("get_remote_tracks_only returned {} tracks", tracks.len());

    Ok(tracks)
}

/// Get count of undownloaded streaming tracks for sidebar badge.
///
/// Returns the count of remote tracks (organized_path IS NULL with track_sources).
/// This is used for displaying the badge count in the Remote view.
///
/// # Returns
/// * `Ok(i64)` - Count of remote tracks
/// * `Err(String)` - Error message if query failed
///
/// # Example (TypeScript)
/// ```typescript
/// const count = await invoke("get_remote_track_count");
/// console.log(`Remote badge: ${count}`);
/// ```
#[tauri::command]
pub async fn get_remote_track_count() -> Result<i64, String> {
    let db_path = PathBuf::from("music_library.db");

    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    let count = query::count_remote_tracks(&conn).map_err(|e| format!("Query error: {}", e))?;

    log::info!("get_remote_track_count returned {}", count);

    Ok(count)
}

/// Get total storage size of all tracks in the library.
///
/// Calculates total bytes by summing file sizes from original_path column.
/// Skips files that cannot be accessed (moved/deleted).
///
/// # Returns
/// * `Ok(u64)` - Total bytes of all accessible track files
/// * `Err(String)` - If database query fails
///
/// # Example (TypeScript)
/// ```typescript
/// const bytes = await invoke("get_library_storage_size");
/// const gb = (bytes / (1024 ** 3)).toFixed(2);
/// console.log(`Library size: ${gb} GB`);
/// ```
#[tauri::command]
pub async fn get_library_storage_size() -> Result<u64, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let mut stmt = conn
            .prepare("SELECT original_path FROM tracks")
            .map_err(|e| format!("Failed to prepare query: {}", e))?;

        let paths: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .map_err(|e| format!("Failed to query tracks: {}", e))?
            .filter_map(|r| r.ok())
            .collect();

        let mut total_size: u64 = 0;
        for path in paths {
            if let Ok(metadata) = std::fs::metadata(&path) {
                total_size += metadata.len();
            }
        }

        Ok(total_size)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: Full integration tests for search_library would require
    // a database with tracks. The underlying search_tracks function
    // has comprehensive unit tests in the search::query module.

    #[test]
    fn test_search_result_serializable() {
        // Verify SearchResult can be serialized (required for Tauri)
        use crate::models::track::{Track, TrackMetadata};

        let track = Track::new(
            TrackMetadata::new(
                "artist".to_string(),
                "artist".to_string(),
                "album".to_string(),
                "title".to_string(),
                None,
                None,
                None,
                None,
                "mp3".to_string(),
                "/path/to/file.mp3".to_string(),
            ),
            "artist/album/title.mp3".to_string(),
        );

        let result = SearchResult { track, score: 0.95 };

        let json = serde_json::to_string(&result);
        assert!(json.is_ok(), "SearchResult should be serializable");

        let json_str = json.unwrap();
        assert!(json_str.contains("\"score\":0.95"));
        assert!(json_str.contains("\"artist\""));
    }
}
