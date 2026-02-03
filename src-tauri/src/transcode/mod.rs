pub mod ffmpeg;
pub mod format;

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub use ffmpeg::{transcode_to_aac, FfmpegConfig};
pub use format::{detect_format, AudioFormat};

/// Result of a transcode operation
#[derive(Debug, Clone, PartialEq)]
pub enum TranscodeResult {
    /// AAC file successfully created at path
    Transcoded(PathBuf),
    /// Transcode skipped with reason (e.g., already lossy <248kbps)
    Skipped(String),
    /// Transcode attempted but failed, original preserved
    Failed(String),
}

/// Transcode audio file to AAC if needed
///
/// Decision logic:
/// - Lossless (FLAC, ALAC, WAV) -> always transcode to AAC
/// - Lossy <248kbps -> skip (preserve quality, avoid re-encoding)
/// - Lossy >=248kbps -> transcode to reduce file size
///
/// On failure, original file is preserved and Failed result returned.
pub async fn transcode_audio(input: &Path, output_dir: &Path) -> Result<TranscodeResult> {
    // Detect input format
    let format = detect_format(input)
        .with_context(|| format!("Failed to detect format: {}", input.display()))?;

    log::info!(
        "Detected format: codec={:?}, bitrate={:?}, lossless={}",
        format.codec,
        format.bitrate,
        format.is_lossless
    );

    // Decision logic
    if format.is_lossless {
        // Lossless -> transcode to AAC
        log::info!("Lossless format detected, transcoding to AAC");
    } else {
        // Lossy format - check bitrate
        let bitrate = format.bitrate.unwrap_or(999_000); // Assume high bitrate if unknown

        if bitrate < 248_000 {
            // Already lossy and below target - skip to avoid quality loss
            let reason = format!(
                "Already lossy <248kbps ({}kbps), preserving original",
                bitrate / 1000
            );
            log::info!("{}", reason);
            return Ok(TranscodeResult::Skipped(reason));
        } else {
            // Lossy but high bitrate - transcode to reduce size
            log::info!(
                "Lossy format at {}kbps, transcoding to 248kbps AAC to reduce size",
                bitrate / 1000
            );
        }
    }

    // Construct output path: {output_dir}/{input_stem}.m4a
    let input_stem = input
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    let output_path = output_dir.join(format!("{}.m4a", input_stem));

    // Perform transcode
    match transcode_to_aac(input, &output_path, &FfmpegConfig::default()).await {
        Ok(()) => {
            log::info!("Successfully transcoded to: {}", output_path.display());
            Ok(TranscodeResult::Transcoded(output_path))
        }
        Err(e) => {
            let error_msg = format!("Transcode failed: {}", e);
            log::error!("{}", error_msg);
            Ok(TranscodeResult::Failed(error_msg))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_transcode_result_variants() {
        let transcoded = TranscodeResult::Transcoded(PathBuf::from("/output/file.m4a"));
        assert!(matches!(transcoded, TranscodeResult::Transcoded(_)));

        let skipped = TranscodeResult::Skipped("Already lossy <248kbps".to_string());
        assert!(matches!(skipped, TranscodeResult::Skipped(_)));

        let failed = TranscodeResult::Failed("FFmpeg error".to_string());
        assert!(matches!(failed, TranscodeResult::Failed(_)));
    }

    #[test]
    fn test_transcode_result_equality() {
        let result1 = TranscodeResult::Skipped("test".to_string());
        let result2 = TranscodeResult::Skipped("test".to_string());
        assert_eq!(result1, result2);
    }
}

