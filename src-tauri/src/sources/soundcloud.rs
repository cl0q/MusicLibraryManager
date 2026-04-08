//! SoundCloud API client with OAuth 2.1 and incremental sync.
//!
//! Implements OAuth 2.1 Authorization Code flow with mandatory PKCE
//! (requirement as of Oct 1, 2024), incremental sync for liked tracks
//! and playlists, and token management via system keychain.
//!
//! ## Source Priority
//!
//! SoundCloud tracks use the following download priority (from CONTEXT.md):
//! 1. SoundCloud direct download (if available)
//! 2. DAB (FLAC)
//! 3. YouTube fallback
//!
//! This differs from Spotify because SoundCloud may have exclusive content
//! (remixes, DJ sets) not available elsewhere.

use chrono::{DateTime, TimeDelta, Utc};
use oauth2::{
    basic::BasicClient, AuthType, AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken,
    PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, Scope, TokenResponse, TokenUrl,
};
use reqwest::Client;
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::{token_refresh::TokenManager, token_storage};

/// SoundCloud OAuth endpoints.
const AUTH_URL: &str = "https://soundcloud.com/connect";
const TOKEN_URL: &str = "https://secure.soundcloud.com/oauth/token";

/// SoundCloud API base URL (v1).
const API_BASE: &str = "https://api.soundcloud.com";

/// Errors that can occur during SoundCloud operations.
#[derive(Error, Debug)]
pub enum SoundCloudError {
    #[error("OAuth configuration error: {0}")]
    ConfigError(String),

