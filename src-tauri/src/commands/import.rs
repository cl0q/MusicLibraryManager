//! Import command handler for Tauri frontend integration.
//!
//! Provides the import_directory command that scans a directory and imports
//! audio files in the background, emitting progress events to the frontend.

use std::path::PathBuf;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::database::get_connection;
use crate::import::{import_batch, scan_directory};

/// Response from import_directory command (returned immediately).
#[derive(Debug, Clone, Serialize)]
pub struct ImportStartedResponse {
    /// Number of audio files found to import
    pub file_count: usize,
}

/// Event payload emitted when background import completes.
#[derive(Debug, Clone, Serialize)]
pub struct ImportCompleteEvent {
    pub succeeded: usize,
    pub failed: usize,
    pub skipped: usize,
    pub total: usize,
    pub failure_summary: Vec<String>,
}

/// Scan a directory and import audio files in the background.
///
/// Returns immediately with the number of files found. The actual import
/// runs on a background thread and emits events:
/// - `import-complete`: When the import finishes (with result counts)
#[tauri::command]
pub async fn import_directory(
    app_handle: AppHandle,
    directory: String,
) -> Result<ImportStartedResponse, String> {
    let dir_path = PathBuf::from(&directory);

    if !dir_path.exists() {
        return Err(format!("Directory does not exist: {}", directory));
    }

    if !dir_path.is_dir() {
        return Err(format!("Path is not a directory: {}", directory));
    }

    // Scan for audio files (fast, stays on main thread)
    let files = scan_directory(&dir_path).map_err(|e| format!("Scan error: {}", e))?;

    let file_count = files.len();
    log::info!("Found {} audio files in {}", file_count, directory);

    if file_count == 0 {
        let _ = app_handle.emit(
            "import-complete",
            ImportCompleteEvent {
                succeeded: 0,
                failed: 0,
                skipped: 0,
                total: 0,
                failure_summary: vec![],
            },
        );
        return Ok(ImportStartedResponse { file_count: 0 });
    }

    // Spawn background thread for the heavy import work
    std::thread::spawn(move || {
        let db_path = PathBuf::from("music_library.db");
        let mut conn = match get_connection(&db_path) {
            Ok(c) => c,
            Err(e) => {
                log::error!("Import background thread: database error: {}", e);
                let _ = app_handle.emit(
                    "import-complete",
                    ImportCompleteEvent {
                        succeeded: 0,
                        failed: file_count,
                        skipped: 0,
                        total: file_count,
                        failure_summary: vec![format!("Database error: {}", e)],
                    },
                );
                return;
            }
        };

        match import_batch(&mut conn, files) {
            Ok(result) => {
                let skipped = file_count - result.succeeded - result.failed;
                log::info!(
                    "Import complete: {} new, {} skipped, {} failed out of {} total",
                    result.succeeded,
                    skipped,
                    result.failed,
                    file_count
                );

                // Take only first 20 failures for the event payload
                let failure_summary: Vec<String> =
                    result.failures.into_iter().take(20).collect();

                let _ = app_handle.emit(
                    "import-complete",
                    ImportCompleteEvent {
                        succeeded: result.succeeded,
                        failed: result.failed,
                        skipped,
                        total: file_count,
                        failure_summary,
                    },
                );
            }
            Err(e) => {
                log::error!("Import failed: {}", e);
                let _ = app_handle.emit(
                    "import-complete",
                    ImportCompleteEvent {
                        succeeded: 0,
                        failed: file_count,
                        skipped: 0,
                        total: file_count,
                        failure_summary: vec![format!("Import error: {}", e)],
                    },
                );
            }
        }
    });

    Ok(ImportStartedResponse { file_count })
}

/// Import a playlist from a file (M3U, M3U8, or Spotify JSON).
///
/// Parses the file, fuzzy-matches tracks against the library,
/// creates a new Regular playlist, and adds matched tracks in order.
#[tauri::command]
pub async fn import_playlist_command(
    playlist_name: String,
    file_path: String,
) -> Result<crate::import::ImportPlaylistResult, String> {
    let db_path = std::path::PathBuf::from("music_library.db");
    let mut conn = crate::database::get_connection(&db_path)
        .map_err(|e| format!("Database error: {}", e))?;

    crate::import::import_playlist_from_file(&mut conn, &playlist_name, &file_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_import_started_response_serialize() {
        let response = ImportStartedResponse { file_count: 100 };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"file_count\":100"));
    }

    #[test]
    fn test_import_complete_event_serialize() {
        let event = ImportCompleteEvent {
            succeeded: 10,
            failed: 2,
            skipped: 88,
            total: 100,
            failure_summary: vec!["error1".to_string()],
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"succeeded\":10"));
        assert!(json.contains("\"skipped\":88"));
    }
}
