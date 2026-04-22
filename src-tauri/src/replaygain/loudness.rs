//! Phase 18 loudness pipeline: integrated loudness, LRA, true peak (dBFS),
//! spectral centroid (ffmpeg), and derived energy bucket.
//!
//! Shape-complementary to `replaygain::analyzer`: ReplayGain is ReplayGain,
//! this module is the More-Info-panel data set. Both write to the `tracks`
//! table (columns added in schema v14): `lufs_i`, `lufs_range`, `true_peak`,
//! `energy_bucket`.
//!
//! # Pipeline
//!
//! 1. `replaygain::analyzer::analyze_track_full` runs EBU R128 over decoded
//!    PCM (pure Rust, same crate the replaygain pass uses) and returns
//!    LUFS-I, LRA, true peak in dBFS, plus ReplayGain values.
//! 2. `ffmpeg_spectral_centroid_hz` shells out to ffmpeg's `aspectralstats`
//!    filter (available in ffmpeg ≥ 4.4). The filter prints per-frame
//!    centroid values to stderr; we average them.
//! 3. `derive_energy_bucket(lufs_i, centroid)` combines the two into a
//!    1..=5 bucket. LUFS-I sets the base band; centroid nudges ±1.
//!
//! # Energy formula (tunable)
//!
//! LUFS bands (CONTRACT §3 item 5):
//! * `-14..−10` → 5
//! * `-18..−14` → 4
//! * `-22..−18` → 3
//! * `-26..−22` → 2
//! * `<−26`    → 1
//!
//! Centroid nudge:
//! * `> 2000 Hz` → `+1` (bright)
//! * `< 800 Hz`  → `-1` (dark)
//! * else        → `0`
//!
//! Result is clamped to `1..=5`.

use std::path::Path;
use std::process::Command;

use rusqlite::Connection;

use crate::replaygain::analyzer::{analyze_track_full, AnalyzerError, FullLoudnessResult};

/// Combined result persisted to the tracks table by Phase 18.
#[derive(Debug, Clone)]
pub struct LoudnessAnalysis {
    pub loudness: FullLoudnessResult,
    /// Spectral centroid in Hz. `None` when the ffmpeg pass failed or
    /// returned no data — the energy bucket derivation treats this as
    /// "no nudge".
    pub spectral_centroid_hz: Option<f64>,
    pub energy_bucket: u8,
}

/// Run the two-pass loudness + centroid analysis and derive the energy
/// bucket. Never calls the database — caller persists via
/// [`save_loudness`].
pub fn analyze_track_loudness(path: &Path) -> Result<LoudnessAnalysis, AnalyzerError> {
    let loudness = analyze_track_full(path)?;
    // Centroid failures are non-fatal — we still persist loudness.
    let spectral_centroid_hz = match ffmpeg_spectral_centroid_hz(path) {
        Ok(v) => Some(v),
        Err(e) => {
            log::warn!(
                "Spectral centroid pass failed for {}: {} — energy bucket will use LUFS-only band",
                path.display(),
                e
            );
            None
        }
    };
    let energy_bucket = derive_energy_bucket(loudness.lufs_i, spectral_centroid_hz);
    Ok(LoudnessAnalysis {
        loudness,
        spectral_centroid_hz,
        energy_bucket,
    })
}

/// Persist all loudness columns on `tracks` for the given track id.
pub fn save_loudness(
    conn: &Connection,
    track_id: i64,
    analysis: &LoudnessAnalysis,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE tracks
         SET lufs_i = ?1,
             lufs_range = ?2,
             true_peak = ?3,
             energy_bucket = ?4
         WHERE id = ?5",
        rusqlite::params![
            analysis.loudness.lufs_i,
            analysis.loudness.lufs_range,
            analysis.loudness.true_peak_dbfs,
            analysis.energy_bucket as i64,
            track_id,
        ],
    )?;
    Ok(())
}

/// Get all track ids whose `lufs_i` is NULL AND have a concrete file on disk
/// (`organized_path IS NOT NULL`). Remote-only tracks are skipped.
pub fn get_unanalyzed_loudness_tracks(
    conn: &Connection,
) -> Result<Vec<(i64, String, String)>, rusqlite::Error> {
    // Returns (id, original_path, organized_path). Caller resolves which
    // path actually points to a readable file (same resolution pattern as
    // sync::progress).
    let mut stmt = conn.prepare(
        "SELECT id, original_path, COALESCE(organized_path, '')
         FROM tracks
         WHERE lufs_i IS NULL AND organized_path IS NOT NULL",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
    })?;
    rows.collect()
}

