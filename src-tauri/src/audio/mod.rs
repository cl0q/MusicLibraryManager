//! Audio processing utilities for Phase 7 enhancements.
//!
//! Provides shared infrastructure for:
//! - PCM decoding for fingerprinting and ReplayGain analysis
//! - Audio format detection and validation

pub mod decoder;

pub use decoder::decode_to_pcm;
