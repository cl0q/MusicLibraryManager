//! Integration tests for Library/Remote view query filtering.
//!
//! Tests the Phase 9 core invariant:
//! - Library view: tracks WHERE organized_path IS NOT NULL
//! - Remote view: tracks WHERE organized_path IS NULL AND track_sources EXISTS
//!
//! Uses in-memory SQLite with full schema (get_memory_connection).
//! Each test creates a fresh database — no shared state.

mod common;

use music_library_manager::database::get_memory_connection;
use music_library_manager::search::query::{get_library_tracks_only, get_remote_tracks_only};

/// Library view must return only tracks with organized_path set.
#[test]
fn library_shows_only_local_tracks() {
    let (conn, track_id) = common::setup_test_db_with_library_track(
        "Test Song",
        "Test Artist",
        "/library/T/Test Artist/Test Song.m4a",
    );

    let tracks = get_library_tracks_only(&conn).expect("Query should succeed");

    assert_eq!(tracks.len(), 1, "Should return exactly 1 library track");
    assert_eq!(tracks[0].id, Some(track_id));
    assert_eq!(tracks[0].metadata.title, "Test Song");
    assert_eq!(tracks[0].metadata.artist, "Test Artist");
    assert!(tracks[0].organized_path.is_some(), "organized_path must be set for library tracks");
    assert_eq!(
        tracks[0].organized_path.as_deref(),
        Some("/library/T/Test Artist/Test Song.m4a")
    );
}

/// Remote view must return only tracks with organized_path IS NULL + track_sources entry.
#[test]
fn remote_shows_only_undownloaded_tracks() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Remote Song", "Remote Artist");

    let tracks = get_remote_tracks_only(&conn).expect("Query should succeed");

    assert_eq!(tracks.len(), 1, "Should return exactly 1 remote track");
    assert_eq!(tracks[0].id, Some(track_id));
    assert_eq!(tracks[0].metadata.title, "Remote Song");
    assert!(
        tracks[0].organized_path.is_none(),
        "organized_path must be NULL for remote tracks"
    );
}

/// Library view must NOT return remote (undownloaded) tracks.
#[test]
fn library_excludes_remote_tracks() {
    let (conn, _track_id) = common::setup_test_db_with_remote_track("Remote Song", "Remote Artist");

    let library_tracks = get_library_tracks_only(&conn).expect("Query should succeed");

    assert_eq!(
        library_tracks.len(),
        0,
        "Library view must not include remote tracks (organized_path IS NULL)"
    );
}

/// Remote view must NOT return library (downloaded) tracks.
#[test]
fn remote_excludes_library_tracks() {
    let (conn, _track_id) = common::setup_test_db_with_library_track(
        "Local Song",
        "Local Artist",
        "/library/L/Local Artist/Local Song.m4a",
    );

    let remote_tracks = get_remote_tracks_only(&conn).expect("Query should succeed");

    assert_eq!(
        remote_tracks.len(),
        0,
        "Remote view must not include library tracks (organized_path IS NOT NULL)"
    );
}

/// Remote view must NOT return tracks without track_sources entries.
/// This tests the INNER JOIN requirement — orphaned tracks don't appear in Remote.
#[test]
fn remote_excludes_orphaned_tracks_without_sources() {
    let conn = get_memory_connection().expect("DB setup should succeed");

    // Insert a track with organized_path IS NULL but NO track_sources entry
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
         VALUES ('Orphan', 'Orphan', 'Orphan Album', 'Orphan Track', 'stream', 'remote://orphan')",
        [],
    ).expect("Insert should succeed");

    let remote_tracks = get_remote_tracks_only(&conn).expect("Query should succeed");

    assert_eq!(
        remote_tracks.len(),
        0,
        "Tracks without track_sources must not appear in Remote view (INNER JOIN requirement)"
    );
}

/// Mixed database: library and remote tracks are correctly separated.
#[test]
fn mixed_db_separates_library_and_remote() {
    let conn = get_memory_connection().expect("DB setup should succeed");

    // Insert a source for the remote track
    conn.execute(
        "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
        [],
    ).expect("Insert source should succeed");
    let source_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();

    // Insert one library track (organized_path set)
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, bitrate)
         VALUES ('Library Artist', 'Library Artist', 'Album', 'Library Track', 'aac', 'orig://lib', '/library/lib.m4a', 248)",
        [],
    ).expect("Insert library track");
    let _lib_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();

    // Insert one remote track (organized_path NULL) + source association
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, date_added)
         VALUES ('Remote Artist', 'Remote Artist', 'Album', 'Remote Track', 'stream', 'remote://rem', NULL)",
        [],
    ).expect("Insert remote track");
    let remote_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();
    conn.execute(
        "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, 'sc_1', datetime('now'))",
        rusqlite::params![remote_id, source_id],
    ).expect("Insert track_source");

    // Library view: only the local track
    let library = get_library_tracks_only(&conn).expect("Library query");
    assert_eq!(library.len(), 1);
    assert_eq!(library[0].metadata.title, "Library Track");

    // Remote view: only the remote track
    let remote = get_remote_tracks_only(&conn).expect("Remote query");
    assert_eq!(remote.len(), 1);
    assert_eq!(remote[0].metadata.title, "Remote Track");
}
