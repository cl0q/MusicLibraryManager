//! Local artwork file cache management.
//!
//! This module provides:
//! - File-based artwork cache with track_id naming
//! - Cache hit detection
//! - Database state persistence

use anyhow::{anyhow, Result};
use rusqlite::Connection;
use std::fs;
use std::path::PathBuf;

/// Artwork cache manager.
///
/// Manages local file cache for album artwork with consistent naming.
/// Files are stored as {track_id}_{size}.jpg.
#[derive(Debug, Clone)]
pub struct ArtworkCache {
    cache_dir: PathBuf,
}

impl ArtworkCache {
    /// Create a new artwork cache.
    ///
    /// Creates the cache directory if it doesn't exist.
    ///
    /// # Arguments
    /// * `cache_dir` - Directory path for cached artwork files
    ///
    /// # Returns
    /// * `Ok(cache)` - Cache instance ready to use
    /// * `Err(_)` - Failed to create cache directory
    pub fn new(cache_dir: PathBuf) -> Result<Self> {
        if !cache_dir.exists() {
            fs::create_dir_all(&cache_dir)
                .map_err(|e| anyhow!("Failed to create artwork cache directory: {}", e))?;
        }

        Ok(Self { cache_dir })
    }

    /// Get the cached file path for a track and size.
    ///
    /// Returns the path regardless of whether the file exists.
    ///
    /// # Arguments
    /// * `track_id` - Track database ID
    /// * `size` - Size identifier ("500" or "1200")
    ///
    /// # Returns
    /// Path to cache file: {cache_dir}/{track_id}_{size}.jpg
    pub fn get_cached_path(&self, track_id: i64, size: &str) -> PathBuf {
        self.cache_dir.join(format!("{}_{}.jpg", track_id, size))
    }

    /// Check if artwork is cached for a track.
    ///
    /// # Arguments
    /// * `track_id` - Track database ID
    /// * `size` - Size identifier ("500" or "1200")
    ///
    /// # Returns
    /// `true` if file exists in cache, `false` otherwise
    pub fn is_cached(&self, track_id: i64, size: &str) -> bool {
        self.get_cached_path(track_id, size).exists()
    }

    /// Save artwork data to cache.
    ///
    /// Writes image data to the cache directory.
    ///
    /// # Arguments
    /// * `track_id` - Track database ID
    /// * `size` - Size identifier ("500" or "1200")
    /// * `data` - Image bytes
    ///
    /// # Returns
    /// * `Ok(path)` - Path to saved file
    /// * `Err(_)` - Failed to write file
    pub fn save_to_cache(&self, track_id: i64, size: &str, data: &[u8]) -> Result<PathBuf> {
        let path = self.get_cached_path(track_id, size);
        fs::write(&path, data)
            .map_err(|e| anyhow!("Failed to write artwork cache file: {}", e))?;
        Ok(path)
    }
}

/// Save artwork state to database.
///
/// Records artwork metadata in the artwork table.
/// Uses INSERT OR REPLACE for idempotent updates.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track database ID
/// * `artwork_path` - Local path to artwork file
/// * `source` - Source of artwork ("embedded", "musicbrainz", "manual")
/// * `mbid` - Optional MusicBrainz release group ID
/// * `resolution` - Image dimensions (e.g., "500x500")
///
/// # Returns
/// * `Ok(())` - State saved successfully
/// * `Err(_)` - Database error
pub fn save_artwork_state(
    conn: &Connection,
    track_id: i64,
    artwork_path: &str,
    source: &str,
    mbid: Option<&str>,
    resolution: &str,
) -> crate::database::connection::Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO artwork (track_id, artwork_path, source, musicbrainz_release_group_id, resolution)
         VALUES (?, ?, ?, ?, ?)",
        rusqlite::params![track_id, artwork_path, source, mbid, resolution],
    )?;
    Ok(())
}

/// Get tracks that don't have artwork yet.
///
/// Returns tracks without entries in the artwork table.
///
/// # Arguments
/// * `conn` - Database connection
///
/// # Returns
/// List of (track_id, artist, album) tuples for tracks needing artwork
pub fn get_tracks_without_artwork(conn: &Connection) -> crate::database::connection::Result<Vec<(i64, String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.artist, t.album
         FROM tracks t
         LEFT JOIN artwork a ON t.id = a.track_id
         WHERE a.track_id IS NULL",
    )?;

    let rows = stmt.query_map([], |row| {
        Ok((row.get(0)?, row.get(1)?, row.get(2)?))
    })?;

    let mut tracks = Vec::new();
    for row in rows {
        tracks.push(row?);
    }

    Ok(tracks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_artwork_cache_path() {
        let temp_dir = TempDir::new().unwrap();
        let cache = ArtworkCache::new(temp_dir.path().to_path_buf()).unwrap();

        let path = cache.get_cached_path(42, "500");
        assert_eq!(path.file_name().unwrap(), "42_500.jpg");

        let path = cache.get_cached_path(42, "1200");
        assert_eq!(path.file_name().unwrap(), "42_1200.jpg");
    }

    #[test]
    fn test_save_and_check_cached() {
        let temp_dir = TempDir::new().unwrap();
        let cache = ArtworkCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Initially not cached
        assert!(!cache.is_cached(42, "500"));

        // Save some data
        let data = vec![0xFF, 0xD8, 0xFF, 0xE0]; // JPEG header
        cache.save_to_cache(42, "500", &data).unwrap();

        // Now should be cached
        assert!(cache.is_cached(42, "500"));

        // Different size should not be cached
        assert!(!cache.is_cached(42, "1200"));
    }

    #[test]
    fn test_get_tracks_without_artwork() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&mut conn).unwrap();

        // Insert test tracks
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist1", "Artist1", "Album1", "Track1", "mp3", "/path/1.mp3"],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist2", "Artist2", "Album2", "Track2", "mp3", "/path/2.mp3"],
        )
        .unwrap();

        // Add artwork for track 1
        save_artwork_state(&conn, 1, "/cache/1_500.jpg", "musicbrainz", None, "500x500").unwrap();

        // Get tracks without artwork
        let tracks = get_tracks_without_artwork(&conn).unwrap();

        // Should only return track 2
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].0, 2);
        assert_eq!(tracks[0].1, "Artist2");
        assert_eq!(tracks[0].2, "Album2");
    }

    #[test]
    fn test_save_artwork_state_roundtrip() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&mut conn).unwrap();

        // Insert test track
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Artist", "Artist", "Album", "Track", "mp3", "/path/1.mp3"],
        )
        .unwrap();

        // Save artwork state
        save_artwork_state(
            &conn,
            1,
            "/cache/1_500.jpg",
            "musicbrainz",
            Some("abc-123"),
            "500x500",
        )
        .unwrap();

        // Query it back
        let (path, source, mbid, resolution): (String, String, Option<String>, String) = conn
            .query_row(
                "SELECT artwork_path, source, musicbrainz_release_group_id, resolution
                 FROM artwork WHERE track_id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();

        assert_eq!(path, "/cache/1_500.jpg");
        assert_eq!(source, "musicbrainz");
        assert_eq!(mbid, Some("abc-123".to_string()));
        assert_eq!(resolution, "500x500");
    }
}
