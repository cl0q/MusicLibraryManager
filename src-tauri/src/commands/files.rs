//! File operation commands.
//!
//! Provides Tauri commands for file-related operations like copying
//! file paths to the system clipboard.

use std::io::Write;
use std::process::Command;

/// Copy text to the system clipboard.
///
/// Uses platform-specific clipboard commands:
/// - macOS: pbcopy
/// - Linux: xclip (primary) or xsel (fallback)
/// - Windows: clip.exe
#[tauri::command]
pub async fn copy_to_clipboard(text: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let mut child = Command::new("pbcopy")
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to spawn pbcopy: {}", e))?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(text.as_bytes())
                .map_err(|e| format!("Failed to write to pbcopy: {}", e))?;
        }

        child
            .wait()
            .map_err(|e| format!("pbcopy failed: {}", e))?;
    }

    #[cfg(target_os = "linux")]
    {
        // Try xclip first
        let xclip_result = Command::new("xclip")
            .arg("-selection")
            .arg("clipboard")
            .stdin(std::process::Stdio::piped())
            .spawn();

        if let Ok(mut child) = xclip_result {
            if let Some(mut stdin) = child.stdin.take() {
                stdin
                    .write_all(text.as_bytes())
                    .map_err(|e| format!("Failed to write to xclip: {}", e))?;
            }
            child
                .wait()
                .map_err(|e| format!("xclip failed: {}", e))?;
        } else {
            // Fall back to xsel
            let mut child = Command::new("xsel")
                .arg("--clipboard")
                .arg("--input")
                .stdin(std::process::Stdio::piped())
                .spawn()
                .map_err(|e| format!("Failed to spawn xsel (xclip also not found): {}", e))?;

            if let Some(mut stdin) = child.stdin.take() {
                stdin
                    .write_all(text.as_bytes())
                    .map_err(|e| format!("Failed to write to xsel: {}", e))?;
            }

            child
                .wait()
                .map_err(|e| format!("xsel failed: {}", e))?;
        }
    }

    #[cfg(target_os = "windows")]
    {
        let mut child = Command::new("clip")
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to spawn clip.exe: {}", e))?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(text.as_bytes())
                .map_err(|e| format!("Failed to write to clip.exe: {}", e))?;
        }

        child
            .wait()
            .map_err(|e| format!("clip.exe failed: {}", e))?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[cfg(target_os = "macos")]
    async fn test_copy_to_clipboard_macos() {
        let result = copy_to_clipboard("test text".to_string()).await;
        // This test will fail if pbcopy is not available
        assert!(result.is_ok());
    }
}
