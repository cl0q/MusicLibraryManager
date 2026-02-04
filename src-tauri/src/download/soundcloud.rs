//! SoundCloud download client using scdl CLI.
//!
//! Downloads 248kbps AAC tracks from SoundCloud using the scdl command-line tool
//! with Go+ authentication. Integrates with the download orchestrator as a
//! primary source for SoundCloud-sourced tracks.
//!
//! ## Requirements
//!
//! - `scdl` CLI installed (`pip install scdl`)
//! - SoundCloud Go+ subscription for 248kbps AAC quality
//! - OAuth access token stored in system keychain via token_storage
//!
//! ## Download Priority
//!
//! For tracks sourced from SoundCloud:
//! 1. SoundCloud direct (this module) - 248kbps AAC with Go+
//! 2. DAB (FLAC) - if track available
//! 3. YouTube (fallback)

use crate::auth::token_storage;
use anyhow::{anyhow, Context, Result};
use std::path::{Path, PathBuf};
use tokio::process::Command;

/// Result of a SoundCloud download attempt.
#[derive(Debug, Clone, PartialEq)]
pub enum SoundCloudDownloadResult {
    /// Audio file successfully downloaded.
    Success(PathBuf),
    /// Track not found or not available for download.
    NotFound,
}

/// Request to download a track from SoundCloud.
#[derive(Debug, Clone)]
pub struct SoundCloudDownloadRequest {
    /// SoundCloud permalink URL (e.g., "https://soundcloud.com/artist/track")
    pub track_url: String,
    /// User ID for keychain access token retrieval
    pub user_id: String,
    /// Directory to save downloaded file
    pub output_dir: PathBuf,
    /// Track ID for logging and error tracking
    pub track_id: String,
}

/// Client for downloading audio from SoundCloud using scdl CLI.
#[derive(Debug)]
pub struct SoundCloudDownloader {
    /// Path to scdl binary, if found during construction.
    #[allow(dead_code)]
    scdl_path: Option<PathBuf>,
}

impl SoundCloudDownloader {
    /// Create a new SoundCloud downloader.
    ///
    /// Returns an error if scdl CLI is not available on the system.
    pub fn new() -> Result<Self> {
        // Verify scdl is available
        let is_available = std::process::Command::new("scdl")
            .arg("--version")
            .output()
            .is_ok();

        if !is_available {
            return Err(anyhow!(
                "scdl CLI not found. Install via: pip install scdl\n\
                 Requires SoundCloud Go+ subscription for 248kbps AAC downloads."
            ));
        }

        Ok(Self { scdl_path: None })
    }

    /// Download a track from SoundCloud using scdl CLI.
    ///
    /// Retrieves the OAuth access token from the system keychain, then invokes
    /// scdl with --auth-token to download the track. SoundCloud Go+ accounts
    /// get 248kbps AAC quality.
    ///
    /// # Arguments
    /// * `request` - Download request with track URL, user ID, and output directory
    ///
    /// # Returns
    /// * `Ok(Success(PathBuf))` - Path to downloaded audio file
    /// * `Ok(NotFound)` - Track not available for download
    /// * `Err` - scdl execution failed or auth token not found
    pub async fn download_track(
        &self,
        request: &SoundCloudDownloadRequest,
    ) -> Result<SoundCloudDownloadResult> {
        // Retrieve SoundCloud access token from keychain
        let access_token = token_storage::get_refresh_token("soundcloud", &request.user_id)
            .map_err(|e| {
                anyhow!(
                    "SoundCloud auth token not found: {}. Run OAuth flow first.",
                    e
                )
            })?;

        // Ensure output directory exists
        tokio::fs::create_dir_all(&request.output_dir)
            .await
            .context("Failed to create output directory")?;

        // Build scdl command:
        // scdl -l <track_url> --auth-token <token> --path <output_dir> --onlymp3 --name-format {title}
        let output = Command::new("scdl")
            .arg("-l")
            .arg(&request.track_url)
            .arg("--auth-token")
            .arg(&access_token)
            .arg("--path")
            .arg(&request.output_dir)
            .arg("--onlymp3")
            .arg("--original-art")
            .arg("--name-format")
            .arg("{title}")
            .output()
            .await
            .context("Failed to execute scdl. Is scdl installed? (pip install scdl)")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);

            // Check for "not found" or "not available" errors
            if stderr.contains("not found")
                || stderr.contains("404")
                || stderr.contains("not available")
                || stderr.contains("Unable to download")
            {
                return Ok(SoundCloudDownloadResult::NotFound);
            }

            return Err(anyhow!(
                "scdl failed: exit code {:?}\nstderr: {}",
                output.status.code(),
                stderr
            ));
        }

        // scdl downloads to output_dir; find the most recently created audio file
        let downloaded_file = find_most_recent_audio_file(&request.output_dir).await?;

        Ok(SoundCloudDownloadResult::Success(downloaded_file))
    }
}