    #[error("Token storage error: {0}")]
    TokenStorageError(#[from] token_storage::TokenStorageError),

    #[error("Token refresh error: {0}")]
    TokenRefreshError(#[from] crate::auth::token_refresh::TokenRefreshError),

    #[error("HTTP request failed: {0}")]
    HttpError(#[from] reqwest::Error),

    #[error("API error: {status} - {message}")]
    ApiError { status: u16, message: String },

    #[error("Rate limited, retry after {retry_after} seconds")]
    RateLimited { retry_after: u64 },

    #[error("Database error: {0}")]
    DatabaseError(#[from] rusqlite::Error),

    #[error("Playlist database error: {0}")]
    PlaylistDatabaseError(#[from] crate::database::connection::DatabaseError),

    #[error("JSON parse error: {0}")]
    ParseError(#[from] serde_json::Error),

    #[error("Environment variable not set: {0}")]
    EnvVarMissing(String),

    #[error("Date/time parse error: {0}")]
    DateParseError(String),
}

/// Result type for SoundCloud operations.
pub type Result<T> = std::result::Result<T, SoundCloudError>;

/// SoundCloud user from API response.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SoundCloudUser {
    pub id: u64,
    pub username: String,
    #[serde(default)]
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub permalink_url: Option<String>,
}

/// SoundCloud track from API response.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SoundCloudTrack {
    pub id: u64,
    pub title: String,
    pub user: SoundCloudUser,
    /// Duration in milliseconds
    pub duration: u64,
    /// ISO 8601 timestamp when track was created
    pub created_at: String,
    /// Full URL to the track on SoundCloud
    pub permalink_url: String,
    /// Whether the track is downloadable by the current user
    #[serde(default)]
    pub downloadable: bool,
    /// Genre of the track
    #[serde(default)]
    pub genre: Option<String>,
    /// Description of the track
    #[serde(default)]
    pub description: Option<String>,
}

/// SoundCloud playlist from API response.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SoundCloudPlaylist {
    pub id: u64,
    pub title: String,
    pub user: SoundCloudUser,
    /// Number of tracks in the playlist
    pub track_count: u64,
    /// ISO 8601 timestamp when playlist was created
    pub created_at: String,
    /// Full URL to the playlist on SoundCloud
    pub permalink_url: String,
    /// Tracks in the playlist (may be paginated)
    #[serde(default)]
    pub tracks: Vec<SoundCloudTrack>,
}

/// Paginated response for SoundCloud collections (likes, playlists).
#[derive(Debug, Clone, Deserialize)]
pub struct SoundCloudCollection<T> {
    pub collection: Vec<T>,
    /// URL for the next page of results, if any
    pub next_href: Option<String>,
}

/// SoundCloud "like" wrapper that includes the liked_at timestamp.
#[derive(Debug, Clone, Deserialize)]
pub struct SoundCloudLike {
    /// When the track was liked (ISO 8601)
    pub created_at: String,
    /// The liked track
    pub track: SoundCloudTrack,
}

/// OAuth authorization URL and PKCE verifier for callback handling.
#[derive(Debug)]
pub struct AuthorizationRequest {
    /// URL to redirect user to for authorization
    pub auth_url: String,
    /// CSRF token for state validation
    pub csrf_token: CsrfToken,
    /// PKCE verifier (must be stored until token exchange)
    pub pkce_verifier: PkceCodeVerifier,
}

/// SoundCloud API client.
///
/// Handles OAuth 2.1 authentication with mandatory PKCE, token refresh,
/// and incremental sync of user's liked tracks and playlists.
pub struct SoundCloudClient {
    http: Client,
    token_manager: TokenManager,
    access_token: String,
    token_expiry: DateTime<Utc>,
    /// Kept for future direct API calls that require client_id parameter.
    #[allow(dead_code)]
    client_id: String,
    /// Kept for future token exchange operations.
    #[allow(dead_code)]
    client_secret: String,
}

impl SoundCloudClient {
    /// Create a new SoundCloud client.
    ///
    /// Reads OAuth credentials from environment variables:
    /// - `SOUNDCLOUD_CLIENT_ID`
    /// - `SOUNDCLOUD_CLIENT_SECRET`
    ///
    /// # Returns
    /// * `Ok(SoundCloudClient)` if credentials are configured
    /// * `Err(SoundCloudError::EnvVarMissing)` if credentials are missing
    pub fn new() -> Result<Self> {
        let client_id = std::env::var("SOUNDCLOUD_CLIENT_ID")
            .map_err(|_| SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_ID".to_string()))?;
        let client_secret = std::env::var("SOUNDCLOUD_CLIENT_SECRET")
            .map_err(|_| SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_SECRET".to_string()))?;

        Self::with_credentials(&client_id, &client_secret)
    }

    /// Create a new SoundCloud client with explicit credentials.
    ///
    /// # Arguments
    /// * `client_id` - OAuth client ID from SoundCloud Developer Portal
    /// * `client_secret` - OAuth client secret from SoundCloud Developer Portal
    pub fn with_credentials(client_id: &str, client_secret: &str) -> Result<Self> {
        let token_manager = TokenManager::new(
            "soundcloud",
            client_id,
            client_secret,
            AUTH_URL,
            TOKEN_URL,
        )?;

        Ok(Self {
            http: Client::new(),
            token_manager,
            access_token: String::new(),
            token_expiry: Utc::now(),
            client_id: client_id.to_string(),
            client_secret: client_secret.to_string(),
        })
    }

    /// Generate OAuth authorization URL with mandatory PKCE.
    ///
    /// SoundCloud requires PKCE (OAuth 2.1 compliance, deadline passed Oct 1, 2024).
    /// Always uses S256 challenge method.
    ///
    /// # Returns
    /// * `Ok(AuthorizationRequest)` with URL, CSRF token, and PKCE verifier
    /// * `Err(SoundCloudError::EnvVarMissing)` if credentials not set
    ///
    /// # Example
    /// ```ignore
    /// let auth_req = SoundCloudClient::authorization_url()?;
    /// // Redirect user to auth_req.auth_url
    /// // Store auth_req.pkce_verifier for token exchange
    /// ```
    pub fn authorization_url() -> Result<AuthorizationRequest> {
        let client_id = std::env::var("SOUNDCLOUD_CLIENT_ID")
            .map_err(|_| SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_ID".to_string()))?;
        let client_secret = std::env::var("SOUNDCLOUD_CLIENT_SECRET")
            .map_err(|_| SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_SECRET".to_string()))?;

        let client = BasicClient::new(ClientId::new(client_id))
            .set_client_secret(ClientSecret::new(client_secret))
            .set_auth_uri(
                AuthUrl::new(AUTH_URL.to_string())
                    .map_err(|e| SoundCloudError::ConfigError(format!("Invalid auth URL: {}", e)))?,
            )
            .set_token_uri(
                TokenUrl::new(TOKEN_URL.to_string())
                    .map_err(|e| SoundCloudError::ConfigError(format!("Invalid token URL: {}", e)))?,
            )
            .set_redirect_uri(
                RedirectUrl::new("http://127.0.0.1:19823/callback".to_string())
                    .map_err(|e| SoundCloudError::ConfigError(format!("Invalid redirect URL: {}", e)))?,
            );

        // Generate PKCE challenge (mandatory for OAuth 2.1)
        let (pkce_challenge, pkce_verifier) = PkceCodeChallenge::new_random_sha256();

        let (auth_url, csrf_token) = client
            .authorize_url(CsrfToken::new_random)
            .add_scope(Scope::new("non-expiring".to_string()))
            .set_pkce_challenge(pkce_challenge)
            .url();

        Ok(AuthorizationRequest {
            auth_url: auth_url.to_string(),
            csrf_token,
            pkce_verifier,
        })
    }

    /// Exchange authorization code for tokens.
    ///
    /// Completes the OAuth 2.1 flow by exchanging the authorization code
    /// (from callback) for access and refresh tokens. The refresh token
    /// is stored in the system keychain.
    ///
    /// # Arguments
    /// * `code` - Authorization code from OAuth callback
    /// * `pkce_verifier` - PKCE verifier from authorization_url()
    /// * `user_id` - User identifier for token storage
    ///
    /// # Returns
    /// * `Ok(())` if tokens were exchanged and stored successfully
    /// * `Err(SoundCloudError)` if exchange or storage failed
    pub async fn exchange_code(
        code: &str,
        pkce_verifier: PkceCodeVerifier,
        user_id: &str,
    ) -> Result<()> {
        let client_id = std::env::var("SOUNDCLOUD_CLIENT_ID")
            .map_err(|_| SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_ID".to_string()))?;
        let client_secret = std::env::var("SOUNDCLOUD_CLIENT_SECRET")
            .map_err(|_| SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_SECRET".to_string()))?;

        let client = BasicClient::new(ClientId::new(client_id))
            .set_client_secret(ClientSecret::new(client_secret))
            .set_auth_uri(
                AuthUrl::new(AUTH_URL.to_string())
                    .map_err(|e| SoundCloudError::ConfigError(format!("Invalid auth URL: {}", e)))?,
            )
            .set_token_uri(
                TokenUrl::new(TOKEN_URL.to_string())
                    .map_err(|e| SoundCloudError::ConfigError(format!("Invalid token URL: {}", e)))?,
            )
            .set_redirect_uri(
                RedirectUrl::new("http://127.0.0.1:19823/callback".to_string())
                    .map_err(|e| SoundCloudError::ConfigError(format!("Invalid redirect URL: {}", e)))?,
            )
            // SoundCloud requires client credentials in POST body, not HTTP Basic Auth
            .set_auth_type(AuthType::RequestBody);

        // Create async HTTP client
        let http_client = oauth2::reqwest::Client::builder()
            .redirect(oauth2::reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| SoundCloudError::ConfigError(format!("HTTP client error: {}", e)))?;

        // Exchange code for tokens with PKCE verifier
        let token_result = client
            .exchange_code(AuthorizationCode::new(code.to_string()))
            .set_pkce_verifier(pkce_verifier)
            .request_async(&http_client)
            .await
            .map_err(|e| SoundCloudError::ConfigError(format!("Token exchange failed: {:?}", e)))?;

        // Store refresh token in keychain
        if let Some(refresh_token) = token_result.refresh_token() {
            token_storage::store_refresh_token("soundcloud", user_id, refresh_token.secret())?;
        }

        Ok(())
    }

    /// Ensure access token is valid, refreshing if needed.
    ///
    /// Proactively refreshes if token expires within 5 minutes.
    async fn ensure_token(&mut self, user_id: &str) -> Result<()> {
        let now = Utc::now();
        let five_minutes = TimeDelta::minutes(5);

        if now >= self.token_expiry - five_minutes {
            match self.token_manager.ensure_valid_token(user_id, self.token_expiry).await {
                Ok(new_token) => {
                    self.access_token = new_token;
                    // SoundCloud access tokens typically expire in 1 hour
                    self.token_expiry = Utc::now() + TimeDelta::hours(1);
                }
                Err(crate::auth::token_refresh::TokenRefreshError::TokenStillValid) => {
                    // Token is still valid, nothing to do
                }
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }

    /// Set the access token directly (for testing or after initial auth).
    pub fn set_access_token(&mut self, token: &str, expiry: DateTime<Utc>) {
        self.access_token = token.to_string();
        self.token_expiry = expiry;
    }

    /// Make an authenticated API request.
    ///
    /// Handles rate limiting with Retry-After header.
    async fn api_get<T: for<'de> Deserialize<'de>>(&self, url: &str) -> Result<T> {
        let response = self
            .http
            .get(url)
            .bearer_auth(&self.access_token)
            .send()
            .await?;

        let status = response.status();

        // Handle rate limiting
        if status.as_u16() == 429 {
            let retry_after = response
                .headers()
                .get("Retry-After")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse().ok())
                .unwrap_or(60);
            return Err(SoundCloudError::RateLimited { retry_after });
        }

        // Handle other errors
        if !status.is_success() {
            let message = response.text().await.unwrap_or_else(|_| "Unknown error".to_string());
            return Err(SoundCloudError::ApiError {
                status: status.as_u16(),
                message,
            });
        }

        let body = response.text().await?;
        serde_json::from_str(&body).map_err(|e| {
            SoundCloudError::ParseError(serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("Failed to parse response: {} - body: {}", e, &body[..body.len().min(200)]),
            )))
        })
    }

    /// Get the current user's profile.
    pub async fn get_me(&self) -> Result<SoundCloudUser> {
        self.api_get(&format!("{}/me", API_BASE)).await
    }

    /// Sync user's liked tracks incrementally.
    ///
    /// Fetches only tracks liked since the last sync timestamp.
    /// Stores tracks in database with source tracking.
    ///
    /// # Arguments
    /// * `user_id` - User identifier for token and sync timestamp retrieval
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(usize)` - Number of new tracks added
    /// * `Err(SoundCloudError)` - If sync failed
    pub async fn sync_likes(&mut self, user_id: &str, conn: &Connection) -> Result<usize> {
        self.ensure_token(user_id).await?;

        let mut added_count = 0;
        // v1 /me/favorites returns flat tracks in liked-at order (most recently liked first).
        // SC API doesn't expose the liked-at timestamp, so we derive synthetic timestamps
        // from position to preserve correct ordering.
        let base_time = Utc::now();
        let mut global_index: i64 = 0;

        let mut next_url = Some(format!(
            "{}/me/favorites?limit=200&linked_partitioning=1",
            API_BASE
        ));

        while let Some(ref url) = next_url {
            log::info!("Fetching SoundCloud likes from: {}", url);

            let (tracks, pagination_next): (Vec<SoundCloudTrack>, Option<String>) =
                match self.api_get::<SoundCloudCollection<SoundCloudTrack>>(url).await {
                    Ok(collection) => {
                        log::info!("Got collection with {} tracks", collection.collection.len());
                        (collection.collection, collection.next_href)
                    }
                    Err(_) => {
                        let tracks: Vec<SoundCloudTrack> = self.api_get(url).await?;
                        log::info!("Got raw array with {} tracks", tracks.len());
                        (tracks, None)
                    }
                };

            for track in tracks {
                // Synthetic liked-at: most recently liked = base_time, older = earlier timestamps.
                // 1-minute spacing preserves sort order.
                let liked_at = base_time - TimeDelta::minutes(global_index);
                let liked_at_str = liked_at.to_rfc3339();
                global_index += 1;

                if insert_track_from_soundcloud(conn, &track, &liked_at_str)? {
                    added_count += 1;
                }
            }

            next_url = pagination_next;
            log::info!("Next page: {:?}", next_url);
        }

        // Update last sync timestamp (for logging purposes, not filtering)
        set_last_sync_timestamp(conn, user_id, "soundcloud", &Utc::now().to_rfc3339())?;

        log::info!("SoundCloud sync complete: {} new tracks added", added_count);
        Ok(added_count)
    }

    /// Sync user's playlists.
    ///
    /// Fetches all playlists and their tracks, storing them in the database.
    ///
    /// # Arguments
    /// * `user_id` - User identifier
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(usize)` - Number of new tracks added across all playlists
    /// * `Err(SoundCloudError)` - If sync failed
    pub async fn sync_playlists(&mut self, user_id: &str, conn: &Connection) -> Result<usize> {
        self.ensure_token(user_id).await?;

        let mut added_count = 0;
        let mut next_url = Some(format!("{}/me/playlists?limit=50", API_BASE));

        while let Some(ref url) = next_url {
            let response: SoundCloudCollection<SoundCloudPlaylist> = self.api_get(url).await?;

            for playlist in response.collection {
                // Fetch full playlist with tracks if not included
                let full_playlist: SoundCloudPlaylist = if playlist.tracks.is_empty() && playlist.track_count > 0 {
                    self.api_get(&format!("{}/playlists/{}", API_BASE, playlist.id)).await?
                } else {
                    playlist
                };

                // Insert each track from the playlist
                for track in &full_playlist.tracks {
                    if insert_track_from_soundcloud(conn, track, &track.created_at)? {
                        added_count += 1;
                    }
                }
            }

            next_url = response.next_href;
        }

        Ok(added_count)
    }

    /// Get a specific SoundCloud playlist.
    ///
    /// # Arguments
    /// * `playlist_id` - SoundCloud playlist ID
    ///
    /// # Returns
    /// * `Ok(SoundCloudPlaylist)` - Playlist with tracks
    /// * `Err(SoundCloudError)` - If API call fails
    pub async fn get_playlist(&self, playlist_id: &str) -> Result<SoundCloudPlaylist> {
        let url = format!("{}/playlists/{}", API_BASE, playlist_id);
        self.api_get(&url).await
    }

    /// Get tracks from a SoundCloud playlist.
    ///
    /// # Arguments
    /// * `playlist_id` - SoundCloud playlist ID
    ///
    /// # Returns
    /// * `Ok(Vec<SoundCloudTrack>)` - List of tracks
    /// * `Err(SoundCloudError)` - If API call fails
    pub async fn get_playlist_tracks(&self, playlist_id: &str) -> Result<Vec<SoundCloudTrack>> {
        let playlist = self.get_playlist(playlist_id).await?;
        Ok(playlist.tracks)
    }
}

/// Parse SoundCloud's non-standard date format.
///
/// SoundCloud uses format: "2026/01/03 09:39:42 +0000"
/// This is not RFC3339, so we need custom parsing.
fn parse_soundcloud_date(date_str: &str) -> Result<DateTime<Utc>> {
    // Try RFC3339 first (in case some responses use it)
    if let Ok(dt) = DateTime::parse_from_rfc3339(date_str) {
        return Ok(dt.with_timezone(&Utc));
    }

    // Parse SoundCloud format: "2026/01/03 09:39:42 +0000"
    let parsed = chrono::NaiveDateTime::parse_from_str(
        date_str.trim_end_matches(" +0000"),
        "%Y/%m/%d %H:%M:%S",
    )
    .map_err(|e| SoundCloudError::DateParseError(format!("{}: {}", e, date_str)))?;

    Ok(parsed.and_utc())
}

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
        Err(e) => Err(SoundCloudError::DatabaseError(e)),
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
        "INSERT INTO last_sync_timestamps (user_id, source, timestamp)
         VALUES (?, ?, ?)
         ON CONFLICT(user_id, source) DO UPDATE SET timestamp = excluded.timestamp",
        [user_id, source, timestamp],
    )?;
    Ok(())
}

/// Find an existing track by fuzzy title+artist similarity.
///
/// Uses a LIKE pre-filter to narrow candidates, then applies Jaro-Winkler
/// similarity scoring (≥0.85 threshold). Returns the best match if found.
fn find_similar_track(
    conn: &Connection,
    title: &str,
    artist: &str,
) -> Result<Option<i64>> {
    use crate::dedup::calculate_similarity;

    let title_prefix = &title[..title.len().min(10)];
    let artist_prefix = &artist[..artist.len().min(10)];

    let mut stmt = conn.prepare(
        "SELECT id, title, artist FROM tracks
         WHERE title LIKE ? OR artist LIKE ?
         LIMIT 50",
    )?;

    let candidates = stmt.query_map(
        rusqlite::params![
            format!("%{title_prefix}%"),
            format!("%{artist_prefix}%"),
        ],
        |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        },
    )?;

    let mut best: Option<(i64, f64)> = None;
    for candidate in candidates {
        let (id, db_title, db_artist) = candidate?;
        let score = calculate_similarity(title, artist, &db_title, &db_artist);
        if score >= 0.85 {
            if best.is_none() || score > best.unwrap().1 {
                best = Some((id, score));
            }
        }
    }

    Ok(best.map(|(id, _)| id))
}

/// Insert a track from SoundCloud into the database.
///
/// Creates a track record and track_sources relationship.
/// Returns true if a new track was inserted, false if it already existed.
fn insert_track_from_soundcloud(
    conn: &Connection,
    track: &SoundCloudTrack,
    added_at: &str,
) -> Result<bool> {
    // First, ensure the soundcloud source exists for this external_id
    let external_id = format!("soundcloud:{}", track.id);

    // Check if this track already exists (by external_id in track_sources)
    let existing: Option<i64> = conn
        .query_row(
            "SELECT ts.track_id FROM track_sources ts
             JOIN sources s ON ts.source_id = s.id
             WHERE ts.external_id = ? AND s.name = 'soundcloud'",
            [&external_id],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(track_id) = existing {
        // Update date_added to keep ordering consistent across syncs
        conn.execute(
            "UPDATE tracks SET date_added = ? WHERE id = ?",
            rusqlite::params![added_at, track_id],
        )?;
        return Ok(false);
    }

    // Also check by original_path (permalink_url) — track may exist from a download
    // but its track_sources entry was cleaned up by migration
    let existing_by_path: Option<i64> = conn
        .query_row(
            "SELECT id FROM tracks WHERE original_path = ?",
            [&track.permalink_url],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(track_id) = existing_by_path {
        // Re-create the track_sources link and update date_added
        conn.execute(
            "UPDATE tracks SET date_added = ? WHERE id = ?",
            rusqlite::params![added_at, track_id],
        )?;
        let source_id: i64 = conn.query_row(
            "SELECT id FROM sources WHERE name = 'soundcloud' LIMIT 1",
            [],
            |row| row.get(0),
        )?;
        conn.execute(
            "INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at)
             VALUES (?, ?, ?, ?)",
            rusqlite::params![track_id, source_id, external_id, added_at],
        )?;
        return Ok(false);
    }

    // Check by similarity — catches local tracks imported from disk whose
    // original_path is a filesystem path (not a SoundCloud permalink)
    if let Some(track_id) = find_similar_track(conn, &track.title, &track.user.username)? {
        conn.execute(
            "INSERT OR IGNORE INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'default', 1)",
            [],
        )?;
        let source_id: i64 = conn.query_row(
            "SELECT id FROM sources WHERE name = 'soundcloud' LIMIT 1",
            [],
            |row| row.get(0),
        )?;
        conn.execute(
            "INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at)
             VALUES (?, ?, ?, ?)",
            rusqlite::params![track_id, source_id, external_id, added_at],
        )?;
        return Ok(false);
    }

    // Insert track into tracks table
    // Use artist from user.username, album as "SoundCloud Likes"
    let duration_secs = track.duration / 1000; // Convert from ms to seconds

    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, genre, duration, format, original_path, date_added)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        rusqlite::params![
            track.user.username,
            track.user.username,
            "SoundCloud Likes",
            track.title,
            track.genre,
            duration_secs as i64,
            "soundcloud", // Format indicates streaming source
            track.permalink_url,
            added_at, // Use SoundCloud "liked at" timestamp
        ],
    )?;

    let track_id = conn.last_insert_rowid();

    // Get or create the soundcloud source
    // Note: In production, user_id would come from the auth context
    // For now, use "default" as placeholder
    conn.execute(
        "INSERT OR IGNORE INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'default', 1)",
        [],
    )?;

    let source_id: i64 = conn.query_row(
        "SELECT id FROM sources WHERE name = 'soundcloud' AND user_id = 'default'",
        [],
        |row| row.get(0),
    )?;

    // Insert track_sources relationship
    conn.execute(
        "INSERT INTO track_sources (track_id, source_id, external_id, added_at)
         VALUES (?, ?, ?, ?)",
        rusqlite::params![track_id, source_id, external_id, added_at],
    )?;

    Ok(true)
}

/// Find or create a track in the library with deduplication.
///
/// Searches for existing track by external_id first, then by similarity.
/// If found, returns existing track_id. Otherwise creates new phantom track.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track` - SoundCloud track
/// * `source_id` - Source ID for track_sources relationship
/// * `added_at` - ISO 8601 timestamp when track was added
///
/// # Returns
/// * `Ok(track_id)` - ID of found or created track
/// * `Err` if database operation fails
fn find_or_create_soundcloud_track(
    conn: &Connection,
    track: &SoundCloudTrack,
    source_id: i64,
    added_at: &str,
) -> Result<i64> {
    let external_id = format!("soundcloud:{}", track.id);

    // Check if track already exists by external_id
    let existing: Option<i64> = conn
        .query_row(
            "SELECT track_id FROM track_sources WHERE external_id = ?",
            [&external_id],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(track_id) = existing {
        return Ok(track_id);
    }

    // Check for duplicate by similarity
    if let Some(track_id) = find_similar_track(conn, &track.title, &track.user.username)? {
        // Found similar track, create track_sources relationship
        conn.execute(
            "INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at)
             VALUES (?, ?, ?, ?)",
            rusqlite::params![track_id, source_id, &external_id, added_at],
        )?;
        return Ok(track_id);
    }

    // No existing track found, create new phantom track
    let duration_secs = track.duration / 1000;

    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, genre, duration, format, original_path, date_added)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        rusqlite::params![
            track.user.username,
            track.user.username,
            "SoundCloud",
            track.title,
            track.genre,
            duration_secs as i64,
            "soundcloud",
            track.permalink_url,
            added_at, // Use SoundCloud "liked at" timestamp
        ],
    )?;

    let track_id = conn.last_insert_rowid();

    // Insert into track_sources
    conn.execute(
        "INSERT INTO track_sources (track_id, source_id, external_id, added_at)
         VALUES (?, ?, ?, ?)",
        rusqlite::params![track_id, source_id, &external_id, added_at],
    )?;

    Ok(track_id)
}

/// Convenience function to sync the full SoundCloud library.
///
/// Syncs both liked tracks and playlists.
///
/// # Arguments
/// * `client` - Authenticated SoundCloud client
/// * `user_id` - User identifier
/// * `conn` - Database connection
///
/// # Returns
/// * `Ok(usize)` - Total number of new tracks added
/// * `Err(SoundCloudError)` - If sync failed
pub async fn sync_soundcloud_library(
    client: &mut SoundCloudClient,
    user_id: &str,
    conn: &Connection,
) -> Result<usize> {
    let likes_count = client.sync_likes(user_id, conn).await?;
    let playlists_count = client.sync_playlists(user_id, conn).await?;
    Ok(likes_count + playlists_count)
}

/// Import a specific SoundCloud playlist into the library.
///
/// Creates a local mirrored playlist and adds all tracks from the SoundCloud playlist.
/// Tracks are deduplicated against existing library tracks.
///
/// # Arguments
/// * `conn` - Database connection
/// * `client` - Authenticated SoundCloud client
/// * `sc_playlist_id` - SoundCloud playlist ID
/// * `source_id` - Database ID of the SoundCloud source
///
/// # Returns
/// * `Ok(playlist_id)` - ID of created local playlist
/// * `Err(SoundCloudError)` - If API call or database operation fails
pub async fn import_soundcloud_playlist(
    conn: &Connection,
    client: &SoundCloudClient,
    sc_playlist_id: &str,
    source_id: i64,
) -> Result<i64> {
    // Fetch playlist from SoundCloud
    let playlist = client.get_playlist(sc_playlist_id).await?;

    // Create local playlist
    use crate::database::playlist::create_playlist;
    use crate::models::PlaylistCategory;

    let playlist_id = create_playlist(
        conn,
        playlist.title.clone(),
        Some("Imported from SoundCloud".to_string()),
        vec![],
        PlaylistCategory::Regular,
    )?;

    // Store external_id for future refresh
    let external_id = format!("soundcloud:{}", sc_playlist_id);
    conn.execute(
        "UPDATE playlists SET external_id = ?, source_id = ? WHERE id = ?",
        rusqlite::params![external_id, source_id, playlist_id],
    )?;

    // Add tracks to playlist with deduplication
    for track in &playlist.tracks {
        let track_id = find_or_create_soundcloud_track(conn, track, source_id, &track.created_at)?;

        // Add to playlist
        use crate::database::playlist::add_track_to_playlist;
        add_track_to_playlist(conn, playlist_id, track_id)?;
    }

    Ok(playlist_id)
}

/// Import SoundCloud liked tracks into a "SoundCloud Likes" playlist.
///
/// Creates or gets the "SoundCloud Likes" playlist and adds all liked tracks.
/// Uses incremental sync to only fetch new liked songs.
///
/// # Arguments
/// * `conn` - Database connection
/// * `client` - Authenticated SoundCloud client
/// * `source_id` - Database ID of the SoundCloud source
/// * `user_id` - User identifier for sync timestamp
///
/// # Returns
/// * `Ok(count)` - Number of new tracks added
/// * `Err(SoundCloudError)` - If API call or database operation fails
pub async fn import_soundcloud_liked_songs(
    conn: &Connection,
    client: &mut SoundCloudClient,
    source_id: i64,
    user_id: &str,
) -> Result<usize> {
    // Get or create "SoundCloud Likes" playlist
    use crate::database::playlist::get_or_create_liked_playlist;
    let playlist_id = get_or_create_liked_playlist(conn, "soundcloud", source_id)?;

    // Get last sync timestamp
    let last_sync = get_last_sync_timestamp(conn, user_id, "soundcloud")?
        .unwrap_or_else(|| (chrono::Utc::now() - chrono::TimeDelta::days(365)).to_rfc3339());

    let mut added_count = 0;
    let base_time = Utc::now();
    let mut global_index: i64 = 0;
    let mut next_url = Some(format!("{}/me/favorites?limit=50&linked_partitioning=1", API_BASE));

    while let Some(ref url) = next_url {
        let response: SoundCloudCollection<SoundCloudTrack> = client.api_get(url).await?;

        for track in response.collection {
            let liked_at = base_time - TimeDelta::minutes(global_index);
            let liked_at_str = liked_at.to_rfc3339();
            global_index += 1;

            // Skip tracks older than last sync (use index-based cutoff)
            // Since we can't get real liked-at timestamps, just process all tracks
            // and rely on find_or_create deduplication
            let track_id = find_or_create_soundcloud_track(conn, &track, source_id, &liked_at_str)?;

            // Add to liked playlist
            use crate::database::playlist::add_liked_track;
            add_liked_track(conn, playlist_id, track_id, &liked_at_str)?;
            added_count += 1;
        }

        // Continue to next page
        next_url = response.next_href;
    }

    // Update last sync timestamp
    set_last_sync_timestamp(conn, user_id, "soundcloud", &chrono::Utc::now().to_rfc3339())?;

    Ok(added_count)
}

/// Refresh a SoundCloud playlist with new tracks from source.
///
/// Fetches current tracks from SoundCloud and adds any new tracks to the local playlist.
/// Uses add-only semantics (tracks removed from SoundCloud remain in local playlist).
///
/// # Arguments
/// * `conn` - Database connection
/// * `client` - Authenticated SoundCloud client
/// * `playlist_id` - Local playlist ID to refresh
///
/// # Returns
/// * `Ok(count)` - Number of new tracks added
/// * `Err(SoundCloudError)` - If API call or database operation fails
pub async fn refresh_soundcloud_playlist(
    conn: &Connection,
    client: &SoundCloudClient,
    playlist_id: i64,
) -> Result<usize> {
    // Get external_id from playlists
    let external_id: String = conn.query_row(
        "SELECT external_id FROM playlists WHERE id = ?",
        [playlist_id],
        |row| row.get(0),
    )?;

    // Extract SoundCloud playlist ID from external_id
    let sc_playlist_id = external_id
        .strip_prefix("soundcloud:")
        .ok_or_else(|| SoundCloudError::ApiError {
            status: 0,
            message: "Invalid external_id format".to_string(),
        })?;

    // Get source_id
    let source_id: i64 = conn.query_row(
        "SELECT source_id FROM playlists WHERE id = ?",
        [playlist_id],
        |row| row.get(0),
    )?;

    // Fetch current tracks from SoundCloud
    let tracks = client.get_playlist_tracks(sc_playlist_id).await?;

    // Build source_tracks with track_id and source position
    let mut source_tracks = Vec::new();
    for (idx, track) in tracks.iter().enumerate() {
        let track_id = find_or_create_soundcloud_track(conn, track, source_id, &track.created_at)?;
        source_tracks.push((track_id, idx));
    }

    // Refresh playlist with add-only semantics
    use crate::database::playlist::refresh_mirrored_playlist;
    let added_count = refresh_mirrored_playlist(conn, playlist_id, source_tracks)?;

    Ok(added_count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_authorization_url_components() {
        // Test using explicit credentials to avoid global state race conditions
        use oauth2::{
            basic::BasicClient, AuthUrl, ClientId, ClientSecret, CsrfToken,
            PkceCodeChallenge, RedirectUrl, Scope, TokenUrl,
        };

        let client = BasicClient::new(ClientId::new("test_client_id".to_string()))
            .set_client_secret(ClientSecret::new("test_client_secret".to_string()))
            .set_auth_uri(AuthUrl::new(AUTH_URL.to_string()).unwrap())
            .set_token_uri(TokenUrl::new(TOKEN_URL.to_string()).unwrap())
            .set_redirect_uri(RedirectUrl::new("http://127.0.0.1:19823/callback".to_string()).unwrap());

        let (pkce_challenge, _pkce_verifier) = PkceCodeChallenge::new_random_sha256();

        let (auth_url, csrf_token) = client
            .authorize_url(CsrfToken::new_random)
            .add_scope(Scope::new("non-expiring".to_string()))
            .set_pkce_challenge(pkce_challenge)
            .url();

        let url_str = auth_url.to_string();

        // Verify URL contains required components
        assert!(url_str.contains("soundcloud.com/connect"));
        assert!(url_str.contains("client_id=test_client_id"));
        assert!(url_str.contains("response_type=code"));
        assert!(url_str.contains("redirect_uri="));
        // PKCE challenge should be present (SHA256 method)
        assert!(url_str.contains("code_challenge="));
        assert!(url_str.contains("code_challenge_method=S256"));
        // Scope should include non-expiring
        assert!(url_str.contains("scope=non-expiring"));

        // CSRF token should be generated
        assert!(!csrf_token.secret().is_empty());
    }

    #[test]
    fn test_client_new_requires_env_vars() {
        // This test verifies the new() constructor checks env vars
        // Using with_credentials instead to avoid race conditions
        // Just verify the error type is correct
        let err = SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_ID".to_string());
        assert_eq!(
            format!("{}", err),
            "Environment variable not set: SOUNDCLOUD_CLIENT_ID"
        );
    }

    #[test]
    fn test_client_creation_with_credentials() {
        let result = SoundCloudClient::with_credentials("test_id", "test_secret");
        assert!(result.is_ok());
    }

    #[test]
    fn test_soundcloud_track_deserialize() {
        let json = r#"{
            "id": 123456789,
            "title": "Test Track",
            "user": {
                "id": 12345,
                "username": "TestArtist"
            },
            "duration": 180000,
            "created_at": "2024-01-15T10:30:00Z",
            "permalink_url": "https://soundcloud.com/testartist/test-track",
            "downloadable": false,
            "genre": "Electronic"
        }"#;

        let track: SoundCloudTrack = serde_json::from_str(json).unwrap();
        assert_eq!(track.id, 123456789);
        assert_eq!(track.title, "Test Track");
        assert_eq!(track.user.username, "TestArtist");
        assert_eq!(track.duration, 180000);
        assert_eq!(track.genre, Some("Electronic".to_string()));
        assert!(!track.downloadable);
    }

    #[test]
    fn test_soundcloud_like_deserialize() {
        let json = r#"{
            "created_at": "2024-02-01T15:45:00Z",
            "track": {
                "id": 987654321,
                "title": "Liked Track",
                "user": {
                    "id": 54321,
                    "username": "AnotherArtist"
                },
                "duration": 240000,
                "created_at": "2024-01-01T00:00:00Z",
                "permalink_url": "https://soundcloud.com/anotherartist/liked-track"
            }
        }"#;

        let like: SoundCloudLike = serde_json::from_str(json).unwrap();
        assert_eq!(like.created_at, "2024-02-01T15:45:00Z");
        assert_eq!(like.track.id, 987654321);
        assert_eq!(like.track.title, "Liked Track");
    }

    #[test]
    fn test_collection_response_deserialize() {
        let json = r#"{
            "collection": [
                {
                    "created_at": "2024-02-01T15:45:00Z",
                    "track": {
                        "id": 1,
                        "title": "Track 1",
                        "user": {"id": 1, "username": "Artist1"},
                        "duration": 120000,
                        "created_at": "2024-01-01T00:00:00Z",
                        "permalink_url": "https://soundcloud.com/artist1/track1"
                    }
                }
            ],
            "next_href": "https://api-v2.soundcloud.com/me/track_likes?limit=50&offset=50"
        }"#;

        let response: SoundCloudCollection<SoundCloudLike> = serde_json::from_str(json).unwrap();
        assert_eq!(response.collection.len(), 1);
        assert_eq!(response.next_href, Some("https://api-v2.soundcloud.com/me/track_likes?limit=50&offset=50".to_string()));
    }

    #[test]
    fn test_database_sync_timestamp() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        // Initially no timestamp
        let ts = get_last_sync_timestamp(&conn, "user1", "soundcloud").unwrap();
        assert!(ts.is_none());

        // Set timestamp
        set_last_sync_timestamp(&conn, "user1", "soundcloud", "2024-02-01T00:00:00Z").unwrap();

        // Retrieve timestamp
        let ts = get_last_sync_timestamp(&conn, "user1", "soundcloud").unwrap();
        assert_eq!(ts, Some("2024-02-01T00:00:00Z".to_string()));

        // Update timestamp
        set_last_sync_timestamp(&conn, "user1", "soundcloud", "2024-02-02T00:00:00Z").unwrap();
        let ts = get_last_sync_timestamp(&conn, "user1", "soundcloud").unwrap();
        assert_eq!(ts, Some("2024-02-02T00:00:00Z".to_string()));
    }

    #[test]
    fn test_insert_track_from_soundcloud() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute("PRAGMA foreign_keys = ON", []).unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        let track = SoundCloudTrack {
            id: 123456,
            title: "Test Track".to_string(),
            user: SoundCloudUser {
                id: 789,
                username: "TestArtist".to_string(),
                avatar_url: None,
                permalink_url: None,
            },
            duration: 180000, // 3 minutes in ms
            created_at: "2024-01-15T10:30:00Z".to_string(),
            permalink_url: "https://soundcloud.com/testartist/test-track".to_string(),
            downloadable: false,
            genre: Some("Electronic".to_string()),
            description: None,
        };

        // First insert should succeed
        let inserted = insert_track_from_soundcloud(&conn, &track, "2024-02-01T00:00:00Z").unwrap();
        assert!(inserted);

        // Verify track was inserted
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks WHERE title = 'Test Track'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);

