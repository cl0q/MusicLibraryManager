//! Chromaprint fingerprint generation and database storage.
//!
//! Provides functions to generate acoustic fingerprints from audio files using the
//! Chromaprint algorithm. Fingerprints are stored in the database as BLOBs for
//! incremental processing and duplicate detection.

use crate::audio::decoder::{decode_to_pcm, DecodeError};
use rusqlite::{Connection, Result as SqlResult};
use rusty_chromaprint::{Configuration, Fingerprinter};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum FingerprintError {
    #[error("Decode error: {0}")]
    Decode(#[from] DecodeError),

    #[error("Fingerprint generation failed")]
    GenerationFailed,

    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),
}

/// Result type for batch fingerprinting operations
#[derive(Debug)]
pub struct BatchFingerprintResult {
    pub processed: usize,
    pub failed: Vec<(i64, String)>,
}

/// Generate a Chromaprint fingerprint from PCM samples.
///
/// # Arguments
/// * `samples` - Interleaved i16 PCM samples
/// * `sample_rate` - Sample rate in Hz
/// * `channels` - Number of channels
///
/// # Returns
/// * `Some(Vec<u32>)` - Raw fingerprint as vector of u32 values
/// * `None` - If fingerprint generation fails
pub fn generate_fingerprint(samples: &[i16], sample_rate: u32, channels: u16) -> Option<Vec<u32>> {
    let config = Configuration::preset_test2();
    let mut fingerprinter = Fingerprinter::new(&config);

    // Start fingerprinter
    fingerprinter.start(sample_rate, channels as u32).ok()?;

    // Feed samples
    fingerprinter.consume(samples);

    // Finish and get fingerprint
    fingerprinter.finish();
    let fp = fingerprinter.fingerprint();
    Some(fp.to_vec())
}

/// Generate fingerprint for an audio file.
///
/// # Arguments
/// * `path` - Path to the audio file
///
/// # Returns
/// * `Ok((fingerprint, duration_seconds))` - Fingerprint and track duration
/// * `Err(FingerprintError)` - If fingerprinting fails
pub fn fingerprint_track(path: &Path) -> Result<(Vec<u32>, u32), FingerprintError> {
    // Decode audio to PCM
    let (samples, sample_rate, channels) = decode_to_pcm(path)?;

    // Generate fingerprint
    let fingerprint = generate_fingerprint(&samples, sample_rate, channels)
        .ok_or(FingerprintError::GenerationFailed)?;

    // Calculate duration in seconds
    let duration_seconds = samples.len() as u32 / (sample_rate * channels as u32);

    Ok((fingerprint, duration_seconds))
}

/// Save a fingerprint to the database.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID
/// * `fingerprint` - Raw fingerprint data
/// * `duration_seconds` - Track duration
///
/// # Returns
/// * `Ok(())` - If saved successfully
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn save_fingerprint(
    conn: &Connection,
    track_id: i64,
    fingerprint: &[u32],
    duration_seconds: u32,
) -> SqlResult<()> {
    // Convert Vec<u32> to bytes (little-endian)
    let mut bytes = Vec::with_capacity(fingerprint.len() * 4);
    for &val in fingerprint {
        bytes.extend_from_slice(&val.to_le_bytes());
    }

    conn.execute(
        "INSERT OR REPLACE INTO fingerprints (track_id, fingerprint, duration_seconds)
         VALUES (?1, ?2, ?3)",
        rusqlite::params![track_id, &bytes, duration_seconds],
    )?;

    Ok(())
}

/// Load a fingerprint from the database.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID
///
/// # Returns
/// * `Ok(Some(Vec<u32>))` - If fingerprint found
/// * `Ok(None)` - If no fingerprint exists for this track
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn load_fingerprint(conn: &Connection, track_id: i64) -> SqlResult<Option<Vec<u32>>> {
    let mut stmt = conn.prepare("SELECT fingerprint FROM fingerprints WHERE track_id = ?")?;

    let result = stmt.query_row([track_id], |row| {
        let bytes: Vec<u8> = row.get(0)?;
        Ok(bytes)
    });

    match result {
        Ok(bytes) => {
            // Convert bytes back to Vec<u32> (little-endian)
            let mut fingerprint = Vec::with_capacity(bytes.len() / 4);
            for chunk in bytes.chunks_exact(4) {
                let val = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                fingerprint.push(val);
            }
            Ok(Some(fingerprint))
        }
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e),
    }
}

/// Get tracks that haven't been fingerprinted yet.
///
/// # Arguments
/// * `conn` - Database connection
///
/// # Returns
/// * `Ok(Vec<(i64, String)>)` - List of (track_id, original_path) tuples
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn get_unfingerprinted_tracks(conn: &Connection) -> SqlResult<Vec<(i64, String)>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.original_path
         FROM tracks t
         LEFT JOIN fingerprints f ON t.id = f.track_id
         WHERE f.track_id IS NULL",
    )?;

    let tracks = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<SqlResult<Vec<_>>>()?;

    Ok(tracks)
}

