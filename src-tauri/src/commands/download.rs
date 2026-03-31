//! Tauri command handlers for download operations.
//!
//! Provides async command handlers for:
//! - download_tracks: Batch download tracks from DAB/YouTube
//! - retry_failed_downloads: Retry all failed downloads from queue
//! - get_retry_queue_status: Get current retry queue status

use crate::download::orchestrator::{BatchResult, DownloadOrchestrator, DownloadRequest, TrackProgress};
use crate::download::queue::RetryQueue;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// Download progress event matching frontend DownloadProgressEvent type
#[derive(Serialize, Clone)]
pub struct DownloadProgressEvent {
    pub track_id: String,
    pub track_name: String,
    pub status: String,
    pub progress: u8,
    pub error: Option<String>,
    pub source: Option<String>,
    pub current_step: Option<String>,
    pub speed: Option<String>,
    pub eta: Option<String>,
    pub file_size: Option<u64>,
}

/// Retry queue status for frontend
#[derive(Serialize, Clone)]
pub struct RetryQueueStatus {
    pub pending_count: usize,
    pub failed_count: usize,
}

/// Managed state for download operations
pub struct DownloadState {
    pub queue_path: Mutex<Option<PathBuf>>,
}

/// Download a batch of tracks
///
/// Coordinates downloads from DAB Music API (primary) and YouTube (fallback),
/// transcodes to AAC, organizes files into library structure, and queues failures for retry.
/// Streams progress updates via events and emits completion event.
///
/// # Arguments
/// * `app_handle` - Tauri app handle for event emission
/// * `requests` - List of tracks to download
/// * `download_dir` - Directory for downloaded originals (`.mlm_staging/downloads`)
/// * `transcode_dir` - Directory for AAC transcodes (`.mlm_staging/transcoded`)
/// * `root_dir` - Library root path for organizing files after download
///
/// # Returns
/// * `BatchResult` with success/failure/skipped counts
#[tauri::command]
pub async fn download_tracks(
    app_handle: AppHandle,
    requests: Vec<DownloadRequest>,
    download_dir: String,
    transcode_dir: String,
    root_dir: String,
) -> Result<BatchResult, String> {
    log::info!(
        "download_tracks invoked: {} tracks, download_dir={}, transcode_dir={}, root_dir={}",
        requests.len(),
        download_dir,
        transcode_dir,
        root_dir
    );

    use crate::database::get_connection;

    // Get database connection (same pattern as other commands)
    let db_path = PathBuf::from("music_library.db");
    let db_conn = get_connection(&db_path)
        .map_err(|e| format!("Failed to get database connection: {}", e))?;

    let download_path = PathBuf::from(&download_dir);
    let root_path = PathBuf::from(&root_dir);
    let mut orchestrator = DownloadOrchestrator::new(
        download_path.clone(),
        PathBuf::from(transcode_dir),
        Some(root_path),
    )
    .map_err(|e| format!("Failed to create orchestrator: {}", e))?;

    // Store queue path in managed state for get_retry_queue_status
    if let Some(state) = app_handle.try_state::<DownloadState>() {
        let queue_path = download_path.join(".retry_queue.json");
        *state.queue_path.lock().unwrap() = Some(queue_path);
    }

    // Create progress callback closure that emits events
    let app_handle_clone = app_handle.clone();
    let progress_callback: Option<Box<dyn Fn(TrackProgress) + Send + Sync>> = Some(Box::new(
        move |tp: TrackProgress| {
            let event = DownloadProgressEvent {
                track_id: tp.track_id,
                track_name: tp.track_name,
                status: tp.status.clone(),
                progress: tp.progress,
                error: tp.error,
                source: tp.source,
                current_step: Some(tp.status),
                speed: None,
                eta: None,
                file_size: None,
            };
            let _ = app_handle_clone.emit("download:progress", &event);
        },
    ));

    let result = orchestrator
        .download_batch(requests, progress_callback)
        .await
        .map_err(|e| format!("Download batch failed: {}", e))?;

    // Update download_status and organized_path for successfully downloaded tracks
    // Convert absolute paths to relative (strip library root) for consistent DB storage
    use crate::database::tracks;
    let root_path = PathBuf::from(&root_dir);
    for (track_id, file_path) in &result.downloaded_paths {
        let absolute = PathBuf::from(file_path);
        // Canonicalize both paths to resolve symlinks before strip_prefix.
        // If canonicalize fails (e.g. file doesn't exist yet), fall back to non-canonical strip.
        let relative_path = {
            let canonical_root = root_path.canonicalize().unwrap_or_else(|_| root_path.clone());
            let canonical_abs = absolute.canonicalize().unwrap_or_else(|_| absolute.clone());
            canonical_abs
                .strip_prefix(&canonical_root)
                .map(|p| p.to_string_lossy().to_string())
                .map_err(|_| format!(
                    "Downloaded file {} is outside library root {} — cannot store relative path. \
                     Ensure download_dir and root_dir are consistent.",
                    absolute.display(),
                    root_path.display()
                ))?
        };
        tracks::update_download_status(&db_conn, *track_id, &relative_path, file_path)
            .map_err(|e| format!("Failed to update download_status for track {}: {}", track_id, e))?;
        log::info!("Updated download_status and organized_path for track {} -> {}", track_id, relative_path);
    }

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
/// * `download_dir` - Directory for downloaded originals
/// * `transcode_dir` - Directory for AAC transcodes
///
/// # Returns
/// * `BatchResult` with success/failure counts
#[tauri::command]
pub async fn retry_failed_downloads(
    download_dir: String,
    transcode_dir: String,
) -> Result<BatchResult, String> {
    log::info!(
        "retry_failed_downloads invoked: download_dir={}, transcode_dir={}",
        download_dir,
        transcode_dir
    );

    let mut orchestrator = DownloadOrchestrator::new(
        PathBuf::from(download_dir),
        PathBuf::from(transcode_dir),
        None,
    )
    .map_err(|e| format!("Failed to create orchestrator: {}", e))?;

    orchestrator
        .retry_failed()
        .await
        .map_err(|e| format!("Retry failed: {}", e))
}

/// Get the current status of the retry queue
///
/// Returns pending and failed counts from the retry queue.
/// Uses DownloadState managed state to find queue path.
#[tauri::command]
pub async fn get_retry_queue_status(
    app_handle: AppHandle,
) -> Result<RetryQueueStatus, String> {
    log::info!("get_retry_queue_status invoked");

    let queue_path = app_handle
        .try_state::<DownloadState>()
        .and_then(|state| state.queue_path.lock().ok()?.clone());

    let Some(queue_path) = queue_path else {
        // No downloads have happened yet, return zeros
        return Ok(RetryQueueStatus {
            pending_count: 0,
            failed_count: 0,
        });
    };

    let mut queue = RetryQueue::new(queue_path);
    queue
        .load()
        .map_err(|e| format!("Failed to load queue: {}", e))?;

    let pending = queue.get_pending();
    let total = queue.len();

    Ok(RetryQueueStatus {
        pending_count: pending.len(),
        failed_count: total - pending.len(),
    })
}

/// Recently downloaded track for history display
#[derive(Serialize, Clone)]
pub struct RecentDownload {
    pub id: i64,
    pub artist: String,
    pub title: String,
    pub download_status: String,
    pub organized_path: Option<String>,
    pub format: Option<String>,
    pub bitrate: Option<u64>,
}

/// Get recently downloaded tracks for download history
///
/// Queries tracks that have a non-NULL download_status (indicating they were
/// downloaded), ordered by download timestamp descending. Used to populate
/// the Downloads page history on mount.
///
/// # Returns
/// * `Vec<RecentDownload>` - Up to 50 most recently downloaded tracks
#[tauri::command]
pub async fn get_recent_downloads() -> Result<Vec<RecentDownload>, String> {
    log::info!("get_recent_downloads invoked");

    use crate::database::get_connection;

    let db_path = PathBuf::from("music_library.db");
    let db_conn = get_connection(&db_path)
        .map_err(|e| format!("Failed to get database connection: {}", e))?;

    let mut stmt = db_conn
        .prepare(
            "SELECT id, artist, title, download_status, organized_path, format, bitrate
             FROM tracks WHERE download_status IS NOT NULL
             ORDER BY download_status DESC LIMIT 50",
        )
        .map_err(|e| format!("Failed to prepare query: {}", e))?;

    let rows = stmt
        .query_map([], |row| {
            Ok(RecentDownload {
                id: row.get(0)?,
                artist: row.get(1)?,
                title: row.get(2)?,
                download_status: row.get(3)?,
                organized_path: row.get(4)?,
                format: row.get(5)?,
                bitrate: row.get(6)?,
            })
        })
        .map_err(|e| format!("Failed to query recent downloads: {}", e))?;

    let downloads: Vec<RecentDownload> = rows
        .filter_map(|r| r.ok())
        .collect();

    log::info!("Returning {} recent downloads", downloads.len());
    Ok(downloads)
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
            downloaded_track_ids: vec![1, 2, 3],
            downloaded_paths: vec![(1, "/path/to/file.m4a".to_string())],
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
