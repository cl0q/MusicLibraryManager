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

use std::path::PathBuf;

use crate::database::get_connection;
use crate::sources::soundcloud::SoundCloudClient;
use crate::sources::spotify::SpotifyClient;

/// Default user ID for startup sync.
///
/// In a single-user desktop app, this is the default user context.
/// When multi-user support is added (Phase 6+), this should come from
/// app configuration or last-logged-in user state.
const DEFAULT_USER_ID: &str = "default_user";

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

    // Attempt Spotify sync
    if std::env::var("SPOTIFY_CLIENT_ID").is_ok()
        && std::env::var("SPOTIFY_CLIENT_SECRET").is_ok()
    {
        match sync_spotify_on_startup().await {
            Ok(count) => {
                if count > 0 {
                    log::info!("Startup sync: added {} new Spotify tracks", count);
                } else {
                    log::info!("Startup sync: Spotify library up to date");
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
            Ok(count) => {
                if count > 0 {
                    log::info!("Startup sync: added {} new SoundCloud tracks", count);
                } else {
                    log::info!("Startup sync: SoundCloud library up to date");
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

    log::info!("Startup tasks complete");
}

/// Sync Spotify liked songs on startup.
///
/// Creates a SpotifyClient (which handles token refresh) and runs
/// incremental sync. Returns the number of new tracks added.
async fn sync_spotify_on_startup() -> Result<usize, String> {
    let mut client = SpotifyClient::new(DEFAULT_USER_ID)
        .await
        .map_err(|e| format!("Failed to create Spotify client: {}", e))?;

    let db_path = PathBuf::from("music_library.db");
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
async fn sync_soundcloud_on_startup() -> Result<usize, String> {
    let mut client =
        SoundCloudClient::new().map_err(|e| format!("Failed to create SoundCloud client: {}", e))?;

    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    client
        .sync_likes(DEFAULT_USER_ID, &conn)
        .await
        .map_err(|e| format!("Sync failed: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_user_id_is_set() {
        assert!(!DEFAULT_USER_ID.is_empty());
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
