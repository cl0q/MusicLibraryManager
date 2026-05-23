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
//!
//! The CPU-heavy loops (fingerprint, replaygain, loudness) run in
//! batches of `batch_control::BATCH_SIZE` tracks with up to
//! `batch_control::worker_count()` blocking workers in flight. Every
//! iteration checks `batch_control::is_cancelled(prefix)` so the stop
//! button from the UI interrupts within one track rather than after all
//! 11k are done.

use crate::commands::batch_control::{
    cancel_flag, is_cancelled, is_turbo_mode, reset_cancel, worker_count, BATCH_SIZE, TURBO_BATCH_SIZE,
};
use crate::database::get_connection;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
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

/// Run `tasks` through a worker pool, respecting the cancel flag for
/// `prefix`. Each task is spawned via `spawn_blocking` so synchronous
/// ffmpeg / fpcalc / rusqlite work doesn't block the tokio runtime.
///
/// Yields control at batch boundaries (every `BATCH_SIZE` items) and
/// between spawns so a stop signal is observed within one track worth
/// of latency rather than after the whole library.
async fn run_parallel_batches<T, F>(prefix: &str, tasks: Vec<T>, work: F)
where
    T: Send + 'static,
    F: Fn(T) + Send + Sync + Clone + 'static,
{
    use futures_util::stream::{FuturesUnordered, StreamExt};

    let turbo_mode = is_turbo_mode();
    let parallelism = worker_count(turbo_mode);
    let batch_size = if turbo_mode { TURBO_BATCH_SIZE } else { BATCH_SIZE };
    
    log::info!("Running {} with {} workers (turbo: {})", prefix, parallelism, turbo_mode);
    
    let mut iter = tasks.into_iter();
    let mut in_flight: FuturesUnordered<tokio::task::JoinHandle<()>> = FuturesUnordered::new();
    let mut dispatched: usize = 0;

    // Prime the pool.
    for _ in 0..parallelism {
        match iter.next() {
            Some(item) if !is_cancelled(prefix) => {
                let w = work.clone();
                in_flight.push(tokio::task::spawn_blocking(move || w(item)));
                dispatched += 1;
            }
            _ => break,
        }
    }

    while let Some(_) = in_flight.next().await {
        if is_cancelled(prefix) {
            // Drain whatever's still running so we don't double-spend on
            // cancelled work, but don't dispatch anything new.
            while let Some(_) = in_flight.next().await {}
            return;
        }
        if let Some(item) = iter.next() {
            let w = work.clone();
            in_flight.push(tokio::task::spawn_blocking(move || w(item)));
            dispatched += 1;

            // Give tokio a tick to process events every batch so the
            // cancel flag gets a chance to be flipped from the UI side.
            if dispatched % batch_size == 0 {
                tokio::task::yield_now().await;
            }
        }
    }
}

