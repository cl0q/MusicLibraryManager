//! ReplayGain tag writing to synced file copies using lofty.
//!
//! Tags are written only to synced copies during the sync pipeline, never to library originals.

use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TaggerError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Lofty error: {0}")]
    Lofty(String),

    #[error("No primary tag found in file")]
    NoTag,
}

/// Write ReplayGain 2.0 tags to an audio file.
///
/// # Arguments
/// * `file_path` - Path to audio file (synced copy, not library original)
/// * `track_gain` - Track gain in dB
/// * `track_peak` - Track peak as linear value
/// * `album_gain` - Optional album gain in dB
/// * `album_peak` - Optional album peak as linear value
///
/// # Returns
/// * `Ok(())` - Tags written successfully
/// * `Err` - If file cannot be read/written or has no primary tag
pub fn write_gain_tags(
    _file_path: &Path,
    _track_gain: f64,
    _track_peak: f64,
    _album_gain: Option<f64>,
    _album_peak: Option<f64>,
) -> Result<(), TaggerError> {
    // TODO: Implement in Task 2
    todo!("Task 2: write_gain_tags implementation")
}

/// Read ReplayGain tags from an audio file.
///
/// # Arguments
/// * `file_path` - Path to audio file
///
/// # Returns
/// * `Ok(Some((track_gain, track_peak)))` - Gain tags found
/// * `Ok(None)` - No gain tags in file
/// * `Err` - If file cannot be read
pub fn read_gain_tags(_file_path: &Path) -> Result<Option<(f64, f64)>, TaggerError> {
    // TODO: Implement in Task 2
    todo!("Task 2: read_gain_tags implementation")
}
