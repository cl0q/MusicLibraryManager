//! AcoustID lookup and MusicBrainz identification.
//!
//! Provides functions to look up acoustic fingerprints on AcoustID and retrieve
//! MusicBrainz recording IDs for metadata enrichment.

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use reqwest::Client;
use rusqlite::{Connection, Result as SqlResult};
use serde::Deserialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AcoustIdError {
    #[error("AcoustID API key not configured. Set ACOUSTID_API_KEY in .env")]
    NoApiKey,

    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),
}

#[derive(Debug, Deserialize)]
pub struct AcoustIdResponse {
    pub status: String,
    pub results: Vec<AcoustIdResult>,
}

#[derive(Debug, Deserialize)]
pub struct AcoustIdResult {
    pub id: String,
    pub score: f64,
    pub recordings: Option<Vec<AcoustIdRecording>>,
}

#[derive(Debug, Deserialize)]
pub struct AcoustIdRecording {
    pub id: String,
    pub title: Option<String>,
    pub artists: Option<Vec<AcoustIdArtist>>,
}

#[derive(Debug, Deserialize)]
pub struct AcoustIdArtist {
    pub id: String,
    pub name: String,
}

/// Compress fingerprint to AcoustID format.
///
/// Converts raw u32 fingerprint data to base64-encoded string format
/// suitable for AcoustID API submission.
///
/// # Arguments
/// * `raw` - Raw fingerprint data
///
/// # Returns
/// * Base64-encoded fingerprint string
pub fn compress_fingerprint(raw: &[u32]) -> String {
    // Convert Vec<u32> to bytes (little-endian)
    let mut bytes = Vec::with_capacity(raw.len() * 4);
    for &val in raw {
        bytes.extend_from_slice(&val.to_le_bytes());
    }

    // Base64 encode the bytes
    BASE64.encode(&bytes)
}

/// Look up a fingerprint on AcoustID.
///
/// # Arguments
/// * `client` - HTTP client
/// * `api_key` - AcoustID API key
/// * `fingerprint` - Raw fingerprint data
/// * `duration` - Track duration in seconds
///
/// # Returns
/// * `Ok(AcoustIdResponse)` - API response with potential matches
/// * `Err(AcoustIdError)` - If lookup fails
pub async fn lookup_acoustid(
    client: &Client,
    api_key: &str,
    fingerprint: &[u32],
    duration: u32,
) -> Result<AcoustIdResponse, AcoustIdError> {
    if api_key.is_empty() {
        return Err(AcoustIdError::NoApiKey);
    }

    // Compress fingerprint for API
    let compressed = compress_fingerprint(fingerprint);

    // Build form parameters
    let params = [
        ("client", api_key),
        ("duration", &duration.to_string()),
        ("fingerprint", &compressed),
        ("meta", "recordings+releasegroups+compress"),
    ];

    // POST to AcoustID API
    let response = client
        .post("https://api.acoustid.org/v2/lookup")
        .form(&params)
        .send()
        .await?;

    // Parse JSON response
    let result = response.json::<AcoustIdResponse>().await?;

    Ok(result)
}

/// Save AcoustID lookup result to database.
///
/// # Arguments
/// * `conn` - Database connection
/// * `track_id` - Track ID
/// * `acoustid` - AcoustID identifier
/// * `mb_recording_id` - MusicBrainz recording ID (optional)
///
/// # Returns
/// * `Ok(())` - If saved successfully
/// * `Err(rusqlite::Error)` - If database operation fails
pub fn save_acoustid_result(
    conn: &Connection,
    track_id: i64,
    acoustid: &str,
    mb_recording_id: Option<&str>,
) -> SqlResult<()> {
    conn.execute(
        "UPDATE fingerprints SET acoustid = ?, musicbrainz_recording_id = ? WHERE track_id = ?",
        rusqlite::params![acoustid, mb_recording_id, track_id],
    )?;

    Ok(())
}

/// Get AcoustID API key from environment.
///
/// # Returns
/// * `Some(String)` - API key if set
/// * `None` - If ACOUSTID_API_KEY not set in environment
pub fn get_api_key() -> Option<String> {
    std::env::var("ACOUSTID_API_KEY").ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compress_fingerprint() {
        // Test with some sample fingerprint data
        let fingerprint = vec![0x12345678u32, 0xABCDEF01, 0xDEADBEEF];

        let compressed = compress_fingerprint(&fingerprint);

        // Should be base64 encoded
        assert!(!compressed.is_empty());

        // Verify it's valid base64
        let decoded = BASE64.decode(&compressed).unwrap();

        // Should be 12 bytes (3 u32s * 4 bytes each)
        assert_eq!(decoded.len(), 12);

        // Verify first u32 can be reconstructed
        let first_u32 =
            u32::from_le_bytes([decoded[0], decoded[1], decoded[2], decoded[3]]);
        assert_eq!(first_u32, 0x12345678);
    }

    #[test]
    fn test_acoustid_api_key_missing() {
        // Remove the env var to ensure it's not set during test
        std::env::remove_var("ACOUSTID_API_KEY");

        let api_key = get_api_key();
        assert_eq!(api_key, None);
    }

    #[test]
    fn test_save_acoustid_result() {
        // Create in-memory database
        let conn = Connection::open_in_memory().unwrap();
        conn.execute(
            "CREATE TABLE fingerprints (
                track_id INTEGER PRIMARY KEY,
                fingerprint BLOB NOT NULL,
                duration_seconds INTEGER NOT NULL,
                acoustid TEXT,
                musicbrainz_recording_id TEXT
            )",
            [],
        )
        .unwrap();

        // Insert a fingerprint first
        conn.execute(
            "INSERT INTO fingerprints (track_id, fingerprint, duration_seconds)
             VALUES (1, X'12345678', 180)",
            [],
        )
        .unwrap();

        // Save AcoustID result
        save_acoustid_result(
            &conn,
            1,
            "test-acoustid-123",
            Some("mbid-456"),
        )
        .unwrap();

        // Verify it was saved
        let (acoustid, mbid): (String, String) = conn
            .query_row(
                "SELECT acoustid, musicbrainz_recording_id FROM fingerprints WHERE track_id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(acoustid, "test-acoustid-123");
        assert_eq!(mbid, "mbid-456");
    }

    #[tokio::test]
    async fn test_lookup_acoustid_no_api_key() {
        let client = Client::new();
        let fingerprint = vec![0x12345678u32];

        let result = lookup_acoustid(&client, "", &fingerprint, 180).await;

        // Should fail with NoApiKey error
        assert!(result.is_err());
        match result {
            Err(AcoustIdError::NoApiKey) => {
                // Expected
            }
            _ => panic!("Expected NoApiKey error"),
        }
    }
}
