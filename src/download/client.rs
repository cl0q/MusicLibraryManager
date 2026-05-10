use anyhow::{Context, Result};
use backoff::{future::retry, Error as BackoffError, ExponentialBackoff};
use reqwest::{Client, Response, StatusCode};
use std::time::Duration;

/// Configuration for HTTP retry behavior
#[derive(Debug, Clone)]
pub struct RetryConfig {
    pub max_retries: u32,
    pub initial_interval: Duration,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_retries: 3,
            initial_interval: Duration::from_secs(1),
        }
    }
}

/// HTTP client wrapper with exponential backoff retry logic
pub struct HttpClient {
    client: Client,
    config: RetryConfig,
}

impl HttpClient {
    /// Create a new HTTP client with default retry configuration
    pub fn new() -> Result<Self> {
        Self::with_config(RetryConfig::default())
    }

    /// Create a new HTTP client with custom retry configuration
    pub fn with_config(config: RetryConfig) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .cookie_store(true)
            .build()
            .context("Failed to build HTTP client")?;

        Ok(Self { client, config })
    }

    /// Perform GET request with exponential backoff retry
    ///
    /// Classifies errors:
    /// - 404 Not Found → permanent error (no retry)
    /// - 429 Rate Limited → transient error (retry with backoff)
    /// - 5xx Server Errors → transient error (retry with backoff)
    /// - Network errors → transient error (retry with backoff)
    pub async fn get_with_retry(&self, url: &str) -> Result<Response> {
        self.get_with_retry_and_headers(url, None).await
    }

    /// Perform GET request with custom headers and exponential backoff retry
    pub async fn get_with_retry_and_headers(
        &self,
        url: &str,
        headers: Option<&reqwest::header::HeaderMap>,
    ) -> Result<Response> {
        let backoff_config = ExponentialBackoff {
            initial_interval: self.config.initial_interval,
            max_elapsed_time: Some(Duration::from_secs(30)),
            ..Default::default()
        };

        let operation = || async {
            let mut request = self.client.get(url);
            if let Some(h) = headers {
                request = request.headers(h.clone());
            }

            let response = request
                .send()
                .await
                .map_err(|e| {
                    BackoffError::transient(anyhow::Error::from(e))
                })?;

            let status = response.status();

            match status {
                status if status.is_success() => Ok(response),
                StatusCode::NOT_FOUND => {
                    Err(BackoffError::permanent(anyhow::anyhow!(
                        "Resource not found (404)"
                    )))
                }
                StatusCode::TOO_MANY_REQUESTS => {
                    Err(BackoffError::transient(anyhow::anyhow!(
                        "Rate limited (429), will retry"
                    )))
                }
                status if status.is_server_error() => {
                    Err(BackoffError::transient(anyhow::anyhow!(
                        "Server error ({}), will retry",
                        status
                    )))
                }
                _ => {
                    Err(BackoffError::permanent(anyhow::anyhow!(
                        "HTTP error: {}",
                        status
                    )))
                }
            }
        };

        retry(backoff_config, operation)
            .await
            .context("Request failed after retries")
    }

    /// Perform POST request with JSON body (no retry — used for login)
    pub async fn post_json<T: serde::Serialize>(
        &self,
        url: &str,
        body: &T,
    ) -> Result<Response> {
        self.client
            .post(url)
            .json(body)
            .send()
            .await
            .context("POST request failed")
    }

    /// Get a reference to the inner reqwest client
    pub fn inner(&self) -> &Client {
        &self.client
    }
}

impl Default for HttpClient {
    fn default() -> Self {
        Self::new().expect("Failed to create default HTTP client")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_retry_config_defaults() {
        let config = RetryConfig::default();
        assert_eq!(config.max_retries, 3);
        assert_eq!(config.initial_interval, Duration::from_secs(1));
    }

    #[tokio::test]
    async fn test_http_client_creation() {
        let client = HttpClient::new();
        assert!(client.is_ok());
    }

    #[tokio::test]
    async fn test_http_client_with_custom_config() {
        let config = RetryConfig {
            max_retries: 5,
            initial_interval: Duration::from_millis(500),
        };
        let client = HttpClient::with_config(config);
        assert!(client.is_ok());
    }

    // Note: Integration tests for actual HTTP retry behavior
    // would require a mock server (e.g., mockito or wiremock)
    // These tests verify configuration and client creation only
}
