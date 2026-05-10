//! Apple Music API client with library sync.
//!
//! Provides integration with Apple Music for:
//! - Developer token scraping from Apple's web player
//! - User authentication via MusicKit JS in a Tauri webview
//! - Fetching user's library songs with incremental sync
//! - Fetching user's library playlists and playlist tracks
//! - Rate limit handling
//!
//! ## Key Differences from Spotify/SoundCloud
//!
//! - No OAuth2 flow. Developer token is scraped from music.apple.com HTML.
//! - User token obtained via MusicKit JS authorize() in a Tauri webview window.
//! - No refresh tokens — user token lasts ~180 days, then re-auth required.
//! - API endpoints are on amp-api.music.apple.com (Apple's private API).
//!
//! ## Usage
//!
//! ```ignore
//! // 1. Scrape developer token
//! let dev_token = scrape_developer_token().await?;
//!
//! // 2. User authorizes via MusicKit JS webview (frontend handles this)
//! // 3. Store user token
//! store_refresh_token("apple_music", "default", &user_token)?;
//!
//! // 4. Create client and sync
//! let mut client = AppleMusicClient::new("default").await?;
//! let added = client.sync_library_songs(&db).await?;
//! ```

use std::time::Duration;

use chrono::{DateTime, TimeDelta, Utc};
use reqwest::{Client, StatusCode};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::token_storage;

/// Apple Music API base URL (private amp-api).
const API_BASE: &str = "https://amp-api.music.apple.com";

/// Apple Music web player URLs for developer token scraping.
/// Primary: production URL. Fallback: legacy beta URL.
const WEB_PLAYER_URL: &str = "https://music.apple.com";
const WEB_PLAYER_URL_FALLBACK: &str = "https://beta.music.apple.com";

/// Maximum items per API request.
const PAGE_SIZE: u32 = 100;

// ============================================================================
// Error Types
// ============================================================================

/// Errors that can occur during Apple Music API operations.
#[derive(Error, Debug)]
pub enum AppleMusicError {
    #[error("Failed to scrape developer token: {0}")]
    DevTokenError(String),

    #[error("User token not found — user must re-authenticate via Apple Music")]
    UserTokenMissing,

