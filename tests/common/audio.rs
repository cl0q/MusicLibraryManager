//! Test audio file generation utilities.
//!
//! Creates real audio files using ffmpeg for integration tests.
//! These are tiny (1-2 second) sine waves — small but valid audio.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Generate a FLAC test file (lossless, ~32KB for 2s).
pub fn create_test_flac(output_dir: &Path, filename: &str) -> PathBuf {
    let path = output_dir.join(filename);
    let status = Command::new("ffmpeg")
        .args([
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=2",
            "-c:a", "flac",
            "-y",
            path.to_str().unwrap(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("ffmpeg must be installed for audio tests");
    assert!(status.success(), "ffmpeg failed to create test FLAC");
    assert!(path.exists(), "FLAC file was not created");
    path
}

/// Generate an MP3 test file at a specific bitrate.
pub fn create_test_mp3(output_dir: &Path, filename: &str, bitrate_kbps: u32) -> PathBuf {
    let path = output_dir.join(filename);
    let bitrate_arg = format!("{}k", bitrate_kbps);
    let status = Command::new("ffmpeg")
        .args([
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=2",
            "-c:a", "libmp3lame",
            "-b:a", &bitrate_arg,
            "-y",
            path.to_str().unwrap(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("ffmpeg must be installed for audio tests");
    assert!(status.success(), "ffmpeg failed to create test MP3");
    path
}

/// Generate a WAV test file (PCM, lossless).
pub fn create_test_wav(output_dir: &Path, filename: &str) -> PathBuf {
    let path = output_dir.join(filename);
    let status = Command::new("ffmpeg")
        .args([
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=2",
            "-c:a", "pcm_s16le",
            "-y",
            path.to_str().unwrap(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("ffmpeg must be installed for audio tests");
    assert!(status.success(), "ffmpeg failed to create test WAV");
    path
}

/// Generate an AAC test file at a specific bitrate.
pub fn create_test_aac(output_dir: &Path, filename: &str, bitrate_kbps: u32) -> PathBuf {
    let path = output_dir.join(filename);
    let bitrate_arg = format!("{}k", bitrate_kbps);
    let status = Command::new("ffmpeg")
        .args([
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=2",
            "-c:a", "aac",
            "-b:a", &bitrate_arg,
            "-y",
            path.to_str().unwrap(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("ffmpeg must be installed for audio tests");
    assert!(status.success(), "ffmpeg failed to create test AAC/M4A");
    path
}

/// Check if ffmpeg is available on this system.
pub fn ffmpeg_available() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
