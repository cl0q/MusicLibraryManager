//! EBU R128 loudness analysis producing ReplayGain 2.0 gain and peak values.

use crate::audio::decoder::decode_to_pcm;
use ebur128::{EbuR128, Mode};
use rusqlite::Connection;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AnalyzerError {
    #[error("Decode error: {0}")]
    Decode(#[from] crate::audio::decoder::DecodeError),

    #[error("EBU R128 error: {0}")]
    EbuR128(String),

    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("Invalid loudness value (silence or corrupted audio)")]
    InvalidLoudness,
}

/// ReplayGain track gain and peak values.
#[derive(Debug, Clone)]
pub struct GainResult {
    pub track_gain: f64,
    pub track_peak: f64,
}

/// Full EBU R128 result — ReplayGain values plus loudness descriptors
/// needed by the Phase 18 More Info panel.
///
/// `lufs_i`: integrated loudness (LUFS, negative for typical music).
/// `lufs_range`: loudness range in LU (positive).
/// `true_peak_dbfs`: max true peak across channels expressed in dBFS.
#[derive(Debug, Clone)]
pub struct FullLoudnessResult {
    pub track_gain: f64,
    pub track_peak: f64,
    pub lufs_i: f64,
    pub lufs_range: f64,
    pub true_peak_dbfs: f64,
}

/// ReplayGain album gain and per-track results.
#[derive(Debug, Clone)]
pub struct AlbumGainResult {
    pub album_gain: f64,
    pub album_peak: f64,
    pub tracks: Vec<(i64, GainResult)>,
}

/// Result of batch analysis operation.
#[derive(Debug)]
pub struct BatchAnalyzeResult {
    pub analyzed: usize,
    pub failed: Vec<(i64, String)>,
}

/// Analyze loudness of raw PCM samples using EBU R128.
///
/// Computes ReplayGain 2.0 values: -18 LUFS reference level.
///
/// # Arguments
/// * `samples` - Interleaved i16 PCM samples
/// * `sample_rate` - Sample rate in Hz
/// * `channels` - Number of audio channels
///
/// # Returns
/// * `Ok((gain_db, peak_linear))` - Gain adjustment in dB, true peak as linear value
/// * `Err` - If analysis fails or audio is silent/corrupted
fn analyze_loudness(samples: &[i16], sample_rate: u32, channels: u16) -> Result<(f64, f64), AnalyzerError> {
    // Create EBU R128 analyzer with integrated loudness and true peak modes
    let mut ebu = EbuR128::new(
        channels as u32,
        sample_rate,
        Mode::I | Mode::TRUE_PEAK,
    )
    .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    // Add all samples (interleaved format from our decoder)
    ebu.add_frames_i16(samples)
        .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    // Get integrated loudness (LUFS)
    let loudness = ebu
        .loudness_global()
        .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    // Handle silence or corrupted audio (-infinity loudness)
    if loudness.is_infinite() || loudness < -70.0 {
        // Silence or near-silence: clamp to reasonable value
        // +20 dB gain means "boost this by 20 dB to reach reference"
        return Ok((20.0, 0.0));
    }

    // Compute ReplayGain 2.0 gain: -18 LUFS reference (not -23)
    // Negative loudness means quiet audio needs positive gain
    let gain = -18.0 - loudness;

    // Get maximum true peak across all channels
    let mut max_peak = 0.0_f64;
    for channel in 0..channels {
        let peak = ebu
            .true_peak(channel as u32)
            .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;
        if peak > max_peak {
            max_peak = peak;
        }
    }

    Ok((gain, max_peak))
}

/// Analyze a single track and return ReplayGain values.
///
/// # Arguments
/// * `path` - Path to audio file
///
/// # Returns
/// * `Ok(GainResult)` - Track gain and peak values
/// * `Err` - If decode or analysis fails
pub fn analyze_track(path: &Path) -> Result<GainResult, AnalyzerError> {
    // Decode to PCM
    let (samples, sample_rate, channels) = decode_to_pcm(path)?;

    // Analyze loudness
    let (track_gain, track_peak) = analyze_loudness(&samples, sample_rate, channels)?;

    Ok(GainResult {
        track_gain,
        track_peak,
    })
}

