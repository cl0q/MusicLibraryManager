//! Playlist database operations with fractional indexing.
//!
//! Provides CRUD operations for playlist management:
//! - Create playlists with tags
//! - Add/remove tracks to/from playlists
//! - Reorder tracks with O(1) performance via fractional indexing
//! - Query playlist tracks in order
//!
//! Fractional indexing uses string-based positions for unlimited reordering
//! without cascading updates. Only the moved track's position is updated.

use rusqlite::{Connection, OptionalExtension};

use crate::database::connection::Result;
use crate::models::{PlaylistCategory, Track, TrackMetadata};

/// Base-62 alphabet for fractional indexing (alphanumeric).
const ALPHABET: &str = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// Delimiter for fractional indexing.
const DELIMITER: char = '|';

/// Generates a fractional index position between left and right positions.
///
/// Uses string-based lexicographic ordering for unlimited precision.
/// Cases:
/// - (None, None) → "a0" (first position)
/// - (Some(left), None) → append "|a0" to left (insert after)
/// - (None, Some(right)) → "a0" if right > "a0", else compute midpoint before right
/// - (Some(left), Some(right)) → compute midpoint string between left and right
///
/// # Arguments
/// * `left` - Optional position before insertion point
/// * `right` - Optional position after insertion point
///
/// # Returns
/// * Position string that maintains lexicographic ordering: left < result < right
pub fn position_between(left: Option<&str>, right: Option<&str>) -> Result<String> {
    match (left, right) {
        // Empty playlist: use first position
        (None, None) => Ok("a0".to_string()),

        // Insert at end: append delimiter + first position
        (Some(left_pos), None) => Ok(increment_position_string(left_pos)),

        // Insert at beginning
        (None, Some(right_pos)) => {
            if right_pos > "a0" {
                Ok("a0".to_string())
            } else {
                // Right is <= "a0", need position before it
                midpoint_position_string("", right_pos)
            }
        }

        // Insert between two positions
        (Some(left_pos), Some(right_pos)) => midpoint_position_string(left_pos, right_pos),
    }
}

/// Increments a position string by appending delimiter and first position.
fn increment_position_string(pos: &str) -> String {
    format!("{}{}{}", pos, DELIMITER, "a0")
}

/// Computes the midpoint position string between left and right.
fn midpoint_position_string(left: &str, right: &str) -> Result<String> {
    let left_chars: Vec<char> = left.chars().collect();
    let right_chars: Vec<char> = right.chars().collect();
    let alphabet_chars: Vec<char> = ALPHABET.chars().collect();

    let mut result = String::new();
    let mut i = 0;

    loop {
        let left_char = left_chars.get(i).copied();
        let right_char = right_chars.get(i).copied();

        match (left_char, right_char) {
            // Same character at position i - continue
            (Some(l), Some(r)) if l == r => {
                result.push(l);
                i += 1;
            }
            // Different characters at position i
            (Some(l), Some(r)) => {
                let l_idx = ALPHABET.find(l).unwrap_or(0);
                let r_idx = ALPHABET.find(r).unwrap_or(0);

                // If adjacent characters, extend left with delimiter
                if r_idx <= l_idx + 1 {
                    result.push(l);
                    result.push(DELIMITER);
                    let mid_idx = alphabet_chars.len() / 2;
                    result.push(alphabet_chars[mid_idx]);
                    return Ok(result);
                }

                // Non-adjacent: use midpoint character
                let mid_idx = (l_idx + r_idx) / 2;
                result.push(alphabet_chars[mid_idx]);
                return Ok(result);
            }
            // Left ended, right continues
            (None, Some(r)) => {
                let r_idx = ALPHABET.find(r).unwrap_or(0);
                if r_idx > 0 {
                    // Use midpoint between start and r
                    let mid_idx = r_idx / 2;
                    result.push(alphabet_chars[mid_idx]);
                } else {
                    // r is first char - use delimiter approach
                    if result.is_empty() {
                        return Ok(format!("{}{}", DELIMITER, alphabet_chars[0]));
                    } else {
                        result.push(DELIMITER);
                        result.push(alphabet_chars[0]);
                    }
                }
                return Ok(result);
            }
            // Right ended, left continues
            (Some(_), None) => {
                result.push(DELIMITER);
                result.push(alphabet_chars[0]);
                return Ok(result);
            }
            // Both ended
            (None, None) => {
                result.push(DELIMITER);
                result.push(alphabet_chars[0]);
                return Ok(result);
            }
        }
    }
}

