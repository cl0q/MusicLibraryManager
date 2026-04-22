//! Database maintenance commands.
//!
//! Provides commands for rebuilding caches and rescanning metadata:
//! - reindex_search: Clear analysis cache and rebuild search index
//! - rescan_metadata: Re-read tags from all local files, update DB

use std::path::{Path, PathBuf};

use crate::config::LibraryConfig;
use crate::database::connection::get_connection;
use crate::metadata::extractor::extract_metadata;
use tauri::Emitter;

/// Clear analysis cache and rebuild search data.
///
/// Clears the track_analysis table so ffprobe data is re-fetched on next view.
/// Returns count of cleared entries.
#[tauri::command]
pub async fn reindex_search(app: tauri::AppHandle) -> Result<u64, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        // Clear analysis cache
        let cleared: u64 = conn
            .execute("DELETE FROM track_analysis", [])
            .map_err(|e| format!("Failed to clear analysis cache: {}", e))? as u64;

        log::info!("Cleared {} track analysis cache entries", cleared);

        let _ = app.emit("maintenance:reindex_complete", serde_json::json!({
            "cleared": cleared
        }));
        // Emit generic library:updated so UI stats refresh immediately
        let _ = app.emit("library:updated", serde_json::json!({ "source": "reindex" }));

        Ok(cleared)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Rescan metadata from local files and update DB.
///
/// Iterates all tracks with organized_path (local files), re-reads tags,
/// and updates artist, album_artist, album, title, genre, year, bitrate,
/// duration, and format. Preserves playlists, sync profiles, download_status.
///
/// Returns (scanned, updated, errors) counts.
#[tauri::command]
pub async fn rescan_metadata(app: tauri::AppHandle) -> Result<RescanResult, String> {
    log::info!("rescan_metadata command invoked");
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let config = LibraryConfig::load(&conn)
            .map_err(|e| format!("Failed to load library config: {}", e))?;
        let root = config.root_path
            .ok_or_else(|| "Library root not configured".to_string())?;

        // Get all local tracks (have organized_path)
        let mut stmt = conn.prepare(
            "SELECT id, organized_path, original_path FROM tracks WHERE organized_path IS NOT NULL AND organized_path != ''"
        ).map_err(|e| format!("Query error: {}", e))?;

        let tracks: Vec<(i64, String, String)> = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|e| format!("Query error: {}", e))?
            .filter_map(|r| r.ok())
            .collect();

        let total = tracks.len();
        log::info!("Rescan: {} local tracks to process", total);
        let mut scanned = 0u64;
        let mut updated = 0u64;
        let mut errors = 0u64;

        for (track_id, organized_path, original_path) in &tracks {
            scanned += 1;
            if scanned <= 3 {
                log::info!("Rescan track {}: organized={}, original={}", track_id, organized_path, &original_path[..original_path.len().min(80)]);
            }

            // Resolve to absolute path
            let abs_path = resolve_local_path(&root, organized_path, &config.scan_folders, &config.download_destination)
                .or_else(|| {
                    // Fall back to original_path if it's a real file
                    if !original_path.starts_with("http") {
                        let p = PathBuf::from(original_path);
                        if p.exists() { Some(p) } else { None }
                    } else {
                        None
                    }
                });

            let abs_path = match abs_path {
                Some(p) => p,
                None => {
                    errors += 1;
                    continue;
                }
            };

            // Extract metadata from file
            let metadata = match extract_metadata(&abs_path) {
                Ok(m) => m,
                Err(e) => {
                    log::warn!("Failed to extract metadata for track {}: {}", track_id, e);
                    errors += 1;
                    continue;
                }
            };

            // Use lofty's audio stream bitrate (kbps) — accurate codec bitrate
            let bitrate_kbps = metadata.bitrate.map(|b| b as u64);

            // Update DB — preserve organized_path, download_status, date_added
            conn.execute(
                "UPDATE tracks SET artist = ?, album_artist = ?, album = ?, title = ?, \
                 genre = ?, year = ?, bitrate = ?, duration = ?, format = ? WHERE id = ?",
                rusqlite::params![
                    metadata.artist,
                    metadata.album_artist,
                    metadata.album,
                    metadata.title,
                    metadata.genre,
                    metadata.year,
                    bitrate_kbps,
                    metadata.duration,
                    metadata.format,
                    track_id,
                ],
            ).map_err(|e| format!("DB update error: {}", e))?;

            updated += 1;

            // Emit progress every 500 tracks
            if scanned % 500 == 0 {
                log::info!("Rescan progress: {}/{} ({} updated, {} errors)", scanned, total, updated, errors);
                let _ = app.emit("maintenance:rescan_progress", serde_json::json!({
                    "scanned": scanned,
                    "total": total,
                    "updated": updated,
                    "errors": errors,
                }));
            }
        }

        log::info!("Rescan complete: {} scanned, {} updated, {} errors", scanned, updated, errors);

        let _ = app.emit("maintenance:rescan_complete", serde_json::json!({
            "scanned": scanned,
            "updated": updated,
            "errors": errors,
        }));
        // Emit generic library:updated so UI stats refresh immediately
        let _ = app.emit("library:updated", serde_json::json!({ "source": "rescan" }));

        Ok(RescanResult { scanned, updated, errors })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[derive(Debug, serde::Serialize)]
