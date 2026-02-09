//! Database operations for tracks table.
//!
//! Provides functions for updating track metadata and status.

use rusqlite::Connection;

/// Update the download_status column for a track to mark it as downloaded.
///
/// Sets download_status to current ISO 8601 timestamp. This marks the track
/// as having transitioned from Remote (undownloaded) to Library (downloaded).
///
/// Per Phase 9 decision: download_status is NULL for undownloaded tracks,
/// ISO 8601 timestamp for downloaded tracks.
///
/// # Arguments
/// * `conn` - SQLite connection
/// * `track_id` - Track ID to update
///
/// # Returns
/// * `Ok(())` on success
/// * `Err(rusqlite::Error)` on database error
pub fn update_download_status(
    conn: &Connection,
    track_id: i64,
) -> rusqlite::Result<()> {
    let timestamp = chrono::Utc::now().to_rfc3339();

    conn.execute(
        "UPDATE tracks SET download_status = ? WHERE id = ?",
        rusqlite::params![timestamp, track_id],
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn test_update_download_status() {
        let conn = Connection::open_in_memory().unwrap();

        // Create tracks table
        conn.execute_batch(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                artist TEXT NOT NULL,
                album_artist TEXT NOT NULL,
                album TEXT NOT NULL,
                title TEXT NOT NULL,
                format TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                organized_path TEXT,
                download_status TEXT
            )",
        )
        .unwrap();

        // Insert test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, download_status)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "mp3", "/path/to/file.mp3", rusqlite::types::Null],
        )
        .unwrap();

        // Verify download_status is NULL
        let status: Option<String> = conn
            .query_row("SELECT download_status FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert_eq!(status, None);

        // Update download_status
        update_download_status(&conn, 1).unwrap();

        // Verify download_status is now set to a timestamp
        let status: Option<String> = conn
            .query_row("SELECT download_status FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert!(status.is_some());

        // Verify it's a valid ISO 8601 timestamp
        let timestamp = status.unwrap();
        assert!(chrono::DateTime::parse_from_rfc3339(&timestamp).is_ok());
    }

    #[test]
    fn test_update_download_status_nonexistent_track() {
        let conn = Connection::open_in_memory().unwrap();

        // Create tracks table
        conn.execute_batch(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                artist TEXT NOT NULL,
                album_artist TEXT NOT NULL,
                album TEXT NOT NULL,
                title TEXT NOT NULL,
                format TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                download_status TEXT
            )",
        )
        .unwrap();

        // Try to update non-existent track (should succeed but affect 0 rows)
        let result = update_download_status(&conn, 999);
        assert!(result.is_ok());
    }
}
