//! Spotify API client with OAuth PKCE and incremental sync.
//!
//! Provides integration with Spotify Web API for:
//! - OAuth 2.0 Authorization Code flow with PKCE
//! - Fetching user's liked songs with incremental sync
//! - Fetching user's playlists and playlist tracks
//! - Rate limit handling with Retry-After header support
//!
//! ## Usage
//!
//! ```ignore
//! // 1. Generate authorization URL
//! let (url, state, verifier) = SpotifyAuth::authorization_url()?;
//!
//! // 2. User authorizes in browser, gets code from redirect
//! // 3. Exchange code for tokens
//! SpotifyAuth::exchange_code(&code, verifier, "user123").await?;
//!
//! // 4. Create client and sync
//! let mut client = SpotifyClient::new("user123").await?;
//! let added = client.sync_liked_songs(&db).await?;
//! ```

use std::env;
use std::time::Duration;

use chrono::{DateTime, TimeDelta, Utc};
use oauth2::{
    basic::{BasicClient, BasicTokenResponse},
    reqwest as oauth2_reqwest, AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken,
    PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, Scope, TokenResponse, TokenUrl,
};
use reqwest::{Client, Response, StatusCode};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::{get_refresh_token, store_refresh_token, TokenManager};

/// Spotify API base URL.
const API_BASE: &str = "https://api.spotify.com/v1";

/// Spotify authorization URL.
const AUTH_URL: &str = "https://accounts.spotify.com/authorize";

/// Spotify token URL.
const TOKEN_URL: &str = "https://accounts.spotify.com/api/token";

/// Default redirect URI for local OAuth callback.
const REDIRECT_URI: &str = "http://localhost:8080/callback";

/// Maximum items per API request (Spotify limit).
const PAGE_SIZE: u32 = 50;

/// Errors that can occur during Spotify API operations.
#[derive(Error, Debug)]
pub enum SpotifyError {
    #[error("Environment variable not set: {0}")]
    MissingEnvVar(String),

    #[error("OAuth error: {0}")]
    OAuthError(String),

