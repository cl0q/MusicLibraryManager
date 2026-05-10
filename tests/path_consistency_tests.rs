//! Integration tests for organized_path consistency invariant.
//!
//! Verifies that organized_path is always stored as a relative path (relative to library root),
//! never as an absolute path. This is the Phase 8-01 architectural invariant.
//!
//! These tests cover:
//! 1. validate_organized_path contract (relative ok, absolute rejected)
//! 2. generate_organized_path always produces relative paths
//! 3. Path round-trip: root + organized_path = correct absolute path
//! 4. update_download_status rejects absolute organized_path
//! 5. strip_prefix produces a relative path without leading slash

mod common;

use music_library_manager::database::get_memory_connection;
use music_library_manager::database::tracks::{update_download_status, validate_organized_path};
use music_library_manager::metadata::sanitize::generate_organized_path;
use music_library_manager::models::track::TrackMetadata;
use std::path::{Path, PathBuf};

// ── Helpers ────────────────────────────────────────────────────────────────

fn make_metadata(
    artist: &str,
    album_artist: &str,
    album: &str,
    title: &str,
    format: &str,
) -> TrackMetadata {
    TrackMetadata {
        artist: artist.to_string(),
        album_artist: album_artist.to_string(),
        album: album.to_string(),
        title: title.to_string(),
        genre: None,
        year: None,
        bitrate: None,
        duration: None,
        format: format.to_string(),
        original_path: "/test/original".to_string(),
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// validate_organized_path accepts relative paths and rejects absolute paths.
#[test]
fn test_validate_organized_path_contract() {
    // Relative path — must be Ok
    assert!(
        validate_organized_path("Artist/Album/track.m4a").is_ok(),
        "Relative path should be accepted"
    );

    // Nested relative path with sub-folder prefix
    assert!(
        validate_organized_path("00_Artists/Some Artist/Best Album/song.flac").is_ok(),
        "Nested relative path should be accepted"
    );

    // Unix absolute path — must be Err
    let err = validate_organized_path("/Volumes/Lexxar/Music/Artist/track.m4a");
    assert!(err.is_err(), "Unix absolute path must be rejected");
    assert!(
        err.unwrap_err().contains("must be relative"),
        "Error must mention 'must be relative'"
    );

    // Windows drive-letter path — must be Err
    let err = validate_organized_path("C:\\Music\\track.m4a");
    assert!(err.is_err(), "Windows absolute path must be rejected");
    assert!(
        err.unwrap_err().contains("must be relative"),
        "Error must mention 'must be relative'"
    );

    // Path traversal — must be Err
    let err = validate_organized_path("../escape/track.m4a");
    assert!(err.is_err(), "Path traversal must be rejected");
}

/// generate_organized_path never produces an absolute path for any metadata.
///
/// Verifies for 5+ different metadata combinations: normal, special chars,
/// empty fields, Unicode, and SoundCloud-style.
#[test]
fn test_generate_organized_path_always_relative() {
    let cases: Vec<(&str, &str, &str, &str, &str)> = vec![
        // (artist, album_artist, album, title, format)
        ("the beatles", "the beatles", "abbey road", "come together", "mp3"),
        ("artist/with/slashes", "artist/with/slashes", "Album: Colon", "title:colon", "m4a"),
        ("", "unknown artist", "unknown album", "untitled", "flac"),
        ("Sigur Rós", "Sigur Rós", "Ágætis byrjun", "Svefn-g-englar", "flac"),
        ("deadmau5", "deadmau5", "4×4=12", "Some Cheeky Track", "aac"),
    ];

    for (artist, album_artist, album, title, format) in cases {
        let metadata = make_metadata(artist, album_artist, album, title, format);
        let path = generate_organized_path(&metadata);
        assert!(
            !path.starts_with('/'),
            "generate_organized_path must never return a path starting with '/'. Got: {}",
            path
        );
        assert!(
            !path.contains(".."),
            "generate_organized_path must never produce path traversal. Got: {}",
            path
        );
        // Also verify validate_organized_path accepts it
        assert!(
            validate_organized_path(&path).is_ok(),
            "Generated path '{}' must pass validate_organized_path",
            path
        );
    }
}

/// Joining library root + "/" + organized_path produces the correct absolute path.
///
/// This is the core round-trip: the absolute file location is always
/// root_path.join(organized_path).
#[test]
fn test_path_roundtrip() {
    let root = PathBuf::from("/Volumes/Lexxar/Music");
    let organized = "00_Artists/Some Artist/track.m4a";

    let absolute = root.join(organized);
    let expected = PathBuf::from("/Volumes/Lexxar/Music/00_Artists/Some Artist/track.m4a");

    assert_eq!(
        absolute, expected,
        "root.join(organized_path) must produce the correct absolute path"
    );
    assert!(
        absolute.to_string_lossy().starts_with('/'),
        "Resulting absolute path must start with '/'"
    );
    assert!(
        !organized.starts_with('/'),
        "organized_path used in join must not start with '/'"
    );
}

/// update_download_status rejects an absolute organized_path.
///
/// This is the write-boundary guard from Plan 01.
#[test]
fn test_update_download_status_rejects_absolute() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Guard Test Track", "Guard Artist");

    // Attempt to mark the track downloaded with an absolute organized_path
    let result = update_download_status(
        &conn,
        track_id,
        "/Volumes/Lexxar/Music/Guard Artist/Guard Test Track.m4a", // absolute — must be rejected
        "/Volumes/Lexxar/Music/Guard Artist/Guard Test Track.m4a",
    );

    assert!(
        result.is_err(),
        "update_download_status must return Err when organized_path is absolute"
    );

    // The track must still have organized_path = NULL (no partial write)
    let organized_path: Option<String> = conn
        .query_row(
            "SELECT organized_path FROM tracks WHERE id = ?",
            rusqlite::params![track_id],
            |row| row.get(0),
        )
        .expect("Query should succeed");

    assert!(
        organized_path.is_none(),
        "organized_path must remain NULL after a rejected update"
    );
}

/// strip_prefix produces a relative path without a leading slash.
///
/// Verifies that PathBuf::strip_prefix correctly removes the root prefix,
/// producing a path component without a leading '/'.
#[test]
fn test_strip_prefix_produces_relative() {
    let absolute = PathBuf::from("/Volumes/Lexxar/Music/Artist/track.m4a");
    let root = Path::new("/Volumes/Lexxar/Music");

    let relative = absolute
        .strip_prefix(root)
        .expect("strip_prefix should succeed when path is inside root");

    let relative_str = relative.to_string_lossy();
    assert!(
        !relative_str.starts_with('/'),
        "strip_prefix result must not have a leading '/'. Got: {}",
        relative_str
    );
    assert_eq!(
        relative_str, "Artist/track.m4a",
        "strip_prefix must produce exactly 'Artist/track.m4a'"
    );
}
