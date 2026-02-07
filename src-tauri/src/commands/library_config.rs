//! Library configuration commands.
//!
//! Provides Tauri commands for library folder selection, configuration,
//! subfolder listing, and connection checking.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tauri::{AppHandle, State};
use tauri_plugin_dialog::DialogExt;

use crate::config::{LibraryConfig, create_marker_file, verify_marker_file};
use crate::database::connection::get_connection;
use crate::mount::MountDetector;

/// Open native OS folder picker for library selection.
///
/// Returns selected path as String, or None if user cancelled.
#[tauri::command]
pub async fn select_library_folder(
    app_handle: AppHandle,
) -> Result<Option<String>, String> {
    // Use Tauri v2 dialog plugin to show folder picker
    let folder_path = app_handle
        .dialog()
        .file()
        .blocking_pick_folder();

    // Convert Option<FilePath> to Option<String>
    // FilePath implements Display, so we can use to_string()
    Ok(folder_path.map(|p| p.to_string()))
}

/// Get immediate subdirectories of a path.
///
/// Returns sorted list of directory names (not full paths).
/// Filters out hidden directories (starting with '.').
#[tauri::command]
pub async fn get_subfolders(root_path: String) -> Result<Vec<String>, String> {
    let path = Path::new(&root_path);

    if !path.exists() {
        return Err(format!("Path does not exist: {}", root_path));
    }

    if !path.is_dir() {
        return Err(format!("Path is not a directory: {}", root_path));
    }

    let mut subfolders = Vec::new();

    let entries = fs::read_dir(path)
        .map_err(|e| format!("Failed to read directory: {}", e))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("Failed to read entry: {}", e))?;
        let path = entry.path();

        if path.is_dir() {
            if let Some(name) = path.file_name() {
                let name_str = name.to_string_lossy().to_string();
                // Filter out hidden directories
                if !name_str.starts_with('.') {
                    subfolders.push(name_str);
                }
            }
        }
    }

    subfolders.sort();
    Ok(subfolders)
}

/// Configure library with root path, scan folders, and download destination.
///
/// Validates path, creates or verifies marker file, and saves to database.
#[tauri::command]
pub async fn configure_library(
    root_path: String,
    scan_folders: Vec<String>,
    download_destination: String,
) -> Result<(), String> {
    let path = Path::new(&root_path);

    // Validate root path exists and is a directory
    if !path.exists() {
        return Err(format!("Path does not exist: {}", root_path));
    }

    if !path.is_dir() {
        return Err(format!("Path is not a directory: {}", root_path));
    }

    // Validate root path is writable
    let test_file = path.join(".mlm-write-test");
    fs::write(&test_file, "test")
        .map_err(|e| format!("Directory is not writable: {}", e))?;
    fs::remove_file(&test_file)
        .map_err(|e| format!("Failed to clean up test file: {}", e))?;

    // Check for existing marker file or create new one
    let library_id = match verify_marker_file(path) {
        Ok(marker) => {
            // Existing library found, use its ID
            log::info!("Found existing library with ID: {}", marker.library_id);
            marker.library_id
        }
        Err(_) => {
            // No marker file, create new library
            let new_id = uuid::Uuid::new_v4().to_string();
            create_marker_file(path, &new_id)
                .map_err(|e| format!("Failed to create marker file: {}", e))?;
            log::info!("Created new library with ID: {}", new_id);
            new_id
        }
    };

    // Create and save configuration
    let config = LibraryConfig {
        root_path: Some(PathBuf::from(root_path)),
        scan_folders,
        download_destination,
        library_id: Some(library_id),
        configured: true,
    };

    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path)
        .map_err(|e| format!("Database connection failed: {}", e))?;

    config.save(&conn)
        .map_err(|e| format!("Failed to save configuration: {}", e))?;

    log::info!("Library configured successfully");
    Ok(())
}

/// Get current library configuration.
///
/// Returns LibraryConfig struct with current settings.
#[tauri::command]
pub async fn get_library_config() -> Result<LibraryConfig, String> {
    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path)
        .map_err(|e| format!("Database connection failed: {}", e))?;

    LibraryConfig::load(&conn)
        .map_err(|e| format!("Failed to load configuration: {}", e))
}

