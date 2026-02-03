//! Search query execution with fuzzy scoring.
//!
//! Placeholder - full implementation in Task 2.

use serde::Serialize;

use crate::database::Result as DbResult;
use crate::models::track::Track;

/// Search result with fuzzy match score.
#[derive(Debug, Serialize)]
pub struct SearchResult {
    /// The matched track
    pub track: Track,
    /// Fuzzy match score (0.0 - 1.0)
    pub score: f64,
}

/// Searches tracks by query with fuzzy matching.
///
/// Placeholder - full implementation coming in Task 2.
pub fn search_tracks(
    _conn: &rusqlite::Connection,
    _query: &str,
) -> DbResult<Vec<SearchResult>> {
    // Full implementation in Task 2
    Ok(vec![])
}
