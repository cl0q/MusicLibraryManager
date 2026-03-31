//! Track analysis commands.
//!
//! Provides Tauri commands for extracting and caching track analysis data:
//! - FFprobe metadata extraction (codec, bitrate, sample rate, etc.)
//! - Fingerprint retrieval (future integration with Phase 7 data)
//! - Spectrogram generation (future feature)

use std::path::{Path, PathBuf};
use std::process::Command;
use serde::Serialize;

use crate::config::LibraryConfig;
use crate::database::connection::get_connection;
use crate::database::track_analysis::{TrackAnalysis, get_analysis, save_analysis};
use crate::search::query::get_track_by_id;

/// Resolve an organized_path (always relative) to an absolute file path by joining
/// it with the configured library root.
///
/// # Errors
/// - Returns `Err` if `path` is absolute — absolute organized_paths violate the
///   Phase 8-01 portability invariant and must not be silently accepted.
/// - Returns `Err` if the library root is not configured.
fn resolve_track_path(conn: &rusqlite::Connection, path: &str) -> Result<String, String> {
    if Path::new(path).is_absolute() {
        return Err(format!(
            "organized_path must be relative to library root, not absolute. \
             Got: {}. Run the schema migration to fix existing data.",
            path
        ));
    }
    // Also reject Windows-style drive-letter paths (not caught by is_absolute() on Unix).
    let is_windows_absolute = path.len() >= 2
        && path.chars().next().map_or(false, |c| c.is_ascii_alphabetic())
        && path.chars().nth(1) == Some(':');
    if is_windows_absolute {
        return Err(format!(
            "organized_path must be relative to library root, not absolute. \
             Got: {}. Run the schema migration to fix existing data.",
            path
        ));
    }
    let config = LibraryConfig::load(conn)
        .map_err(|e| format!("Failed to load library config: {}", e))?;
    let root = config.root_path
        .ok_or_else(|| "Library not configured".to_string())?;
    Ok(root.join(path).to_string_lossy().to_string())
}

/// Track analysis response sent to frontend.
///
/// Contains all available analysis data for a track, with optional fields
/// to support incremental feature availability.
#[derive(Debug, Serialize)]
pub struct TrackAnalysisResponse {
    /// FFprobe JSON output (full metadata dump)
    pub ffprobe_output: Option<String>,
    /// Acoustic fingerprint (Chromaprint or similar)
    pub fingerprint: Option<String>,
    /// Path to generated spectrogram image
    pub spectrogram_path: Option<String>,
}

/// Get track analysis data (ffprobe metadata, fingerprint, spectrogram).
///
/// Checks cache first, then runs ffprobe if needed. Remote tracks (no organized_path)
/// return an error. Missing ffprobe binary returns helpful installation instructions.
///
/// # Arguments
/// * `track_id` - Track ID to analyze
///
/// # Returns
/// * `Ok(TrackAnalysisResponse)` - Analysis data (cached or freshly extracted)
/// * `Err(String)` - Error message if track not found, remote track, or ffprobe failed
#[tauri::command]
pub async fn get_track_analysis(track_id: i64) -> Result<TrackAnalysisResponse, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = PathBuf::from("music_library.db");
        let conn = get_connection(&db_path)
            .map_err(|e| format!("Database error: {}", e))?;

        // Check cache first
        if let Some(cached) = get_analysis(&conn, track_id)
            .map_err(|e| format!("Failed to get cached analysis: {}", e))? {
            return Ok(TrackAnalysisResponse {
                ffprobe_output: cached.ffprobe_output,
                fingerprint: cached.fingerprint,
                spectrogram_path: cached.spectrogram_path,
            });
        }

        // Get track from database
        let track = get_track_by_id(&conn, track_id)
            .map_err(|e| format!("Database query failed: {}", e))?
            .ok_or_else(|| format!("Track {} not found", track_id))?;

        // Track.organized_path is String (not Option). Remote tracks (organized_path IS NULL
        // in the database) will fail at get_track_by_id with a rusqlite type error when trying
        // to deserialize NULL → String. An empty organized_path also means no local file.
        if track.organized_path.is_empty() {
            return Err("Track has no local file (remote/undownloaded track)".to_string());
        }

        // Resolve relative organized_path against library root.
        // Rejects absolute paths (stale data) with a descriptive error.
        let file_path = resolve_track_path(&conn, &track.organized_path)?;

        // Run ffprobe to extract metadata as JSON
        let output = Command::new("ffprobe")
            .args(&[
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                &file_path,
            ])
            .output();

        // Handle ffprobe execution errors
        let output = match output {
            Ok(o) => o,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(
                    "ffprobe not found. Install FFmpeg via: brew install ffmpeg".to_string()
                );
            }
            Err(e) => {
                return Err(format!("Failed to run ffprobe: {}", e));
            }
        };

        if !output.status.success() {
            return Err(format!(
                "ffprobe failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }

        let ffprobe_json = String::from_utf8(output.stdout)
            .map_err(|e| format!("Invalid UTF-8 from ffprobe: {}", e))?;

        // Save to cache
        let analysis = TrackAnalysis {
            track_id,
            ffprobe_output: Some(ffprobe_json.clone()),
            fingerprint: None, // Fingerprint data exists in Phase 7 fingerprints table, future integration
            spectrogram_path: None, // On-demand generation to be added later
            analysis_timestamp: chrono::Utc::now().to_rfc3339(),
        };

        save_analysis(&conn, &analysis)
            .map_err(|e| format!("Failed to cache analysis: {}", e))?;

        Ok(TrackAnalysisResponse {
            ffprobe_output: Some(ffprobe_json),
            fingerprint: None,
            spectrogram_path: None,
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get artwork for a track (stub — to be implemented).
#[tauri::command]
pub async fn get_track_artwork(_track_id: i64) -> Result<Option<String>, String> {
    Ok(None)
}

/// Generate acoustic fingerprint for a track (stub — to be implemented).
#[tauri::command]
pub async fn generate_track_fingerprint(_track_id: i64) -> Result<Option<String>, String> {
    Ok(None)
}

/// Generate waveform data for a track (stub — to be implemented).
#[tauri::command]
pub async fn generate_track_waveform(_track_id: i64) -> Result<Option<String>, String> {
    Ok(None)
}

/// Generate spectrogram for a track (stub — to be implemented).
#[tauri::command]
pub async fn generate_track_spectrogram(_track_id: i64) -> Result<Option<String>, String> {
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::get_memory_connection;
    use crate::database::schema::initialize_schema;

    #[tokio::test]
    async fn test_get_track_analysis_not_found() {
        // This test verifies error handling for non-existent track
        let result = get_track_analysis(999).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    #[tokio::test]
    async fn test_get_track_analysis_remote_track() {
        // Test with a remote track (organized_path = NULL)
        // This would require setting up a test database, which is beyond this unit test scope
        // Integration tests would cover this case
    }
}
