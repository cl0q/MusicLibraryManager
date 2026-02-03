//! Path sanitization for FAT32-compatible filenames.
//!
//! Provides utilities for creating safe, organized file paths:
//! - FAT32-compatible character replacement
//! - Windows reserved name handling (CON, PRN, etc.)
//! - Artist/Album/Track directory structure generation
//!
//! # Placeholder
//! This is a stub implementation. Full implementation in Task 2.

use crate::models::track::TrackMetadata;

/// Sanitize a string to be a valid FAT32 filename.
///
/// Stub implementation - to be completed in Task 2.
pub fn sanitize_filename(_name: &str) -> String {
    "stub".to_string()
}

/// Generate organized path: Artist/Album/Track.ext
///
/// Stub implementation - to be completed in Task 2.
pub fn generate_organized_path(_metadata: &TrackMetadata) -> String {
    "stub/stub/stub.mp3".to_string()
}

/// Generate SoundCloud-specific path: SoundCloud/Artist/Track.ext
///
/// Stub implementation - to be completed in Task 2.
pub fn generate_soundcloud_path(_metadata: &TrackMetadata) -> String {
    "SoundCloud/stub/stub.mp3".to_string()
}
