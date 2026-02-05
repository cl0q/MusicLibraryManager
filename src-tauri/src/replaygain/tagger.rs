//! ReplayGain tag writing to synced file copies using lofty.
//!
//! Tags are written only to synced copies during the sync pipeline, never to library originals.

use lofty::config::WriteOptions;
use lofty::file::AudioFile;
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem, TagType};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TaggerError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Lofty error: {0}")]
    LoftyError(#[from] lofty::error::LoftyError),

    #[error("Parse error: {0}")]
    Parse(String),

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
    file_path: &Path,
    track_gain: f64,
    track_peak: f64,
    album_gain: Option<f64>,
    album_peak: Option<f64>,
) -> Result<(), TaggerError> {
    // Open the audio file
    let probe = Probe::open(file_path)?;
    let mut tagged_file = probe.read()?;

    // Get or create primary tag
    let tag = if let Some(primary_tag) = tagged_file.primary_tag_mut() {
        primary_tag
    } else {
        // No primary tag exists, create one
        let tag_type = tagged_file.primary_tag_type();
        tagged_file.insert_tag(Tag::new(tag_type));
        tagged_file.primary_tag_mut().ok_or(TaggerError::NoTag)?
    };

    // Write ReplayGain 2.0 track tags
    // Format: "{:.2} dB" for gain, "{:.6}" for peak
    let track_gain_str = format!("{:.2} dB", track_gain);
    let track_peak_str = format!("{:.6}", track_peak);

    tag.insert(TagItem::new(
        ItemKey::ReplayGainTrackGain,
        ItemValue::Text(track_gain_str),
    ));
    tag.insert(TagItem::new(
        ItemKey::ReplayGainTrackPeak,
        ItemValue::Text(track_peak_str),
    ));

    // Write album tags if provided
    if let (Some(album_gain), Some(album_peak)) = (album_gain, album_peak) {
        let album_gain_str = format!("{:.2} dB", album_gain);
        let album_peak_str = format!("{:.6}", album_peak);

        tag.insert(TagItem::new(
            ItemKey::ReplayGainAlbumGain,
            ItemValue::Text(album_gain_str),
        ));
        tag.insert(TagItem::new(
            ItemKey::ReplayGainAlbumPeak,
            ItemValue::Text(album_peak_str),
        ));
    }

    // Save changes
    tagged_file.save_to_path(file_path, WriteOptions::default())?;

    Ok(())
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
pub fn read_gain_tags(file_path: &Path) -> Result<Option<(f64, f64)>, TaggerError> {
    // Open the audio file
    let probe = Probe::open(file_path)?;
    let tagged_file = probe.read()?;

    // Get primary tag
    let tag = match tagged_file.primary_tag() {
        Some(t) => t,
        None => return Ok(None), // No tags = no gain values
    };

    // Try to read track gain and peak
    let track_gain_str = match tag.get(&ItemKey::ReplayGainTrackGain) {
        Some(item) => match item.value() {
            ItemValue::Text(s) => s.as_str(),
            _ => return Ok(None),
        },
        None => return Ok(None),
    };

    let track_peak_str = match tag.get(&ItemKey::ReplayGainTrackPeak) {
        Some(item) => match item.value() {
            ItemValue::Text(s) => s.as_str(),
            _ => return Ok(None),
        },
        None => return Ok(None),
    };

    // Parse gain: "X.XX dB" format
    let track_gain = track_gain_str
        .trim_end_matches(" dB")
        .trim_end_matches("dB")
        .trim()
        .parse::<f64>()
        .ok()
        .ok_or_else(|| TaggerError::Parse("Invalid ReplayGain format".to_string()))?;

    // Parse peak: "X.XXXXXX" format
    let track_peak = track_peak_str
        .trim()
        .parse::<f64>()
        .ok()
        .ok_or_else(|| TaggerError::Parse("Invalid ReplayGain peak format".to_string()))?;

    Ok(Some((track_gain, track_peak)))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: Full write/read tests would require a valid audio file
    // These tests verify the compilation and basic structure

    #[test]
    fn test_write_gain_tags_compiles() {
        // This test verifies the function signature compiles correctly
        // A full test requires an actual audio file

        // The function should accept these parameters
        let _result: Result<(), TaggerError> = write_gain_tags(
            Path::new("nonexistent.m4a"),
            -6.5,
            0.85,
            Some(-5.0),
            Some(0.90),
        );

        // Should fail with IO error (file not found)
        // We don't actually run it to avoid test failures
    }

    #[test]
    fn test_read_gain_tags_compiles() {
        // Verify function signature
        let _result: Result<Option<(f64, f64)>, TaggerError> =
            read_gain_tags(Path::new("nonexistent.m4a"));

        // Should fail with IO error (file not found)
    }
}
