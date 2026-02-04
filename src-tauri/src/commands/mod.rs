//! Tauri command handlers for frontend integration.
//!
//! Provides async command handlers that can be invoked from the UI:
//! - import_directory: Import audio files from a directory
//! - search_library: Search tracks with fuzzy matching
//! - detect_duplicates: Find and mark duplicate tracks
//! - download_tracks: Batch download tracks from DAB/YouTube
//! - retry_failed_downloads: Retry failed downloads from queue
//! - get_retry_queue_status: Get current retry queue status
//! - spotify_auth_url: Generate Spotify OAuth URL with PKCE
//! - spotify_exchange_code: Exchange Spotify authorization code for tokens
//! - sync_spotify: Trigger incremental Spotify sync
//! - soundcloud_auth_url: Generate SoundCloud OAuth URL with PKCE
//! - soundcloud_exchange_code: Exchange SoundCloud authorization code for tokens
//! - sync_soundcloud: Trigger incremental SoundCloud sync
//! - check_duplicates: Fuzzy duplicate detection across sources
//! - create_sync_profile: Create new sync profile
//! - list_sync_profiles: Get all sync profiles with statistics
//! - get_sync_profile: Get single sync profile by ID
//! - delete_sync_profile: Delete sync profile and associated data
//! - add_track_to_profile: Add track to sync profile
//! - add_playlist_to_profile: Add playlist to sync profile
//! - add_rule_to_profile: Add filter rule to sync profile
//! - detect_rockbox_devices_cmd: Detect connected Rockbox devices
//! - preview_sync_cmd: Preview sync operations (dry-run)
//! - execute_sync_cmd: Execute full sync to device/folder
//!
//! Commands are registered in lib.rs via tauri::generate_handler![]

pub mod download;
pub mod duplicate;
pub mod import;
pub mod playlist;
pub mod search;
pub mod sources;
pub mod sync;

// Re-export commands for registration
pub use download::{download_tracks, get_retry_queue_status, retry_failed_downloads};
pub use duplicate::detect_duplicates;
pub use import::import_directory;
pub use playlist::{
    add_track_to_playlist_command, create_playlist_command, get_playlist_tracks_command,
    get_playlists_command, remove_track_from_playlist_command, reorder_playlist_track_command,
    search_playlist_tracks_command,
};
pub use search::{get_library_storage_size, search_library};
pub use sources::{
    check_duplicates, soundcloud_auth_url, soundcloud_exchange_code, spotify_auth_url,
    spotify_exchange_code, sync_soundcloud, sync_spotify, OAuthState,
};
pub use sync::{
    add_playlist_to_profile, add_rule_to_profile, add_track_to_profile, create_sync_profile,
    delete_sync_profile, detect_rockbox_devices_cmd, execute_sync_cmd, get_last_sync_time,
    get_sync_profile, list_sync_profiles, preview_sync_cmd,
};