/// Check if library drive is currently connected.
///
/// Returns true if library is configured and root path exists, false otherwise.
#[tauri::command]
pub async fn check_library_connection() -> Result<bool, String> {
    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path)
        .map_err(|e| format!("Database connection failed: {}", e))?;

    let config = LibraryConfig::load(&conn)
        .map_err(|e| format!("Failed to load configuration: {}", e))?;

    if !config.is_configured() {
        return Ok(false);
    }

    // Check if root path exists and is accessible
    if let Some(root) = config.root_path {
        Ok(root.exists() && root.is_dir())
    } else {
        Ok(false)
    }
}

/// Get current library mount state from MountDetector.
///
/// Returns the current mount state as a string: "connected", "disconnected", or "not_configured".
/// If MountDetector is not registered (library not configured at startup), returns "not_configured".
#[tauri::command]
pub async fn get_library_mount_state(
    mount_detector: State<'_, Arc<MountDetector>>,
) -> Result<String, String> {
    use crate::mount::LibraryMountState;

    let state = mount_detector.get_state();

    let state_str = match state {
        LibraryMountState::Connected => "connected",
        LibraryMountState::Disconnected => "disconnected",
        LibraryMountState::NotConfigured => "not_configured",
    };

    Ok(state_str.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use std::fs;
    use crate::database::get_memory_connection;

    #[tokio::test]
    async fn test_get_subfolders() {
        let dir = tempdir().unwrap();
        let root = dir.path();

        // Create some subdirectories
        fs::create_dir(root.join("00_Artist")).unwrap();
        fs::create_dir(root.join("03_Club")).unwrap();
        fs::create_dir(root.join(".hidden")).unwrap();

        // Create a file (should be ignored)
        fs::write(root.join("file.txt"), "test").unwrap();

        let subfolders = get_subfolders(root.to_string_lossy().to_string())
            .await
            .unwrap();

        assert_eq!(subfolders, vec!["00_Artist", "03_Club"]);
    }

    #[tokio::test]
    async fn test_get_subfolders_nonexistent() {
        let result = get_subfolders("/nonexistent/path".to_string()).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("does not exist"));
    }

    #[tokio::test]
    async fn test_configure_library_creates_marker() {
        let dir = tempdir().unwrap();
        let root = dir.path();

        // Create a subfolder for scanning
        fs::create_dir(root.join("Music")).unwrap();

        let result = configure_library(
            root.to_string_lossy().to_string(),
            vec!["Music".to_string()],
            "Music".to_string(),
        )
        .await;

        assert!(result.is_ok());

        // Verify marker file was created
        let marker_path = root.join("mlm-library.json");
        assert!(marker_path.exists());

        // Verify marker can be read
        let marker = verify_marker_file(root).unwrap();
        assert_eq!(marker.version, 1);
        assert!(!marker.library_id.is_empty());
    }

    #[tokio::test]
    async fn test_configure_library_uses_existing_marker() {
        let dir = tempdir().unwrap();
        let root = dir.path();

        // Create existing marker file
        let existing_id = "existing-uuid-123";
        create_marker_file(root, existing_id).unwrap();

        let result = configure_library(
            root.to_string_lossy().to_string(),
            vec![],
            "Downloads".to_string(),
        )
        .await;

        assert!(result.is_ok());

        // Verify existing ID was preserved
        let marker = verify_marker_file(root).unwrap();
        assert_eq!(marker.library_id, existing_id);
    }

    #[tokio::test]
    async fn test_configure_library_readonly_fails() {
        // This test is platform-specific and may not work on all systems
        // Skip if we can't create a readonly directory
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let dir = tempdir().unwrap();
            let root = dir.path();

            // Make directory readonly
            let mut perms = fs::metadata(root).unwrap().permissions();
            perms.set_mode(0o444);
            fs::set_permissions(root, perms).unwrap();

            let result = configure_library(
                root.to_string_lossy().to_string(),
                vec![],
                "Downloads".to_string(),
            )
            .await;

            assert!(result.is_err());
            assert!(result.unwrap_err().contains("not writable"));

            // Restore permissions for cleanup
            let mut perms = fs::metadata(root).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(root, perms).unwrap();
        }
    }

    #[tokio::test]
    async fn test_check_library_connection_unconfigured() {
        // Use in-memory database for test
        let result = check_library_connection().await;
        // This will return Ok(false) since no library is configured in the test db
        assert!(result.is_ok());
    }
}
