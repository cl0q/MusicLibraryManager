//! App startup tasks including auto-sync.
//!
//! Implements locked decision from CONTEXT.md: "Auto-sync on app open"
//!
//! On app startup, silently syncs Spotify and SoundCloud libraries
//! if credentials are configured. Failures are logged as warnings
//! and do not block app startup.
//!
//! # Behavior
//!
//! - Checks for SPOTIFY_CLIENT_ID/SECRET in environment
//! - If present, creates SpotifyClient and runs incremental sync
//! - Checks for SOUNDCLOUD_CLIENT_ID/SECRET in environment
//! - If present, creates SoundCloudClient and runs incremental sync
//! - All errors are caught and logged, never propagated


use crate::config::LibraryConfig;
use crate::database::{get_connection, initialize_schema};
use crate::database::playlist::{create_smart_playlists, create_local_likes_playlist};
use crate::mount::{MountDetector, LibraryMountState};
use crate::sources::soundcloud::SoundCloudClient;
use crate::sources::spotify::SpotifyClient;
use tauri::{Emitter, Manager};

/// Default user ID for startup sync.
///
/// In a single-user desktop app, this is the default user context.
/// When multi-user support is added (Phase 6+), this should come from
/// app configuration or last-logged-in user state.
const DEFAULT_USER_ID: &str = "default";

/// Initialize database and playlists on startup.
///
/// Runs before async sync tasks to ensure database schema and
/// smart playlists are ready. Called synchronously.
///
/// Tasks:
/// - Initialize database schema (idempotent)
/// - Create smart playlists (Recently Added, Most Played)
/// - Create Local Likes playlist
///
/// This function logs warnings on failure but doesn't propagate errors.
pub fn initialize_on_startup() {
    log::info!("Initializing database and playlists...");

    let db_path = crate::database::db_path();
    let mut conn = match get_connection(&db_path) {
        Ok(c) => c,
        Err(e) => {
            log::error!("Failed to connect to database: {}", e);
            return;
        }
    };

    // Initialize schema (idempotent)
    if let Err(e) = initialize_schema(&mut conn) {
        log::error!("Failed to initialize schema: {}", e);
        return;
    }

    // Create smart playlists (idempotent)
    if let Err(e) = create_smart_playlists(&conn) {
        log::warn!("Failed to create smart playlists: {}", e);
    } else {
        log::info!("Smart playlists initialized");
    }

    // Create Local Likes playlist (idempotent)
    if let Err(e) = create_local_likes_playlist(&conn) {
        log::warn!("Failed to create Local Likes playlist: {}", e);
    } else {
        log::info!("Local Likes playlist initialized");
    }

    log::info!("Database initialization complete");
}

/// Run startup tasks when app opens.
///
/// Implements locked decision from CONTEXT.md: "Auto-sync on app open"
///
/// Tasks:
/// - Background sync of Spotify library (if authenticated)
/// - Background sync of SoundCloud library (if authenticated)
/// - Silent failure if user hasn't authenticated yet
///
/// This function never returns an error - all failures are logged as warnings.
pub async fn run_startup_tasks() {
    log::info!("Running startup tasks...");

    // Initialize database and playlists first (synchronous)
    initialize_on_startup();

    // Attempt Spotify sync
    if std::env::var("SPOTIFY_CLIENT_ID").is_ok()
        && std::env::var("SPOTIFY_CLIENT_SECRET").is_ok()
    {
        match sync_spotify_on_startup().await {
            Ok(counts) => {
                if counts.added > 0 {
                    log::info!("Startup sync: added {} new Spotify tracks ({} found, {} skipped)", counts.added, counts.found, counts.skipped);
                } else {
                    log::info!("Startup sync: Spotify library up to date ({} tracks checked)", counts.found);
                }
            }
            Err(e) => {
                log::warn!(
                    "Startup Spotify sync failed (user may not be authenticated): {}",
                    e
                );
            }
        }
    } else {
        log::info!("Startup sync: Spotify credentials not configured, skipping");
    }

    // Attempt SoundCloud sync
    if std::env::var("SOUNDCLOUD_CLIENT_ID").is_ok()
        && std::env::var("SOUNDCLOUD_CLIENT_SECRET").is_ok()
    {
        match sync_soundcloud_on_startup().await {
            Ok(counts) => {
                if counts.added > 0 {
                    log::info!("Startup sync: added {} new SoundCloud tracks ({} found, {} skipped)", counts.added, counts.found, counts.skipped);
                } else {
                    log::info!("Startup sync: SoundCloud library up to date ({} tracks checked)", counts.found);
                }
            }
            Err(e) => {
                log::warn!(
                    "Startup SoundCloud sync failed (user may not be authenticated): {}",
                    e
                );
            }
        }
    } else {
        log::info!("Startup sync: SoundCloud credentials not configured, skipping");
    }

    // Attempt Apple Music sync
    // No env var check needed — AppleMusicClient::new() will fail gracefully
    // if no stored user token exists.
    match sync_apple_music_on_startup().await {
        Ok(counts) => {
            if counts.added > 0 {
                log::info!("Startup sync: added {} new Apple Music tracks ({} found, {} skipped)", counts.added, counts.found, counts.skipped);
            } else {
                log::info!("Startup sync: Apple Music library up to date ({} tracks checked)", counts.found);
            }
        }
        Err(e) => {
            // This is expected when user hasn't connected Apple Music
            log::info!(
                "Startup Apple Music sync skipped (user may not be authenticated): {}",
                e
            );
        }
    }

    log::info!("Startup tasks complete");
}

