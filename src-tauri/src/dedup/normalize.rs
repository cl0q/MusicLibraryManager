//! String normalization for duplicate detection.
//!
//! Normalizes track titles and artist names for comparison by handling:
//! - Unicode normalization (NFC: canonical composition)
//! - Lowercase conversion
//! - Punctuation removal
//! - Whitespace collapsing
//! - Featuring notation standardization

use regex::Regex;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;

/// Regex for matching featuring variations: "feat.", "ft.", "featuring", "with"
/// Case-insensitive for pre-normalization matching
static RE_FEAT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(feat\.?|ft\.?|featuring|with)\b").expect("Invalid featuring regex")
});

/// Regex for matching ampersand between words
static RE_AMPERSAND: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s+&\s+").expect("Invalid ampersand regex"));

/// Normalize track title or album name for comparison.
///
/// Handles:
/// - Unicode normalization (NFC: compose diacritics)
/// - Lowercase conversion
/// - Punctuation removal (keeps alphanumeric and whitespace)
/// - Whitespace collapsing
///
/// # Arguments
/// * `text` - The text to normalize
///
/// # Returns
/// Normalized string suitable for comparison
///
/// # Example
/// ```
/// use music_library_manager::dedup::normalize;
///
/// assert_eq!(normalize("Cafe"), "cafe");
/// assert_eq!(normalize("Song Name!"), "song name");
/// assert_eq!(normalize("  Multiple   Spaces  "), "multiple spaces");
/// ```
pub fn normalize(text: &str) -> String {
    // Unicode normalization (NFC: compose diacritics)
    let nfc: String = text.nfc().collect();

    // Lowercase
    let lower = nfc.to_lowercase();

    // Remove punctuation, keep alphanumeric and whitespace
    let cleaned: String = lower
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect();

    // Collapse multiple spaces to single space and trim
    cleaned
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

/// Normalize artist name with featuring notation standardization.
///
/// Handles:
/// - Featuring variations: "feat.", "ft.", "featuring", "with" -> "feat"
/// - Ampersand between words: "& Artist" -> "feat artist"
/// - Then applies standard normalization (lowercase, punctuation removal)
///
/// Note: Featuring substitution happens BEFORE punctuation removal to preserve "&"
///
/// # Arguments
/// * `artist` - The artist name to normalize
///
/// # Returns
/// Normalized artist string with standardized featuring notation
///
/// # Example
/// ```
/// use music_library_manager::dedup::normalize_artist;
///
/// assert_eq!(normalize_artist("Artist feat. Someone"), "artist feat someone");
/// assert_eq!(normalize_artist("Artist ft. Someone"), "artist feat someone");
/// assert_eq!(normalize_artist("Artist & Someone"), "artist feat someone");
/// assert_eq!(normalize_artist("Artist (feat. Someone)"), "artist feat someone");
/// ```
pub fn normalize_artist(artist: &str) -> String {
    // First: Handle ampersand BEFORE punctuation removal
    // Replace "&" between words with " feat "
    let with_ampersand = RE_AMPERSAND.replace_all(artist, " feat ").to_string();

    // Second: Standardize featuring notation (case-insensitive)
    // Match variations: feat., ft., featuring, with (with word boundaries)
    let with_feat = RE_FEAT.replace_all(&with_ampersand, "feat").to_string();

    // Finally: Apply standard normalization (lowercase, punctuation, whitespace)
    normalize(&with_feat)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_basic() {
        assert_eq!(normalize("Hello World"), "hello world");
        assert_eq!(normalize("HELLO WORLD"), "hello world");
        assert_eq!(normalize("  Multiple   Spaces  "), "multiple spaces");
    }

    #[test]
    fn test_normalize_unicode() {
        // Diacritics - Note: NFC keeps accented characters composed
        // The filter only keeps alphanumeric, so accented letters remain
        assert_eq!(normalize("Cafe"), "cafe");
        assert_eq!(normalize("naive"), "naive");

        // Punctuation
        assert_eq!(normalize("Song Name!"), "song name");
        assert_eq!(normalize("Track (Remix)"), "track remix");
    }

    #[test]
    fn test_normalize_empty_and_whitespace() {
        assert_eq!(normalize(""), "");
        assert_eq!(normalize("   "), "");
        assert_eq!(normalize("\t\n"), "");
    }

    #[test]
    fn test_normalize_numbers() {
        assert_eq!(normalize("Track 123"), "track 123");
        assert_eq!(normalize("2001: A Space Odyssey"), "2001 a space odyssey");
    }

    #[test]
    fn test_normalize_artist_featuring() {
        assert_eq!(
            normalize_artist("Artist feat. Someone"),
            "artist feat someone"
        );
        assert_eq!(
            normalize_artist("Artist ft. Someone"),
            "artist feat someone"
        );
        assert_eq!(
            normalize_artist("Artist featuring Someone"),
            "artist feat someone"
        );
        assert_eq!(normalize_artist("Artist & Someone"), "artist feat someone");
        assert_eq!(
            normalize_artist("Artist (feat. Someone)"),
            "artist feat someone"
        );
    }

    #[test]
    fn test_normalize_artist_with_keyword() {
        // "with" as featuring notation
        assert_eq!(
            normalize_artist("Artist with Someone"),
            "artist feat someone"
        );
    }

    #[test]
    fn test_normalize_artist_multiple_featuring() {
        assert_eq!(
            normalize_artist("Artist feat. A & B"),
            "artist feat a feat b"
        );
    }

    #[test]
    fn test_normalize_artist_no_featuring() {
        // Artist names without featuring should remain unchanged (except lowercase)
        assert_eq!(normalize_artist("The Beatles"), "the beatles");
        assert_eq!(normalize_artist("A$AP Rocky"), "aap rocky");
    }

    #[test]
    fn test_normalize_artist_complex_brackets() {
        assert_eq!(
            normalize_artist("Artist [feat. Someone] (Remix)"),
            "artist feat someone remix"
        );
    }
}
