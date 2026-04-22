//! ReplayGain 2.0 loudness analysis and tagging.
//!
//! This module provides EBU R128 loudness analysis producing ReplayGain 2.0 values,
//! database persistence for gain values, and tag writing to synced file copies only.
//!
//! ## Key Concepts
//!
//! - **Track Gain**: Individual track loudness normalization
//! - **Album Gain**: Album-level loudness normalization (preserves dynamic range between tracks)
//! - **ReplayGain 2.0 Reference**: -18 LUFS (not -23 used in EBU R128 broadcasting)
//! - **Library Originals Stay Pristine**: Tags written only to synced copies during sync pipeline
//!
//! ## Usage
//!
//! ```no_run
//! use music_library_manager::replaygain::{analyze_track, GainResult};
//! use std::path::Path;
//!
//! let gain = analyze_track(Path::new("track.mp3")).unwrap();
//! println!("Track gain: {:.2} dB, Peak: {:.6}", gain.track_gain, gain.track_peak);
//! ```

pub mod analyzer;
pub mod loudness;
pub mod tagger;

// Re-export public API
pub use analyzer::{
    analyze_album, analyze_track, batch_analyze, get_track_gain, get_unanalyzed_tracks,
    save_album_gain, save_track_gain, AlbumGainResult, BatchAnalyzeResult, GainResult,
};
pub use tagger::{read_gain_tags, write_gain_tags};
