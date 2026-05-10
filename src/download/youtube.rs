use anyhow::{anyhow, Context, Result};
use std::path::{Path, PathBuf};
use tokio::process::Command;

/// Result of a YouTube download attempt
#[derive(Debug, Clone, PartialEq)]
pub enum YoutubeDownloadResult {
    /// Audio file successfully downloaded
    Success(PathBuf),
    /// No results found for the query
    NotFound,
}

/// Client for downloading audio from YouTube using yt-dlp CLI
#[derive(Debug)]
pub struct YoutubeClient {
    #[allow(dead_code)]
    yt_dlp_path: Option<PathBuf>,
}

impl YoutubeClient {
    /// Create a new YouTube client
    ///
    /// Returns an error if yt-dlp CLI is not available
    pub fn new() -> Result<Self> {
        // Verify yt-dlp is available on the system
        let is_available = std::process::Command::new("yt-dlp")
            .arg("--version")
            .output()
            .is_ok();

        if !is_available {
            return Err(anyhow!(
                "yt-dlp CLI not found. Install via: pip install yt-dlp\n\
                 Or visit: https://github.com/yt-dlp/yt-dlp#installation"
            ));
        }

        Ok(Self {
            yt_dlp_path: None,
        })
    }

    /// Search YouTube and download the first result's audio
    ///
    /// # Arguments
    /// * `query` - Search query (e.g., "Daft Punk - Around the World")
    /// * `output_dir` - Directory to save downloaded audio file
    ///
    /// # Returns
    /// * `Success(PathBuf)` - Path to downloaded audio file
    /// * `NotFound` - No results found for query
    pub async fn search_and_download(
        &self,
        query: &str,
        output_dir: &Path,
    ) -> Result<YoutubeDownloadResult> {
        // Create output directory if it doesn't exist
        tokio::fs::create_dir_all(output_dir)
            .await
            .context("Failed to create output directory")?;

        // Build yt-dlp command
        let output_template = format!(
            "{}/%(title)s-%(id)s.%(ext)s",
            output_dir.display()
        );

        let search_query = format!("ytsearch1:{}", query);

        let mut cmd = Command::new("yt-dlp");
        cmd.arg(&search_query)
            .arg("-f").arg("bestaudio") // Best available audio quality
            .arg("-x") // Extract audio from video container
            .arg("-o").arg(&output_template)
            .arg("--no-playlist") // Don't download playlists
            .arg("--print").arg("after_move:filepath"); // Print final file path

        // Execute command
        let output = cmd
            .output()
            .await
            .context("Failed to execute yt-dlp command")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);

            // Check if it's a "no results found" error
            if stderr.contains("No video results") || stderr.contains("Unable to extract") {
                return Ok(YoutubeDownloadResult::NotFound);
            }

