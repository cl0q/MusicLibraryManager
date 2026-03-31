use crate::download::dab::{DabClient, DownloadResult as DabDownloadResult};
use crate::download::queue::{QueueItem, RetryQueue};
use crate::download::soundcloud::{
    SoundCloudDownloadRequest, SoundCloudDownloadResult, SoundCloudDownloader,
};
use crate::download::youtube::{YoutubeClient, YoutubeDownloadResult};
use crate::transcode::{transcode_audio, TranscodeResult};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Request to download a single track
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadRequest {
    /// Track ID for DAB Music API (if available)
    pub track_id: Option<String>,
    /// Search query for both DAB and YouTube
    pub query: String,
    /// Artist name for metadata and file organization
    pub artist: String,
    /// Track title for metadata and file organization
    pub title: String,
    /// SoundCloud permalink URL (if track sourced from SoundCloud)
    pub soundcloud_url: Option<String>,
    /// User ID for SoundCloud auth token retrieval
    pub user_id: Option<String>,
}

/// Result of a batch download operation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchResult {
    /// Number of tracks successfully downloaded and transcoded
    pub succeeded: u32,
    /// Number of tracks that failed (added to retry queue)
    pub failed: u32,
    /// Number of tracks skipped (e.g., already exist)
    pub skipped: u32,
    /// Track IDs that were successfully downloaded (for database status updates)
    pub downloaded_track_ids: Vec<i64>,
    /// Map of track_id → absolute file path for database status updates.
    /// Contains the final file path (transcoded AAC if available, FLAC otherwise).
    #[serde(default)]
    pub downloaded_paths: HashMap<i64, String>,
}

impl BatchResult {
    fn new() -> Self {
        Self {
            succeeded: 0,
            failed: 0,
            skipped: 0,
            downloaded_track_ids: Vec::new(),
            downloaded_paths: HashMap::new(),
        }
    }
}

/// Orchestrates downloads across DAB and YouTube sources
///
/// Coordinates:
/// - DAB Music API (primary source)
/// - YouTube search + download (fallback)
/// - Audio transcoding (FLAC → AAC)
/// - Retry queue for failed downloads
///
/// Sequential processing (not parallel) simplifies rate limiting and debugging.
pub struct DownloadOrchestrator {
    dab_client: DabClient,
    youtube_client: YoutubeClient,
    soundcloud_downloader: Option<SoundCloudDownloader>,
    retry_queue: RetryQueue,
    flac_dir: PathBuf,
    aac_dir: PathBuf,
}

impl DownloadOrchestrator {
    /// Create a new download orchestrator
    ///
    /// # Arguments
    /// * `flac_dir` - Directory for FLAC originals (Lexar SSD)
    /// * `aac_dir` - Directory for AAC transcodes (temp staging)
    pub fn new(flac_dir: PathBuf, aac_dir: PathBuf) -> Result<Self> {
        // Create directories if they don't exist
        std::fs::create_dir_all(&flac_dir)
            .context("Failed to create FLAC directory")?;
        std::fs::create_dir_all(&aac_dir)
            .context("Failed to create AAC directory")?;

        // Initialize retry queue in FLAC directory
        let queue_path = flac_dir.join(".retry_queue.json");
        let mut retry_queue = RetryQueue::new(queue_path);
        retry_queue.load().context("Failed to load retry queue")?;

        // SoundCloud downloader is optional (requires scdl CLI)
        let soundcloud_downloader = match SoundCloudDownloader::new() {
            Ok(dl) => {
                log::info!("scdl available: SoundCloud downloads enabled");
                Some(dl)
            }
            Err(e) => {
                log::info!("scdl not available, SoundCloud direct downloads disabled: {}", e);
                None
            }
        };

        Ok(Self {
            dab_client: DabClient::new()?,
            youtube_client: YoutubeClient::new()?,
            soundcloud_downloader,
            retry_queue,
            flac_dir,
            aac_dir,
        })
    }

