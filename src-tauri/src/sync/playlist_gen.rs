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
    library_root: &Path,
    path_prefix: &str,
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

        // Relative path from profile root — mirrors library folder structure
        let original = Path::new(&track.metadata.original_path);
        let relative_path = if let Ok(rel) = original.strip_prefix(library_root) {
            let parent = rel.parent().unwrap_or(Path::new(""));
            let mut parts: Vec<String> = parent
                .components()
                .filter_map(|c| {
                    if let std::path::Component::Normal(p) = c {
                        Some(sanitize_filename(p.to_str().unwrap_or("unknown")))
                    } else {
                        None
                    }
                })
                .collect();
            let stem = rel
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown");
            parts.push(format!("{}.m4a", sanitize_filename(stem)));
            parts.join("/")
        } else if track.metadata.original_path.contains("soundcloud.com") {
            // SoundCloud tracks: 03_Club/SoundCloud/title.m4a
            format!(
                "03_Club/SoundCloud/{}.m4a",
                sanitize_filename(&track.metadata.title)
            )
        } else {
            // Fallback for tracks not under library root
            format!(
                "{}/{}/{}.m4a",
                sanitize_filename(&track.metadata.album_artist),
                sanitize_filename(&track.metadata.album),
                sanitize_filename(&track.metadata.title)
            )
        };
        if path_prefix.is_empty() {
            lines.push(relative_path);
        } else {
            lines.push(format!("{}{}", path_prefix, relative_path));
        }
    }

    // Trailing newline required by M3U8 spec
    Ok(lines.join("\n") + "\n")
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

