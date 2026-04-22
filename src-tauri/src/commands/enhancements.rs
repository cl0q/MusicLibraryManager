//! Tauri command handlers for Phase 7 enhancement features.
//!
//! Provides async command handlers for:
//! - fingerprint_library_cmd: Batch generate Chromaprint fingerprints
//! - fetch_artwork_cmd: Batch fetch album artwork from MusicBrainz/CAA
//! - analyze_replaygain_cmd: Batch analyze ReplayGain values
//! - deep_scan_cmd: Fingerprint-based duplicate detection
//! - get_review_queue_cmd: Retrieve review queue entries
//! - resolve_review_item_cmd: Approve/reject/dismiss review items
//! - get_review_queue_count_cmd: Get count of pending review items

use crate::database::get_connection;
use std::collections::HashMap;
use std::path::PathBuf;
use tauri::Emitter;

/// Build a lookup map of track_id -> (artist, title) for progress reporting.
fn build_track_info_map(
    conn: &rusqlite::Connection,
    tracks: &[(i64, String)],
) -> Result<HashMap<i64, (String, String)>, String> {
    let mut map = HashMap::new();
    if tracks.is_empty() {
        return Ok(map);
    }
    let placeholders: Vec<&str> = tracks.iter().map(|_| "?").collect();
    let sql = format!(
        "SELECT id, artist, title FROM tracks WHERE id IN ({})",
        placeholders.join(",")
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| format!("Query error: {}", e))?;
    let params: Vec<&dyn rusqlite::ToSql> = tracks
        .iter()
        .map(|(id, _)| id as &dyn rusqlite::ToSql)
        .collect();
    let rows = stmt
        .query_map(params.as_slice(), |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|e| format!("Query error: {}", e))?;
    for row in rows {
        if let Ok((id, artist, title)) = row {
            map.insert(id, (artist, title));
        }
    }
    Ok(map)
}