    /// Download a batch of tracks sequentially
    ///
    /// For each track:
    /// 1. Try DAB Music API (if track_id provided)
    /// 2. Fall back to YouTube on DAB NotFound
    /// 3. Transcode to AAC if download succeeds
    /// 4. Add to retry queue on any failure
    ///
    /// Sequential processing (per user decision):
    /// - Simpler implementation
    /// - Avoids rate limits
    /// - Easier to debug
    /// - Sufficient throughput for typical batches
    ///
    /// # Arguments
    /// * `requests` - List of tracks to download
    /// * `progress_callback` - Optional callback for progress updates (current, total, track_title)
    ///
    /// # Returns
    /// * `BatchResult` with downloaded_track_ids for database status updates
    pub async fn download_batch(
        &mut self,
        requests: Vec<DownloadRequest>,
        progress_callback: Option<Box<dyn Fn(usize, usize, &str) + Send + Sync>>,
    ) -> Result<BatchResult> {
        let total = requests.len();
        let mut result = BatchResult::new();

        for (i, request) in requests.into_iter().enumerate() {
            let progress = i + 1;

            // Call progress callback before processing track
            if let Some(ref callback) = progress_callback {
                let track_display = format!("{} - {}", request.artist, request.title);
                callback(progress, total, &track_display);
            }

            log::info!(
                "Downloading Track {}/{}: {} - {}...",
                progress,
                total,
                request.artist,
                request.title
            );

            // Generate filename: Artist - Title.flac
            let filename = format!("{} - {}.flac", request.artist, request.title);
            let flac_path = self.flac_dir.join(&filename);

            // Skip if file already exists
            if flac_path.exists() {
                log::info!("File already exists, skipping");
                result.skipped += 1;
                continue;
            }

            // Track successful download path
            let mut downloaded_path: Option<PathBuf> = None;
            let mut source = "unknown";

            // Step 0: Try SoundCloud direct download (if track has SoundCloud URL)
            if let (Some(sc_url), Some(user_id)) =
                (&request.soundcloud_url, &request.user_id)
            {
                if let Some(ref sc_downloader) = self.soundcloud_downloader {
                    log::info!("Attempting SoundCloud direct download: {}", sc_url);
                    let sc_request = SoundCloudDownloadRequest {
                        track_url: sc_url.clone(),
                        user_id: user_id.clone(),
                        output_dir: self.aac_dir.clone(),
                        track_id: request.track_id.clone().unwrap_or_else(|| sc_url.clone()),
                    };

                    match sc_downloader.download_track(&sc_request).await {
                        Ok(SoundCloudDownloadResult::Success(path)) => {
                            log::info!("SoundCloud download succeeded: {}", path.display());
                            downloaded_path = Some(path);
                            source = "soundcloud";
                        }
                        Ok(SoundCloudDownloadResult::NotFound) => {
                            log::info!(
                                "SoundCloud track not available for download, falling back to DAB"
                            );
                        }
                        Err(e) => {
                            log::warn!(
                                "SoundCloud download failed: {}, falling back to DAB",
                                e
                            );
                        }
                    }
                } else {
                    log::info!("scdl not available, skipping SoundCloud direct download");
                }
            }

            // Step 1: Try DAB Music API (if SoundCloud didn't succeed)
            if downloaded_path.is_none() {
                if let Some(track_id) = &request.track_id {
                    log::info!("Attempting DAB download with track_id: {}", track_id);
                    match self.dab_client.download_stream(track_id, &flac_path).await {
                        Ok(DabDownloadResult::Success(path)) => {
                            log::info!("DAB download succeeded");
                            downloaded_path = Some(path);
                            source = "dab";
                        }
                        Ok(DabDownloadResult::NotFound) => {
                            log::info!("DAB returned NotFound (404), falling back to YouTube");
                        }
                        Err(e) => {
                            log::error!("DAB download failed: {}", e);
                            let queue_item = QueueItem::new(
                                request.track_id.clone().unwrap_or_else(|| request.query.clone()),
                                request.query.clone(),
                                "dab".to_string(),
                                e.to_string(),
                            );
                            self.retry_queue.add(queue_item)?;
                            result.failed += 1;
                            continue; // Skip to next track
                        }
                    }
                }
            }

            // Step 2: Try YouTube if DAB didn't succeed
            if downloaded_path.is_none() {
                log::info!("Attempting YouTube download with query: {}", request.query);
                match self.youtube_client.search_and_download(&request.query, &self.flac_dir).await {
                    Ok(YoutubeDownloadResult::Success(path)) => {
                        log::info!("YouTube download succeeded: {}", path.display());
                        downloaded_path = Some(path);
                        source = "youtube";
                    }
                    Ok(YoutubeDownloadResult::NotFound) => {
                        log::warn!("YouTube returned no results for query: {}", request.query);
                        let queue_item = QueueItem::new(
                            request.track_id.clone().unwrap_or_else(|| request.query.clone()),
                            request.query.clone(),
                            "youtube".to_string(),
                            "No results found".to_string(),
                        );
                        self.retry_queue.add(queue_item)?;
                        result.failed += 1;
                        continue; // Skip to next track
                    }
                    Err(e) => {
                        log::error!("YouTube download failed: {}", e);
                        let queue_item = QueueItem::new(
                            request.track_id.clone().unwrap_or_else(|| request.query.clone()),
                            request.query.clone(),
                            "youtube".to_string(),
                            e.to_string(),
                        );
                        self.retry_queue.add(queue_item)?;
                        result.failed += 1;
                        continue; // Skip to next track
                    }
                }
            }

            // Step 3: Transcode to AAC
            if let Some(path) = downloaded_path {
                log::info!("Transcoding to AAC...");
                match transcode_audio(&path, &self.aac_dir).await {
                    Ok(TranscodeResult::Transcoded(aac_path)) => {
                        log::info!("Transcoded to: {}", aac_path.display());
                        result.succeeded += 1;

                        // Track successful download for database update
                        if let Some(track_id) = request.track_id.as_ref().and_then(|id| id.parse::<i64>().ok()) {
                            result.downloaded_track_ids.push(track_id);
                            result.downloaded_paths.insert(track_id, aac_path.to_string_lossy().to_string());
                        }
                    }
                    Ok(TranscodeResult::Skipped(reason)) => {
                        log::info!("Transcode skipped: {}", reason);
                        result.succeeded += 1; // Original kept, consider success

                        // Track successful download for database update
                        if let Some(track_id) = request.track_id.as_ref().and_then(|id| id.parse::<i64>().ok()) {
                            result.downloaded_track_ids.push(track_id);
                            result.downloaded_paths.insert(track_id, path.to_string_lossy().to_string());
                        }
                    }
                    Ok(TranscodeResult::Failed(error)) => {
                        log::error!("Transcode failed: {}", error);
                        // Keep FLAC, add to retry queue for transcode retry
                        let queue_item = QueueItem::new(
                            request.track_id.clone().unwrap_or_else(|| request.query.clone()),
                            request.query.clone(),
                            format!("{}-transcode", source),
                            error,
                        );
                        self.retry_queue.add(queue_item)?;
                        result.failed += 1;
                    }
                    Err(e) => {
                        log::error!("Transcode error: {}", e);
                        let queue_item = QueueItem::new(
                            request.track_id.clone().unwrap_or_else(|| request.query.clone()),
                            request.query.clone(),
                            format!("{}-transcode", source),
                            e.to_string(),
                        );
                        self.retry_queue.add(queue_item)?;
                        result.failed += 1;
                    }
                }
            }

            log::info!("Completed {}/{}", progress, total);
        }

        // Save retry queue after batch
        self.retry_queue.save()?;

        log::info!(
            "Batch complete: {} succeeded, {} failed, {} skipped",
            result.succeeded,
            result.failed,
            result.skipped
        );

        Ok(result)
    }

