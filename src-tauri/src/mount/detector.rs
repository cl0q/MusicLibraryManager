//! Mount detector implementation using filesystem watching.
//!
//! Monitors the /Volumes directory (macOS) for mount/unmount events by watching
//! for directory creation/deletion. When changes occur, checks if the configured
//! library root path exists and emits events to the frontend.

use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use notify::{Watcher, RecursiveMode, Event};
use serde::Serialize;
use tauri::Emitter;

/// Library mount state for frontend communication.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum LibraryMountState {
    Connected,
    Disconnected,
    NotConfigured,
}

/// Mount detector service that monitors library drive connection state.
///
/// Watches the /Volumes directory for mount/unmount events and tracks
/// whether the configured library root path is accessible.
pub struct MountDetector {
    /// Current mount state
    state: Arc<RwLock<LibraryMountState>>,
    /// Library root path being monitored
    library_root: PathBuf,
}

impl MountDetector {
    /// Create a new mount detector instance.
    ///
    /// Checks initial mount state by verifying library root exists.
    pub fn new(library_root: PathBuf) -> Self {
        let initial_state = if library_root.exists() {
            LibraryMountState::Connected
        } else {
            LibraryMountState::Disconnected
        };

        Self {
            state: Arc::new(RwLock::new(initial_state)),
            library_root,
        }
    }

    /// Get current mount state.
    pub fn get_state(&self) -> LibraryMountState {
        self.state.read().unwrap().clone()
    }

    /// Start background mount detection.
    ///
    /// Spawns a background thread that watches /Volumes for changes.
    /// When volumes mount or unmount, checks if library root path exists
    /// and emits events to the frontend when state changes.
    ///
    /// Returns Arc<Self> so it can be stored in Tauri managed state.
    pub fn start(
        app_handle: tauri::AppHandle,
        library_root: PathBuf,
    ) -> Result<Arc<Self>, String> {
        let detector = Arc::new(Self::new(library_root.clone()));

        // Clone Arc references for background thread
        let detector_clone = Arc::clone(&detector);
        let app_handle_clone = app_handle.clone();

        // Emit initial state
        let initial_state = detector.get_state();
        log::info!("Library mount detector initialized: {:?}", initial_state);
        app_handle
            .emit("library-mount-changed", &initial_state)
            .map_err(|e| format!("Failed to emit initial state: {}", e))?;

        // Spawn background watcher thread
        std::thread::spawn(move || {
            if let Err(e) = Self::watch_volumes(detector_clone, app_handle_clone) {
                log::error!("Mount detection thread error: {}", e);
            }
        });

        Ok(detector)
    }

    /// Watch /Volumes directory for mount/unmount events.
    ///
    /// This function runs in a background thread and monitors the /Volumes
    /// directory. On macOS, when a volume is mounted, a new directory appears
    /// in /Volumes. When unmounted, the directory disappears.
    fn watch_volumes(
        detector: Arc<Self>,
        app_handle: tauri::AppHandle,
    ) -> Result<(), String> {
        let (tx, rx) = std::sync::mpsc::channel();

        // Create watcher for /Volumes directory
        let mut watcher = notify::recommended_watcher(tx)
            .map_err(|e| format!("Failed to create watcher: {}", e))?;

        // Watch /Volumes (non-recursive to avoid deep scanning)
        #[cfg(target_os = "macos")]
        let watch_path = PathBuf::from("/Volumes");

        #[cfg(not(target_os = "macos"))]
        let watch_path = {
            log::warn!("Mount detection not fully implemented for this platform");
            detector.library_root.parent()
                .unwrap_or(&detector.library_root)
                .to_path_buf()
        };

        watcher
            .watch(&watch_path, RecursiveMode::NonRecursive)
            .map_err(|e| format!("Failed to watch {}: {}", watch_path.display(), e))?;

        log::info!("Mount detector watching: {}", watch_path.display());

        // Event loop
        loop {
            match rx.recv_timeout(Duration::from_secs(1)) {
                Ok(Ok(event)) => {
                    // On any event in /Volumes, check library state
                    if Self::is_relevant_event(&event) {
                        Self::check_and_update_state(&detector, &app_handle);
                    }
                }
                Ok(Err(e)) => {
                    log::warn!("Watcher error: {}", e);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    // Periodic check even without events
                    Self::check_and_update_state(&detector, &app_handle);
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    log::error!("Watcher channel disconnected");
                    break;
                }
            }
        }

        Ok(())
    }

    /// Check if the filesystem event is relevant for mount detection.
    fn is_relevant_event(event: &Event) -> bool {
        use notify::EventKind;

        match event.kind {
            // Directory creation/deletion indicates mount/unmount
            EventKind::Create(_) | EventKind::Remove(_) => true,
            // Modification events might also indicate mount state changes
            EventKind::Modify(_) => true,
            _ => false,
        }
    }

    /// Check library root existence and update state if changed.
    fn check_and_update_state(detector: &Arc<Self>, app_handle: &tauri::AppHandle) {
        let current_exists = detector.library_root.exists();
        let current_state = if current_exists {
            LibraryMountState::Connected
        } else {
            LibraryMountState::Disconnected
        };

        // Check if state changed
        let previous_state = {
            let state_lock = detector.state.read().unwrap();
            state_lock.clone()
        };

        if current_state != previous_state {
            // Update state
            {
                let mut state_lock = detector.state.write().unwrap();
                *state_lock = current_state.clone();
            }

            // Log state change
            log::info!(
                "Library mount state changed: {:?} -> {:?}",
                previous_state,
                current_state
            );

            // Emit event to frontend
            if let Err(e) = app_handle.emit("library-mount-changed", &current_state) {
                log::error!("Failed to emit library-mount-changed event: {}", e);
            }

            // If disconnected, also log a warning
            if current_state == LibraryMountState::Disconnected {
                log::warn!("Library drive disconnected: {}", detector.library_root.display());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mount_state_serialization() {
        let state = LibraryMountState::Connected;
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(json, r#""connected""#);

        let state = LibraryMountState::Disconnected;
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(json, r#""disconnected""#);

        let state = LibraryMountState::NotConfigured;
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(json, r#""notconfigured""#);
    }

    #[test]
    fn test_new_detector_connected() {
        // Use current directory which definitely exists
        let detector = MountDetector::new(std::env::current_dir().unwrap());
        assert_eq!(detector.get_state(), LibraryMountState::Connected);
    }

    #[test]
    fn test_new_detector_disconnected() {
        // Use a path that doesn't exist
        let detector = MountDetector::new(PathBuf::from("/nonexistent/path"));
        assert_eq!(detector.get_state(), LibraryMountState::Disconnected);
    }
}
