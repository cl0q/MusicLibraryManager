//! Shared transcode cache management for device sync.
//!
//! Provides efficient caching and linking of transcoded AAC files across multiple
//! sync profiles. Files are transcoded once and reused, avoiding duplicate work
//! and disk space usage.
//!
//! # Platform-specific behavior
//!
//! - **Unix (macOS, Linux)**: Uses hardlinks when possible (same filesystem),
//!   falls back to copy if hardlink fails (cross-filesystem)
//! - **Windows**: Always copies files (symlinks require admin privileges)
//!
//! # Example
//! ```ignore
//! use music_library_manager::sync::cache::TranscodeCache;
//! use std::path::PathBuf;
//!
//! let cache = TranscodeCache::new(PathBuf::from("/cache"))?;
//! let cache_path = cache.get_cache_path(42, Path::new("/original.flac"));
//!
//! if cache.exists(42, Path::new("/original.flac")) {
//!     cache.link_to_profile(&cache_path, Path::new("/profile/Artist/Album/Track.m4a"))?;
//! }
//! ```

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use crate::metadata::sanitize::sanitize_filename;
use crate::models::track::Track;

/// Shared transcode cache for managing AAC files across sync profiles.
///
/// The cache stores transcoded files with deterministic names based on track ID,
/// allowing multiple sync profiles to reference the same cached file without
/// re-transcoding or duplicating disk space.
pub struct TranscodeCache {
    cache_dir: PathBuf,
}

impl TranscodeCache {
    /// Create a new TranscodeCache with the specified cache directory.
    ///
    /// The cache directory will be created if it doesn't exist.
    ///
    /// # Arguments
    /// * `cache_dir` - Path to the cache directory
    ///
    /// # Returns
    /// A new TranscodeCache instance
    ///
    /// # Errors
    /// Returns an error if the cache directory cannot be created
    pub fn new(cache_dir: PathBuf) -> Result<Self> {
        fs::create_dir_all(&cache_dir)
            .with_context(|| format!("Failed to create cache directory: {}", cache_dir.display()))?;
        Ok(Self { cache_dir })
    }

    /// Get deterministic cache path for a track.
    ///
    /// Cache files are named `{track_id}.m4a` for simple, stable references.
    /// The track_id uniquely identifies the cached transcode.
    ///
    /// # Arguments
    /// * `track_id` - Database ID of the track
    /// * `original_path` - Original file path (unused but kept for future expansion)
    ///
    /// # Returns
    /// Path to the cached AAC file
    pub fn get_cache_path(&self, track_id: i64, _original_path: &Path) -> PathBuf {
        self.cache_dir.join(format!("{}.m4a", track_id))
    }

    /// Check if a cached transcode exists for a track.
    ///
    /// Validates that the cache file exists and has non-zero size.
    ///
    /// # Arguments
    /// * `track_id` - Database ID of the track
    /// * `original_path` - Original file path
    ///
    /// # Returns
    /// `true` if cached file exists and is valid, `false` otherwise
    pub fn exists(&self, track_id: i64, original_path: &Path) -> bool {
        let cache_path = self.get_cache_path(track_id, original_path);

        if !cache_path.exists() {
            return false;
        }

        // Validate file has non-zero size
        match fs::metadata(&cache_path) {
            Ok(metadata) => metadata.len() > 0,
            Err(_) => false,
        }
    }

    /// Link or copy cached file to profile folder.
    ///
    /// Platform-specific behavior:
    /// - Unix: Attempts hardlink first (efficient, same filesystem), falls back to copy
    /// - Windows: Always copies (symlinks require elevated privileges)
    ///
    /// Creates parent directories as needed.
    ///
    /// # Arguments
    /// * `cache_path` - Path to cached AAC file
    /// * `profile_path` - Destination path in profile folder
    ///
    /// # Returns
    /// `Ok(())` on success
    ///
    /// # Errors
    /// Returns an error if the file operation fails
    pub fn link_to_profile(&self, cache_path: &Path, profile_path: &Path) -> Result<()> {
        // Create parent directories
        if let Some(parent) = profile_path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create parent directories: {}", parent.display()))?;
        }

