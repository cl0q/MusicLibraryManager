//! Fingerprint-based duplicate detection with review queue.
//!
//! Provides functions to detect and process duplicate tracks using audio fingerprints.
//! Tracks with matching fingerprints but differing metadata are flagged for review.
//! Tracks with matching fingerprints and similar metadata are auto-merged based on quality.

use rusqlite::{Connection, Result as SqlResult};
use serde_json::json;

use crate::dedup::normalize::{normalize, normalize_artist};
use crate::fingerprint::matcher::compare_fingerprints;
use crate::transcode::format::detect_format;
use std::path::Path;

/// Review queue entry for conflict tracking
#[derive(Debug)]
pub struct ReviewQueueEntry {
    pub action_type: String,     // "fingerprint_dedup" | "metadata_conflict"
    pub track_id: i64,
    pub related_track_id: Option<i64>,
    pub details: String,         // JSON string
    pub auto_action: Option<String>, // "kept_higher_quality" | "flagged"
}

/// Result of a review queue row query
#[derive(Debug)]
pub struct ReviewQueueRow {
    pub id: i64,
    pub action_type: String,
    pub track_id: i64,
    pub related_track_id: Option<i64>,
    pub details: String,
    pub auto_action: Option<String>,
    pub status: String,
    pub created_at: String,
    pub resolved_at: Option<String>,
}

/// Result of a deep scan operation
#[derive(Debug)]
pub struct DeepScanResult {
    pub pairs_compared: usize,
    pub duplicates_found: usize,
    pub conflicts_flagged: usize,
}

/// Track information for duplicate processing
#[derive(Debug)]
struct TrackInfo {
    id: i64,
    title: String,
    artist: String,
    album: String,
    original_path: String,
    format: String,
    bitrate: Option<i32>,
    is_duplicate: i32,
}

/// Add an entry to the review queue.
///
/// # Arguments
/// * `conn` - Database connection
/// * `entry` - Review queue entry to add
///
/// # Returns
/// * `Ok(i64)` - ID of the newly created review queue entry
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn add_to_review_queue(conn: &Connection, entry: &ReviewQueueEntry) -> SqlResult<i64> {
    conn.execute(
        "INSERT INTO review_queue (action_type, track_id, related_track_id, details, auto_action, status)
         VALUES (?1, ?2, ?3, ?4, ?5, 'pending')",
        rusqlite::params![
            entry.action_type,
            entry.track_id,
            entry.related_track_id,
            entry.details,
            entry.auto_action,
        ],
    )?;

    Ok(conn.last_insert_rowid())
}

/// Detect fingerprint duplicates for a given track.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID to find duplicates of
///
/// # Returns
/// * `Ok(Vec<(i64, f64)>)` - List of (matching_track_id, score) tuples sorted by score descending
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn detect_fingerprint_duplicates(
    conn: &Connection,
    track_id: i64,
) -> SqlResult<Vec<(i64, f64)>> {
    // Load fingerprint for track_id
    let target_fp = match crate::fingerprint::chromaprint::load_fingerprint(conn, track_id)? {
        Some(fp) => fp,
        None => return Ok(Vec::new()), // No fingerprint for this track
    };

    // Load all other fingerprints (excluding track_id)
    let mut stmt = conn.prepare(
        "SELECT track_id, fingerprint FROM fingerprints WHERE track_id != ?",
    )?;

    let mut matches = Vec::new();

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

        // Compare fingerprints using matcher module
        let score = compare_fingerprints(&target_fp, &other_fp);

        // Include matches with score >= 0.4
        if score >= 0.4 {
            matches.push((other_track_id, score));
        }
    }

    // Sort by score descending
    matches.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok(matches)
}

/// Load track information from database.
fn load_track_info(conn: &Connection, track_id: i64) -> SqlResult<TrackInfo> {
    conn.query_row(
        "SELECT id, title, artist, album, original_path, format, bitrate, is_duplicate
         FROM tracks WHERE id = ?",
        [track_id],
        |row| {
            Ok(TrackInfo {
                id: row.get(0)?,
                title: row.get(1)?,
                artist: row.get(2)?,
                album: row.get(3)?,
                original_path: row.get(4)?,
                format: row.get(5)?,
                bitrate: row.get(6)?,
                is_duplicate: row.get(7)?,
            })
        },
    )
}