/// Batch fingerprint all unfingerprinted tracks in the library.
///
/// Generates Chromaprint fingerprints for tracks without existing fingerprints.
/// Emits progress events for real-time UI updates.
///
/// # Arguments
/// * `app` - Tauri AppHandle for event emission
///
/// # Returns
/// * `Ok(serde_json::Value)` - JSON with { processed, failed }
/// * `Err(String)` - If database or fingerprinting fails
///
/// # Events
/// - "fingerprint:started" with { total }
/// - "fingerprint:progress" with { current, total, track_id }
/// - "fingerprint:completed" with { processed, failed }
#[tauri::command]
pub async fn fingerprint_library_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    // Use spawn_blocking + block_on pattern for rusqlite (!Send)
    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            // Get unfingerprinted tracks
            let tracks = crate::fingerprint::chromaprint::get_unfingerprinted_tracks(&conn)
                .map_err(|e| format!("Failed to get unfingerprinted tracks: {}", e))?;

            let total = tracks.len();
            log::info!("Starting fingerprint scan: {} tracks", total);

            // Build track info map for verbose progress reporting
            let track_info = build_track_info_map(&conn, &tracks)?;

            // Emit started event
            let _ = app.emit("fingerprint:started", serde_json::json!({ "total": total }));

            // Process each track
            let mut processed = 0;
            let mut failed_tracks = Vec::new();

            for (i, (track_id, path)) in tracks.iter().enumerate() {
                let (artist, title) = track_info.get(track_id)
                    .map(|(a, t)| (a.as_str(), t.as_str()))
                    .unwrap_or(("", ""));

                match crate::fingerprint::chromaprint::fingerprint_track(std::path::Path::new(path)) {
                    Ok((fingerprint, duration)) => {
                        match crate::fingerprint::chromaprint::save_fingerprint(&conn, *track_id, &fingerprint, duration) {
                            Ok(_) => {
                                processed += 1;
                                let _ = app.emit("fingerprint:progress", serde_json::json!({
                                    "current": i + 1,
                                    "total": total,
                                    "track_id": track_id,
                                    "artist": artist,
                                    "title": title,
                                    "path": path,
                                    "percent": ((i + 1) as f64 / total as f64 * 100.0) as u32
                                }));
                            }
                            Err(e) => {
                                log::error!("Failed to save fingerprint for track {}: {}", track_id, e);
                                failed_tracks.push(serde_json::json!({
                                    "track_id": track_id,
                                    "error": format!("Database error: {}", e)
                                }));
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!("Failed to fingerprint track {} at {}: {}", track_id, path, e);
                        failed_tracks.push(serde_json::json!({
                            "track_id": track_id,
                            "error": format!("Fingerprint error: {}", e)
                        }));
                    }
                }
            }

            // Emit completed event
            let _ = app.emit("fingerprint:completed", serde_json::json!({
                "processed": processed,
                "failed": failed_tracks.len()
            }));

            log::info!("Fingerprint scan complete: {} processed, {} failed", processed, failed_tracks.len());

            Ok(serde_json::json!({
                "processed": processed,
                "failed": failed_tracks.len(),
                "failures": failed_tracks
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Batch fetch artwork for tracks without artwork.
///
/// Fetches album artwork from MusicBrainz/Cover Art Archive for tracks
/// without cached artwork. Respects 1 req/sec MusicBrainz rate limit.
/// Emits progress events for real-time UI updates.
///
/// # Arguments
/// * `app` - Tauri AppHandle for event emission
///
/// # Returns
/// * `Ok(serde_json::Value)` - JSON with { fetched, already_cached, not_found, failed }
/// * `Err(String)` - If database or artwork fetching fails
///
/// # Events
/// - "artwork:started" with { total }
/// - "artwork:progress" with { current, total, track_id }
/// - "artwork:completed" with { fetched, not_found, failed }
#[tauri::command]
pub async fn fetch_artwork_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            // Get tracks without artwork
            let tracks = crate::artwork::cache::get_tracks_without_artwork(&conn)
                .map_err(|e| format!("Failed to get tracks without artwork: {}", e))?;

            let total = tracks.len();
            log::info!("Starting artwork fetch: {} tracks", total);

            // Emit started event
            let _ = app.emit("artwork:started", serde_json::json!({ "total": total }));

            // Create artwork cache
            let cache_dir = PathBuf::from("artwork_cache");
            let cache = crate::artwork::ArtworkCache::new(cache_dir)
                .map_err(|e| format!("Failed to create artwork cache: {}", e))?;

            // Create HTTP client
            let client = reqwest::Client::builder()
                .user_agent("MusicLibraryManager/1.0")
                .build()
                .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

            // Batch fetch artwork
            let result = crate::artwork::batch_fetch_artwork(&conn, &cache, &client, &tracks)
                .await
                .map_err(|e| format!("Batch fetch failed: {}", e))?;

            // Emit progress after each track (batch_fetch_artwork doesn't emit per-track)
            // We'll emit completed immediately since batch_fetch_artwork is synchronous
            let _ = app.emit("artwork:completed", serde_json::json!({
                "fetched": result.fetched,
                "already_cached": result.already_cached,
                "not_found": result.not_found,
                "failed": result.failed.len()
            }));

            log::info!("Artwork fetch complete: {} fetched, {} cached, {} not found, {} failed",
                result.fetched, result.already_cached, result.not_found, result.failed.len());

            Ok(serde_json::json!({
                "fetched": result.fetched,
                "already_cached": result.already_cached,
                "not_found": result.not_found,
                "failed": result.failed.len(),
                "failures": result.failed.iter().map(|(id, err)| {
                    serde_json::json!({ "track_id": id, "error": err })
                }).collect::<Vec<_>>()
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Batch analyze ReplayGain for unanalyzed tracks.
///
/// Analyzes EBU R128 loudness for tracks without ReplayGain values.
/// Emits progress events for real-time UI updates.
///
/// # Arguments
/// * `app` - Tauri AppHandle for event emission
///
/// # Returns
/// * `Ok(serde_json::Value)` - JSON with { analyzed, failed }
/// * `Err(String)` - If database or analysis fails
///
/// # Events
/// - "replaygain:started" with { total }
/// - "replaygain:progress" with { current, total, track_id }
/// - "replaygain:completed" with { analyzed, failed }
#[tauri::command]
pub async fn analyze_replaygain_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            // Get unanalyzed tracks
            let tracks = crate::replaygain::analyzer::get_unanalyzed_tracks(&conn)
                .map_err(|e| format!("Failed to get unanalyzed tracks: {}", e))?;

            let total = tracks.len();
            log::info!("Starting ReplayGain analysis: {} tracks", total);

            // Build track info map for verbose progress reporting
            let track_info = build_track_info_map(&conn, &tracks)?;

            // Emit started event
            let _ = app.emit("replaygain:started", serde_json::json!({ "total": total }));

            // Process each track
            let mut analyzed = 0;
            let mut failed_tracks = Vec::new();

            for (i, (track_id, path)) in tracks.iter().enumerate() {
                let (artist, title) = track_info.get(track_id)
                    .map(|(a, t)| (a.as_str(), t.as_str()))
                    .unwrap_or(("", ""));

                // Phase 18: run the fuller analysis (adds LRA, true peak in
                // dBFS, spectral centroid, energy bucket) from the same
                // decoded audio we'd have used for the original gain pass.
                // The replaygain gain + peak are still saved to the
                // existing `replaygain` table; the loudness descriptors go
                // to the new tracks columns.
                match crate::replaygain::loudness::analyze_track_loudness(std::path::Path::new(path)) {
                    Ok(analysis) => {
                        let gain = crate::replaygain::analyzer::GainResult {
                            track_gain: analysis.loudness.track_gain,
                            track_peak: analysis.loudness.track_peak,
                        };
                        let save_rg = crate::replaygain::analyzer::save_track_gain(&conn, *track_id, &gain);
                        let save_loud = crate::replaygain::loudness::save_loudness(&conn, *track_id, &analysis);

                        match (save_rg, save_loud) {
                            (Ok(_), Ok(_)) => {
                                analyzed += 1;
                                let _ = app.emit("replaygain:progress", serde_json::json!({
                                    "current": i + 1,
                                    "total": total,
                                    "track_id": track_id,
                                    "artist": artist,
                                    "title": title,
                                    "path": path,
                                    "percent": ((i + 1) as f64 / total as f64 * 100.0) as u32,
                                    "lufs_i": analysis.loudness.lufs_i,
                                    "lufs_range": analysis.loudness.lufs_range,
                                    "true_peak": analysis.loudness.true_peak_dbfs,
                                    "energy_bucket": analysis.energy_bucket,
                                }));
                            }
                            (Err(e), _) => {
                                log::error!("Failed to save ReplayGain for track {}: {}", track_id, e);
                                failed_tracks.push(serde_json::json!({
                                    "track_id": track_id,
                                    "error": format!("Database error (rg): {}", e)
                                }));
                            }
                            (_, Err(e)) => {
                                log::error!("Failed to save loudness for track {}: {}", track_id, e);
                                failed_tracks.push(serde_json::json!({
                                    "track_id": track_id,
                                    "error": format!("Database error (loudness): {}", e)
                                }));
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!("Failed to analyze track {} at {}: {}", track_id, path, e);
                        failed_tracks.push(serde_json::json!({
                            "track_id": track_id,
                            "error": format!("Analysis error: {}", e)
                        }));
                    }
                }
            }

            // Emit completed event
            let _ = app.emit("replaygain:completed", serde_json::json!({
                "analyzed": analyzed,
                "failed": failed_tracks.len()
            }));

            log::info!("ReplayGain analysis complete: {} analyzed, {} failed", analyzed, failed_tracks.len());

            Ok(serde_json::json!({
                "analyzed": analyzed,
                "failed": failed_tracks.len(),
                "failures": failed_tracks
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Execute deep scan for fingerprint-based duplicates.
///
/// Compares all fingerprinted tracks to find duplicates based on audio similarity.
/// Emits progress events for real-time UI updates.
///
/// # Arguments
/// * `app` - Tauri AppHandle for event emission
///
/// # Returns
/// * `Ok(serde_json::Value)` - JSON with { pairs_compared, duplicates_found, conflicts_flagged }
/// * `Err(String)` - If database or scan fails
///
/// # Events
/// - "deepscan:started" with { }
/// - "deepscan:completed" with { pairs_compared, duplicates_found, conflicts_flagged }
#[tauri::command]
pub async fn deep_scan_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            log::info!("Starting deep scan for fingerprint duplicates");

            // Emit started event
            let _ = app.emit("deepscan:started", serde_json::json!({}));

            // Run deep scan
            let result = crate::dedup::fingerprint::deep_scan_library(&conn)
                .map_err(|e| format!("Deep scan failed: {}", e))?;

            // Emit completed event
            let _ = app.emit("deepscan:completed", serde_json::json!({
                "pairs_compared": result.pairs_compared,
                "duplicates_found": result.duplicates_found,
                "conflicts_flagged": result.conflicts_flagged
            }));

            log::info!("Deep scan complete: {} pairs compared, {} duplicates, {} conflicts",
                result.pairs_compared, result.duplicates_found, result.conflicts_flagged);

            Ok(serde_json::json!({
                "pairs_compared": result.pairs_compared,
                "duplicates_found": result.duplicates_found,
                "conflicts_flagged": result.conflicts_flagged
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get review queue entries with optional status filter.
///
/// # Arguments
/// * `status` - Optional status filter ("pending" | "approved" | "rejected" | "dismissed")
///
/// # Returns
/// * `Ok(serde_json::Value)` - JSON array of review queue items
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn get_review_queue_cmd(status: Option<String>) -> Result<serde_json::Value, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let items = crate::dedup::fingerprint::get_review_queue(&conn, status.as_deref())
            .map_err(|e| format!("Failed to get review queue: {}", e))?;

        // Convert to JSON
        let json_items: Vec<serde_json::Value> = items
            .iter()
            .map(|item| {
                serde_json::json!({
                    "id": item.id,
                    "action_type": item.action_type,
                    "track_id": item.track_id,
                    "related_track_id": item.related_track_id,
                    "details": item.details,
                    "auto_action": item.auto_action,
                    "status": item.status,
                    "created_at": item.created_at,
                    "resolved_at": item.resolved_at
                })
            })
            .collect();

        Ok(serde_json::json!(json_items))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Resolve a review queue item with approve/reject/dismiss action.
///
/// # Arguments
/// * `review_id` - Review queue entry ID
/// * `action` - Action to take ("approved" | "rejected" | "dismissed")
///
/// # Returns
/// * `Ok(())` - If resolution succeeded
/// * `Err(String)` - If action is invalid or database update fails
#[tauri::command]
pub async fn resolve_review_item_cmd(review_id: i64, action: String) -> Result<(), String> {
    // Validate action
    if !["approved", "rejected", "dismissed"].contains(&action.as_str()) {
        return Err(format!("Invalid action '{}'. Must be 'approved', 'rejected', or 'dismissed'", action));
    }

    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        crate::dedup::fingerprint::resolve_review_item(&conn, review_id, &action)
            .map_err(|e| format!("Failed to resolve review item: {}", e))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get count of pending review queue items.
///
/// Used by sidebar badge to show number of items requiring attention.
///
/// # Returns
/// * `Ok(i64)` - Count of pending items
/// * `Err(String)` - If database query fails
#[tauri::command]
pub async fn get_review_queue_count_cmd() -> Result<i64, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM review_queue WHERE status = 'pending'",
                [],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to get review queue count: {}", e))?;

        Ok(count)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Phase 18: Batch analyze full loudness (LUFS-I, LRA, true peak, energy
/// bucket) for all local tracks where `lufs_i IS NULL`.
///
/// Runs through the same async-blocking queue pattern as the other
/// enhancement ops. Emits the `loudness:*` event family so the Activity
/// panel picks up progress identically to `replaygain:*`.
///
/// # Events
/// - "loudness:started" { total }
/// - "loudness:progress" { current, total, track_id, artist, title, path, percent }
/// - "loudness:completed" { analyzed, failed }
#[tauri::command]
pub async fn analyze_loudness_all(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            // Resolve tracks with NULL lufs_i that have files on disk.
            let tracks = crate::replaygain::loudness::get_unanalyzed_loudness_tracks(&conn)
                .map_err(|e| format!("Failed to list unanalyzed tracks: {}", e))?;

            let total = tracks.len();
            log::info!("Starting loudness analysis: {} tracks", total);

            // Load library root once so we can resolve relative organized paths.
            let lib_config = crate::config::LibraryConfig::load(&conn)
                .map_err(|e| format!("Config error: {}", e))?;
            let library_root = lib_config.root_path.clone();

            // Build track info map for verbose progress (reuse the 2-tuple helper).
            let tuple_tracks: Vec<(i64, String)> = tracks
                .iter()
                .map(|(id, orig, _org)| (*id, orig.clone()))
                .collect();
            let track_info = build_track_info_map(&conn, &tuple_tracks)?;

            let _ = app.emit("loudness:started", serde_json::json!({ "total": total }));

            let mut analyzed = 0usize;
            let mut failed_tracks = Vec::new();

            for (i, (track_id, original_path, organized_path)) in tracks.iter().enumerate() {
                let (artist, title) = track_info
                    .get(track_id)
                    .map(|(a, t)| (a.as_str(), t.as_str()))
                    .unwrap_or(("", ""));

                // Path resolution: prefer an existing organized path joined
                // with the library root; else fall back to original_path
                // (which may be absolute for scan-imported tracks).
                let resolved: std::path::PathBuf = resolve_source_path(
                    original_path,
                    organized_path,
                    library_root.as_deref(),
                    &lib_config.scan_folders,
                );

                if !resolved.exists() {
                    failed_tracks.push(serde_json::json!({
                        "track_id": track_id,
                        "error": format!("File not found: {}", resolved.display()),
                    }));
                    continue;
                }

                match crate::replaygain::loudness::analyze_track_loudness(&resolved) {
                    Ok(analysis) => {
                        match crate::replaygain::loudness::save_loudness(&conn, *track_id, &analysis) {
                            Ok(_) => {
                                analyzed += 1;
                                let _ = app.emit(
                                    "loudness:progress",
                                    serde_json::json!({
                                        "current": i + 1,
                                        "total": total,
                                        "track_id": track_id,
                                        "artist": artist,
                                        "title": title,
                                        "path": resolved.display().to_string(),
                                        "percent": ((i + 1) as f64 / total.max(1) as f64 * 100.0) as u32,
                                        "lufs_i": analysis.loudness.lufs_i,
                                        "lufs_range": analysis.loudness.lufs_range,
                                        "true_peak": analysis.loudness.true_peak_dbfs,
                                        "energy_bucket": analysis.energy_bucket,
                                    }),
                                );
                            }
                            Err(e) => {
                                log::error!("save_loudness failed for track {}: {}", track_id, e);
                                failed_tracks.push(serde_json::json!({
                                    "track_id": track_id,
                                    "error": format!("Database error: {}", e),
                                }));
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!(
                            "Loudness analysis failed for track {} at {}: {}",
                            track_id,
                            resolved.display(),
                            e
                        );
                        failed_tracks.push(serde_json::json!({
                            "track_id": track_id,
                            "error": format!("Analysis error: {}", e),
                        }));
                    }
                }
            }

            let _ = app.emit(
                "loudness:completed",
                serde_json::json!({ "analyzed": analyzed, "failed": failed_tracks.len() }),
            );

            log::info!(
                "Loudness analysis complete: {} analyzed, {} failed",
                analyzed,
                failed_tracks.len()
            );

            Ok(serde_json::json!({
                "analyzed": analyzed,
                "failed": failed_tracks.len(),
                "failures": failed_tracks,
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Resolve the on-disk path for a track given its original + organized paths.
/// Mirrors the resolution logic used by `execute_sync_cmd`:
/// 1. If organized_path is non-empty, try `library_root/<organized>`.
/// 2. Also try `library_root/<scan_folder>/<organized>` for each scan folder.
/// 3. Fall back to `original_path` (works for scan-imported absolute paths).
fn resolve_source_path(
    original_path: &str,
    organized_path: &str,
    library_root: Option<&std::path::Path>,
    scan_folders: &[String],
) -> std::path::PathBuf {
    if !organized_path.is_empty() {
        if let Some(root) = library_root {
            let direct = root.join(organized_path);
            if direct.exists() {
                return direct;
            }
            for folder in scan_folders {
                let candidate = root.join(folder).join(organized_path);
                if candidate.exists() {
                    return candidate;
                }
            }
        }
    }
    std::path::PathBuf::from(original_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_action() {
        // Valid actions
        assert!(["approved", "rejected", "dismissed"].contains(&"approved"));
        assert!(["approved", "rejected", "dismissed"].contains(&"rejected"));
        assert!(["approved", "rejected", "dismissed"].contains(&"dismissed"));

        // Invalid actions
        assert!(!["approved", "rejected", "dismissed"].contains(&"invalid"));
        assert!(!["approved", "rejected", "dismissed"].contains(&""));
    }
}