        #[cfg(unix)]
        {
            // Try hardlink first (same filesystem, saves space)
            if std::fs::hard_link(cache_path, profile_path).is_ok() {
                log::debug!(
                    "Hardlinked {} to {}",
                    cache_path.display(),
                    profile_path.display()
                );
                return Ok(());
            }

            // Fallback to copy if hard_link fails (cross-filesystem)
            log::debug!(
                "Hardlink failed, copying {} to {}",
                cache_path.display(),
                profile_path.display()
            );
            copy_with_buffering(cache_path, profile_path)?;
        }

        #[cfg(not(unix))]
        {
            // Windows: always copy (symlinks need admin rights)
            log::debug!(
                "Copying {} to {} (Windows)",
                cache_path.display(),
                profile_path.display()
            );
            copy_with_buffering(cache_path, profile_path)?;
        }

        Ok(())
    }

    /// Compute SHA256 checksum for a file.
    ///
    /// Used for sync state tracking to detect file changes.
    /// Reads file in 64KB chunks for memory efficiency.
    ///
    /// # Arguments
    /// * `path` - Path to the file
    ///
    /// # Returns
    /// Hex-encoded SHA256 checksum string
    ///
    /// # Errors
    /// Returns an error if the file cannot be read
    pub fn compute_checksum(&self, path: &Path) -> Result<String> {
        let mut file = File::open(path)
            .with_context(|| format!("Failed to open file for checksum: {}", path.display()))?;

        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 65536]; // 64KB buffer

        loop {
            let n = file
                .read(&mut buffer)
                .with_context(|| format!("Failed to read file for checksum: {}", path.display()))?;

            if n == 0 {
                break;
            }

            hasher.update(&buffer[..n]);
        }

        Ok(format!("{:x}", hasher.finalize()))
    }

    /// Build profile-specific path for a track.
    ///
    /// Preserves library folder hierarchy by stripping library_root from
    /// original_path and swapping the extension to .m4a.
    /// Falls back to Artist/Album/Track.m4a if original_path is not under library_root.
    ///
    /// # Arguments
    /// * `profile_folder` - Base path to profile folder
    /// * `track` - Track to generate path for
    /// * `library_root` - Library root path to strip from original_path
    pub fn build_profile_path(&self, profile_folder: &Path, track: &Track, library_root: &Path) -> Result<PathBuf> {
        let original = Path::new(&track.metadata.original_path);

        if let Ok(relative) = original.strip_prefix(library_root) {
            // Preserve library structure, sanitize each component, swap extension
            let mut profile_path = profile_folder.to_path_buf();
            if let Some(parent) = relative.parent() {
                for component in parent.components() {
                    if let std::path::Component::Normal(part) = component {
                        profile_path.push(sanitize_filename(
                            part.to_str().unwrap_or("unknown"),
                        ));
                    }
                }
            }
            let stem = relative
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown");
            profile_path.push(format!("{}.m4a", sanitize_filename(stem)));
            Ok(profile_path)
        } else if track.metadata.original_path.contains("soundcloud.com") {
            // SoundCloud tracks: 03_Club/SoundCloud/title.m4a
            let title = sanitize_filename(&track.metadata.title);
            Ok(profile_folder.join("03_Club").join("SoundCloud").join(format!("{}.m4a", title)))
        } else {
            // Fallback: track not under library root
            let artist = sanitize_filename(&track.metadata.album_artist);
            let album = sanitize_filename(&track.metadata.album);
            let title = sanitize_filename(&track.metadata.title);
            Ok(profile_folder.join(&artist).join(&album).join(format!("{}.m4a", title)))
        }
    }
}