pub struct RescanResult {
    pub scanned: u64,
    pub updated: u64,
    pub errors: u64,
}

/// Resolve organized_path to absolute by trying root + path, then scan folders.
fn resolve_local_path(
    root: &Path,
    organized_path: &str,
    scan_folders: &[String],
    download_destination: &str,
) -> Option<PathBuf> {
    let direct = root.join(organized_path);
    if direct.exists() { return Some(direct); }

    for folder in scan_folders {
        let candidate = root.join(folder).join(organized_path);
        if candidate.exists() { return Some(candidate); }
    }

    let candidate = root.join(download_destination).join(organized_path);
    if candidate.exists() { return Some(candidate); }

    None
}

/// Find tracks whose files can't be found on disk.
/// Returns count and sample of orphaned track IDs.
#[tauri::command]
pub async fn find_orphaned_tracks() -> Result<OrphanResult, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let config = LibraryConfig::load(&conn)
            .map_err(|e| format!("Failed to load library config: {}", e))?;
        let root = config.root_path
            .ok_or_else(|| "Library root not configured".to_string())?;

        let mut stmt = conn.prepare(
            "SELECT id, organized_path, original_path FROM tracks WHERE organized_path IS NOT NULL AND organized_path != ''"
        ).map_err(|e| format!("Query error: {}", e))?;

        let tracks: Vec<(i64, String, String)> = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|e| format!("Query error: {}", e))?
            .filter_map(|r| r.ok())
            .collect();

        let mut orphan_ids = Vec::new();

        for (track_id, organized_path, original_path) in &tracks {
            let found = resolve_local_path(&root, organized_path, &config.scan_folders, &config.download_destination).is_some()
                || (!original_path.starts_with("http")
                    && !original_path.starts_with("spotify:")
                    && PathBuf::from(original_path).exists());

            if !found {
                orphan_ids.push(*track_id);
            }
        }

        log::info!("Found {} orphaned tracks out of {} local tracks", orphan_ids.len(), tracks.len());

        Ok(OrphanResult {
            total_local: tracks.len() as u64,
            orphaned: orphan_ids.len() as u64,
            orphan_ids,
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[derive(Debug, serde::Serialize)]
pub struct OrphanResult {
    pub total_local: u64,
    pub orphaned: u64,
    pub orphan_ids: Vec<i64>,
}

/// Delete orphaned tracks from the database.
/// Only deletes tracks whose files can't be found on disk.
#[tauri::command]
pub async fn purge_orphaned_tracks() -> Result<u64, String> {
    let orphans = find_orphaned_tracks().await?;

    if orphans.orphan_ids.is_empty() {
        return Ok(0);
    }

    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let mut deleted = 0u64;
        for chunk in orphans.orphan_ids.chunks(500) {
            let placeholders: Vec<String> = chunk.iter().map(|_| "?".to_string()).collect();
            let sql = format!("DELETE FROM tracks WHERE id IN ({})", placeholders.join(","));
            let params: Vec<rusqlite::types::Value> = chunk.iter().map(|id| rusqlite::types::Value::Integer(*id)).collect();
            let count = conn.execute(&sql, rusqlite::params_from_iter(params))
                .map_err(|e| format!("Delete error: {}", e))?;
            deleted += count as u64;
        }

        log::info!("Purged {} orphaned tracks", deleted);
        Ok(deleted)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Phase 19: Remove multiple tracks from the library (DB only).
///
/// Deletes rows from `tracks`. Files on disk are untouched. Foreign-key
/// cascades handle `replaygain`, `fingerprints`, `artwork`,
/// `track_analysis`, `playlist_tracks`, `sync_profile_tracks`, etc.
///
/// Returns the number of rows actually deleted (may be less than input
/// if some ids no longer existed).
#[tauri::command]
pub async fn remove_tracks_from_library(track_ids: Vec<i64>) -> Result<u64, String> {
    if track_ids.is_empty() {
        return Ok(0);
    }
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        // Cascades require foreign_keys=ON (cheap, idempotent).
        conn.execute_batch("PRAGMA foreign_keys = ON;")
            .map_err(|e| format!("Failed to enable foreign keys: {}", e))?;

        let mut deleted = 0u64;
        for chunk in track_ids.chunks(500) {
            let placeholders: Vec<String> = chunk.iter().map(|_| "?".to_string()).collect();
            let sql = format!("DELETE FROM tracks WHERE id IN ({})", placeholders.join(","));
            let params: Vec<rusqlite::types::Value> = chunk
                .iter()
                .map(|id| rusqlite::types::Value::Integer(*id))
                .collect();
            let n = conn
                .execute(&sql, rusqlite::params_from_iter(params))
                .map_err(|e| format!("Delete error: {}", e))?;
            deleted += n as u64;
        }
        log::info!("Removed {} tracks from library (DB only)", deleted);
        Ok(deleted)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Phase 19 destructive action: Delete file(s) from disk AND the matching
/// DB row(s). For each track id:
///   1. Resolve the on-disk path (organized_path joined under library_root,
///      falling back to original_path when the track has no organized entry
///      or the file isn't found under the library root).
///   2. Remove the file if present. Missing files are logged as warnings
///      but do not block the DB cleanup.
///   3. Delete the tracks row (cascading rows follow).
///
/// Returns a structured summary so the UI can differentiate.
#[derive(Debug, serde::Serialize)]
pub struct DeleteFromDiskResult {
    pub files_deleted: u64,
    pub files_missing: u64,
    pub rows_deleted: u64,
    pub errors: Vec<String>,
}

#[tauri::command]
pub async fn delete_tracks_from_disk(
    track_ids: Vec<i64>,
) -> Result<DeleteFromDiskResult, String> {
    if track_ids.is_empty() {
        return Ok(DeleteFromDiskResult {
            files_deleted: 0,
            files_missing: 0,
            rows_deleted: 0,
            errors: vec![],
        });
    }
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")
            .map_err(|e| format!("Failed to enable foreign keys: {}", e))?;

        let lib_config = LibraryConfig::load(&conn)
            .map_err(|e| format!("Config error: {}", e))?;
        let library_root = lib_config.root_path.clone();

        let mut files_deleted = 0u64;
        let mut files_missing = 0u64;
        let mut errors = Vec::new();
        let mut ids_to_delete = Vec::with_capacity(track_ids.len());

        for track_id in &track_ids {
            // Look up the track's on-disk location.
            let row: Option<(String, Option<String>)> = conn
                .query_row(
                    "SELECT original_path, organized_path FROM tracks WHERE id = ?",
                    [track_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .ok();
            let Some((original_path, organized_path)) = row else {
                errors.push(format!("track {} not found", track_id));
                continue;
            };

            let resolved = resolve_path_for_delete(
                &original_path,
                organized_path.as_deref().unwrap_or(""),
                library_root.as_deref(),
                &lib_config.scan_folders,
            );
            match std::fs::remove_file(&resolved) {
                Ok(_) => files_deleted += 1,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    files_missing += 1;
                    log::warn!("File missing for track {}: {}", track_id, resolved.display());
                }
                Err(e) => {
                    errors.push(format!(
                        "failed to delete {}: {}",
                        resolved.display(),
                        e
                    ));
                    continue;
                }
            }
            ids_to_delete.push(*track_id);
        }

        // Delete DB rows for tracks whose files were handled (or were
        // already missing — the DB row should still go away).
        let mut rows_deleted = 0u64;
        for chunk in ids_to_delete.chunks(500) {
            let placeholders: Vec<String> = chunk.iter().map(|_| "?".to_string()).collect();
            let sql = format!("DELETE FROM tracks WHERE id IN ({})", placeholders.join(","));
            let params: Vec<rusqlite::types::Value> = chunk
                .iter()
                .map(|id| rusqlite::types::Value::Integer(*id))
                .collect();
            let n = conn
                .execute(&sql, rusqlite::params_from_iter(params))
                .map_err(|e| format!("Delete error: {}", e))?;
            rows_deleted += n as u64;
        }
        log::info!(
            "delete_tracks_from_disk: {} files deleted, {} missing, {} rows gone, {} errors",
            files_deleted,
            files_missing,
            rows_deleted,
            errors.len()
        );
        Ok(DeleteFromDiskResult {
            files_deleted,
            files_missing,
            rows_deleted,
            errors,
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

fn resolve_path_for_delete(
    original_path: &str,
    organized_path: &str,
    library_root: Option<&Path>,
    scan_folders: &[String],
) -> PathBuf {
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
    PathBuf::from(original_path)
}
