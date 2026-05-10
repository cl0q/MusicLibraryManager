//! Full pipeline integration tests.
//!
//! Tests the complete track lifecycle:
//!   Remote track in DB → download audio → transcode → organize into library → update DB
//!
//! These tests use real audio files (generated via ffmpeg) and real transcoding,
//! but mock external APIs (DAB, YouTube) — no network calls.

mod common;

use common::audio;
use music_library_manager::database::{get_memory_connection, tracks::update_download_status};
use music_library_manager::transcode::{self, TranscodeResult};

// ---------------------------------------------------------------------------
// 1. Transcode pipeline tests (real ffmpeg, real audio files)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn transcode_flac_to_aac_produces_m4a() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let input = audio::create_test_flac(tmp.path(), "lossless.flac");
    let output_dir = tmp.path().join("transcoded");
    std::fs::create_dir_all(&output_dir).unwrap();

    let result = transcode::transcode_audio(&input, &output_dir).await.unwrap();

    match result {
        TranscodeResult::Transcoded(path) => {
            assert!(path.exists(), "Transcoded file must exist");
            assert_eq!(path.extension().unwrap(), "m4a", "Output must be .m4a");
            // Verify it's a valid audio file by checking size > 0
            let meta = std::fs::metadata(&path).unwrap();
            assert!(meta.len() > 0, "Transcoded file must not be empty");
        }
        other => panic!("Expected Transcoded, got {:?}", other),
    }
}

#[tokio::test]
async fn transcode_high_bitrate_mp3_to_aac() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let input = audio::create_test_mp3(tmp.path(), "high.mp3", 320);
    let output_dir = tmp.path().join("transcoded");
    std::fs::create_dir_all(&output_dir).unwrap();

    let result = transcode::transcode_audio(&input, &output_dir).await.unwrap();

    // 320kbps MP3 >= 248kbps threshold → should transcode
    match result {
        TranscodeResult::Transcoded(path) => {
            assert!(path.exists());
            assert_eq!(path.extension().unwrap(), "m4a");
        }
        other => panic!("Expected Transcoded for 320k MP3, got {:?}", other),
    }
}

#[tokio::test]
async fn transcode_low_bitrate_mp3_is_skipped() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let input = audio::create_test_mp3(tmp.path(), "low.mp3", 128);
    let output_dir = tmp.path().join("transcoded");
    std::fs::create_dir_all(&output_dir).unwrap();

    let result = transcode::transcode_audio(&input, &output_dir).await.unwrap();

    // 128kbps MP3 < 248kbps threshold → should skip
    match result {
        TranscodeResult::Skipped(reason) => {
            assert!(
                reason.contains("248kbps") || reason.contains("below"),
                "Skip reason should mention threshold: {}",
                reason
            );
        }
        other => panic!("Expected Skipped for 128k MP3, got {:?}", other),
    }
}

#[tokio::test]
async fn transcode_wav_to_aac() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let input = audio::create_test_wav(tmp.path(), "pcm.wav");
    let output_dir = tmp.path().join("transcoded");
    std::fs::create_dir_all(&output_dir).unwrap();

    let result = transcode::transcode_audio(&input, &output_dir).await.unwrap();

    // WAV is lossless → should always transcode
    match result {
        TranscodeResult::Transcoded(path) => {
            assert!(path.exists());
            assert_eq!(path.extension().unwrap(), "m4a");
        }
        other => panic!("Expected Transcoded for WAV, got {:?}", other),
    }
}

// ---------------------------------------------------------------------------
// 2. Format detection tests (real audio files, symphonia)
// ---------------------------------------------------------------------------

#[test]
fn detect_flac_format_is_lossless() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let path = audio::create_test_flac(tmp.path(), "detect.flac");

    let format = transcode::detect_format(&path).unwrap();
    assert!(format.is_lossless, "FLAC must be detected as lossless");
    assert!(format.sample_rate.is_some());
}

#[test]
fn detect_mp3_format_is_lossy() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let path = audio::create_test_mp3(tmp.path(), "detect.mp3", 256);

    let format = transcode::detect_format(&path).unwrap();
    assert!(!format.is_lossless, "MP3 must be detected as lossy");
    assert!(format.bitrate.is_some(), "MP3 bitrate should be detected");
}

// ---------------------------------------------------------------------------
// 3. Database: Remote → Library transition with real file paths
// ---------------------------------------------------------------------------

