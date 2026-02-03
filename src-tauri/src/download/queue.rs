use anyhow::{Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// A single item in the retry queue
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueueItem {
    /// Unique identifier for the track
    pub track_id: String,
    /// Search query for YouTube fallback
    pub query: String,
    /// Source that failed: "dab" or "youtube"
    pub source: String,
    /// Number of retry attempts made
    pub attempt_count: u32,
    /// Error message from last failure
    pub last_error: String,
    /// ISO 8601 timestamp when item was queued
    pub queued_at: String,
}

impl QueueItem {
    /// Create a new queue item
    pub fn new(track_id: String, query: String, source: String, error: String) -> Self {
        Self {
            track_id,
            query,
            source,
            attempt_count: 1,
            last_error: error,
            queued_at: Utc::now().to_rfc3339(),
        }
    }
}

/// Persistent retry queue for failed downloads
///
/// Queue is persisted to disk as JSON, ensuring no tracks are lost on app restart.
/// Max retry attempts (default 3) prevents unbounded queue growth.
pub struct RetryQueue {
    items: Vec<QueueItem>,
    max_attempts: u32,
    queue_path: PathBuf,
}

impl RetryQueue {
    /// Create a new retry queue with the specified storage path
    pub fn new(queue_path: PathBuf) -> Self {
        Self {
            items: Vec::new(),
            max_attempts: 3, // User decision in 02-CONTEXT.md
            queue_path,
        }
    }

    /// Load queue items from disk
    ///
    /// If the queue file doesn't exist (first run), items remain empty.
    /// Reference: RESEARCH.md "Pattern 4: Persistent Retry Queue"
    pub fn load(&mut self) -> Result<()> {
        if !self.queue_path.exists() {
            log::info!("Queue file not found, starting with empty queue");
            return Ok(());
        }

        let contents = std::fs::read_to_string(&self.queue_path)
            .context("Failed to read queue file")?;

        self.items = serde_json::from_str(&contents)
            .context("Failed to deserialize queue items")?;

        log::info!("Loaded {} items from queue", self.items.len());
        Ok(())
    }

    /// Save queue items to disk atomically
    ///
    /// Atomic write pattern: write to temp file, then rename to queue_path.
    /// This prevents corruption if app crashes mid-write.
    /// Reference: RESEARCH.md "Code Examples: Persistent Retry Queue with Serialization"
    pub fn save(&self) -> Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = self.queue_path.parent() {
            std::fs::create_dir_all(parent)
                .context("Failed to create queue directory")?;
        }

        // Serialize items to pretty JSON
        let json = serde_json::to_string_pretty(&self.items)
            .context("Failed to serialize queue items")?;

        // Atomic write: temp file + rename
        let temp_path = self.queue_path.with_extension("tmp");
        std::fs::write(&temp_path, json)
            .context("Failed to write temporary queue file")?;

        std::fs::rename(&temp_path, &self.queue_path)
            .context("Failed to rename temporary queue file")?;

        log::debug!("Saved {} items to queue", self.items.len());
        Ok(())
    }

    /// Add an item to the queue
    ///
    /// Items are only added if they haven't exceeded max retry attempts.
    /// Queue is automatically saved after adding.
    pub fn add(&mut self, item: QueueItem) -> Result<()> {
        if item.attempt_count >= self.max_attempts {
            log::warn!(
                "Max retries exceeded for {}, dropping from queue",
                item.track_id
            );
            return Ok(());
        }

        self.items.push(item);
        self.save()?;
        Ok(())
    }

    /// Remove an item from the queue by track_id
    ///
    /// Queue is automatically saved after removal.
    pub fn remove(&mut self, track_id: &str) -> Result<()> {
        self.items.retain(|item| item.track_id != track_id);
        self.save()?;
        Ok(())
    }

    /// Get all pending items (those under max retry attempts)
    pub fn get_pending(&self) -> Vec<QueueItem> {
        self.items
            .iter()
            .filter(|item| item.attempt_count < self.max_attempts)
            .cloned()
            .collect()
    }

    /// Get total number of items in queue
    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Check if queue is empty
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_queue_item_creation() {
        let item = QueueItem::new(
            "track123".to_string(),
            "Artist - Title".to_string(),
            "dab".to_string(),
            "Network error".to_string(),
        );

        assert_eq!(item.track_id, "track123");
        assert_eq!(item.query, "Artist - Title");
        assert_eq!(item.source, "dab");
        assert_eq!(item.attempt_count, 1);
        assert_eq!(item.last_error, "Network error");
        assert!(!item.queued_at.is_empty());
    }

    #[test]
    fn test_retry_queue_new() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("queue.json");
        let queue = RetryQueue::new(queue_path.clone());

        assert_eq!(queue.max_attempts, 3);
        assert_eq!(queue.queue_path, queue_path);
        assert!(queue.is_empty());
    }

    #[test]
    fn test_save_and_load_round_trip() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("queue.json");

        // Create and save queue
        let mut queue = RetryQueue::new(queue_path.clone());
        let item1 = QueueItem::new(
            "track1".to_string(),
            "Query 1".to_string(),
            "dab".to_string(),
            "Error 1".to_string(),
        );
        let item2 = QueueItem::new(
            "track2".to_string(),
            "Query 2".to_string(),
            "youtube".to_string(),
            "Error 2".to_string(),
        );

        queue.add(item1.clone()).unwrap();
        queue.add(item2.clone()).unwrap();

        assert_eq!(queue.len(), 2);

        // Load into new queue instance
        let mut queue2 = RetryQueue::new(queue_path);
        queue2.load().unwrap();

        assert_eq!(queue2.len(), 2);
        assert_eq!(queue2.items[0].track_id, "track1");
        assert_eq!(queue2.items[1].track_id, "track2");
    }

    #[test]
    fn test_load_nonexistent_file() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("nonexistent.json");

        let mut queue = RetryQueue::new(queue_path);
        let result = queue.load();

        assert!(result.is_ok());
        assert!(queue.is_empty());
    }

    #[test]
    fn test_max_attempts_enforcement() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("queue.json");

        let mut queue = RetryQueue::new(queue_path);

        // Create item with attempt_count already at max
        let mut item = QueueItem::new(
            "track1".to_string(),
            "Query".to_string(),
            "dab".to_string(),
            "Error".to_string(),
        );
        item.attempt_count = 3; // Max attempts

        // Should not add to queue
        queue.add(item).unwrap();
        assert!(queue.is_empty());
    }

    #[test]
    fn test_remove_item() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("queue.json");

        let mut queue = RetryQueue::new(queue_path);
        let item1 = QueueItem::new(
            "track1".to_string(),
            "Query 1".to_string(),
            "dab".to_string(),
            "Error 1".to_string(),
        );
        let item2 = QueueItem::new(
            "track2".to_string(),
            "Query 2".to_string(),
            "youtube".to_string(),
            "Error 2".to_string(),
        );

        queue.add(item1).unwrap();
        queue.add(item2).unwrap();
        assert_eq!(queue.len(), 2);

        // Remove first item
        queue.remove("track1").unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue.items[0].track_id, "track2");
    }

    #[test]
    fn test_get_pending() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("queue.json");

        let mut queue = RetryQueue::new(queue_path);

        // Add item within retry limit
        let item1 = QueueItem::new(
            "track1".to_string(),
            "Query 1".to_string(),
            "dab".to_string(),
            "Error 1".to_string(),
        );
        queue.add(item1).unwrap();

        // Add item at max retries
        let mut item2 = QueueItem::new(
            "track2".to_string(),
            "Query 2".to_string(),
            "youtube".to_string(),
            "Error 2".to_string(),
        );
        item2.attempt_count = 3;
        // Bypass add() validation to test get_pending filtering
        queue.items.push(item2);

        // get_pending should only return item1
        let pending = queue.get_pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].track_id, "track1");
    }

    #[test]
    fn test_atomic_write_creates_parent_dir() {
        let temp_dir = TempDir::new().unwrap();
        let queue_path = temp_dir.path().join("subdir").join("queue.json");

        let mut queue = RetryQueue::new(queue_path.clone());
        let item = QueueItem::new(
            "track1".to_string(),
            "Query".to_string(),
            "dab".to_string(),
            "Error".to_string(),
        );

        // Should create parent directory automatically
        queue.add(item).unwrap();
        assert!(queue_path.exists());
        assert!(queue_path.parent().unwrap().exists());
    }
}