            return Err(anyhow!(
                "yt-dlp failed: exit code {:?}\nstderr: {}",
                output.status.code(),
                stderr
            ));
        }

        // Parse output to get downloaded file path
        let stdout = String::from_utf8_lossy(&output.stdout);
        let file_path = stdout
            .lines()
            .last()
            .ok_or_else(|| anyhow!("yt-dlp produced no output"))?
            .trim();

        let path = PathBuf::from(file_path);
        if !path.exists() {
            return Err(anyhow!(
                "yt-dlp reported success but file not found: {}",
                file_path
            ));
        }

        Ok(YoutubeDownloadResult::Success(path))
    }

    /// Download audio from a specific YouTube URL
    ///
    /// # Arguments
    /// * `url` - YouTube video URL
    /// * `output_dir` - Directory to save downloaded audio file
    ///
    /// # Returns
    /// * `Success(PathBuf)` - Path to downloaded audio file
    /// * `NotFound` - Video not found or unavailable
    pub async fn download_by_url(
        &self,
        url: &str,
        output_dir: &Path,
    ) -> Result<YoutubeDownloadResult> {
        // Create output directory if it doesn't exist
        tokio::fs::create_dir_all(output_dir)
            .await
            .context("Failed to create output directory")?;

        // Build yt-dlp command
        let output_template = format!(
            "{}/%(title)s-%(id)s.%(ext)s",
            output_dir.display()
        );

        let mut cmd = Command::new("yt-dlp");
        cmd.arg(url)
            .arg("-f").arg("bestaudio") // Best available audio quality
            .arg("-x") // Extract audio from video container
            .arg("-o").arg(&output_template)
            .arg("--print").arg("after_move:filepath"); // Print final file path

        // Execute command
        let output = cmd
            .output()
            .await
            .context("Failed to execute yt-dlp command")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);

            // Check if it's a "video unavailable" error
            if stderr.contains("Video unavailable") || stderr.contains("Unable to extract") {
                return Ok(YoutubeDownloadResult::NotFound);
            }

            return Err(anyhow!(
                "yt-dlp failed: exit code {:?}\nstderr: {}",
                output.status.code(),
                stderr
            ));
        }

        // Parse output to get downloaded file path
        let stdout = String::from_utf8_lossy(&output.stdout);
        let file_path = stdout
            .lines()
            .last()
            .ok_or_else(|| anyhow!("yt-dlp produced no output"))?
            .trim();

        let path = PathBuf::from(file_path);
        if !path.exists() {
            return Err(anyhow!(
                "yt-dlp reported success but file not found: {}",
                file_path
            ));
        }

        Ok(YoutubeDownloadResult::Success(path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Test that yt-dlp CLI is available on the system
    ///
    /// Run with: cargo test -- --ignored
    #[tokio::test]
    #[ignore]
    async fn test_verify_yt_dlp_available() {
        let result = std::process::Command::new("yt-dlp")
            .arg("--version")
            .output();

        assert!(
            result.is_ok() && result.unwrap().status.success(),
            "yt-dlp CLI not available. Install via: pip install yt-dlp"
        );
    }

    /// Test searching and downloading a known track
    ///
    /// Run with: cargo test -- --ignored
    /// Requires: yt-dlp CLI installed
    #[tokio::test]
    #[ignore]
    async fn test_search_known_track() {
        let client = YoutubeClient::new().expect("Failed to create YouTube client");
        let temp_dir = TempDir::new().expect("Failed to create temp directory");

        let result = client
            .search_and_download("Daft Punk - Around the World", temp_dir.path())
            .await
            .expect("Failed to download track");

        match result {
            YoutubeDownloadResult::Success(path) => {
                assert!(path.exists(), "Downloaded file should exist");

                // Check file extension is a known audio format
                let ext = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .expect("File should have extension");

                assert!(
                    ["m4a", "opus", "webm", "mp3"].contains(&ext),
                    "Expected audio format, got: {}",
                    ext
                );

                // Verify file has content
                let metadata = std::fs::metadata(&path).expect("Failed to get file metadata");
                assert!(metadata.len() > 0, "Downloaded file should not be empty");
            }
            YoutubeDownloadResult::NotFound => {
                panic!("Expected to find Daft Punk track");
            }
        }
    }

    /// Test downloading by direct URL
    ///
    /// Run with: cargo test -- --ignored
    /// Requires: yt-dlp CLI installed
    #[tokio::test]
    #[ignore]
    async fn test_download_by_url() {
        let client = YoutubeClient::new().expect("Failed to create YouTube client");
        let temp_dir = TempDir::new().expect("Failed to create temp directory");

        // Use YouTube's official test video
        let url = "https://www.youtube.com/watch?v=jNQXAC9IVRw";

        let result = client
            .download_by_url(url, temp_dir.path())
            .await
            .expect("Failed to download video");

        match result {
            YoutubeDownloadResult::Success(path) => {
                assert!(path.exists(), "Downloaded file should exist");

                // Verify file has content
                let metadata = std::fs::metadata(&path).expect("Failed to get file metadata");
                assert!(metadata.len() > 0, "Downloaded file should not be empty");
            }
            YoutubeDownloadResult::NotFound => {
                panic!("Expected to download test video");
            }
        }
    }

    /// Test that YoutubeClient::new() fails when yt-dlp is not available
    #[test]
    fn test_client_creation_without_yt_dlp() {
        // This test will pass if yt-dlp IS installed (expected in dev environment)
        // It documents the error handling behavior
        let result = YoutubeClient::new();

        // If yt-dlp is available, client should be created successfully
        if result.is_ok() {
            println!("yt-dlp is available on this system");
        } else {
            // If not available, error should mention installation instructions
            let err = result.unwrap_err();
            assert!(
                err.to_string().contains("Install via"),
                "Error should include installation instructions"
            );
        }
    }
}
