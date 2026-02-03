//! Path sanitization for FAT32-compatible filenames.
//!
//! Provides utilities for creating safe, organized file paths:
//! - FAT32-compatible character replacement (uses sanitize-filename crate)
//! - Windows reserved name handling (CON, PRN, AUX, etc.)
//! - Artist/Album/Track directory structure generation
//!
//! # Examples
//! ```ignore
//! use music_library_manager::metadata::sanitize::{sanitize_filename, generate_organized_path};
//!
//! assert_eq!(sanitize_filename("My Song / Remix"), "My Song _ Remix");
//! assert_eq!(sanitize_filename("CON"), "_CON");
//! assert_eq!(sanitize_filename(""), "unknown");
//! ```

use sanitize_filename::{sanitize_with_options, Options};

use crate::models::track::TrackMetadata;

/// Sanitize a string to be a valid FAT32 filename.
///
/// Applies the following transformations:
/// - Replaces invalid characters (< > : " / \ | ? *) with underscore
/// - Truncates to 255 characters (FAT32 limit)
/// - Prefixes Windows reserved names (CON, PRN, AUX, NUL, COM1-9, LPT1-9) with underscore
/// - Returns "unknown" for empty or whitespace-only input
///
/// # Arguments
/// * `name` - The string to sanitize
///
/// # Returns
/// A FAT32-safe filename string
///
/// # Examples
/// ```ignore
/// assert_eq!(sanitize_filename("My Song"), "My Song");
/// assert_eq!(sanitize_filename("CON"), "_CON");
/// assert_eq!(sanitize_filename("Song: Remix"), "Song_ Remix");
/// assert_eq!(sanitize_filename(""), "unknown");
/// ```
pub fn sanitize_filename(name: &str) -> String {
    let trimmed = name.trim();

    if trimmed.is_empty() {
        return "unknown".to_string();
    }

    // Check for Windows reserved names BEFORE sanitization
    // (sanitize_with_options with windows:true would remove them entirely)
    let is_reserved = is_windows_reserved(trimmed);

    // Don't use windows:true since we handle reserved names ourselves
    // windows:true would turn "CON" into just "_" instead of preserving it
    let options = Options {
        truncate: true,   // Truncate to 255 chars
        windows: false,   // We handle reserved names manually with prefix
        replacement: "_", // Replace invalid chars with underscore
    };

    let sanitized = sanitize_with_options(trimmed, options);

    // Handle empty result after sanitization (all invalid chars)
    if sanitized.is_empty() {
        return "unknown".to_string();
    }

    // Handle Windows reserved names with underscore prefix
    // Pattern from Python implementation: _CON not CON_
    if is_reserved {
        format!("_{}", sanitized)
    } else {
        sanitized
    }
}

/// Check if a name is a Windows reserved name.
///
/// Reserved names: CON, PRN, AUX, NUL, COM1-COM9, LPT1-LPT9
/// Also handles names with extensions (CON.txt is still reserved)
fn is_windows_reserved(name: &str) -> bool {
    // Extract base name without extension for checking
    let base = name
        .split('.')
        .next()
        .unwrap_or(name)
        .to_uppercase();

    matches!(
        base.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "COM1" | "COM2" | "COM3" | "COM4" | "COM5" | "COM6"
            | "COM7" | "COM8" | "COM9" | "LPT1" | "LPT2" | "LPT3" | "LPT4" | "LPT5" | "LPT6"
            | "LPT7" | "LPT8" | "LPT9"
    )
}

/// Generate organized path: Artist/Album/Track.ext
///
/// Uses album_artist for the artist directory (for proper album grouping).
/// All path components are sanitized for FAT32 compatibility.
///
/// # Arguments
/// * `metadata` - Track metadata containing album_artist, album, title, format
///
/// # Returns
/// Organized path string in format "Artist/Album/Title.ext"
///
/// # Example
/// ```ignore
/// let metadata = TrackMetadata {
///     album_artist: "the beatles".to_string(),
///     album: "abbey road".to_string(),
///     title: "come together".to_string(),
///     format: "mp3".to_string(),
///     // ... other fields
/// };
/// assert_eq!(generate_organized_path(&metadata), "the beatles/abbey road/come together.mp3");
/// ```
pub fn generate_organized_path(metadata: &TrackMetadata) -> String {
    let artist = sanitize_filename(&metadata.album_artist);
    let album = sanitize_filename(&metadata.album);
    let title = sanitize_filename(&metadata.title);
    let ext = &metadata.format;

    // Format: Artist/Album/Track.ext
    format!("{}/{}/{}.{}", artist, album, title, ext)
}

