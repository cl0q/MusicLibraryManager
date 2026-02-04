//! Data models for the music library.
//!
//! Contains core data structures:
//! - `Track` - Complete track record with database fields
//! - `TrackMetadata` - Extracted audio file metadata
//! - `Playlist` - Playlist management structures

pub mod playlist;
pub mod track;

pub use playlist::{Playlist, PlaylistCategory, PlaylistTag, PlaylistTrack};
pub use track::{Track, TrackMetadata};