/// Compare quality of two tracks.
///
/// Returns true if track1 is better quality than track2.
/// Lossless > lossy, then by bitrate.
fn is_better_quality(track1: &TrackInfo, track2: &TrackInfo) -> bool {
    // Detect format quality from file (codec-based detection)
    let format1_result = detect_format(Path::new(&track1.original_path));
    let format2_result = detect_format(Path::new(&track2.original_path));

    let is_lossless1 = format1_result.as_ref().map(|f| f.is_lossless).unwrap_or(false);
    let is_lossless2 = format2_result.as_ref().map(|f| f.is_lossless).unwrap_or(false);

    // Lossless always beats lossy
    if is_lossless1 && !is_lossless2 {
        return true;
    }
    if !is_lossless1 && is_lossless2 {
        return false;
    }

    // If both same lossiness, compare by bitrate
    let bitrate1 = track1.bitrate.unwrap_or(0);
    let bitrate2 = track2.bitrate.unwrap_or(0);

    bitrate1 > bitrate2
}

/// Check if metadata substantially differs between two tracks.
///
/// Uses fuzzy matching with 0.7 threshold (lower than normal dedup threshold).
fn metadata_differs(track1: &TrackInfo, track2: &TrackInfo) -> bool {
    use strsim::jaro_winkler;

    let norm_title1 = normalize(&track1.title);
    let norm_title2 = normalize(&track2.title);
    let norm_artist1 = normalize_artist(&track1.artist);
    let norm_artist2 = normalize_artist(&track2.artist);

    let title_sim = jaro_winkler(&norm_title1, &norm_title2);
    let artist_sim = jaro_winkler(&norm_artist1, &norm_artist2);

    // Metadata differs if either title or artist similarity < 0.7
    title_sim < 0.7 || artist_sim < 0.7
}

/// Process a fingerprint duplicate pair.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - First track ID
/// * `duplicate_id` - Second track ID
/// * `score` - Fingerprint similarity score
///
/// # Returns
/// * `Ok(())` - If processing completed successfully
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn process_fingerprint_duplicate(
    conn: &Connection,
    track_id: i64,
    duplicate_id: i64,
    score: f64,
) -> SqlResult<()> {
    // Load both tracks
    let track1 = load_track_info(conn, track_id)?;
    let track2 = load_track_info(conn, duplicate_id)?;

    // Check if metadata substantially differs
    if metadata_differs(&track1, &track2) {
        // FLAG for review - don't auto-merge
        let details = json!({
            "score": score,
            "track_1": {
                "id": track1.id,
                "title": track1.title,
                "artist": track1.artist,
                "album": track1.album,
                "format": track1.format,
                "bitrate": track1.bitrate,
            },
            "track_2": {
                "id": track2.id,
                "title": track2.title,
                "artist": track2.artist,
                "album": track2.album,
                "format": track2.format,
                "bitrate": track2.bitrate,
            },
            "reason": "metadata_differs"
        })
        .to_string();

        let entry = ReviewQueueEntry {
            action_type: "metadata_conflict".to_string(),
            track_id: track1.id,
            related_track_id: Some(track2.id),
            details,
            auto_action: Some("flagged".to_string()),
        };

        add_to_review_queue(conn, &entry)?;
    } else {
        // Metadata agrees - auto-keep best quality
        let (better_track, worse_track) = if is_better_quality(&track1, &track2) {
            (&track1, &track2)
        } else {
            (&track2, &track1)
        };

        // Mark lower quality track as duplicate
        conn.execute(
            "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?",
            rusqlite::params![better_track.id, worse_track.id],
        )?;

        // Log to review queue
        let details = json!({
            "score": score,
            "kept": {
                "id": better_track.id,
                "title": better_track.title,
                "artist": better_track.artist,
                "album": better_track.album,
                "format": better_track.format,
                "bitrate": better_track.bitrate,
            },
            "marked_duplicate": {
                "id": worse_track.id,
                "title": worse_track.title,
                "artist": worse_track.artist,
                "album": worse_track.album,
                "format": worse_track.format,
                "bitrate": worse_track.bitrate,
            }
        })
        .to_string();

        let entry = ReviewQueueEntry {
            action_type: "fingerprint_dedup".to_string(),
            track_id: better_track.id,
            related_track_id: Some(worse_track.id),
            details,
            auto_action: Some("kept_higher_quality".to_string()),
        };

        add_to_review_queue(conn, &entry)?;
    }

    Ok(())
}

