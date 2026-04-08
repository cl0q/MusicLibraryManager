//! Tauri command handlers for OAuth authorization and sync operations.
//!
//! Exposes Spotify and SoundCloud integration to the frontend via Tauri commands:
//! - OAuth authorization URL generation with PKCE
//! - Authorization code exchange for tokens
//! - Incremental sync of liked songs/tracks
//! - Fuzzy duplicate detection across sources
//!
//! # Frontend Usage (TypeScript)
//! ```typescript
//! import { invoke } from "@tauri-apps/api/tauri";
//!
//! // 1. Get auth URL and open in browser
//! const url = await invoke<string>("spotify_auth_url");
//! window.open(url);
//!
//! // 2. After user authorizes, exchange code
//! await invoke("spotify_exchange_code", { code: "...", userId: "user1" });
//!
//! // 3. Sync liked songs
//! const count = await invoke<number>("sync_spotify", { userId: "user1" });
//! ```

use std::path::PathBuf;
use std::sync::Mutex;

use oauth2::{CsrfToken, PkceCodeVerifier};
use serde::Serialize;
use tauri::State;

use crate::database::get_connection;
use crate::dedup::matcher::{calculate_similarity, is_variant};
use crate::sources::soundcloud::SoundCloudClient;
use crate::sources::spotify::{SpotifyAuth, SpotifyClient};

/// Temporary storage for OAuth PKCE verifiers during authorization flow.
///
/// PKCE verifiers must be stored between the authorization URL generation
/// and the code exchange step. This state is managed by Tauri and shared
/// across command invocations.
pub struct OAuthState {
    pub spotify_verifier: Mutex<Option<(PkceCodeVerifier, CsrfToken)>>,
    pub soundcloud_verifier: Mutex<Option<(PkceCodeVerifier, CsrfToken)>>,
}

impl Default for OAuthState {
    fn default() -> Self {
        Self {
            spotify_verifier: Mutex::new(None),
            soundcloud_verifier: Mutex::new(None),
        }
    }
}

/// Response from sync operations.
#[derive(Debug, Serialize)]
pub struct SyncResponse {
    /// Number of new tracks added during sync.
    pub added: usize,
    /// Source that was synced.
    pub source: String,
}

/// A potential duplicate match.
#[derive(Debug, Serialize)]
pub struct DuplicateMatch {
    /// Database track ID of the potential duplicate.
    pub track_id: i64,
    /// Title of the matched track.
    pub title: String,
    /// Artist of the matched track.
    pub artist: String,
    /// Similarity score (0.0-1.0).
    pub similarity: f64,
    /// Whether this is a variant (remix, edit, live, etc.)
    pub is_variant: bool,
}

// ============================================================================
// Spotify Commands
// ============================================================================

/// Generate a Spotify OAuth authorization URL with PKCE.
///
/// Returns the URL to open in a browser. The PKCE verifier is stored
/// internally for the subsequent code exchange step.
///
/// # Returns
/// * `Ok(String)` - Authorization URL to open in browser
/// * `Err(String)` - If environment variables are missing
#[tauri::command]
pub fn spotify_auth_url(oauth_state: State<OAuthState>) -> Result<String, String> {
    let (url, csrf_token, pkce_verifier) =
        SpotifyAuth::authorization_url().map_err(|e| format!("Failed to generate auth URL: {}", e))?;

    // Store verifier for code exchange
    let mut verifier = oauth_state
        .spotify_verifier
        .lock()
        .map_err(|e| format!("Failed to lock OAuth state: {}", e))?;
    *verifier = Some((pkce_verifier, csrf_token));

    Ok(url)
}

/// Exchange a Spotify authorization code for tokens.
///
/// Completes the OAuth flow by exchanging the authorization code for
/// access and refresh tokens. The refresh token is stored in the system keychain.
///
/// # Arguments
/// * `code` - Authorization code from the OAuth redirect
/// * `user_id` - User identifier for token storage
///
/// # Returns
/// * `Ok(())` - Tokens exchanged and stored successfully
/// * `Err(String)` - If exchange fails or no PKCE verifier found
#[tauri::command]
pub async fn spotify_exchange_code(
    code: String,
    user_id: String,
    oauth_state: State<'_, OAuthState>,
) -> Result<(), String> {
    let verifier = {
        let mut state = oauth_state
            .spotify_verifier
            .lock()
            .map_err(|e| format!("Failed to lock OAuth state: {}", e))?;
        state
            .take()
            .ok_or_else(|| "No PKCE verifier found. Call spotify_auth_url first.".to_string())?
    };

    SpotifyAuth::exchange_code(&code, verifier.0, &user_id)
        .await
        .map_err(|e| format!("Token exchange failed: {}", e))?;

    log::info!("Spotify OAuth tokens exchanged for user {}", user_id);
    Ok(())
}

