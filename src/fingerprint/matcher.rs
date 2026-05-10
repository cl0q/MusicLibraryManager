//! Local fingerprint comparison for duplicate detection.
//!
//! Provides functions to compare two fingerprints and determine if they represent
//! the same recording.

use rusqlite::{Connection, Result as SqlResult};
use rusty_chromaprint::{match_fingerprints, Configuration};

/// Compare two fingerprints and return a similarity score.
///
/// # Arguments
/// * `fp1` - First fingerprint
/// * `fp2` - Second fingerprint
///
/// # Returns
/// * `f64` - Similarity score from 0.0 (completely different) to 1.0 (identical)
pub fn compare_fingerprints(fp1: &[u32], fp2: &[u32]) -> f64 {
    // Use rusty_chromaprint's match_fingerprints
    let config = Configuration::preset_test2();

    match match_fingerprints(fp1, fp2, &config) {
        Ok(segments) => {
            if segments.is_empty() {
                return 0.0;
            }

            // Calculate score based on best matching segment
            // Score is based on the length of the longest matching segment
            // relative to the shorter fingerprint
            let best_segment = segments
                .iter()
                .max_by_key(|seg| seg.items_count)
                .unwrap();

            let shorter_length = fp1.len().min(fp2.len());
            if shorter_length == 0 {
                return 0.0;
            }

            // Score is the ratio of matched length to shorter fingerprint length
            let score = best_segment.items_count as f64 / shorter_length as f64;

            // Clamp to [0.0, 1.0] range
            score.min(1.0).max(0.0)
        }
        Err(_) => 0.0, // No matching segments found
    }
}

/// Check if two fingerprints represent duplicate recordings.
///
/// # Arguments
/// * `fp1` - First fingerprint
/// * `fp2` - Second fingerprint
/// * `threshold` - Similarity threshold (default: 0.5)
///
/// # Returns
/// * `bool` - True if fingerprints are considered duplicates
pub fn are_duplicates(fp1: &[u32], fp2: &[u32], threshold: f64) -> bool {
    let score = compare_fingerprints(fp1, fp2);
    score >= threshold
}

/// Find potential duplicate tracks based on fingerprint comparison.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID to find duplicates of
///
/// # Returns
/// * `Ok(Vec<(i64, f64)>)` - List of (track_id, similarity_score) tuples for potential duplicates
/// * `Err(rusqlite::Error)` - If database operation fails
///
/// # Note
/// This is a naive O(n) implementation that compares against all other fingerprints.
/// For large libraries, consider implementing locality-sensitive hashing (LSH) for better performance.
pub fn find_fingerprint_duplicates(
    conn: &Connection,
    track_id: i64,
) -> SqlResult<Vec<(i64, f64)>> {
    // Load the target fingerprint
    let target_fp = crate::fingerprint::chromaprint::load_fingerprint(conn, track_id)?;

    let target_fp = match target_fp {
        Some(fp) => fp,
        None => return Ok(Vec::new()), // No fingerprint for this track
    };

    // Load all other fingerprints
    let mut stmt = conn.prepare(
        "SELECT track_id, fingerprint FROM fingerprints WHERE track_id != ?",
    )?;

    let mut candidates = Vec::new();

    let rows = stmt.query_map([track_id], |row| {
        let other_track_id: i64 = row.get(0)?;
        let bytes: Vec<u8> = row.get(1)?;

        // Convert bytes to Vec<u32>
        let mut fingerprint = Vec::with_capacity(bytes.len() / 4);
        for chunk in bytes.chunks_exact(4) {
            let val = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            fingerprint.push(val);
        }

        Ok((other_track_id, fingerprint))
    })?;

    for row_result in rows {
        let (other_track_id, other_fp) = row_result?;

        // Compare fingerprints
        let score = compare_fingerprints(&target_fp, &other_fp);

        // Only include candidates with score >= 0.3 (low threshold to catch potential matches)
        if score >= 0.3 {
            candidates.push((other_track_id, score));
        }
    }

    // Sort by score descending
    candidates.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok(candidates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fingerprint::chromaprint::save_fingerprint;

    #[test]
    fn test_compare_identical_fingerprints() {
        // Identical fingerprints should have very high score
        let fp = vec![
            0x12345678u32,
            0xABCDEF01,
            0xDEADBEEF,
            0xCAFEBABE,
            0x00000000,
            0xFFFFFFFF,
        ];

        let score = compare_fingerprints(&fp, &fp);

        // Should be close to 1.0 for identical fingerprints
        assert!(
            score >= 0.9,
            "Expected score >= 0.9 for identical fingerprints, got {}",
            score
        );
    }

    #[test]
    fn test_compare_different_fingerprints() {
        // Completely different fingerprints should have low score
        let fp1 = vec![0x00000000u32, 0x11111111, 0x22222222];
        let fp2 = vec![0xFFFFFFFFu32, 0xEEEEEEEE, 0xDDDDDDDD];

        let score = compare_fingerprints(&fp1, &fp2);

        // Should be very low for completely different data
        assert!(
            score < 0.3,
            "Expected score < 0.3 for different fingerprints, got {}",
            score
        );
    }

    #[test]
    fn test_are_duplicates_threshold() {
        // Test threshold logic
        let fp1 = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];
        let fp2 = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];

        // Identical fingerprints should be duplicates at 0.5 threshold
        assert!(are_duplicates(&fp1, &fp2, 0.5));

        // Different fingerprints
        let fp3 = vec![0xFFFFFFFFu32, 0xEEEEEEEE, 0xDDDDDDDD];

        // Should not be duplicates
        assert!(!are_duplicates(&fp1, &fp3, 0.5));
    }

    #[test]
    fn test_find_fingerprint_duplicates() {
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

        // Insert test fingerprints
        let fp1 = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];
        let fp2 = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF]; // Identical to fp1
        let fp3 = vec![0xFFFFFFFFu32, 0xEEEEEEEE, 0xDDDDDDDD]; // Different

        save_fingerprint(&conn, 1, &fp1, 180).unwrap();
        save_fingerprint(&conn, 2, &fp2, 180).unwrap();
        save_fingerprint(&conn, 3, &fp3, 180).unwrap();

        // Find duplicates of track 1
        let duplicates = find_fingerprint_duplicates(&conn, 1).unwrap();

        // Should find track 2 as a high-confidence duplicate
        // May or may not find track 3 depending on threshold
        assert!(!duplicates.is_empty());

        // Track 2 should have high score
        let track2_match = duplicates.iter().find(|(id, _)| *id == 2);
        assert!(track2_match.is_some());

        let (_id, score) = track2_match.unwrap();
        assert!(*score >= 0.9, "Expected high score for identical fingerprint");
    }

    #[test]
    fn test_compare_empty_fingerprints() {
        let fp1: Vec<u32> = Vec::new();
        let fp2 = vec![0x12345678u32];

        let score = compare_fingerprints(&fp1, &fp2);

        // Empty fingerprint should return 0.0
        assert_eq!(score, 0.0);
    }
}