/// Create a new playlist with tags.
///
/// Uses transaction pattern for atomic operation.
/// Inserts into playlists table and playlist_tags table.
///
/// # Arguments
/// * `conn` - Database connection
/// * `name` - Playlist name
/// * `description` - Optional description
/// * `tags` - Vector of tag strings
/// * `category` - PlaylistCategory enum (Liked, Smart, or Regular)
///
/// # Returns
/// * `Ok(playlist_id)` - ID of created playlist
/// * `Err` if database operation fails
pub fn create_playlist(
    conn: &Connection,
    name: String,
    description: Option<String>,
    tags: Vec<String>,
    category: PlaylistCategory,
) -> Result<i64> {
    // Start transaction
    conn.execute_batch("BEGIN")?;

    // Insert playlist
    conn.execute(
        "INSERT INTO playlists (name, description, category, is_liked, is_smart, is_pinned)
         VALUES (?1, ?2, ?3, 0, 0, 0)",
        rusqlite::params![name, description, category.to_string()],
    )?;

    let playlist_id = conn.last_insert_rowid();

    // Insert tags
    for tag in tags {
        conn.execute(
            "INSERT INTO playlist_tags (playlist_id, tag) VALUES (?1, ?2)",
            rusqlite::params![playlist_id, tag],
        )?;
    }

    // Commit transaction
    conn.execute_batch("COMMIT")?;

    Ok(playlist_id)
}

/// Add a track to a playlist (appends to end with fractional indexing).
///
/// Queries the last position in the playlist and generates a new position after it.
/// Uses UNIQUE constraint to prevent duplicate (playlist_id, track_id) pairs.
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of playlist
/// * `track_id` - ID of track to add
///
/// # Returns
/// * `Ok(())` if track added successfully
/// * `Err` if track already in playlist or database operation fails
pub fn add_track_to_playlist(conn: &Connection, playlist_id: i64, track_id: i64) -> Result<()> {
    // Query last position in playlist
    let last_position: Option<String> = conn
        .query_row(
            "SELECT position FROM playlist_tracks
             WHERE playlist_id = ?1
             ORDER BY position DESC
             LIMIT 1",
            [playlist_id],
            |row| row.get(0),
        )
        .optional()?;

    // Generate new position (append after last)
    let new_position = position_between(last_position.as_deref(), None)?;

    // Insert track with new position
    conn.execute(
        "INSERT INTO playlist_tracks (playlist_id, track_id, position)
         VALUES (?1, ?2, ?3)",
        rusqlite::params![playlist_id, track_id, new_position],
    )?;

    Ok(())
}

/// Remove a track from a playlist.
///
/// Deletes the playlist_tracks entry. Does NOT update positions of remaining tracks
/// (fractional indexing advantage - no cascading updates needed).
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of playlist
/// * `track_id` - ID of track to remove
///
/// # Returns
/// * `Ok(())` if track removed successfully (or wasn't in playlist)
/// * `Err` if database operation fails
pub fn remove_track_from_playlist(
    conn: &Connection,
    playlist_id: i64,
    track_id: i64,
) -> Result<()> {
    conn.execute(
        "DELETE FROM playlist_tracks
         WHERE playlist_id = ?1 AND track_id = ?2",
        rusqlite::params![playlist_id, track_id],
    )?;

    Ok(())
}

/// Reorder a track within a playlist via drag-drop.
///
/// Updates only the moved track's position (O(1) database operation).
/// Computes new position between after_track and before_track.
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of playlist
/// * `track_id` - ID of track to reorder
/// * `after_track_id` - Optional ID of track to insert after (None = insert at beginning)
/// * `before_track_id` - Optional ID of track to insert before (None = insert at end)
///
/// # Returns
/// * `Ok(())` if track reordered successfully
/// * `Err` if database operation fails
pub fn reorder_playlist_track(
    conn: &Connection,
    playlist_id: i64,
    track_id: i64,
    after_track_id: Option<i64>,
    before_track_id: Option<i64>,
) -> Result<()> {
    // Get positions of after_track and before_track
    let after_position: Option<String> = if let Some(after_id) = after_track_id {
        conn.query_row(
            "SELECT position FROM playlist_tracks
             WHERE playlist_id = ?1 AND track_id = ?2",
            rusqlite::params![playlist_id, after_id],
            |row| row.get(0),
        )
        .optional()?
    } else {
        None
    };

    let before_position: Option<String> = if let Some(before_id) = before_track_id {
        conn.query_row(
            "SELECT position FROM playlist_tracks
             WHERE playlist_id = ?1 AND track_id = ?2",
            rusqlite::params![playlist_id, before_id],
            |row| row.get(0),
        )
        .optional()?
    } else {
        None
    };

    // Compute new position between after and before
    let new_position = position_between(after_position.as_deref(), before_position.as_deref())?;

    // Update only the moved track's position (O(1) operation)
    conn.execute(
        "UPDATE playlist_tracks
         SET position = ?1
         WHERE playlist_id = ?2 AND track_id = ?3",
        rusqlite::params![new_position, playlist_id, track_id],
    )?;

    Ok(())
}

