//! Data models for the music library.
//!
//! Contains core data structures:
//! - `Track` - Complete track record with database fields
//! - `TrackMetadata` - Extracted audio file metadata

pub mod track;

pub use track::{Track, TrackMetadata};
