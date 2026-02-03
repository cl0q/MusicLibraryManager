//! Tauri command handlers for frontend integration.
//!
//! Provides async command handlers that can be invoked from the UI:
//! - import_directory: Import audio files from a directory
//! - search_library: Search tracks with fuzzy matching
//! - detect_duplicates: Find and mark duplicate tracks
//! - download_tracks: Batch download tracks from DAB/YouTube
//! - retry_failed_downloads: Retry failed downloads from queue
//! - get_retry_queue_status: Get current retry queue status
//!
//! Commands are registered in lib.rs via tauri::generate_handler![]

pub mod download;
pub mod duplicate;
pub mod import;
pub mod search;

// Re-export commands for registration
pub use download::{download_tracks, get_retry_queue_status, retry_failed_downloads};
pub use duplicate::detect_duplicates;
pub use import::import_directory;
pub use search::search_library;
