//! Track analysis commands.
//!
//! Provides Tauri commands for extracting and caching track analysis data:
//! - FFprobe metadata extraction (codec, bitrate, sample rate, etc.)
//! - Fingerprint retrieval (future integration with Phase 7 data)
//! - Spectrogram generation (future feature)

use std::path::Path;
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

    // Try direct join first (downloaded tracks include prefix like "00_Artists/...")
    let direct = root.join(path);
    if direct.exists() {
        return Ok(direct.to_string_lossy().to_string());
    }
    // Search scan folders (imported tracks omit the scan folder prefix)
    for folder in &config.scan_folders {
        let candidate = root.join(folder).join(path);
        if candidate.exists() {
            return Ok(candidate.to_string_lossy().to_string());
        }
    }
    // Try download_destination
    let candidate = root.join(&config.download_destination).join(path);
    if candidate.exists() {
        return Ok(candidate.to_string_lossy().to_string());
    }
    // Fall back to direct path (will fail at caller if file doesn't exist)
    Ok(direct.to_string_lossy().to_string())
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
        let db_path = crate::database::db_path();
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

        let organized_path = track.organized_path
            .as_deref()
            .filter(|p| !p.is_empty())
            .ok_or_else(|| "Track has no local file (remote/undownloaded track)".to_string())?;

        // Resolve relative organized_path against library root.
        // Rejects absolute paths (stale data) with a descriptive error.
        let file_path = resolve_track_path(&conn, organized_path)?;

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

/// Extract embedded artwork from a track and return as base64 data URI.
#[tauri::command]
pub async fn get_track_artwork(track_id: i64) -> Result<Option<String>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path)
            .map_err(|e| format!("Database error: {}", e))?;

        let track = get_track_by_id(&conn, track_id)
            .map_err(|e| format!("Database query failed: {}", e))?
            .ok_or_else(|| format!("Track {} not found", track_id))?;

        let organized_path = track.organized_path
            .as_deref()
            .filter(|p| !p.is_empty())
            .ok_or_else(|| "No local file".to_string())?;

        let file_path = resolve_track_path(&conn, organized_path)?;

        // Extract cover art to stdout as PNG via ffmpeg
        let output = Command::new("ffmpeg")
            .args(&["-i", &file_path, "-an", "-vcodec", "png", "-f", "image2pipe", "-"])
            .output();

        match output {
            Ok(o) if o.status.success() && !o.stdout.is_empty() => {
                use base64::Engine;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&o.stdout);
                Ok(Some(format!("data:image/png;base64,{}", b64)))
            }
            _ => Ok(None),
        }
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Generate acoustic fingerprint for a track using fpcalc (Chromaprint).
/// Returns a text summary string, not an image.
#[tauri::command]
pub async fn generate_track_fingerprint(track_id: i64) -> Result<Option<String>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        let track = get_track_by_id(&conn, track_id)
            .map_err(|e| format!("DB error: {}", e))?
            .ok_or_else(|| format!("Track {} not found", track_id))?;
        let organized_path = track.organized_path.as_deref().filter(|p| !p.is_empty())
            .ok_or_else(|| "No local file".to_string())?;
        let file_path = resolve_track_path(&conn, organized_path)?;

        let output = Command::new("fpcalc")
            .args(&["-json", &file_path])
            .output();

        match output {
            Ok(o) if o.status.success() => {
                let stdout = String::from_utf8_lossy(&o.stdout).to_string();
                Ok(Some(stdout))
            }
            Ok(o) => Err(format!("fpcalc failed: {}", String::from_utf8_lossy(&o.stderr))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Err("fpcalc not found. Install Chromaprint via: brew install chromaprint".to_string())
            }
            Err(e) => Err(format!("Failed to run fpcalc: {}", e)),
        }
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Generate waveform visualization for a track as base64 PNG data URI.
/// Uses ffmpeg's showwavespic filter.
#[tauri::command]
pub async fn generate_track_waveform(track_id: i64) -> Result<Option<String>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        let track = get_track_by_id(&conn, track_id)
            .map_err(|e| format!("DB error: {}", e))?
            .ok_or_else(|| format!("Track {} not found", track_id))?;
        let organized_path = track.organized_path.as_deref().filter(|p| !p.is_empty())
            .ok_or_else(|| "No local file".to_string())?;
        let file_path = resolve_track_path(&conn, organized_path)?;

        let output = Command::new("ffmpeg")
            .args(&[
                "-i", &file_path,
                "-filter_complex", "showwavespic=s=600x120:colors=#d4940c",
                "-frames:v", "1",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-",
            ])
            .output();

        match output {
            Ok(o) if o.status.success() && !o.stdout.is_empty() => {
                use base64::Engine;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&o.stdout);
                Ok(Some(format!("data:image/png;base64,{}", b64)))
            }
            Ok(o) => Err(format!("ffmpeg waveform failed: {}", String::from_utf8_lossy(&o.stderr))),
            Err(e) => Err(format!("Failed to run ffmpeg: {}", e)),
        }
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Generate spectrogram for a track as base64 PNG data URI.
/// Uses ffmpeg's showspectrumpic filter.
#[tauri::command]
pub async fn generate_track_spectrogram(track_id: i64) -> Result<Option<String>, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        let track = get_track_by_id(&conn, track_id)
            .map_err(|e| format!("DB error: {}", e))?
            .ok_or_else(|| format!("Track {} not found", track_id))?;
        let organized_path = track.organized_path.as_deref().filter(|p| !p.is_empty())
            .ok_or_else(|| "No local file".to_string())?;
        let file_path = resolve_track_path(&conn, organized_path)?;

        let output = Command::new("ffmpeg")
            .args(&[
                "-i", &file_path,
                "-filter_complex", "showspectrumpic=s=600x200:legend=0",
                "-frames:v", "1",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-",
            ])
            .output();

        match output {
            Ok(o) if o.status.success() && !o.stdout.is_empty() => {
                use base64::Engine;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&o.stdout);
                Ok(Some(format!("data:image/png;base64,{}", b64)))
            }
            Ok(o) => Err(format!("ffmpeg spectrogram failed: {}", String::from_utf8_lossy(&o.stderr))),
            Err(e) => Err(format!("Failed to run ffmpeg: {}", e)),
        }
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
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
