//! Duplicate detection module for identifying and marking duplicate tracks.
//!
//! Detects duplicates via metadata matching (artist, album, title) and marks
//! lower-quality versions as duplicates in the database.
//!
//! Quality hierarchy: lossless > lossy, then bitrate descending.

pub mod detector;

pub use detector::mark_duplicates;