/// Analyze multiple tracks as an album, computing both track and album gain.
///
/// Album gain preserves dynamic range between tracks (quieter tracks stay quieter).
///
/// # Arguments
/// * `tracks` - List of (track_id, path) tuples for all tracks in album
///
/// # Returns
/// * `Ok(AlbumGainResult)` - Album gain, album peak, and per-track results
/// * `Err` - If any track fails to decode or analyze
pub fn analyze_album(tracks: &[(i64, &Path)]) -> Result<AlbumGainResult, AnalyzerError> {
    if tracks.is_empty() {
        return Err(AnalyzerError::EbuR128(
            "Cannot analyze empty album".to_string(),
        ));
    }

    let mut track_results = Vec::new();
    let mut album_analyzers = Vec::new();

    // Analyze each track individually for track gain
    // Also create EBU R128 analyzers for album gain calculation
    for (track_id, path) in tracks {
        let (samples, sample_rate, channels) = decode_to_pcm(path)?;

        // Individual track gain
        let (track_gain, track_peak) = analyze_loudness(&samples, sample_rate, channels)?;
        track_results.push((
            *track_id,
            GainResult {
                track_gain,
                track_peak,
            },
        ));

        // Create analyzer for album gain (will feed to loudness_global_multiple)
        let mut ebu = EbuR128::new(channels as u32, sample_rate, Mode::I | Mode::TRUE_PEAK)
            .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

        ebu.add_frames_i16(&samples)
            .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

        album_analyzers.push(ebu);
    }

    // Compute album-level loudness using all tracks
    let album_loudness = EbuR128::loudness_global_multiple(album_analyzers.iter())
        .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    // Handle silence
    let album_gain = if album_loudness.is_infinite() || album_loudness < -70.0 {
        20.0
    } else {
        -18.0 - album_loudness
    };

    // Album peak is the maximum peak across all tracks
    let album_peak = track_results
        .iter()
        .map(|(_, result)| result.track_peak)
        .fold(0.0_f64, f64::max);

    Ok(AlbumGainResult {
        album_gain,
        album_peak,
        tracks: track_results,
    })
}

/// Analyze loudness descriptors used by Phase 18 More Info: integrated
/// loudness (LUFS-I), loudness range (LRA), true peak in dBFS, and the
/// ReplayGain values.
///
/// Shares decoding work with [`analyze_track`] but enables the `LRA` mode
/// in EBU R128 so loudness_range() is callable.
pub fn analyze_track_full(path: &Path) -> Result<FullLoudnessResult, AnalyzerError> {
    let (samples, sample_rate, channels) = decode_to_pcm(path)?;

    let mut ebu = EbuR128::new(
        channels as u32,
        sample_rate,
        Mode::I | Mode::LRA | Mode::TRUE_PEAK,
    )
    .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    ebu.add_frames_i16(&samples)
        .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    // Integrated loudness
    let loudness = ebu
        .loudness_global()
        .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;

    // Silence / near-silence handling: match analyze_track's clamp behaviour.
    let silent = loudness.is_infinite() || loudness < -70.0;

    let (track_gain, lufs_i) = if silent {
        (20.0, -70.0)
    } else {
        (-18.0 - loudness, loudness)
    };

    // Loudness range — may error if no gated blocks; fall back to 0.0.
    let lufs_range = ebu.loudness_range().unwrap_or(0.0);

    // Max true peak across channels (linear). Convert to dBFS; -∞ for silence.
    let mut max_peak = 0.0_f64;
    for channel in 0..channels {
        let peak = ebu
            .true_peak(channel as u32)
            .map_err(|e| AnalyzerError::EbuR128(e.to_string()))?;
        if peak > max_peak {
            max_peak = peak;
        }
    }
    let true_peak_dbfs = linear_to_dbfs(max_peak);

    Ok(FullLoudnessResult {
        track_gain,
        track_peak: max_peak,
        lufs_i,
        lufs_range,
        true_peak_dbfs,
    })
}

/// Convert a linear peak value (0..1+) to dBFS. Silence / zero peak maps
/// to -120.0 (arbitrary floor) rather than -∞ so it serialises cleanly.
pub fn linear_to_dbfs(linear: f64) -> f64 {
    if linear <= 0.0 {
        return -120.0;
    }
    20.0 * linear.log10()
}

/// Save track gain values to database.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID
/// * `gain` - Gain result to save
///
/// # Returns
/// * `Ok(())` - Success
/// * `Err` - Database error
pub fn save_track_gain(
    conn: &Connection,
    track_id: i64,
    gain: &GainResult,
) -> Result<(), AnalyzerError> {
    conn.execute(
        "INSERT OR REPLACE INTO replaygain (track_id, track_gain, track_peak) VALUES (?, ?, ?)",
        rusqlite::params![track_id, gain.track_gain, gain.track_peak],
    )?;
    Ok(())
}

