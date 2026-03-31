use crate::download::client::HttpClient;
use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::fs::File;
use tokio::io::AsyncWriteExt;

/// DAB Music API track metadata from search results
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DabTrack {
    pub id: u64,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album_title: String,
    #[serde(default)]
    pub album_id: String,
    #[serde(default)]
    pub duration: u64,
    pub audio_quality: Option<DabAudioQuality>,
}

/// Audio quality metadata from DAB
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DabAudioQuality {
    pub maximum_bit_depth: Option<u32>,
    pub maximum_sampling_rate: Option<f64>,
    pub is_hi_res: Option<bool>,
}

/// DAB search response wrapper
#[derive(Debug, Deserialize)]
pub struct DabSearchResponse {
    pub tracks: Vec<DabTrack>,
}

/// DAB stream response — contains the actual download URL
#[derive(Debug, Deserialize)]
pub struct DabStreamResponse {
    pub url: String,
}

/// Result of a download operation
#[derive(Debug)]
pub enum DownloadResult {
    /// File downloaded successfully to this path
    Success(PathBuf),
    /// Track not found on DAB — triggers YouTube fallback
    NotFound,
}

/// Client for DAB Music API (dab.yeet.su)
///
/// Two-step download flow:
/// 1. Search by artist+title to get DAB track ID
/// 2. Get stream URL via /api/stream?trackId=... then download the FLAC
pub struct DabClient {
    client: HttpClient,
    base_url: String,
}

