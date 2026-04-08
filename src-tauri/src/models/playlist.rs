//! Playlist data models.
//!
//! Contains structures for playlist management:
//! - `PlaylistCategory` - Enum for playlist types (Liked, Smart, Regular)
//! - `Playlist` - Complete playlist record with all metadata
//! - `PlaylistTrack` - Track membership in playlist with ordering
//! - `PlaylistTag` - Tag association for playlist organization

use serde::{Deserialize, Serialize};
use std::fmt;

/// Playlist category enum.
///
/// Categorizes playlists into three types:
/// - Liked: Special playlist for liked/favorited tracks
/// - Smart: Auto-generated playlist based on rules
/// - Regular: User-created manual playlist
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum PlaylistCategory {
    Liked,
    Smart,
    Regular,
}

impl fmt::Display for PlaylistCategory {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlaylistCategory::Liked => write!(f, "liked"),
            PlaylistCategory::Smart => write!(f, "smart"),
            PlaylistCategory::Regular => write!(f, "regular"),
        }
    }
}

impl PlaylistCategory {
    /// Parse category from database string (case-insensitive).
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "liked" => Some(PlaylistCategory::Liked),
            "smart" => Some(PlaylistCategory::Smart),
            "regular" => Some(PlaylistCategory::Regular),
            _ => None,
        }
    }
}

/// Playlist model.
///
/// Represents a complete playlist record from the database with all metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub description: Option<String>,
    pub category: PlaylistCategory,
    pub is_liked: bool,
    pub is_smart: bool,
    pub is_pinned: bool,
    pub cover_image_path: Option<String>,
    pub cover_image_url: Option<String>,
    pub source_id: Option<i64>,
    pub external_id: Option<String>,
    pub date_created: String,
}

/// Playlist track model.
///
/// Represents a track's membership in a playlist with its position.
/// Position uses fractional indexing for efficient reordering without gaps.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistTrack {
    pub id: i64,
    pub playlist_id: i64,
    pub track_id: i64,
    pub position: String,
    pub added_at: String,
}

/// Playlist tag model.
///
/// Represents a tag associated with a playlist for organization.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistTag {
    pub playlist_id: i64,
    pub tag: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_playlist_category_display() {
        assert_eq!(PlaylistCategory::Liked.to_string(), "liked");
        assert_eq!(PlaylistCategory::Smart.to_string(), "smart");
        assert_eq!(PlaylistCategory::Regular.to_string(), "regular");
    }

    #[test]
    fn test_playlist_category_from_str() {
        assert_eq!(
            PlaylistCategory::from_str("liked"),
            Some(PlaylistCategory::Liked)
        );
        assert_eq!(
            PlaylistCategory::from_str("smart"),
            Some(PlaylistCategory::Smart)
        );
        assert_eq!(
            PlaylistCategory::from_str("regular"),
            Some(PlaylistCategory::Regular)
        );
        assert_eq!(PlaylistCategory::from_str("invalid"), None);
    }

    #[test]
    fn test_playlist_serialization() {
        let playlist = Playlist {
            id: 1,
            name: "My Playlist".to_string(),
            description: Some("Test playlist".to_string()),
            category: PlaylistCategory::Regular,
            is_liked: false,
            is_smart: false,
            is_pinned: true,
            cover_image_path: None,
            cover_image_url: Some("http://example.com/cover.jpg".to_string()),
            source_id: None,
            external_id: None,
            date_created: "2026-02-04T00:00:00Z".to_string(),
        };

        let json = serde_json::to_string(&playlist).unwrap();
        assert!(json.contains("My Playlist"));
        assert!(json.contains("regular"));
    }

    #[test]
    fn test_playlist_track_serialization() {
        let track = PlaylistTrack {
            id: 1,
            playlist_id: 1,
            track_id: 42,
            position: "a0".to_string(),
            added_at: "2026-02-04T00:00:00Z".to_string(),
        };

        let json = serde_json::to_string(&track).unwrap();
        assert!(json.contains("\"position\":\"a0\""));
    }

    #[test]
    fn test_playlist_tag_serialization() {
        let tag = PlaylistTag {
            playlist_id: 1,
            tag: "workout".to_string(),
        };

        let json = serde_json::to_string(&tag).unwrap();
        assert!(json.contains("workout"));
    }
}