/// Perform a deep scan of the entire library for fingerprint duplicates.
///
/// # Arguments
/// * `conn` - Database connection
///
/// # Returns
/// * `Ok(DeepScanResult)` - Scan result with statistics
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn deep_scan_library(conn: &Connection) -> SqlResult<DeepScanResult> {
    // Get all tracks with fingerprints
    let mut stmt = conn.prepare(
        "SELECT t.id FROM tracks t
         INNER JOIN fingerprints f ON t.id = f.track_id
         WHERE t.is_duplicate = 0
         ORDER BY t.id",
    )?;

    let track_ids: Vec<i64> = stmt
        .query_map([], |row| row.get(0))?
        .collect::<SqlResult<Vec<_>>>()?;

    let mut pairs_compared = 0;
    let mut duplicates_found = 0;
    let mut conflicts_flagged = 0;

    // Compare all pairs (O(n^2) but acceptable for initial implementation)
    for i in 0..track_ids.len() {
        let track_id = track_ids[i];

        // Find duplicates for this track
        let matches = detect_fingerprint_duplicates(conn, track_id)?;

        for (dup_id, score) in matches {
            // Only process pairs where dup_id > track_id to avoid duplicates
            if dup_id <= track_id {
                continue;
            }

            pairs_compared += 1;

            // Check if either track is already marked as duplicate
            let track_info = load_track_info(conn, track_id)?;
            let dup_info = load_track_info(conn, dup_id)?;

            if track_info.is_duplicate == 1 || dup_info.is_duplicate == 1 {
                continue; // Skip already processed duplicates
            }

            // Process the duplicate pair
            process_fingerprint_duplicate(conn, track_id, dup_id, score)?;

            // Check if it was flagged or auto-merged
            if metadata_differs(&track_info, &dup_info) {
                conflicts_flagged += 1;
            } else {
                duplicates_found += 1;
            }
        }
    }

    Ok(DeepScanResult {
        pairs_compared,
        duplicates_found,
        conflicts_flagged,
    })
}

/// Get review queue entries.
///
/// # Arguments
/// * `conn` - Database connection
/// * `status` - Optional status filter ("pending" | "resolved" | "dismissed")
///
/// # Returns
/// * `Ok(Vec<ReviewQueueRow>)` - List of review queue rows
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn get_review_queue(
    conn: &Connection,
    status: Option<&str>,
) -> SqlResult<Vec<ReviewQueueRow>> {
    let query = if let Some(s) = status {
        format!(
            "SELECT id, action_type, track_id, related_track_id, details, auto_action, status, created_at, resolved_at
             FROM review_queue WHERE status = '{}' ORDER BY created_at DESC",
            s
        )
    } else {
        "SELECT id, action_type, track_id, related_track_id, details, auto_action, status, created_at, resolved_at
         FROM review_queue ORDER BY created_at DESC"
            .to_string()
    };

    let mut stmt = conn.prepare(&query)?;

    let rows = stmt
        .query_map([], |row| {
            Ok(ReviewQueueRow {
                id: row.get(0)?,
                action_type: row.get(1)?,
                track_id: row.get(2)?,
                related_track_id: row.get(3)?,
                details: row.get(4)?,
                auto_action: row.get(5)?,
                status: row.get(6)?,
                created_at: row.get(7)?,
                resolved_at: row.get(8)?,
            })
        })?
        .collect::<SqlResult<Vec<_>>>()?;

    Ok(rows)
}