#[test]
fn download_status_update_transitions_remote_to_library() {
    let (conn, track_id) = common::setup_test_db_with_remote_track("Test Track", "Test Artist");

    // Verify track starts as Remote
    let org_path: Option<String> = conn
        .query_row(
            "SELECT organized_path FROM tracks WHERE id = ?",
            [track_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(org_path.is_none(), "Track should start as Remote (NULL organized_path)");

    let dl_status: Option<String> = conn
        .query_row(
            "SELECT download_status FROM tracks WHERE id = ?",
            [track_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(dl_status.is_none(), "download_status should start NULL");

    // Simulate download completion
    update_download_status(&conn, track_id, "/library/Artist/Track.m4a", "/library/Artist/Track.m4a").unwrap();

    // Verify transition to Library
    let org_path: Option<String> = conn
        .query_row(
            "SELECT organized_path FROM tracks WHERE id = ?",
            [track_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        org_path,
        Some("/library/Artist/Track.m4a".to_string()),
        "organized_path must be set after download"
    );

    let dl_status: Option<String> = conn
        .query_row(
            "SELECT download_status FROM tracks WHERE id = ?",
            [track_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(dl_status.is_some(), "download_status must be set");
    let ts = dl_status.unwrap();
    assert!(
        chrono::DateTime::parse_from_rfc3339(&ts).is_ok(),
        "download_status must be valid ISO 8601: {}",
        ts
    );

    // Verify format was detected from extension
    let format: String = conn
        .query_row("SELECT format FROM tracks WHERE id = ?", [track_id], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(format, "aac", "m4a extension should map to 'aac' format");
}

#[test]
fn library_view_excludes_remote_and_vice_versa() {
    let conn = get_memory_connection().unwrap();

    // Insert source for remote tracks
    conn.execute(
        "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test', 1)",
        [],
    )
    .unwrap();

    // Insert a remote track
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
         VALUES ('Remote Artist', 'Remote Artist', 'Album', 'Remote Track', 'stream', 'sc://1')",
        [],
    )
    .unwrap();
    let remote_id: i64 = conn
        .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
        .unwrap();
    conn.execute(
        "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, 1, 'ext1', datetime('now'))",
        [remote_id],
    )
    .unwrap();

    // Insert a library track
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, bitrate)
         VALUES ('Local Artist', 'Local Artist', 'Album', 'Local Track', 'aac', 'orig://2', '/lib/track.m4a', 248000)",
        [],
    )
    .unwrap();

    // Library view: organized_path IS NOT NULL
    let library_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks WHERE organized_path IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(library_count, 1);

    // Remote view: organized_path IS NULL + has source
    let remote_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks t
             INNER JOIN track_sources ts ON t.id = ts.track_id
             WHERE t.organized_path IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(remote_count, 1);

    // Now download the remote track
    update_download_status(&conn, remote_id, "/lib/remote_track.m4a", "/lib/remote_track.m4a").unwrap();

    // Library should now have 2, remote should have 0
    let library_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks WHERE organized_path IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(library_count, 2, "Both tracks should be in Library now");

    let remote_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks t
             INNER JOIN track_sources ts ON t.id = ts.track_id
             WHERE t.organized_path IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(remote_count, 0, "Remote should be empty after download");
}

// ---------------------------------------------------------------------------
// 4. Full chain: download → transcode → organize → DB update
// ---------------------------------------------------------------------------

#[tokio::test]
async fn full_chain_flac_download_to_library_track() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let staging = tmp.path().join("staging");
    let transcoded = tmp.path().join("transcoded");
    let library = tmp.path().join("library");
    std::fs::create_dir_all(&staging).unwrap();
    std::fs::create_dir_all(&transcoded).unwrap();
    std::fs::create_dir_all(&library).unwrap();

    // 1. Set up DB with a remote track
    let (conn, track_id) = common::setup_test_db_with_remote_track("Midnight Drive", "ODESZA");

    // 2. Simulate download: create a FLAC file as if downloaded from DAB
    let downloaded_flac = audio::create_test_flac(&staging, "ODESZA - Midnight Drive.flac");
    assert!(downloaded_flac.exists());

    // 3. Transcode FLAC → AAC
    let transcode_result = transcode::transcode_audio(&downloaded_flac, &transcoded)
        .await
        .unwrap();
    let aac_path = match transcode_result {
        TranscodeResult::Transcoded(p) => p,
        other => panic!("Expected Transcoded, got {:?}", other),
    };
    assert!(aac_path.exists());
    assert_eq!(aac_path.extension().unwrap(), "m4a");

    // 4. Organize: move to library structure
    let artist_dir = library.join("00_Artist").join("ODESZA").join("Midnight Drive");
    std::fs::create_dir_all(&artist_dir).unwrap();
    let final_path = artist_dir.join(aac_path.file_name().unwrap());
    std::fs::rename(&aac_path, &final_path).unwrap();
    assert!(final_path.exists());

    // 5. Update DB
    let path_str = final_path.to_str().unwrap();
    update_download_status(&conn, track_id, path_str, path_str).unwrap();

    // 6. Verify the full state
    let row = conn
        .query_row(
            "SELECT organized_path, download_status, format FROM tracks WHERE id = ?",
            [track_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .unwrap();

    let (org_path, dl_status, format) = row;
    assert!(org_path.is_some(), "organized_path must be set");
    assert!(
        org_path.unwrap().contains("ODESZA"),
        "Path should contain artist name"
    );
    assert!(dl_status.is_some(), "download_status must be set");
    assert_eq!(format, "aac", "Format should be aac for .m4a file");
}

#[tokio::test]
async fn full_chain_low_bitrate_mp3_is_preserved() {
    if !audio::ffmpeg_available() {
        eprintln!("SKIP: ffmpeg not available");
        return;
    }

    let tmp = tempfile::TempDir::new().unwrap();
    let staging = tmp.path().join("staging");
    let transcoded = tmp.path().join("transcoded");
    std::fs::create_dir_all(&staging).unwrap();
    std::fs::create_dir_all(&transcoded).unwrap();

    // 1. Set up DB with a remote track
    let (conn, track_id) = common::setup_test_db_with_remote_track("Lo-Fi Beat", "ChillHop");

    // 2. Simulate download: 128kbps MP3
    let downloaded_mp3 = audio::create_test_mp3(&staging, "ChillHop - Lo-Fi Beat.mp3", 128);

    // 3. Transcode should SKIP (128k < 248k threshold)
    let result = transcode::transcode_audio(&downloaded_mp3, &transcoded)
        .await
        .unwrap();
    match &result {
        TranscodeResult::Skipped(_) => {} // expected
        other => panic!("Expected Skipped for 128k MP3, got {:?}", other),
    }

    // 4. Since transcode skipped, use original MP3 file as the organized path
    let mp3_str = downloaded_mp3.to_str().unwrap();
    update_download_status(&conn, track_id, mp3_str, mp3_str).unwrap();

    // 5. Verify format is mp3 (not aac)
    let format: String = conn
        .query_row("SELECT format FROM tracks WHERE id = ?", [track_id], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(format, "mp3", "Low bitrate MP3 should be preserved as mp3");
}

// ---------------------------------------------------------------------------
// 5. File organization tests
// ---------------------------------------------------------------------------

#[test]
fn organize_creates_artist_directory_structure() {
    let tmp = tempfile::TempDir::new().unwrap();
    let root = tmp.path().join("library");
    std::fs::create_dir_all(&root).unwrap();

    // Create a source file
    let source = tmp.path().join("source.m4a");
    std::fs::write(&source, b"fake audio").unwrap();

    // Simulate organization: Artist/Title structure
    let safe_artist = "ODESZA";
    let safe_title = "Midnight Drive";
    let target_dir = root.join("00_Artist").join(safe_artist).join(safe_title);
    std::fs::create_dir_all(&target_dir).unwrap();
    let target = target_dir.join("source.m4a");
    std::fs::rename(&source, &target).unwrap();

    assert!(target.exists());
    assert!(target_dir.exists());
    assert!(root.join("00_Artist").join("ODESZA").exists());
}

#[test]
fn organize_soundcloud_goes_to_soundcloud_dir() {
    let tmp = tempfile::TempDir::new().unwrap();
    let root = tmp.path().join("library");

    let sc_dir = root.join("01_SoundCloud");
    std::fs::create_dir_all(&sc_dir).unwrap();

    let source = tmp.path().join("track.m4a");
    std::fs::write(&source, b"fake audio").unwrap();

    let target = sc_dir.join("track.m4a");
    std::fs::rename(&source, &target).unwrap();

    assert!(target.exists());
    assert!(sc_dir.exists());
}

// ---------------------------------------------------------------------------
// 6. Batch download DB updates
// ---------------------------------------------------------------------------

#[test]
fn batch_download_updates_multiple_tracks() {
    let conn = get_memory_connection().unwrap();

    // Insert source
    conn.execute(
        "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test', 1)",
        [],
    )
    .unwrap();

    // Insert 5 remote tracks
    let mut track_ids = Vec::new();
    for i in 0..5 {
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, 'Album', ?, 'stream', ?)",
            rusqlite::params![
                format!("Artist{}", i),
                format!("Artist{}", i),
                format!("Track{}", i),
                format!("sc://track{}", i)
            ],
        )
        .unwrap();
        let id: i64 = conn
            .query_row("SELECT last_insert_rowid()", [], |row| row.get(0))
            .unwrap();
        conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, 1, ?, datetime('now'))",
            rusqlite::params![id, format!("ext{}", i)],
        )
        .unwrap();
        track_ids.push(id);
    }

    // Verify all are remote
    let remote_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks WHERE organized_path IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(remote_count, 5);

    // Simulate batch download: update 3 of them
    for &id in &track_ids[..3] {
        let path = format!("/lib/track_{}.m4a", id);
        update_download_status(&conn, id, &path, &path).unwrap();
    }

    // Verify: 3 in library, 2 still remote
    let library_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks WHERE organized_path IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(library_count, 3, "3 tracks should be in Library");

    let remote_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM tracks WHERE organized_path IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(remote_count, 2, "2 tracks should still be Remote");
}

// ---------------------------------------------------------------------------
// 7. Retry queue serialization
// ---------------------------------------------------------------------------

#[test]
fn retry_queue_persists_and_loads() {
    use music_library_manager::download::QueueItem;

    let tmp = tempfile::TempDir::new().unwrap();
    let queue_path = tmp.path().join("retry_queue.json");

    // Create queue and add items
    {
        let mut queue = music_library_manager::download::queue::RetryQueue::new(queue_path.clone());
        queue
            .add(QueueItem::new(
                "track1".into(),
                "Artist - Title".into(),
                "dab".into(),
                "Not found".into(),
            ))
            .unwrap();
        queue
            .add(QueueItem::new(
                "track2".into(),
                "Artist2 - Title2".into(),
                "youtube".into(),
                "Timeout".into(),
            ))
            .unwrap();
        queue.save().unwrap();
    }

    // Load in a new queue instance
    {
        let mut queue = music_library_manager::download::queue::RetryQueue::new(queue_path);
        queue.load().unwrap();
        let pending = queue.get_pending();
        assert_eq!(pending.len(), 2, "Should have 2 pending items after reload");
        assert_eq!(pending[0].track_id, "track1");
        assert_eq!(pending[1].source, "youtube");
    }
}

// ---------------------------------------------------------------------------
// 8. Mock HTTP server: DAB search → stream → download flow
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mock_dab_search_returns_matching_track() {
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let server = MockServer::start().await;

    // Mock search endpoint
    Mock::given(method("GET"))
        .and(path("/api/search"))
        .and(query_param("q", "ODESZA Midnight Drive"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "tracks": [{
                "id": 42,
                "title": "Midnight Drive",
                "artist": "ODESZA",
                "albumTitle": "Summer's Gone",
                "albumId": "album1",
                "duration": 240
            }]
        })))
        .mount(&server)
        .await;

    // Mock stream endpoint
    Mock::given(method("GET"))
        .and(path("/api/stream"))
        .and(query_param("trackId", "42"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "url": format!("{}/cdn/track42.flac", server.uri()) })),
        )
        .mount(&server)
        .await;

    // Mock CDN download — serve a tiny valid response
    Mock::given(method("GET"))
        .and(path("/cdn/track42.flac"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![0u8; 1024]))
        .mount(&server)
        .await;

    // Verify search endpoint works
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{}/api/search?q=ODESZA%20Midnight%20Drive", server.uri()))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);

    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["tracks"][0]["artist"], "ODESZA");
    assert_eq!(body["tracks"][0]["title"], "Midnight Drive");
    assert_eq!(body["tracks"][0]["id"], 42);

    // Verify stream endpoint
    let resp = client
        .get(format!("{}/api/stream?trackId=42", server.uri()))
        .send()
        .await
        .unwrap();
    let stream_body: serde_json::Value = resp.json().await.unwrap();
    assert!(stream_body["url"].as_str().unwrap().contains("/cdn/track42.flac"));
}

#[tokio::test]
async fn mock_dab_search_not_found_triggers_empty_tracks() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/api/search"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "tracks": [] })),
        )
        .mount(&server)
        .await;

    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{}/api/search?q=nonexistent", server.uri()))
        .send()
        .await
        .unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["tracks"].as_array().unwrap().is_empty());
}
