//! Mount detection module for library drive monitoring.
//!
//! Provides OS-level mount detection so the app knows when the configured
//! library drive connects or disconnects. Uses filesystem watching to monitor
//! volume mount/unmount events and emits Tauri events to the frontend.

pub mod detector;

pub use detector::{MountDetector, LibraryMountState};