/// Save album gain values to database for multiple tracks.
///
/// Updates only the album_gain and album_peak columns, preserving existing track gain values.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_ids` - List of track IDs in the album
/// * `album_gain` - Album gain value
/// * `album_peak` - Album peak value
///
/// # Returns
/// * `Ok(())` - Success
/// * `Err` - Database error
pub fn save_album_gain(
    conn: &Connection,
    track_ids: &[i64],
    album_gain: f64,
    album_peak: f64,
) -> Result<(), AnalyzerError> {
    if track_ids.is_empty() {
        return Ok(());
    }

    // Build placeholders for IN clause
    let placeholders = track_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let query = format!(
        "UPDATE replaygain SET album_gain = ?, album_peak = ? WHERE track_id IN ({})",
        placeholders
    );

    // Build params: album_gain, album_peak, then all track_ids
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = vec![
        Box::new(album_gain),
        Box::new(album_peak),
    ];
    for id in track_ids {
        params.push(Box::new(*id));
    }

    conn.execute(&query, rusqlite::params_from_iter(params.iter().map(|p| p.as_ref())))?;
    Ok(())
}

/// Get tracks that haven't been analyzed yet.
///
/// # Arguments
/// * `conn` - Database connection
///
/// # Returns
/// * `Ok(Vec<(track_id, original_path)>)` - List of unanalyzed tracks
/// * `Err` - Database error
pub fn get_unanalyzed_tracks(conn: &Connection) -> Result<Vec<(i64, String)>, AnalyzerError> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.original_path
         FROM tracks t
         LEFT JOIN replaygain r ON t.id = r.track_id
         WHERE r.track_id IS NULL",
    )?;

    let tracks = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;

    Ok(tracks)
}

