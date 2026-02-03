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
use crate::search::query::{search_tracks, SearchResult};

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
