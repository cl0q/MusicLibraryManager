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

    log::info!(
        "Transcoding {} to AAC ({}kbps, encoder: {})",
        input.display(),
        config.target_bitrate / 1000,
        encoder
    );

    // First attempt: try to preserve cover art with -c:v copy
    let (status, stderr_output) = run_ffmpeg(
        input,
        &temp_output,
        encoder,
        &bitrate_str,
        &["-c:v", "copy", "-disposition:v", "attached_pic"],
    )
    .await?;

    if !status.success() {
        // Clean up temp file from failed attempt
        let _ = fs::remove_file(&temp_output).await;

        // Check if the failure is cover-art/video-stream related
        let is_cover_art_issue = stderr_output.contains("Video")
            || stderr_output.contains("attached_pic")
            || stderr_output.contains("video stream")
            || stderr_output.contains("Could not find tag for codec")
            || status.code() == Some(234);

        if is_cover_art_issue {
            log::warn!(
                "FFmpeg failed with cover art flags, retrying without video stream: {}",
                input.display()
            );

            // Retry without cover art: use -vn to strip video/image streams
            let (retry_status, retry_stderr) = run_ffmpeg(
                input,
                &temp_output,
                encoder,
                &bitrate_str,
                &["-vn"],
            )
            .await?;

            if !retry_status.success() {
                let _ = fs::remove_file(&temp_output).await;
                anyhow::bail!(
                    "FFmpeg transcode failed on retry (no cover art) with exit code: {:?}\nstderr: {}",
                    retry_status.code(),
                    retry_stderr
                );
            }
        } else {
            anyhow::bail!(
                "FFmpeg transcode failed with exit code: {:?}\nstderr: {}",
                status.code(),
                stderr_output
            );
        }
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

/// Run FFmpeg with the given audio args and extra flags (e.g. video handling).
/// Returns the exit status and collected stderr output.
async fn run_ffmpeg(
    input: &Path,
    output: &Path,
    encoder: &str,
    bitrate: &str,
    extra_args: &[&str],
) -> Result<(std::process::ExitStatus, String)> {
    let mut cmd = Command::new("ffmpeg");
    cmd.arg("-i")
        .arg(input)
        .arg("-c:a")
        .arg(encoder)
        .arg("-b:a")
        .arg(bitrate);

    for arg in extra_args {
        cmd.arg(arg);
    }

    cmd.arg("-y")
        .arg(output)
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .context("Failed to spawn ffmpeg process")?;

    // Collect stderr for both logging and error diagnosis
    let mut stderr_output = String::new();
    if let Some(stderr) = child.stderr.take() {
        let reader = BufReader::new(stderr);
        let mut lines = reader.lines();

        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("time=") {
                log::debug!("FFmpeg progress: {}", line);
            }
            stderr_output.push_str(&line);
            stderr_output.push('\n');
        }
    }

    let status = child
        .wait()
        .await
        .context("Failed to wait for ffmpeg process")?;

    Ok((status, stderr_output))
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