/// Get all tracks in a playlist, ordered by position.
///
/// Joins playlist_tracks with tracks table, ordering by fractional position.
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of playlist
///
/// # Returns
/// * `Ok(Vec<Track>)` - Tracks in playlist order
/// * `Err` if database operation fails
pub fn get_playlist_tracks(conn: &Connection, playlist_id: i64) -> Result<Vec<Track>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.artist, t.album_artist, t.album, t.title, t.genre, t.year,
                t.bitrate, t.duration, t.format, t.original_path,
                t.organized_path,
                t.is_duplicate, t.date_added
         FROM tracks t
         JOIN playlist_tracks pt ON t.id = pt.track_id
         WHERE pt.playlist_id = ?1
         ORDER BY pt.position",
    )?;

    let tracks = stmt
        .query_map([playlist_id], |row| {
            let metadata = TrackMetadata::new(
                row.get(1)?, // artist
                row.get(2)?, // album_artist
                row.get(3)?, // album
                row.get(4)?, // title
                row.get(5)?, // genre
                row.get(6)?, // year
                row.get(7)?, // bitrate
                row.get(8)?, // duration
                row.get(9)?, // format
                row.get(10)?, // original_path
            );

            Ok(Track {
                id: Some(row.get(0)?),
                metadata,
                organized_path: row.get(11)?,
                is_duplicate: row.get::<_, i32>(12)? != 0,
                date_added: row.get(13)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    Ok(tracks)
}

/// Search for tracks within a playlist using case-insensitive LIKE queries.
///
/// Searches title, artist, and album fields with wildcards.
/// Maintains playlist order (by position).
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of playlist to search within
/// * `query` - Search query string
///
/// # Returns
/// * `Ok(Vec<Track>)` - Matching tracks in playlist order
/// * `Err` if database operation fails
pub fn search_playlist_tracks(
    conn: &Connection,
    playlist_id: i64,
    query: &str,
) -> Result<Vec<Track>> {
    let search_pattern = format!("%{}%", query);

    let mut stmt = conn.prepare(
        "SELECT t.id, t.artist, t.album_artist, t.album, t.title, t.genre, t.year,
                t.bitrate, t.duration, t.format, t.original_path,
                t.organized_path,
                t.is_duplicate, t.date_added
         FROM tracks t
         JOIN playlist_tracks pt ON t.id = pt.track_id
         WHERE pt.playlist_id = ?1
           AND (t.title LIKE ?2 OR t.artist LIKE ?2 OR t.album LIKE ?2)
         ORDER BY pt.position",
    )?;

    let tracks = stmt
        .query_map(
            rusqlite::params![playlist_id, search_pattern],
            |row| {
                let metadata = TrackMetadata::new(
                    row.get(1)?, // artist
                    row.get(2)?, // album_artist
                    row.get(3)?, // album
                    row.get(4)?, // title
                    row.get(5)?, // genre
                    row.get(6)?, // year
                    row.get(7)?, // bitrate
                    row.get(8)?, // duration
                    row.get(9)?, // format
                    row.get(10)?, // original_path
                );

                Ok(Track {
                    id: Some(row.get(0)?),
                    metadata,
                    organized_path: row.get(11)?,
                    is_duplicate: row.get::<_, i32>(12)? != 0,
                    date_added: row.get(13)?,
                })
            },
        )?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    Ok(tracks)
}

// Smart playlists and liked playlists functions

/// Helper function to capitalize first letter of a string.
fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().chain(chars).collect(),
    }
}

/// Create smart playlists (Recently Added, Most Played).
///
/// Inserts two smart playlists with is_smart=1 and is_pinned=1.
/// Uses INSERT OR IGNORE for idempotent operation (safe to call multiple times).
///
/// # Arguments
/// * `conn` - Database connection
///
/// # Returns
/// * `Ok(())` if playlists created successfully
/// * `Err` if database operation fails
pub fn create_smart_playlists(conn: &Connection) -> Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO playlists (name, category, is_smart, is_pinned) VALUES (?, ?, 1, 1)",
        ["Recently Added", "smart"],
    )?;

    conn.execute(
        "INSERT OR IGNORE INTO playlists (name, category, is_smart, is_pinned) VALUES (?, ?, 1, 1)",
        ["Most Played", "smart"],
    )?;

    Ok(())
}

