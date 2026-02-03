//! Secure token storage using system keychain.
//!
//! Uses the keyring crate to store OAuth refresh tokens in:
//! - macOS Keychain
//! - Windows Credential Manager
//! - Linux Secret Service
//!
//! Never stores credentials in plaintext files.

use keyring::Entry;
use thiserror::Error;

/// Service name for keychain entries.
const SERVICE_NAME: &str = "com.musiclibrarymanager";

/// Errors that can occur during token storage operations.
#[derive(Error, Debug)]
pub enum TokenStorageError {
    #[error("Keyring error: {0}")]
    KeyringError(#[from] keyring::Error),

    #[error("Token not found for {0}/{1}")]
    TokenNotFound(String, String),
}

/// Result type for token storage operations.
pub type Result<T> = std::result::Result<T, TokenStorageError>;

/// Build a keyring key from source and user_id.
fn build_key(source: &str, user_id: &str) -> String {
    format!("{}_{}_refresh", source, user_id)
}

/// Store a refresh token securely in the system keychain.
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
    let key = build_key(source, user_id);
    let entry = Entry::new(SERVICE_NAME, &key)?;
    entry.set_password(token)?;
    Ok(())
}

/// Retrieve a refresh token from the system keychain.
///
/// # Arguments
/// * `source` - The source identifier (e.g., "spotify", "soundcloud")
/// * `user_id` - The user identifier for this source
///
/// # Returns
/// * `Ok(String)` with the refresh token if found
/// * `Err(TokenStorageError::TokenNotFound)` if no token exists
/// * `Err(TokenStorageError::KeyringError)` for other keyring errors
///
/// # Example
/// ```ignore
/// let token = get_refresh_token("spotify", "user123")?;
/// ```
pub fn get_refresh_token(source: &str, user_id: &str) -> Result<String> {
    let key = build_key(source, user_id);
    let entry = Entry::new(SERVICE_NAME, &key)?;
    match entry.get_password() {
        Ok(token) => Ok(token),
        Err(keyring::Error::NoEntry) => {
            Err(TokenStorageError::TokenNotFound(source.to_string(), user_id.to_string()))
        }
        Err(e) => Err(TokenStorageError::KeyringError(e)),
    }
}

/// Delete a refresh token from the system keychain.
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
    let key = build_key(source, user_id);
    let entry = Entry::new(SERVICE_NAME, &key)?;
    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()), // Already deleted, not an error
        Err(e) => Err(TokenStorageError::KeyringError(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: These tests use a test service name to avoid polluting the real keychain.
    // On CI/headless systems, keyring may fail due to missing credential store.

    /// Test service name to avoid polluting real credentials.
    const TEST_SERVICE: &str = "com.musiclibrarymanager.test";

    /// Helper to create test entries that don't pollute the real keychain.
    fn test_entry(source: &str, user_id: &str) -> keyring::Result<Entry> {
        let key = format!("{}_{}_refresh_test", source, user_id);
        Entry::new(TEST_SERVICE, &key)
    }

    #[test]
    fn test_build_key() {
        assert_eq!(build_key("spotify", "user123"), "spotify_user123_refresh");
        assert_eq!(
            build_key("soundcloud", "abc"),
            "soundcloud_abc_refresh"
        );
    }

    #[test]
    #[ignore] // Requires actual keychain access
    fn test_store_and_retrieve_token() {
        let entry = test_entry("spotify", "test_user").unwrap();

        // Store
        entry.set_password("test_refresh_token").unwrap();

        // Retrieve
        let token = entry.get_password().unwrap();
        assert_eq!(token, "test_refresh_token");

        // Cleanup
        entry.delete_credential().unwrap();
    }

    #[test]
    #[ignore] // Requires actual keychain access
    fn test_delete_nonexistent_token() {
        let entry = test_entry("spotify", "nonexistent_user").unwrap();

        // Delete should not fail for non-existent entry
        let result = entry.delete_credential();
        // NoEntry is acceptable
        match result {
            Ok(()) | Err(keyring::Error::NoEntry) => {}
            Err(e) => panic!("Unexpected error: {:?}", e),
        }
    }

    #[test]
    fn test_token_not_found_error_display() {
        let err = TokenStorageError::TokenNotFound("spotify".to_string(), "user123".to_string());
        assert_eq!(format!("{}", err), "Token not found for spotify/user123");
    }
}
