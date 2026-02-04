//! Device synchronization module.
//!
//! Handles synchronization profiles, transcode caching, device filesystem operations,
//! and M3U8 playlist generation for Rockbox-enabled devices.
//!
//! Module organization:
//! - `profile` - Sync profile management and content resolution
//! - `cache` - Transcode cache management (TODO: Plan 05-02)
//! - `device` - Device filesystem operations and M3U8 generation (TODO: Plan 05-03)
//! - `playlist_gen` - Playlist file generation for devices (TODO: Plan 05-03)
//! - `progress` - Sync progress tracking and reporting (TODO: Plan 05-04)

pub mod profile;

// Stubbed modules for future plans
// pub mod cache;
// pub mod device;
// pub mod playlist_gen;
// pub mod progress;
