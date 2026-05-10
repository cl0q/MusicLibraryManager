//! Integration tests for the playlist import pipeline.
//!
//! Tests the full flow: parse file → match against DB → create playlist → verify contents.
//! Uses in-memory SQLite with seeded tracks — no library mount required.

mod common;

use music_library_manager::database::get_memory_connection;
use music_library_manager::import::playlist_importer::{
    find_best_match, import_playlist_from_file, parse_m3u_file, parse_spotify_json,
    parse_spotify_json_str,
};

fn fixture_path(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/common/fixtures/playlists")
        .join(name)
}

/// Seed an in-memory DB with test tracks that match our fixtures.
fn seed_test_library() -> rusqlite::Connection {
    let conn = get_memory_connection().unwrap();

    let tracks = vec![
        ("Daft Punk", "Get Lucky", Some("00_Artists/Daft Punk/Get Lucky.m4a")),
        ("The Beatles", "Hey Jude", Some("00_Artists/The Beatles/Hey Jude.m4a")),
        ("Pink Floyd", "Comfortably Numb", Some("00_Artists/Pink Floyd/Comfortably Numb.m4a")),
        ("Radiohead", "Creep", None), // remote track (no organized_path)
    ];

    for (artist, title, organized_path) in tracks {
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?1, ?1, 'Test Album', ?2, 'aac', ?3, ?4)",
            rusqlite::params![
                artist,
                title,
                format!("original://{}-{}", artist, title),
                organized_path,
            ],
        )
        .unwrap();
    }

    conn
}

// -- M3U Parsing Tests --

#[test]
fn m3u_parse_known_tracks_fixture() {
    let tracks = parse_m3u_file(&fixture_path("test_known_tracks.m3u")).unwrap();
    assert_eq!(tracks.len(), 3);

    assert_eq!(tracks[0].artist, "Daft Punk");
    assert_eq!(tracks[0].title, "Get Lucky");
    assert_eq!(tracks[0].duration, Some(180));

    assert_eq!(tracks[1].artist, "The Beatles");
    assert_eq!(tracks[1].title, "Hey Jude");

    assert_eq!(tracks[2].artist, "Pink Floyd");
    assert_eq!(tracks[2].title, "Comfortably Numb");
}

#[test]
fn m3u_parse_no_dash_uses_unknown_artist() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("nodash.m3u");
    std::fs::write(&path, "#EXTM3U\n#EXTINF:120,Just A Title\ntrack.mp3\n").unwrap();

    let tracks = parse_m3u_file(&path).unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].artist, "Unknown");
    assert_eq!(tracks[0].title, "Just A Title");
}

#[test]
fn m3u_parse_empty_extinf_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("empty.m3u");
    std::fs::write(&path, "#EXTM3U\n#EXTINF:0,\ntrack.mp3\n#EXTINF:180,Real - Track\nreal.mp3\n").unwrap();

    let tracks = parse_m3u_file(&path).unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].title, "Track");
}

// -- Spotify JSON Parsing Tests --

#[test]
fn spotify_parse_real_export_format() {
    // Tests the real Spotify export format with title + artist_names
    let tracks = parse_spotify_json(&fixture_path("test_spotify_export.json")).unwrap();
    assert_eq!(tracks.len(), 3);

    assert_eq!(tracks[0].artist, "Daft Punk");
    assert_eq!(tracks[0].title, "Get Lucky");
    assert_eq!(tracks[0].duration, Some(180));

    assert_eq!(tracks[1].artist, "The Beatles");
    assert_eq!(tracks[1].title, "Hey Jude");
    assert_eq!(tracks[1].duration, Some(431));

    assert_eq!(tracks[2].artist, "Nobody Real");
    assert_eq!(tracks[2].title, "Totally Unknown Track");
}

#[test]
fn spotify_parse_api_format_with_nested_track() {
    // Tests Spotify API format (artists: [{name}]) and nested track schema
    let tracks = parse_spotify_json(&fixture_path("test_spotify_api.json")).unwrap();
    assert_eq!(tracks.len(), 2);

    // Direct format
    assert_eq!(tracks[0].artist, "Daft Punk");
    assert_eq!(tracks[0].title, "Get Lucky");

    // Nested track format
    assert_eq!(tracks[1].artist, "The Beatles");
    assert_eq!(tracks[1].title, "Hey Jude");
}

#[test]
fn spotify_parse_missing_tracks_key_errors() {
    let result = parse_spotify_json_str(r#"{"items":[]}"#);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("JSON missing 'tracks' array"));
}

#[test]
fn spotify_parse_invalid_json_errors() {
    let result = parse_spotify_json_str("not json at all");
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("Invalid JSON"));
}

#[test]
fn spotify_parse_with_real_playlist_file() {
    // Test against the actual Spotify export from streaming2ipod (if available)
    let real_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("streaming2ipod/tools/get_spotify_playlists/playlist_21A5m2e7cYy74RwgDAbtWM.json");

    if real_path.exists() {
        let tracks = parse_spotify_json(&real_path).unwrap();
        assert!(!tracks.is_empty(), "Real Spotify export should have tracks");
        // First track from STEREOHYPE SOUNDS
        assert_eq!(tracks[0].artist, "James Hype");
        assert_eq!(tracks[0].title, "Waterfalls (feat. Sam Harper & Bobby Harvey)");
    }
}

// -- Fuzzy Matching Tests --

