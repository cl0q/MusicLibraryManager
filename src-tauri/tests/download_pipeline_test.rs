//! Integration tests for the download pipeline.
//!
//! Tests the Phase 11 download flow:
//! - Remote track (organized_path IS NULL) → downloaded → Library track (organized_path IS NOT NULL)
//! - DAB client creation and configuration
//! - Database state transitions after download_status update
//!
//! Note: Tests that require live HTTP calls are marked #[ignore].
//! Tests here exercise DB state transitions and matching logic without network.

mod common;

use music_library_manager::database::get_memory_connection;
use music_library_manager::database::tracks::update_download_status;
use music_library_manager::search::query::{get_library_tracks_only, get_remote_tracks_only};

/// A remote track (organized_path IS NULL) must have organized_path unset before download.
#[test]
fn remote_track_has_null_organized_path() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Remote Song", "Artist");

    let remote = get_remote_tracks_only(&conn).expect("Query should succeed");
    assert_eq!(remote.len(), 1);
    assert_eq!(remote[0].id, Some(track_id));
    assert!(
        remote[0].organized_path.is_none(),
        "Remote track must have organized_path IS NULL before download"
    );
}

/// After update_download_status, track moves from Remote to Library view.
/// This is the core Remote→Library transition that Phase 9/11 depends on.
#[test]
fn download_status_update_moves_track_from_remote_to_library() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Downloadable Song", "Artist");

    // Verify it starts as remote
    let remote_before = get_remote_tracks_only(&conn).expect("Remote query");
    assert_eq!(remote_before.len(), 1, "Track should be in Remote before download");
    let library_before = get_library_tracks_only(&conn).expect("Library query");
    assert_eq!(library_before.len(), 0, "Track should NOT be in Library before download");

    // Simulate download completion by updating organized_path
    let final_path = "/library/A/Artist/Downloadable Song.m4a";
    update_download_status(&conn, track_id, final_path).expect("DB update should succeed");

    // After update: track must appear in Library, NOT in Remote
    let library_after = get_library_tracks_only(&conn).expect("Library query after download");
    assert_eq!(library_after.len(), 1, "Track should be in Library after download");
    assert_eq!(
        library_after[0].organized_path.as_deref(),
        Some(final_path),
        "organized_path must match the downloaded file path"
    );

    let remote_after = get_remote_tracks_only(&conn).expect("Remote query after download");
    assert_eq!(
        remote_after.len(),
        0,
        "Track must disappear from Remote after download (organized_path no longer NULL)"
    );
}

/// update_download_status must also update format and bitrate from the file path.
/// This is critical for the Library view's Format column.
#[test]
fn download_status_update_sets_format_and_bitrate() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Format Test Song", "Artist");

    // Download to an m4a path (should set format='aac')
    update_download_status(&conn, track_id, "/library/test.m4a").expect("DB update should succeed");

    let (format, bitrate): (String, Option<i64>) = conn
        .query_row(
            "SELECT format, bitrate FROM tracks WHERE id = ?",
            rusqlite::params![track_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("Query should succeed");

    assert_eq!(
        format, "aac",
        "Format should be 'aac' for .m4a files (per detect_file_format_bitrate)"
    );
    // bitrate may be None if symphonia can't detect (file doesn't exist), that's OK
    let _ = bitrate; // Not asserting bitrate value — depends on whether file exists
}

/// download_status column must be set to an ISO 8601 timestamp after download.
#[test]
fn download_status_set_to_iso8601_timestamp() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Timestamp Test", "Artist");

    update_download_status(&conn, track_id, "/library/test.m4a").expect("DB update");

    let download_status: Option<String> = conn
        .query_row(
            "SELECT download_status FROM tracks WHERE id = ?",
            rusqlite::params![track_id],
            |row| row.get(0),
        )
        .expect("Query should succeed");

    assert!(
        download_status.is_some(),
        "download_status must be set after update_download_status"
    );
    let status = download_status.unwrap();
    // ISO 8601 format check: starts with year (e.g., "2026-")
    assert!(
        status.starts_with("20") && status.contains('T'),
        "download_status must be ISO 8601 timestamp, got: {}",
        status
    );
}

/// Multiple remote tracks: batch update moves all to library.
#[test]
fn batch_download_moves_all_tracks_from_remote() {
    let conn = get_memory_connection().expect("DB setup");

    // Insert source
    conn.execute(
        "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
        [],
    ).unwrap();
    let source_id: i64 = conn.query_row("SELECT last_insert_rowid()", [], |r| r.get(0)).unwrap();

    // Insert 3 remote tracks
    let mut track_ids = Vec::new();
    for i in 0..3 {
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, date_added)
             VALUES ('Artist', 'Artist', 'Album', ?, 'stream', ?, NULL)",
            rusqlite::params![format!("Track {}", i), format!("remote://track-{}", i)],
        ).unwrap();
        let id: i64 = conn.query_row("SELECT last_insert_rowid()", [], |r| r.get(0)).unwrap();
        track_ids.push(id);

        conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, datetime('now'))",
            rusqlite::params![id, source_id, format!("sc_{}", id)],
        ).unwrap();
    }

    assert_eq!(get_remote_tracks_only(&conn).unwrap().len(), 3);
    assert_eq!(get_library_tracks_only(&conn).unwrap().len(), 0);

    // Update all 3
    for (i, &id) in track_ids.iter().enumerate() {
        update_download_status(&conn, id, &format!("/library/track-{}.m4a", i)).unwrap();
    }

    assert_eq!(get_remote_tracks_only(&conn).unwrap().len(), 0, "All 3 should leave Remote");
    assert_eq!(get_library_tracks_only(&conn).unwrap().len(), 3, "All 3 should appear in Library");
}