/// Sync Spotify liked songs on startup.
///
/// Creates a SpotifyClient (which handles token refresh) and runs
/// incremental sync. Returns the number of new tracks added.
async fn sync_spotify_on_startup() -> Result<crate::models::SyncCounts, String> {
    let mut client = SpotifyClient::new(DEFAULT_USER_ID)
        .await
        .map_err(|e| format!("Failed to create Spotify client: {}", e))?;

    let db_path = crate::database::db_path();
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    client
        .sync_liked_songs(&conn)
        .await
        .map_err(|e| format!("Sync failed: {}", e))
}

/// Sync SoundCloud liked tracks on startup.
///
/// Creates a SoundCloudClient and runs incremental sync.
/// Returns the number of new tracks added.
async fn sync_soundcloud_on_startup() -> Result<crate::models::SyncCounts, String> {
    let mut client =
        SoundCloudClient::new().map_err(|e| format!("Failed to create SoundCloud client: {}", e))?;

    let db_path = crate::database::db_path();
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    client
        .sync_likes(DEFAULT_USER_ID, &conn)
        .await
        .map_err(|e| format!("Sync failed: {}", e))
}

/// Sync Apple Music library songs on startup.
///
/// Creates an AppleMusicClient (which scrapes a fresh dev token and loads
/// the stored user token) and runs incremental sync.
/// Returns the number of new tracks added.
async fn sync_apple_music_on_startup() -> Result<crate::models::SyncCounts, String> {
    use crate::sources::AppleMusicClient;

    let mut client = AppleMusicClient::new(DEFAULT_USER_ID)
        .await
        .map_err(|e| format!("Failed to create Apple Music client: {}", e))?;

    let db_path = crate::database::db_path();
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    client
        .sync_library_songs(&conn)
        .await
        .map_err(|e| format!("Sync failed: {}", e))
}

/// Setup mount detection for library drive monitoring.
///
/// Called during app setup to initialize background mount detection.
/// Only activates if library is configured. Does not block startup on failure.
///
/// Tasks:
/// - Load library configuration from database
/// - Emit initial mount state (Connected/Disconnected/NotConfigured)
/// - Start background mount detector if library configured
/// - Store MountDetector in Tauri managed state
pub fn setup_mount_detection(app_handle: tauri::AppHandle) -> Result<(), String> {
    log::info!("Setting up mount detection...");

    let db_path = crate::database::db_path();
    let conn = get_connection(&db_path)
        .map_err(|e| format!("Failed to get database connection: {}", e))?;

    // Load library configuration
    let config = LibraryConfig::load(&conn)
        .map_err(|e| format!("Failed to load library config: {}", e))?;

    if !config.is_configured() {
        log::info!("Library not configured, skipping mount detection");
        // Emit NotConfigured state
        let _ = app_handle.emit("library-mount-changed", &LibraryMountState::NotConfigured);
        return Ok(());
    }

    let library_root = config.root_path
        .ok_or_else(|| "Library configured but root_path is None".to_string())?;

    // Check current mount state
    if library_root.exists() {
        log::info!("Library drive connected at: {}", library_root.display());
    } else {
        log::warn!("Library drive not currently connected: {}", library_root.display());
        // Emit Disconnected state
        let _ = app_handle.emit("library-mount-changed", &LibraryMountState::Disconnected);
    }

    // Start background mount detector
    match MountDetector::start(app_handle.clone(), library_root.clone()) {
        Ok(detector) => {
            // Store detector in managed state
            app_handle.manage(detector);
            log::info!("Mount detection started successfully");
            Ok(())
        }
        Err(e) => {
            // Log error but don't block startup
            log::error!("Failed to start mount detection: {}", e);
            log::warn!("Continuing without mount detection");
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_user_id_is_set() {
        assert!(!DEFAULT_USER_ID.is_empty());
    }

    #[test]
    fn test_initialize_on_startup() {
        use tempfile::tempdir;

        // Create temporary directory for test database
        let temp_dir = tempdir().unwrap();
        let db_path = temp_dir.path().join("music_library.db");

        // Change to temp directory so initialize_on_startup creates db there
        let original_dir = std::env::current_dir().unwrap();
        std::env::set_current_dir(temp_dir.path()).unwrap();

        // Run initialization
        initialize_on_startup();

        // Restore original directory
        std::env::set_current_dir(original_dir).unwrap();

        // Verify database was created
        assert!(db_path.exists());

        // Verify playlists were created
        let conn = get_connection(&db_path).unwrap();

        // Check smart playlists exist
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM playlists WHERE is_smart = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 2); // Recently Added + Most Played

        // Check Local Likes exists
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM playlists WHERE name = 'Local Likes' AND is_liked = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[tokio::test]
    #[ignore] // Requires authenticated user and network access
    async fn test_startup_tasks_integration() {
        // This test requires:
        // - SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET env vars
        // - SOUNDCLOUD_CLIENT_ID and SOUNDCLOUD_CLIENT_SECRET env vars
        // - Refresh tokens stored in keychain for DEFAULT_USER_ID
        // - Network access
        run_startup_tasks().await;
    }
}
