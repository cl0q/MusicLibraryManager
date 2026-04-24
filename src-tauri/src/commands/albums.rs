//! Phase 21 Tauri commands for the albums subsystem.
//!
//! Plan 02 adds `detect_album_siblings_cmd` — runs the sibling-detection pass
//! over the entire `albums` table, writes `variant_of` linkages, and persists
//! a sync report JSON.
//!
//! Plan 03 adds `get_album_detail_cmd` and `set_variant_preference_cmd` —
//! the frontend-facing pair that powers `AlbumDetailPage` and the UFO toggle.

use crate::database::albums::{
    backfill_albums_from_tracks, get_album_by_slug, get_album_with_siblings,
    upsert_variant_preference, AlbumDetail,
};
use crate::database::connection::with_transaction;
use crate::database::{db_path, get_connection};
use crate::yeat::{detect_album_siblings, write_sibling_report, SiblingReport};

/// Default user_id constant. Aligns with the app-wide hardcoded "default"
/// per 21-CONTEXT.md §UFO Toggle UX + Persistence — known tech debt until
/// user management lands in v1.4+.
const DEFAULT_USER_ID: &str = "default";

/// Run the Phase 21 sibling-detection pass.
///
/// # Returns
/// The [`SiblingReport`] on success with `report_path` populated. On failure
/// (DB open error, transaction failure, report-file write failure) returns a
/// string error suitable for surfacing to the frontend.
///
/// # Side effects
/// 1. UPDATEs `albums.variant_of` for every Yeat-scoped variant album that has
///    a unique matching base in the same era + stem (idempotent — second run
///    mutates zero rows).
/// 2. Writes a pretty-printed JSON file at
///    `<cwd>/.planning/sync-reports/album-siblings-<ISO8601-colons-replaced>.json`.
///    Creates the directory if missing.
///
/// # Security (T-21.02-02)
/// Takes NO user input (zero-argument Tauri command). Not an injection surface.
#[tauri::command]
pub async fn detect_album_siblings_cmd() -> Result<SiblingReport, String> {
    // rusqlite::Connection is !Send — hold on a blocking thread.
    tokio::task::spawn_blocking(move || {
        let db = db_path();
        let mut conn = get_connection(&db).map_err(|e| format!("open db: {}", e))?;
        let mut report = detect_album_siblings(&mut conn)?;
        let report_path = write_sibling_report(&report)?;
        report.report_path = report_path.to_string_lossy().to_string();
        Ok(report)
    })
    .await
    .map_err(|e| format!("join: {}", e))?
}

/// Fetch the full detail payload for an album identified by its slug.
///
/// Slug format: `"{deunicode(album_artist)} {deunicode(title)}"` lowercased
/// with non-alphanumeric chars collapsed to `-`. Frontend produces this via
/// `ui/src/utils/slug.ts::computeSlug` (Plan 21-04); backend resolves via
/// `database::albums::get_album_by_slug`.
///
/// If the slug resolves to a variant album, the response auto-redirects to
/// the base album (so `detail.album.id = base.id` and `detail.siblings`
/// contains the variants). This mirrors the UI expectation that the detail
/// page always shows "an album and its family."
///
/// # Errors
/// - `"album not found: {slug}"` — no album matches the slug.
/// - `"open db: ..."`, `"query: ..."` — DB-level failures.
///
/// # Security (T-21.03-03)
/// The slug is an arbitrary user-controlled string but it NEVER touches
/// std::fs or std::path — it is compared in-memory against computed slugs
/// from album rows. No path traversal vector even if the slug contains
/// `../` or shell metacharacters.
#[tauri::command]
pub async fn get_album_detail_cmd(album_slug: String) -> Result<AlbumDetail, String> {
    tokio::task::spawn_blocking(move || {
        let db = db_path();
        let conn = get_connection(&db).map_err(|e| format!("open db: {}", e))?;

        let matched = get_album_by_slug(&conn, &album_slug)
            .map_err(|e| format!("query slug: {}", e))?
            .ok_or_else(|| format!("album not found: {}", album_slug))?;

        let detail = get_album_with_siblings(&conn, matched.id, DEFAULT_USER_ID)
            .map_err(|e| format!("query detail: {}", e))?
            .ok_or_else(|| format!("album not found (id {}): {}", matched.id, album_slug))?;

        Ok(detail)
    })
    .await
    .map_err(|e| format!("join: {}", e))?
}

