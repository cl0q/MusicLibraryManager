use anyhow::{Context, Result};
use std::path::Path;
use std::process::Stdio;
use tokio::fs;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

/// Configuration for FFmpeg AAC encoding
#[derive(Debug, Clone)]
pub struct FfmpegConfig {
    /// Target bitrate in bits per second (default: 248000 = 248kbps)
    pub target_bitrate: u32,
    /// Preferred encoder (default: "libfdk_aac")
    pub encoder: String,
    /// Fallback encoder if preferred unavailable (default: "aac")
    pub fallback_encoder: String,
}

impl Default for FfmpegConfig {
    fn default() -> Self {
        Self {
            target_bitrate: 248_000,
            encoder: "libfdk_aac".to_string(),
            fallback_encoder: "aac".to_string(),
        }
    }
}

/// Check if libfdk_aac encoder is available in ffmpeg build
pub async fn check_libfdk_aac_available() -> Result<bool> {
    let output = Command::new("ffmpeg")
        .arg("-encoders")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await
        .context("Failed to run ffmpeg -encoders")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let available = stdout.contains("libfdk_aac");

    if !available {
        log::warn!("libfdk_aac encoder not found, falling back to native AAC (lower quality)");
    }

    Ok(available)
}

/// Transcode audio file to AAC using FFmpeg
///
/// Transcodes input file to AAC format with specified bitrate.
/// Uses libfdk_aac encoder if available, falls back to native aac encoder.
/// Writes to temporary file first, then renames on success (atomic write).
/// Original file is never modified.
pub async fn transcode_to_aac(
    input: &Path,
    output: &Path,
    config: &FfmpegConfig,
) -> Result<()> {
    // Check encoder availability
    let use_libfdk = check_libfdk_aac_available().await.unwrap_or(false);
    let encoder = if use_libfdk {
        &config.encoder
    } else {
        &config.fallback_encoder
    };

    // Create temp output path (atomic write pattern)
    let temp_output = output.with_extension("tmp.m4a");

    // Ensure parent directory exists
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)
            .await
            .with_context(|| format!("Failed to create output directory: {}", parent.display()))?;
    }

    // Build ffmpeg command
    // Example: ffmpeg -i input.flac -c:a libfdk_aac -b:a 248k output.m4a
    let bitrate_str = format!("{}k", config.target_bitrate / 1000);
    let mut cmd = Command::new("ffmpeg");
    cmd.arg("-i")
        .arg(input)
        .arg("-c:a")
        .arg(encoder)
        .arg("-b:a")
        .arg(&bitrate_str)
        .arg("-y") // Overwrite temp file if exists
        .arg(&temp_output)
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    log::info!(
        "Transcoding {} to AAC ({}kbps, encoder: {})",
        input.display(),
        config.target_bitrate / 1000,
        encoder
    );

    // Spawn process and capture stderr for progress
    let mut child = cmd
        .spawn()
        .context("Failed to spawn ffmpeg process")?;

    // Stream stderr for progress logging
    if let Some(stderr) = child.stderr.take() {
        let reader = BufReader::new(stderr);
        let mut lines = reader.lines();

        tokio::spawn(async move {
            while let Ok(Some(line)) = lines.next_line().await {
                if line.contains("time=") {
                    log::debug!("FFmpeg progress: {}", line);
                }
            }
        });
    }

    // Wait for completion
    let status = child
        .wait()
        .await
        .context("Failed to wait for ffmpeg process")?;

    if !status.success() {
        // Clean up temp file on failure
        let _ = fs::remove_file(&temp_output).await;
        anyhow::bail!(
            "FFmpeg transcode failed with exit code: {:?}",
            status.code()
        );
    }

    // Atomic rename: temp -> final output
    fs::rename(&temp_output, output)
        .await
        .with_context(|| {
            format!(
                "Failed to rename temp file {} to {}",
                temp_output.display(),
                output.display()
            )
        })?;

    log::info!("Transcode complete: {}", output.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffmpeg_config_default() {
        let config = FfmpegConfig::default();
        assert_eq!(config.target_bitrate, 248_000);
        assert_eq!(config.encoder, "libfdk_aac");
        assert_eq!(config.fallback_encoder, "aac");
    }

    #[tokio::test]
    async fn test_check_libfdk_aac_available() {
        // This test requires ffmpeg to be installed
        // It will check if libfdk_aac is available, but won't fail if ffmpeg not installed
        match check_libfdk_aac_available().await {
            Ok(available) => {
                // Just log the result - don't assert since ffmpeg may not have libfdk_aac
                println!("libfdk_aac available: {}", available);
            }
            Err(_) => {
                // ffmpeg not installed - skip test
                println!("ffmpeg not available, skipping test");
            }
        }
    }

    #[test]
    fn test_bitrate_calculation() {
        let config = FfmpegConfig::default();
        let bitrate_k = config.target_bitrate / 1000;
        assert_eq!(bitrate_k, 248);
    }
}