/// Trigger incremental Spotify sync of liked songs.
///
/// Creates a SpotifyClient (which refreshes tokens automatically) and
/// syncs liked songs added since the last sync. New tracks are inserted
/// into the database with source tracking.
///
/// Uses `spawn_blocking` with `block_on` to handle rusqlite's `!Send` Connection
/// being held across async boundaries in the sync methods.
///
/// # Arguments
/// * `user_id` - User identifier (must have completed OAuth flow)
///
/// # Returns
/// * `Ok(SyncResponse)` - Number of new tracks added
/// * `Err(String)` - If sync fails
#[tauri::command]
pub async fn sync_spotify(user_id: String) -> Result<SyncResponse, String> {
    log::info!("Starting Spotify sync for user {}", user_id);

    // Run sync in a blocking thread because rusqlite::Connection is !Send
    // and sync_liked_songs holds it across .await points
    let handle = tokio::runtime::Handle::current();
    let added = tokio::task::spawn_blocking(move || {
        handle.block_on(async {
            let mut client = SpotifyClient::new(&user_id)
                .await
                .map_err(|e| format!("Failed to create Spotify client: {}", e))?;

            let db_path = PathBuf::from("music_library.db");
            let conn =
                get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            client
                .sync_liked_songs(&conn)
                .await
                .map_err(|e| format!("Spotify sync failed: {}", e))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))??;

    log::info!("Spotify sync complete: {} new tracks added", added);

    Ok(SyncResponse {
        added,
        source: "spotify".to_string(),
    })
}

// ============================================================================
// SoundCloud Commands
// ============================================================================

/// Generate a SoundCloud OAuth authorization URL with mandatory PKCE.
///
/// SoundCloud requires PKCE (OAuth 2.1 compliance). Returns the URL
/// to open in a browser. The PKCE verifier is stored internally.
///
/// # Returns
/// * `Ok(String)` - Authorization URL to open in browser
/// * `Err(String)` - If environment variables are missing
#[tauri::command]
pub fn soundcloud_auth_url(oauth_state: State<OAuthState>) -> Result<String, String> {
    let auth_request = SoundCloudClient::authorization_url()
        .map_err(|e| format!("Failed to generate auth URL: {}", e))?;

    // Store verifier for code exchange
    let mut verifier = oauth_state
        .soundcloud_verifier
        .lock()
        .map_err(|e| format!("Failed to lock OAuth state: {}", e))?;
    *verifier = Some((auth_request.pkce_verifier, auth_request.csrf_token));

    Ok(auth_request.auth_url)
}

/// Exchange a SoundCloud authorization code for tokens.
///
/// Completes the OAuth 2.1 flow by exchanging the authorization code
/// for access and refresh tokens. The refresh token is stored in the system keychain.
///
/// # Arguments
/// * `code` - Authorization code from the OAuth redirect
/// * `user_id` - User identifier for token storage
///
/// # Returns
/// * `Ok(())` - Tokens exchanged and stored successfully
/// * `Err(String)` - If exchange fails or no PKCE verifier found
#[tauri::command]
pub async fn soundcloud_exchange_code(
    code: String,
    user_id: String,
    oauth_state: State<'_, OAuthState>,
) -> Result<(), String> {
    let verifier = {
        let mut state = oauth_state
            .soundcloud_verifier
            .lock()
            .map_err(|e| format!("Failed to lock OAuth state: {}", e))?;
        state
            .take()
            .ok_or_else(|| "No PKCE verifier found. Call soundcloud_auth_url first.".to_string())?
    };

    SoundCloudClient::exchange_code(&code, verifier.0, &user_id)
        .await
        .map_err(|e| format!("Token exchange failed: {}", e))?;

    log::info!("SoundCloud OAuth tokens exchanged for user {}", user_id);
    Ok(())
}

/// Trigger incremental SoundCloud sync of liked tracks.
///
/// Creates a SoundCloudClient (reads credentials from env) and
/// syncs liked tracks added since the last sync.
///
/// Uses `spawn_blocking` with `block_on` to handle rusqlite's `!Send` Connection
/// being held across async boundaries in the sync methods.
///
/// # Arguments
/// * `user_id` - User identifier (must have completed OAuth flow)
///
/// # Returns
/// * `Ok(SyncResponse)` - Number of new tracks added
/// * `Err(String)` - If sync fails
#[tauri::command]
pub async fn sync_soundcloud(user_id: String) -> Result<SyncResponse, String> {
    log::info!("Starting SoundCloud sync for user {}", user_id);

    // Run sync in a blocking thread because rusqlite::Connection is !Send
    // and sync_likes holds it across .await points
    let handle = tokio::runtime::Handle::current();
    let added = tokio::task::spawn_blocking(move || {
        handle.block_on(async {
            let mut client = SoundCloudClient::new()
                .map_err(|e| format!("Failed to create SoundCloud client: {}", e))?;

            let db_path = PathBuf::from("music_library.db");
            let conn =
                get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            client
                .sync_likes(&user_id, &conn)
                .await
                .map_err(|e| format!("SoundCloud sync failed: {}", e))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))??;

    log::info!("SoundCloud sync complete: {} new tracks added", added);

    Ok(SyncResponse {
        added,
        source: "soundcloud".to_string(),
    })
}

// ============================================================================
// Duplicate Detection
// ============================================================================

/// Check for potential duplicates of a track in the library.
///
/// Searches the database for tracks with similar title and artist,
/// using fuzzy matching (Jaro-Winkler) with normalization. Also
/// identifies variants (remixes, edits, live versions).
///
/// # Arguments
/// * `title` - Track title to check
/// * `artist` - Track artist to check
/// * `threshold` - Minimum similarity score (0.0-1.0), defaults to 0.85
///
/// # Returns
/// * `Ok(Vec<DuplicateMatch>)` - Potential duplicates sorted by similarity
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn check_duplicates(
    title: String,
    artist: String,
    threshold: Option<f64>,
) -> Result<Vec<DuplicateMatch>, String> {
    let threshold = threshold.unwrap_or(0.85);

    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    // Query all tracks from database for comparison
    let mut stmt = conn
        .prepare("SELECT id, title, artist FROM tracks WHERE title IS NOT NULL AND artist IS NOT NULL")
        .map_err(|e| format!("Query error: {}", e))?;

    let matches: Vec<DuplicateMatch> = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|e| format!("Query error: {}", e))?
        .filter_map(|r| r.ok())
        .filter_map(|(track_id, db_title, db_artist)| {
            let similarity = calculate_similarity(&title, &artist, &db_title, &db_artist);
            if similarity >= threshold {
                let variant = is_variant(&title, &db_title, &artist, &db_artist);
                Some(DuplicateMatch {
                    track_id,
                    title: db_title,
                    artist: db_artist,
                    similarity,
                    is_variant: variant,
                })
            } else {
                None
            }
        })
        .collect();

    Ok(matches)
}

/// Check if a source (spotify/soundcloud/dab) is connected (stub — to be implemented).
#[tauri::command]
pub async fn check_source_connected(_source: String) -> Result<bool, String> {
    Ok(false)
}

/// Disconnect a source (stub — to be implemented).
#[tauri::command]
pub async fn disconnect_source(_source: String) -> Result<(), String> {
    Ok(())
}

/// Connect Spotify: generate auth URL, open browser, listen for callback, exchange code.
#[tauri::command]
pub async fn connect_spotify_with_server(
    oauth_state: State<'_, OAuthState>,
) -> Result<String, String> {
    // Generate auth URL (stores PKCE verifier in state)
    let url = spotify_auth_url(State::clone(&oauth_state))?;
    open::that(&url).map_err(|e| format!("Failed to open browser: {}", e))?;

    // Wait for OAuth callback on local server
    let code = wait_for_oauth_callback().await?;

    // Exchange code for tokens (consumes PKCE verifier from state)
    spotify_exchange_code(code, "default".to_string(), oauth_state).await?;

    Ok("Connected".to_string())
}

/// Connect SoundCloud: generate auth URL, open browser, listen for callback, exchange code.
#[tauri::command]
pub async fn connect_soundcloud_with_server(
    oauth_state: State<'_, OAuthState>,
) -> Result<String, String> {
    // Generate auth URL (stores PKCE verifier in state)
    let url = soundcloud_auth_url(State::clone(&oauth_state))?;
    open::that(&url).map_err(|e| format!("Failed to open browser: {}", e))?;

    // Wait for OAuth callback on local server
    let code = wait_for_oauth_callback().await?;

    // Exchange code for tokens (consumes PKCE verifier from state)
    soundcloud_exchange_code(code, "default".to_string(), oauth_state).await?;

    Ok("Connected".to_string())
}

/// Start a temporary HTTP server on port 19823, wait for the OAuth callback,
/// extract the `code` parameter, send a success page, and return the code.
async fn wait_for_oauth_callback() -> Result<String, String> {
    use tokio::net::TcpListener;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let listener = TcpListener::bind("127.0.0.1:19823").await
        .map_err(|e| format!("Failed to bind callback server: {}", e))?;

    log::info!("OAuth callback server listening on 127.0.0.1:19823");

    // Wait for a single connection (with 2 minute timeout)
    let (mut stream, _) = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        listener.accept(),
    )
    .await
    .map_err(|_| "OAuth timed out — no callback received within 2 minutes".to_string())?
    .map_err(|e| format!("Failed to accept connection: {}", e))?;

    // Read the HTTP request
    let mut buf = vec![0u8; 4096];
    let n = stream.read(&mut buf).await
        .map_err(|e| format!("Failed to read callback: {}", e))?;
    let request = String::from_utf8_lossy(&buf[..n]);

    // Extract code from GET /callback?code=...&state=...
    let code = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1)) // "/callback?code=...&state=..."
        .and_then(|path| path.split('?').nth(1))
        .and_then(|query| {
            query.split('&')
                .find_map(|param| {
                    let mut kv = param.splitn(2, '=');
                    match (kv.next(), kv.next()) {
                        (Some("code"), Some(v)) => Some(v.to_string()),
                        _ => None,
                    }
                })
        })
        .ok_or_else(|| "No authorization code in callback".to_string())?;

    // Send success response
    let html = "<html><body style='font-family:system-ui;text-align:center;padding:60px;background:#0c0c12;color:#e8e8f0'><h2>Authorization successful</h2><p>You can close this tab.</p></body></html>";
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        html.len(),
        html
    );
    let _ = stream.write_all(response.as_bytes()).await;

    log::info!("OAuth callback received, code extracted");
    Ok(code)
}

