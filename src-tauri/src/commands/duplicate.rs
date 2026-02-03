//! Tauri command handler for duplicate detection.
//!
//! Provides the `detect_duplicates` command that can be invoked from the UI
//! to scan the library and mark duplicate tracks.

use std::path::PathBuf;

use crate::database::get_connection;
use crate::duplicate::detector::mark_duplicates;

/// Response from the duplicate detection command.
#[derive(Debug, serde::Serialize)]
pub struct DuplicateResponse {
    /// Number of tracks marked as duplicates.
    pub duplicates_found: usize,
}

/// Detects and marks duplicate tracks in the library.
///
/// Scans all tracks with complete metadata (artist, album, title) and marks
/// lower-quality versions as duplicates, keeping the highest quality copy.
///
/// # Returns
/// * `Ok(DuplicateResponse)` - Number of duplicates found and marked
/// * `Err(String)` - Error message if detection failed
///
/// # Example (from frontend)
/// ```javascript
/// const result = await invoke('detect_duplicates');
/// console.log(`Found ${result.duplicates_found} duplicates`);
/// ```
#[tauri::command]
pub async fn detect_duplicates() -> Result<DuplicateResponse, String> {
    // TODO: Make database path configurable (Phase 6)
    let db_path = PathBuf::from("music_library.db");

    let mut conn =
        get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    let count =
        mark_duplicates(&mut conn).map_err(|e| format!("Duplicate detection error: {}", e))?;

    Ok(DuplicateResponse {
        duplicates_found: count,
    })
}