    #[error("HTTP request failed: {0}")]
    HttpError(#[from] reqwest::Error),

    #[error("Rate limited, retry after {0} seconds")]
    RateLimited(u64),

    #[error("API error ({status}): {message}")]
    ApiError { status: u16, message: String },

    #[error("Database error: {0}")]
    DatabaseError(#[from] rusqlite::Error),

    #[error("JSON parse error: {0}")]
    JsonError(#[from] serde_json::Error),

    #[error("Token storage error: {0}")]
    StorageError(#[from] token_storage::TokenStorageError),

    #[error("Parse error: {0}")]
    ParseError(String),

    #[error("Playlist database error: {0}")]
    PlaylistDatabaseError(#[from] crate::database::connection::DatabaseError),
}

/// Result type for Apple Music operations.
pub type Result<T> = std::result::Result<T, AppleMusicError>;

// ============================================================================
// API Response Types
// ============================================================================

/// Generic paginated response from Apple Music API.
#[derive(Debug, Deserialize)]
pub struct AppleMusicResponse<T> {
    /// Array of resource objects.
    pub data: Vec<T>,
    /// URL for the next page, if more results exist.
    pub next: Option<String>,
}

/// A library song resource from Apple Music.
#[derive(Debug, Deserialize)]
pub struct LibrarySong {
    /// Unique identifier (e.g., "i.abcdef1234567890")
    pub id: String,
    /// Song attributes.
    pub attributes: LibrarySongAttributes,
}

/// Attributes of a library song.
#[derive(Debug, Deserialize)]
pub struct LibrarySongAttributes {
    /// Track name.
    pub name: String,
    /// Artist name.
    #[serde(rename = "artistName")]
    pub artist_name: String,
    /// Album name.
    #[serde(rename = "albumName")]
    pub album_name: String,
    /// Duration in milliseconds.
    #[serde(rename = "durationInMillis")]
    pub duration_in_millis: Option<u64>,
    /// When the song was added to the library (ISO 8601).
    #[serde(rename = "dateAdded")]
    pub date_added: Option<String>,
    /// Array of genre names.
    #[serde(rename = "genreNames", default)]
    pub genre_names: Vec<String>,
    /// Play parameters (contains catalogId for catalog lookup).
    #[serde(rename = "playParams")]
    pub play_params: Option<PlayParams>,
}

/// Play parameters for a library song.
#[derive(Debug, Deserialize)]
pub struct PlayParams {
    /// Library song ID.
    pub id: Option<String>,
    /// Catalog song ID (for linking to Apple Music catalog).
    #[serde(rename = "catalogId")]
    pub catalog_id: Option<String>,
    /// Kind of content (e.g., "song").
    pub kind: Option<String>,
}

/// A library playlist resource from Apple Music.
#[derive(Debug, Deserialize)]
pub struct LibraryPlaylist {
    /// Unique identifier.
    pub id: String,
    /// Playlist attributes.
    pub attributes: LibraryPlaylistAttributes,
}

/// Attributes of a library playlist.
#[derive(Debug, Deserialize)]
pub struct LibraryPlaylistAttributes {
    /// Playlist name.
    pub name: String,
    /// Playlist description.
    pub description: Option<LibraryPlaylistDescription>,
    /// When the playlist was last modified (ISO 8601).
    #[serde(rename = "lastModifiedDate")]
    pub last_modified_date: Option<String>,
    /// When the playlist was created (ISO 8601).
    #[serde(rename = "dateAdded")]
    pub date_added: Option<String>,
}

/// Description container for playlists.
#[derive(Debug, Deserialize)]
pub struct LibraryPlaylistDescription {
    pub standard: Option<String>,
}

/// Storefront resource (user's region).
#[derive(Debug, Deserialize)]
pub struct Storefront {
    pub id: String,
}

/// Paginated storefront response.
#[derive(Debug, Deserialize)]
pub struct StorefrontResponse {
    pub data: Vec<Storefront>,
}

/// Intermediate struct for database insertion of Apple Music tracks.
#[derive(Debug, Clone, Serialize)]
pub struct AppleMusicSyncedTrack {
    /// Apple Music library song ID.
    pub apple_music_id: String,
    /// Track title.
    pub title: String,
    /// Artist name.
    pub artist: String,
    /// Album name.
    pub album: String,
    /// Duration in seconds.
    pub duration_secs: u64,
    /// ISO 8601 timestamp when added to library.
    pub added_at: String,
    /// Genre (first from genre_names array).
    pub genre: Option<String>,
}

impl From<&LibrarySong> for AppleMusicSyncedTrack {
    fn from(song: &LibrarySong) -> Self {
        Self {
            apple_music_id: song.id.clone(),
            title: song.attributes.name.clone(),
            artist: song.attributes.artist_name.clone(),
            album: song.attributes.album_name.clone(),
            duration_secs: song.attributes.duration_in_millis.unwrap_or(0) / 1000,
            added_at: song
                .attributes
                .date_added
                .clone()
                .unwrap_or_else(|| Utc::now().to_rfc3339()),
            genre: song.attributes.genre_names.first().cloned(),
        }
    }
}

// ============================================================================
// Developer Token Scraping
// ============================================================================

/// Scrape the Apple Music developer token from the web player.
///
/// Fetches the music.apple.com HTML (with beta.music.apple.com as fallback),
/// finds the configuration meta tag, URL-decodes the content, parses as JSON,
/// and extracts the MEDIA_API token.
///
/// # Returns
/// * `Ok(String)` - The developer JWT token
/// * `Err(AppleMusicError::DevTokenError)` - If scraping fails
///
/// # How it works
/// Uses multiple strategies in order:
/// 1. Scan the HTML page source for JWT tokens (eyJhbGciOi... pattern)
/// 2. Look for MusicKit.configure / developerToken assignments in script tags
/// 3. Parse the legacy meta tag `desktop-music-app/config/environment`
/// 4. Fetch linked JavaScript bundles and scan them for JWT tokens
pub async fn scrape_developer_token() -> Result<String> {
    let http = Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| AppleMusicError::DevTokenError(format!("Failed to create HTTP client: {}", e)))?;

    // Try primary URL, then fallback
    let urls = [WEB_PLAYER_URL, WEB_PLAYER_URL_FALLBACK];
    let mut last_err = String::new();

    for url in &urls {
        match fetch_web_player_html(&http, url).await {
            Ok(html) => {
                // Strategy 1: Scan HTML for JWT tokens directly
                if let Some(token) = extract_jwt_from_text(&html) {
                    log::info!("Found Apple Music developer token via JWT scan in page source from {}", url);
                    return Ok(token);
                }

                // Strategy 2: Look for MusicKit.configure / developerToken in script tags
                if let Some(token) = extract_token_from_musickit_config(&html) {
                    log::info!("Found Apple Music developer token via MusicKit config pattern from {}", url);
                    return Ok(token);
                }

                // Strategy 3: Legacy meta tag approach
                match extract_token_from_meta_tag(&html) {
                    Ok(token) => {
                        log::info!("Found Apple Music developer token via legacy meta tag from {}", url);
                        return Ok(token);
                    }
                    Err(e) => {
                        log::debug!("Meta tag extraction failed for {}: {}", url, e);
                    }
                }

                // Strategy 4: Fetch linked JS bundles and scan for JWT tokens
                match extract_token_from_js_bundles(&http, &html, url).await {
                    Ok(token) => {
                        log::info!("Found Apple Music developer token in JS bundle from {}", url);
                        return Ok(token);
                    }
                    Err(e) => {
                        log::debug!("JS bundle scanning failed for {}: {}", url, e);
                    }
                }

                // Log HTML preview for debugging
                let preview: String = html.chars().take(500).collect();
                log::warn!(
                    "All token extraction strategies failed for {}. HTML preview (first 500 chars): {}",
                    url, preview
                );
                last_err = format!("All extraction strategies failed for {}", url);
            }
            Err(e) => {
                log::warn!("Failed to fetch {}: {}", url, e);
                last_err = format!("{}: {}", url, e);
            }
        }
    }

    Err(AppleMusicError::DevTokenError(format!(
        "Failed to scrape developer token from all sources. Last error: {}",
        last_err
    )))
}

/// Current Chrome User-Agent string for web scraping requests.
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";

/// Fetch the Apple Music web player HTML from a given URL.
async fn fetch_web_player_html(http: &Client, url: &str) -> std::result::Result<String, String> {
    log::info!("Fetching Apple Music web player from {}", url);

    let response = http
        .get(url)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        .header("Accept-Language", "en-US,en;q=0.9")
        .send()
        .await
        .map_err(|e| format!("Failed to fetch web player: {:#}", e))?;

    if !response.status().is_success() {
        return Err(format!("Web player returned status {}", response.status()));
    }

    response
        .text()
        .await
        .map_err(|e| format!("Failed to read response body: {:#}", e))
}

/// Strategy 1: Scan text for Apple Music JWT tokens.
///
/// Apple developer tokens are JWTs starting with `eyJhbGciOi` (base64 for `{"alg":`)
/// and are typically 200+ characters long. We look for these in the page source
/// or JS bundle content.
fn extract_jwt_from_text(text: &str) -> Option<String> {
    let re = regex::Regex::new(
        r#"eyJhbGciOi[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
    )
    .ok()?;

    for m in re.find_iter(text) {
        let candidate = m.as_str();
        // Apple developer tokens are typically 200-800 chars; skip very short JWTs
        // (which might be other tokens) and very long ones (which might be user tokens)
        if candidate.len() >= 100 && candidate.len() <= 1500 {
            // Validate it looks like an Apple Music developer token by decoding the header
            if is_apple_music_developer_jwt(candidate) {
                return Some(candidate.to_string());
            }
        }
    }
    None
}

/// Check if a JWT is likely an Apple Music developer token.
///
/// Decodes the JWT header (first segment) to verify it contains expected fields
/// like `alg: "ES256"` which Apple uses for MusicKit tokens.
fn is_apple_music_developer_jwt(jwt: &str) -> bool {
    use base64::Engine;

    let parts: Vec<&str> = jwt.splitn(3, '.').collect();
    if parts.len() != 3 {
        return false;
    }

    // Decode the header (first part)
    let header_b64 = parts[0];
    // JWT uses base64url encoding (no padding)
    let engine = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let header_bytes = match engine.decode(header_b64) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let header_str = match std::str::from_utf8(&header_bytes) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let header: serde_json::Value = match serde_json::from_str(header_str) {
        Ok(v) => v,
        Err(_) => return false,
    };

    // Apple Music developer tokens use ES256 algorithm and have "kid" field
    let alg = header.get("alg").and_then(|v| v.as_str()).unwrap_or("");
    let has_kid = header.get("kid").is_some();

    (alg == "ES256" && has_kid) || alg == "ES256"
}

/// Strategy 2: Look for MusicKit.configure or developerToken assignments in HTML.
///
/// Apple's web player may configure MusicKit with patterns like:
/// - `MusicKit.configure({developerToken: "..."})`
/// - `developerToken:"..."`
/// - `"developerToken":"..."`
/// - `token:"eyJhbGciOi..."`
fn extract_token_from_musickit_config(html: &str) -> Option<String> {
    // Pattern 1: MusicKit.configure({ developerToken: "..." })
    // Pattern 2: developerToken: "..." or "developerToken":"..."
    // Pattern 3: token assignments with JWT values
    let patterns = [
        r#"developerToken\s*[:=]\s*["']([^"']+)["']"#,
        r#"developer-token\s*[:=]\s*["']([^"']+)["']"#,
        r#""developerToken"\s*:\s*"([^"]+)""#,
        r#"MusicKit\.configure\s*\(\s*\{[^}]*?developerToken\s*:\s*["']([^"']+)["']"#,
        r#"data-developer-token\s*=\s*["']([^"']+)["']"#,
    ];

    for pattern in &patterns {
        if let Ok(re) = regex::Regex::new(pattern) {
            if let Some(caps) = re.captures(html) {
                if let Some(token) = caps.get(1) {
                    let t = token.as_str();
                    if t.starts_with("eyJhbGciOi") && t.len() >= 100 {
                        log::debug!("Found token via MusicKit config pattern: {}", pattern);
                        return Some(t.to_string());
                    }
                }
            }
        }
    }
    None
}

/// Strategy 3: Legacy meta tag extraction (original approach).
///
/// Looks for:
/// ```html
/// <meta name="desktop-music-app/config/environment" content="%7B...%7D">
/// ```
/// The content is URL-encoded JSON containing `MEDIA_API.token`.
fn extract_token_from_meta_tag(html: &str) -> Result<String> {
    // Try both the original pattern and a more relaxed version
    let patterns = [
        r#"<meta\s+name=["']desktop-music-app/config/environment["']\s+content=["']([^"']+)["']"#,
        r#"content=["']([^"']+)["']\s+name=["']desktop-music-app/config/environment["']"#,
    ];

    let mut encoded_content: Option<String> = None;
    for pattern in &patterns {
        if let Ok(re) = regex::Regex::new(pattern) {
            if let Some(caps) = re.captures(html) {
                if let Some(m) = caps.get(1) {
                    encoded_content = Some(m.as_str().to_string());
                    break;
                }
            }
        }
    }

    let encoded = encoded_content.ok_or_else(|| {
        AppleMusicError::DevTokenError(
            "Meta tag 'desktop-music-app/config/environment' not found.".to_string(),
        )
    })?;

    // URL-decode the content
    let decoded = urlencoding::decode(&encoded).map_err(|e| {
        AppleMusicError::DevTokenError(format!("Failed to URL-decode meta content: {}", e))
    })?;

    // Parse as JSON and extract token from multiple possible paths
    let config: serde_json::Value = serde_json::from_str(&decoded).map_err(|e| {
        AppleMusicError::DevTokenError(format!("Failed to parse config JSON: {}", e))
    })?;

    // Try multiple JSON paths for the token
    let token = config
        .get("MEDIA_API")
        .and_then(|api| api.get("token"))
        .and_then(|t| t.as_str())
        .or_else(|| {
            config
                .get("MEDIA_API")
                .and_then(|api| api.get("developerToken"))
                .and_then(|t| t.as_str())
        })
        .or_else(|| {
            config
                .get("mediaApi")
                .and_then(|api| api.get("token"))
                .and_then(|t| t.as_str())
        })
        .ok_or_else(|| {
            let keys: Vec<String> = config
                .as_object()
                .map(|obj| obj.keys().cloned().collect())
                .unwrap_or_default();
            AppleMusicError::DevTokenError(format!(
                "Token not found in config JSON. Top-level keys: {:?}",
                keys
            ))
        })?;

    Ok(token.to_string())
}

/// Strategy 4: Fetch linked JavaScript bundles and scan them for JWT tokens.
///
/// Apple's web player loads JS bundles that may contain the developer token.
/// We extract `<script src="...">` URLs from the HTML and fetch them.
async fn extract_token_from_js_bundles(
    http: &Client,
    html: &str,
    base_url: &str,
) -> std::result::Result<String, String> {
    // Find script src URLs in the HTML
    let re = regex::Regex::new(r#"<script[^>]+src=["']([^"']+)["']"#)
        .map_err(|e| format!("Regex error: {}", e))?;

    let mut js_urls: Vec<String> = Vec::new();
    for caps in re.captures_iter(html) {
        if let Some(src) = caps.get(1) {
            let src_str = src.as_str();
            // Prioritize bundle/chunk JS files that likely contain config
            let url = if src_str.starts_with("http") {
                src_str.to_string()
            } else if src_str.starts_with("//") {
                format!("https:{}", src_str)
            } else if src_str.starts_with('/') {
                format!("{}{}", base_url.trim_end_matches('/'), src_str)
            } else {
                format!("{}/{}", base_url.trim_end_matches('/'), src_str)
            };
            js_urls.push(url);
        }
    }

    // Also look for modulepreload links which may contain the token
    let link_re = regex::Regex::new(r#"<link[^>]+rel=["']modulepreload["'][^>]+href=["']([^"']+)["']"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    for caps in link_re.captures_iter(html) {
        if let Some(href) = caps.get(1) {
            let href_str = href.as_str();
            let url = if href_str.starts_with("http") {
                href_str.to_string()
            } else if href_str.starts_with("//") {
                format!("https:{}", href_str)
            } else if href_str.starts_with('/') {
                format!("{}{}", base_url.trim_end_matches('/'), href_str)
            } else {
                format!("{}/{}", base_url.trim_end_matches('/'), href_str)
            };
            js_urls.push(url);
        }
    }

    log::debug!("Found {} JS bundle URLs to scan for tokens", js_urls.len());

    // Limit to first 15 bundles to avoid excessive requests
    let max_bundles = 15;
    for (i, url) in js_urls.iter().take(max_bundles).enumerate() {
        log::debug!("Scanning JS bundle {}/{}: {}", i + 1, js_urls.len().min(max_bundles), url);

        match http
            .get(url)
            .header("User-Agent", USER_AGENT)
            .header("Referer", base_url)
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(js_text) = resp.text().await {
                    if let Some(token) = extract_jwt_from_text(&js_text) {
                        return Ok(token);
                    }
                    // Also try MusicKit config patterns in JS
                    if let Some(token) = extract_token_from_musickit_config(&js_text) {
                        return Ok(token);
                    }
                }
            }
            Ok(resp) => {
                log::debug!("JS bundle {} returned status {}", url, resp.status());
            }
            Err(e) => {
                log::debug!("Failed to fetch JS bundle {}: {}", url, e);
            }
        }
    }

    Err(format!(
        "No developer token found in {} JS bundles",
        js_urls.len().min(max_bundles)
    ))
}

// ============================================================================
// Apple Music API Client
// ============================================================================

/// Apple Music API client.
///
/// Unlike Spotify/SoundCloud, this client does NOT use OAuth2 or token refresh.
/// The developer token is scraped from Apple's web player, and the user token
/// is obtained via MusicKit JS in a webview. User tokens last ~180 days.
pub struct AppleMusicClient {
    http: Client,
    /// Developer JWT token (scraped from web player).
    dev_token: String,
    /// Music User Token (from MusicKit JS authorize).
    user_token: String,
    /// User's storefront/region (cached after first lookup).
    storefront: Option<String>,
    /// User identifier for database operations.
    user_id: String,
}

impl AppleMusicClient {
    /// Create a new Apple Music client for the given user.
    ///
    /// Scrapes a fresh developer token and loads the stored user token.
    /// Fails if no user token is stored (user must authenticate first).
    ///
    /// # Arguments
    /// * `user_id` - User identifier (typically "default")
    ///
    /// # Returns
    /// * `Ok(AppleMusicClient)` - Ready to make API calls
    /// * `Err(AppleMusicError)` - If token scraping or retrieval fails
    pub async fn new(user_id: &str) -> Result<Self> {
        // Scrape fresh developer token
        let dev_token = scrape_developer_token().await?;

        // Load stored user token
        let user_token = token_storage::get_refresh_token("apple_music", user_id)
            .map_err(|e| match e {
                token_storage::TokenStorageError::TokenNotFound(_, _) => {
                    AppleMusicError::UserTokenMissing
                }
                other => AppleMusicError::StorageError(other),
            })?;

        Ok(Self {
            http: Client::builder()
                .timeout(Duration::from_secs(30))
                .build()?,
            dev_token,
            user_token,
            storefront: None,
            user_id: user_id.to_string(),
        })
    }

    /// Make an authenticated GET request to the Apple Music API.
    ///
    /// Adds required headers:
    /// - `Authorization: Bearer <dev_token>`
    /// - `Music-User-Token: <user_token>`
    /// - `Origin: https://music.apple.com`
    ///
    /// Handles:
    /// - 429 Too Many Requests (rate limiting)
    /// - 401 Unauthorized (expired user token)
    /// - Other error status codes
    async fn get(&self, url: &str) -> Result<reqwest::Response> {
        let response = self
            .http
            .get(url)
            .header("Authorization", format!("Bearer {}", self.dev_token))
            .header("Music-User-Token", &self.user_token)
            .header("Origin", "https://music.apple.com")
            .send()
            .await?;

        match response.status() {
            StatusCode::TOO_MANY_REQUESTS => {
                let retry_after = response
                    .headers()
                    .get("Retry-After")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(30);
                Err(AppleMusicError::RateLimited(retry_after))
            }
            StatusCode::UNAUTHORIZED => {
                Err(AppleMusicError::ApiError {
                    status: 401,
                    message: "User token expired. Please re-authenticate with Apple Music.".to_string(),
                })
            }
            status if !status.is_success() => {
                let body = response.text().await.unwrap_or_default();
                Err(AppleMusicError::ApiError {
                    status: status.as_u16(),
                    message: body.chars().take(200).collect(),
                })
            }
            _ => Ok(response),
        }
    }

    /// Get the user's storefront (region), cached after first call.
    ///
    /// # Returns
    /// * `Ok(String)` - Storefront ID (e.g., "us", "gb", "jp")
    pub async fn get_storefront(&mut self) -> Result<String> {
        if let Some(ref sf) = self.storefront {
            return Ok(sf.clone());
        }

        let url = format!("{}/v1/me/storefront", API_BASE);
        let response = self.get(&url).await?;
        let data: StorefrontResponse = response.json().await?;

        let sf = data
            .data
            .into_iter()
            .next()
            .map(|s| s.id)
            .ok_or_else(|| {
                AppleMusicError::ApiError {
                    status: 200,
                    message: "No storefront returned".to_string(),
                }
            })?;

        self.storefront = Some(sf.clone());
        Ok(sf)
    }

    /// Check if the stored user token is still valid.
    ///
    /// Makes a lightweight storefront API call to verify the token works.
    ///
    /// # Returns
    /// * `true` if the token is valid
    /// * `false` if the token is expired or invalid
    pub async fn check_token_valid(&self) -> bool {
        let url = format!("{}/v1/me/storefront", API_BASE);
        match self.get(&url).await {
            Ok(response) => response.status().is_success(),
            Err(_) => false,
        }
    }

    /// Sync user's library songs incrementally.
    ///
    /// Fetches library songs added since the last sync and stores them
    /// in the database with source tracking via `track_sources` table.
    ///
    /// # Arguments
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(SyncCounts)` - Counts of found, added, and skipped tracks
    /// * `Err(AppleMusicError)` - If API call or database operation fails
    pub async fn sync_library_songs(&mut self, conn: &Connection) -> Result<crate::models::SyncCounts> {
        // Get last sync timestamp
        let last_sync = get_last_sync_timestamp(conn, &self.user_id, "apple_music")?
            .unwrap_or_else(|| {
                // Default to 1 year ago for initial sync
                (Utc::now() - TimeDelta::days(365)).to_rfc3339()
            });

        let last_sync_dt =
            DateTime::parse_from_rfc3339(&last_sync).unwrap_or_else(|_| Utc::now().into());

        let mut counts = crate::models::SyncCounts::default();
        let mut next_url = Some(format!(
            "{}/v1/me/library/songs?limit={}",
            API_BASE, PAGE_SIZE
        ));
        let mut tracks_to_insert: Vec<AppleMusicSyncedTrack> = Vec::new();

        // Paginate through all library songs
        while let Some(ref url) = next_url {
            let response = self.get(url).await?;
            let data: AppleMusicResponse<LibrarySong> = response.json().await?;

            for song in &data.data {
                let synced = AppleMusicSyncedTrack::from(song);
                counts.found += 1;

                // Check if this song was added after last sync
                if let Ok(added_dt) = DateTime::parse_from_rfc3339(&synced.added_at) {
                    if added_dt <= last_sync_dt {
                        // Apple Music library songs are NOT guaranteed to be in
                        // reverse chronological order, so we can't break early.
                        // We must scan all pages but skip old tracks.
                        counts.skipped += 1;
                        continue;
                    }
                }

                tracks_to_insert.push(synced);
                counts.added += 1;
            }

            // Follow pagination
            next_url = data.next.map(|next| {
                if next.starts_with('/') {
                    format!("{}{}", API_BASE, next)
                } else {
                    next
                }
            });
        }

        // Insert tracks into database
        if !tracks_to_insert.is_empty() {
            insert_synced_tracks(conn, &self.user_id, &tracks_to_insert)?;
        }

        // Update last sync timestamp
        set_last_sync_timestamp(conn, &self.user_id, "apple_music", &Utc::now().to_rfc3339())?;

        Ok(counts)
    }

    /// Sync user's library playlists.
    ///
    /// Fetches all playlists and their tracks, creating/updating them
    /// in the local database.
    ///
    /// # Arguments
    /// * `conn` - Database connection
    ///
    /// # Returns
    /// * `Ok(count)` - Number of playlists synced
    /// * `Err(AppleMusicError)` - If API call or database operation fails
    pub async fn sync_playlists(&mut self, conn: &Connection) -> Result<usize> {
        let source_id = ensure_source_exists(conn, &self.user_id, "apple_music")?;

        let mut playlist_count = 0;
        let mut next_url = Some(format!(
            "{}/v1/me/library/playlists?limit={}",
            API_BASE, PAGE_SIZE
        ));

        // Fetch all playlists
        let mut all_playlists: Vec<LibraryPlaylist> = Vec::new();
        while let Some(ref url) = next_url {
            let response = self.get(url).await?;
            let data: AppleMusicResponse<LibraryPlaylist> = response.json().await?;
            all_playlists.extend(data.data);
            next_url = data.next.map(|next| {
                if next.starts_with('/') {
                    format!("{}{}", API_BASE, next)
                } else {
                    next
                }
            });
        }

        // Process each playlist
        for playlist in all_playlists {
            let external_id = format!("apple_music:playlist:{}", playlist.id);
            let playlist_name = playlist.attributes.name.clone();
            let description = playlist
                .attributes
                .description
                .as_ref()
                .and_then(|d| d.standard.clone());

            // Get or create local playlist
            use crate::database::playlist::create_playlist;
            use crate::models::PlaylistCategory;

            // Check if playlist already exists by external_id
            let existing_playlist_id: Option<i64> = conn
                .query_row(
                    "SELECT id FROM playlists WHERE external_id = ?",
                    [&external_id],
                    |row| row.get(0),
                )
                .optional()?;

            let local_playlist_id = if let Some(id) = existing_playlist_id {
                id
            } else {
                let id = create_playlist(
                    conn,
                    playlist_name,
                    description,
                    vec![],
                    PlaylistCategory::Regular,
                )?;
                // Set external_id and source_id
                conn.execute(
                    "UPDATE playlists SET external_id = ?, source_id = ? WHERE id = ?",
                    rusqlite::params![external_id, source_id, id],
                )?;
                id
            };

            // Fetch tracks for this playlist
            let mut tracks_next_url = Some(format!(
                "{}/v1/me/library/playlists/{}/tracks?limit={}",
                API_BASE, playlist.id, PAGE_SIZE
            ));

            while let Some(ref url) = tracks_next_url {
                let response = self.get(url).await?;
                let data: AppleMusicResponse<LibrarySong> = response.json().await?;

                for song in &data.data {
                    let synced = AppleMusicSyncedTrack::from(song);
                    let track_id = find_or_create_track(conn, &synced, source_id)?;

                    // Add to playlist (ignore if already present)
                    use crate::database::playlist::add_track_to_playlist;
                    let _ = add_track_to_playlist(conn, local_playlist_id, track_id);
                }

                tracks_next_url = data.next.map(|next| {
                    if next.starts_with('/') {
                        format!("{}{}", API_BASE, next)
                    } else {
                        next
                    }
                });
            }

            playlist_count += 1;
        }

        Ok(playlist_count)
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
        Err(e) => Err(AppleMusicError::DatabaseError(e)),
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
    let result = conn.query_row(
        "SELECT id FROM sources WHERE name = ? AND user_id = ?",
        [source_name, user_id],
        |row| row.get(0),
    );

    match result {
        Ok(id) => Ok(id),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            conn.execute(
                "INSERT INTO sources (name, user_id, enabled) VALUES (?, ?, 1)",
                [source_name, user_id],
            )?;
            Ok(conn.last_insert_rowid())
        }
        Err(e) => Err(AppleMusicError::DatabaseError(e)),
    }
}

/// Insert synced tracks into database with source tracking.
fn insert_synced_tracks(
    conn: &Connection,
    user_id: &str,
    tracks: &[AppleMusicSyncedTrack],
) -> Result<()> {
    let source_id = ensure_source_exists(conn, user_id, "apple_music")?;

    for track in tracks {
        let external_id = format!("apple_music:{}", track.apple_music_id);

        // Check if track already exists by external_id
        let existing: Option<i64> = conn
            .query_row(
                "SELECT track_id FROM track_sources WHERE external_id = ?",
                [&external_id],
                |row| row.get(0),
            )
            .optional()?;

        if existing.is_some() {
            // Track already synced from this source, skip
            continue;
        }

        // Insert into tracks table (phantom track)
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, duration, date_added)
             VALUES (?, ?, ?, ?, 'apple_music', ?, ?, ?)",
            rusqlite::params![
                &track.artist,
                &track.artist,
                &track.album,
                &track.title,
                &external_id,
                track.duration_secs as i64,
                &track.added_at,
            ],
        )?;

        let track_id = conn.last_insert_rowid();

        // Insert into track_sources
        conn.execute(
            "INSERT INTO track_sources (track_id, source_id, external_id, added_at)
             VALUES (?, ?, ?, ?)",
            rusqlite::params![track_id, source_id, &external_id, &track.added_at],
        )?;
    }

    Ok(())
}

/// Find or create a track in the library with deduplication.
///
/// Searches for existing track by external_id first, then by similarity.
/// If found, returns existing track_id. Otherwise creates new phantom track.
fn find_or_create_track(
    conn: &Connection,
    track: &AppleMusicSyncedTrack,
    source_id: i64,
) -> Result<i64> {
    let external_id = format!("apple_music:{}", track.apple_music_id);

    // First, check if track already exists by external_id
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

    // Check for duplicate by similarity (use dedup module)
    use crate::dedup::calculate_similarity;

    let similar: Option<i64> = conn
        .query_row(
            "SELECT id, title, artist FROM tracks
             WHERE title LIKE ? OR artist LIKE ?
             LIMIT 50",
            rusqlite::params![
                format!("%{}%", &track.title[..track.title.len().min(10)]),
                format!("%{}%", &track.artist[..track.artist.len().min(10)])
            ],
            |row| {
                let id: i64 = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;

                let similarity =
                    calculate_similarity(&track.title, &track.artist, &title, &artist);
                if similarity >= 0.85 {
                    Ok(Some(id))
                } else {
                    Ok(None)
                }
            },
        )
        .optional()?
        .flatten();

    if let Some(track_id) = similar {
        // Found similar track, create track_sources relationship
        conn.execute(
            "INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at)
             VALUES (?, ?, ?, ?)",
            rusqlite::params![track_id, source_id, &external_id, &track.added_at],
        )?;
        return Ok(track_id);
    }

    // No existing track found, create new phantom track
    conn.execute(
        "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, duration, date_added)
         VALUES (?, ?, ?, ?, 'apple_music', ?, ?, ?)",
        rusqlite::params![
            &track.artist,
            &track.artist,
            &track.album,
            &track.title,
            &external_id,
            track.duration_secs as i64,
            &track.added_at,
        ],
    )?;

    let track_id = conn.last_insert_rowid();

    // Insert into track_sources
    conn.execute(
        "INSERT INTO track_sources (track_id, source_id, external_id, added_at)
         VALUES (?, ?, ?, ?)",
        rusqlite::params![track_id, source_id, &external_id, &track.added_at],
    )?;

    Ok(track_id)
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_apple_music_error_display() {
        let err = AppleMusicError::DevTokenError("test error".to_string());
        assert_eq!(
            format!("{}", err),
            "Failed to scrape developer token: test error"
        );

        let err = AppleMusicError::UserTokenMissing;
        assert!(format!("{}", err).contains("re-authenticate"));

        let err = AppleMusicError::RateLimited(30);
        assert!(format!("{}", err).contains("30"));
    }

    #[test]
    fn test_external_id_format() {
        let id = "i.abcdef1234567890";
        let external_id = format!("apple_music:{}", id);
        assert_eq!(external_id, "apple_music:i.abcdef1234567890");
    }

    #[test]
    fn test_synced_track_from_library_song() {
        let song = LibrarySong {
            id: "i.abc123".to_string(),
            attributes: LibrarySongAttributes {
                name: "Test Song".to_string(),
                artist_name: "Test Artist".to_string(),
                album_name: "Test Album".to_string(),
                duration_in_millis: Some(240000),
                date_added: Some("2024-01-15T10:30:00Z".to_string()),
                genre_names: vec!["Electronic".to_string()],
                play_params: None,
            },
        };

        let synced = AppleMusicSyncedTrack::from(&song);
        assert_eq!(synced.apple_music_id, "i.abc123");
        assert_eq!(synced.title, "Test Song");
        assert_eq!(synced.artist, "Test Artist");
        assert_eq!(synced.album, "Test Album");
        assert_eq!(synced.duration_secs, 240);
        assert_eq!(synced.added_at, "2024-01-15T10:30:00Z");
        assert_eq!(synced.genre, Some("Electronic".to_string()));
    }

    #[test]
    fn test_synced_track_missing_duration() {
        let song = LibrarySong {
            id: "i.xyz789".to_string(),
            attributes: LibrarySongAttributes {
                name: "No Duration".to_string(),
                artist_name: "Artist".to_string(),
                album_name: "Album".to_string(),
                duration_in_millis: None,
                date_added: None,
                genre_names: vec![],
                play_params: None,
            },
        };

        let synced = AppleMusicSyncedTrack::from(&song);
        assert_eq!(synced.duration_secs, 0);
        assert_eq!(synced.genre, None);
        // added_at should default to now (non-empty)
        assert!(!synced.added_at.is_empty());
    }

    #[test]
    fn test_deserialize_library_song() {
        let json = r#"{
            "id": "i.abcdef1234567890",
            "attributes": {
                "name": "Strobe",
                "artistName": "deadmau5",
                "albumName": "For Lack of a Better Name",
                "durationInMillis": 637000,
                "dateAdded": "2023-06-15T12:00:00Z",
                "genreNames": ["Electronic", "Dance"],
                "playParams": {
                    "id": "i.abcdef1234567890",
                    "catalogId": "326832530",
                    "kind": "song"
                }
            }
        }"#;

        let song: LibrarySong = serde_json::from_str(json).unwrap();
        assert_eq!(song.id, "i.abcdef1234567890");
        assert_eq!(song.attributes.name, "Strobe");
        assert_eq!(song.attributes.artist_name, "deadmau5");
        assert_eq!(song.attributes.duration_in_millis, Some(637000));
        assert_eq!(song.attributes.genre_names.len(), 2);
        assert!(song.attributes.play_params.is_some());
        let pp = song.attributes.play_params.unwrap();
        assert_eq!(pp.catalog_id.unwrap(), "326832530");
    }

    #[test]
    fn test_deserialize_library_playlist() {
        let json = r#"{
            "id": "p.abc123",
            "attributes": {
                "name": "My Playlist",
                "description": {
                    "standard": "A great playlist"
                },
                "lastModifiedDate": "2024-01-20T15:30:00Z",
                "dateAdded": "2024-01-01T00:00:00Z"
            }
        }"#;

        let playlist: LibraryPlaylist = serde_json::from_str(json).unwrap();
        assert_eq!(playlist.id, "p.abc123");
        assert_eq!(playlist.attributes.name, "My Playlist");
        assert_eq!(
            playlist.attributes.description.unwrap().standard.unwrap(),
            "A great playlist"
        );
    }

    #[test]
    fn test_deserialize_paginated_response() {
        let json = r#"{
            "data": [
                {
                    "id": "i.song1",
                    "attributes": {
                        "name": "Song 1",
                        "artistName": "Artist 1",
                        "albumName": "Album 1",
                        "durationInMillis": 180000,
                        "genreNames": ["Pop"]
                    }
                }
            ],
            "next": "/v1/me/library/songs?offset=100&limit=100"
        }"#;

        let response: AppleMusicResponse<LibrarySong> = serde_json::from_str(json).unwrap();
        assert_eq!(response.data.len(), 1);
        assert_eq!(response.data[0].id, "i.song1");
        assert!(response.next.is_some());
        assert!(response.next.unwrap().contains("offset=100"));
    }

    #[test]
    fn test_deserialize_paginated_response_no_next() {
        let json = r#"{
            "data": []
        }"#;

        let response: AppleMusicResponse<LibrarySong> = serde_json::from_str(json).unwrap();
        assert!(response.data.is_empty());
        assert!(response.next.is_none());
    }

    #[test]
    fn test_deserialize_storefront() {
        let json = r#"{
            "data": [
                {"id": "us"}
            ]
        }"#;

        let response: StorefrontResponse = serde_json::from_str(json).unwrap();
        assert_eq!(response.data[0].id, "us");
    }

    #[tokio::test]
    #[ignore] // Requires network access — canary test for Apple web player changes
    async fn test_scrape_developer_token() {
        let result = scrape_developer_token().await;
        match result {
            Ok(token) => {
                assert!(!token.is_empty());
                // JWT tokens have 3 parts separated by dots
                assert_eq!(token.split('.').count(), 3, "Token should be a JWT");
                println!("Developer token scraped successfully ({} chars)", token.len());
            }
            Err(e) => {
                panic!("Failed to scrape developer token: {}", e);
            }
        }
    }
}