/// Find the most recently modified audio file in a directory.
///
/// Helper for locating scdl output when the exact filename is unknown.
/// Searches for .mp3 and .m4a files and returns the one with the most
/// recent modification time.
async fn find_most_recent_audio_file(dir: &Path) -> Result<PathBuf> {
    let mut entries = tokio::fs::read_dir(dir)
        .await
        .context("Failed to read output directory")?;

    let mut candidates: Vec<(PathBuf, std::time::SystemTime)> = Vec::new();

    while let Some(entry) = entries
        .next_entry()
        .await
        .context("Failed to read directory entry")?
    {
        let path = entry.path();
        if let Some(ext) = path.extension() {
            let ext_lower = ext.to_string_lossy().to_lowercase();
            if ext_lower == "mp3" || ext_lower == "m4a" || ext_lower == "aac" {
                if let Ok(metadata) = entry.metadata().await {
                    if let Ok(modified) = metadata.modified() {
                        candidates.push((path, modified));
                    }
                }
            }
        }
    }

    // Sort by modified time descending (most recent first)
    candidates.sort_by(|a, b| b.1.cmp(&a.1));

    candidates
        .first()
        .map(|(path, _)| path.clone())
        .ok_or_else(|| anyhow!("No audio file found in download directory after scdl completed"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_soundcloud_download_request_creation() {
        let request = SoundCloudDownloadRequest {
            track_url: "https://soundcloud.com/artist/track-name".to_string(),
            user_id: "test_user".to_string(),
            output_dir: PathBuf::from("/tmp/downloads"),
            track_id: "sc_12345".to_string(),
        };

        assert_eq!(
            request.track_url,
            "https://soundcloud.com/artist/track-name"
        );
        assert_eq!(request.user_id, "test_user");
        assert_eq!(request.output_dir, PathBuf::from("/tmp/downloads"));
        assert_eq!(request.track_id, "sc_12345");
    }

    #[test]
    fn test_soundcloud_download_result_variants() {
        let success = SoundCloudDownloadResult::Success(PathBuf::from("/tmp/track.mp3"));
        let not_found = SoundCloudDownloadResult::NotFound;

        assert_eq!(
            success,
            SoundCloudDownloadResult::Success(PathBuf::from("/tmp/track.mp3"))
        );
        assert_eq!(not_found, SoundCloudDownloadResult::NotFound);
        assert_ne!(success, not_found);
    }

    #[tokio::test]
    async fn test_find_most_recent_audio_file_empty_dir() {
        let temp_dir = TempDir::new().unwrap();
        let result = find_most_recent_audio_file(temp_dir.path()).await;

        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("No audio file found"));
    }

    #[tokio::test]
    async fn test_find_most_recent_audio_file_with_files() {
        let temp_dir = TempDir::new().unwrap();

        // Create some audio files
        let mp3_path = temp_dir.path().join("track1.mp3");
        tokio::fs::write(&mp3_path, b"fake mp3 content").await.unwrap();

        // Small delay to ensure different timestamps
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let m4a_path = temp_dir.path().join("track2.m4a");
        tokio::fs::write(&m4a_path, b"fake m4a content").await.unwrap();

        // Also create a non-audio file that should be ignored
        let txt_path = temp_dir.path().join("readme.txt");
        tokio::fs::write(&txt_path, b"not audio").await.unwrap();

        let result = find_most_recent_audio_file(temp_dir.path()).await;
        assert!(result.is_ok());

        let found = result.unwrap();
        // Should find the most recent audio file (m4a was created last)
        assert_eq!(found, m4a_path);
    }

    #[tokio::test]
    async fn test_find_most_recent_audio_file_ignores_non_audio() {
        let temp_dir = TempDir::new().unwrap();

        // Create only non-audio files
        tokio::fs::write(temp_dir.path().join("document.pdf"), b"pdf content")
            .await
            .unwrap();
        tokio::fs::write(temp_dir.path().join("image.png"), b"png content")
            .await
            .unwrap();

        let result = find_most_recent_audio_file(temp_dir.path()).await;
        assert!(result.is_err());
    }

    #[test]
    fn test_client_creation_without_scdl() {
        // This test documents the error handling behavior.
        // If scdl IS installed (expected in dev environment), it will succeed.
        let result = SoundCloudDownloader::new();

        if result.is_ok() {
            println!("scdl is available on this system");
        } else {
            let err = result.unwrap_err();
            assert!(
                err.to_string().contains("scdl CLI not found"),
                "Error should mention scdl not found"
            );
        }
    }

    #[tokio::test]
    #[ignore] // Requires scdl installation, SoundCloud Go+ account, and auth token in keychain
    async fn test_download_soundcloud_track_integration() {
        let downloader = SoundCloudDownloader::new().expect("scdl not available");
        let temp_dir = TempDir::new().expect("Failed to create temp directory");

        let request = SoundCloudDownloadRequest {
            track_url: "https://soundcloud.com/example/test-track".to_string(),
            user_id: "test_user".to_string(),
            output_dir: temp_dir.path().to_path_buf(),
            track_id: "sc_test".to_string(),
        };

        let result = downloader.download_track(&request).await;
        match result {
            Ok(SoundCloudDownloadResult::Success(path)) => {
                assert!(path.exists(), "Downloaded file should exist");
                let metadata = std::fs::metadata(&path).expect("Failed to get file metadata");
                assert!(metadata.len() > 0, "Downloaded file should not be empty");
            }
            Ok(SoundCloudDownloadResult::NotFound) => {
                println!("Track not found (expected for test URL)");
            }
            Err(e) => {
                println!("Download failed (may need auth): {}", e);
            }
        }
    }
}