/// Generate and write playlist to profile root directory.
///
/// # Arguments
/// * `profile_folder` - Root directory of the sync profile
/// * `playlist_name` - Name for the playlist file (without .m3u8 extension)
/// * `tracks` - Tracks to include in the playlist
/// * `library_root` - Library root path for resolving relative track paths
pub fn write_profile_playlist(
    profile_folder: &Path,
    playlist_name: &str,
    tracks: &[Track],
    library_root: &Path,
    path_prefix: &str,
) -> Result<()> {
    let content = generate_m3u8(playlist_name, tracks, profile_folder, library_root, path_prefix)?;
    let playlist_path = profile_folder.join(format!("{}.m3u8", sanitize_filename(playlist_name)));

    write_playlist_file(&playlist_path, &content)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::track::TrackMetadata;
    use tempfile::TempDir;
    use std::fs;
    use std::path::PathBuf;

    const TEST_LIBRARY_ROOT: &str = "/library";

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
            original_path: format!("/library/00_Artist/{}/{}/{}.m4a", album_artist, album, title),
        };

        Track {
            id: Some(id),
            metadata,
            organized_path: Some(format!("{}/{}/{}.m4a", album_artist, album, title)),
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
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Test Playlist", &tracks, &profile_folder, library_root, "").unwrap();

        assert!(content.starts_with("#EXTM3U\n"));
        assert!(content.ends_with('\n'), "M3U8 must end with a trailing newline");
    }

    #[test]
    fn test_generate_m3u8_extinf() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Test Playlist", &tracks, &profile_folder, library_root, "").unwrap();

        assert!(content.contains("#EXTINF:180,Artist A - Track 1"));
    }

    #[test]
    fn test_generate_m3u8_preserves_library_structure() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Test Playlist", &tracks, &profile_folder, library_root, "").unwrap();

        // Should preserve library folder structure (00_Artist/...)
        let lines: Vec<&str> = content.lines().collect();
        for line in &lines {
            if !line.starts_with('#') && !line.is_empty() {
                assert!(!line.starts_with('/'), "Path should be relative: {}", line);
            }
        }

        assert!(content.contains("00_Artist/Artist A/Album 1/Track 1.m4a"));
    }

    #[test]
    fn test_generate_m3u8_multiple_tracks() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
            create_test_track(2, "Artist B", "Artist B", "Album 2", "Track 2", Some(240)),
            create_test_track(3, "Artist C", "Artist C", "Album 3", "Track 3", Some(200)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Multi Track", &tracks, &profile_folder, library_root, "").unwrap();

        assert!(content.contains("Artist A - Track 1"));
        assert!(content.contains("Artist B - Track 2"));
        assert!(content.contains("Artist C - Track 3"));

        assert!(content.contains("00_Artist/Artist A/Album 1/Track 1.m4a"));
        assert!(content.contains("00_Artist/Artist B/Album 2/Track 2.m4a"));
        assert!(content.contains("00_Artist/Artist C/Album 3/Track 3.m4a"));
    }

    #[test]
    fn test_sanitize_filenames_in_paths() {
        let mut track = create_test_track(1, "Artist: Name", "Artist: Name", "Album / Part 2", "Song?", Some(180));
        track.metadata.original_path = "/library/00_Artist/Artist: Name/Album / Part 2/Song?.m4a".to_string();

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Sanitized", &[track], &profile_folder, library_root, "").unwrap();

        let lines: Vec<&str> = content.lines().collect();
        for line in &lines {
            if !line.starts_with('#') && !line.is_empty() {
                assert!(!line.contains(':'), "Path should not contain colon: {}", line);
                assert!(!line.contains('?'), "Path should not contain question mark: {}", line);
            }
        }
    }

    #[test]
    fn test_generate_m3u8_zero_duration() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", None),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("No Duration", &tracks, &profile_folder, library_root, "").unwrap();

        assert!(content.contains("#EXTINF:0,Artist A - Track 1"));
    }

    #[test]
    fn test_generate_m3u8_with_path_prefix() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Prefixed", &tracks, &profile_folder, library_root, "/Music/").unwrap();

        let lines: Vec<&str> = content.lines().collect();
        // Path line should start with the prefix
        let path_line = lines.iter().find(|l| !l.starts_with('#')).unwrap();
        assert!(path_line.starts_with("/Music/"), "Path should start with prefix: {}", path_line);
        assert!(path_line.contains("Track 1.m4a"));
    }

    #[test]
    fn test_generate_m3u8_without_path_prefix() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("No Prefix", &tracks, &profile_folder, library_root, "").unwrap();

        let lines: Vec<&str> = content.lines().collect();
        let path_line = lines.iter().find(|l| !l.starts_with('#')).unwrap();
        // With empty prefix, path should be a plain relative path (no leading slash)
        assert!(!path_line.starts_with('/'), "Path should be relative with no prefix: {}", path_line);
        assert!(path_line.contains("Track 1.m4a"));
    }

    #[test]
    fn test_generate_m3u8_extinf_on_separate_line_from_path() {
        let tracks = vec![
            create_test_track(1, "Artist A", "Artist A", "Album 1", "Track 1", Some(180)),
        ];

        let profile_folder = PathBuf::from("/tmp/profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);
        let content = generate_m3u8("Format Check", &tracks, &profile_folder, library_root, "").unwrap();

        let lines: Vec<&str> = content.lines().collect();
        // Line 0: #EXTM3U, Line 1: #EXTINF:..., Line 2: path
        assert_eq!(lines.len(), 3, "Expected exactly 3 lines: header, extinf, path");
        assert!(lines[1].starts_with("#EXTINF:180,"), "EXTINF line format wrong: {}", lines[1]);
        assert!(!lines[2].starts_with('#'), "Path line should not start with #: {}", lines[2]);
        assert!(lines[2].ends_with(".m4a"), "Path line should end with .m4a: {}", lines[2]);
    }

    #[test]
    fn test_write_playlist_file_creates_file() {
        let temp_dir = TempDir::new().unwrap();
        let playlist_path = temp_dir.path().join("test.m3u8");

        let content = "#EXTM3U\n#EXTINF:180,Artist - Title\nArtist/Album/Title.m4a\n";
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

        let library_root = Path::new(TEST_LIBRARY_ROOT);
        write_profile_playlist(profile_folder, "Test Playlist", &tracks, library_root, "").unwrap();

        // Playlist file should exist at profile root
        let playlist_path = profile_folder.join("Test Playlist.m3u8");
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

        let mut track = create_test_track(1, "CON", "CON", "PRN", "AUX", Some(180));
        track.metadata.original_path = "/library/00_Artist/CON/PRN/AUX.m4a".to_string();

        let library_root = Path::new(TEST_LIBRARY_ROOT);
        write_profile_playlist(profile_folder, "Reserved", &[track], library_root, "").unwrap();

        let content = fs::read_to_string(
            profile_folder.join("Reserved.m3u8")
        ).unwrap();

        // Paths should be prefixed with underscore for reserved names
        assert!(content.contains("_CON/_PRN/_AUX.m4a"));
    }
}
