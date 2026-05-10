//! Duplicate detection algorithm with metadata matching and quality comparison.
//!
//! Groups tracks by normalized (artist, album, title) and marks lower-quality
//! copies as duplicates, keeping the highest quality version.

use rusqlite::{params, Connection};
use std::collections::HashMap;

use crate::database::{with_transaction, Result as DbResult};

/// Internal representation of a track for duplicate comparison.
#[derive(Debug, Clone)]
struct DuplicateTrack {
    id: i64,
    artist: String,
    album: String,
    title: String,
    format: String,
    bitrate: Option<u32>,
}

/// Detects and marks duplicate tracks in the database.
///
/// Algorithm:
/// 1. Find all tracks with complete metadata (non-empty artist, album, title)
/// 2. Group by normalized (lowercase) metadata
/// 3. For groups with multiple tracks, sort by quality
/// 4. Mark all but the highest quality as duplicates
///
/// Quality hierarchy:
/// - Lossless formats (flac, wav, alac, aiff) > lossy formats
/// - Within same category: higher bitrate wins
///
/// # Arguments
/// * `conn` - Mutable database connection (transaction requires mut)
///
/// # Returns
/// * `Ok(usize)` - Number of tracks marked as duplicates
/// * `Err(DatabaseError)` - If database operation failed
///
/// # Example
/// ```ignore
/// use music_library_manager::duplicate::mark_duplicates;
/// use music_library_manager::database::get_memory_connection;
///
/// let mut conn = get_memory_connection()?;
/// // ... import some tracks ...
/// let count = mark_duplicates(&mut conn)?;
/// println!("Marked {} duplicates", count);
/// ```
pub fn mark_duplicates(conn: &mut Connection) -> DbResult<usize> {
    // Find all tracks with complete metadata (not empty strings)
    // Only consider tracks not already marked as duplicates
    let mut stmt = conn.prepare(
        "SELECT id, artist, album, title, format, bitrate
         FROM tracks
         WHERE artist IS NOT NULL AND artist != ''
           AND album IS NOT NULL AND album != ''
           AND title IS NOT NULL AND title != ''
           AND is_duplicate = 0
         ORDER BY artist, album, title",
    )?;

    let mut groups: HashMap<(String, String, String), Vec<DuplicateTrack>> = HashMap::new();

    let rows = stmt.query_map([], |row| {
        Ok(DuplicateTrack {
            id: row.get(0)?,
            // Normalize to lowercase for case-insensitive matching
            artist: row.get::<_, String>(1)?.to_lowercase(),
            album: row.get::<_, String>(2)?.to_lowercase(),
            title: row.get::<_, String>(3)?.to_lowercase(),
            format: row.get(4)?,
            bitrate: row.get(5)?,
        })
    })?;

    // Group by (artist, album, title)
    for row in rows {
        if let Ok(track) = row {
            let key = (track.artist.clone(), track.album.clone(), track.title.clone());
            groups.entry(key).or_default().push(track);
        }
    }

    // Drop statement before transaction (releases borrow on conn)
    drop(stmt);

    // Mark lower-quality copies as duplicates
    let mut count = 0;

    with_transaction(conn, |tx| {
        for (_key, mut group) in groups {
            if group.len() > 1 {
                // Sort by quality: lossless > lossy, then bitrate descending
                group.sort_by(compare_quality);

                // Keep first (best quality), mark rest as duplicates
                for track in group.iter().skip(1) {
                    tx.execute(
                        "UPDATE tracks SET is_duplicate = 1 WHERE id = ?1",
                        params![track.id],
                    )?;
                    count += 1;
                }
            }
        }

        Ok(count)
    })
}

/// Compares two tracks by quality for sorting.
///
/// Returns Ordering such that higher quality tracks come first.
/// Quality hierarchy:
/// 1. Lossless > lossy
/// 2. Within same category: higher bitrate first
fn compare_quality(a: &DuplicateTrack, b: &DuplicateTrack) -> std::cmp::Ordering {
    let a_lossless = is_lossless(&a.format);
    let b_lossless = is_lossless(&b.format);

    match (a_lossless, b_lossless) {
        (true, false) => std::cmp::Ordering::Less,    // a is better (Less = comes first)
        (false, true) => std::cmp::Ordering::Greater, // b is better
        _ => {
            // Same lossless status, compare bitrate descending
            let a_bitrate = a.bitrate.unwrap_or(0);
            let b_bitrate = b.bitrate.unwrap_or(0);
            b_bitrate.cmp(&a_bitrate) // Higher bitrate first
        }
    }
}

