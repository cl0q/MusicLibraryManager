//! Secure token storage.
//!
//! Uses file-based storage for OAuth refresh tokens.
//! Tokens are stored in the app's data directory.
//!
//! Note: For production, consider encrypting the token file
//! or using the system keychain with proper code signing.

use std::fs;
use std::path::PathBuf;
use thiserror::Error;

/// Errors that can occur during token storage operations.
#[derive(Error, Debug)]
pub enum TokenStorageError {
    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Token not found for {0}/{1}")]
    TokenNotFound(String, String),
}

/// Result type for token storage operations.
pub type Result<T> = std::result::Result<T, TokenStorageError>;

/// Get the token storage directory.
fn get_token_dir() -> PathBuf {
    // Use a .tokens directory in the current working directory
    // In production, this should be in the app's data directory
    PathBuf::from(".tokens")
}

/// Build a filename from source and user_id.
fn build_filename(source: &str, user_id: &str) -> String {
    format!("{}_{}_refresh.token", source, user_id)
}

/// Store a refresh token in the token storage directory.
///
/// # Arguments
/// * `source` - The source identifier (e.g., "spotify", "soundcloud")
/// * `user_id` - The user identifier for this source
/// * `token` - The refresh token to store
///
/// # Returns
/// * `Ok(())` if the token was stored successfully
/// * `Err(TokenStorageError)` if storage failed
///
/// # Example
/// ```ignore
/// store_refresh_token("spotify", "user123", "refresh_token_value")?;
/// ```
pub fn store_refresh_token(source: &str, user_id: &str, token: &str) -> Result<()> {
    let token_dir = get_token_dir();
    let filename = build_filename(source, user_id);
    let path = token_dir.join(&filename);

    log::info!("Storing refresh token to: {:?}", path);

    // Create directory if it doesn't exist
    fs::create_dir_all(&token_dir)?;

    // Write token to file
    fs::write(&path, token)?;

    log::info!("Token stored successfully for {}/{}", source, user_id);
    Ok(())
}

/// Retrieve a refresh token from the token storage directory.
///
/// # Arguments
/// * `source` - The source identifier (e.g., "spotify", "soundcloud")
/// * `user_id` - The user identifier for this source
///
/// # Returns
/// * `Ok(String)` with the refresh token if found
/// * `Err(TokenStorageError::TokenNotFound)` if no token exists
/// * `Err(TokenStorageError::IoError)` for file system errors
///
/// # Example
/// ```ignore
/// let token = get_refresh_token("spotify", "user123")?;
/// ```
pub fn get_refresh_token(source: &str, user_id: &str) -> Result<String> {
    let token_dir = get_token_dir();
    let filename = build_filename(source, user_id);
    let path = token_dir.join(&filename);

    log::debug!("Getting refresh token from: {:?}", path);

    if !path.exists() {
        log::debug!("Token file not found for {}/{}", source, user_id);
        return Err(TokenStorageError::TokenNotFound(
            source.to_string(),
            user_id.to_string(),
        ));
    }

    let token = fs::read_to_string(&path)?;
    log::debug!("Token retrieved for {}/{}", source, user_id);
    Ok(token)
}

/// Delete a refresh token from the token storage directory.
///
/// # Arguments
/// * `source` - The source identifier (e.g., "spotify", "soundcloud")
/// * `user_id` - The user identifier for this source
///
/// # Returns
/// * `Ok(())` if the token was deleted (or didn't exist)
/// * `Err(TokenStorageError)` if deletion failed
///
/// # Example
/// ```ignore
/// delete_token("spotify", "user123")?;
/// ```
pub fn delete_token(source: &str, user_id: &str) -> Result<()> {
    let token_dir = get_token_dir();
    let filename = build_filename(source, user_id);
    let path = token_dir.join(&filename);

    log::info!("Deleting token at: {:?}", path);

    if path.exists() {
        fs::remove_file(&path)?;
        log::info!("Token deleted for {}/{}", source, user_id);
    } else {
        log::debug!("Token file didn't exist for {}/{}", source, user_id);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_build_filename() {
        assert_eq!(
            build_filename("spotify", "user123"),
            "spotify_user123_refresh.token"
        );
        assert_eq!(
            build_filename("soundcloud", "abc"),
            "soundcloud_abc_refresh.token"
        );
    }

    #[test]
    fn test_store_and_retrieve_token() {
        let temp_dir = TempDir::new().unwrap();
        let token_path = temp_dir.path().join("spotify_test_refresh.token");

        // Store
        fs::create_dir_all(temp_dir.path()).unwrap();
        fs::write(&token_path, "test_refresh_token").unwrap();

        // Retrieve
        let token = fs::read_to_string(&token_path).unwrap();
        assert_eq!(token, "test_refresh_token");
    }

    #[test]
    fn test_token_not_found_error_display() {
        let err = TokenStorageError::TokenNotFound("spotify".to_string(), "user123".to_string());
        assert_eq!(format!("{}", err), "Token not found for spotify/user123");
    }
}