    /// Retry all failed downloads from the queue
    ///
    /// For each pending item:
    /// 1. Increment attempt count
    /// 2. Retry download based on item.source
    /// 3. Remove from queue on success
    /// 4. Update error and save queue on failure
    pub async fn retry_failed(&mut self) -> Result<BatchResult> {
        let pending = self.retry_queue.get_pending();
        let total = pending.len();
        let mut result = BatchResult::new();

        log::info!("Retrying {} failed downloads", total);

        for (i, mut item) in pending.into_iter().enumerate() {
            let progress = i + 1;
            log::info!(
                "Retry {}/{}: {} (attempt {})",
                progress,
                total,
                item.track_id,
                item.attempt_count + 1
            );

            // Increment attempt count
            item.attempt_count += 1;

            // Generate filename from query (fallback)
            let filename = format!("{}.flac", item.query.replace('/', "-"));
            let flac_path = self.flac_dir.join(&filename);

            let mut success = false;

            // Retry based on source
            if item.source == "dab" {
                match self.dab_client.download_stream(&item.track_id, &flac_path).await {
                    Ok(DabDownloadResult::Success(_)) => {
                        log::info!("DAB retry succeeded");
                        success = true;
                    }
                    Ok(DabDownloadResult::NotFound) => {
                        log::info!("DAB still returns NotFound");
                        item.last_error = "Track not found (404)".to_string();
                    }
                    Err(e) => {
                        log::error!("DAB retry failed: {}", e);
                        item.last_error = e.to_string();
                    }
                }
            } else if item.source == "youtube" {
                match self.youtube_client.search_and_download(&item.query, &self.flac_dir).await {
                    Ok(YoutubeDownloadResult::Success(_)) => {
                        log::info!("YouTube retry succeeded");
                        success = true;
                    }
                    Ok(YoutubeDownloadResult::NotFound) => {
                        log::info!("YouTube still returns no results");
                        item.last_error = "No results found".to_string();
                    }
                    Err(e) => {
                        log::error!("YouTube retry failed: {}", e);
                        item.last_error = e.to_string();
                    }
                }
            } else if item.source.contains("transcode") {
                // Retry transcode
                if flac_path.exists() {
                    match transcode_audio(&flac_path, &self.aac_dir).await {
                        Ok(TranscodeResult::Transcoded(_)) | Ok(TranscodeResult::Skipped(_)) => {
                            log::info!("Transcode retry succeeded");
                            success = true;
                        }
                        Ok(TranscodeResult::Failed(error)) => {
                            log::error!("Transcode retry failed: {}", error);
                            item.last_error = error;
                        }
                        Err(e) => {
                            log::error!("Transcode retry error: {}", e);
                            item.last_error = e.to_string();
                        }
                    }
                } else {
                    log::error!("FLAC file not found for transcode retry");
                    item.last_error = "FLAC file missing".to_string();
                }
            }

            if success {
                self.retry_queue.remove(&item.track_id)?;
                result.succeeded += 1;
            } else {
                // Update item with incremented attempt count and new error
                self.retry_queue.remove(&item.track_id)?;
                self.retry_queue.add(item)?;
                result.failed += 1;
            }
        }

        log::info!(
            "Retry complete: {} succeeded, {} failed",
            result.succeeded,
            result.failed
        );

        Ok(result)
    }

