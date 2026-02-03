//! Deduplication module for track normalization and fuzzy matching.
//!
//! Provides string normalization and duplicate detection for tracks
//! across different sources (Spotify, SoundCloud). Handles variations
//! in track names, artist names, and featuring notation.

pub mod matcher;
pub mod normalize;

pub use matcher::{calculate_similarity, is_variant};
pub use normalize::{normalize, normalize_artist};