/// Resolve a review queue item.
///
/// # Arguments
/// * `conn` - Database connection
/// * `review_id` - Review queue entry ID
/// * `action` - Action to take ("approved" | "rejected" | "dismissed")
///
/// # Returns
/// * `Ok(())` - If resolution succeeded
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn resolve_review_item(conn: &Connection, review_id: i64, action: &str) -> SqlResult<()> {
    conn.execute(
        "UPDATE review_queue SET status = ?, resolved_at = CURRENT_TIMESTAMP WHERE id = ?",
        rusqlite::params![action, review_id],
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::schema::initialize_schema;
    use crate::fingerprint::chromaprint::save_fingerprint;

    fn create_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();
        conn
    }

    fn insert_test_track(
        conn: &Connection,
        title: &str,
        artist: &str,
        format: &str,
        bitrate: Option<i32>,
        path: &str,
    ) -> i64 {
        conn.execute(
            "INSERT INTO tracks (title, artist, album_artist, album, format, bitrate, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![title, artist, artist, "Album", format, bitrate, path],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    #[test]
    fn test_add_to_review_queue() {
        let conn = create_test_db();

        let track_id = insert_test_track(&conn, "Test Track", "Test Artist", "mp3", Some(320), "/test.mp3");

        let entry = ReviewQueueEntry {
            action_type: "fingerprint_dedup".to_string(),
            track_id,
            related_track_id: None,
            details: "{}".to_string(),
            auto_action: Some("kept_higher_quality".to_string()),
        };

        let review_id = add_to_review_queue(&conn, &entry).unwrap();
        assert!(review_id > 0);

        // Verify entry exists
        let rows = get_review_queue(&conn, None).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].track_id, track_id);
        assert_eq!(rows[0].status, "pending");
    }

    #[test]
    fn test_resolve_review_item() {
        let conn = create_test_db();

        let track_id = insert_test_track(&conn, "Test Track", "Test Artist", "mp3", Some(320), "/test.mp3");

        let entry = ReviewQueueEntry {
            action_type: "fingerprint_dedup".to_string(),
            track_id,
            related_track_id: None,
            details: "{}".to_string(),
            auto_action: Some("kept_higher_quality".to_string()),
        };

        let review_id = add_to_review_queue(&conn, &entry).unwrap();

        // Resolve the entry
        resolve_review_item(&conn, review_id, "approved").unwrap();

        // Verify status changed
        let rows = get_review_queue(&conn, Some("approved")).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, "approved");
        assert!(rows[0].resolved_at.is_some());
    }

    #[test]
    fn test_process_fingerprint_duplicate_flags_metadata_conflict() {
        let conn = create_test_db();

        // Two tracks with very different titles
        let track1 = insert_test_track(&conn, "Song One", "Artist", "mp3", Some(320), "/song1.mp3");
        let track2 = insert_test_track(&conn, "Completely Different", "Other Artist", "mp3", Some(320), "/song2.mp3");

        // Add fingerprints (identical for testing)
        let fp = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];
        save_fingerprint(&conn, track1, &fp, 180).unwrap();
        save_fingerprint(&conn, track2, &fp, 180).unwrap();

        // Process duplicate - should flag due to metadata difference
        process_fingerprint_duplicate(&conn, track1, track2, 0.95).unwrap();

        // Verify review queue entry created
        let rows = get_review_queue(&conn, None).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].action_type, "metadata_conflict");
        assert_eq!(rows[0].auto_action, Some("flagged".to_string()));

        // Verify neither track marked as duplicate
        let dup1: i32 = conn
            .query_row("SELECT is_duplicate FROM tracks WHERE id = ?", [track1], |row| {
                row.get(0)
            })
            .unwrap();
        let dup2: i32 = conn
            .query_row("SELECT is_duplicate FROM tracks WHERE id = ?", [track2], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(dup1, 0);
        assert_eq!(dup2, 0);
    }

    #[test]
    fn test_process_fingerprint_duplicate_auto_keeps_quality() {
        let conn = create_test_db();

        // Two tracks with similar metadata but different quality
        // Note: These won't actually exist as files, but format detection will fail gracefully
        let track1 = insert_test_track(&conn, "Song Name", "Artist", "mp3", Some(320), "/high.mp3");
        let track2 = insert_test_track(&conn, "Song Name", "Artist", "mp3", Some(128), "/low.mp3");

        // Add fingerprints (identical for testing)
        let fp = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];
        save_fingerprint(&conn, track1, &fp, 180).unwrap();
        save_fingerprint(&conn, track2, &fp, 180).unwrap();

        // Process duplicate - should auto-keep higher bitrate
        process_fingerprint_duplicate(&conn, track1, track2, 0.95).unwrap();

        // Verify review queue entry created
        let rows = get_review_queue(&conn, None).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].action_type, "fingerprint_dedup");
        assert_eq!(rows[0].auto_action, Some("kept_higher_quality".to_string()));

        // Verify lower bitrate track marked as duplicate
        let dup2: i32 = conn
            .query_row("SELECT is_duplicate FROM tracks WHERE id = ?", [track2], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(dup2, 1);

        // Verify variant_of set correctly
        let variant_of: Option<i64> = conn
            .query_row("SELECT variant_of FROM tracks WHERE id = ?", [track2], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(variant_of, Some(track1));
    }

    #[test]
    fn test_deep_scan_skips_existing_duplicates() {
        let conn = create_test_db();

        // Create three tracks - track2 already marked as duplicate of track1
        let track1 = insert_test_track(&conn, "Track 1", "Artist", "mp3", Some(320), "/track1.mp3");
        let track2 = insert_test_track(&conn, "Track 2", "Artist", "mp3", Some(320), "/track2.mp3");
        let track3 = insert_test_track(&conn, "Track 3", "Artist", "mp3", Some(320), "/track3.mp3");

        // Mark track2 as duplicate of track1
        conn.execute(
            "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?",
            rusqlite::params![track1, track2],
        )
        .unwrap();

        // Add fingerprints - track1 and track3 have matching fingerprints
        let fp = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];
        save_fingerprint(&conn, track1, &fp, 180).unwrap();
        save_fingerprint(&conn, track2, &fp, 180).unwrap();
        save_fingerprint(&conn, track3, &fp, 180).unwrap();

        // Run deep scan
        let result = deep_scan_library(&conn).unwrap();

        // Should process track1 vs track3 (both not marked as duplicates)
        // track2 is skipped because it's already marked as duplicate
        // Note: Both track1 and track3 find each other, but we only process once due to pair ordering check
        assert!(result.pairs_compared > 0);

        // Verify review queue has entry for track1 and track3
        let rows = get_review_queue(&conn, None).unwrap();
        assert_eq!(rows.len(), 1); // One pair processed (track1 vs track3)
    }
}
