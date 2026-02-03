//! OAuth token lifecycle management.
//!
//! Provides proactive token refresh to avoid expired token errors.
//! Tokens are refreshed automatically before they expire (5-minute buffer).

use chrono::{DateTime, TimeDelta, Utc};
use oauth2::{
    basic::{BasicClient, BasicTokenResponse},
    reqwest,
    AuthUrl, ClientId, ClientSecret, RedirectUrl, RefreshToken, TokenResponse, TokenUrl,
};
use thiserror::Error;

use crate::auth::token_storage;

/// Errors that can occur during token refresh.
#[derive(Error, Debug)]
pub enum TokenRefreshError {
    #[error("Token storage error: {0}")]
    StorageError(#[from] token_storage::TokenStorageError),

    #[error("Token refresh failed: {0}")]
    RefreshFailed(String),

    #[error("Invalid OAuth configuration: {0}")]
    InvalidConfig(String),

    #[error("Token still valid, no refresh needed")]
    TokenStillValid,
}

/// Result type for token refresh operations.
pub type Result<T> = std::result::Result<T, TokenRefreshError>;

/// Configured OAuth client type (with token URL set for refresh operations).
type ConfiguredClient = oauth2::Client<
    oauth2::basic::BasicErrorResponse,
    BasicTokenResponse,
    oauth2::basic::BasicTokenIntrospectionResponse,
    oauth2::StandardRevocableToken,
    oauth2::basic::BasicRevocationErrorResponse,
    oauth2::EndpointSet,     // HasAuthUrl
    oauth2::EndpointNotSet,  // HasDeviceAuthUrl
    oauth2::EndpointNotSet,  // HasIntrospectionUrl
    oauth2::EndpointNotSet,  // HasRevocationUrl
    oauth2::EndpointSet,     // HasTokenUrl
>;

/// OAuth token manager for a specific source.
///
/// Manages the OAuth 2.0 Authorization Code flow with PKCE support
/// and handles token refresh transparently.
pub struct TokenManager {
    client: ConfiguredClient,
    source: String,
}

impl TokenManager {
    /// Create a new TokenManager for the specified source.
    ///
    /// # Arguments
    /// * `source` - Source identifier (e.g., "spotify", "soundcloud")
    /// * `client_id` - OAuth client ID
    /// * `client_secret` - OAuth client secret
    /// * `auth_url` - Authorization URL for the OAuth provider
    /// * `token_url` - Token URL for the OAuth provider
    ///
    /// # Returns
    /// * `Ok(TokenManager)` if configuration is valid
    /// * `Err(TokenRefreshError::InvalidConfig)` if URLs are invalid
    ///
    /// # Example
    /// ```ignore
    /// let manager = TokenManager::new(
    ///     "spotify",
    ///     "client_id",
    ///     "client_secret",
    ///     "https://accounts.spotify.com/authorize",
    ///     "https://accounts.spotify.com/api/token",
    /// )?;
    /// ```
    pub fn new(
        source: &str,
        client_id: &str,
        client_secret: &str,
        auth_url: &str,
        token_url: &str,
    ) -> Result<Self> {
        let auth_url = AuthUrl::new(auth_url.to_string())
            .map_err(|e| TokenRefreshError::InvalidConfig(format!("Invalid auth URL: {}", e)))?;
        let token_url = TokenUrl::new(token_url.to_string())
            .map_err(|e| TokenRefreshError::InvalidConfig(format!("Invalid token URL: {}", e)))?;

        let client = BasicClient::new(ClientId::new(client_id.to_string()))
            .set_client_secret(ClientSecret::new(client_secret.to_string()))
            .set_auth_uri(auth_url)
            .set_token_uri(token_url)
            .set_redirect_uri(
                RedirectUrl::new("http://localhost:8080/callback".to_string())
                    .map_err(|e| TokenRefreshError::InvalidConfig(format!("Invalid redirect URL: {}", e)))?,
            );

        Ok(Self {
            client,
            source: source.to_string(),
        })
    }

    /// Get the source identifier for this manager.
    pub fn source(&self) -> &str {
        &self.source
    }

    /// Ensure a valid access token, refreshing if needed.
    ///
    /// Proactively refreshes the token if it will expire within 5 minutes.
    /// This prevents API calls from failing due to expired tokens.
    ///
    /// # Arguments
    /// * `user_id` - User identifier for token retrieval
    /// * `current_expiry` - Current access token expiration time
    ///
    /// # Returns
    /// * `Ok(String)` with new access token if refreshed
    /// * `Err(TokenRefreshError::TokenStillValid)` if no refresh needed
    /// * `Err(TokenRefreshError)` if refresh failed
    ///
    /// # Example
    /// ```ignore
    /// let expiry = Utc::now() + Duration::minutes(3); // Expires in 3 min
    /// let new_token = manager.ensure_valid_token("user123", expiry).await?;
    /// ```
    pub async fn ensure_valid_token(
        &self,
        user_id: &str,
        current_expiry: DateTime<Utc>,
    ) -> Result<String> {
        let now = Utc::now();
        let five_minutes = TimeDelta::minutes(5);

        // Refresh proactively if expiring within 5 minutes
        if now >= current_expiry - five_minutes {
            self.refresh_access_token(user_id).await
        } else {
            // Token still valid, caller should use cached token
            Err(TokenRefreshError::TokenStillValid)
        }
    }

