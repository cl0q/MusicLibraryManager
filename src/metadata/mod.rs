//! Metadata extraction and path sanitization for audio files.
//!
//! This module provides:
//! - `extractor` - Lofty-based audio metadata extraction
//! - `sanitize` - FAT32-safe filename and path generation
//!
//! # Example
//! ```ignore
//! use std::path::Path;
//! use music_library_manager::metadata::{extract_metadata, generate_organized_path};
//!
//! let path = Path::new("/music/song.mp3");
//! let metadata = extract_metadata(path)?;
//! let organized = generate_organized_path(&metadata);
//! // e.g., "artist name/album name/track title.mp3"
//! ```

pub mod extractor;
pub mod sanitize;

pub use extractor::extract_metadata;
pub use sanitize::{generate_organized_path, generate_soundcloud_path, sanitize_filename};
