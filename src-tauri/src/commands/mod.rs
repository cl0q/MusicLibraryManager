//! Tauri command handlers for frontend integration.
//!
//! Provides async command handlers that can be invoked from the UI:
//! - import_directory: Import audio files from a directory
//!
//! Commands are registered in lib.rs via tauri::generate_handler![]

pub mod import;

// Re-export commands for registration
pub use import::import_directory;