/// Checks if a format is lossless.
///
/// Lossless formats: flac, wav, alac, aiff
/// Note: AIFF is lossless (learning from Python implementation).
fn is_lossless(format: &str) -> bool {
    matches!(format, "flac" | "wav" | "alac" | "aiff")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::get_memory_connection;

    #[test]
    fn test_quality_comparison_lossless_vs_lossy() {
        let flac = DuplicateTrack {
            id: 1,
            artist: "test".to_string(),
            album: "test".to_string(),
            title: "test".to_string(),
            format: "flac".to_string(),
            bitrate: None,
        };

        let mp3_320 = DuplicateTrack {
            id: 2,
            artist: "test".to_string(),
            album: "test".to_string(),
            title: "test".to_string(),
            format: "mp3".to_string(),
            bitrate: Some(320),
        };

        // FLAC > MP3 (lossless beats lossy regardless of bitrate)
        assert_eq!(compare_quality(&flac, &mp3_320), std::cmp::Ordering::Less);
        assert_eq!(compare_quality(&mp3_320, &flac), std::cmp::Ordering::Greater);
    }

    #[test]
    fn test_quality_comparison_bitrate() {
        let mp3_320 = DuplicateTrack {
            id: 2,
            artist: "test".to_string(),
            album: "test".to_string(),
            title: "test".to_string(),
            format: "mp3".to_string(),
            bitrate: Some(320),
        };

        let mp3_128 = DuplicateTrack {
            id: 3,
            artist: "test".to_string(),
            album: "test".to_string(),
            title: "test".to_string(),
            format: "mp3".to_string(),
            bitrate: Some(128),
        };

        // MP3 320 > MP3 128 (higher bitrate wins)
        assert_eq!(compare_quality(&mp3_320, &mp3_128), std::cmp::Ordering::Less);
        assert_eq!(compare_quality(&mp3_128, &mp3_320), std::cmp::Ordering::Greater);
    }

    #[test]
    fn test_quality_comparison_same() {
        let mp3_a = DuplicateTrack {
            id: 1,
            artist: "test".to_string(),
            album: "test".to_string(),
            title: "test".to_string(),
            format: "mp3".to_string(),
            bitrate: Some(320),
        };

        let mp3_b = DuplicateTrack {
            id: 2,
            artist: "test".to_string(),
            album: "test".to_string(),
            title: "test".to_string(),
            format: "mp3".to_string(),
            bitrate: Some(320),
        };

        // Same quality = equal
        assert_eq!(compare_quality(&mp3_a, &mp3_b), std::cmp::Ordering::Equal);
    }

    #[test]
    fn test_lossless_formats() {
        assert!(is_lossless("flac"));
        assert!(is_lossless("wav"));
        assert!(is_lossless("alac"));
        assert!(is_lossless("aiff")); // Python learning: AIFF is lossless
        assert!(!is_lossless("mp3"));
        assert!(!is_lossless("aac"));
        assert!(!is_lossless("ogg"));
    }

    #[test]
    fn test_mark_duplicates_no_duplicates() {
        let mut conn = get_memory_connection().unwrap();

        // Insert two different tracks
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist A', 'Artist A', 'Album A', 'Song A', 'mp3', '/path/a.mp3')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist B', 'Artist B', 'Album B', 'Song B', 'mp3', '/path/b.mp3')",
            [],
        )
        .unwrap();

        let count = mark_duplicates(&mut conn).unwrap();
        assert_eq!(count, 0, "No duplicates should be found");
    }

    #[test]
    fn test_mark_duplicates_keeps_higher_quality() {
        let mut conn = get_memory_connection().unwrap();

        // Insert same song in FLAC (should be kept)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song', 'flac', '/path/song.flac')",
            [],
        )
        .unwrap();

        // Insert same song in MP3 (should be marked as duplicate)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, bitrate, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song', 'mp3', 320, '/path/song.mp3')",
            [],
        )
        .unwrap();

        let count = mark_duplicates(&mut conn).unwrap();
        assert_eq!(count, 1, "One duplicate should be marked");

        // Verify FLAC is not marked as duplicate
        let flac_dup: i32 = conn
            .query_row(
                "SELECT is_duplicate FROM tracks WHERE format = 'flac'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(flac_dup, 0, "FLAC should not be marked as duplicate");

        // Verify MP3 is marked as duplicate
        let mp3_dup: i32 = conn
            .query_row(
                "SELECT is_duplicate FROM tracks WHERE format = 'mp3'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(mp3_dup, 1, "MP3 should be marked as duplicate");
    }

    #[test]
    fn test_mark_duplicates_case_insensitive() {
        let mut conn = get_memory_connection().unwrap();

        // Insert tracks with different casing (should be treated as duplicates)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('ARTIST', 'ARTIST', 'ALBUM', 'SONG', 'flac', '/path/upper.flac')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('artist', 'artist', 'album', 'song', 'mp3', '/path/lower.mp3')",
            [],
        )
        .unwrap();

        let count = mark_duplicates(&mut conn).unwrap();
        assert_eq!(count, 1, "Case-insensitive matching should find duplicate");
    }

    #[test]
    fn test_mark_duplicates_ignores_empty_metadata() {
        let mut conn = get_memory_connection().unwrap();

        // Insert tracks with empty artist (should NOT be grouped as duplicates)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('', '', 'Album', 'Song', 'flac', '/path/a.flac')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('', '', 'Album', 'Song', 'mp3', '/path/b.mp3')",
            [],
        )
        .unwrap();

        let count = mark_duplicates(&mut conn).unwrap();
        assert_eq!(count, 0, "Empty strings should not match as duplicates");
    }

    #[test]
    fn test_mark_duplicates_multiple_groups() {
        let mut conn = get_memory_connection().unwrap();

        // Group 1: Two copies of Song A
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song A', 'flac', '/path/a.flac')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song A', 'mp3', '/path/a.mp3')",
            [],
        )
        .unwrap();

        // Group 2: Three copies of Song B
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song B', 'flac', '/path/b.flac')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, bitrate, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song B', 'mp3', 320, '/path/b-320.mp3')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, bitrate, original_path)
             VALUES ('Artist', 'Artist', 'Album', 'Song B', 'mp3', 128, '/path/b-128.mp3')",
            [],
        )
        .unwrap();

        let count = mark_duplicates(&mut conn).unwrap();
        assert_eq!(count, 3, "Should mark 1 + 2 = 3 duplicates");

        // Verify all FLAC files are kept
        let flac_dups: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM tracks WHERE format = 'flac' AND is_duplicate = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(flac_dups, 0, "No FLAC should be marked as duplicate");
    }
}
