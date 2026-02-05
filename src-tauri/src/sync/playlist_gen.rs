//! M3U8 playlist generation for Rockbox devices.
//!
//! Generates RFC-compliant M3U8 playlists with relative paths that work
//! with Rockbox firmware on iPods and other supported devices.

use std::path::Path;
use std::fs::File;
use std::io::{BufWriter, Write};
use anyhow::{Result, Context};
use crate::models::track::Track;
use crate::metadata::sanitize::sanitize_filename;

/// Generate M3U8 playlist content with relative paths.
///
/// Creates an M3U8 playlist following the extended M3U format:
/// - #EXTM3U header line
/// - #EXTINF:{duration},{artist} - {title} metadata lines
/// - Relative file paths: Artist/Album/Track.m4a
///
/// Paths are relative to the profile folder root and use FAT32-safe names.
///
/// # Arguments
/// * `playlist_name` - Name of the playlist (for future metadata)
/// * `tracks` - Slice of tracks to include in playlist
/// * `profile_folder` - Root path of the sync profile (not used in relative paths but kept for API consistency)
///
/// # Returns
/// M3U8 content as a string with Unix line endings (\n)
pub fn generate_m3u8(
    _playlist_name: &str,
    tracks: &[Track],
    _profile_folder: &Path,
) -> Result<String> {
    let mut lines = Vec::new();

    // M3U8 header
    lines.push("#EXTM3U".to_string());

    for track in tracks {
        // #EXTINF with duration and artist - title
        let duration = track.metadata.duration.unwrap_or(0);
        let extinf = format!(
            "#EXTINF:{},{} - {}",
            duration,
            track.metadata.artist,
            track.metadata.title
        );
        lines.push(extinf);

        // Relative path from profile root to track file
        // Profile structure: Artist/Album/Track.m4a
        let relative_path = format!(
            "{}/{}/{}.m4a",
            sanitize_filename(&track.metadata.album_artist),
            sanitize_filename(&track.metadata.album),
            sanitize_filename(&track.metadata.title)
        );
        lines.push(relative_path);
    }

    Ok(lines.join("\n"))
}

/// Write playlist content to a file.
///
/// Creates parent directories if they don't exist.
///
/// # Arguments
/// * `playlist_path` - Full path where playlist file should be written
/// * `content` - M3U8 content string to write
pub fn write_playlist_file(
    playlist_path: &Path,
    content: &str,
) -> Result<()> {
    if let Some(parent) = playlist_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let file = File::create(playlist_path)
        .context("Failed to create playlist file")?;

    let mut writer = BufWriter::new(file);
    writer.write_all(content.as_bytes())?;
    writer.flush()?;

    Ok(())
}

