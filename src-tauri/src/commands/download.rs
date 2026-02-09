//! Tauri command handlers for download operations.
//!
//! Provides async command handlers for:
//! - download_tracks: Batch download tracks from DAB/YouTube
//! - retry_failed_downloads: Retry all failed downloads from queue
//! - get_retry_queue_status: Get current retry queue status

use crate::download::orchestrator::{BatchResult, DownloadOrchestrator, DownloadRequest};
use crate::download::queue::{QueueItem, RetryQueue};
use serde::Serialize;
use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager};

/// Progress update payload for channel streaming
#[derive(Serialize, Clone)]
pub struct ProgressUpdate {
    pub current: usize,
    pub total: usize,
    pub track_title: String,
}

/// Download a batch of tracks
///
/// Coordinates downloads from DAB Music API (primary) and YouTube (fallback),
/// transcodes to AAC, and queues failures for retry.
/// Streams progress updates via events and emits completion event.
///
/// # Arguments
/// * `app_handle` - Tauri app handle for event emission
/// * `requests` - List of tracks to download
/// * `flac_dir` - Directory for FLAC originals (Lexar SSD)
/// * `aac_dir` - Directory for AAC transcodes (temp staging)
///
/// # Returns
/// * `BatchResult` with success/failure/skipped counts
#[tauri::command]
pub async fn download_tracks(
    app_handle: AppHandle,
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

    use crate::database::get_connection;

    // Get database connection
    let db_path = app_handle
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?
        .join("music_library.db");

    let db_conn = get_connection(&db_path)
        .map_err(|e| format!("Failed to get database connection: {}", e))?;

    let mut orchestrator = DownloadOrchestrator::new(
        PathBuf::from(flac_dir),
        PathBuf::from(aac_dir),
    )
    .map_err(|e| format!("Failed to create orchestrator: {}", e))?;

    // Create progress callback closure that emits events
    let app_handle_clone = app_handle.clone();
    let progress_callback: Option<Box<dyn Fn(usize, usize, &str) + Send + Sync>> = Some(Box::new(
        move |current: usize, total: usize, track_title: &str| {
            let update = ProgressUpdate {
                current,
                total,
                track_title: track_title.to_string(),
            };
            // Emit progress update event (ignore errors if frontend not listening)
            let _ = app_handle_clone.emit("download-progress", &update);
        },
    ));

    let result = orchestrator
        .download_batch(requests, progress_callback)
        .await
        .map_err(|e| format!("Download batch failed: {}", e))?;

    // Update download_status for successfully downloaded tracks
    // This will be implemented in Task 2 and Task 3
    // For now, we'll leave the placeholder for the database update

    // Emit download-complete event with batch result
    app_handle
        .emit("download-complete", &result)
        .map_err(|e| format!("Failed to emit download-complete event: {}", e))?;

    Ok(result)
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
            soundcloud_url: None,
            user_id: None,
        };

        // Verify serialization (required for Tauri IPC)
        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("track123"));
        assert!(json.contains("Artist - Title"));
    }

    #[test]
    fn test_download_request_with_soundcloud_serialization() {
        let request = DownloadRequest {
            track_id: None,
            query: "Artist - SC Track".to_string(),
            artist: "Artist".to_string(),
            title: "SC Track".to_string(),
            soundcloud_url: Some("https://soundcloud.com/artist/sc-track".to_string()),
            user_id: Some("user123".to_string()),
        };

        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("soundcloud.com"));
        assert!(json.contains("user123"));

        // Verify deserialization round-trip
        let deserialized: DownloadRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.soundcloud_url, request.soundcloud_url);
        assert_eq!(deserialized.user_id, request.user_id);
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