impl DabClient {
    /// Create a new DAB API client
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: HttpClient::new()?,
            base_url: "https://dab.yeet.su/api".to_string(),
        })
    }

    /// Search for tracks by query string
    ///
    /// Returns a list of matching tracks with metadata
    pub async fn search_track(&self, query: &str) -> Result<Vec<DabTrack>> {
        let url = format!("{}/search?q={}", self.base_url, urlencoding::encode(query));

        let response = self
            .client
            .get_with_retry(&url)
            .await
            .context("Failed to search DAB API")?;

        if !response.status().is_success() {
            anyhow::bail!("DAB search returned status: {}", response.status());
        }

        let search_response = response
            .json::<DabSearchResponse>()
            .await
            .context("Failed to parse DAB search response")?;

        Ok(search_response.tracks)
    }

    /// Get the stream URL for a DAB track ID
    ///
    /// Returns the direct FLAC download URL from Qobuz CDN
    async fn get_stream_url(&self, dab_track_id: u64) -> Result<String> {
        let url = format!("{}/stream?trackId={}", self.base_url, dab_track_id);

        let response = self
            .client
            .get_with_retry(&url)
            .await
            .context("Failed to get DAB stream URL")?;

        if response.status().is_client_error() {
            anyhow::bail!("DAB stream returned status: {}", response.status());
        }

        let stream_response = response
            .json::<DabStreamResponse>()
            .await
            .context("Failed to parse DAB stream response")?;

        Ok(stream_response.url)
    }

    /// Search for a track and download the best match as FLAC.
    ///
    /// Flow:
    /// 1. Search DAB by query (artist + title)
    /// 2. Validate the result matches the requested artist/title
    /// 3. Get stream URL for that track
    /// 4. Download FLAC to output_path
    ///
    /// Returns:
    /// - `DownloadResult::Success(path)` if file downloaded successfully
    /// - `DownloadResult::NotFound` if no matching track found on DAB
    /// - `Err` for network/disk errors
    pub async fn search_and_download(
        &self,
        query: &str,
        artist: &str,
        title: &str,
        output_path: &Path,
    ) -> Result<DownloadResult> {
        // Step 1: Search DAB
        log::info!("DAB: Searching for '{}'", query);
        let tracks = match self.search_track(query).await {
            Ok(tracks) => tracks,
            Err(e) => {
                log::warn!("DAB search failed: {}", e);
                return Err(e);
            }
        };

        if tracks.is_empty() {
            log::info!("DAB: No results for '{}'", query);
            return Ok(DownloadResult::NotFound);
        }

        // Step 2: Find a result that matches both artist and title
        let matched = tracks
            .iter()
            .find(|t| title_matches(&t.title, title) && artist_matches(&t.artist, artist));

        let best_match = match matched {
            Some(m) => m,
            None => {
                log::info!(
                    "DAB: {} results but none match '{}' by '{}' (top result: '{}' by '{}')",
                    tracks.len(),
                    title,
                    artist,
                    tracks[0].title,
                    tracks[0].artist
                );
                return Ok(DownloadResult::NotFound);
            }
        };

        log::info!(
            "DAB: Matched: {} - {} (ID: {}, quality: {:?})",
            best_match.artist,
            best_match.title,
            best_match.id,
            best_match.audio_quality
        );

        // Step 3: Get stream URL
        let stream_url = self.get_stream_url(best_match.id).await?;
        log::info!("DAB: Got stream URL, downloading FLAC...");

        // Step 4: Download FLAC from stream URL
        self.download_from_url(&stream_url, output_path).await
    }

    /// Download a DAB track by its numeric track ID directly to a file.
    ///
    /// Two-step: get stream URL via /api/stream?trackId=N, then download.
    /// Used by the orchestrator's retry path when track_id is already known.
    pub async fn download_stream(&self, track_id: &str, output_path: &Path) -> Result<DownloadResult> {
        let id: u64 = track_id.parse().map_err(|_| {
            anyhow!("Invalid DAB track_id (expected integer): {}", track_id)
        })?;
        let stream_url = self.get_stream_url(id).await?;
        self.download_from_url(&stream_url, output_path).await
    }

    /// Download audio from a direct URL to the specified output path
    ///
    /// Streams to temporary file for atomic write:
    /// - Writes to .tmp file first
    /// - Renames to final path only on success
    /// - Deletes partial file on failure
    async fn download_from_url(
        &self,
        url: &str,
        output_path: &Path,
    ) -> Result<DownloadResult> {
        let response = self
            .client
            .get_with_retry(url)
            .await
            .context("Failed to download from stream URL")?;

        if !response.status().is_success() {
            if response.status().as_u16() == 404 {
                return Ok(DownloadResult::NotFound);
            }
            anyhow::bail!("Download returned status: {}", response.status());
        }

        // Create temporary file for atomic write
        let temp_path = output_path.with_extension("tmp");

        // Ensure parent directory exists
        if let Some(parent) = temp_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .context("Failed to create output directory")?;
        }

        // Stream response to temporary file
        let mut file = File::create(&temp_path)
            .await
            .context("Failed to create temporary file")?;

        let mut stream = response.bytes_stream();
        let mut total_bytes: u64 = 0;

        while let Some(chunk_result) = stream.next().await {
            let chunk = chunk_result.context("Failed to read chunk from stream")?;
            total_bytes += chunk.len() as u64;
            file.write_all(&chunk)
                .await
                .context("Failed to write chunk to file")?;
        }

        // Ensure all data is written to disk
        file.flush().await.context("Failed to flush file")?;
        drop(file);

        if total_bytes == 0 {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return Err(anyhow!("Downloaded file is empty"));
        }

        // Atomic rename: only expose complete file
        tokio::fs::rename(&temp_path, output_path)
            .await
            .context("Failed to rename temporary file to final path")?;

        log::info!(
            "DAB: Downloaded {} bytes to {}",
            total_bytes,
            output_path.display()
        );

        Ok(DownloadResult::Success(output_path.to_path_buf()))
    }
}

/// Check if a DAB result title matches the requested title.
///
/// Normalizes both strings (lowercase, strip non-alphanumeric) and checks
/// if one contains the other. This handles cases like:
/// - "Oxycodone" vs "oxycodone" (case)
/// - "Track (feat. Artist)" vs "Track" (extra info)
/// - "Track - Remix" vs "Track" (versions)
fn title_matches(dab_title: &str, requested_title: &str) -> bool {
    let normalize = |s: &str| -> String {
        s.to_lowercase()
            .chars()
            .filter(|c| c.is_alphanumeric() || c.is_whitespace())
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };

    let dab = normalize(dab_title);
    let req = normalize(requested_title);

    if dab.is_empty() || req.is_empty() {
        return false;
    }

    // Exact match or one contains the other
    dab == req || dab.contains(&req) || req.contains(&dab)
}

/// Check if a DAB result artist matches the requested artist.
///
/// Uses the same normalization as title_matches. Checks if one contains
/// the other to handle variations like "Big Scoob" vs "WTM Scoob".
fn artist_matches(dab_artist: &str, requested_artist: &str) -> bool {
    let normalize = |s: &str| -> String {
        s.to_lowercase()
            .chars()
            .filter(|c| c.is_alphanumeric() || c.is_whitespace())
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };

    let dab = normalize(dab_artist);
    let req = normalize(requested_artist);

    if dab.is_empty() || req.is_empty() {
        return false;
    }

    // Exact match or one contains the other
    dab == req || dab.contains(&req) || req.contains(&dab)
}

