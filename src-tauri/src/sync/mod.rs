//! Device synchronization module.
//!
//! Handles synchronization profiles, transcode caching, device filesystem operations,
//! and M3U8 playlist generation for Rockbox-enabled devices.
//!
//! Module organization:
//! - `profile` - Sync profile management and content resolution
//! - `cache` - Transcode cache management (Plan 05-02: Complete)
//! - `device` - Rockbox device detection and filesystem operations (Plan 05-03: Complete)
//! - `playlist_gen` - M3U8 playlist file generation (Plan 05-03: In Progress)
//! - `progress` - Sync progress tracking and reporting (TODO: Plan 05-04)

pub mod cache;
pub mod device;
pub mod profile;

// Public exports
pub use cache::TranscodeCache;
pub use device::{RockboxDevice, detect_rockbox_devices, get_available_space};

// Stubbed modules for future plans
// pub mod playlist_gen;
// pub mod progress;