#[test]
fn match_exact_title_and_artist() {
    let conn = seed_test_library();
    let result = find_best_match(&conn, "Daft Punk", "Get Lucky").unwrap();
    assert!(result.is_some(), "Exact match should succeed");
    let (_, score) = result.unwrap();
    assert!(score >= 0.75, "Score {} should be >= 0.75", score);
}

#[test]
fn match_case_insensitive() {
    let conn = seed_test_library();
    let result = find_best_match(&conn, "daft punk", "get lucky").unwrap();
    assert!(result.is_some(), "Case-insensitive match should succeed");
}

#[test]
fn match_remote_tracks_included() {
    let conn = seed_test_library();
    // Radiohead - Creep is a remote track (no organized_path)
    let result = find_best_match(&conn, "Radiohead", "Creep").unwrap();
    assert!(result.is_some(), "Remote tracks should be matchable");
}

#[test]
fn match_no_match_below_threshold() {
    let conn = seed_test_library();
    let result = find_best_match(&conn, "Completely Different", "Nothing Similar").unwrap();
    assert!(result.is_none(), "Unrelated tracks should not match");
}

#[test]
fn match_empty_library_returns_none() {
    let conn = get_memory_connection().unwrap();
    let result = find_best_match(&conn, "Any", "Track").unwrap();
    assert!(result.is_none());
}

// -- Full Import Pipeline Tests --

#[test]
fn import_m3u_creates_playlist_with_matched_tracks() {
    let mut conn = seed_test_library();
    let fixture = fixture_path("test_known_tracks.m3u");

    let result = import_playlist_from_file(
        &mut conn,
        "Test M3U Import",
        fixture.to_str().unwrap(),
    )
    .unwrap();

    assert_eq!(result.playlist_name, "Test M3U Import");
    assert_eq!(result.total_tracks, 3);
    assert_eq!(result.matched_tracks, 3, "All 3 tracks exist in seeded DB");
    assert_eq!(result.unmatched_tracks, 0);
    assert!(result.unmatched_details.is_empty());

    // Verify playlist exists in DB
    let name: String = conn
        .query_row(
            "SELECT name FROM playlists WHERE id = ?1",
            [result.playlist_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(name, "Test M3U Import");

    // Verify tracks were added to playlist
    let track_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?1",
            [result.playlist_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(track_count, 3);
}

#[test]
fn import_m3u_no_matches_creates_empty_playlist() {
    let mut conn = seed_test_library();
    let fixture = fixture_path("test_no_matches.m3u");

    let result = import_playlist_from_file(
        &mut conn,
        "No Matches Playlist",
        fixture.to_str().unwrap(),
    )
    .unwrap();

    assert_eq!(result.total_tracks, 2);
    assert_eq!(result.matched_tracks, 0);
    assert_eq!(result.unmatched_tracks, 2);
    assert_eq!(result.unmatched_details.len(), 2);
    assert!(result.unmatched_details[0].contains("Nonexistent Artist"));

    // Playlist created but empty
    let track_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?1",
            [result.playlist_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(track_count, 0);
}

#[test]
fn import_spotify_json_creates_playlist_with_partial_matches() {
    let mut conn = seed_test_library();
    let fixture = fixture_path("test_spotify_export.json");

    let result = import_playlist_from_file(
        &mut conn,
        "Spotify Import Test",
        fixture.to_str().unwrap(),
    )
    .unwrap();

    assert_eq!(result.total_tracks, 3);
    assert_eq!(result.matched_tracks, 2, "Daft Punk + Beatles should match");
    assert_eq!(result.unmatched_tracks, 1, "Nobody Real should not match");
    assert_eq!(result.unmatched_details.len(), 1);
    assert!(result.unmatched_details[0].contains("Nobody Real"));
}

#[test]
fn import_unsupported_format_errors() {
    let mut conn = seed_test_library();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("test.txt");
    std::fs::write(&path, "not a playlist").unwrap();

    let result = import_playlist_from_file(&mut conn, "Bad", path.to_str().unwrap());
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("Unsupported file format"));
}

#[test]
fn import_nonexistent_file_errors() {
    let mut conn = seed_test_library();
    let result = import_playlist_from_file(&mut conn, "Ghost", "/tmp/does_not_exist.m3u");
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("Cannot read file"));
}

#[test]
fn import_transaction_atomicity_playlist_exists_after_success() {
    let mut conn = seed_test_library();
    let fixture = fixture_path("test_known_tracks.m3u");

    let result = import_playlist_from_file(
        &mut conn,
        "Atomic Test",
        fixture.to_str().unwrap(),
    )
    .unwrap();

    // Both playlist and tracks should exist
    let playlist_exists: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM playlists WHERE id = ?1",
            [result.playlist_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(playlist_exists);

    let tracks_exist: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM playlist_tracks WHERE playlist_id = ?1",
            [result.playlist_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(tracks_exist);
}

#[test]
fn import_multiple_playlists_no_conflict() {
    let mut conn = seed_test_library();
    let fixture = fixture_path("test_known_tracks.m3u");

    let r1 = import_playlist_from_file(&mut conn, "First", fixture.to_str().unwrap()).unwrap();
    let r2 = import_playlist_from_file(&mut conn, "Second", fixture.to_str().unwrap()).unwrap();

    assert_ne!(r1.playlist_id, r2.playlist_id);

    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM playlists", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 2);
}