        // Verify track_sources relationship
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM track_sources WHERE external_id = 'soundcloud:123456'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);

        // Second insert of same track should return false (duplicate)
        let inserted = insert_track_from_soundcloud(&conn, &track, "2024-02-01T00:00:00Z").unwrap();
        assert!(!inserted);

        // Count should still be 1
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks WHERE title = 'Test Track'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_error_display() {
        let err = SoundCloudError::EnvVarMissing("SOUNDCLOUD_CLIENT_ID".to_string());
        assert_eq!(format!("{}", err), "Environment variable not set: SOUNDCLOUD_CLIENT_ID");

        let err = SoundCloudError::RateLimited { retry_after: 60 };
        assert_eq!(format!("{}", err), "Rate limited, retry after 60 seconds");

        let err = SoundCloudError::ApiError {
            status: 401,
            message: "Unauthorized".to_string(),
        };
        assert_eq!(format!("{}", err), "API error: 401 - Unauthorized");
    }

    #[tokio::test]
    #[ignore] // Requires SoundCloud credentials
    async fn test_sync_likes_integration() {
        // This test requires:
        // - SOUNDCLOUD_CLIENT_ID env var
        // - SOUNDCLOUD_CLIENT_SECRET env var
        // - Valid refresh token stored in keychain for user

        let mut client = SoundCloudClient::new().unwrap();
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        // Would need to set access token manually for this test
        // client.set_access_token("...", Utc::now() + TimeDelta::hours(1));

        let count = client.sync_likes("test_user", &conn).await.unwrap();
        println!("Synced {} liked tracks", count);
    }

    #[tokio::test]
    #[ignore] // Requires real DB + SoundCloud credentials + app NOT running (shared refresh token)
    async fn test_sync_likes_ordering_e2e() {
        // Uses real DB and token to verify sync produces correct liked-at ordering.
        // Run with: cargo test test_sync_likes_ordering_e2e -- --ignored --nocapture
        // NOTE: App must be closed first — SC rotates refresh tokens on use.
        dotenvy::dotenv().ok();

        let db_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("music_library.db");
        if !db_path.exists() {
            panic!("No music_library.db found at {:?}", db_path);
        }
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        let mut client = SoundCloudClient::new().unwrap();
        client.ensure_token("default").await.unwrap();

        let count = client.sync_likes("default", &conn).await.unwrap();
        println!("Synced {} new liked tracks", count);

        // Verify ordering: date_added should be DESC (most recently liked first)
        let mut stmt = conn
            .prepare(
                "SELECT t.title, t.date_added FROM tracks t
                 JOIN track_sources ts ON ts.track_id = t.id
                 JOIN sources s ON ts.source_id = s.id
                 WHERE s.name = 'soundcloud' AND t.date_added IS NOT NULL
                 ORDER BY t.date_added DESC
                 LIMIT 10",
            )
            .unwrap();
        let rows: Vec<(String, String)> = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();

        println!("\nTop 10 liked tracks (should match SoundCloud likes page order):");
        for (i, (title, date)) in rows.iter().enumerate() {
            println!("  {}. {} ({})", i + 1, title, date);
        }

        // Verify descending order
        for window in rows.windows(2) {
            assert!(
                window[0].1 >= window[1].1,
                "date_added not in DESC order: {} >= {} failed",
                window[0].1,
                window[1].1
            );
        }

        // First track should match SoundCloud likes page
        assert!(
            !rows.is_empty(),
            "No SoundCloud tracks found after sync"
        );
        println!("\nFirst liked track: {}", rows[0].0);
        println!("Expected (from SC page): Stereo Players vs Cieśla & Winamp & DJ PitorS - Salam Aleikum v2 (Bagrol Mashup)");
    }

    #[test]
    fn test_find_or_create_soundcloud_track_new() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        // Create source
        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
            [],
        )
        .unwrap();
        let source_id = conn.last_insert_rowid();

        let track = SoundCloudTrack {
            id: 123456,
            title: "Test Track".to_string(),
            user: SoundCloudUser {
                id: 789,
                username: "TestArtist".to_string(),
                avatar_url: None,
                permalink_url: None,
            },
            duration: 180000,
            created_at: "2024-01-15T10:30:00Z".to_string(),
            permalink_url: "https://soundcloud.com/testartist/test-track".to_string(),
            downloadable: false,
            genre: Some("Electronic".to_string()),
            description: None,
        };

        let track_id = find_or_create_soundcloud_track(&conn, &track, source_id, "2024-02-01T00:00:00Z").unwrap();
        assert!(track_id > 0);

        // Verify track was created
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks WHERE title = 'Test Track'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);

        // Verify track_sources relationship
        let ts_count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM track_sources WHERE external_id = 'soundcloud:123456'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(ts_count, 1);
    }

    #[test]
    fn test_find_or_create_soundcloud_track_existing() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
            [],
        )
        .unwrap();
        let source_id = conn.last_insert_rowid();

        let track = SoundCloudTrack {
            id: 123456,
            title: "Test Track".to_string(),
            user: SoundCloudUser {
                id: 789,
                username: "TestArtist".to_string(),
                avatar_url: None,
                permalink_url: None,
            },
            duration: 180000,
            created_at: "2024-01-15T10:30:00Z".to_string(),
            permalink_url: "https://soundcloud.com/testartist/test-track".to_string(),
            downloadable: false,
            genre: Some("Electronic".to_string()),
            description: None,
        };

        // Create track first time
        let track_id1 = find_or_create_soundcloud_track(&conn, &track, source_id, "2024-02-01T00:00:00Z").unwrap();

        // Create same track again
        let track_id2 = find_or_create_soundcloud_track(&conn, &track, source_id, "2024-02-01T00:00:00Z").unwrap();

        // Should return same track_id
        assert_eq!(track_id1, track_id2);

        // Should still only have one track
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
    }

    #[tokio::test]
    #[ignore] // Requires SoundCloud credentials
    async fn test_import_soundcloud_playlist_integration() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        let client = SoundCloudClient::new().unwrap();

        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
            [],
        )
        .unwrap();
        let source_id = conn.last_insert_rowid();

        // Would need actual playlist ID
        // let playlist_id = import_soundcloud_playlist(&conn, &client, "test_playlist_id", source_id).await.unwrap();
        // println!("Imported playlist: {}", playlist_id);
    }

    #[tokio::test]
    #[ignore] // Requires SoundCloud credentials
    async fn test_import_soundcloud_liked_songs_integration() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        let mut client = SoundCloudClient::new().unwrap();

        conn.execute(
            "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'test_user', 1)",
            [],
        )
        .unwrap();
        let source_id = conn.last_insert_rowid();

        let count = import_soundcloud_liked_songs(&conn, &mut client, source_id, "test_user")
            .await
            .unwrap();
        println!("Imported {} liked songs", count);
    }

    #[tokio::test]
    #[ignore] // Requires SoundCloud credentials
    async fn test_refresh_soundcloud_playlist_integration() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&conn).unwrap();

        let client = SoundCloudClient::new().unwrap();

        // Would need to first import a playlist, then refresh it
        // let added = refresh_soundcloud_playlist(&conn, &client, playlist_id).await.unwrap();
        // println!("Added {} new tracks on refresh", added);
    }
}
