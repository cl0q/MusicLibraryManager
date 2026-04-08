//! Playlist file import: parse M3U/M3U8 and Spotify JSON, match to library tracks.

use std::path::Path;
use rusqlite::Connection;
use serde::Serialize;
use strsim::jaro_winkler;

use crate::dedup::normalize::{normalize, normalize_artist};
use crate::database::playlist::add_track_to_playlist;

/// A track parsed from an external playlist file.
#[derive(Debug, Clone)]
pub struct ParsedTrack {
    pub artist: String,
    pub title: String,
    pub duration: Option<i32>,
    pub path: Option<String>,
}

/// Result of matching one ParsedTrack against the library.
#[derive(Debug)]
pub struct MatchResult {
    pub imported_track: ParsedTrack,
    pub matched_track_id: Option<i64>,
    pub confidence: f64,
}

/// Returned from import_playlist_from_file to the Tauri command layer.
#[derive(Debug, Serialize)]
pub struct ImportPlaylistResult {
    pub playlist_id: i64,
    pub playlist_name: String,
    pub total_tracks: i64,
    pub matched_tracks: i64,
    pub unmatched_tracks: i64,
    pub unmatched_details: Vec<String>,
}

// -- Parsers --

/// Parse an M3U or M3U8 file. Extracts (artist, title) from EXTINF tags.
///
/// EXTINF title format: "Artist - Title". If no " - " separator found, artist = "Unknown".
pub fn parse_m3u_file(path: &Path) -> Result<Vec<ParsedTrack>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot read file: {}", e))?;

    let (_, playlist) = m3u8_rs::parse_media_playlist(content.as_bytes())
        .map_err(|_| "Failed to parse M3U/M3U8 file".to_string())?;

    let mut tracks = Vec::new();
    for segment in playlist.segments {
        let title_str = segment.title.as_deref().unwrap_or("").trim();
        if title_str.is_empty() {
            continue;
        }
        let (artist, title) = split_artist_title(title_str);
        tracks.push(ParsedTrack {
            artist: artist.trim().to_string(),
            title: title.trim().to_string(),
            duration: Some(segment.duration as i32),
            path: if segment.uri.is_empty() { None } else { Some(segment.uri) },
        });
    }
    Ok(tracks)
}

/// Parse a Spotify JSON export file.
///
/// Supports two schemas:
///   Schema A: `{"tracks":[{"artists":[{"name":"..."}],"name":"...","duration_ms":N}]}`
///   Schema B: `{"tracks":[{"track":{"artists":[...],"name":"...","duration_ms":N}}]}`
pub fn parse_spotify_json(path: &Path) -> Result<Vec<ParsedTrack>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot read file: {}", e))?;
    parse_spotify_json_str(&content)
}

/// Parse Spotify JSON from a string (testable without filesystem).
pub fn parse_spotify_json_str(content: &str) -> Result<Vec<ParsedTrack>, String> {
    let json: serde_json::Value = serde_json::from_str(content)
        .map_err(|e| format!("Invalid JSON: {}", e))?;

    let tracks_array = json["tracks"]
        .as_array()
        .ok_or_else(|| "JSON missing 'tracks' array".to_string())?;

    let mut parsed = Vec::new();
    for item in tracks_array {
        let track_obj = if item.get("track").is_some() {
            &item["track"]
        } else {
            item
        };

        if !track_obj.is_object() {
            continue;
        }

        // Support multiple schemas:
        //   Real export: { "title": "...", "artist_names": ["..."] }
        //   Spotify API: { "name": "...", "artists": [{"name": "..."}] }
        let artist = if let Some(names) = track_obj["artist_names"].as_array() {
            // Real Spotify export format: artist_names is a string array
            names.first()
                .and_then(|n| n.as_str())
                .unwrap_or("Unknown")
                .to_string()
        } else {
            // Spotify API format: artists is array of {name: string}
            track_obj["artists"]
                .as_array()
                .and_then(|a| a.first())
                .and_then(|a| a["name"].as_str())
                .unwrap_or("Unknown")
                .to_string()
        };

        let title = track_obj["title"]
            .as_str()
            .or_else(|| track_obj["name"].as_str())
            .unwrap_or("Unknown")
            .to_string();

        let duration = track_obj["duration_ms"]
            .as_i64()
            .map(|d| (d / 1000) as i32);

        parsed.push(ParsedTrack { artist, title, duration, path: None });
    }
    Ok(parsed)
}

fn split_artist_title(full_title: &str) -> (&str, &str) {
    if let Some(pos) = full_title.find(" - ") {
        (&full_title[..pos], &full_title[pos + 3..])
    } else {
        ("Unknown", full_title)
    }
}

// -- Matching --

/// Match one (artist, title) against the library.
///
/// Queries ALL tracks (both local and remote) for broadest match coverage.
/// Scoring: title_score * 0.7 + artist_score * 0.3 (jaro_winkler on normalized strings).
/// Threshold: 0.75 -- below this returns None (unmatched).
pub fn find_best_match(
    conn: &Connection,
    artist: &str,
    title: &str,
) -> Result<Option<(i64, f64)>, String> {
    let norm_artist = normalize_artist(artist);
    let norm_title = normalize(title);

    if norm_title.is_empty() {
        return Ok(None);
    }

    let mut stmt = conn
        .prepare(
            "SELECT id, artist, title FROM tracks \
             WHERE artist LIKE ?1 OR title LIKE ?2 \
             LIMIT 50"
        )
        .map_err(|e| e.to_string())?;

    let candidates: Vec<(i64, String, String)> = stmt
        .query_map(
            rusqlite::params![
                format!("%{}%", if norm_artist.len() > 3 { &norm_artist } else { artist }),
                format!("%{}%", if norm_title.len() > 3 { &norm_title } else { title }),
            ],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|e| e.to_string())?
        .collect::<Result<_, _>>()
        .map_err(|e| e.to_string())?;

    let best = candidates
        .into_iter()
        .map(|(id, db_artist, db_title)| {
            let title_score = jaro_winkler(&norm_title, &normalize(&db_title));
            let artist_score = jaro_winkler(&norm_artist, &normalize_artist(&db_artist));
            let score = (title_score * 0.7) + (artist_score * 0.3);
            (id, score)
        })
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok(best.filter(|(_, score)| *score >= 0.75))
}