/// Derive energy bucket (1..=5) from integrated loudness and optional
/// spectral centroid. See module-level docs for the exact cutoffs.
///
/// Pure function: testable without disk or ffmpeg.
pub fn derive_energy_bucket(lufs_i: f64, spectral_centroid_hz: Option<f64>) -> u8 {
    // Silence / near-silence → 1
    if !lufs_i.is_finite() || lufs_i < -70.0 {
        return 1;
    }
    let mut base: i32 = if lufs_i >= -14.0 {
        5
    } else if lufs_i >= -18.0 {
        4
    } else if lufs_i >= -22.0 {
        3
    } else if lufs_i >= -26.0 {
        2
    } else {
        1
    };
    if let Some(c) = spectral_centroid_hz {
        if c > 2000.0 {
            base += 1;
        } else if c < 800.0 {
            base -= 1;
        }
    }
    base.clamp(1, 5) as u8
}

/// Shell out to ffmpeg to compute the mean spectral centroid (Hz) across
/// audio frames. Uses the `aspectralstats` filter (available in ffmpeg
/// ≥ 4.4) plus `ametadata=print` which dumps per-frame values to stderr.
/// We parse lines of the form:
///
/// ```text
/// [Parsed_ametadata_1 @ 0x...] lavfi.aspectralstats.1.centroid=1352.51
/// ```
///
/// and average them. If no lines match, fall back to `astats` with the
/// `Spectral_centroid` metadata key (older ffmpeg builds).
pub fn ffmpeg_spectral_centroid_hz(path: &Path) -> anyhow::Result<f64> {
    // Primary: aspectralstats + ametadata=print
    //
    // Filter chain detail: `aspectralstats=measure=centroid` keeps the
    // computation cheap (we only need centroid, not flux / rolloff / etc).
    // `ametadata=print` emits per-frame values to stderr via the logger.
    let out = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-nostats",
            "-i",
            &path.display().to_string(),
            "-af",
            "aspectralstats=measure=centroid,ametadata=print",
            "-f",
            "null",
            "-",
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("ffmpeg spawn failed: {}", e))?;

    let stderr = String::from_utf8_lossy(&out.stderr);
    let mut sum = 0.0_f64;
    let mut n = 0_u64;
    for line in stderr.lines() {
        // Fast contains check before substring parsing.
        if !line.contains("centroid=") {
            continue;
        }
        if let Some((_, tail)) = line.rsplit_once("centroid=") {
            let val = tail.split_whitespace().next().unwrap_or(tail);
            if let Ok(v) = val.trim().parse::<f64>() {
                if v.is_finite() && v >= 0.0 {
                    sum += v;
                    n += 1;
                }
            }
        }
    }

    if n > 0 {
        return Ok(sum / n as f64);
    }

    // Fallback path — older ffmpeg builds expose spectral centroid via
    // astats under `lavfi.astats.Overall.Spectral_centroid_Hz`. We try
    // this before failing the analysis.
    log::debug!(
        "aspectralstats produced no centroid frames for {}; falling back to astats",
        path.display()
    );
    let out2 = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-nostats",
            "-i",
            &path.display().to_string(),
            "-af",
            "astats=metadata=1:reset=0,ametadata=print",
            "-f",
            "null",
            "-",
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("ffmpeg astats spawn failed: {}", e))?;

    let stderr2 = String::from_utf8_lossy(&out2.stderr);
    let mut sum2 = 0.0_f64;
    let mut n2 = 0_u64;
    for line in stderr2.lines() {
        if !line.contains("Spectral_centroid") {
            continue;
        }
        if let Some((_, tail)) = line.rsplit_once('=') {
            if let Ok(v) = tail.trim().parse::<f64>() {
                if v.is_finite() && v >= 0.0 {
                    sum2 += v;
                    n2 += 1;
                }
            }
        }
    }

    if n2 > 0 {
        Ok(sum2 / n2 as f64)
    } else {
        anyhow::bail!("no spectral centroid frames emitted by ffmpeg");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn energy_bucket_bands_without_centroid() {
        // Centre of each LUFS band → base value.
        assert_eq!(derive_energy_bucket(-12.0, None), 5);
        assert_eq!(derive_energy_bucket(-16.0, None), 4);
        assert_eq!(derive_energy_bucket(-20.0, None), 3);
        assert_eq!(derive_energy_bucket(-24.0, None), 2);
        assert_eq!(derive_energy_bucket(-30.0, None), 1);
    }

    #[test]
    fn energy_bucket_band_boundaries() {
        // Upper boundary of each band (inclusive on the upper side per spec).
        assert_eq!(derive_energy_bucket(-14.0, None), 5); // −14..−10 band
        assert_eq!(derive_energy_bucket(-18.0, None), 4);
        assert_eq!(derive_energy_bucket(-22.0, None), 3);
        assert_eq!(derive_energy_bucket(-26.0, None), 2);
    }

    #[test]
    fn energy_bucket_bright_nudge() {
        // Loud-ish + bright centroid clamps at 5 (already at ceiling).
        assert_eq!(derive_energy_bucket(-12.0, Some(3500.0)), 5);
        // Mid-band + bright nudges up by 1.
        assert_eq!(derive_energy_bucket(-20.0, Some(2500.0)), 4);
    }

    #[test]
    fn energy_bucket_dark_nudge() {
        // Mid-band + dark nudges down by 1.
        assert_eq!(derive_energy_bucket(-20.0, Some(500.0)), 2);
        // Floor clamp: already 1, dark nudge can't drop below 1.
        assert_eq!(derive_energy_bucket(-30.0, Some(400.0)), 1);
    }

    #[test]
    fn energy_bucket_mid_centroid_no_nudge() {
        // 1200 Hz is in the neutral zone (800..=2000).
        assert_eq!(derive_energy_bucket(-20.0, Some(1200.0)), 3);
    }

    #[test]
    fn energy_bucket_silence_is_one() {
        // Silence per analyzer convention → lufs_i = -70.0 or less.
        assert_eq!(derive_energy_bucket(-70.0, None), 1);
        assert_eq!(derive_energy_bucket(f64::NEG_INFINITY, None), 1);
    }

    #[test]
    fn save_loudness_round_trips() {
        use crate::database::schema::initialize_schema;

        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
             VALUES (?, ?, ?, ?, ?, ?)",
            ["A", "A", "Al", "T", "flac", "/p.flac"],
        )
        .unwrap();
        let id = conn.last_insert_rowid();

        let analysis = LoudnessAnalysis {
            loudness: FullLoudnessResult {
                track_gain: -4.5,
                track_peak: 0.912,
                lufs_i: -13.5,
                lufs_range: 6.2,
                true_peak_dbfs: -0.8,
            },
            spectral_centroid_hz: Some(2800.0),
            energy_bucket: 5,
        };
        save_loudness(&conn, id, &analysis).unwrap();

        let (lufs, lra, peak, energy): (f64, f64, f64, i64) = conn
            .query_row(
                "SELECT lufs_i, lufs_range, true_peak, energy_bucket FROM tracks WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert!((lufs + 13.5).abs() < 1e-9);
        assert!((lra - 6.2).abs() < 1e-9);
        assert!((peak + 0.8).abs() < 1e-9);
        assert_eq!(energy, 5);
    }

    #[test]
    fn get_unanalyzed_skips_remote_tracks() {
        use crate::database::schema::initialize_schema;

        let conn = Connection::open_in_memory().unwrap();
        initialize_schema(&conn).unwrap();

        // Remote track — no organized_path, should be skipped.
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?, ?, ?, ?, ?, ?, NULL)",
            ["R", "R", "Rm", "T1", "spotify", "/spot/1"],
        ).unwrap();

        // Local track — has organized_path, unanalyzed.
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            ["L", "L", "Lm", "T2", "flac", "/abs/p.flac", "rel/p.flac"],
        ).unwrap();

        let rows = get_unanalyzed_loudness_tracks(&conn).unwrap();
        assert_eq!(rows.len(), 1, "should only list the local track");
        assert_eq!(rows[0].1, "/abs/p.flac");
        assert_eq!(rows[0].2, "rel/p.flac");
    }
}
