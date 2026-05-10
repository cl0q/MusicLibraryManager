//! Acoustic fingerprinting module for audio identification and duplicate detection.
//!
//! This module provides:
//! - Chromaprint fingerprint generation from audio files
//! - AcoustID lookup for MusicBrainz identification
//! - Local fingerprint comparison for duplicate detection

pub mod acoustid;
pub mod chromaprint;
pub mod matcher;

// Re-export key functions
pub use acoustid::lookup_acoustid;
pub use chromaprint::{batch_fingerprint, fingerprint_track};
pub use matcher::compare_fingerprints;