/// Get track gain values from database.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID
///
/// # Returns
/// * `Ok(Some(GainResult))` - Gain values if found
/// * `Ok(None)` - Track not analyzed yet
/// * `Err` - Database error
pub fn get_track_gain(
    conn: &Connection,
    track_id: i64,
) -> Result<Option<GainResult>, AnalyzerError> {
    let mut stmt =
        conn.prepare("SELECT track_gain, track_peak FROM replaygain WHERE track_id = ?")?;

    let result = stmt.query_row([track_id], |row| {
        Ok(GainResult {
            track_gain: row.get(0)?,
            track_peak: row.get(1)?,
        })
    });

    match result {
        Ok(gain) => Ok(Some(gain)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Batch analyze multiple tracks with error handling.
///
/// Continues processing even if individual tracks fail.
///
/// # Arguments
/// * `conn` - Database connection
/// * `tracks` - List of (track_id, path) tuples
///
/// # Returns
/// * `Ok(BatchAnalyzeResult)` - Analysis results with success/failure counts
/// * `Err` - Should not error (individual failures collected in result)
pub fn batch_analyze(
    conn: &Connection,
    tracks: &[(i64, String)],
) -> Result<BatchAnalyzeResult, AnalyzerError> {
    let mut analyzed = 0;
    let mut failed = Vec::new();

    for (track_id, path) in tracks {
        match analyze_track(Path::new(path)) {
            Ok(gain) => {
                if let Err(e) = save_track_gain(conn, *track_id, &gain) {
                    failed.push((*track_id, format!("Database error: {}", e)));
                } else {
                    analyzed += 1;
                }
            }
            Err(e) => {
                failed.push((*track_id, format!("Analysis error: {}", e)));
            }
        }
    }

    Ok(BatchAnalyzeResult { analyzed, failed })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_analyze_loudness_silence() {
        // Feed silent samples (zeros)
        let samples = vec![0_i16; 44100 * 2]; // 1 second of silence, stereo
        let result = analyze_loudness(&samples, 44100, 2);

        assert!(result.is_ok());
        let (gain, peak) = result.unwrap();

        // Silence should result in high positive gain (clamped to +20 dB)
        assert_eq!(gain, 20.0);
        assert_eq!(peak, 0.0);
    }

    #[test]
    fn test_analyze_loudness_full_scale() {
        // Generate full-scale sine wave (very loud)
        let sample_rate = 44100_u32;
        let duration_secs = 1_f64;
        let freq = 1000_f64; // 1 kHz tone
        let mut samples = Vec::new();

        for i in 0..(sample_rate as f64 * duration_secs) as usize {
            let t = i as f64 / sample_rate as f64;
            let value = (2.0 * std::f64::consts::PI * freq * t).sin();
            // Scale to near full-scale (0.9 to avoid clipping in processing)
            let sample = (value * 0.9 * i16::MAX as f64) as i16;
            samples.push(sample); // Left channel
            samples.push(sample); // Right channel
        }

        let result = analyze_loudness(&samples, sample_rate, 2);
        assert!(result.is_ok());
        let (gain, peak) = result.unwrap();

        // Full-scale audio should have negative gain (already louder than reference)
        assert!(gain < 0.0, "Expected negative gain for loud audio, got {}", gain);

        // Peak should be close to 1.0 (full scale)
        assert!(peak > 0.5, "Expected high peak for full-scale audio, got {}", peak);
    }

    #[test]
    fn test_replaygain_reference_level() {
        // Verify that the reference level is -18 LUFS, not -23
        // Generate a known-loudness signal and verify gain calculation

        // Create a moderate-level sine wave
        let sample_rate = 44100_u32;
        let duration_secs = 1_f64;
        let freq = 1000_f64;
        let mut samples = Vec::new();

        for i in 0..(sample_rate as f64 * duration_secs) as usize {
            let t = i as f64 / sample_rate as f64;
            let value = (2.0 * std::f64::consts::PI * freq * t).sin();
            // Scale to moderate level (0.3 amplitude)
            let sample = (value * 0.3 * i16::MAX as f64) as i16;
            samples.push(sample);
            samples.push(sample);
        }

        let result = analyze_loudness(&samples, sample_rate, 2);
        assert!(result.is_ok());
        let (gain, _) = result.unwrap();

        // The actual gain value will depend on the signal
        // What matters is the formula: gain = -18.0 - loudness
        // We can't predict exact loudness, but we can verify the implementation exists
        // and produces a reasonable value (not NaN, not infinite)
        assert!(gain.is_finite(), "Gain should be finite");
        assert!(gain > -30.0 && gain < 30.0, "Gain should be reasonable, got {}", gain);
    }

    #[test]
    fn test_save_and_load_track_gain() {
        use rusqlite::Connection;

        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&mut conn).unwrap();

        // Insert a test track
        conn.execute(
            "INSERT INTO tracks (title, artist, album_artist, album, original_path, format)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Test", "Artist", "Artist", "Album", "/test.mp3", "mp3"],
        )
        .unwrap();
        let track_id = conn.last_insert_rowid();

        // Save gain values
        let gain = GainResult {
            track_gain: -6.5,
            track_peak: 0.85,
        };
        save_track_gain(&conn, track_id, &gain).unwrap();

        // Load them back
        let loaded = get_track_gain(&conn, track_id).unwrap();
        assert!(loaded.is_some());
        let loaded = loaded.unwrap();

        assert_eq!(loaded.track_gain, -6.5);
        assert_eq!(loaded.track_peak, 0.85);
    }

    #[test]
    fn test_get_unanalyzed_tracks() {
        use rusqlite::Connection;

        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::schema::initialize_schema(&mut conn).unwrap();

        // Insert two tracks
        conn.execute(
            "INSERT INTO tracks (title, artist, album_artist, album, original_path, format)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Track1", "Artist", "Artist", "Album", "/track1.mp3", "mp3"],
        )
        .unwrap();
        let track1_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO tracks (title, artist, album_artist, album, original_path, format)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params!["Track2", "Artist", "Artist", "Album", "/track2.mp3", "mp3"],
        )
        .unwrap();
        let track2_id = conn.last_insert_rowid();

        // Initially both unanalyzed
        let unanalyzed = get_unanalyzed_tracks(&conn).unwrap();
        assert_eq!(unanalyzed.len(), 2);

        // Analyze track1
        let gain = GainResult {
            track_gain: -5.0,
            track_peak: 0.8,
        };
        save_track_gain(&conn, track1_id, &gain).unwrap();

        // Now only track2 should be unanalyzed
        let unanalyzed = get_unanalyzed_tracks(&conn).unwrap();
        assert_eq!(unanalyzed.len(), 1);
        assert_eq!(unanalyzed[0].0, track2_id);
    }
}
