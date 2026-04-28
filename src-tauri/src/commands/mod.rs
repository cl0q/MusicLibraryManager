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
//! - fingerprint_library_cmd: Batch generate Chromaprint fingerprints
//! - fetch_artwork_cmd: Batch fetch album artwork
//! - analyze_replaygain_cmd: Batch analyze ReplayGain values
//! - deep_scan_cmd: Fingerprint-based duplicate detection
//! - get_review_queue_cmd: Retrieve review queue entries
//! - resolve_review_item_cmd: Approve/reject/dismiss review items
//! - get_review_queue_count_cmd: Get pending review count for sidebar badge
//! - backfill_yeat_tags_cmd: Backfill `track_tags` from on-disk Yeat taxonomy
//! - detect_album_siblings_cmd: Detect and link album variant siblings (Phase 21)
//! - get_album_detail_cmd: Fetch an album + its tracks + siblings + variant preference (Phase 21)
//! - set_variant_preference_cmd: Persist the user's UFO toggle selection (Phase 21)
//! - rescan_albums_cmd: Re-run albums backfill + sibling detection (Phase 21.1)
//!
//! Commands are registered in lib.rs via tauri::generate_handler![]

pub mod albums;
pub mod analysis;
pub mod batch_control;
pub mod download;
pub mod duplicate;
pub mod enhancements;
pub mod files;
pub mod import;
pub mod library_config;
pub mod maintenance;
pub mod playlist;
pub mod search;
pub mod sources;
pub mod sync;
pub mod yeat;

// Re-export commands for registration
pub use albums::{
    detect_album_siblings_cmd, get_album_detail_cmd, rescan_albums_cmd, set_variant_preference_cmd,
    RescanAlbumsResult,
};
pub use analysis::get_track_analysis;
pub use batch_control::stop_analysis_cmd;
pub use download::{download_tracks, get_retry_queue_status, retry_failed_downloads};
pub use duplicate::detect_duplicates;
pub use enhancements::{
    analyze_loudness_all, analyze_replaygain_cmd, deep_scan_cmd, fetch_artwork_cmd,
    fingerprint_library_cmd, get_review_queue_cmd, get_review_queue_count_cmd,
    resolve_review_item_cmd,
};
pub use files::copy_to_clipboard;
pub use import::{import_directory, import_playlist_command};
pub use library_config::{
    check_library_connection, configure_library, get_library_config,
    get_library_mount_state, get_subfolders, select_library_folder,
    set_library_size_limit, get_library_size_limit, check_library_size_limit,
    LibrarySizeStatus,
};
pub use playlist::{
    add_track_to_playlist_command, create_playlist_command, get_playlist_tracks_command,
    get_playlists_command, remove_track_from_playlist_command, reorder_playlist_track_command,
    search_playlist_tracks_command, sync_source_likes_playlist,
};
pub use search::{get_library_storage_size, get_library_tracks, get_library_tracks_only, get_remote_tracks_only, get_remote_track_count, search_library};
pub use sources::{
    apple_music_check_connected, apple_music_get_dev_token, apple_music_store_user_token,
    check_duplicates, disconnect_apple_music, soundcloud_auth_url, soundcloud_exchange_code,
    spotify_auth_url, spotify_exchange_code, sync_apple_music, sync_soundcloud, sync_spotify,
    OAuthState,
};
pub use sync::{
    add_playlist_to_profile, add_rule_to_profile, add_track_to_profile, create_sync_profile,
    delete_sync_profile, detect_rockbox_devices_cmd, execute_sync_cmd, get_last_sync_time,
    get_sync_profile, list_sync_profiles, preview_sync_cmd,
};
pub use yeat::{
    backfill_yeat_tags_cmd, backfill_yeat_tags_from_db_cmd, BackfillReport, DbBackfillReport,
    DriftEntry,
};