// -- Import command logic --

/// Parse file, match tracks to library, create playlist, add matched tracks.
///
/// The entire operation is atomic -- if any step fails, the database is unchanged.
pub fn import_playlist_from_file(
    conn: &mut Connection,
    playlist_name: &str,
    file_path: &str,
) -> Result<ImportPlaylistResult, String> {
    let path = Path::new(file_path);

    // Parse by extension
    let parsed_tracks = if file_path.ends_with(".json") {
        parse_spotify_json(path)?
    } else if file_path.ends_with(".m3u8") || file_path.ends_with(".m3u") {
        parse_m3u_file(path)?
    } else {
        return Err("Unsupported file format. Use .m3u, .m3u8, or Spotify .json".to_string());
    };

    let total = parsed_tracks.len() as i64;

    // Match tracks against library (read-only queries, before transaction)
    let mut matches: Vec<(ParsedTrack, Option<i64>, f64)> = Vec::new();
    for track in parsed_tracks {
        let best = find_best_match(conn, &track.artist, &track.title)?;
        let (matched_id, confidence) = match best {
            Some((id, score)) => (Some(id), score),
            None => (None, 0.0),
        };
        matches.push((track, matched_id, confidence));
    }

    // Create playlist + add tracks atomically using rusqlite transaction
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    let description = format!(
        "Imported from {}",
        path.file_name().unwrap_or_default().to_string_lossy()
    );

    tx.execute(
        "INSERT INTO playlists (name, description, category, is_liked, is_smart, is_pinned)
         VALUES (?1, ?2, 'regular', 0, 0, 0)",
        rusqlite::params![playlist_name, description],
    ).map_err(|e| format!("Failed to create playlist: {}", e))?;

    let playlist_id = tx.last_insert_rowid();

    let mut matched_count = 0i64;
    let mut unmatched_details: Vec<String> = Vec::new();

    for (imported_track, matched_id, _confidence) in &matches {
        if let Some(track_id) = matched_id {
            // Use add_track_to_playlist which handles fractional indexing
            add_track_to_playlist(&tx, playlist_id, *track_id)
                .map_err(|e| format!("Failed to add track to playlist: {}", e))?;
            matched_count += 1;
        } else {
            unmatched_details.push(format!("{} - {}", imported_track.artist, imported_track.title));
        }
    }

    tx.commit().map_err(|e| e.to_string())?;

    Ok(ImportPlaylistResult {
        playlist_id,
        playlist_name: playlist_name.to_string(),
        total_tracks: total,
        matched_tracks: matched_count,
        unmatched_tracks: total - matched_count,
        unmatched_details,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn test_parse_m3u_file_returns_tracks() {
        let content = "#EXTM3U\n#EXTINF:180,Daft Punk - Get Lucky\nhttp://example.com/track.mp3\n";
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.m3u");
        std::fs::write(&path, content).unwrap();

        let tracks = parse_m3u_file(&path).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].artist, "Daft Punk");
        assert_eq!(tracks[0].title, "Get Lucky");
        assert_eq!(tracks[0].duration, Some(180));
    }

    #[test]
    fn test_parse_m3u_title_only_no_dash() {
        let content = "#EXTM3U\n#EXTINF:120,Just A Title\ntrack.mp3\n";
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.m3u");
        std::fs::write(&path, content).unwrap();

        let tracks = parse_m3u_file(&path).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].artist, "Unknown");
        assert_eq!(tracks[0].title, "Just A Title");
    }

    #[test]
    fn test_parse_spotify_json_standard_schema() {
        let json = r#"{"tracks":[{"artists":[{"name":"The Beatles"}],"name":"Hey Jude","duration_ms":431000}]}"#;
        let tracks = parse_spotify_json_str(json).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].artist, "The Beatles");
        assert_eq!(tracks[0].title, "Hey Jude");
        assert_eq!(tracks[0].duration, Some(431));
        assert!(tracks[0].path.is_none());
    }

    #[test]
    fn test_parse_spotify_json_nested_track_schema() {
        let json = r#"{"tracks":[{"track":{"artists":[{"name":"Radiohead"}],"name":"Creep","duration_ms":236000}}]}"#;
        let tracks = parse_spotify_json_str(json).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].artist, "Radiohead");
        assert_eq!(tracks[0].title, "Creep");
        assert_eq!(tracks[0].duration, Some(236));
    }

    #[test]
    fn test_parse_spotify_json_missing_tracks_key() {
        let json = r#"{"items":[]}"#;
        let result = parse_spotify_json_str(json);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("JSON missing 'tracks' array"));
    }

    #[test]
    fn test_find_best_match_returns_none_for_empty_library() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE tracks (id INTEGER PRIMARY KEY, artist TEXT NOT NULL, title TEXT NOT NULL)"
        ).unwrap();

        let result = find_best_match(&conn, "Any Artist", "Any Title").unwrap();
        assert!(result.is_none());
    }
}
