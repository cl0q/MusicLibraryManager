//! Database operations for tracks table.
//!
//! Provides functions for updating track metadata and status.

use rusqlite::Connection;
use std::path::Path;

/// Validate that an organized_path is relative to the library root (never absolute).
///
/// Enforces the Phase 8-01 invariant: organized_path is ALWAYS relative to library root.
/// An absolute path would break portability when the library moves to a different drive.
///
/// # Arguments
/// * `path` - The organized_path candidate to validate
///
/// # Returns
/// * `Ok(())` if path is a valid relative path
/// * `Err(String)` describing the violation
pub fn validate_organized_path(path: &str) -> Result<(), String> {
    // Check for Unix/POSIX absolute path (starts with /)
    // Also check for Windows-style absolute paths (e.g. C:\...) which contain a drive letter
    // followed by a colon. On Unix, Path::is_absolute() won't catch these.
    let is_windows_absolute = path.len() >= 2
        && path.chars().next().map_or(false, |c| c.is_ascii_alphabetic())
        && path.chars().nth(1) == Some(':');

    if Path::new(path).is_absolute() || is_windows_absolute {
        return Err(format!(
            "organized_path must be relative to library root, not absolute. Got: {}",
            path
        ));
    }
    if path.contains("..") {
        return Err(format!(
            "organized_path must not contain '..', got: {}",
            path
        ));
    }
    Ok(())
}

/// Update the download_status and organized_path for a track to mark it as downloaded.
///
/// Sets download_status to current ISO 8601 timestamp and organized_path to
/// the downloaded file location. This transitions the track from Remote to Library.
///
/// Per Phase 9 decision: download_status is NULL for undownloaded tracks,
/// ISO 8601 timestamp for downloaded tracks. organized_path IS NULL = remote,
/// organized_path IS NOT NULL = library.
///
/// # Arguments
/// * `conn` - SQLite connection
/// * `track_id` - Track ID to update
/// * `organized_path` - Relative path for DB storage (e.g. "00_Artist/Artist/Title/track.m4a")
/// * `absolute_path` - Absolute path to the file on disk (for bitrate detection)
///
/// # Returns
/// * `Ok(())` on success
/// * `Err(rusqlite::Error)` on database error
pub fn update_download_status(
    conn: &Connection,
    track_id: i64,
    organized_path: &str,
    absolute_path: &str,
) -> rusqlite::Result<()> {
    validate_organized_path(organized_path)
        .map_err(|e| rusqlite::Error::InvalidParameterName(e))?;

    let timestamp = chrono::Utc::now().to_rfc3339();

    // Detect format and bitrate from the actual file on disk
    let (format, bitrate) = detect_file_format_bitrate(absolute_path);

    conn.execute(
        "UPDATE tracks SET download_status = ?, organized_path = ?, format = ?, bitrate = ?, date_added = ? WHERE id = ?",
        rusqlite::params![timestamp, organized_path, format, bitrate, timestamp, track_id],
    )?;

    Ok(())
}

/// Detect format name and bitrate from a downloaded file path.
///
/// Uses file extension for format (m4a -> "aac", mp3 -> "mp3", flac -> "flac")
/// and symphonia for bitrate detection. Returns defaults on failure.
fn detect_file_format_bitrate(file_path: &str) -> (String, Option<u64>) {
    use std::path::Path;

    let path = Path::new(file_path);

    // Determine format from extension
    let format = match path.extension().and_then(|e| e.to_str()) {
        Some("m4a") | Some("aac") => "aac".to_string(),
        Some("mp3") => "mp3".to_string(),
        Some("flac") => "flac".to_string(),
        Some("opus") => "opus".to_string(),
        Some("wav") => "wav".to_string(),
        Some(ext) => ext.to_lowercase(),
        None => "unknown".to_string(),
    };

    // Detect bitrate using transcode::format module
    let bitrate = match crate::transcode::detect_format(path) {
        Ok(audio_format) => audio_format.bitrate,
        Err(e) => {
            log::warn!("Failed to detect bitrate for {}: {}", file_path, e);
            None
        }
    };

    (format, bitrate)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn test_validate_organized_path_rejects_unix_absolute() {
        let result = validate_organized_path("/Volumes/Lexxar/Music/Artist/track.m4a");
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains("must be relative"), "Expected 'must be relative' in: {}", msg);
    }

    #[test]
    fn test_validate_organized_path_rejects_windows_absolute() {
        let result = validate_organized_path("C:\\Music\\track.m4a");
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains("must be relative"), "Expected 'must be relative' in: {}", msg);
    }

    #[test]
    fn test_validate_organized_path_rejects_dotdot() {
        let result = validate_organized_path("../Artist/track.m4a");
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(msg.contains("must not contain"), "Expected 'must not contain' in: {}", msg);
    }

    #[test]
    fn test_validate_organized_path_accepts_relative() {
        let result = validate_organized_path("Artist/Album/track.m4a");
        assert!(result.is_ok());
    }

    #[test]
    fn test_update_download_status_rejects_absolute_organized_path() {
        let conn = Connection::open_in_memory().unwrap();

        // Create tracks table
        conn.execute_batch(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                artist TEXT NOT NULL,
                album_artist TEXT NOT NULL,
                album TEXT NOT NULL,
                title TEXT NOT NULL,
                bitrate INTEGER,
                format TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                organized_path TEXT,
                download_status TEXT,
                date_added TEXT
            )",
        )
        .unwrap();

        // Insert test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "stream", "/path/to/file.mp3"],
        )
        .unwrap();

        // Attempt to update with absolute organized_path — must return Err
        let result = update_download_status(
            &conn,
            1,
            "/abs/path.m4a",
            "/abs/path.m4a",
        );
        assert!(result.is_err(), "Expected Err when organized_path is absolute");
    }

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
                bitrate INTEGER,
                format TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                organized_path TEXT,
                download_status TEXT,
                date_added TEXT
            )",
        )
        .unwrap();

        // Insert test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, download_status)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "stream", "/path/to/file.mp3", rusqlite::types::Null],
        )
        .unwrap();

        // Verify download_status is NULL
        let status: Option<String> = conn
            .query_row("SELECT download_status FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert_eq!(status, None);

        // Update download_status (file doesn't exist, so format detection falls back gracefully)
        update_download_status(&conn, 1, "downloads/track.m4a", "/downloads/track.m4a").unwrap();

        // Verify download_status is now set to a timestamp
        let status: Option<String> = conn
            .query_row("SELECT download_status FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert!(status.is_some());

        // Verify it's a valid ISO 8601 timestamp
        let timestamp = status.unwrap();
        assert!(chrono::DateTime::parse_from_rfc3339(&timestamp).is_ok());

        // Verify organized_path is set
        let org_path: Option<String> = conn
            .query_row("SELECT organized_path FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert_eq!(org_path, Some("downloads/track.m4a".to_string()));

        // Verify format was updated from extension
        let format: String = conn
            .query_row("SELECT format FROM tracks WHERE id = 1", [], |row| row.get(0))
            .unwrap();
        assert_eq!(format, "aac");
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
                bitrate INTEGER,
                format TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                organized_path TEXT,
                download_status TEXT,
                date_added TEXT
            )",
        )
        .unwrap();

        // Try to update non-existent track (should succeed but affect 0 rows)
        let result = update_download_status(&conn, 999, "downloads/missing.m4a", "/downloads/missing.m4a");
        assert!(result.is_ok());
    }
}
