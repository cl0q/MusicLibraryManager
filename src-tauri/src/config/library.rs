//! Library configuration management.
//!
//! Provides LibraryConfig struct for managing library root path, scan folders,
//! download destination, and library identification. Handles relative/absolute
//! path conversion for portability.

use std::path::{Path, PathBuf};
use serde::{Deserialize, Serialize};
use rusqlite::Connection;
use chrono::Utc;

/// Library configuration with relative path helpers.
///
/// Stores library root path, scan folders, download destination, and library ID.
/// Paths are stored as relative to library root for portability.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LibraryConfig {
    /// Absolute path to library root (None if not configured)
    pub root_path: Option<PathBuf>,

    /// Relative paths from root to scan for music (e.g., vec!["00_Artist", "03_Club"])
    pub scan_folders: Vec<String>,

    /// Relative path from root for new downloads (e.g., "00_Artist")
    pub download_destination: String,

    /// Stable library identifier (UUID, None if not configured)
    pub library_id: Option<String>,

    /// Whether library was explicitly configured
    pub configured: bool,
}

impl Default for LibraryConfig {
    fn default() -> Self {
        Self {
            root_path: None,
            scan_folders: Vec::new(),
            download_destination: "00_Artist".to_string(),
            library_id: None,
            configured: false,
        }
    }
}

impl LibraryConfig {
    /// Load configuration from database.
    ///
    /// Returns default unconfigured state if library_root key is empty or missing.
    pub fn load(conn: &Connection) -> Result<Self, Box<dyn std::error::Error>> {
        // Check if library is configured
        let library_root: String = conn
            .query_row(
                "SELECT value FROM app_config WHERE key = 'library_root'",
                [],
                |row| row.get(0),
            )
            .unwrap_or_default();

        if library_root.is_empty() {
            return Ok(Self::default());
        }

        let library_id: String = conn
            .query_row(
                "SELECT value FROM app_config WHERE key = 'library_id'",
                [],
                |row| row.get(0),
            )
            .unwrap_or_default();

        let scan_folders_json: String = conn
            .query_row(
                "SELECT value FROM app_config WHERE key = 'scan_folders'",
                [],
                |row| row.get(0),
            )
            .unwrap_or_else(|_| "[]".to_string());

        let scan_folders: Vec<String> = serde_json::from_str(&scan_folders_json)?;

        let download_destination: String = conn
            .query_row(
                "SELECT value FROM app_config WHERE key = 'download_destination'",
                [],
                |row| row.get(0),
            )
            .unwrap_or_else(|_| "00_Artist".to_string());

        Ok(Self {
            root_path: Some(PathBuf::from(library_root)),
            scan_folders,
            download_destination,
            library_id: if library_id.is_empty() { None } else { Some(library_id) },
            configured: true,
        })
    }

    /// Save configuration to database.
    ///
    /// Uses INSERT OR REPLACE for upsert semantics.
    pub fn save(&self, conn: &Connection) -> Result<(), Box<dyn std::error::Error>> {
        let root_path = self.root_path.as_ref()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();

        let library_id = self.library_id.as_ref()
            .map(|s| s.as_str())
            .unwrap_or("");

        let scan_folders_json = serde_json::to_string(&self.scan_folders)?;

        // Upsert configuration values
        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)",
            ["library_root", &root_path],
        )?;

        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)",
            ["library_id", library_id],
        )?;

        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)",
            ["scan_folders", &scan_folders_json],
        )?;

        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)",
            ["download_destination", &self.download_destination],
        )?;

        let configured = if self.configured { "1" } else { "0" };
        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)",
            ["library_configured", configured],
        )?;

        Ok(())
    }

    /// Resolve relative path to absolute path within library.
    ///
    /// Returns None if library is not configured.
    pub fn resolve_path(&self, relative: &str) -> Option<PathBuf> {
        self.root_path.as_ref().map(|root| root.join(relative))
    }

    /// Convert absolute path to relative path (for database storage).
    ///
    /// Returns error if path is not within library root or if not configured.
    pub fn make_relative(&self, absolute: &Path) -> Result<String, String> {
        let root = self.root_path.as_ref()
            .ok_or_else(|| "Library not configured".to_string())?;

        let relative = absolute.strip_prefix(root)
            .map_err(|_| format!("Path {} is not within library root", absolute.display()))?;

        // Convert to string with forward slashes for portability
        let relative_str = relative.to_str()
            .ok_or_else(|| "Path contains invalid UTF-8".to_string())?;

        // Normalize path separators to forward slashes
        Ok(relative_str.replace('\\', "/"))
    }

    /// Check if library is configured.
    pub fn is_configured(&self) -> bool {
        self.configured
    }
}

