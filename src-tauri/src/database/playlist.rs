//! Playlist database operations with fractional indexing.
//!
//! Provides CRUD operations for playlist management:
//! - Create playlists with tags
//! - Add/remove tracks to/from playlists
//! - Reorder tracks with O(1) performance via fractional indexing
//! - Query playlist tracks in order
//!
//! Fractional indexing uses string-based positions for unlimited reordering
//! without cascading updates. Only the moved track's position is updated.

use crate::database::connection::Result;

/// Base-62 alphabet for fractional indexing (alphanumeric).
const ALPHABET: &str = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// Delimiter for fractional indexing.
const DELIMITER: char = '|';

/// Generates a fractional index position between left and right positions.
///
/// Uses string-based lexicographic ordering for unlimited precision.
/// Cases:
/// - (None, None) → "a0" (first position)
/// - (Some(left), None) → append "|a0" to left (insert after)
/// - (None, Some(right)) → "a0" if right > "a0", else compute midpoint before right
/// - (Some(left), Some(right)) → compute midpoint string between left and right
///
/// # Arguments
/// * `left` - Optional position before insertion point
/// * `right` - Optional position after insertion point
///
/// # Returns
/// * Position string that maintains lexicographic ordering: left < result < right
pub fn position_between(left: Option<&str>, right: Option<&str>) -> Result<String> {
    match (left, right) {
        // Empty playlist: use first position
        (None, None) => Ok("a0".to_string()),

        // Insert at end: append delimiter + first position
        (Some(left_pos), None) => Ok(increment_position_string(left_pos)),

        // Insert at beginning
        (None, Some(right_pos)) => {
            if right_pos > "a0" {
                Ok("a0".to_string())
            } else {
                // Right is <= "a0", need position before it
                midpoint_position_string("", right_pos)
            }
        }

        // Insert between two positions
        (Some(left_pos), Some(right_pos)) => midpoint_position_string(left_pos, right_pos),
    }
}

/// Increments a position string by appending delimiter and first position.
fn increment_position_string(pos: &str) -> String {
    format!("{}{}{}", pos, DELIMITER, "a0")
}

/// Computes the midpoint position string between left and right.
fn midpoint_position_string(left: &str, right: &str) -> Result<String> {
    let left_chars: Vec<char> = left.chars().collect();
    let right_chars: Vec<char> = right.chars().collect();
    let alphabet_chars: Vec<char> = ALPHABET.chars().collect();

    let mut result = String::new();
    let mut i = 0;

    loop {
        let left_char = left_chars.get(i).copied();
        let right_char = right_chars.get(i).copied();

        match (left_char, right_char) {
            // Same character at position i - continue
            (Some(l), Some(r)) if l == r => {
                result.push(l);
                i += 1;
            }
            // Different characters at position i
            (Some(l), Some(r)) => {
                let l_idx = ALPHABET.find(l).unwrap_or(0);
                let r_idx = ALPHABET.find(r).unwrap_or(0);

                // If adjacent characters, extend left with delimiter
                if r_idx <= l_idx + 1 {
                    result.push(l);
                    result.push(DELIMITER);
                    let mid_idx = alphabet_chars.len() / 2;
                    result.push(alphabet_chars[mid_idx]);
                    return Ok(result);
                }

                // Non-adjacent: use midpoint character
                let mid_idx = (l_idx + r_idx) / 2;
                result.push(alphabet_chars[mid_idx]);
                return Ok(result);
            }
            // Left ended, right continues
            (None, Some(r)) => {
                let r_idx = ALPHABET.find(r).unwrap_or(0);
                if r_idx > 0 {
                    // Use midpoint between start and r
                    let mid_idx = r_idx / 2;
                    result.push(alphabet_chars[mid_idx]);
                } else {
                    // r is first char - use delimiter approach
                    if result.is_empty() {
                        return Ok(format!("{}{}", DELIMITER, alphabet_chars[0]));
                    } else {
                        result.push(DELIMITER);
                        result.push(alphabet_chars[0]);
                    }
                }
                return Ok(result);
            }
            // Right ended, left continues
            (Some(_), None) => {
                result.push(DELIMITER);
                result.push(alphabet_chars[0]);
                return Ok(result);
            }
            // Both ended
            (None, None) => {
                result.push(DELIMITER);
                result.push(alphabet_chars[0]);
                return Ok(result);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_position_between_empty_playlist() {
        let pos = position_between(None, None).unwrap();
        assert_eq!(pos, "a0");
    }

    #[test]
    fn test_position_between_insert_at_end() {
        let pos = position_between(Some("a0"), None).unwrap();
        assert_eq!(pos, "a0|a0");
        assert!(pos.as_str() > "a0");

        let pos2 = position_between(Some("z9"), None).unwrap();
        assert_eq!(pos2, "z9|a0");
        assert!(pos2.as_str() > "z9");
    }

    #[test]
    fn test_position_between_insert_at_beginning() {
        let pos = position_between(None, Some("b0")).unwrap();
        assert_eq!(pos, "a0");
        assert!(pos.as_str() < "b0");

        // Edge case: right is "a0" or less
        let pos2 = position_between(None, Some("a0")).unwrap();
        assert!(pos2.as_str() < "a0", "Expected {} < a0", pos2);
    }

    #[test]
    fn test_position_between_insert_between() {
        let pos = position_between(Some("a0"), Some("b0")).unwrap();
        assert!(pos.as_str() > "a0");
        assert!(pos.as_str() < "b0");

        // Adjacent positions
        let pos2 = position_between(Some("a0"), Some("a1")).unwrap();
        assert!(pos2.as_str() > "a0");
        assert!(pos2.as_str() < "a1");
    }

    #[test]
    fn test_position_lexicographic_ordering() {
        // Test that multiple insertions maintain order
        let p1 = position_between(None, None).unwrap(); // "a0"
        let p2 = position_between(Some(&p1), None).unwrap(); // "a0|a0"
        let p3 = position_between(Some(&p2), None).unwrap(); // "a0|a0|a0"

        assert!(p1 < p2);
        assert!(p2 < p3);

        // Insert between p1 and p2
        let p_mid = position_between(Some(&p1), Some(&p2)).unwrap();
        assert!(p1.as_str() < p_mid.as_str(), "Expected {} < {}", p1, p_mid);
        assert!(p_mid.as_str() < p2.as_str(), "Expected {} < {}", p_mid, p2);
    }

    #[test]
    fn test_increment_position_string() {
        assert_eq!(increment_position_string("a0"), "a0|a0");
        assert_eq!(increment_position_string("z9"), "z9|a0");
        assert_eq!(increment_position_string("test"), "test|a0");
    }

    #[test]
    fn test_midpoint_position_string() {
        // Basic midpoint
        let mid = midpoint_position_string("a0", "z0").unwrap();
        assert!(mid.as_str() > "a0");
        assert!(mid.as_str() < "z0");

        // Adjacent characters
        let mid2 = midpoint_position_string("a0", "a1").unwrap();
        assert!(mid2.as_str() > "a0");
        assert!(mid2.as_str() < "a1");

        // Different lengths
        let mid3 = midpoint_position_string("a", "b").unwrap();
        assert!(mid3.as_str() > "a");
        assert!(mid3.as_str() < "b");
    }
}