    /// Get the current retry queue for inspection
    pub fn get_retry_queue(&self) -> &RetryQueue {
        &self.retry_queue
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_download_request_creation() {
        let request = DownloadRequest {
            track_id: Some("track123".to_string()),
            query: "Artist - Title".to_string(),
            artist: "Artist".to_string(),
            title: "Title".to_string(),
            soundcloud_url: None,
            user_id: None,
        };

        assert_eq!(request.track_id, Some("track123".to_string()));
        assert_eq!(request.query, "Artist - Title");
        assert!(request.soundcloud_url.is_none());
    }

    #[test]
    fn test_download_request_with_soundcloud() {
        let request = DownloadRequest {
            track_id: None,
            query: "Artist - SoundCloud Track".to_string(),
            artist: "Artist".to_string(),
            title: "SoundCloud Track".to_string(),
            soundcloud_url: Some("https://soundcloud.com/artist/track".to_string()),
            user_id: Some("user123".to_string()),
        };

        assert!(request.soundcloud_url.is_some());
        assert_eq!(
            request.soundcloud_url.unwrap(),
            "https://soundcloud.com/artist/track"
        );
    }

    #[test]
    fn test_batch_result_new() {
        let result = BatchResult::new();
        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 0);
        assert_eq!(result.skipped, 0);
    }

    #[tokio::test]
    async fn test_orchestrator_creation() {
        let temp_dir = TempDir::new().unwrap();
        let flac_dir = temp_dir.path().join("flac");
        let aac_dir = temp_dir.path().join("aac");

        let orchestrator = DownloadOrchestrator::new(flac_dir.clone(), aac_dir.clone());

        // Should succeed if yt-dlp is available
        // If not available, that's also acceptable (documented requirement)
        match orchestrator {
            Ok(orch) => {
                assert!(flac_dir.exists(), "FLAC directory should be created");
                assert!(aac_dir.exists(), "AAC directory should be created");
                assert_eq!(orch.flac_dir, flac_dir);
                assert_eq!(orch.aac_dir, aac_dir);
            }
            Err(e) => {
                // Acceptable if yt-dlp not installed
                println!("Orchestrator creation requires yt-dlp: {}", e);
            }
        }
    }

    #[tokio::test]
    async fn test_orchestrator_skip_existing() {
        let temp_dir = TempDir::new().unwrap();
        let flac_dir = temp_dir.path().join("flac");
        let aac_dir = temp_dir.path().join("aac");

        // Skip test if yt-dlp not available
        if YoutubeClient::new().is_err() {
            println!("Skipping test: yt-dlp not available");
            return;
        }

        let mut orchestrator = DownloadOrchestrator::new(flac_dir.clone(), aac_dir.clone()).unwrap();

        // Create a file to simulate existing download
        std::fs::create_dir_all(&flac_dir).unwrap();
        let existing_file = flac_dir.join("Artist - Title.flac");
        std::fs::write(&existing_file, b"mock content").unwrap();

        let request = DownloadRequest {
            track_id: Some("track123".to_string()),
            query: "Artist - Title".to_string(),
            artist: "Artist".to_string(),
            title: "Title".to_string(),
            soundcloud_url: None,
            user_id: None,
        };

        let result = orchestrator.download_batch(vec![request], None).await.unwrap();

        assert_eq!(result.skipped, 1);
        assert_eq!(result.succeeded, 0);
        assert_eq!(result.failed, 0);
    }

    // Integration tests with actual DAB/YouTube APIs would be marked with #[ignore]
    // and run via `cargo test -- --ignored`
}