/// Persist the user's UFO toggle selection.
///
/// UPSERTs into `user_album_variant_pref` with user_id='default'. Validates
/// (in the database layer) that `selected_album_id` is either equal to
/// `base_album_id` OR is a row where `variant_of = base_album_id`. Any other
/// value returns an error — prevents a malicious client from writing
/// arbitrary foreign album ids.
///
/// # Errors
/// - `"upsert pref: ..."` — validation failure or DB error surfaced verbatim.
///
/// # Security (T-21.03-04)
/// Two i64 inputs. DB-layer validation catches unrelated album ids; see
/// `database::albums::upsert_variant_preference`. No data corruption
/// possible even on a malicious renderer process.
#[tauri::command]
pub async fn set_variant_preference_cmd(
    base_album_id: i64,
    selected_album_id: i64,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let db = db_path();
        let conn = get_connection(&db).map_err(|e| format!("open db: {}", e))?;
        upsert_variant_preference(&conn, DEFAULT_USER_ID, base_album_id, selected_album_id)
            .map_err(|e| format!("upsert pref: {}", e))?;
        Ok(())
    })
    .await
    .map_err(|e| format!("join: {}", e))?
}

/// Phase 21.1 — result payload for `rescan_albums_cmd`.
///
/// Reports back to the frontend:
/// - `backfilled_albums`: count of albums rows inserted by
///   `backfill_albums_from_tracks` (usually 0 on subsequent rescans since the
///   backfill uses `INSERT OR IGNORE`).
/// - `sibling_pairs_detected`: count of 1-base + 1-variant linkages seen by
///   `detect_album_siblings` (includes both newly-linked and already-correct
///   rows — same as the Tauri `detect_album_siblings_cmd`).
/// - `ambiguous_count`: count of orphan variants + multi-base candidates
///   surfaced during detection. >0 indicates data the user may want to
///   review via the sync report JSON.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RescanAlbumsResult {
    pub backfilled_albums: usize,
    pub sibling_pairs_detected: usize,
    pub ambiguous_count: usize,
}

/// Phase 21.1 — Re-run the album backfill + sibling detection on the live
/// library. Exposed to the UI so the user can manually refresh album data
/// after importing new tracks or noticing drift (e.g. missing UFO toggle).
///
/// Idempotent; non-destructive to `user_album_variant_pref`. Runs the
/// backfill inside its own transaction (so if it fails, no partial writes);
/// sibling detection runs afterwards (the fn takes `&mut Connection` and
/// opens its own transaction).
///
/// # Security (T-21.1-04)
/// Zero-argument Tauri command. Not an injection surface. Authorization: any
/// user of the app can invoke — same level as other maintenance commands.
#[tauri::command]
pub async fn rescan_albums_cmd() -> Result<RescanAlbumsResult, String> {
    tokio::task::spawn_blocking(move || {
        let db = db_path();
        let mut conn = get_connection(&db).map_err(|e| format!("open db: {}", e))?;

        // Step 1: idempotent backfill inside its own transaction.
        let backfilled = with_transaction(&mut conn, |tx| backfill_albums_from_tracks(tx))
            .map_err(|e| format!("backfill: {}", e))?;

        // Step 2: sibling detection (opens its own tx internally).
        let report = detect_album_siblings(&mut conn)
            .map_err(|e| format!("detect siblings: {}", e))?;

        // Step 3: best-effort report persistence. Failure here doesn't fail
        // the command — the DB mutations are already committed.
        match write_sibling_report(&report) {
            Ok(path) => log::info!("rescan_albums: wrote report to {}", path.display()),
            Err(e) => log::warn!("rescan_albums: report write failed (mutations already committed): {}", e),
        }

        let ambiguous_count = report.ambiguous_siblings.orphan_variants.len()
            + report.ambiguous_siblings.multi_base_candidates.len();

        Ok(RescanAlbumsResult {
            backfilled_albums: backfilled,
            sibling_pairs_detected: report.pairs_detected,
            ambiguous_count,
        })
    })
    .await
    .map_err(|e| format!("join: {}", e))?
}

#[cfg(test)]
mod tests {
    // The core detect_album_siblings logic is tested in
    // src/yeat/siblings.rs::tests. The core get_album_with_siblings +
    // upsert_variant_preference are tested in src/database/albums.rs::tests.
    // rescan_albums_cmd is a thin wrapper over backfill_albums_from_tracks +
    // detect_album_siblings, both exercised by their own test modules.
    // This module is a thin Tauri wrapper layer — no additional unit tests
    // needed.
}