/// Batch fingerprint all unfingerprinted tracks in the library.
///
/// Processes tracks in parallel batches. Cancellable via
/// `stop_analysis_cmd("fingerprint")`.
///
/// # Events
/// - "fingerprint:started" with { total }
/// - "fingerprint:progress" with { current, total, track_id, ... }
/// - "fingerprint:completed" with { processed, failed }
/// - "fingerprint:stopped" with { processed, failed } when cancelled
#[tauri::command]
pub async fn fingerprint_library_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    const PREFIX: &str = "fingerprint";
    reset_cancel(PREFIX);

    // Pull the task list (blocking work on rusqlite) up front so the
    // parallel loop below doesn't need a shared Connection.
    let (tracks, track_info) = tokio::task::spawn_blocking(|| -> Result<_, String> {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        let tracks = crate::fingerprint::chromaprint::get_unfingerprinted_tracks(&conn)
            .map_err(|e| format!("Failed to get unfingerprinted tracks: {}", e))?;
        let track_info = build_track_info_map(&conn, &tracks)?;
        Ok((tracks, track_info))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))??;

    let total = tracks.len();
    log::info!("Starting fingerprint scan: {} tracks", total);
    let _ = app.emit("fingerprint:started", serde_json::json!({ "total": total }));

    let processed = Arc::new(AtomicUsize::new(0));
    let counter = Arc::new(AtomicUsize::new(0));
    let failed = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
    let track_info = Arc::new(track_info);

    {
        let processed = processed.clone();
        let counter = counter.clone();
        let failed = failed.clone();
        let track_info = track_info.clone();
        let app = app.clone();

        run_parallel_batches(PREFIX, tracks, move |(track_id, path): (i64, String)| {
            if is_cancelled(PREFIX) {
                return;
            }
            let (artist, title) = track_info
                .get(&track_id)
                .map(|(a, t)| (a.clone(), t.clone()))
                .unwrap_or_default();

            match crate::fingerprint::chromaprint::fingerprint_track(std::path::Path::new(&path)) {
                Ok((fingerprint, duration)) => {
                    let db_path = crate::database::db_path();
                    let conn = match get_connection(&db_path) {
                        Ok(c) => c,
                        Err(e) => {
                            failed.lock().unwrap().push(serde_json::json!({
                                "track_id": track_id,
                                "error": format!("Database error: {}", e),
                            }));
                            counter.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    };
                    match crate::fingerprint::chromaprint::save_fingerprint(
                        &conn, track_id, &fingerprint, duration,
                    ) {
                        Ok(_) => {
                            processed.fetch_add(1, Ordering::Relaxed);
                            let cur = counter.fetch_add(1, Ordering::Relaxed) + 1;
                            log::debug(
                                "Fingerprint [{}/{}] {} — {} → saved (duration: {:.2}s)",
                                cur,
                                total,
                                artist,
                                title,
                                duration
                            );
                            let _ = app.emit(
                                "fingerprint:progress",
                                serde_json::json!({
                                    "current": cur,
                                    "total": total,
                                    "track_id": track_id,
                                    "artist": artist,
                                    "title": title,
                                    "path": path,
                                    "percent": (cur as f64 / total.max(1) as f64 * 100.0) as u32,
                                    "saved_to_db": true,
                                }),
                            );
                        }
                        Err(e) => {
                            log::error!(
                                "Failed to save fingerprint for track {}: {}",
                                track_id,
                                e
                            );
                            failed.lock().unwrap().push(serde_json::json!({
                                "track_id": track_id,
                                "error": format!("Database error: {}", e),
                            }));
                            counter.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                }
                Err(e) => {
                    log::warn!("Failed to fingerprint track {} at {}: {}", track_id, path, e);
                    failed.lock().unwrap().push(serde_json::json!({
                        "track_id": track_id,
                        "error": format!("Fingerprint error: {}", e),
                    }));
                    counter.fetch_add(1, Ordering::Relaxed);
                }
            }
        })
        .await;
    }

    let processed_n = processed.load(Ordering::Relaxed);
    let failures = Arc::try_unwrap(failed)
        .unwrap_or_else(|arc| Mutex::new(arc.lock().unwrap().clone()))
        .into_inner()
        .unwrap_or_default();
    let failed_n = failures.len();
    let cancelled = is_cancelled(PREFIX);

    let event = if cancelled {
        "fingerprint:stopped"
    } else {
        "fingerprint:completed"
    };
    let _ = app.emit(
        event,
        serde_json::json!({
            "processed": processed_n,
            "failed": failed_n,
            "cancelled": cancelled,
        }),
    );
    log::info!(
        "Fingerprint scan {}: {} processed, {} failed",
        if cancelled { "stopped" } else { "complete" },
        processed_n,
        failed_n
    );

    Ok(serde_json::json!({
        "processed": processed_n,
        "failed": failed_n,
        "cancelled": cancelled,
        "failures": failures,
    }))
}

/// Batch fetch artwork for tracks without artwork.
///
/// Not parallelised — MusicBrainz rate-limits us to ~1 req/sec so extra
/// workers don't help. Cancellation is still wired up so the UI stop
/// button works.
///
/// # Events
/// - "artwork:started" with { total }
/// - "artwork:progress" with { current, total, track_id, ... }
/// - "artwork:completed" with { fetched, already_cached, not_found, failed }
/// - "artwork:stopped" with the same shape when cancelled
#[tauri::command]
pub async fn fetch_artwork_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    const PREFIX: &str = "artwork";
    reset_cancel(PREFIX);

    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            let tracks = crate::artwork::cache::get_tracks_without_artwork(&conn)
                .map_err(|e| format!("Failed to get tracks without artwork: {}", e))?;

            let total = tracks.len();
            log::info!("Starting artwork fetch: {} tracks", total);
            let _ = app.emit("artwork:started", serde_json::json!({ "total": total }));

            let cache_dir = PathBuf::from("artwork_cache");
            let cache = crate::artwork::ArtworkCache::new(cache_dir)
                .map_err(|e| format!("Failed to create artwork cache: {}", e))?;

            let client = reqwest::Client::builder()
                .user_agent("MusicLibraryManager/1.0")
                .build()
                .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

            // batch_fetch_artwork handles its own per-track loop + rate
            // limit; it polls `is_cancelled(PREFIX)` between tracks.
            let result = crate::artwork::batch_fetch_artwork(
                &conn,
                &cache,
                &client,
                &tracks,
                || is_cancelled(PREFIX),
                |current, track_id| {
                    let _ = app.emit(
                        "artwork:progress",
                        serde_json::json!({
                            "current": current,
                            "total": total,
                            "track_id": track_id,
                            "percent": (current as f64 / total.max(1) as f64 * 100.0) as u32,
                        }),
                    );
                },
            )
            .await
            .map_err(|e| format!("Batch fetch failed: {}", e))?;

            let cancelled = is_cancelled(PREFIX);
            let event = if cancelled {
                "artwork:stopped"
            } else {
                "artwork:completed"
            };
            let _ = app.emit(
                event,
                serde_json::json!({
                    "fetched": result.fetched,
                    "already_cached": result.already_cached,
                    "not_found": result.not_found,
                    "failed": result.failed.len(),
                    "cancelled": cancelled,
                }),
            );

            log::info!(
                "Artwork fetch {}: {} fetched, {} cached, {} not found, {} failed",
                if cancelled { "stopped" } else { "complete" },
                result.fetched,
                result.already_cached,
                result.not_found,
                result.failed.len()
            );

            Ok(serde_json::json!({
                "fetched": result.fetched,
                "already_cached": result.already_cached,
                "not_found": result.not_found,
                "failed": result.failed.len(),
                "cancelled": cancelled,
                "failures": result.failed.iter().map(|(id, err)| {
                    serde_json::json!({ "track_id": id, "error": err })
                }).collect::<Vec<_>>(),
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Batch analyze ReplayGain + full loudness for unanalyzed tracks.
///
/// Parallel; cancellable via `stop_analysis_cmd("replaygain")`.
#[tauri::command]
pub async fn analyze_replaygain_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    const PREFIX: &str = "replaygain";
    reset_cancel(PREFIX);

    let (tracks, track_info) = tokio::task::spawn_blocking(|| -> Result<_, String> {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
        let tracks = crate::replaygain::analyzer::get_unanalyzed_tracks(&conn)
            .map_err(|e| format!("Failed to get unanalyzed tracks: {}", e))?;
        let track_info = build_track_info_map(&conn, &tracks)?;
        Ok((tracks, track_info))
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))??;

    let total = tracks.len();
    log::info!("Starting ReplayGain analysis: {} tracks", total);
    let _ = app.emit("replaygain:started", serde_json::json!({ "total": total }));

    let analyzed = Arc::new(AtomicUsize::new(0));
    let counter = Arc::new(AtomicUsize::new(0));
    let failed = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
    let track_info = Arc::new(track_info);

    {
        let analyzed = analyzed.clone();
        let counter = counter.clone();
        let failed = failed.clone();
        let track_info = track_info.clone();
        let app = app.clone();

        run_parallel_batches(PREFIX, tracks, move |(track_id, path): (i64, String)| {
            if is_cancelled(PREFIX) {
                return;
            }
            let (artist, title) = track_info
                .get(&track_id)
                .map(|(a, t)| (a.clone(), t.clone()))
                .unwrap_or_default();

            match crate::replaygain::loudness::analyze_track_loudness(std::path::Path::new(&path)) {
                Ok(analysis) => {
                    let db_path = crate::database::db_path();
                    let conn = match get_connection(&db_path) {
                        Ok(c) => c,
                        Err(e) => {
                            failed.lock().unwrap().push(serde_json::json!({
                                "track_id": track_id,
                                "error": format!("Database error: {}", e),
                            }));
                            counter.fetch_add(1, Ordering::Relaxed);
                            return;
                        }
                    };
                    let gain = crate::replaygain::analyzer::GainResult {
                        track_gain: analysis.loudness.track_gain,
                        track_peak: analysis.loudness.track_peak,
                    };
                    let save_rg =
                        crate::replaygain::analyzer::save_track_gain(&conn, track_id, &gain);
                    let save_loud =
                        crate::replaygain::loudness::save_loudness(&conn, track_id, &analysis);

                    match (save_rg, save_loud) {
                        (Ok(_), Ok(_)) => {
                            analyzed.fetch_add(1, Ordering::Relaxed);
                            let cur = counter.fetch_add(1, Ordering::Relaxed) + 1;
                            log::debug(
                                "ReplayGain [{}/{}] {} — {} → LUFS-I {:.1}, saved to DB",
                                cur,
                                total,
                                artist,
                                title,
                                analysis.loudness.lufs_i
                            );
                            let _ = app.emit(
                                "replaygain:progress",
                                serde_json::json!({
                                    "current": cur,
                                    "total": total,
                                    "track_id": track_id,
                                    "artist": artist,
                                    "title": title,
                                    "path": path,
                                    "percent": (cur as f64 / total.max(1) as f64 * 100.0) as u32,
                                    "lufs_i": analysis.loudness.lufs_i,
                                    "lufs_range": analysis.loudness.lufs_range,
                                    "true_peak": analysis.loudness.true_peak_dbfs,
                                    "energy_bucket": analysis.energy_bucket,
                                    "saved_to_db": true,
                                }),
                            );
                        }
                        (Err(e), _) => {
                            log::error!(
                                "Failed to save ReplayGain for track {}: {}",
                                track_id,
                                e
                            );
                            failed.lock().unwrap().push(serde_json::json!({
                                "track_id": track_id,
                                "error": format!("Database error (rg): {}", e),
                            }));
                            counter.fetch_add(1, Ordering::Relaxed);
                        }
                        (_, Err(e)) => {
                            log::error!("Failed to save loudness for track {}: {}", track_id, e);
                            failed.lock().unwrap().push(serde_json::json!({
                                "track_id": track_id,
                                "error": format!("Database error (loudness): {}", e),
                            }));
                            counter.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                }
                Err(e) => {
                    log::warn!("Failed to analyze track {} at {}: {}", track_id, path, e);
                    failed.lock().unwrap().push(serde_json::json!({
                        "track_id": track_id,
                        "error": format!("Analysis error: {}", e),
                    }));
                    counter.fetch_add(1, Ordering::Relaxed);
                }
            }
        })
        .await;
    }

    let analyzed_n = analyzed.load(Ordering::Relaxed);
    let failures = Arc::try_unwrap(failed)
        .unwrap_or_else(|arc| Mutex::new(arc.lock().unwrap().clone()))
        .into_inner()
        .unwrap_or_default();
    let failed_n = failures.len();
    let cancelled = is_cancelled(PREFIX);

    let event = if cancelled {
        "replaygain:stopped"
    } else {
        "replaygain:completed"
    };
    let _ = app.emit(
        event,
        serde_json::json!({
            "analyzed": analyzed_n,
            "failed": failed_n,
            "cancelled": cancelled,
        }),
    );
    log::info!(
        "ReplayGain {}: {} analyzed, {} failed",
        if cancelled { "stopped" } else { "complete" },
        analyzed_n,
        failed_n
    );

    Ok(serde_json::json!({
        "analyzed": analyzed_n,
        "failed": failed_n,
        "cancelled": cancelled,
        "failures": failures,
    }))
}

/// Execute deep scan for fingerprint-based duplicates.
///
/// Cancellation is best-effort — the underlying pairwise comparison is
/// already fast once fingerprints exist, so we only check the flag
/// before the scan starts. Still, we emit a stopped event if the user
/// clicks stop before we get going.
#[tauri::command]
pub async fn deep_scan_cmd(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    const PREFIX: &str = "deepscan";
    reset_cancel(PREFIX);

    tokio::task::spawn_blocking(move || {
        let handle = tokio::runtime::Handle::current();
        handle.block_on(async {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            log::info!("Starting deep scan for fingerprint duplicates");
            let _ = app.emit("deepscan:started", serde_json::json!({}));

            if is_cancelled(PREFIX) {
                let _ = app.emit(
                    "deepscan:stopped",
                    serde_json::json!({
                        "pairs_compared": 0,
                        "duplicates_found": 0,
                        "conflicts_flagged": 0,
                        "cancelled": true,
                    }),
                );
                return Ok(serde_json::json!({
                    "pairs_compared": 0,
                    "duplicates_found": 0,
                    "conflicts_flagged": 0,
                    "cancelled": true,
                }));
            }

            let result = crate::dedup::fingerprint::deep_scan_library(&conn)
                .map_err(|e| format!("Deep scan failed: {}", e))?;

            let cancelled = is_cancelled(PREFIX);
            let event = if cancelled {
                "deepscan:stopped"
            } else {
                "deepscan:completed"
            };
            let _ = app.emit(
                event,
                serde_json::json!({
                    "pairs_compared": result.pairs_compared,
                    "duplicates_found": result.duplicates_found,
                    "conflicts_flagged": result.conflicts_flagged,
                    "cancelled": cancelled,
                }),
            );

            log::info!(
                "Deep scan {}: {} pairs, {} duplicates, {} conflicts",
                if cancelled { "stopped" } else { "complete" },
                result.pairs_compared,
                result.duplicates_found,
                result.conflicts_flagged
            );

            Ok(serde_json::json!({
                "pairs_compared": result.pairs_compared,
                "duplicates_found": result.duplicates_found,
                "conflicts_flagged": result.conflicts_flagged,
                "cancelled": cancelled,
            }))
        })
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

/// Get review queue entries with optional status filter.
#[tauri::command]
pub async fn get_review_queue_cmd(status: Option<String>) -> Result<serde_json::Value, String> {
    tokio::task::spawn_blocking(move || {
        let db_path = crate::database::db_path();
        let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

        let items = crate::dedup::fingerprint::get_review_queue(&conn, status.as_deref())
            .map_err(|e| format!("Failed to get review queue: {}", e))?;

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
#[tauri::command]
pub async fn resolve_review_item_cmd(review_id: i64, action: String) -> Result<(), String> {
    if !["approved", "rejected", "dismissed"].contains(&action.as_str()) {
        return Err(format!(
            "Invalid action '{}'. Must be 'approved', 'rejected', or 'dismissed'",
            action
        ));
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
/// Parallel; cancellable via `stop_analysis_cmd("loudness")`.
#[tauri::command]
pub async fn analyze_loudness_all(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    const PREFIX: &str = "loudness";
    reset_cancel(PREFIX);

    // Prep: pull task list + library config off the tokio async runtime.
    let (tracks, track_info, library_root, scan_folders) =
        tokio::task::spawn_blocking(|| -> Result<_, String> {
            let db_path = crate::database::db_path();
            let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

            let tracks = crate::replaygain::loudness::get_unanalyzed_loudness_tracks(&conn)
                .map_err(|e| format!("Failed to list unanalyzed tracks: {}", e))?;

            let lib_config = crate::config::LibraryConfig::load(&conn)
                .map_err(|e| format!("Config error: {}", e))?;

            let tuple_tracks: Vec<(i64, String)> = tracks
                .iter()
                .map(|(id, orig, _org)| (*id, orig.clone()))
                .collect();
            let track_info = build_track_info_map(&conn, &tuple_tracks)?;

            Ok((
                tracks,
                track_info,
                lib_config.root_path,
                lib_config.scan_folders,
            ))
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))??;

    let total = tracks.len();
    log::info!("Starting loudness analysis: {} tracks", total);
    let _ = app.emit("loudness:started", serde_json::json!({ "total": total }));

    let analyzed = Arc::new(AtomicUsize::new(0));
    let counter = Arc::new(AtomicUsize::new(0));
    let failed = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
    let track_info = Arc::new(track_info);
    let library_root = Arc::new(library_root);
    let scan_folders = Arc::new(scan_folders);

    {
        let analyzed = analyzed.clone();
        let counter = counter.clone();
        let failed = failed.clone();
        let track_info = track_info.clone();
        let library_root = library_root.clone();
        let scan_folders = scan_folders.clone();
        let app = app.clone();

        run_parallel_batches(
            PREFIX,
            tracks,
            move |(track_id, original_path, organized_path): (i64, String, String)| {
                if is_cancelled(PREFIX) {
                    return;
                }
                let (artist, title) = track_info
                    .get(&track_id)
                    .map(|(a, t)| (a.clone(), t.clone()))
                    .unwrap_or_default();

                let resolved: std::path::PathBuf = resolve_source_path(
                    &original_path,
                    &organized_path,
                    library_root.as_ref().as_deref(),
                    scan_folders.as_slice(),
                );

                if !resolved.exists() {
                    failed.lock().unwrap().push(serde_json::json!({
                        "track_id": track_id,
                        "error": format!("File not found: {}", resolved.display()),
                    }));
                    counter.fetch_add(1, Ordering::Relaxed);
                    return;
                }

                match crate::replaygain::loudness::analyze_track_loudness(&resolved) {
                    Ok(analysis) => {
                        let db_path = crate::database::db_path();
                        let conn = match get_connection(&db_path) {
                            Ok(c) => c,
                            Err(e) => {
                                failed.lock().unwrap().push(serde_json::json!({
                                    "track_id": track_id,
                                    "error": format!("Database error: {}", e),
                                }));
                                counter.fetch_add(1, Ordering::Relaxed);
                                return;
                            }
                        };
                        match crate::replaygain::loudness::save_loudness(&conn, track_id, &analysis)
                        {
                            Ok(_) => {
                                analyzed.fetch_add(1, Ordering::Relaxed);
                                let cur = counter.fetch_add(1, Ordering::Relaxed) + 1;
                                log::info!(
                                    "Loudness [{}/{}] {} — {} → LUFS-I {:.1}, LRA {:.1}, peak {:.1} dB, energy {}",
                                    cur,
                                    total,
                                    artist,
                                    title,
                                    analysis.loudness.lufs_i,
                                    analysis.loudness.lufs_range,
                                    analysis.loudness.true_peak_dbfs,
                                    analysis.energy_bucket,
                                );
                                let _ = app.emit(
                                    "loudness:progress",
                                    serde_json::json!({
                                        "current": cur,
                                        "total": total,
                                        "track_id": track_id,
                                        "artist": artist,
                                        "title": title,
                                        "path": resolved.display().to_string(),
                                        "percent": (cur as f64 / total.max(1) as f64 * 100.0) as u32,
                                        "lufs_i": analysis.loudness.lufs_i,
                                        "lufs_range": analysis.loudness.lufs_range,
                                        "true_peak": analysis.loudness.true_peak_dbfs,
                                        "energy_bucket": analysis.energy_bucket,
                                    }),
                                );
                            }
                            Err(e) => {
                                log::error!("save_loudness failed for track {}: {}", track_id, e);
                                failed.lock().unwrap().push(serde_json::json!({
                                    "track_id": track_id,
                                    "error": format!("Database error: {}", e),
                                }));
                                counter.fetch_add(1, Ordering::Relaxed);
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
                        failed.lock().unwrap().push(serde_json::json!({
                            "track_id": track_id,
                            "error": format!("Analysis error: {}", e),
                        }));
                        counter.fetch_add(1, Ordering::Relaxed);
                    }
                }
            },
        )
        .await;
    }

    let analyzed_n = analyzed.load(Ordering::Relaxed);
    let failures = Arc::try_unwrap(failed)
        .unwrap_or_else(|arc| Mutex::new(arc.lock().unwrap().clone()))
        .into_inner()
        .unwrap_or_default();
    let failed_n = failures.len();
    let cancelled = is_cancelled(PREFIX);

    let event = if cancelled {
        "loudness:stopped"
    } else {
        "loudness:completed"
    };
    let _ = app.emit(
        event,
        serde_json::json!({
            "analyzed": analyzed_n,
            "failed": failed_n,
            "cancelled": cancelled,
        }),
    );
    log::info!(
        "Loudness {}: {} analyzed, {} failed",
        if cancelled { "stopped" } else { "complete" },
        analyzed_n,
        failed_n
    );

    let _ = cancel_flag(PREFIX); // keep the registry entry live for next run

    Ok(serde_json::json!({
        "analyzed": analyzed_n,
        "failed": failed_n,
        "cancelled": cancelled,
        "failures": failures,
    }))
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
    #[test]
    fn test_validate_action() {
        assert!(["approved", "rejected", "dismissed"].contains(&"approved"));
        assert!(["approved", "rejected", "dismissed"].contains(&"rejected"));
        assert!(["approved", "rejected", "dismissed"].contains(&"dismissed"));
        assert!(!["approved", "rejected", "dismissed"].contains(&"invalid"));
        assert!(!["approved", "rejected", "dismissed"].contains(&""));
    }
}
