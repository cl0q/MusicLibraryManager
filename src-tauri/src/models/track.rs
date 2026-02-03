//! Track data structures for the music library.
//!
//! `TrackMetadata` holds extracted audio file metadata.
//! `Track` represents a complete library entry with database fields.

use serde::{Deserialize, Serialize};

/// Metadata extracted from an audio file.
///
/// All string fields are normalized to lowercase and trimmed.
/// Missing fields use fallback values:
/// - artist: extracted artist or empty string
/// - album_artist: album_artist -> artist -> "various artists"
/// - album: album or "unknown album"
/// - title: title or filename stem
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackMetadata {
    /// Track artist (may differ from album artist)
    pub artist: String,
    /// Album artist for grouping (primary for organization)
    pub album_artist: String,
    /// Album name
    pub album: String,
    /// Track title
    pub title: String,
    /// Genre tag if present
    pub genre: Option<String>,
    /// Release year if present
    pub year: Option<u32>,
    /// Audio bitrate in kbps if available
    pub bitrate: Option<u32>,
    /// Duration in seconds if available
    pub duration: Option<u32>,
    /// File format (mp3, flac, m4a, ogg, wav, aiff)
    pub format: String,
    /// Original file path where metadata was extracted from
    pub original_path: String,
}

/// Complete track record for database storage.
///
/// Combines extracted metadata with library-specific fields:
/// - organized_path: sanitized Artist/Album/Track.ext path
/// - is_duplicate: whether a better quality version exists
/// - date_added: when track was imported to library
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Track {
    /// Database ID (None until inserted)
    pub id: Option<i64>,
    /// Extracted audio metadata
    pub metadata: TrackMetadata,
    /// Sanitized path for organized library: Artist/Album/Track.ext
    pub organized_path: String,
    /// True if a higher quality duplicate exists
    pub is_duplicate: bool,
    /// ISO 8601 timestamp when added to library
    pub date_added: Option<String>,
}

impl TrackMetadata {
    /// Create a new TrackMetadata with all fields specified.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        artist: String,
        album_artist: String,
        album: String,
        title: String,
        genre: Option<String>,
        year: Option<u32>,
        bitrate: Option<u32>,
        duration: Option<u32>,
        format: String,
        original_path: String,
    ) -> Self {
        Self {
            artist,
            album_artist,
            album,
            title,
            genre,
            year,
            bitrate,
            duration,
            format,
            original_path,
        }
    }
}

impl Track {
    /// Create a new Track from metadata with generated organized path.
    pub fn new(metadata: TrackMetadata, organized_path: String) -> Self {
        Self {
            id: None,
            metadata,
            organized_path,
            is_duplicate: false,
            date_added: None,
        }
    }

    /// Create a Track with database ID (for loaded records).
    pub fn with_id(id: i64, metadata: TrackMetadata, organized_path: String) -> Self {
        Self {
            id: Some(id),
            metadata,
            organized_path,
            is_duplicate: false,
            date_added: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_track_metadata_creation() {
        let metadata = TrackMetadata::new(
            "artist name".to_string(),
            "album artist".to_string(),
            "album name".to_string(),
            "track title".to_string(),
            Some("rock".to_string()),
            Some(2024),
            Some(320),
            Some(240),
            "mp3".to_string(),
            "/path/to/file.mp3".to_string(),
        );

        assert_eq!(metadata.artist, "artist name");
        assert_eq!(metadata.album_artist, "album artist");
        assert_eq!(metadata.format, "mp3");
    }

    #[test]
    fn test_track_creation() {
        let metadata = TrackMetadata::new(
            "artist".to_string(),
            "artist".to_string(),
            "album".to_string(),
            "title".to_string(),
            None,
            None,
            None,
            None,
            "flac".to_string(),
            "/music/file.flac".to_string(),
        );

        let track = Track::new(metadata.clone(), "artist/album/title.flac".to_string());

        assert!(track.id.is_none());
        assert!(!track.is_duplicate);
        assert_eq!(track.organized_path, "artist/album/title.flac");
    }

    #[test]
    fn test_track_with_id() {
        let metadata = TrackMetadata::new(
            "artist".to_string(),
            "artist".to_string(),
            "album".to_string(),
            "title".to_string(),
            None,
            None,
            None,
            None,
            "mp3".to_string(),
            "/music/file.mp3".to_string(),
        );

        let track = Track::with_id(42, metadata, "artist/album/title.mp3".to_string());

        assert_eq!(track.id, Some(42));
    }
}