impl Default for DabClient {
    fn default() -> Self {
        Self::new().expect("Failed to create default DAB client")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_dab_client_creation() {
        let client = DabClient::new();
        assert!(client.is_ok());
    }

    #[tokio::test]
    async fn test_dab_client_default() {
        let client = DabClient::default();
        assert_eq!(client.base_url, "https://dab.yeet.su/api");
    }

    #[tokio::test]
    #[ignore] // Requires network access
    async fn test_search_track() {
        let client = DabClient::new().unwrap();
        let results = client.search_track("duel links *67").await.unwrap();
        assert!(!results.is_empty(), "Should find results for 'duel links *67'");
        assert_eq!(results[0].title.to_lowercase(), "duel links");
    }

    #[tokio::test]
    #[ignore] // Requires network access
    async fn test_search_and_download() {
        let client = DabClient::new().unwrap();
        let temp_dir = TempDir::new().unwrap();
        let output_path = temp_dir.path().join("duel_links.flac");

        let result = client
            .search_and_download("duel links *67", "*67", "duel links", &output_path)
            .await
            .unwrap();

        match result {
            DownloadResult::Success(path) => {
                assert!(path.exists(), "Downloaded file should exist");
                let metadata = std::fs::metadata(&path).unwrap();
                assert!(metadata.len() > 100_000, "FLAC should be > 100KB");
            }
            DownloadResult::NotFound => {
                panic!("Should find 'duel links' by *67 on DAB");
            }
        }
    }

    #[tokio::test]
    #[ignore] // Requires network access
    async fn test_search_rejects_wrong_title() {
        let client = DabClient::new().unwrap();
        let temp_dir = TempDir::new().unwrap();
        let output_path = temp_dir.path().join("test.flac");

        // Search for "Oxycodone" by "WTM Scoob" — DAB won't have this exact track
        // and should NOT match unrelated results
        let result = client
            .search_and_download("WTM Scoob Oxycodone", "WTM Scoob", "Oxycodone", &output_path)
            .await
            .unwrap();

        assert!(
            matches!(result, DownloadResult::NotFound),
            "Should return NotFound when DAB results don't match title"
        );
    }

    #[tokio::test]
    #[ignore] // Makes live HTTP call to dab.yeet.su — fails with 401. See tests/download_pipeline_test.rs for fixture-based version.
    async fn test_search_not_found() {
        let client = DabClient::new().unwrap();
        let temp_dir = TempDir::new().unwrap();
        let output_path = temp_dir.path().join("test.flac");

        let result = client
            .search_and_download("xyznonexistenttrack99999", "", "xyznonexistent", &output_path)
            .await
            .unwrap();

        assert!(
            matches!(result, DownloadResult::NotFound),
            "Should return NotFound for gibberish query"
        );
    }

    #[test]
    fn test_title_matches() {
        // Exact match
        assert!(title_matches("Oxycodone", "Oxycodone"));
        // Case insensitive
        assert!(title_matches("oxycodone", "Oxycodone"));
        // DAB title contains requested
        assert!(title_matches("Oxycodone (feat. Someone)", "Oxycodone"));
        // Requested contains DAB title
        assert!(title_matches("Oxycodone", "Oxycodone Remix"));
        // No match
        assert!(!title_matches("Perfect Opposites", "Oxycodone"));
        assert!(!title_matches("Something Else", "Duel Links"));
        // Empty strings
        assert!(!title_matches("", "Oxycodone"));
        assert!(!title_matches("Oxycodone", ""));
    }

    #[test]
    fn test_artist_matches() {
        // Exact match
        assert!(artist_matches("*67", "*67"));
        // Case insensitive
        assert!(artist_matches("juice wrld", "Juice WRLD"));
        // Contains
        assert!(artist_matches("WTM Scoob", "Scoob"));
        // No match
        assert!(!artist_matches("Juice WRLD", "WTM Scoob"));
        assert!(!artist_matches("COFFEEBLACK", "*67"));
        // Empty
        assert!(!artist_matches("", "Artist"));
        assert!(!artist_matches("Artist", ""));
    }
}
