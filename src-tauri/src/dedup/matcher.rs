//! Fuzzy duplicate detection and variant identification.
//!
//! Provides similarity calculation and duplicate detection using
//! Jaro-Winkler distance for fuzzy string matching.

use regex::Regex;
use std::sync::LazyLock;
use strsim::jaro_winkler;

use crate::dedup::normalize::{normalize, normalize_artist};

/// Regex for matching variant keywords in track titles
static RE_VARIANTS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b(remix|edit|mix|version|live|acoustic|radio|extended|instrumental|vocal|dub|vip|bootleg|rework|remaster)\b",
    )
    .expect("Invalid variants regex")
});

/// Calculate similarity score between two tracks.
///
/// Returns value 0.0-1.0 where:
/// - 1.0 = exact match
/// - 0.95+ = very likely duplicate
/// - 0.85-0.95 = likely duplicate (check manually)
/// - < 0.85 = different tracks
///
/// Weighting: title 70%, artist 30%
///
/// # Arguments
/// * `title1` - First track title
/// * `artist1` - First track artist
/// * `title2` - Second track title
/// * `artist2` - Second track artist
///
/// # Returns
/// Similarity score between 0.0 and 1.0
///
/// # Example
/// ```
/// use music_library_manager::dedup::calculate_similarity;
///
/// let score = calculate_similarity(
///     "Song Name",
///     "Artist",
///     "Song Name",
///     "Artist",
/// );
/// assert!(score > 0.99);
/// ```
pub fn calculate_similarity(title1: &str, artist1: &str, title2: &str, artist2: &str) -> f64 {
    let norm_title1 = normalize(title1);
    let norm_title2 = normalize(title2);
    let norm_artist1 = normalize_artist(artist1);
    let norm_artist2 = normalize_artist(artist2);

    // Empty strings are not equal (missing metadata)
    if norm_title1.is_empty() || norm_title2.is_empty() {
        return 0.0;
    }
    if norm_artist1.is_empty() || norm_artist2.is_empty() {
        return 0.0;
    }

    let title_sim = jaro_winkler(&norm_title1, &norm_title2);
    let artist_sim = jaro_winkler(&norm_artist1, &norm_artist2);

    // Weighted average: title more important than artist
    (title_sim * 0.7) + (artist_sim * 0.3)
}

/// Check if a track is a variant of another track (remix, edit, live, acoustic).
///
/// Returns true if one title contains variant keywords but artist matches closely.
///
/// Used for variant_of field in database (from CONTEXT.md decision).
///
/// # Arguments
/// * `title1` - First track title
/// * `title2` - Second track title
/// * `artist1` - First track artist
/// * `artist2` - Second track artist
///
/// # Returns
/// True if one track appears to be a variant (remix/edit/etc.) of the other
///
/// # Example
/// ```
/// use music_library_manager::dedup::is_variant;
///
/// assert!(is_variant(
///     "Song Name (Remix)",
///     "Song Name",
///     "Artist",
///     "Artist",
/// ));
/// ```
pub fn is_variant(title1: &str, title2: &str, artist1: &str, artist2: &str) -> bool {
    let norm_title1 = normalize(title1);
    let norm_title2 = normalize(title2);
    let norm_artist1 = normalize_artist(artist1);
    let norm_artist2 = normalize_artist(artist2);

    // Artist must be similar (0.90+ threshold)
    let artist_sim = jaro_winkler(&norm_artist1, &norm_artist2);
    if artist_sim < 0.90 {
        return false;
    }

    // Check for variant keywords in each title
    let has_variant1 = RE_VARIANTS.is_match(&norm_title1);
    let has_variant2 = RE_VARIANTS.is_match(&norm_title2);

    // One title has variant keyword, other doesn't
    if has_variant1 != has_variant2 {
        // Check if base title is similar (remove variant keywords and compare)
        let base1 = RE_VARIANTS.replace_all(&norm_title1, "").trim().to_string();
        let base2 = RE_VARIANTS.replace_all(&norm_title2, "").trim().to_string();

        // Collapse whitespace after keyword removal
        let base1 = base1.split_whitespace().collect::<Vec<_>>().join(" ");
        let base2 = base2.split_whitespace().collect::<Vec<_>>().join(" ");

        let base_sim = jaro_winkler(&base1, &base2);
        return base_sim >= 0.85; // High similarity on base title
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_similarity_exact_match() {
        let score = calculate_similarity("Song Name", "Artist", "Song Name", "Artist");
        assert!(score > 0.99);
    }

    #[test]
    fn test_calculate_similarity_case_insensitive() {
        let score = calculate_similarity("Song Name", "Artist", "SONG NAME", "ARTIST");
        assert!(score > 0.99);
    }

    #[test]
    fn test_calculate_similarity_featuring_variation() {
        let score =
            calculate_similarity("Song", "Artist feat. Someone", "Song", "Artist & Someone");
        assert!(score > 0.90); // Should be recognized as duplicate
    }

    #[test]
    fn test_calculate_similarity_different_tracks() {
        // Use more distinct track names that should have lower similarity
        let score = calculate_similarity("Bohemian Rhapsody", "Queen", "Stairway to Heaven", "Led Zeppelin");
        assert!(score < 0.75);
    }

    #[test]
    fn test_calculate_similarity_empty_title() {
        let score = calculate_similarity("", "Artist", "Song", "Artist");
        assert_eq!(score, 0.0);
    }

    #[test]
    fn test_calculate_similarity_empty_artist() {
        let score = calculate_similarity("Song", "", "Song", "Artist");
        assert_eq!(score, 0.0);
    }

    #[test]
    fn test_is_variant_remix() {
        assert!(is_variant(
            "Song Name (Remix)",
            "Song Name",
            "Artist",
            "Artist",
        ));
        assert!(is_variant(
            "Song Name",
            "Song Name (Radio Edit)",
            "Artist",
            "Artist",
        ));
    }

    #[test]
    fn test_is_variant_live() {
        assert!(is_variant(
            "Song Name (Live)",
            "Song Name",
            "Artist",
            "Artist",
        ));
    }

    #[test]
    fn test_is_variant_acoustic() {
        assert!(is_variant(
            "Song Name (Acoustic)",
            "Song Name",
            "Artist",
            "Artist",
        ));
    }

    #[test]
    fn test_is_variant_extended() {
        assert!(is_variant(
            "Song Name (Extended Mix)",
            "Song Name",
            "Artist",
            "Artist",
        ));
    }

    #[test]
    fn test_is_variant_different_artists() {
        // Different artists - not a variant
        assert!(!is_variant(
            "Song Name (Remix)",
            "Song Name",
            "Queen",
            "Led Zeppelin",
        ));
    }

    #[test]
    fn test_is_variant_both_have_keywords() {
        // Both have remix keyword - not a variant relationship
        assert!(!is_variant(
            "Song Name (Remix)",
            "Song Name (VIP Remix)",
            "Artist",
            "Artist",
        ));
    }

    #[test]
    fn test_is_variant_different_songs() {
        // Different base songs - more distinct titles
        assert!(!is_variant(
            "Bohemian Rhapsody (Remix)",
            "Stairway to Heaven",
            "Artist",
            "Artist",
        ));
    }
}
