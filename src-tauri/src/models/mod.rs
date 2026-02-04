//! Data models for the music library.
//!
//! Contains core data structures:
//! - `Track` - Complete track record with database fields
//! - `TrackMetadata` - Extracted audio file metadata
//! - `Playlist` - Playlist management structures
//! - `Sync` - Sync profile structures

pub mod playlist;
pub mod sync;
pub mod track;

pub use playlist::{Playlist, PlaylistCategory, PlaylistTag, PlaylistTrack};
pub use sync::{FilterRuleDto, SyncProfileDto};
pub use track::{Track, TrackMetadata};