    /// Refresh the access token using the stored refresh token.
    async fn refresh_access_token(&self, user_id: &str) -> Result<String> {
        // Get refresh token from secure storage
        let refresh_token_str = token_storage::get_refresh_token(&self.source, user_id)?;
        let refresh_token = RefreshToken::new(refresh_token_str);

        // Create async HTTP client
        let http_client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| TokenRefreshError::RefreshFailed(format!("HTTP client error: {}", e)))?;

        // Exchange refresh token for new access token
        let token_result = self
            .client
            .exchange_refresh_token(&refresh_token)
            .request_async(&http_client)
            .await
            .map_err(|e| TokenRefreshError::RefreshFailed(format!("{:?}", e)))?;

        // Store new refresh token if provided (some providers rotate refresh tokens)
        if let Some(new_refresh) = token_result.refresh_token() {
            token_storage::store_refresh_token(&self.source, user_id, new_refresh.secret())?;
        }

        Ok(token_result.access_token().secret().to_string())
    }
}

/// Convenience function to ensure a valid token for a source.
///
/// Creates a temporary TokenManager and refreshes the token if needed.
///
/// # Arguments
/// * `source` - Source identifier
/// * `client_id` - OAuth client ID
/// * `client_secret` - OAuth client secret
/// * `auth_url` - Authorization URL
/// * `token_url` - Token URL
/// * `user_id` - User identifier
/// * `current_expiry` - Current access token expiration
///
/// # Returns
/// * `Ok(String)` with access token if refreshed
/// * `Err(TokenRefreshError)` if refresh failed or not needed
pub async fn ensure_valid_token(
    source: &str,
    client_id: &str,
    client_secret: &str,
    auth_url: &str,
    token_url: &str,
    user_id: &str,
    current_expiry: DateTime<Utc>,
) -> Result<String> {
    let manager = TokenManager::new(source, client_id, client_secret, auth_url, token_url)?;
    manager.ensure_valid_token(user_id, current_expiry).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeDelta;

    #[test]
    fn test_token_manager_creation() {
        let manager = TokenManager::new(
            "spotify",
            "test_client_id",
            "test_client_secret",
            "https://accounts.spotify.com/authorize",
            "https://accounts.spotify.com/api/token",
        );
        assert!(manager.is_ok());

        let manager = manager.unwrap();
        assert_eq!(manager.source(), "spotify");
    }

    #[test]
    fn test_token_manager_invalid_auth_url() {
        let manager = TokenManager::new(
            "spotify",
            "test_client_id",
            "test_client_secret",
            "not a valid url",
            "https://accounts.spotify.com/api/token",
        );
        assert!(manager.is_err());
        match manager {
            Err(TokenRefreshError::InvalidConfig(msg)) => {
                assert!(msg.contains("auth URL"));
            }
            _ => panic!("Expected InvalidConfig error"),
        }
    }

    #[test]
    fn test_token_manager_invalid_token_url() {
        let manager = TokenManager::new(
            "spotify",
            "test_client_id",
            "test_client_secret",
            "https://accounts.spotify.com/authorize",
            "not a valid url",
        );
        assert!(manager.is_err());
        match manager {
            Err(TokenRefreshError::InvalidConfig(msg)) => {
                assert!(msg.contains("token URL"));
            }
            _ => panic!("Expected InvalidConfig error"),
        }
    }

    #[tokio::test]
    async fn test_token_still_valid_no_refresh() {
        let manager = TokenManager::new(
            "spotify",
            "test_client_id",
            "test_client_secret",
            "https://accounts.spotify.com/authorize",
            "https://accounts.spotify.com/api/token",
        )
        .unwrap();

        // Token expires in 30 minutes - no refresh needed
        let expiry = Utc::now() + TimeDelta::minutes(30);
        let result = manager.ensure_valid_token("user123", expiry).await;

        assert!(matches!(result, Err(TokenRefreshError::TokenStillValid)));
    }

    #[tokio::test]
    async fn test_token_expiring_soon_needs_refresh() {
        let manager = TokenManager::new(
            "spotify",
            "test_client_id",
            "test_client_secret",
            "https://accounts.spotify.com/authorize",
            "https://accounts.spotify.com/api/token",
        )
        .unwrap();

        // Token expires in 3 minutes - refresh needed (< 5 min buffer)
        let expiry = Utc::now() + TimeDelta::minutes(3);
        let result = manager.ensure_valid_token("user123", expiry).await;

        // Will fail because no refresh token is stored, but it attempted to refresh
        assert!(matches!(
            result,
            Err(TokenRefreshError::StorageError(_))
        ));
    }

    #[test]
    fn test_error_display() {
        let err = TokenRefreshError::TokenStillValid;
        assert_eq!(format!("{}", err), "Token still valid, no refresh needed");

        let err = TokenRefreshError::RefreshFailed("network error".to_string());
        assert_eq!(format!("{}", err), "Token refresh failed: network error");
    }
}