/// Generate SoundCloud-specific path: SoundCloud/Artist/Track.ext
///
/// SoundCloud content uses a flat artist/track structure under a dedicated folder.
/// This matches requirement LIB-06 for source-aware organization.
///
/// # Arguments
/// * `metadata` - Track metadata containing artist, title, format
///
/// # Returns
/// SoundCloud path string in format "SoundCloud/Artist/Title.ext"
///
/// # Example
/// ```ignore
/// let metadata = TrackMetadata {
///     artist: "some producer".to_string(),
///     title: "deep cut".to_string(),
///     format: "mp3".to_string(),
///     // ... other fields
/// };
/// assert_eq!(generate_soundcloud_path(&metadata), "SoundCloud/some producer/deep cut.mp3");
/// ```
pub fn generate_soundcloud_path(metadata: &TrackMetadata) -> String {
    let artist = sanitize_filename(&metadata.artist);
    let title = sanitize_filename(&metadata.title);
    let ext = &metadata.format;

    format!("SoundCloud/{}/{}.{}", artist, title, ext)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ===== sanitize_filename tests =====

    #[test]
    fn test_sanitize_normal_name() {
        assert_eq!(sanitize_filename("My Song"), "My Song");
    }

    #[test]
    fn test_sanitize_empty_string() {
        assert_eq!(sanitize_filename(""), "unknown");
    }

    #[test]
    fn test_sanitize_whitespace_only() {
        assert_eq!(sanitize_filename("   "), "unknown");
    }

    #[test]
    fn test_sanitize_windows_reserved_con() {
        // CON should become _CON (underscore prefix pattern)
        assert_eq!(sanitize_filename("CON"), "_CON");
    }

    #[test]
    fn test_sanitize_windows_reserved_prn() {
        assert_eq!(sanitize_filename("PRN"), "_PRN");
    }

    #[test]
    fn test_sanitize_windows_reserved_aux() {
        assert_eq!(sanitize_filename("AUX"), "_AUX");
    }

    #[test]
    fn test_sanitize_windows_reserved_nul() {
        assert_eq!(sanitize_filename("NUL"), "_NUL");
    }

    #[test]
    fn test_sanitize_windows_reserved_com1() {
        assert_eq!(sanitize_filename("COM1"), "_COM1");
    }

    #[test]
    fn test_sanitize_windows_reserved_lpt1() {
        assert_eq!(sanitize_filename("LPT1"), "_LPT1");
    }

    #[test]
    fn test_sanitize_windows_reserved_case_insensitive() {
        assert_eq!(sanitize_filename("con"), "_con");
        assert_eq!(sanitize_filename("Con"), "_Con");
    }

    #[test]
    fn test_sanitize_invalid_chars_colon() {
        // Colon should be replaced with underscore
        let result = sanitize_filename("Song: Remix");
        assert!(!result.contains(':'));
        assert!(result.contains('_'));
    }

    #[test]
    fn test_sanitize_invalid_chars_slash() {
        // Forward slash should be replaced
        let result = sanitize_filename("Song / Remix");
        assert!(!result.contains('/'));
    }

    #[test]
    fn test_sanitize_invalid_chars_backslash() {
        // Backslash should be replaced
        let result = sanitize_filename("Song \\ Remix");
        assert!(!result.contains('\\'));
    }

    #[test]
    fn test_sanitize_invalid_chars_question() {
        let result = sanitize_filename("What?");
        assert!(!result.contains('?'));
    }

    #[test]
    fn test_sanitize_invalid_chars_asterisk() {
        let result = sanitize_filename("Star*");
        assert!(!result.contains('*'));
    }

    #[test]
    fn test_sanitize_invalid_chars_quotes() {
        let result = sanitize_filename("\"Quoted\"");
        assert!(!result.contains('"'));
    }

    #[test]
    fn test_sanitize_invalid_chars_angle_brackets() {
        let result = sanitize_filename("<Tag>");
        assert!(!result.contains('<'));
        assert!(!result.contains('>'));
    }

    #[test]
    fn test_sanitize_invalid_chars_pipe() {
        let result = sanitize_filename("A|B");
        assert!(!result.contains('|'));
    }

    #[test]
    fn test_sanitize_preserves_unicode() {
        // Unicode characters should be preserved
        assert_eq!(sanitize_filename("Bjork"), "Bjork");
        assert_eq!(sanitize_filename("Cafe"), "Cafe");
    }

    #[test]
    fn test_sanitize_trims_whitespace() {
        assert_eq!(sanitize_filename("  Song  "), "Song");
    }

    // ===== is_windows_reserved tests =====

    #[test]
    fn test_is_windows_reserved_with_extension() {
        // CON.txt is still reserved
        assert!(is_windows_reserved("CON"));
    }

    #[test]
    fn test_is_windows_reserved_not_reserved() {
        assert!(!is_windows_reserved("CONCERT"));
        assert!(!is_windows_reserved("AUXILIARY"));
        assert!(!is_windows_reserved("MyFile"));
    }

    // ===== generate_organized_path tests =====

    #[test]
    fn test_generate_organized_path_basic() {
        let metadata = create_test_metadata(
            "artist",
            "album artist",
            "album",
            "title",
            "mp3",
        );
        assert_eq!(
            generate_organized_path(&metadata),
            "album artist/album/title.mp3"
        );
    }

    #[test]
    fn test_generate_organized_path_with_special_chars() {
        let metadata = create_test_metadata(
            "artist",
            "artist: name",
            "album / part 2",
            "song?",
            "flac",
        );
        let path = generate_organized_path(&metadata);
        // Should not contain invalid characters
        assert!(!path.contains(':'));
        assert!(!path.contains('?'));
        // Should only contain forward slashes as path separators
        let parts: Vec<&str> = path.split('/').collect();
        assert_eq!(parts.len(), 3); // artist/album/track.ext
    }

    #[test]
    fn test_generate_organized_path_with_reserved_name() {
        let metadata = create_test_metadata(
            "artist",
            "CON",
            "PRN",
            "AUX",
            "mp3",
        );
        let path = generate_organized_path(&metadata);
        assert!(path.starts_with("_CON/"));
        assert!(path.contains("/_PRN/"));
        assert!(path.contains("/_AUX.mp3"));
    }

    // ===== generate_soundcloud_path tests =====

    #[test]
    fn test_generate_soundcloud_path_basic() {
        let metadata = create_test_metadata(
            "producer",
            "album artist",
            "album",
            "track",
            "mp3",
        );
        assert_eq!(
            generate_soundcloud_path(&metadata),
            "SoundCloud/producer/track.mp3"
        );
    }

    #[test]
    fn test_generate_soundcloud_path_uses_artist_not_album_artist() {
        // SoundCloud path should use artist, not album_artist
        let metadata = create_test_metadata(
            "the actual artist",
            "different album artist",
            "album",
            "song",
            "flac",
        );
        let path = generate_soundcloud_path(&metadata);
        assert!(path.contains("the actual artist"));
        assert!(!path.contains("different album artist"));
    }

    // ===== Helper functions =====

    fn create_test_metadata(
        artist: &str,
        album_artist: &str,
        album: &str,
        title: &str,
        format: &str,
    ) -> TrackMetadata {
        TrackMetadata {
            artist: artist.to_string(),
            album_artist: album_artist.to_string(),
            album: album.to_string(),
            title: title.to_string(),
            genre: None,
            year: None,
            bitrate: None,
            duration: None,
            format: format.to_string(),
            original_path: "/test/path".to_string(),
        }
    }
}
