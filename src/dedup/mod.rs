//! Deduplication module for track normalization and fuzzy matching.
//!
//! Provides string normalization and duplicate detection for tracks
//! across different sources (Spotify, SoundCloud). Handles variations
//! in track names, artist names, and featuring notation.

pub mod fingerprint;
pub mod matcher;
pub mod normalize;

pub use fingerprint::{
    add_to_review_queue, deep_scan_library, detect_fingerprint_duplicates, get_review_queue,
    process_fingerprint_duplicate, resolve_review_item, DeepScanResult, ReviewQueueEntry,
    ReviewQueueRow,
};
pub use matcher::{calculate_similarity, is_variant};
pub use normalize::{normalize, normalize_artist};
