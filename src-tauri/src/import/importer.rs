//! Batch importer with atomic transactions.
//!
//! Imports audio files to the database with:
//! - Continue-on-error metadata extraction (failures collected, not fatal)
//! - Batch processing (50 files per transaction for incremental commits)
//! - Atomic transactions (batch either fully commits or rolls back)
//!
//! # Example
//! ```ignore
//! use std::path::PathBuf;
//! use music_library_manager::database::get_memory_connection;
//! use music_library_manager::import::import_batch;
//!
//! let files = vec![PathBuf::from("/music/song.mp3")];
//! let mut conn = get_memory_connection()?;
//! let result = import_batch(&mut conn, files)?;
//!
//! println!("Imported: {}", result.succeeded);
//! println!("Failed: {}", result.failed);
//! for failure in &result.failures {
//!     eprintln!("  {}", failure);
//! }
//! ```

use rusqlite::{params, Connection, Transaction};
use std::path::PathBuf;

use crate::database::{with_transaction, DatabaseError, Result as DbResult};
use crate::metadata::extractor::extract_metadata;
use crate::metadata::sanitize::generate_organized_path;
use crate::models::track::TrackMetadata;

/// Number of files to process per database transaction.
///
/// Matches Python implementation: batch size of 50 provides good balance
/// between commit frequency (for progress visibility) and transaction overhead.
const BATCH_SIZE: usize = 50;

/// Result of a batch import operation.
///
/// Contains both success count and detailed failure information.
/// Failures are non-fatal - import continues and collects all errors
/// for reporting at the end.
#[derive(Debug)]
pub struct ImportResult {
    /// Number of successfully imported files
    pub succeeded: usize,
    /// Number of failed imports (metadata extraction or database errors)
    pub failed: usize,
    /// Detailed error messages for each failure (format: "path: error")
    pub failures: Vec<String>,
}

/// Import a batch of audio files to the database.
///
/// Processes files in chunks of 50, extracting metadata and saving to database.
/// Uses continue-on-error pattern: metadata extraction failures are collected
/// but don't stop the import. Database errors for a batch cause that batch
/// to be marked as failed but other batches continue.
///
/// # Arguments
/// * `conn` - Mutable database connection
/// * `files` - List of audio file paths to import
///
/// # Returns
/// * `Ok(ImportResult)` - Import completed (check succeeded/failed counts)
/// * `Err(DatabaseError)` - Fatal database error (connection lost, etc.)
///
/// # Behavior
/// - Files are processed in batches of 50
/// - Metadata extraction errors are collected, not fatal
/// - Each batch is wrapped in an atomic transaction
/// - Transaction failure marks entire batch as failed
/// - Duplicate paths (UNIQUE constraint) cause batch failure
///
/// # Example
/// ```ignore
/// let files = scan_directory(Path::new("/music"))?;
/// let result = import_batch(&mut conn, files)?;
///
/// if result.failed > 0 {
///     println!("Warnings:");
///     for failure in &result.failures {
///         eprintln!("  {}", failure);
///     }
/// }
/// println!("Imported {} tracks", result.succeeded);
/// ```
pub fn import_batch(conn: &mut Connection, files: Vec<PathBuf>) -> DbResult<ImportResult> {
    let mut total_succeeded = 0;
    let mut total_failures: Vec<String> = Vec::new();

    // Process in batches to commit incrementally (Python pattern: 50 files per tx)
    for chunk in files.chunks(BATCH_SIZE) {
        let mut batch_metadata: Vec<TrackMetadata> = Vec::new();
        let mut extraction_failures: Vec<String> = Vec::new();

        // Extract metadata with continue-on-error
        for path in chunk {
            match extract_metadata(path) {
                Ok(metadata) => batch_metadata.push(metadata),
                Err(e) => {
                    extraction_failures.push(format!("{}: {}", path.display(), e));
                }
            }
        }

        // Collect extraction failures
        total_failures.extend(extraction_failures);

        // Skip database save if no metadata extracted successfully
        if batch_metadata.is_empty() {
            continue;
        }

        // Atomic transaction for batch
        match save_batch(conn, batch_metadata) {
            Ok(count) => total_succeeded += count,
            Err(e) => {
                // Mark entire batch as failed on database error
                for path in chunk {
                    total_failures.push(format!("{}: database error - {}", path.display(), e));
                }
            }
        }
    }

    // Log a summary of failure reasons so the user can see what's going wrong
    if !total_failures.is_empty() {
        // Count failures by error type
        let mut error_counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        for failure in &total_failures {
            // Extract error type from "path: error message" format
            let error_type = failure
                .split(": ")
                .skip(1)
                .collect::<Vec<_>>()
                .join(": ");
            let short_error = if error_type.len() > 80 {
                error_type[..80].to_string()
            } else {
                error_type
            };
            *error_counts.entry(short_error).or_insert(0) += 1;
        }

        log::warn!(
            "Import had {} failures. Breakdown by error type:",
            total_failures.len()
        );
        let mut sorted_errors: Vec<_> = error_counts.into_iter().collect();
        sorted_errors.sort_by(|a, b| b.1.cmp(&a.1));
        for (error, count) in sorted_errors.iter().take(10) {
            log::warn!("  {} x {}", count, error);
        }
    }

    Ok(ImportResult {
        succeeded: total_succeeded,
        failed: total_failures.len(),
        failures: total_failures,
    })
}

