 Here is Claude's plan:
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Apple Music Integration Plan

 Context

 Add Apple Music as a third music source alongside Spotify and SoundCloud. Uses the reverse-engineered approach (scrape developer token from Apple's web player, MusicKit JS for user auth) to avoid the $99/year Apple
 Developer Program fee. This follows established patterns from the existing source integrations.

 Key architectural difference: No OAuth2 flow. Developer token is scraped from beta.music.apple.com HTML. User token is obtained via MusicKit JS authorize() in a Tauri webview window. No refresh tokens — user token lasts
 ~180 days, then re-auth required.

 ---
 Files to Create

 1. src-tauri/src/sources/apple_music.rs (NEW, ~700-900 lines)

 Follows the exact structure of spotify.rs / soundcloud.rs:

 Error type: AppleMusicError with variants: DevTokenError, UserTokenMissing, HttpError, RateLimited, ApiError, DatabaseError, JsonError, StorageError, ParseError

 API response structs (deserialize amp-api.music.apple.com JSON):
 - AppleMusicResponse<T> — generic paginated response with data: Vec<T> and next: Option<String>
 - LibrarySong / LibrarySongAttributes — library song resource (name, artistName, albumName, durationInMillis, dateAdded, genreNames, playParams)
 - LibraryPlaylist / LibraryPlaylistAttributes — library playlist resource
 - Storefront / StorefrontResponse — user's region
 - AppleMusicSyncedTrack — intermediate struct for DB insertion (mirrors SyncedTrack pattern)

 Developer token scraping:
 - pub async fn scrape_developer_token() -> Result<String>
 - Fetch https://beta.music.apple.com HTML
 - Regex parse <meta name="desktop-music-app/config/environment" content="..."> tag
 - URL-decode the content attribute, parse as JSON, extract MEDIA_API.token
 - Uses existing reqwest + regex + urlencoding crates (zero new deps)

 API client:
 - AppleMusicClient struct with http, dev_token, user_token, storefront fields
 - new(user_id) — scrapes fresh dev token, loads stored user token from .tokens/
 - get(url) — authenticated GET with headers: Authorization: Bearer <dev_token>, Music-User-Token: <user_token>, Origin: https://music.apple.com. Handles 429 (rate limit) and 401 (expired token).
 - No TokenManager — no refresh mechanism exists. 401 = user must re-auth.

 Sync methods:
 - sync_library_songs(&mut self, conn) -> Result<usize> — paginate GET /v1/me/library/songs?limit=100, dedup via track_sources.external_id then Jaro-Winkler, insert phantom tracks with format = "apple_music", external_id =
 "apple_music:{id}"
 - sync_playlists(&mut self, user_id, conn) -> Result<usize> — fetch GET /v1/me/library/playlists, then tracks per playlist via GET /v1/me/library/playlists/{id}/tracks
 - get_storefront(&mut self) -> Result<String> — GET /v1/me/storefront, cached after first call
 - check_token_valid(&self) -> bool — lightweight storefront call to verify token

 Database operations: Reuse existing patterns from spotify.rs:
 - ensure_source_exists(conn, user_id, "apple_music")
 - find_or_create_track() with external_id check then fuzzy match
 - get_last_sync_timestamp / set_last_sync_timestamp for incremental sync

 2. ui/public/apple-music-auth.html (NEW, ~80 lines)

 Standalone HTML page loaded in the MusicKit auth webview window:
 - Reads devToken from URL query param
 - Loads MusicKit JS v3 from https://js-cdn.music.apple.com/musickit/v3/musickit.js
 - Configures MusicKit with the scraped developer token
 - Calls MusicKit.getInstance().authorize() — opens Apple's login popup
 - On success, emits apple-music-auth-complete event via window.__TAURI__.event.emit() with the user token
 - Auto-closes the window after success
 - Shows status messages and error states
 - Styled to match app theme (dark background)

 ---
 Files to Modify

 3. src-tauri/src/sources/mod.rs

 Add:
 pub mod apple_music;
 pub use apple_music::{AppleMusicClient, AppleMusicError, scrape_developer_token};

 4. src-tauri/src/commands/sources.rs

 Add 5 new Tauri commands (no OAuthState needed — no PKCE):

 - apple_music_get_dev_token() -> Result<String, String> — calls scrape_developer_token(), returns JWT for frontend
 - apple_music_store_user_token(user_token, user_id) -> Result<(), String> — stores via existing store_refresh_token("apple_music", user_id, token)
 - apple_music_check_connected(user_id) -> Result<bool, String> — checks if token file exists AND makes lightweight API call to verify it still works
 - sync_apple_music(user_id) -> Result<SyncResponse, String> — creates AppleMusicClient, runs sync_library_songs, returns SyncResponse { added, source: "apple_music" }
 - disconnect_apple_music(user_id) -> Result<(), String> — calls delete_token("apple_music", user_id)

 5. src-tauri/src/commands/mod.rs

 Add to re-exports:
 pub use sources::{
     // ... existing ...
     apple_music_get_dev_token, apple_music_store_user_token,
     apple_music_check_connected, sync_apple_music, disconnect_apple_music,
 };

 6. src-tauri/src/lib.rs

 Register new commands in invoke_handler (after line 155):
 commands::sources::apple_music_get_dev_token,
 commands::sources::apple_music_store_user_token,
 commands::sources::apple_music_check_connected,
 commands::sources::sync_apple_music,
 commands::sources::disconnect_apple_music,

 7. src-tauri/src/startup.rs

 Add Apple Music auto-sync block after the SoundCloud block (~line 141). Unlike Spotify/SoundCloud, no env var check needed — just attempt to create AppleMusicClient::new("default") which will fail gracefully if no stored
 user token exists.

 8. ui/src/utils/tauri-commands.ts

 Add in "Source Connection Commands" section:
 - apple_music_get_dev_token(): Promise<string>
 - apple_music_store_user_token(userToken, userId): Promise<void>
 - apple_music_check_connected(userId): Promise<boolean>
 - sync_apple_music(userId): Promise<SyncResponse>
 - disconnect_apple_music(userId): Promise<void>

 9. ui/src/pages/Sources.tsx

 Add Apple Music as third source card:

 State: const [appleMusic, setAppleMusic] = useState<SourceState>({ status: "disconnected" })

 Connection check: Add apple_music_check_connected("default") to checkConnections()

 Connect handler (different from Spotify/SoundCloud — no browser redirect):
 1. Call apple_music_get_dev_token() to get scraped JWT
 2. Open WebviewWindow("apple-music-auth", { url: "/apple-music-auth.html?devToken=..." })
 3. Listen for apple-music-auth-complete event
 4. On receive, call apple_music_store_user_token(token, "default")

 Sync/disconnect handlers: Follow exact Spotify/SoundCloud pattern.

 JSX: Add <SourceCard name="Apple Music" ... /> with Apple Music icon (pink/red gradient SVG).

 ---
 No Changes Needed

 - Cargo.toml — zero new dependencies (reqwest, regex, urlencoding, serde, chrono all already present)
 - Database schema — existing tables handle it: sources.name = 'apple_music', track_sources.external_id = 'apple_music:{id}', tracks.format = 'apple_music'
 - token_storage.rs — reuse as-is with source = "apple_music" (stores user token in .tokens/apple_music_default_refresh.token)
 - token_refresh.rs — NOT used (no refresh mechanism for Apple Music)
 - tauri.conf.json — CSP is already null, no changes needed for loading MusicKit JS from Apple CDN

 ---
 Auth Flow Sequence

 User clicks "Connect Apple Music"
   -> Frontend: apple_music_get_dev_token()
   -> Backend: HTTP GET beta.music.apple.com, parse meta tag, return JWT
   -> Frontend: Open WebviewWindow with apple-music-auth.html?devToken=...
   -> Auth window: Load MusicKit JS, configure, call authorize()
   -> Apple login popup appears in webview
   -> User signs in with Apple ID + 2FA
   -> MusicKit returns Music User Token (~180 day lifetime)
   -> Auth window: emit("apple-music-auth-complete", { userToken })
   -> Main window: listen receives event
   -> Frontend: apple_music_store_user_token(token, "default")
   -> Backend: write to .tokens/apple_music_default_refresh.token
   -> UI updates to "connected"

 ---
 Risk Mitigations

 ┌───────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │             Risk              │                                                        Mitigation                                                        │
 ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Apple changes web player HTML │ Clear error message: "Meta tag not found. Apple may have changed their web player." Regex targets stable name attribute. │
 ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ User token expires (401)      │ sync_apple_music propagates clear error. User clicks "Connect" to re-auth. Frontend shows error state on SourceCard.     │
 ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ MusicKit JS CDN unavailable   │ Auth window shows error message. User can retry later.                                                                   │
 ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Rate limiting (429)           │ Return RateLimited(retry_after) error. Initial impl surfaces as error; backoff can be added later.                       │
 ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ amp-api endpoint changes      │ Same class of risk as token scraping. Error messages identify the failing endpoint.                                      │
 └───────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 ---
 Verification

 1. Unit tests: JSON deserialization of sample LibrarySong/LibraryPlaylist responses, AppleMusicError display, external_id format
 2. Integration test (#[ignore]): test_scrape_developer_token — live scrape against current Apple web player (canary for breakage)
 3. Manual E2E: Connect flow -> Auth window opens -> Apple login -> token stored -> Sync -> tracks appear in library -> Disconnect -> token removed -> Re-connect works
 4. Startup auto-sync: App launches, Apple Music syncs silently if token exists, logs warning if token expired
 5. Build: cargo build passes, npm run build passes, no new warnings