/// Generate and write playlist to profile's Playlists directory.
///
/// Convenience function that:
/// 1. Creates profile_folder/Playlists/ directory if needed
/// 2. Generates M3U8 content from tracks
/// 3. Writes to profile_folder/Playlists/{playlist_name}.m3u8
///
/// # Arguments
/// * `profile_folder` - Root directory of the sync profile
/// * `playlist_name` - Name for the playlist file (without .m3u8 extension)
/// * `tracks` - Tracks to include in the playlist
pub fn write_profile_playlist(
    profile_folder: &Path,
    playlist_name: &str,
    tracks: &[Track],
) -> Result<()> {
    let playlists_dir = profile_folder.join("Playlists");
    std::fs::create_dir_all(&playlists_dir)?;

    let content = generate_m3u8(playlist_name, tracks, profile_folder)?;
    let playlist_path = playlists_dir.join(format!("{}.m3u8", playlist_name));

    write_playlist_file(&playlist_path, &content)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::track::TrackMetadata;
    use tempfile::TempDir;
    use std::fs;

    fn create_test_track(
        id: i64,
        artist: &str,
        album_artist: &str,
        album: &str,
        title: &str,
        duration: Option<u32>,
    ) -> Track {
        let metadata = TrackMetadata {
            artist: artist.to_string(),
            album_artist: album_artist.to_string(),
            album: album.to_string(),
            title: title.to_string(),
            genre: None,
            year: None,
            bitrate: Some(248),
            duration,
            format: "m4a".to_string(),
            original_path: "/original/path".to_string(),
        };

        Track {
            id: Some(id),
            metadata,
            organized_path: format!("{}/{}/{}.m4a", album_artist, album, title),
            is_duplicate: false,
            date_added: Some("2024-01-01T00:00:00Z".to_string()),
        }
    }

    #[test]
    fn test_generate_m3u8_header() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let content = generate_m3u8("Test Playlist", &tracks, &profile_folder).unwrap();

        // Should start with #EXTM3U header
        assert!(content.starts_with("#EXTM3U\n"));
    }

    #[test]
    fn test_generate_m3u8_extinf() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let content = generate_m3u8("Test Playlist", &tracks, &profile_folder).unwrap();

        // Should contain #EXTINF line with duration, artist, and title
        assert!(content.contains("#EXTINF:180,Artist A - Track 1"));
    }

    #[test]
    fn test_generate_m3u8_relative_paths() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let content = generate_m3u8("Test Playlist", &tracks, &profile_folder).unwrap();

        // Paths should be relative (no leading /)
        let lines: Vec<&str> = content.lines().collect();
        for line in &lines {
            if !line.starts_with('#') && !line.is_empty() {
                assert!(!line.starts_with('/'), "Path should be relative: {}", line);
            }
        }

        // Should contain relative path
        assert!(content.contains("Artist A/Album 1/Track 1.m4a"));
    }

    #[test]
    fn test_generate_m3u8_multiple_tracks() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
            create_test_track(2, "Artist B", "Artist B", "Album 2", "Track 2", Some(240)),
            create_test_track(3, "Artist C", "Artist C", "Album 3", "Track 3", Some(200)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let content = generate_m3u8("Multi Track", &tracks, &profile_folder).unwrap();

        // Should contain all three tracks
        assert!(content.contains("Artist A - Track 1"));
        assert!(content.contains("Artist B - Track 2"));
        assert!(content.contains("Artist C - Track 3"));

        // Should contain all three paths
        assert!(content.contains("Artist A/Album 1/Track 1.m4a"));
        assert!(content.contains("Artist B/Album 2/Track 2.m4a"));
        assert!(content.contains("Artist C/Album 3/Track 3.m4a"));
    }

    #[test]
    fn test_sanitize_filenames_in_paths() {
        let tracks = vec![
            create_test_track(
                1,
                "Artist: Name",
                "Artist: Name",
                "Album / Part 2",
                "Song?",
                Some(180),
            ),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let content = generate_m3u8("Sanitized", &tracks, &profile_folder).unwrap();

        // Paths should not contain invalid FAT32 characters
        let lines: Vec<&str> = content.lines().collect();
        for line in &lines {
            if !line.starts_with('#') && !line.is_empty() {
                assert!(!line.contains(':'), "Path should not contain colon: {}", line);
                assert!(!line.contains('?'), "Path should not contain question mark: {}", line);
                // Note: forward slash is the path separator, so we can't check for that
            }
        }
    }

    #[test]
    fn test_generate_m3u8_zero_duration() {
        // Test handling of tracks with no duration
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", None),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let content = generate_m3u8("No Duration", &tracks, &profile_folder).unwrap();

        // Should default to 0 for missing duration
        assert!(content.contains("#EXTINF:0,Artist A - Track 1"));
    }

    #[test]
    fn test_write_playlist_file_creates_file() {
        let temp_dir = TempDir::new().unwrap();
        let playlist_path = temp_dir.path().join("test.m3u8");

        let content = "#EXTM3U\n#EXTINF:180,Artist - Title\nArtist/Album/Title.m4a";
        write_playlist_file(&playlist_path, content).unwrap();

        // File should exist
        assert!(playlist_path.exists());

        // Content should match
        let written_content = fs::read_to_string(&playlist_path).unwrap();
        assert_eq!(written_content, content);
    }

    #[test]
    fn test_write_playlist_file_creates_parent_dirs() {
        let temp_dir = TempDir::new().unwrap();
        let playlist_path = temp_dir.path().join("subdir").join("deep").join("test.m3u8");

        let content = "#EXTM3U\n";
        write_playlist_file(&playlist_path, content).unwrap();

        // File should exist with nested parent dirs created
        assert!(playlist_path.exists());
    }

    #[test]
    fn test_write_profile_playlist() {
        let temp_dir = TempDir::new().unwrap();
        let profile_folder = temp_dir.path();

        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
            create_test_track(2, "Artist B", "Artist B", "Album 2", "Track 2", Some(240)),
        ];

        write_profile_playlist(profile_folder, "Test Playlist", &tracks).unwrap();

        // Playlists directory should be created
        let playlists_dir = profile_folder.join("Playlists");
        assert!(playlists_dir.exists());
        assert!(playlists_dir.is_dir());

        // Playlist file should exist
        let playlist_path = playlists_dir.join("Test Playlist.m3u8");
        assert!(playlist_path.exists());

        // Content should be valid M3U8
        let content = fs::read_to_string(&playlist_path).unwrap();
        assert!(content.starts_with("#EXTM3U"));
        assert!(content.contains("Artist A - Track 1"));
        assert!(content.contains("Artist B - Track 2"));
    }

    #[test]
    fn test_write_profile_playlist_sanitizes_name() {
        let temp_dir = TempDir::new().unwrap();
        let profile_folder = temp_dir.path();

        let tracks = vec![
            create_test_track(1, "CON", "CON", "PRN", "AUX", Some(180)),
        ];

        write_profile_playlist(profile_folder, "Reserved", &tracks).unwrap();

        // Should handle Windows reserved names with underscore prefix
        let content = fs::read_to_string(
            profile_folder.join("Playlists").join("Reserved.m3u8")
        ).unwrap();

        // Paths should be prefixed with underscore for reserved names
        assert!(content.contains("_CON/_PRN/_AUX.m4a"));
    }
}
