pub mod client;
pub mod dab;
pub mod orchestrator;
pub mod queue;
pub mod youtube;

// Re-export key types for Tauri commands
pub use orchestrator::{BatchResult, DownloadRequest};
pub use queue::QueueItem;
