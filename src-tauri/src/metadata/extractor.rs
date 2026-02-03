//! Audio metadata extraction using lofty.
//!
//! Supports reading metadata from:
//! - MP3 (ID3v2)
//! - FLAC (Vorbis Comments)
//! - AAC/M4A (MP4 atoms)
//! - OGG (Vorbis Comments)
//! - WAV (ID3v2/RIFF INFO)
//! - AIFF (ID3v2)
//!
//! Missing metadata uses fallbacks:
//! - album_artist -> artist -> "various artists"
//! - album -> "unknown album"
//! - title -> filename stem

use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, Tag};
use std::path::Path;

use crate::models::track::TrackMetadata;

/// Extract metadata from an audio file.
///
/// Reads ID3v2, Vorbis Comments, or MP4 atoms depending on format.
/// All string fields are normalized to lowercase and trimmed.
///
/// # Arguments
/// * `path` - Path to the audio file
///
/// # Returns
/// * `Ok(TrackMetadata)` - Successfully extracted metadata
/// * `Err(String)` - Error message if extraction failed
///
/// # Fallback Behavior
/// * `artist` - Raw artist tag or empty string
/// * `album_artist` - album_artist tag -> artist -> "various artists"
/// * `album` - album tag -> "unknown album"
/// * `title` - title tag -> filename stem
///
/// # Example
/// ```ignore
/// use std::path::Path;
/// use music_library_manager::metadata::extract_metadata;
///
/// let metadata = extract_metadata(Path::new("/music/song.mp3"))?;
/// println!("Artist: {}", metadata.album_artist);
/// ```
pub fn extract_metadata(path: &Path) -> Result<TrackMetadata, String> {
    // Get file extension for format field
    let format_str = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();

    // Open and read the audio file
    let tagged_file = Probe::open(path)
        .map_err(|e| format!("Cannot open file: {}", e))?
        .read()
        .map_err(|e| format!("Cannot read file: {}", e))?;

    // Get the primary tag (ID3v2, Vorbis, MP4) or fall back to first available
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag());

    // Extract raw tag values (may be None)
    let (raw_artist, raw_album_artist, raw_album, raw_title, raw_genre, raw_year) =
        if let Some(tag) = tag {
            (
                tag.artist().map(|s| s.to_string()),
                get_album_artist(tag),
                tag.album().map(|s| s.to_string()),
                tag.title().map(|s| s.to_string()),
                tag.genre().map(|s| s.to_string()),
                tag.year(),
            )
        } else {
            (None, None, None, None, None, None)
        };

    // Normalize: trim and lowercase
    let artist_normalized = raw_artist
        .as_ref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .unwrap_or_default();

    // Album artist fallback chain: album_artist -> artist -> "various artists"
    let album_artist_normalized = raw_album_artist
        .as_ref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            if !artist_normalized.is_empty() {
                Some(artist_normalized.clone())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "various artists".to_string());

    // Album fallback: album -> "unknown album"
    let album_normalized = raw_album
        .as_ref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown album".to_string());

    // Title fallback: title -> filename stem
    let title_normalized = raw_title
        .as_ref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            path.file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown")
                .to_lowercase()
        });

    // Normalize genre if present
    let genre_normalized = raw_genre
        .as_ref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());

    // Extract audio properties
    let properties = tagged_file.properties();
    let bitrate = properties.audio_bitrate();
    let duration = properties.duration().as_secs() as u32;
    let duration = if duration > 0 { Some(duration) } else { None };

    Ok(TrackMetadata {
        artist: artist_normalized,
        album_artist: album_artist_normalized,
        album: album_normalized,
        title: title_normalized,
        genre: genre_normalized,
        year: raw_year,
        bitrate,
        duration,
        format: format_str,
        original_path: path.to_string_lossy().to_string(),
    })
}

/// Extract album artist from tag using ItemKey.
///
/// Lofty uses ItemKey::AlbumArtist to access album artist across formats:
/// - ID3v2: TPE2 frame
/// - Vorbis Comments: ALBUMARTIST
/// - MP4: aART atom
fn get_album_artist(tag: &Tag) -> Option<String> {
    tag.get_string(&ItemKey::AlbumArtist).map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_extract_metadata_missing_file() {
        let path = PathBuf::from("/nonexistent/file.mp3");
        let result = extract_metadata(&path);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Cannot open file"));
    }

    #[test]
    fn test_format_extraction_from_extension() {
        // Test that extension is properly extracted
        let mp3_path = PathBuf::from("/test/song.MP3");
        let _format = mp3_path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        assert_eq!(_format, "mp3");

        let flac_path = PathBuf::from("/test/song.FLAC");
        let _format = flac_path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        assert_eq!(_format, "flac");
    }
}
