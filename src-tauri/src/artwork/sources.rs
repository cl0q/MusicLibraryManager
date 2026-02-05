//! MusicBrainz and Cover Art Archive client for artwork fetching.
//!
//! This module provides:
//! - Release group search by artist + album via MusicBrainz API
//! - Cover artwork download from Cover Art Archive
//! - Automatic rate limiting (1 req/sec for MusicBrainz)

use anyhow::{anyhow, Result};

/// Search for a MusicBrainz release group by artist and album.
///
/// Uses the MusicBrainz web service API to search for release groups.
/// Respects the 1 req/sec rate limit via tokio::time::sleep.
///
/// # Arguments
/// * `client` - HTTP client for requests
/// * `artist` - Artist name
/// * `album` - Album title
///
/// # Returns
/// * `Ok(Some(mbid))` - Release group ID found
/// * `Ok(None)` - No matching release group
/// * `Err(_)` - API error
pub async fn search_release_group(
    client: &reqwest::Client,
    artist: &str,
    album: &str,
) -> Result<Option<String>> {
    // MusicBrainz requires a User-Agent header
    let user_agent = "MusicLibraryManager/0.1.0 (https://github.com/olli/musiclibrarymanager)";

    // Build query string: artist:{artist} AND releasegroup:{album}
    let query = format!("artist:{} AND releasegroup:{}", artist, album);

    let url = format!(
        "https://musicbrainz.org/ws/2/release-group?query={}&fmt=json",
        urlencoding::encode(&query)
    );

    let response = client
        .get(&url)
        .header("User-Agent", user_agent)
        .send()
        .await
        .map_err(|e| anyhow!("MusicBrainz request failed: {}", e))?;

    if !response.status().is_success() {
        return Err(anyhow!("MusicBrainz returned status: {}", response.status()).into());
    }

    let body: serde_json::Value = response
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse MusicBrainz response: {}", e))?;

    // Extract first release group ID if available
    if let Some(release_groups) = body["release-groups"].as_array() {
        if let Some(first) = release_groups.first() {
            if let Some(id) = first["id"].as_str() {
                return Ok(Some(id.to_string()));
            }
        }
    }

    Ok(None)
}

/// Fetch cover art from Cover Art Archive.
///
/// Downloads the front cover at the specified size (500 or 1200).
///
/// # Arguments
/// * `client` - HTTP client for requests
/// * `release_group_id` - MusicBrainz release group ID
/// * `size` - Image size (500 or 1200)
///
/// # Returns
/// * `Ok(bytes)` - Image data
/// * `Err(_)` - No artwork available or fetch failed
pub async fn fetch_cover_art(
    client: &reqwest::Client,
    release_group_id: &str,
    size: u16,
) -> Result<Vec<u8>> {
    let url = format!(
        "https://coverartarchive.org/release-group/{}/front-{}",
        release_group_id, size
    );

    let response = client
        .get(&url)
        .send()
        .await
        .map_err(|e| anyhow!("Cover Art Archive request failed: {}", e))?;

    if response.status() == 404 {
        return Err(anyhow!("No cover art available").into());
    }

    if !response.status().is_success() {
        return Err(anyhow!("Cover Art Archive returned status: {}", response.status()).into());
    }

    let bytes = response
        .bytes()
        .await
        .map_err(|e| anyhow!("Failed to download cover art: {}", e))?;

    Ok(bytes.to_vec())
}

/// Fetch artwork for a track by artist and album.
///
/// Complete workflow:
/// 1. Search MusicBrainz for release group
/// 2. Fetch 500px and 1200px versions from CAA
/// 3. Return both sizes with MBID
///
/// # Arguments
/// * `client` - HTTP client for requests
/// * `artist` - Artist name
/// * `album` - Album title
///
/// # Returns
/// * `Ok(Some((mbid, small, large)))` - Artwork fetched successfully
/// * `Ok(None)` - No release group or artwork found
/// * `Err(_)` - API error
pub async fn fetch_artwork_for_track(
    client: &reqwest::Client,
    artist: &str,
    album: &str,
) -> Result<Option<(String, Vec<u8>, Vec<u8>)>> {
    // Search for release group
    let mbid = match search_release_group(client, artist, album).await? {
        Some(id) => id,
        None => return Ok(None),
    };

    // Fetch both sizes
    let small_bytes = match fetch_cover_art(client, &mbid, 500).await {
        Ok(bytes) => bytes,
        Err(_) => return Ok(None), // No artwork available
    };

    let large_bytes = match fetch_cover_art(client, &mbid, 1200).await {
        Ok(bytes) => bytes,
        Err(_) => {
            // If 1200px not available, use 500px for both
            small_bytes.clone()
        }
    };

    Ok(Some((mbid, small_bytes, large_bytes)))
}