/// Marker file metadata for library verification.
#[derive(Serialize, Deserialize, Debug)]
pub struct MarkerFile {
    pub version: u32,
    pub library_id: String,
    pub created_at: String,
    pub name: Option<String>,
}

/// Verify marker file exists and return its contents.
pub fn verify_marker_file(path: &Path) -> Result<MarkerFile, String> {
    let marker_path = path.join("mlm-library.json");

    if !marker_path.exists() {
        return Err("No MLM library found at this location".to_string());
    }

    let content = std::fs::read_to_string(&marker_path)
        .map_err(|e| format!("Failed to read marker file: {}", e))?;

    let marker: MarkerFile = serde_json::from_str(&content)
        .map_err(|e| format!("Invalid marker file format: {}", e))?;

    Ok(marker)
}

/// Create marker file at library root.
pub fn create_marker_file(path: &Path, library_id: &str) -> Result<(), String> {
    let marker_path = path.join("mlm-library.json");

    let marker = MarkerFile {
        version: 1,
        library_id: library_id.to_string(),
        created_at: Utc::now().to_rfc3339(),
        name: None,
    };

    let content = serde_json::to_string_pretty(&marker)
        .map_err(|e| format!("Failed to serialize marker file: {}", e))?;

    std::fs::write(&marker_path, content)
        .map_err(|e| format!("Failed to write marker file: {}", e))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use crate::database::get_memory_connection;

    #[test]
    fn test_default_config_unconfigured() {
        let config = LibraryConfig::default();
        assert!(!config.is_configured());
        assert!(config.root_path.is_none());
        assert!(config.library_id.is_none());
    }

    #[test]
    fn test_load_unconfigured() {
        let conn = get_memory_connection().unwrap();
        let config = LibraryConfig::load(&conn).unwrap();

        assert!(!config.is_configured());
        assert!(config.root_path.is_none());
    }

    #[test]
    fn test_save_and_load() {
        let conn = get_memory_connection().unwrap();

        let config = LibraryConfig {
            root_path: Some(PathBuf::from("/Volumes/Lexxar/Music")),
            scan_folders: vec!["00_Artist".to_string(), "03_Club".to_string()],
            download_destination: "00_Artist".to_string(),
            library_id: Some("test-uuid-123".to_string()),
            configured: true,
        };

        config.save(&conn).unwrap();

        let loaded = LibraryConfig::load(&conn).unwrap();
        assert!(loaded.is_configured());
        assert_eq!(loaded.root_path.unwrap().to_str().unwrap(), "/Volumes/Lexxar/Music");
        assert_eq!(loaded.scan_folders, vec!["00_Artist", "03_Club"]);
        assert_eq!(loaded.download_destination, "00_Artist");
        assert_eq!(loaded.library_id.unwrap(), "test-uuid-123");
    }

    #[test]
    fn test_resolve_path() {
        let config = LibraryConfig {
            root_path: Some(PathBuf::from("/Volumes/Lexxar/Music")),
            scan_folders: vec![],
            download_destination: "00_Artist".to_string(),
            library_id: None,
            configured: true,
        };

        let resolved = config.resolve_path("00_Artist/SomeArtist/Album").unwrap();
        assert_eq!(resolved.to_str().unwrap(), "/Volumes/Lexxar/Music/00_Artist/SomeArtist/Album");
    }

    #[test]
    fn test_make_relative() {
        let config = LibraryConfig {
            root_path: Some(PathBuf::from("/Volumes/Lexxar/Music")),
            scan_folders: vec![],
            download_destination: "00_Artist".to_string(),
            library_id: None,
            configured: true,
        };

        let absolute = PathBuf::from("/Volumes/Lexxar/Music/00_Artist/SomeArtist/track.mp3");
        let relative = config.make_relative(&absolute).unwrap();
        assert_eq!(relative, "00_Artist/SomeArtist/track.mp3");
    }

    #[test]
    fn test_make_relative_outside_root() {
        let config = LibraryConfig {
            root_path: Some(PathBuf::from("/Volumes/Lexxar/Music")),
            scan_folders: vec![],
            download_destination: "00_Artist".to_string(),
            library_id: None,
            configured: true,
        };

        let absolute = PathBuf::from("/Users/someone/file.mp3");
        let result = config.make_relative(&absolute);
        assert!(result.is_err());
    }

    #[test]
    fn test_marker_file_create_and_verify() {
        let dir = tempdir().unwrap();
        let library_id = "test-uuid-456";

        create_marker_file(dir.path(), library_id).unwrap();

        let marker = verify_marker_file(dir.path()).unwrap();
        assert_eq!(marker.version, 1);
        assert_eq!(marker.library_id, library_id);
        assert!(marker.name.is_none());
    }

    #[test]
    fn test_verify_marker_file_missing() {
        let dir = tempdir().unwrap();
        let result = verify_marker_file(dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("No MLM library found"));
    }
}
