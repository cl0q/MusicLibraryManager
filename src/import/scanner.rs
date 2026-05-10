//! Recursive directory scanner for audio files.
//!
//! Scans directories recursively to find supported audio formats:
//! - MP3 (MPEG-1 Audio Layer III)
//! - FLAC (Free Lossless Audio Codec)
//! - AAC/M4A (Advanced Audio Coding)
//! - OGG (Ogg Vorbis)
//! - WAV (Waveform Audio)
//! - AIFF (Audio Interchange File Format)
//! - ALAC (Apple Lossless Audio Codec)
//!
//! # Example
//! ```ignore
//! use std::path::Path;
//! use music_library_manager::import::scan_directory;
//!
//! let files = scan_directory(Path::new("/music"))?;
//! for file in files {
//!     println!("Found: {}", file.display());
//! }
//! ```

use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Errors that can occur during directory scanning.
#[derive(Debug, Error)]
pub enum ScanError {
    /// Filesystem I/O error (permission denied, path not found, etc.)
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    /// No audio files found in the scanned directory tree
    #[error("No audio files found in directory")]
    NoFiles,
}

/// Result type for scanner operations.
pub type Result<T> = std::result::Result<T, ScanError>;

/// Recursively scan a directory for audio files.
///
/// Traverses the directory tree depth-first, collecting paths to all
/// supported audio files. Subdirectories are scanned automatically.
///
/// # Arguments
/// * `dir` - Root directory to scan
///
/// # Returns
/// * `Ok(Vec<PathBuf>)` - Sorted list of audio file paths
/// * `Err(ScanError::Io)` - Filesystem error occurred
/// * `Err(ScanError::NoFiles)` - No audio files found
///
/// # Supported Formats
/// MP3, FLAC, AAC, M4A, OGG, WAV, AIFF, ALAC
///
/// # Example
/// ```ignore
/// use std::path::Path;
/// use music_library_manager::import::scan_directory;
///
/// let files = scan_directory(Path::new("/music/albums"))?;
/// println!("Found {} audio files", files.len());
/// ```
pub fn scan_directory(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut audio_files = Vec::new();

    scan_directory_recursive(dir, &mut audio_files)?;

    // Sort for deterministic output (helps with testing and reproducibility)
    audio_files.sort();

    if audio_files.is_empty() {
        return Err(ScanError::NoFiles);
    }

    Ok(audio_files)
}

/// Internal recursive scanner that collects audio files into a Vec.
///
/// Separated from public API to allow continuing on subdirectory errors
/// while still collecting files from accessible directories.
fn scan_directory_recursive(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_dir() {
            // Continue scanning subdirectories, ignore permission errors on subdirs
            if let Err(e) = scan_directory_recursive(&path, files) {
                // Log but continue - we want to find as many files as possible
                eprintln!(
                    "Warning: Could not scan subdirectory {}: {}",
                    path.display(),
                    e
                );
            }
        } else if is_audio_file(&path) {
            files.push(path);
        }
    }

    Ok(())
}

