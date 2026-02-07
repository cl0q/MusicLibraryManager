//! Import command handler for Tauri frontend integration.
//!
//! Provides the import_directory command that can be invoked from the UI
//! to scan a directory and import audio files to the library.
//!
//! # Frontend Usage (TypeScript)
//! ```typescript
//! import { invoke } from "@tauri-apps/api/tauri";
//!
//! const result = await invoke<ImportResponse>("import_directory", {
//!     directory: "/path/to/music"
//! });
//!
//! console.log(`Imported ${result.succeeded} files`);
//! if (result.failed > 0) {
//!     console.warn(`Failed: ${result.failures.join(", ")}`);
//! }
//! ```

use std::path::PathBuf;

use serde::Serialize;

use crate::database::get_connection;
use crate::import::{import_batch, scan_directory};

/// Response from import_directory command.
///
/// Serialized to JSON for frontend consumption.
#[derive(Debug, Serialize)]
pub struct ImportResponse {
    /// Number of successfully imported files
    pub succeeded: usize,
    /// Number of failed imports
    pub failed: usize,
    /// Error messages for failed imports
    pub failures: Vec<String>,
}

/// Import audio files from a directory to the library.
///
/// Scans the specified directory recursively for audio files,
/// extracts metadata, and imports to the database.
///
/// # Arguments
/// * `directory` - Path to directory to scan
///
/// # Returns
/// * `Ok(ImportResponse)` - Import result with success/failure counts
/// * `Err(String)` - Error message if import failed
///
/// # Errors
/// - Directory does not exist or is not a directory
/// - No audio files found in directory
/// - Database connection failed
///
/// # Example (TypeScript)
/// ```typescript
/// const result = await invoke("import_directory", {
///     directory: "/Users/me/Music"
/// });
/// ```
#[tauri::command]
pub async fn import_directory(directory: String) -> Result<ImportResponse, String> {
    let dir_path = PathBuf::from(&directory);

    // Validate directory exists
    if !dir_path.exists() {
        return Err(format!("Directory does not exist: {}", directory));
    }

    if !dir_path.is_dir() {
        return Err(format!("Path is not a directory: {}", directory));
    }

    // Scan for audio files
    let files = scan_directory(&dir_path).map_err(|e| format!("Scan error: {}", e))?;

    let file_count = files.len();
    log::info!("Found {} audio files in {}", file_count, directory);

    // Get database connection
    // TODO: Phase 6 will make database path configurable
    // For now, use default path in current working directory
    let db_path = PathBuf::from("music_library.db");
    let mut conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    // Import files
    let result = import_batch(&mut conn, files).map_err(|e| format!("Import error: {}", e))?;

    let skipped = file_count - result.succeeded - result.failed;
    log::info!(
        "Import complete: {} new, {} skipped (already imported), {} failed out of {} total files",
        result.succeeded,
        skipped,
        result.failed,
        file_count
    );

    Ok(ImportResponse {
        succeeded: result.succeeded,
        failed: result.failed,
        failures: result.failures,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_import_response_serialize() {
        let response = ImportResponse {
            succeeded: 10,
            failed: 2,
            failures: vec!["error1".to_string(), "error2".to_string()],
        };

        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"succeeded\":10"));
        assert!(json.contains("\"failed\":2"));
        assert!(json.contains("\"failures\""));
    }

    // Note: Full integration tests for import_directory would require
    // actual audio files. The underlying scan_directory and import_batch
    // functions have comprehensive unit tests in their respective modules.
}
