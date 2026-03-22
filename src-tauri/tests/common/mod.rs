// Shared test utilities for integration tests.
// Import with: mod common; or use common::{setup_test_temp_dir, ...};
use music_library_manager::database::get_memory_connection;

/// Creates an isolated temporary directory for test files.
/// Returns (TempDir handle, PathBuf to root).
/// IMPORTANT: Keep TempDir in scope for test duration — dropping it deletes the directory.
pub fn setup_test_temp_dir() -> (tempfile::TempDir, std::path::PathBuf) {
    let temp_dir = tempfile::TempDir::new().unwrap();
    let path = temp_dir.path().to_path_buf();
    (temp_dir, path)
}

/// Creates in-memory DB with one remote track and a source association.
/// Returns (Connection, track_id).
pub fn setup_test_db_with_remote_track(title: &str, artist: &str) -> (rusqlite::Connection, i64) {
    let conn = get_memory_connection().unwrap();

    // Insert a source (soundcloud, required for track_sources FK)
    conn.execute(
        "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
        [],
    )
    .unwrap();
    let source_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();

    // Insert remote track (organized_path IS NULL = remote, format 'stream')
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, date_added)
         VALUES (?, ?, 'Test Album', ?, 'stream', ?, NULL)",
        rusqlite::params![artist, artist, title, format!("remote://{}-{}", artist, title)],
    )
    .unwrap();
    let track_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();

    // Insert track_source so INNER JOIN in get_remote_tracks_only returns this track
    conn.execute(
        "INSERT INTO track_sources (track_id, source_id, external_id, added_at)
         VALUES (?, ?, ?, datetime('now'))",
        rusqlite::params![track_id, source_id, format!("sc_{}", track_id)],
    )
    .unwrap();

    (conn, track_id)
}

/// Creates in-memory DB with one local library track.
/// Returns (Connection, track_id).
pub fn setup_test_db_with_library_track(
    title: &str,
    artist: &str,
    organized_path: &str,
) -> (rusqlite::Connection, i64) {
    let conn = get_memory_connection().unwrap();

    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, bitrate)
         VALUES (?, ?, 'Test Album', ?, 'aac', ?, ?, 248)",
        rusqlite::params![
            artist,
            artist,
            title,
            format!("original://{}-{}", artist, title),
            organized_path
        ],
    )
    .unwrap();
    let track_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();

    (conn, track_id)
}

/// Loads a JSON fixture file from tests/common/fixtures/{name}.json.
/// Path is relative to the crate root (src-tauri/).
/// Panics if file not found or invalid JSON — fail fast in tests.
pub fn load_fixture(relative_path: &str) -> serde_json::Value {
    let fixture_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/common/fixtures")
        .join(relative_path);
    let json_str = std::fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("Fixture not found at {}: {}", fixture_path.display(), e));
    serde_json::from_str(&json_str)
        .unwrap_or_else(|e| panic!("Invalid JSON in fixture {}: {}", fixture_path.display(), e))
}