/// Check if a file path has a supported audio extension.
///
/// Checks are case-insensitive (both .MP3 and .mp3 match).
///
/// # Supported Extensions
/// - mp3 (MPEG-1 Audio Layer III)
/// - flac (Free Lossless Audio Codec)
/// - aac (Advanced Audio Coding - raw)
/// - m4a (Advanced Audio Coding - container)
/// - ogg (Ogg Vorbis)
/// - wav (Waveform Audio)
/// - aiff (Audio Interchange File Format)
/// - alac (Apple Lossless - typically in m4a container)
fn is_audio_file(path: &Path) -> bool {
    path.extension()
        .and_then(|s| s.to_str())
        .map(|ext| ext.to_lowercase())
        .map(|ext| {
            matches!(
                ext.as_str(),
                "mp3" | "flac" | "aac" | "m4a" | "ogg" | "wav" | "aiff" | "alac"
            )
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use tempfile::tempdir;

    // ===== is_audio_file tests =====

    #[test]
    fn test_is_audio_file_mp3() {
        assert!(is_audio_file(Path::new("song.mp3")));
        assert!(is_audio_file(Path::new("song.MP3")));
    }

    #[test]
    fn test_is_audio_file_flac() {
        assert!(is_audio_file(Path::new("track.flac")));
        assert!(is_audio_file(Path::new("track.FLAC")));
    }

    #[test]
    fn test_is_audio_file_aac_m4a() {
        assert!(is_audio_file(Path::new("audio.aac")));
        assert!(is_audio_file(Path::new("audio.m4a")));
    }

    #[test]
    fn test_is_audio_file_ogg() {
        assert!(is_audio_file(Path::new("music.ogg")));
    }

    #[test]
    fn test_is_audio_file_wav() {
        assert!(is_audio_file(Path::new("sample.wav")));
    }

    #[test]
    fn test_is_audio_file_aiff() {
        assert!(is_audio_file(Path::new("hires.aiff")));
    }

    #[test]
    fn test_is_audio_file_alac() {
        assert!(is_audio_file(Path::new("lossless.alac")));
    }

    #[test]
    fn test_is_audio_file_non_audio() {
        assert!(!is_audio_file(Path::new("image.jpg")));
        assert!(!is_audio_file(Path::new("document.txt")));
        assert!(!is_audio_file(Path::new("video.mp4")));
        assert!(!is_audio_file(Path::new("archive.zip")));
    }

    #[test]
    fn test_is_audio_file_no_extension() {
        assert!(!is_audio_file(Path::new("noextension")));
    }

    // ===== scan_directory tests =====

    #[test]
    fn test_scan_directory_finds_audio_files() {
        let dir = tempdir().unwrap();

        // Create test audio files
        File::create(dir.path().join("song1.mp3")).unwrap();
        File::create(dir.path().join("song2.flac")).unwrap();
        File::create(dir.path().join("readme.txt")).unwrap();

        let files = scan_directory(dir.path()).unwrap();

        assert_eq!(files.len(), 2);
        assert!(files.iter().any(|p| p.ends_with("song1.mp3")));
        assert!(files.iter().any(|p| p.ends_with("song2.flac")));
    }

    #[test]
    fn test_scan_directory_recursive() {
        let dir = tempdir().unwrap();

        // Create nested directory structure
        let subdir = dir.path().join("artist/album");
        fs::create_dir_all(&subdir).unwrap();

        File::create(dir.path().join("root.mp3")).unwrap();
        File::create(subdir.join("track.flac")).unwrap();

        let files = scan_directory(dir.path()).unwrap();

        assert_eq!(files.len(), 2);
        assert!(files.iter().any(|p| p.ends_with("root.mp3")));
        assert!(files.iter().any(|p| p.ends_with("track.flac")));
    }

    #[test]
    fn test_scan_directory_no_files_error() {
        let dir = tempdir().unwrap();

        // Create only non-audio files
        File::create(dir.path().join("readme.txt")).unwrap();
        File::create(dir.path().join("cover.jpg")).unwrap();

        let result = scan_directory(dir.path());

        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ScanError::NoFiles));
    }

    #[test]
    fn test_scan_directory_empty() {
        let dir = tempdir().unwrap();

        let result = scan_directory(dir.path());

        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ScanError::NoFiles));
    }

    #[test]
    fn test_scan_directory_results_sorted() {
        let dir = tempdir().unwrap();

        // Create files that would be unordered if not sorted
        File::create(dir.path().join("z_song.mp3")).unwrap();
        File::create(dir.path().join("a_song.mp3")).unwrap();
        File::create(dir.path().join("m_song.mp3")).unwrap();

        let files = scan_directory(dir.path()).unwrap();

        assert_eq!(files.len(), 3);
        // Verify sorted order
        let filenames: Vec<_> = files
            .iter()
            .map(|p| p.file_name().unwrap().to_str().unwrap())
            .collect();
        assert_eq!(filenames, vec!["a_song.mp3", "m_song.mp3", "z_song.mp3"]);
    }

    #[test]
    fn test_scan_directory_nonexistent() {
        let result = scan_directory(Path::new("/nonexistent/directory"));

        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ScanError::Io(_)));
    }
}