/// Copy file with buffered I/O for memory efficiency.
///
/// Uses 64KB buffer to handle large files with fixed memory usage.
/// Suitable for multi-MB AAC files without loading entire file into memory.
///
/// # Arguments
/// * `src` - Source file path
/// * `dst` - Destination file path
///
/// # Returns
/// `Ok(())` on success
///
/// # Errors
/// Returns an error if file operations fail
fn copy_with_buffering(src: &Path, dst: &Path) -> Result<()> {
    let mut reader = BufReader::new(
        File::open(src)
            .with_context(|| format!("Failed to open source file: {}", src.display()))?
    );

    let mut writer = BufWriter::new(
        File::create(dst)
            .with_context(|| format!("Failed to create destination file: {}", dst.display()))?
    );

    const CHUNK_SIZE: usize = 65536; // 64KB
    let mut buffer = [0u8; CHUNK_SIZE];

    loop {
        let n = reader
            .read(&mut buffer)
            .with_context(|| format!("Failed to read from source: {}", src.display()))?;

        if n == 0 {
            break;
        }

        writer
            .write_all(&buffer[..n])
            .with_context(|| format!("Failed to write to destination: {}", dst.display()))?;
    }

    writer
        .flush()
        .with_context(|| format!("Failed to flush destination: {}", dst.display()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::track::{Track, TrackMetadata};
    use tempfile::TempDir;

    const TEST_LIBRARY_ROOT: &str = "/library";

    fn create_test_track(id: i64, artist: &str, album: &str, title: &str) -> Track {
        let metadata = TrackMetadata {
            artist: artist.to_string(),
            album_artist: artist.to_string(),
            album: album.to_string(),
            title: title.to_string(),
            genre: None,
            year: None,
            bitrate: None,
            duration: None,
            format: "flac".to_string(),
            original_path: format!("/library/00_Artist/{}/{}/{}.flac", artist, album, title),
        };

        Track {
            id: Some(id),
            metadata,
            organized_path: Some(format!("{}/{}/{}.flac", artist, album, title)),
            is_duplicate: false,
            date_added: None,
            ..Default::default()
        }
    }

    #[test]
    fn test_cache_path_deterministic() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        let path1 = cache.get_cache_path(42, Path::new("/original/file.flac"));
        let path2 = cache.get_cache_path(42, Path::new("/different/path.flac"));

        // Same track_id should produce same cache path regardless of original path
        assert_eq!(path1, path2);
        assert!(path1.ends_with("42.m4a"));
    }

    #[test]
    fn test_exists_nonexistent() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        assert!(!cache.exists(999, Path::new("/nonexistent.flac")));
    }

    #[test]
    fn test_exists_valid_file() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Create a valid cache file
        let cache_path = cache.get_cache_path(123, Path::new("/test.flac"));
        fs::write(&cache_path, b"test audio data").unwrap();

        assert!(cache.exists(123, Path::new("/test.flac")));
    }

    #[test]
    fn test_exists_zero_size_file() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Create empty cache file (invalid)
        let cache_path = cache.get_cache_path(456, Path::new("/test.flac"));
        fs::write(&cache_path, b"").unwrap();

        assert!(!cache.exists(456, Path::new("/test.flac")));
    }

    #[test]
    fn test_link_to_profile_creates_file() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Create source cache file
        let cache_path = cache.get_cache_path(789, Path::new("/test.flac"));
        let test_data = b"test aac audio data";
        fs::write(&cache_path, test_data).unwrap();

        // Link to profile
        let profile_path = temp_dir.path().join("profile/Artist/Album/Track.m4a");
        cache.link_to_profile(&cache_path, &profile_path).unwrap();

        // Verify file exists and has correct content
        assert!(profile_path.exists());
        let content = fs::read(&profile_path).unwrap();
        assert_eq!(content, test_data);
    }

    #[test]
    fn test_link_to_profile_creates_directories() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Create source cache file
        let cache_path = cache.get_cache_path(101, Path::new("/test.flac"));
        fs::write(&cache_path, b"data").unwrap();

        // Link to nested path that doesn't exist
        let profile_path = temp_dir.path().join("profile/deep/nested/path/Track.m4a");
        cache.link_to_profile(&cache_path, &profile_path).unwrap();

        // Verify directories were created
        assert!(profile_path.parent().unwrap().exists());
        assert!(profile_path.exists());
    }

    #[test]
    fn test_compute_checksum_consistent() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Create test file
        let test_file = temp_dir.path().join("test.txt");
        fs::write(&test_file, b"test content for checksum").unwrap();

        // Compute checksum multiple times
        let checksum1 = cache.compute_checksum(&test_file).unwrap();
        let checksum2 = cache.compute_checksum(&test_file).unwrap();

        // Should be consistent
        assert_eq!(checksum1, checksum2);

        // Should be valid hex string
        assert_eq!(checksum1.len(), 64); // SHA256 is 256 bits = 64 hex chars
        assert!(checksum1.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_compute_checksum_different_content() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        // Create two files with different content
        let file1 = temp_dir.path().join("file1.txt");
        let file2 = temp_dir.path().join("file2.txt");

        fs::write(&file1, b"content A").unwrap();
        fs::write(&file2, b"content B").unwrap();

        let checksum1 = cache.compute_checksum(&file1).unwrap();
        let checksum2 = cache.compute_checksum(&file2).unwrap();

        // Different content should produce different checksums
        assert_ne!(checksum1, checksum2);
    }

    #[test]
    fn test_build_profile_path_preserves_library_structure() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        let track = create_test_track(1, "Artist Name", "Album Name", "Track Title");
        let profile_folder = temp_dir.path().join("profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);

        let path = cache.build_profile_path(&profile_folder, &track, library_root).unwrap();

        // Should preserve library hierarchy (00_Artist/Artist/Album/Track.m4a)
        assert!(path.to_string_lossy().contains("00_Artist"));
        assert!(path.to_string_lossy().contains("Artist Name"));
        assert!(path.to_string_lossy().contains("Album Name"));
        assert!(path.to_string_lossy().contains("Track Title"));
        assert!(path.to_string_lossy().ends_with(".m4a"));
    }

    #[test]
    fn test_build_profile_path_sanitizes() {
        let temp_dir = TempDir::new().unwrap();
        let cache = TranscodeCache::new(temp_dir.path().to_path_buf()).unwrap();

        let mut track = create_test_track(2, "Artist: Name", "Album/Part 2", "Track?");
        track.metadata.original_path = "/library/00_Artist/Artist: Name/Album/Part 2/Track?.flac".to_string();
        let profile_folder = temp_dir.path().join("profile");
        let library_root = Path::new(TEST_LIBRARY_ROOT);

        let path = cache.build_profile_path(&profile_folder, &track, library_root).unwrap();
        let path_str = path.to_string_lossy();

        // Should not contain invalid FAT32 characters
        assert!(!path_str.contains(':'));
        assert!(!path_str.contains('?'));

        // Path separators should only be directory separators
        let components: Vec<_> = path.components().collect();
        assert!(components.len() >= 4); // profile/artist/album/track.m4a
    }

    #[test]
    fn test_copy_with_buffering() {
        let temp_dir = TempDir::new().unwrap();

        let src = temp_dir.path().join("source.dat");
        let dst = temp_dir.path().join("dest.dat");

        // Create source file with test data
        let test_data = b"test data for buffered copy operation";
        fs::write(&src, test_data).unwrap();

        // Copy
        copy_with_buffering(&src, &dst).unwrap();

        // Verify
        assert!(dst.exists());
        let copied_data = fs::read(&dst).unwrap();
        assert_eq!(copied_data, test_data);
    }

    #[test]
    fn test_copy_with_buffering_large_file() {
        let temp_dir = TempDir::new().unwrap();

        let src = temp_dir.path().join("large.dat");
        let dst = temp_dir.path().join("large_copy.dat");

        // Create larger file (> buffer size to test chunking)
        let test_data = vec![0xAB; 128 * 1024]; // 128KB
        fs::write(&src, &test_data).unwrap();

        copy_with_buffering(&src, &dst).unwrap();

        // Verify size and content match
        let src_metadata = fs::metadata(&src).unwrap();
        let dst_metadata = fs::metadata(&dst).unwrap();
        assert_eq!(src_metadata.len(), dst_metadata.len());

        let copied_data = fs::read(&dst).unwrap();
        assert_eq!(copied_data, test_data);
    }
}