/// Log in to DAB Music API (stub — to be implemented).
#[tauri::command]
pub async fn dab_login(_email: String, _password: String) -> Result<(), String> {
    Err("Not yet implemented".to_string())
}

/// Check if DAB Music API connection is active (stub — to be implemented).
#[tauri::command]
pub async fn check_dab_connected() -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_oauth_state_default() {
        let state = OAuthState::default();
        assert!(state.spotify_verifier.lock().unwrap().is_none());
        assert!(state.soundcloud_verifier.lock().unwrap().is_none());
    }

    #[test]
    fn test_sync_response_serialize() {
        let response = SyncResponse {
            added: 42,
            source: "spotify".to_string(),
        };

        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"added\":42"));
        assert!(json.contains("\"source\":\"spotify\""));
    }

    #[test]
    fn test_duplicate_match_serialize() {
        let m = DuplicateMatch {
            track_id: 1,
            title: "Song".to_string(),
            artist: "Artist".to_string(),
            similarity: 0.95,
            is_variant: false,
        };

        let json = serde_json::to_string(&m).unwrap();
        assert!(json.contains("\"track_id\":1"));
        assert!(json.contains("\"similarity\":0.95"));
        assert!(json.contains("\"is_variant\":false"));
    }

    #[test]
    fn test_duplicate_match_variant_serialize() {
        let m = DuplicateMatch {
            track_id: 2,
            title: "Song (Remix)".to_string(),
            artist: "Artist".to_string(),
            similarity: 0.88,
            is_variant: true,
        };

        let json = serde_json::to_string(&m).unwrap();
        assert!(json.contains("\"is_variant\":true"));
    }

    #[test]
    fn test_check_duplicates_with_database() {
        use crate::database::get_memory_connection;

        let conn = get_memory_connection().unwrap();

        // Insert some tracks
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Daft Punk', 'Daft Punk', 'Discovery', 'One More Time', 'mp3', '/a.mp3')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES ('Daft Punk', 'Daft Punk', 'Discovery', 'Digital Love', 'flac', '/b.flac')",
            [],
        )
        .unwrap();

        // Check similarity against a known duplicate
        let mut stmt = conn
            .prepare("SELECT id, title, artist FROM tracks WHERE title IS NOT NULL AND artist IS NOT NULL")
            .unwrap();

        let matches: Vec<DuplicateMatch> = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0).unwrap(),
                    row.get::<_, String>(1).unwrap(),
                    row.get::<_, String>(2).unwrap(),
                ))
            })
            .unwrap()
            .filter_map(|r| r.ok())
            .filter_map(|(track_id, db_title, db_artist)| {
                let similarity =
                    calculate_similarity("One More Time", "Daft Punk", &db_title, &db_artist);
                if similarity >= 0.85 {
                    Some(DuplicateMatch {
                        track_id,
                        title: db_title,
                        artist: db_artist,
                        similarity,
                        is_variant: false,
                    })
                } else {
                    None
                }
            })
            .collect();

        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].title, "One More Time");
        assert!(matches[0].similarity > 0.99);
    }
}
