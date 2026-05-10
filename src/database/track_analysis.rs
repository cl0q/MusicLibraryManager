//! Track analysis data storage.
//!
//! Provides database operations for caching track analysis data:
//! - FFprobe metadata output (JSON)
//! - Acoustic fingerprints (future use)
//! - Spectrogram image paths (future use)

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::database::Result as DbResult;

/// Track analysis cache entry.
///
/// Stores technical metadata and analysis data for a track.
/// All fields except track_id and analysis_timestamp are optional
/// to support incremental data population.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackAnalysis {
    /// Track ID (foreign key to tracks table)
    pub track_id: i64,
    /// FFprobe JSON output (full metadata dump)
    pub ffprobe_output: Option<String>,
    /// Acoustic fingerprint (Chromaprint or similar)
    pub fingerprint: Option<String>,
    /// Path to generated spectrogram image
    pub spectrogram_path: Option<String>,
    /// ISO 8601 timestamp of last analysis
    pub analysis_timestamp: String,
}

/// Get cached analysis data for a track.
///
/// Returns None if no cached analysis exists for the track.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID to retrieve analysis for
///
/// # Returns
/// * `Ok(Some(TrackAnalysis))` - Cached analysis data
/// * `Ok(None)` - No cached data exists
/// * `Err(DatabaseError)` - Database query failed
pub fn get_analysis(conn: &Connection, track_id: i64) -> DbResult<Option<TrackAnalysis>> {
    let mut stmt = conn.prepare(
        "SELECT track_id, ffprobe_output, fingerprint, spectrogram_path, analysis_timestamp
         FROM track_analysis
         WHERE track_id = ?",
    )?;

    let result = stmt.query_row([track_id], |row| {
        Ok(TrackAnalysis {
            track_id: row.get(0)?,
            ffprobe_output: row.get(1)?,
            fingerprint: row.get(2)?,
            spectrogram_path: row.get(3)?,
            analysis_timestamp: row.get(4)?,
        })
    });

    match result {
        Ok(analysis) => Ok(Some(analysis)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Save or update analysis data for a track.
///
/// Uses INSERT OR REPLACE to update existing entries or create new ones.
///
/// # Arguments
/// * `conn` - Database connection
/// * `analysis` - Track analysis data to save
///
/// # Returns
/// * `Ok(())` - Analysis data saved successfully
/// * `Err(DatabaseError)` - Database operation failed
pub fn save_analysis(conn: &Connection, analysis: &TrackAnalysis) -> DbResult<()> {
    conn.execute(
        "INSERT OR REPLACE INTO track_analysis (track_id, ffprobe_output, fingerprint, spectrogram_path, analysis_timestamp)
         VALUES (?, ?, ?, ?, ?)",
        (
            &analysis.track_id,
            &analysis.ffprobe_output,
            &analysis.fingerprint,
            &analysis.spectrogram_path,
            &analysis.analysis_timestamp,
        ),
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::get_memory_connection;
    use crate::database::schema::initialize_schema;

    #[test]
    fn test_get_analysis_not_found() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        let result = get_analysis(&conn, 999).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_save_and_get_analysis() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Insert a test track first
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3"],
        )
        .unwrap();

        let track_id = conn.last_insert_rowid();

        // Save analysis data
        let analysis = TrackAnalysis {
            track_id,
            ffprobe_output: Some("{\"format\": \"mp3\"}".to_string()),
            fingerprint: Some("AQAB1234".to_string()),
            spectrogram_path: None,
            analysis_timestamp: "2026-02-07T12:00:00Z".to_string(),
        };

        save_analysis(&conn, &analysis).unwrap();

        // Retrieve and verify
        let retrieved = get_analysis(&conn, track_id).unwrap().unwrap();
        assert_eq!(retrieved.track_id, track_id);
        assert_eq!(
            retrieved.ffprobe_output,
            Some("{\"format\": \"mp3\"}".to_string())
        );
        assert_eq!(retrieved.fingerprint, Some("AQAB1234".to_string()));
        assert!(retrieved.spectrogram_path.is_none());
    }

    #[test]
    fn test_update_existing_analysis() {
        let conn = get_memory_connection().unwrap();
        initialize_schema(&conn).unwrap();

        // Insert a test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3"],
        )
        .unwrap();

        let track_id = conn.last_insert_rowid();

        // Save initial analysis
        let analysis1 = TrackAnalysis {
            track_id,
            ffprobe_output: Some("{\"format\": \"mp3\"}".to_string()),
            fingerprint: None,
            spectrogram_path: None,
            analysis_timestamp: "2026-02-07T12:00:00Z".to_string(),
        };

        save_analysis(&conn, &analysis1).unwrap();

        // Update with new data
        let analysis2 = TrackAnalysis {
            track_id,
            ffprobe_output: Some("{\"format\": \"flac\"}".to_string()),
            fingerprint: Some("AQAB5678".to_string()),
            spectrogram_path: Some("/path/to/spectrogram.png".to_string()),
            analysis_timestamp: "2026-02-07T13:00:00Z".to_string(),
        };

        save_analysis(&conn, &analysis2).unwrap();

        // Verify updated data
        let retrieved = get_analysis(&conn, track_id).unwrap().unwrap();
        assert_eq!(
            retrieved.ffprobe_output,
            Some("{\"format\": \"flac\"}".to_string())
        );
        assert_eq!(retrieved.fingerprint, Some("AQAB5678".to_string()));
        assert_eq!(
            retrieved.spectrogram_path,
            Some("/path/to/spectrogram.png".to_string())
        );
        assert_eq!(retrieved.analysis_timestamp, "2026-02-07T13:00:00Z");
    }

    #[test]
    fn test_cascade_delete() {
        let conn = get_memory_connection().unwrap();
        // Enable foreign keys for this test
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        initialize_schema(&conn).unwrap();

        // Insert track and analysis
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            ["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3"],
        )
        .unwrap();

        let track_id = conn.last_insert_rowid();

        let analysis = TrackAnalysis {
            track_id,
            ffprobe_output: Some("{\"format\": \"mp3\"}".to_string()),
            fingerprint: None,
            spectrogram_path: None,
            analysis_timestamp: "2026-02-07T12:00:00Z".to_string(),
        };

        save_analysis(&conn, &analysis).unwrap();

        // Delete the track
        conn.execute("DELETE FROM tracks WHERE id = ?", [track_id])
            .unwrap();

        // Verify analysis was also deleted (CASCADE)
        let result = get_analysis(&conn, track_id).unwrap();
        assert!(result.is_none());
    }
}
