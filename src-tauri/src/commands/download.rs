//! Tauri command handlers for download operations.
//!
//! Provides async command handlers for:
//! - download_tracks: Batch download tracks from DAB/YouTube
//! - retry_failed_downloads: Retry all failed downloads from queue
//! - get_retry_queue_status: Get current retry queue status

use crate::download::orchestrator::{BatchResult, DownloadOrchestrator, DownloadRequest};
use crate::download::queue::{QueueItem, RetryQueue};
use std::path::PathBuf;

/// Download a batch of tracks
///
/// Coordinates downloads from DAB Music API (primary) and YouTube (fallback),
/// transcodes to AAC, and queues failures for retry.
///
/// # Arguments
/// * `requests` - List of tracks to download
/// * `flac_dir` - Directory for FLAC originals (Lexar SSD)
/// * `aac_dir` - Directory for AAC transcodes (temp staging)
///
/// # Returns
/// * `BatchResult` with success/failure/skipped counts
#[tauri::command]
pub async fn download_tracks(
    requests: Vec<DownloadRequest>,
    flac_dir: String,
    aac_dir: String,
) -> Result<BatchResult, String> {
    log::info!(
        "download_tracks invoked: {} tracks, flac_dir={}, aac_dir={}",
        requests.len(),
        flac_dir,
        aac_dir
    );

    let mut orchestrator = DownloadOrchestrator::new(
        PathBuf::from(flac_dir),
        PathBuf::from(aac_dir),
    )
    .map_err(|e| format!("Failed to create orchestrator: {}", e))?;

    orchestrator
        .download_batch(requests)
        .await
        .map_err(|e| format!("Download batch failed: {}", e))
}

/// Retry all failed downloads from the retry queue
///
/// Loads pending items from the retry queue and retries each one.
/// Increments attempt count and updates queue on failure.
/// Removes from queue on success.
///
/// # Arguments
/// * `flac_dir` - Directory for FLAC originals
/// * `aac_dir` - Directory for AAC transcodes
///
/// # Returns
/// * `BatchResult` with success/failure counts
#[tauri::command]
pub async fn retry_failed_downloads(
    flac_dir: String,
    aac_dir: String,
) -> Result<BatchResult, String> {
    log::info!(
        "retry_failed_downloads invoked: flac_dir={}, aac_dir={}",
        flac_dir,
        aac_dir
    );

    let mut orchestrator = DownloadOrchestrator::new(
        PathBuf::from(flac_dir),
        PathBuf::from(aac_dir),
    )
    .map_err(|e| format!("Failed to create orchestrator: {}", e))?;

    orchestrator
        .retry_failed()
        .await
        .map_err(|e| format!("Retry failed: {}", e))
}

/// Get the current status of the retry queue
///
/// Returns all pending items (those under max retry attempts) from the queue.
///
/// # Arguments
/// * `queue_path` - Path to the retry queue JSON file
///
/// # Returns
/// * Vector of QueueItem with track info and error details
#[tauri::command]
pub async fn get_retry_queue_status(queue_path: String) -> Result<Vec<QueueItem>, String> {
    log::info!("get_retry_queue_status invoked: queue_path={}", queue_path);

    let mut queue = RetryQueue::new(PathBuf::from(queue_path));
    queue
        .load()
        .map_err(|e| format!("Failed to load queue: {}", e))?;

    Ok(queue.get_pending())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_download_request_serialization() {
        let request = DownloadRequest {
            track_id: Some("track123".to_string()),
            query: "Artist - Title".to_string(),
            artist: "Artist".to_string(),
            title: "Title".to_string(),
        };

        // Verify serialization (required for Tauri IPC)
        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("track123"));
        assert!(json.contains("Artist - Title"));
    }

    #[test]
    fn test_batch_result_serialization() {
        let result = BatchResult {
            succeeded: 5,
            failed: 2,
            skipped: 1,
        };

        // Verify serialization (required for Tauri IPC)
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"succeeded\":5"));
        assert!(json.contains("\"failed\":2"));
    }

    #[test]
    fn test_queue_item_serialization() {
        use crate::download::queue::QueueItem;

        let item = QueueItem::new(
            "track123".to_string(),
            "Query".to_string(),
            "dab".to_string(),
            "Error".to_string(),
        );

        // Verify serialization (required for Tauri IPC)
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("track123"));
        assert!(json.contains("dab"));
    }

    // Integration tests for actual command invocation would require Tauri app context
    // and would be tested via frontend integration tests
}
