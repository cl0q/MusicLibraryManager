//! Rockbox device detection and filesystem operations.
//!
//! Provides platform-specific device detection by scanning mounted volumes
//! for the .rockbox directory marker, and querying available disk space.

use std::path::{Path, PathBuf};
use std::fs;
use anyhow::{Result, Context};
use serde::{Serialize, Deserialize};

/// Rockbox device information.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RockboxDevice {
    pub mount_point: PathBuf,
    pub device_name: String,
    pub available_space: u64,  // Bytes
}

/// Detect all Rockbox devices by scanning platform-specific mount points.
///
/// Platform behavior:
/// - macOS: Scans /Volumes for devices with .rockbox directory
/// - Linux: Scans /mnt and /media recursively for devices with .rockbox directory
/// - Windows: Scans drive letters A: through Z: for devices with .rockbox directory
///
/// Returns empty vector if no devices found (not an error).
pub fn detect_rockbox_devices() -> Result<Vec<RockboxDevice>> {
    let mut devices = Vec::new();

    #[cfg(target_os = "macos")]
    {
        let volumes = PathBuf::from("/Volumes");
        if volumes.exists() {
            for entry in fs::read_dir(&volumes)? {
                let entry = entry?;
                let path = entry.path();
                if is_rockbox_device(&path) {
                    devices.push(create_device_info(path)?);
                }
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        for base in &["/mnt", "/media"] {
            let base_path = PathBuf::from(base);
            if base_path.exists() {
                scan_mount_base(&base_path, &mut devices)?;
            }
        }
    }

    #[cfg(target_os = "windows")]
    {
        // Scan drive letters A: through Z:
        for letter in b'A'..=b'Z' {
            let drive = format!("{}:\\", letter as char);
            let path = PathBuf::from(&drive);
            if path.exists() && is_rockbox_device(&path) {
                devices.push(create_device_info(path)?);
            }
        }
    }

    Ok(devices)
}

/// Check if a path contains a Rockbox device by looking for .rockbox directory.
pub fn is_rockbox_device(path: &Path) -> bool {
    path.join(".rockbox").is_dir()
}

/// Create device info struct from a mount point.
fn create_device_info(mount_point: PathBuf) -> Result<RockboxDevice> {
    let device_name = mount_point
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("Unknown Device")
        .to_string();

    let available_space = get_available_space(&mount_point)?;

    Ok(RockboxDevice {
        mount_point,
        device_name,
        available_space,
    })
}

/// Get available disk space for a mount point.
///
/// Platform implementations:
/// - Unix (macOS/Linux): Uses `df -k` command and parses output
/// - Windows: Uses `wmic` command to query logical disk free space
///
/// Uses std::process::Command to avoid unsafe FFI and external crate dependencies.
pub fn get_available_space(mount_point: &Path) -> Result<u64> {
    #[cfg(unix)]
    {
        use std::process::Command;

        // Use df -k to get available space in kilobytes
        let output = Command::new("df")
            .arg("-k")
            .arg(mount_point)
            .output()
            .context("Failed to execute df command")?;

        if !output.status.success() {
            return Err(anyhow::anyhow!("df command failed"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);

        // Parse df output: header line, then data line
        // Format: Filesystem 1K-blocks Used Available Capacity Mounted on
        let lines: Vec<&str> = stdout.lines().collect();
        if lines.len() < 2 {
            return Err(anyhow::anyhow!("Unexpected df output format"));
        }

        // Get the data line (second line)
        let data_line = lines[1];
        let columns: Vec<&str> = data_line.split_whitespace().collect();

        // Available space is the 4th column (index 3)
        if columns.len() < 4 {
            return Err(anyhow::anyhow!("Cannot parse df output"));
        }

        let available_kb: u64 = columns[3]
            .parse()
            .context("Failed to parse available space")?;

        // Convert from kilobytes to bytes
        Ok(available_kb * 1024)
    }

    #[cfg(windows)]
    {
        use std::process::Command;

        // Get drive letter from mount point
        let drive_letter = mount_point
            .to_str()
            .and_then(|s| s.chars().next())
            .ok_or_else(|| anyhow::anyhow!("Invalid mount point"))?;

        // Use wmic to query free space
        let output = Command::new("wmic")
            .args(&[
                "logicaldisk",
                "where",
                &format!("DeviceID='{}:'", drive_letter),
                "get",
                "FreeSpace",
                "/value",
            ])
            .output()
            .context("Failed to execute wmic command")?;

        if !output.status.success() {
            return Err(anyhow::anyhow!("wmic command failed"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);

        // Parse wmic output: FreeSpace=123456789
        for line in stdout.lines() {
            if line.starts_with("FreeSpace=") {
                let value = line.trim_start_matches("FreeSpace=").trim();
                return value
                    .parse::<u64>()
                    .context("Failed to parse free space value");
            }
        }

        Err(anyhow::anyhow!("Could not find FreeSpace in wmic output"))
    }

    #[cfg(not(any(unix, windows)))]
    {
        // Unsupported platform - return large placeholder value
        Ok(u64::MAX)
    }
}

/// Recursively scan a mount base directory for Rockbox devices.
///
/// Used on Linux to scan /mnt and /media which may have nested mount points.
#[cfg(target_os = "linux")]
fn scan_mount_base(base: &Path, devices: &mut Vec<RockboxDevice>) -> Result<()> {
    if is_rockbox_device(base) {
        devices.push(create_device_info(base.to_path_buf())?);
        return Ok(());
    }

    // Check subdirectories
    if let Ok(entries) = fs::read_dir(base) {
        for entry in entries {
            if let Ok(entry) = entry {
                let path = entry.path();
                if path.is_dir() {
                    // Recursively scan subdirectories
                    if is_rockbox_device(&path) {
                        devices.push(create_device_info(path)?);
                    } else {
                        // Go one level deeper for /media/{username}/DEVICE structure
                        if let Ok(sub_entries) = fs::read_dir(&path) {
                            for sub_entry in sub_entries {
                                if let Ok(sub_entry) = sub_entry {
                                    let sub_path = sub_entry.path();
                                    if sub_path.is_dir() && is_rockbox_device(&sub_path) {
                                        devices.push(create_device_info(sub_path)?);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_is_rockbox_device_detects_marker() {
        let temp_dir = TempDir::new().unwrap();
        let device_path = temp_dir.path();

        // Initially not a Rockbox device
        assert!(!is_rockbox_device(device_path));

        // Create .rockbox directory
        let rockbox_dir = device_path.join(".rockbox");
        fs::create_dir(&rockbox_dir).unwrap();

        // Now it should be detected
        assert!(is_rockbox_device(device_path));
    }

    #[test]
    fn test_is_rockbox_device_rejects_file() {
        let temp_dir = TempDir::new().unwrap();
        let device_path = temp_dir.path();

        // Create .rockbox as a file, not a directory
        let rockbox_file = device_path.join(".rockbox");
        fs::write(&rockbox_file, "not a directory").unwrap();

        // Should not be detected as device
        assert!(!is_rockbox_device(device_path));
    }

    #[test]
    fn test_create_device_info_extracts_name() {
        let temp_dir = TempDir::new().unwrap();
        let device_path = temp_dir.path();

        // Create .rockbox directory
        let rockbox_dir = device_path.join(".rockbox");
        fs::create_dir(&rockbox_dir).unwrap();

        let device_info = create_device_info(device_path.to_path_buf()).unwrap();

        // Device name should be extracted from path
        assert!(!device_info.device_name.is_empty());
        assert_eq!(device_info.mount_point, device_path);
    }

    #[test]
    fn test_get_available_space_returns_bytes() {
        // Test with current directory (should always be accessible)
        let current_dir = std::env::current_dir().unwrap();

        let result = get_available_space(&current_dir);

        // Should succeed and return a positive value
        assert!(result.is_ok());
        let space = result.unwrap();
        assert!(space > 0, "Available space should be greater than 0");
    }

    #[test]
    #[ignore] // Requires actual Rockbox device
    fn test_detect_rockbox_devices_integration() {
        // This test requires a physical Rockbox device to be connected
        // Run manually with: cargo test test_detect_rockbox_devices_integration -- --ignored
        let devices = detect_rockbox_devices().unwrap();

        if !devices.is_empty() {
            println!("Found {} Rockbox device(s):", devices.len());
            for device in &devices {
                println!("  - {} at {:?} ({} bytes available)",
                    device.device_name,
                    device.mount_point,
                    device.available_space
                );
            }
        } else {
            println!("No Rockbox devices found (this is not an error if no device connected)");
        }
    }

    #[test]
    fn test_detect_rockbox_devices_no_error_when_empty() {
        // detect_rockbox_devices should return Ok(vec![]) when no devices found, not an error
        let result = detect_rockbox_devices();
        assert!(result.is_ok());
    }
}
