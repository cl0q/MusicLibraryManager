//! Album artwork fetching, caching, and embedding module.
//!
//! This module provides automatic artwork management:
//! - Fetch album artwork from MusicBrainz Cover Art Archive
//! - Local file caching to avoid re-downloading
//! - Embed artwork into audio files for portable device compatibility
//!
//! The module fetches two sizes:
//! - 500px for embedding (iPod Classic resolution)
//! - 1200px for UI display (high-DPI screens)

pub mod cache;
pub mod embed;
pub mod sources;

pub use cache::ArtworkCache;
pub use sources::fetch_artwork_for_track;

use anyhow::Result;
use rusqlite::Connection;

/// Result of batch artwork fetching operation.
#[derive(Debug, Clone)]
pub struct BatchArtworkResult {
    pub fetched: usize,
    pub already_cached: usize,
    pub not_found: usize,
    pub failed: Vec<(i64, String)>,
}

/// Batch fetch artwork for multiple tracks.
///
/// This function orchestrates the complete artwork workflow:
/// 1. Check if artwork is already cached
/// 2. Check if track has embedded artwork (extract to cache)
/// 3. Fetch from MusicBrainz/CAA if not available
/// 4. Save to cache and database
///
/// Respects 1 req/sec MusicBrainz rate limit.
///
/// # Arguments
/// * `conn` - Database connection
/// * `cache` - Artwork cache instance
/// * `client` - HTTP client for API requests
/// * `track_ids` - List of (track_id, artist, album) tuples
///
/// # Returns
/// Statistics about the batch operation
pub async fn batch_fetch_artwork<C, P>(
    conn: &Connection,
    cache: &ArtworkCache,
    client: &reqwest::Client,
    track_ids: &[(i64, String, String)],
    cancelled: C,
    mut on_progress: P,
) -> Result<BatchArtworkResult>
where
    C: Fn() -> bool,
    P: FnMut(usize, i64),
{
    use std::path::Path;

    let mut result = BatchArtworkResult {
        fetched: 0,
        already_cached: 0,
        not_found: 0,
        failed: Vec::new(),
    };

    for (idx, (track_id, artist, album)) in track_ids.iter().enumerate() {
        if cancelled() {
            break;
        }
        on_progress(idx + 1, *track_id);
        // Check if already cached
        if cache.is_cached(*track_id, "500") && cache.is_cached(*track_id, "1200") {
            result.already_cached += 1;
            continue;
        }

        // Try to extract embedded artwork first
        let track_path: Option<String> = conn
            .query_row(
                "SELECT original_path FROM tracks WHERE id = ?",
                [track_id],
                |row| row.get(0),
            )
            .ok();

        if let Some(path_str) = track_path {
            let path = Path::new(&path_str);
            if path.exists() {
                match embed::extract_embedded_artwork(path) {
                    Ok(Some(artwork_data)) => {
                        // Resize to 500px and 1200px
                        match embed::resize_artwork(&artwork_data, 500) {
                            Ok(small) => {
                                let _ = cache.save_to_cache(*track_id, "500", &small);
                            }
                            Err(_) => {}
                        }
                        match embed::resize_artwork(&artwork_data, 1200) {
                            Ok(large) => {
                                let path_500 = cache.get_cached_path(*track_id, "500");
                                let _ = cache.save_to_cache(*track_id, "1200", &large);
                                let _ = cache::save_artwork_state(
                                    conn,
                                    *track_id,
                                    path_500.to_str().unwrap_or(""),
                                    "embedded",
                                    None,
                                    "500x500",
                                );
                                result.fetched += 1;
                                continue;
                            }
                            Err(_) => {}
                        }
                    }
                    _ => {}
                }
            }
        }

        // Fetch from MusicBrainz/CAA (convert anyhow::Error to string for failed Vec)
        match sources::fetch_artwork_for_track(client, artist, album).await {
            Ok(Some((mbid, small_bytes, large_bytes))) => {
                // Save to cache
                match cache.save_to_cache(*track_id, "500", &small_bytes) {
                    Ok(path_500) => {
                        let _ = cache.save_to_cache(*track_id, "1200", &large_bytes);
                        let _ = cache::save_artwork_state(
                            conn,
                            *track_id,
                            path_500.to_str().unwrap_or(""),
                            "musicbrainz",
                            Some(&mbid),
                            "500x500",
                        );
                        result.fetched += 1;
                    }
                    Err(e) => {
                        result.failed.push((*track_id, e.to_string()));
                    }
                }
            }
            Ok(None) => {
                result.not_found += 1;
            }
            Err(e) => {
                result.failed.push((*track_id, e.to_string()));
            }
        }

        // Rate limit: 1 request per second to MusicBrainz
        tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
    }

    Ok(result)
}