    #[error("HTTP request failed: {0}")]
    HttpError(#[from] reqwest::Error),

    #[error("Token error: {0}")]
    TokenError(String),

    #[error("Database error: {0}")]
    DatabaseError(#[from] rusqlite::Error),

    #[error("Rate limited, retry after {0} seconds")]
    RateLimited(u64),

    #[error("API error: {0}")]
    ApiError(String),

    #[error("JSON parsing error: {0}")]
    JsonError(#[from] serde_json::Error),

    #[error("Token refresh error: {0}")]
    RefreshError(#[from] crate::auth::token_refresh::TokenRefreshError),

    #[error("Token storage error: {0}")]
    StorageError(#[from] crate::auth::token_storage::TokenStorageError),
}

/// Result type for Spotify operations.
pub type Result<T> = std::result::Result<T, SpotifyError>;

// ============================================================================
// API Response Types
// ============================================================================

/// Spotify artist object.
#[derive(Debug, Deserialize)]
pub struct SpotifyArtist {
    pub name: String,
}

/// Spotify album object.
#[derive(Debug, Deserialize)]
pub struct SpotifyAlbum {
    pub name: String,
}

/// Spotify track object.
#[derive(Debug, Deserialize)]
pub struct SpotifyTrack {
    pub id: String,
    pub name: String,
    pub artists: Vec<SpotifyArtist>,
    pub album: SpotifyAlbum,
    pub duration_ms: u64,
    /// Spotify URI (e.g., "spotify:track:abc123")
    pub uri: String,
}

/// Wrapper for saved tracks response (includes added_at timestamp).
#[derive(Debug, Deserialize)]
pub struct SavedTrack {
    pub track: SpotifyTrack,
    /// ISO 8601 timestamp when track was added to library.
    pub added_at: String,
}

/// Paginated response for saved tracks.
#[derive(Debug, Deserialize)]
pub struct SavedTracksResponse {
    pub items: Vec<SavedTrack>,
    /// URL for next page, None if no more pages.
    pub next: Option<String>,
    /// Total number of items.
    pub total: u32,
}

/// Spotify playlist object (summary).
#[derive(Debug, Deserialize)]
pub struct SpotifyPlaylist {
    pub id: String,
    pub name: String,
    /// Snapshot ID for change detection.
    pub snapshot_id: String,
    pub tracks: PlaylistTracksRef,
}

/// Reference to playlist tracks (for total count).
#[derive(Debug, Deserialize)]
pub struct PlaylistTracksRef {
    pub total: u32,
}

/// Paginated response for user's playlists.
#[derive(Debug, Deserialize)]
pub struct PlaylistsResponse {
    pub items: Vec<SpotifyPlaylist>,
    pub next: Option<String>,
    pub total: u32,
}

/// Wrapper for playlist track item.
#[derive(Debug, Deserialize)]
pub struct PlaylistTrackItem {
    pub track: Option<SpotifyTrack>, // Can be null for local files
    pub added_at: Option<String>,
}

/// Paginated response for playlist tracks.
#[derive(Debug, Deserialize)]
pub struct PlaylistTracksResponse {
    pub items: Vec<PlaylistTrackItem>,
    pub next: Option<String>,
    pub total: u32,
}

/// Track data formatted for database insertion.
#[derive(Debug, Clone, Serialize)]
pub struct SyncedTrack {
    pub spotify_id: String,
    pub spotify_uri: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_secs: u64,
    pub added_at: String,
}

impl From<&SavedTrack> for SyncedTrack {
    fn from(saved: &SavedTrack) -> Self {
        let artist = saved
            .track
            .artists
            .iter()
            .map(|a| a.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");

        Self {
            spotify_id: saved.track.id.clone(),
            spotify_uri: saved.track.uri.clone(),
            title: saved.track.name.clone(),
            artist,
            album: saved.track.album.name.clone(),
            duration_secs: saved.track.duration_ms / 1000,
            added_at: saved.added_at.clone(),
        }
    }
}

// ============================================================================
// OAuth Authorization Flow
// ============================================================================

/// OAuth authorization flow handler.
///
/// Handles the initial authorization URL generation and code exchange.
/// Use this before creating a SpotifyClient.
pub struct SpotifyAuth;

impl SpotifyAuth {
    /// Generate an OAuth authorization URL with PKCE challenge.
    ///
    /// Returns the URL to open in a browser, a CSRF state token, and
    /// the PKCE verifier (which must be stored for code exchange).
    ///
    /// # Returns
    /// * `Ok((url, state, verifier))` - Authorization URL, CSRF token, PKCE verifier
    /// * `Err(SpotifyError)` - If environment variables are missing
    ///
    /// # Environment Variables
    /// - `SPOTIFY_CLIENT_ID` - OAuth client ID from Spotify Developer Dashboard
    /// - `SPOTIFY_CLIENT_SECRET` - OAuth client secret (optional for PKCE, but needed for token refresh)
    pub fn authorization_url() -> Result<(String, CsrfToken, PkceCodeVerifier)> {
        let client_id = env::var("SPOTIFY_CLIENT_ID")
            .map_err(|_| SpotifyError::MissingEnvVar("SPOTIFY_CLIENT_ID".to_string()))?;

        // Client secret is optional for PKCE but we include it for refresh token support
        let client_secret = env::var("SPOTIFY_CLIENT_SECRET").ok();

        let mut client = BasicClient::new(ClientId::new(client_id))
            .set_auth_uri(AuthUrl::new(AUTH_URL.to_string()).unwrap())
            .set_token_uri(TokenUrl::new(TOKEN_URL.to_string()).unwrap())
            .set_redirect_uri(RedirectUrl::new(REDIRECT_URI.to_string()).unwrap());

        if let Some(secret) = client_secret {
            client = client.set_client_secret(ClientSecret::new(secret));
        }

        // Generate PKCE challenge
        let (pkce_challenge, pkce_verifier) = PkceCodeChallenge::new_random_sha256();

        // Build authorization URL with scopes
        let (auth_url, csrf_token) = client
            .authorize_url(CsrfToken::new_random)
            .add_scope(Scope::new("user-library-read".to_string()))
            .add_scope(Scope::new("playlist-read-private".to_string()))
            .set_pkce_challenge(pkce_challenge)
            .url();

        Ok((auth_url.to_string(), csrf_token, pkce_verifier))
    }

    /// Exchange authorization code for tokens.
    ///
    /// After user authorizes in browser and is redirected to callback,
    /// extract the `code` parameter and call this to get tokens.
    ///
    /// The refresh token is automatically stored in the system keychain.
    ///
    /// # Arguments
    /// * `code` - Authorization code from redirect URL
    /// * `pkce_verifier` - PKCE verifier from `authorization_url()`
    /// * `user_id` - User identifier for storing tokens
    ///
    /// # Returns
    /// * `Ok(access_token)` - Access token for immediate API calls
    /// * `Err(SpotifyError)` - If exchange fails
    pub async fn exchange_code(
        code: &str,
        pkce_verifier: PkceCodeVerifier,
        user_id: &str,
    ) -> Result<String> {
        let client_id = env::var("SPOTIFY_CLIENT_ID")
            .map_err(|_| SpotifyError::MissingEnvVar("SPOTIFY_CLIENT_ID".to_string()))?;
        let client_secret = env::var("SPOTIFY_CLIENT_SECRET")
            .map_err(|_| SpotifyError::MissingEnvVar("SPOTIFY_CLIENT_SECRET".to_string()))?;

        let client = BasicClient::new(ClientId::new(client_id))
            .set_client_secret(ClientSecret::new(client_secret))
            .set_auth_uri(AuthUrl::new(AUTH_URL.to_string()).unwrap())
            .set_token_uri(TokenUrl::new(TOKEN_URL.to_string()).unwrap())
            .set_redirect_uri(RedirectUrl::new(REDIRECT_URI.to_string()).unwrap());

        // Create HTTP client
        let http_client = oauth2_reqwest::Client::builder()
            .redirect(oauth2_reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| SpotifyError::OAuthError(format!("HTTP client error: {}", e)))?;

        // Exchange code for tokens
        let token_result: BasicTokenResponse = client
            .exchange_code(AuthorizationCode::new(code.to_string()))
            .set_pkce_verifier(pkce_verifier)
            .request_async(&http_client)
            .await
            .map_err(|e| SpotifyError::OAuthError(format!("{:?}", e)))?;

        // Store refresh token in keychain
        if let Some(refresh_token) = token_result.refresh_token() {
            store_refresh_token("spotify", user_id, refresh_token.secret())?;
        } else {
            return Err(SpotifyError::TokenError(
                "No refresh token in response".to_string(),
            ));
        }

        Ok(token_result.access_token().secret().to_string())
    }
}

// ============================================================================
// Spotify API Client
// ============================================================================

/// Spotify API client with automatic token refresh.
///
/// Handles API calls with proper authentication, rate limiting, and pagination.
pub struct SpotifyClient {
    http: Client,
    token_manager: TokenManager,
    user_id: String,
    access_token: String,
    token_expiry: DateTime<Utc>,
}

impl SpotifyClient {
    /// Create a new Spotify client for the given user.
    ///
    /// Requires that the user has already completed OAuth authorization
    /// (tokens stored in keychain via `SpotifyAuth::exchange_code`).
    ///
    /// # Arguments
    /// * `user_id` - User identifier used during authorization
    ///
    /// # Returns
    /// * `Ok(SpotifyClient)` - Ready to make API calls
    /// * `Err(SpotifyError)` - If token retrieval or refresh fails
    pub async fn new(user_id: &str) -> Result<Self> {
        let client_id = env::var("SPOTIFY_CLIENT_ID")
            .map_err(|_| SpotifyError::MissingEnvVar("SPOTIFY_CLIENT_ID".to_string()))?;
        let client_secret = env::var("SPOTIFY_CLIENT_SECRET")
            .map_err(|_| SpotifyError::MissingEnvVar("SPOTIFY_CLIENT_SECRET".to_string()))?;

        let token_manager = TokenManager::new(
            "spotify",
            &client_id,
            &client_secret,
            AUTH_URL,
            TOKEN_URL,
        )?;

        // Get initial access token by refreshing
        let _refresh_token = get_refresh_token("spotify", user_id)?;

        // Force initial token refresh to get access token
        // Token expiry is set to past to trigger refresh
        let expired = Utc::now() - TimeDelta::hours(1);
        let access_token = token_manager.ensure_valid_token(user_id, expired).await?;

        Ok(Self {
            http: Client::builder()
                .timeout(Duration::from_secs(30))
                .build()?,
            token_manager,
            user_id: user_id.to_string(),
            access_token,
            token_expiry: Utc::now() + TimeDelta::hours(1),
        })
    }

    /// Ensure access token is valid, refreshing proactively if needed.
    async fn ensure_token(&mut self) -> Result<()> {
        // Refresh proactively 5 minutes before expiration
        let buffer = TimeDelta::minutes(5);
        if Utc::now() >= self.token_expiry - buffer {
            let new_token = self
                .token_manager
                .ensure_valid_token(&self.user_id, self.token_expiry)
                .await?;
            self.access_token = new_token;
            self.token_expiry = Utc::now() + TimeDelta::hours(1);
        }
        Ok(())
    }

    /// Make an authenticated GET request to Spotify API.
    ///
    /// Handles rate limiting with Retry-After header support.
    async fn get(&mut self, url: &str) -> Result<Response> {
        self.ensure_token().await?;

        let response = self
            .http
            .get(url)
            .bearer_auth(&self.access_token)
            .send()
            .await?;

        // Handle rate limiting
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            let retry_after = response
                .headers()
                .get("Retry-After")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(30);

            return Err(SpotifyError::RateLimited(retry_after));
        }

        // Handle other errors
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(SpotifyError::ApiError(format!(
                "{}: {}",
                status,
                body.chars().take(200).collect::<String>()
            )));
        }

        Ok(response)
    }

    /// Sync user's liked songs incrementally.
    ///
    /// Fetches tracks added since last sync and stores them in the database
    /// with source tracking in `track_sources` table.
    ///
    /// # Arguments
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(count)` - Number of new tracks synced
    /// * `Err(SpotifyError)` - If API call or database operation fails
    pub async fn sync_liked_songs(&mut self, conn: &Connection) -> Result<usize> {
        // Get last sync timestamp from database
        let last_sync = get_last_sync_timestamp(conn, &self.user_id, "spotify")?
            .unwrap_or_else(|| {
                // Default to 1 year ago for initial sync
                (Utc::now() - TimeDelta::days(365)).to_rfc3339()
            });

        let last_sync_dt =
            DateTime::parse_from_rfc3339(&last_sync).unwrap_or_else(|_| Utc::now().into());

        let mut added_count = 0;
        let mut next_url = Some(format!("{}/me/tracks?limit={}", API_BASE, PAGE_SIZE));
        let mut tracks_to_insert: Vec<SyncedTrack> = Vec::new();

        // Paginate through all liked songs
        while let Some(ref url) = next_url {
            let response = self.get(url).await?;
            let data: SavedTracksResponse = response.json().await?;

            let mut found_old_track = false;
            for item in data.items {
                // Parse added_at timestamp
                let added_at = DateTime::parse_from_rfc3339(&item.added_at)
                    .unwrap_or_else(|_| Utc::now().into());

                // Only process tracks added since last sync
                if added_at > last_sync_dt {
                    tracks_to_insert.push(SyncedTrack::from(&item));
                    added_count += 1;
                } else {
                    // Spotify returns tracks in reverse chronological order,
                    // so once we hit old tracks, we can stop
                    found_old_track = true;
                    break;
                }
            }

            // Stop if we found old tracks, otherwise continue to next page
            if found_old_track {
                break;
            }
            next_url = data.next;
        }

        // Insert tracks into database
        if !tracks_to_insert.is_empty() {
            insert_synced_tracks(conn, &self.user_id, &tracks_to_insert)?;
        }

        // Update last sync timestamp
        set_last_sync_timestamp(conn, &self.user_id, "spotify", &Utc::now().to_rfc3339())?;

        Ok(added_count)
    }

    /// Get all user playlists.
    ///
    /// # Returns
    /// * `Ok(Vec<SpotifyPlaylist>)` - List of user's playlists
    /// * `Err(SpotifyError)` - If API call fails
    pub async fn get_playlists(&mut self) -> Result<Vec<SpotifyPlaylist>> {
        let mut playlists = Vec::new();
        let mut next_url = Some(format!("{}/me/playlists?limit={}", API_BASE, PAGE_SIZE));

        while let Some(url) = next_url {
            let response = self.get(&url).await?;
            let data: PlaylistsResponse = response.json().await?;

            playlists.extend(data.items);
            next_url = data.next;
        }

        Ok(playlists)
    }

    /// Sync tracks from a specific playlist.
    ///
    /// # Arguments
    /// * `playlist_id` - Spotify playlist ID
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(count)` - Number of tracks synced from playlist
    /// * `Err(SpotifyError)` - If API call or database operation fails
    pub async fn sync_playlist(
        &mut self,
        playlist_id: &str,
        conn: &Connection,
    ) -> Result<usize> {
        let mut tracks_to_insert: Vec<SyncedTrack> = Vec::new();
        let mut next_url = Some(format!(
            "{}/playlists/{}/tracks?limit={}",
            API_BASE, playlist_id, PAGE_SIZE
        ));

        while let Some(url) = next_url {
            let response = self.get(&url).await?;
            let data: PlaylistTracksResponse = response.json().await?;

            for item in data.items {
                // Skip local files (track is null)
                if let Some(track) = item.track {
                    let artist = track
                        .artists
                        .iter()
                        .map(|a| a.name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ");

                    tracks_to_insert.push(SyncedTrack {
                        spotify_id: track.id,
                        spotify_uri: track.uri,
                        title: track.name,
                        artist,
                        album: track.album.name,
                        duration_secs: track.duration_ms / 1000,
                        added_at: item.added_at.unwrap_or_default(),
                    });
                }
            }

            next_url = data.next;
        }

        let count = tracks_to_insert.len();

        // Insert tracks into database
        if !tracks_to_insert.is_empty() {
            insert_synced_tracks(conn, &self.user_id, &tracks_to_insert)?;
        }

        Ok(count)
    }

    /// Sync all user playlists.
    ///
    /// Fetches all playlists and their tracks, storing in database.
    ///
    /// # Arguments
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok((playlist_count, track_count))` - Number of playlists and total tracks synced
    /// * `Err(SpotifyError)` - If API call or database operation fails
    pub async fn sync_all_playlists(&mut self, conn: &Connection) -> Result<(usize, usize)> {
        let playlists = self.get_playlists().await?;
        let playlist_count = playlists.len();
        let mut total_tracks = 0;

        for playlist in playlists {
            let count = self.sync_playlist(&playlist.id, conn).await?;
            total_tracks += count;
        }

        Ok((playlist_count, total_tracks))
    }
}

// ============================================================================
// Database Operations
// ============================================================================

/// Get the last sync timestamp for a source.
fn get_last_sync_timestamp(
    conn: &Connection,
    user_id: &str,
    source: &str,
) -> Result<Option<String>> {
    let result = conn.query_row(
        "SELECT timestamp FROM last_sync_timestamps WHERE user_id = ? AND source = ?",
        [user_id, source],
        |row| row.get(0),
    );

    match result {
        Ok(timestamp) => Ok(Some(timestamp)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(SpotifyError::DatabaseError(e)),
    }
}

/// Set the last sync timestamp for a source.
fn set_last_sync_timestamp(
    conn: &Connection,
    user_id: &str,
    source: &str,
    timestamp: &str,
) -> Result<()> {
    conn.execute(
        "INSERT INTO last_sync_timestamps (user_id, source, timestamp) VALUES (?, ?, ?)
         ON CONFLICT(user_id, source) DO UPDATE SET timestamp = excluded.timestamp",
        [user_id, source, timestamp],
    )?;
    Ok(())
}

/// Ensure source record exists for user.
fn ensure_source_exists(conn: &Connection, user_id: &str, source_name: &str) -> Result<i64> {
    // Try to get existing source
    let result = conn.query_row(
        "SELECT id FROM sources WHERE name = ? AND user_id = ?",
        [source_name, user_id],
        |row| row.get(0),
    );

    match result {
        Ok(id) => Ok(id),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            // Insert new source
            conn.execute(
                "INSERT INTO sources (name, user_id, enabled) VALUES (?, ?, 1)",
                [source_name, user_id],
            )?;
            Ok(conn.last_insert_rowid())
        }
        Err(e) => Err(SpotifyError::DatabaseError(e)),
    }
}

/// Insert synced tracks into database with source tracking.
fn insert_synced_tracks(
    conn: &Connection,
    user_id: &str,
    tracks: &[SyncedTrack],
) -> Result<()> {
    // Ensure source record exists
    let source_id = ensure_source_exists(conn, user_id, "spotify")?;

    for track in tracks {
        // Check if track already exists by checking track_sources for this external_id
        let existing: Option<i64> = conn
            .query_row(
                "SELECT track_id FROM track_sources WHERE external_id = ?",
                [&track.spotify_uri],
                |row| row.get(0),
            )
            .optional()?;

        if existing.is_some() {
            // Track already synced from this source, skip
            continue;
        }

        // Insert into tracks table
        // Note: This creates a "phantom" track entry that will be matched
        // with local files via the duplicate detection system
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, duration)
             VALUES (?, ?, ?, ?, 'spotify', ?, ?)",
            rusqlite::params![
                &track.artist,
                &track.artist, // album_artist = artist for now
                &track.album,
                &track.title,
                &track.spotify_uri, // Use URI as "path" for Spotify tracks
                track.duration_secs as i64,
            ],
        )?;

        let track_id = conn.last_insert_rowid();

        // Insert into track_sources
        conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at)
             VALUES (?, ?, ?, ?)",
            rusqlite::params![track_id, source_id, &track.spotify_uri, &track.added_at],
        )?;
    }

    Ok(())
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::get_memory_connection;

    #[test]
    #[ignore] // Env var tests are flaky due to parallel execution; run manually with --ignored
    fn test_authorization_url_generation() {
        // Set required env vars for test
        env::set_var("SPOTIFY_CLIENT_ID", "test_client_id");
        env::set_var("SPOTIFY_CLIENT_SECRET", "test_client_secret");

        let result = SpotifyAuth::authorization_url();
        assert!(result.is_ok());

        let (url, state, _verifier) = result.unwrap();

        // Verify URL contains required components
        assert!(url.starts_with(AUTH_URL));
        assert!(url.contains("client_id=test_client_id"));
        assert!(url.contains("redirect_uri="));
        assert!(url.contains("scope="));
        assert!(url.contains("user-library-read"));
        assert!(url.contains("playlist-read-private"));
        assert!(url.contains("code_challenge="));
        assert!(url.contains("code_challenge_method=S256"));

        // CSRF state should not be empty
        assert!(!state.secret().is_empty());

        // Clean up
        env::remove_var("SPOTIFY_CLIENT_ID");
        env::remove_var("SPOTIFY_CLIENT_SECRET");
    }

    #[test]
    #[ignore] // Env var tests are flaky due to parallel execution; run manually with --ignored
    fn test_authorization_url_missing_client_id() {
        // Ensure env var is not set
        env::remove_var("SPOTIFY_CLIENT_ID");

        let result = SpotifyAuth::authorization_url();
        assert!(result.is_err());

        match result {
            Err(SpotifyError::MissingEnvVar(var)) => {
                assert_eq!(var, "SPOTIFY_CLIENT_ID");
            }
            _ => panic!("Expected MissingEnvVar error"),
        }
    }

    #[test]
    fn test_synced_track_from_saved_track() {
        let saved = SavedTrack {
            track: SpotifyTrack {
                id: "track123".to_string(),
                name: "Test Song".to_string(),
                artists: vec![
                    SpotifyArtist {
                        name: "Artist 1".to_string(),
                    },
                    SpotifyArtist {
                        name: "Artist 2".to_string(),
                    },
                ],
                album: SpotifyAlbum {
                    name: "Test Album".to_string(),
                },
                duration_ms: 180000,
                uri: "spotify:track:track123".to_string(),
            },
            added_at: "2026-02-03T12:00:00Z".to_string(),
        };

        let synced = SyncedTrack::from(&saved);

        assert_eq!(synced.spotify_id, "track123");
        assert_eq!(synced.spotify_uri, "spotify:track:track123");
        assert_eq!(synced.title, "Test Song");
        assert_eq!(synced.artist, "Artist 1, Artist 2");
        assert_eq!(synced.album, "Test Album");
        assert_eq!(synced.duration_secs, 180);
        assert_eq!(synced.added_at, "2026-02-03T12:00:00Z");
    }

    #[test]
    fn test_get_last_sync_timestamp_none() {
        let conn = get_memory_connection().unwrap();

        let result = get_last_sync_timestamp(&conn, "user123", "spotify").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_set_and_get_last_sync_timestamp() {
        let conn = get_memory_connection().unwrap();

        let timestamp = "2026-02-03T12:00:00Z";
        set_last_sync_timestamp(&conn, "user123", "spotify", timestamp).unwrap();

        let result = get_last_sync_timestamp(&conn, "user123", "spotify").unwrap();
        assert_eq!(result, Some(timestamp.to_string()));
    }

    #[test]
    fn test_set_last_sync_timestamp_upsert() {
        let conn = get_memory_connection().unwrap();

        // Set initial timestamp
        set_last_sync_timestamp(&conn, "user123", "spotify", "2026-02-01T12:00:00Z").unwrap();

        // Update timestamp
        set_last_sync_timestamp(&conn, "user123", "spotify", "2026-02-03T12:00:00Z").unwrap();

        // Should have updated value
        let result = get_last_sync_timestamp(&conn, "user123", "spotify").unwrap();
        assert_eq!(result, Some("2026-02-03T12:00:00Z".to_string()));

        // Should only have one row
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM last_sync_timestamps WHERE user_id = 'user123'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_ensure_source_exists_creates() {
        let conn = get_memory_connection().unwrap();

        let source_id = ensure_source_exists(&conn, "user123", "spotify").unwrap();
        assert!(source_id > 0);

        // Verify source was created
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sources WHERE name = 'spotify' AND user_id = 'user123'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_ensure_source_exists_returns_existing() {
        let conn = get_memory_connection().unwrap();

        // Create first
        let id1 = ensure_source_exists(&conn, "user123", "spotify").unwrap();

        // Call again
        let id2 = ensure_source_exists(&conn, "user123", "spotify").unwrap();

        // Should return same ID
        assert_eq!(id1, id2);

        // Should only have one row
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sources WHERE name = 'spotify' AND user_id = 'user123'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_insert_synced_tracks() {
        let conn = get_memory_connection().unwrap();

        let tracks = vec![
            SyncedTrack {
                spotify_id: "track1".to_string(),
                spotify_uri: "spotify:track:track1".to_string(),
                title: "Song 1".to_string(),
                artist: "Artist 1".to_string(),
                album: "Album 1".to_string(),
                duration_secs: 180,
                added_at: "2026-02-03T12:00:00Z".to_string(),
            },
            SyncedTrack {
                spotify_id: "track2".to_string(),
                spotify_uri: "spotify:track:track2".to_string(),
                title: "Song 2".to_string(),
                artist: "Artist 2".to_string(),
                album: "Album 2".to_string(),
                duration_secs: 240,
                added_at: "2026-02-03T13:00:00Z".to_string(),
            },
        ];

        insert_synced_tracks(&conn, "user123", &tracks).unwrap();

        // Verify tracks were inserted
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 2);

        // Verify track_sources were created
        let source_count: i32 = conn
            .query_row("SELECT COUNT(*) FROM track_sources", [], |row| row.get(0))
            .unwrap();
        assert_eq!(source_count, 2);

        // Verify source was created
        let source_count: i32 = conn
            .query_row("SELECT COUNT(*) FROM sources", [], |row| row.get(0))
            .unwrap();
        assert_eq!(source_count, 1);
    }

    #[test]
    fn test_insert_synced_tracks_skips_duplicates() {
        let conn = get_memory_connection().unwrap();

        let track = SyncedTrack {
            spotify_id: "track1".to_string(),
            spotify_uri: "spotify:track:track1".to_string(),
            title: "Song 1".to_string(),
            artist: "Artist 1".to_string(),
            album: "Album 1".to_string(),
            duration_secs: 180,
            added_at: "2026-02-03T12:00:00Z".to_string(),
        };

        // Insert first time
        insert_synced_tracks(&conn, "user123", &[track.clone()]).unwrap();

        // Insert again (should skip)
        insert_synced_tracks(&conn, "user123", &[track]).unwrap();

        // Should still only have one track
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_error_display() {
        let err = SpotifyError::MissingEnvVar("SPOTIFY_CLIENT_ID".to_string());
        assert_eq!(
            format!("{}", err),
            "Environment variable not set: SPOTIFY_CLIENT_ID"
        );

        let err = SpotifyError::RateLimited(30);
        assert_eq!(format!("{}", err), "Rate limited, retry after 30 seconds");
    }

    // Integration tests (require actual Spotify credentials)

    #[tokio::test]
    #[ignore] // Requires Spotify credentials and network access
    async fn test_sync_liked_songs_integration() {
        // This test requires:
        // 1. SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET env vars
        // 2. A refresh token stored in keychain for "test_user"
        // 3. Network access to Spotify API

        let conn = get_memory_connection().unwrap();
        let mut client = SpotifyClient::new("test_user").await.unwrap();
        let count = client.sync_liked_songs(&conn).await.unwrap();
        println!("Synced {} tracks", count);
    }

    #[tokio::test]
    #[ignore] // Requires Spotify credentials and network access
    async fn test_get_playlists_integration() {
        let mut client = SpotifyClient::new("test_user").await.unwrap();
        let playlists = client.get_playlists().await.unwrap();
        println!("Found {} playlists", playlists.len());
        for p in playlists {
            println!("  - {} ({} tracks)", p.name, p.tracks.total);
        }
    }
}