/// Batch fingerprint multiple tracks.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_ids` - List of (track_id, path) tuples to fingerprint
///
/// # Returns
/// * `Ok(BatchFingerprintResult)` - Processing result with success/failure counts
/// * `Err(FingerprintError)` - If database operation fails
pub fn batch_fingerprint(
    conn: &Connection,
    track_ids: &[(i64, String)],
) -> Result<BatchFingerprintResult, FingerprintError> {
    let mut processed = 0;
    let mut failed = Vec::new();

    for (track_id, path) in track_ids {
        match fingerprint_track(Path::new(path)) {
            Ok((fingerprint, duration)) => {
                if let Err(e) = save_fingerprint(conn, *track_id, &fingerprint, duration) {
                    log::error!("Failed to save fingerprint for track {}: {}", track_id, e);
                    failed.push((*track_id, format!("Database error: {}", e)));
                } else {
                    processed += 1;
                }
            }
            Err(e) => {
                log::warn!("Failed to fingerprint track {} at {}: {}", track_id, path, e);
                failed.push((*track_id, format!("Fingerprint error: {}", e)));
            }
        }
    }

    Ok(BatchFingerprintResult { processed, failed })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn test_fingerprint_blob_roundtrip() {
        // Create in-memory database with fingerprints table
        let conn = Connection::open_in_memory().unwrap();
        conn.execute(
            "CREATE TABLE fingerprints (
                track_id INTEGER PRIMARY KEY,
                fingerprint BLOB NOT NULL,
                duration_seconds INTEGER NOT NULL,
                acoustid TEXT,
                musicbrainz_recording_id TEXT
            )",
            [],
        )
        .unwrap();

        // Test data
        let track_id = 1;
        let original_fingerprint = vec![
            0x12345678u32,
            0xABCDEF01,
            0xDEADBEEF,
            0xCAFEBABE,
            0x00000000,
            0xFFFFFFFF,
        ];
        let duration = 180;

        // Save fingerprint
        save_fingerprint(&conn, track_id, &original_fingerprint, duration).unwrap();

        // Load fingerprint
        let loaded_fingerprint = load_fingerprint(&conn, track_id).unwrap();

        // Verify roundtrip
        assert_eq!(loaded_fingerprint, Some(original_fingerprint));
    }

    #[test]
    fn test_get_unfingerprinted_tracks() {
        // Create in-memory database
        let conn = Connection::open_in_memory().unwrap();
        conn.execute(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                file_format TEXT NOT NULL,
                bitrate INTEGER,
                sample_rate INTEGER,
                channels INTEGER,
                duration_seconds INTEGER,
                file_size_bytes INTEGER NOT NULL,
                date_added TEXT NOT NULL,
                date_modified TEXT NOT NULL
            )",
            [],
        )
        .unwrap();
        conn.execute(
            "CREATE TABLE fingerprints (
                track_id INTEGER PRIMARY KEY,
                fingerprint BLOB NOT NULL,
                duration_seconds INTEGER NOT NULL,
                acoustid TEXT,
                musicbrainz_recording_id TEXT
            )",
            [],
        )
        .unwrap();

        // Insert test tracks
        conn.execute(
            "INSERT INTO tracks (id, title, artist, album, original_path, file_format, file_size_bytes, date_added, date_modified)
             VALUES (1, 'Track 1', 'Artist 1', 'Album 1', '/path/1.mp3', 'MP3', 1000, '2024-01-01', '2024-01-01')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (id, title, artist, album, original_path, file_format, file_size_bytes, date_added, date_modified)
             VALUES (2, 'Track 2', 'Artist 2', 'Album 2', '/path/2.mp3', 'MP3', 2000, '2024-01-01', '2024-01-01')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (id, title, artist, album, original_path, file_format, file_size_bytes, date_added, date_modified)
             VALUES (3, 'Track 3', 'Artist 3', 'Album 3', '/path/3.mp3', 'MP3', 3000, '2024-01-01', '2024-01-01')",
            [],
        )
        .unwrap();

        // Fingerprint track 1 only
        let fingerprint = vec![0x12345678u32];
        save_fingerprint(&conn, 1, &fingerprint, 180).unwrap();

        // Get unfingerprinted tracks
        let unfingerprinted = get_unfingerprinted_tracks(&conn).unwrap();

        // Should return tracks 2 and 3
        assert_eq!(unfingerprinted.len(), 2);
        assert!(unfingerprinted.iter().any(|(id, _)| *id == 2));
        assert!(unfingerprinted.iter().any(|(id, _)| *id == 3));
        assert!(!unfingerprinted.iter().any(|(id, _)| *id == 1));
    }

    #[test]
    fn test_generate_fingerprint_with_silence() {
        // Create a buffer of silence (zeros)
        let sample_rate = 44100;
        let channels = 2;
        let duration_seconds = 1;
        let sample_count = sample_rate * channels * duration_seconds;
        let samples = vec![0i16; sample_count as usize];

        // Generate fingerprint from silence
        let result = generate_fingerprint(&samples, sample_rate, channels as u16);

        // Should not panic and should return a result
        // Silence may produce an empty fingerprint, which is valid behavior
        assert!(result.is_some());
        // The key is that it doesn't panic or return None
    }

    #[test]
    fn test_load_nonexistent_fingerprint() {
        // Create in-memory database
        let conn = Connection::open_in_memory().unwrap();
        conn.execute(
            "CREATE TABLE fingerprints (
                track_id INTEGER PRIMARY KEY,
                fingerprint BLOB NOT NULL,
                duration_seconds INTEGER NOT NULL,
                acoustid TEXT,
                musicbrainz_recording_id TEXT
            )",
            [],
        )
        .unwrap();

        // Try to load fingerprint for non-existent track
        let result = load_fingerprint(&conn, 999).unwrap();

        // Should return None, not an error
        assert_eq!(result, None);
    }
}