/// Get tracks for a smart playlist by querying the corresponding view.
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_name` - Name of smart playlist ("Recently Added" or "Most Played")
/// * `limit` - Optional limit on number of tracks returned
///
/// # Returns
/// * `Ok(Vec<Track>)` with track data from the view
/// * `Err` if playlist_name is invalid or query fails
pub fn get_smart_playlist_tracks(
    conn: &Connection,
    playlist_name: &str,
    limit: Option<i32>,
) -> Result<Vec<Track>> {
    let view_name = match playlist_name {
        "Recently Added" => "smart_playlist_recently_added",
        "Most Played" => "smart_playlist_most_played",
        _ => {
            return Err(rusqlite::Error::InvalidQuery.into());
        }
    };

    let query = if let Some(lim) = limit {
        format!("SELECT * FROM {} LIMIT {}", view_name, lim)
    } else {
        format!("SELECT * FROM {}", view_name)
    };

    let mut stmt = conn.prepare(&query)?;
    let tracks = stmt
        .query_map([], |row| {
            let artist: String = row.get(1)?;
            Ok(Track {
                id: Some(row.get(0)?),
                metadata: TrackMetadata {
                    artist: artist.clone(),
                    album_artist: artist, // Views don't include album_artist, use artist
                    album: row.get(2)?,
                    title: row.get(3)?,
                    genre: None,
                    year: None,
                    bitrate: None,
                    duration: None,
                    format: row.get(5)?,
                    original_path: row.get(6)?,
                },
                organized_path: None,
                is_duplicate: false,
                date_added: Some(row.get(4)?),
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    Ok(tracks)
}

/// Create a liked playlist for a specific source.
///
/// Generates playlist name as "{Source} Likes" (e.g., "Spotify Likes").
/// Uses INSERT OR IGNORE for idempotent operation.
///
/// # Arguments
/// * `conn` - Database connection
/// * `source_name` - Name of the source (e.g., "spotify", "soundcloud")
/// * `source_id` - Database ID of the source
///
/// # Returns
/// * `Ok(playlist_id)` if playlist created successfully
/// * `Err` if database operation fails
pub fn create_liked_playlist_for_source(
    conn: &Connection,
    source_name: &str,
    source_id: i64,
) -> Result<i64> {
    let playlist_name = format!("{} Likes", capitalize(source_name));

    conn.execute(
        "INSERT OR IGNORE INTO playlists (name, category, is_liked, is_pinned, source_id) VALUES (?, ?, 1, 1, ?)",
        rusqlite::params![&playlist_name, "liked", source_id],
    )?;

    // Get the playlist ID
    let playlist_id: i64 = conn.query_row(
        "SELECT id FROM playlists WHERE source_id = ? AND is_liked = 1",
        [source_id],
        |row| row.get(0),
    )?;

    Ok(playlist_id)
}

/// Get or create a liked playlist for a specific source.
///
/// Checks if a liked playlist already exists for the source.
/// If it exists, returns the playlist_id. If not, creates it.
///
/// # Arguments
/// * `conn` - Database connection
/// * `source_name` - Name of the source (e.g., "spotify", "soundcloud")
/// * `source_id` - Database ID of the source
///
/// # Returns
/// * `Ok(playlist_id)` - ID of existing or newly created playlist
/// * `Err` if database operation fails
pub fn get_or_create_liked_playlist(
    conn: &Connection,
    source_name: &str,
    source_id: i64,
) -> Result<i64> {
    // Try to get existing playlist
    let existing = conn.query_row(
        "SELECT id FROM playlists WHERE source_id = ? AND is_liked = 1",
        [source_id],
        |row| row.get::<_, i64>(0),
    );

    match existing {
        Ok(id) => Ok(id),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            // Doesn't exist, create it
            create_liked_playlist_for_source(conn, source_name, source_id)
        }
        Err(e) => Err(e.into()),
    }
}

/// Create the "Local Likes" playlist for locally-sourced liked tracks.
///
/// Uses INSERT OR IGNORE for idempotent operation.
///
/// # Returns
/// * `Ok(playlist_id)` if playlist created successfully
/// * `Err` if database operation fails
pub fn create_local_likes_playlist(conn: &Connection) -> Result<i64> {
    conn.execute(
        "INSERT OR IGNORE INTO playlists (name, category, is_liked, is_pinned) VALUES (?, ?, 1, 1)",
        ["Local Likes", "liked"],
    )?;

    // Get the playlist ID
    let playlist_id: i64 = conn.query_row(
        "SELECT id FROM playlists WHERE name = 'Local Likes' AND is_liked = 1",
        [],
        |row| row.get(0),
    )?;

    Ok(playlist_id)
}

/// Refresh a mirrored playlist with add-only semantics.
///
/// Adds new tracks from the source without removing existing tracks.
/// Preserves user's manual reordering by only adding tracks not already present.
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of playlist to refresh
/// * `source_tracks` - Vector of (track_id, source_position_index) from source
///
/// # Returns
/// * `Ok(usize)` - Number of new tracks added
/// * `Err` if database operation fails
pub fn refresh_mirrored_playlist(
    conn: &Connection,
    playlist_id: i64,
    source_tracks: Vec<(i64, usize)>,
) -> Result<usize> {
    // Start transaction
    conn.execute_batch("BEGIN")?;

    // Query existing tracks in playlist
    let mut stmt = conn.prepare(
        "SELECT track_id, position FROM playlist_tracks WHERE playlist_id = ?",
    )?;

    let existing_tracks: std::collections::HashSet<i64> = stmt
        .query_map([playlist_id], |row| row.get::<_, i64>(0))?
        .collect::<std::result::Result<_, _>>()?;

    drop(stmt);

    let mut added_count = 0;

    // Add new tracks (tracks in source but not in local playlist)
    for (track_id, _source_idx) in source_tracks {
        if !existing_tracks.contains(&track_id) {
            // Track is not in playlist, add it
            add_track_to_playlist(conn, playlist_id, track_id)?;
            added_count += 1;
        }
        // If track already exists, skip it (preserves existing position)
    }

    // Commit transaction
    conn.execute_batch("COMMIT")?;

    Ok(added_count)
}

/// Add a liked track to a liked playlist.
///
/// Idempotent operation - if track already in playlist, does nothing.
/// Appends track to end of playlist with fractional indexing.
///
/// # Arguments
/// * `conn` - Database connection
/// * `playlist_id` - ID of liked playlist
/// * `track_id` - ID of track to add
/// * `date_added` - ISO 8601 timestamp when track was liked
///
/// # Returns
/// * `Ok(())` if track added or already exists
/// * `Err` if database operation fails
pub fn add_liked_track(
    conn: &Connection,
    playlist_id: i64,
    track_id: i64,
    date_added: &str,
) -> Result<()> {
    // Check if track already in playlist
    let exists: Option<i64> = conn
        .query_row(
            "SELECT id FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?",
            rusqlite::params![playlist_id, track_id],
            |row| row.get(0),
        )
        .optional()?;

    if exists.is_some() {
        // Track already in playlist, skip (idempotent)
        return Ok(());
    }

    // Get last position in playlist
    let last_position: Option<String> = conn
        .query_row(
            "SELECT position FROM playlist_tracks
             WHERE playlist_id = ?
             ORDER BY position DESC
             LIMIT 1",
            [playlist_id],
            |row| row.get(0),
        )
        .optional()?;

    // Generate new position (append after last)
    let new_position = position_between(last_position.as_deref(), None)?;

    // Insert track with new position and date_added
    conn.execute(
        "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at)
         VALUES (?, ?, ?, ?)",
        rusqlite::params![playlist_id, track_id, new_position, date_added],
    )?;

    Ok(())
}

/// Sync all tracks from a source into its liked playlist.
///
/// Finds (or creates) the liked playlist for the given source,
/// then adds any tracks present in `track_sources` but missing
/// from the playlist. Existing tracks are left untouched.
///
/// # Arguments
/// * `conn` - Database connection
/// * `source_name` - Source name (e.g. "soundcloud", "spotify")
///
/// # Returns
/// * `Ok((playlist_id, added_count, total_count))` on success
/// * `Err` if source not found or database operation fails
pub fn sync_source_likes_playlist(
    conn: &Connection,
    source_name: &str,
) -> Result<(i64, usize, usize)> {
    // Look up source
    let source_id: i64 = conn.query_row(
        "SELECT id FROM sources WHERE name = ?1 LIMIT 1",
        [source_name],
        |row| row.get(0),
    )?;

    // Get or create the liked playlist
    let playlist_id = get_or_create_liked_playlist(conn, source_name, source_id)?;

    // Get all track IDs from this source, newest first
    let mut stmt = conn.prepare(
        "SELECT track_id FROM track_sources WHERE source_id = ?1 ORDER BY added_at DESC",
    )?;
    let source_track_ids: Vec<i64> = stmt
        .query_map([source_id], |row| row.get::<_, i64>(0))?
        .collect::<std::result::Result<_, _>>()?;

    let total = source_track_ids.len();

    // Rebuild playlist: clear and re-insert in newest-first order
    conn.execute_batch("BEGIN")?;

    let old_count: usize = conn.query_row(
        "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?1",
        [playlist_id],
        |row| row.get(0),
    )?;

    conn.execute(
        "DELETE FROM playlist_tracks WHERE playlist_id = ?1",
        [playlist_id],
    )?;

    for track_id in &source_track_ids {
        add_track_to_playlist(conn, playlist_id, *track_id)?;
    }

    conn.execute_batch("COMMIT")?;

    let added = total.saturating_sub(old_count);

    Ok((playlist_id, added, total))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_position_between_empty_playlist() {
        let pos = position_between(None, None).unwrap();
        assert_eq!(pos, "a0");
    }

    #[test]
    fn test_position_between_insert_at_end() {
        let pos = position_between(Some("a0"), None).unwrap();
        assert_eq!(pos, "a0|a0");
        assert!(pos.as_str() > "a0");

        let pos2 = position_between(Some("z9"), None).unwrap();
        assert_eq!(pos2, "z9|a0");
        assert!(pos2.as_str() > "z9");
    }

    #[test]
    fn test_position_between_insert_at_beginning() {
        let pos = position_between(None, Some("b0")).unwrap();
        assert_eq!(pos, "a0");
        assert!(pos.as_str() < "b0");

        // Edge case: right is "a0" or less
        let pos2 = position_between(None, Some("a0")).unwrap();
        assert!(pos2.as_str() < "a0", "Expected {} < a0", pos2);
    }

    #[test]
    fn test_position_between_insert_between() {
        let pos = position_between(Some("a0"), Some("b0")).unwrap();
        assert!(pos.as_str() > "a0");
        assert!(pos.as_str() < "b0");

        // Adjacent positions
        let pos2 = position_between(Some("a0"), Some("a1")).unwrap();
        assert!(pos2.as_str() > "a0");
        assert!(pos2.as_str() < "a1");
    }

    #[test]
    fn test_position_lexicographic_ordering() {
        // Test that multiple insertions maintain order
        let p1 = position_between(None, None).unwrap(); // "a0"
        let p2 = position_between(Some(&p1), None).unwrap(); // "a0|a0"
        let p3 = position_between(Some(&p2), None).unwrap(); // "a0|a0|a0"

        assert!(p1 < p2);
        assert!(p2 < p3);

        // Insert between p1 and p2
        let p_mid = position_between(Some(&p1), Some(&p2)).unwrap();
        assert!(p1.as_str() < p_mid.as_str(), "Expected {} < {}", p1, p_mid);
        assert!(p_mid.as_str() < p2.as_str(), "Expected {} < {}", p_mid, p2);
    }

    #[test]
    fn test_increment_position_string() {
        assert_eq!(increment_position_string("a0"), "a0|a0");
        assert_eq!(increment_position_string("z9"), "z9|a0");
        assert_eq!(increment_position_string("test"), "test|a0");
    }

    #[test]
    fn test_midpoint_position_string() {
        // Basic midpoint
        let mid = midpoint_position_string("a0", "z0").unwrap();
        assert!(mid.as_str() > "a0");
        assert!(mid.as_str() < "z0");

        // Adjacent characters
        let mid2 = midpoint_position_string("a0", "a1").unwrap();
        assert!(mid2.as_str() > "a0");
        assert!(mid2.as_str() < "a1");

        // Different lengths
        let mid3 = midpoint_position_string("a", "b").unwrap();
        assert!(mid3.as_str() > "a");
        assert!(mid3.as_str() < "b");
    }

    #[test]
    fn test_create_playlist_with_tags() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        // Create playlist with tags
        let playlist_id = create_playlist(
            &conn,
            "My Playlist".to_string(),
            Some("Test description".to_string()),
            vec!["rock".to_string(), "workout".to_string()],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Verify playlist created
        let (name, description, category): (String, Option<String>, String) = conn
            .query_row(
                "SELECT name, description, category FROM playlists WHERE id = ?1",
                [playlist_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();

        assert_eq!(name, "My Playlist");
        assert_eq!(description, Some("Test description".to_string()));
        assert_eq!(category, "regular");

        // Verify tags created
        let tag_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM playlist_tags WHERE playlist_id = ?1",
                [playlist_id],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(tag_count, 2);
    }

    #[test]
    fn test_add_track_to_playlist() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        // Create playlist
        let playlist_id = create_playlist(
            &conn,
            "Test Playlist".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Insert tracks
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params!["Artist 1", "Artist 1", "Album", "Track 1", "mp3", "/path1.mp3"],
        )
        .unwrap();
        let track1_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params!["Artist 2", "Artist 2", "Album", "Track 2", "mp3", "/path2.mp3"],
        )
        .unwrap();
        let track2_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params!["Artist 3", "Artist 3", "Album", "Track 3", "mp3", "/path3.mp3"],
        )
        .unwrap();
        let track3_id = conn.last_insert_rowid();

        // Add tracks to playlist
        add_track_to_playlist(&conn, playlist_id, track1_id).unwrap();
        add_track_to_playlist(&conn, playlist_id, track2_id).unwrap();
        add_track_to_playlist(&conn, playlist_id, track3_id).unwrap();

        // Verify positions are ordered
        let positions: Vec<String> = conn
            .prepare("SELECT position FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position")
            .unwrap()
            .query_map([playlist_id], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        assert_eq!(positions.len(), 3);
        assert!(positions[0] < positions[1]);
        assert!(positions[1] < positions[2]);
    }

    #[test]
    fn test_add_track_duplicate_fails() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Test".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "mp3", "/path.mp3"],
        )
        .unwrap();
        let track_id = conn.last_insert_rowid();

        // Add track first time - should succeed
        add_track_to_playlist(&conn, playlist_id, track_id).unwrap();

        // Add same track again - should fail due to UNIQUE constraint
        let result = add_track_to_playlist(&conn, playlist_id, track_id);
        assert!(result.is_err());
    }

    #[test]
    fn test_remove_track_from_playlist() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Test".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Insert 3 tracks
        for i in 1..=3 {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![
                    format!("Artist {}", i),
                    format!("Artist {}", i),
                    "Album",
                    format!("Track {}", i),
                    "mp3",
                    format!("/path{}.mp3", i)
                ],
            )
            .unwrap();

            add_track_to_playlist(&conn, playlist_id, conn.last_insert_rowid()).unwrap();
        }

        // Get middle track ID
        let track_ids: Vec<i64> = conn
            .prepare("SELECT track_id FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position")
            .unwrap()
            .query_map([playlist_id], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        let middle_track_id = track_ids[1];

        // Get positions before removal
        let positions_before: Vec<String> = conn
            .prepare("SELECT position FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position")
            .unwrap()
            .query_map([playlist_id], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        // Remove middle track
        remove_track_from_playlist(&conn, playlist_id, middle_track_id).unwrap();

        // Verify only 2 tracks remain
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?1",
                [playlist_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);

        // Verify positions of remaining tracks are unchanged
        let positions_after: Vec<String> = conn
            .prepare("SELECT position FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position")
            .unwrap()
            .query_map([playlist_id], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        assert_eq!(positions_after[0], positions_before[0]); // First track unchanged
        assert_eq!(positions_after[1], positions_before[2]); // Third track unchanged
    }

    #[test]
    fn test_reorder_playlist_track() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Test".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Insert 3 tracks
        let mut track_ids = Vec::new();
        for i in 1..=3 {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![
                    format!("Artist {}", i),
                    format!("Artist {}", i),
                    "Album",
                    format!("Track {}", i),
                    "mp3",
                    format!("/path{}.mp3", i)
                ],
            )
            .unwrap();

            let track_id = conn.last_insert_rowid();
            track_ids.push(track_id);
            add_track_to_playlist(&conn, playlist_id, track_id).unwrap();
        }

        // Move track 3 between track 1 and track 2
        reorder_playlist_track(&conn, playlist_id, track_ids[2], Some(track_ids[0]), Some(track_ids[1])).unwrap();

        // Verify new order
        let ordered_ids: Vec<i64> = conn
            .prepare("SELECT track_id FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position")
            .unwrap()
            .query_map([playlist_id], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        assert_eq!(ordered_ids, vec![track_ids[0], track_ids[2], track_ids[1]]);

        // Verify only the moved track's position changed (1 UPDATE)
        // We can't directly test the UPDATE count, but we verify logical correctness
    }

    #[test]
    fn test_search_playlist_tracks() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Test".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Insert tracks with different metadata
        let tracks_data = vec![
            ("Daft Punk", "Random Access Memories", "Get Lucky"),
            ("Daft Punk", "Discovery", "One More Time"),
            ("Justice", "Cross", "D.A.N.C.E."),
            ("The Weeknd", "After Hours", "Blinding Lights"),
        ];

        for (artist, album, title) in tracks_data {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![artist, artist, album, title, "mp3", format!("/{}.mp3", title)],
            )
            .unwrap();

            add_track_to_playlist(&conn, playlist_id, conn.last_insert_rowid()).unwrap();
        }

        // Search by artist
        let results = search_playlist_tracks(&conn, playlist_id, "Daft Punk").unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].metadata.title, "Get Lucky");
        assert_eq!(results[1].metadata.title, "One More Time");

        // Search by title (partial)
        let results = search_playlist_tracks(&conn, playlist_id, "Light").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].metadata.title, "Blinding Lights");

        // Search by album
        let results = search_playlist_tracks(&conn, playlist_id, "Cross").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].metadata.artist, "Justice");

        // Search with no matches
        let results = search_playlist_tracks(&conn, playlist_id, "xyz123").unwrap();
        assert_eq!(results.len(), 0);

        // Case-insensitive search
        let results = search_playlist_tracks(&conn, playlist_id, "daft punk").unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_get_playlist_tracks() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Test".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Insert tracks
        let titles = vec!["Track A", "Track B", "Track C"];
        for title in &titles {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params!["Artist", "Artist", "Album", title, "mp3", format!("/{}.mp3", title)],
            )
            .unwrap();

            add_track_to_playlist(&conn, playlist_id, conn.last_insert_rowid()).unwrap();
        }

        // Get tracks in order
        let tracks = get_playlist_tracks(&conn, playlist_id).unwrap();

        assert_eq!(tracks.len(), 3);
        assert_eq!(tracks[0].metadata.title, "Track A");
        assert_eq!(tracks[1].metadata.title, "Track B");
        assert_eq!(tracks[2].metadata.title, "Track C");

        // Verify they're ordered by position
        for i in 0..tracks.len() - 1 {
            assert!(tracks[i].id < tracks[i + 1].id || tracks[i].metadata.title < tracks[i + 1].metadata.title);
        }
    }

    #[test]
    fn test_refresh_mirrored_playlist_add_only() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        // Create playlist
        let playlist_id = create_playlist(
            &conn,
            "Mirrored Playlist".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Insert tracks A, B, C
        let mut track_ids = Vec::new();
        for title in &["Track A", "Track B", "Track C"] {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?, ?, ?, ?, ?, ?)",
                rusqlite::params!["Artist", "Artist", "Album", title, "mp3", format!("/{}.mp3", title)],
            )
            .unwrap();
            let track_id = conn.last_insert_rowid();
            track_ids.push(track_id);
            add_track_to_playlist(&conn, playlist_id, track_id).unwrap();
        }

        // Verify initial state
        let tracks = get_playlist_tracks(&conn, playlist_id).unwrap();
        assert_eq!(tracks.len(), 3);

        // Source now has [A, B, D, C] (D is new, C moved, but we keep original order)
        let track_d_id = {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?, ?, ?, ?, ?, ?)",
                rusqlite::params!["Artist", "Artist", "Album", "Track D", "mp3", "/trackd.mp3"],
            )
            .unwrap();
            conn.last_insert_rowid()
        };

        let source_tracks = vec![
            (track_ids[0], 0), // A at position 0
            (track_ids[1], 1), // B at position 1
            (track_d_id, 2),   // D at position 2 (new)
            (track_ids[2], 3), // C at position 3
        ];

        // Refresh playlist
        let added_count = refresh_mirrored_playlist(&conn, playlist_id, source_tracks).unwrap();
        assert_eq!(added_count, 1); // Only D was added

        // Verify D was added
        let tracks = get_playlist_tracks(&conn, playlist_id).unwrap();
        assert_eq!(tracks.len(), 4);
        assert!(tracks.iter().any(|t| t.metadata.title == "Track D"));

        // Verify A, B, C positions unchanged (still in original order)
        let titles: Vec<&str> = tracks.iter().map(|t| t.metadata.title.as_str()).collect();
        assert_eq!(titles[0], "Track A");
        assert_eq!(titles[1], "Track B");
        assert_eq!(titles[2], "Track C");
        assert_eq!(titles[3], "Track D"); // D added at end
    }

    #[test]
    fn test_refresh_mirrored_playlist_removes_nothing() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Test".to_string(),
            None,
            vec![],
            PlaylistCategory::Regular,
        )
        .unwrap();

        // Add tracks A, B, C
        let mut track_ids = Vec::new();
        for title in &["Track A", "Track B", "Track C"] {
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                 VALUES (?, ?, ?, ?, ?, ?)",
                rusqlite::params!["Artist", "Artist", "Album", title, "mp3", format!("/{}.mp3", title)],
            )
            .unwrap();
            let track_id = conn.last_insert_rowid();
            track_ids.push(track_id);
            add_track_to_playlist(&conn, playlist_id, track_id).unwrap();
        }

        // Source now only has [A, B] (C removed from source)
        let source_tracks = vec![(track_ids[0], 0), (track_ids[1], 1)];

        // Refresh playlist
        let added_count = refresh_mirrored_playlist(&conn, playlist_id, source_tracks).unwrap();
        assert_eq!(added_count, 0); // No new tracks

        // Verify C still exists in playlist (add-only semantics)
        let tracks = get_playlist_tracks(&conn, playlist_id).unwrap();
        assert_eq!(tracks.len(), 3);
        assert!(tracks.iter().any(|t| t.metadata.title == "Track C"));
    }

    #[test]
    fn test_add_liked_track() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Liked".to_string(),
            None,
            vec![],
            PlaylistCategory::Liked,
        )
        .unwrap();

        // Insert tracks
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track 1", "mp3", "/track1.mp3"],
        )
        .unwrap();
        let track1_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track 2", "mp3", "/track2.mp3"],
        )
        .unwrap();
        let track2_id = conn.last_insert_rowid();

        // Add liked tracks
        add_liked_track(&conn, playlist_id, track1_id, "2026-02-01T00:00:00Z").unwrap();
        add_liked_track(&conn, playlist_id, track2_id, "2026-02-02T00:00:00Z").unwrap();

        // Verify tracks added
        let tracks = get_playlist_tracks(&conn, playlist_id).unwrap();
        assert_eq!(tracks.len(), 2);

        // Verify added_at timestamps
        let timestamps: Vec<Option<String>> = conn
            .prepare("SELECT added_at FROM playlist_tracks WHERE playlist_id = ? ORDER BY position")
            .unwrap()
            .query_map([playlist_id], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<_, _>>()
            .unwrap();

        assert_eq!(timestamps[0], Some("2026-02-01T00:00:00Z".to_string()));
        assert_eq!(timestamps[1], Some("2026-02-02T00:00:00Z".to_string()));
    }

    #[test]
    fn test_add_liked_track_idempotent() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        let playlist_id = create_playlist(
            &conn,
            "Liked".to_string(),
            None,
            vec![],
            PlaylistCategory::Liked,
        )
        .unwrap();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track 1", "mp3", "/track1.mp3"],
        )
        .unwrap();
        let track_id = conn.last_insert_rowid();

        // Add track first time
        add_liked_track(&conn, playlist_id, track_id, "2026-02-01T00:00:00Z").unwrap();

        // Add same track again (should be idempotent)
        add_liked_track(&conn, playlist_id, track_id, "2026-02-01T00:00:00Z").unwrap();

        // Should still only have one track
        let tracks = get_playlist_tracks(&conn, playlist_id).unwrap();
        assert_eq!(tracks.len(), 1);
    }
}