/// Save a batch of metadata to the database within a transaction.
///
/// Generates organized paths and inserts tracks. The entire batch
/// either commits successfully or rolls back completely.
///
/// After successful batch insert, fingerprints each track and checks for duplicates.
///
/// # Arguments
/// * `conn` - Database connection
/// * `metadata_list` - List of extracted metadata to save
///
/// # Returns
/// * `Ok(usize)` - Number of tracks successfully inserted
/// * `Err(DatabaseError)` - Transaction failed (rolled back)
fn save_batch(conn: &mut Connection, metadata_list: Vec<TrackMetadata>) -> DbResult<usize> {
    // Track IDs and paths for fingerprinting after commit
    let mut inserted_tracks: Vec<(i64, String)> = Vec::new();

    let count = with_transaction(conn, |tx| {
        let mut count = 0;

        for metadata in metadata_list {
            if let Some(track_id) = insert_track(tx, &metadata)? {
                inserted_tracks.push((track_id, metadata.original_path.clone()));
                count += 1;
            }
            // None = duplicate, silently skipped
        }

        Ok(count)
    })?;

    // FINGERPRINT INTEGRATION POINT
    // After successful transaction commit, fingerprint each newly imported track
    // This is best-effort: fingerprinting failures are logged but don't block import
    for (track_id, path) in inserted_tracks {
        // Fingerprint the new track (best-effort, non-blocking)
        match crate::fingerprint::chromaprint::fingerprint_track(std::path::Path::new(&path)) {
            Ok((fp, duration)) => {
                if let Err(e) = crate::fingerprint::chromaprint::save_fingerprint(conn, track_id, &fp, duration) {
                    log::warn!("Failed to save fingerprint for track {}: {}", track_id, e);
                }

                // Check for fingerprint duplicates
                match crate::dedup::fingerprint::detect_fingerprint_duplicates(conn, track_id) {
                    Ok(dups) => {
                        for (dup_id, score) in dups {
                            if let Err(e) = crate::dedup::fingerprint::process_fingerprint_duplicate(conn, track_id, dup_id, score) {
                                log::warn!("Failed to process fingerprint duplicate for track {}: {}", track_id, e);
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!("Failed to detect fingerprint duplicates for track {}: {}", track_id, e);
                    }
                }
            }
            Err(e) => {
                log::warn!("Failed to fingerprint track during import: {} - {}", path, e);
            }
        }
    }

    Ok(count)
}

/// Insert a single track into the database, skipping duplicates.
///
/// Generates the organized path from metadata and inserts all fields.
/// Uses INSERT OR IGNORE so duplicate original_path entries are skipped.
///
/// # Returns
/// * `Ok(Some(i64))` - Track ID of the newly inserted track
/// * `Ok(None)` - Track already exists (skipped)
/// * `Err(DatabaseError)` - If insert fails
fn insert_track(tx: &Transaction, metadata: &TrackMetadata) -> Result<Option<i64>, DatabaseError> {
    let organized_path = generate_organized_path(metadata);

    let rows_changed = tx.execute(
        "INSERT OR IGNORE INTO tracks (artist, album_artist, album, title, genre, year, bitrate, duration, format, original_path, organized_path)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            metadata.artist,
            metadata.album_artist,
            metadata.album,
            metadata.title,
            metadata.genre,
            metadata.year,
            metadata.bitrate,
            metadata.duration,
            metadata.format,
            metadata.original_path,
            organized_path,
        ],
    )?;

    if rows_changed > 0 {
        Ok(Some(tx.last_insert_rowid()))
    } else {
        Ok(None) // Duplicate, skipped
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::get_memory_connection;
    use std::fs::File;
    use tempfile::tempdir;

    // ===== ImportResult tests =====

    #[test]
    fn test_import_result_debug() {
        let result = ImportResult {
            succeeded: 10,
            failed: 2,
            failures: vec!["error1".to_string(), "error2".to_string()],
        };
        let debug = format!("{:?}", result);
        assert!(debug.contains("succeeded: 10"));
        assert!(debug.contains("failed: 2"));
    }

    // ===== import_batch tests =====

    #[test]
    fn test_import_batch_empty() {
        let mut conn = get_memory_connection().unwrap();
        let result = import_batch(&mut conn, vec![]).unwrap();

        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 0);
        assert!(result.failures.is_empty());
    }

    #[test]
    fn test_import_batch_nonexistent_files() {
        let mut conn = get_memory_connection().unwrap();
        let files = vec![
            PathBuf::from("/nonexistent/file1.mp3"),
            PathBuf::from("/nonexistent/file2.flac"),
        ];

        let result = import_batch(&mut conn, files).unwrap();

        // All should fail - files don't exist
        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 2);
        assert_eq!(result.failures.len(), 2);
        assert!(result.failures[0].contains("nonexistent"));
    }

    #[test]
    fn test_import_batch_invalid_audio_files() {
        let dir = tempdir().unwrap();

        // Create files that exist but aren't valid audio
        let file1 = dir.path().join("fake.mp3");
        let file2 = dir.path().join("fake.flac");
        File::create(&file1).unwrap();
        File::create(&file2).unwrap();

        let mut conn = get_memory_connection().unwrap();
        let result = import_batch(&mut conn, vec![file1, file2]).unwrap();

        // Should fail - empty files aren't valid audio
        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 2);
    }

    #[test]
    fn test_import_batch_continues_on_error() {
        let dir = tempdir().unwrap();

        // Mix of valid-looking and invalid files
        let invalid = dir.path().join("invalid.mp3");
        File::create(&invalid).unwrap();

        let mut conn = get_memory_connection().unwrap();
        let result = import_batch(&mut conn, vec![invalid]).unwrap();

        // Import should complete (not panic) even with invalid files
        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 1);
    }

    // ===== Batch size tests =====

    #[test]
    fn test_batch_size_constant() {
        // Verify batch size matches Python implementation
        assert_eq!(BATCH_SIZE, 50);
    }

    // ===== insert_track tests =====

    #[test]
    fn test_insert_track_generates_organized_path() {
        let mut conn = get_memory_connection().unwrap();

        let metadata = TrackMetadata {
            artist: "test artist".to_string(),
            album_artist: "test album artist".to_string(),
            album: "test album".to_string(),
            title: "test track".to_string(),
            genre: Some("rock".to_string()),
            year: Some(2024),
            bitrate: Some(320),
            duration: Some(180),
            format: "mp3".to_string(),
            original_path: "/test/path.mp3".to_string(),
        };

        // Use save_batch to test insert_track (which it calls)
        let result = save_batch(&mut conn, vec![metadata]).unwrap();
        assert_eq!(result, 1);

        // Verify organized_path was generated
        let organized: String = conn
            .query_row(
                "SELECT organized_path FROM tracks WHERE original_path = '/test/path.mp3'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(organized, "test album artist/test album/test track.mp3");
    }

    #[test]
    fn test_insert_track_duplicate_path_skipped() {
        let mut conn = get_memory_connection().unwrap();

        let metadata1 = TrackMetadata {
            artist: "artist1".to_string(),
            album_artist: "artist1".to_string(),
            album: "album1".to_string(),
            title: "title1".to_string(),
            genre: None,
            year: None,
            bitrate: None,
            duration: None,
            format: "mp3".to_string(),
            original_path: "/same/path.mp3".to_string(),
        };

        let metadata2 = TrackMetadata {
            artist: "artist2".to_string(),
            album_artist: "artist2".to_string(),
            album: "album2".to_string(),
            title: "title2".to_string(),
            genre: None,
            year: None,
            bitrate: None,
            duration: None,
            format: "mp3".to_string(),
            original_path: "/same/path.mp3".to_string(), // Same path!
        };

        // First insert should succeed
        let result1 = save_batch(&mut conn, vec![metadata1]).unwrap();
        assert_eq!(result1, 1);

        // Second insert should be silently skipped (not fail the batch)
        let result2 = save_batch(&mut conn, vec![metadata2]).unwrap();
        assert_eq!(result2, 0);
    }
}
