//! Full-text search module for the music library.
//!
//! Provides Tantivy-based indexing and fuzzy matching for instant library queries.
//!
//! # Architecture
//! Two-pass search strategy:
//! 1. **Candidate retrieval**: Database LIKE query for initial filtering
//! 2. **Fuzzy scoring**: Jaro-Winkler + Levenshtein scoring for ranking
//!
//! # Example
//! ```ignore
//! use music_library_manager::search::query::{search_tracks, SearchResult};
//! use music_library_manager::database::get_connection;
//! use std::path::Path;
//!
//! let conn = get_connection(Path::new("library.db"))?;
//! let results = search_tracks(&conn, "beatls")?; // Fuzzy matches "Beatles"
//! ```

pub mod indexer;
pub mod query;

// Re-export commonly used items
pub use indexer::{commit_index, create_index, index_track, SearchIndex};
pub use query::{search_tracks, SearchResult};
