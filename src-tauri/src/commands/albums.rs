//! Phase 21 Tauri commands for the albums subsystem.
//!
//! Plan 02 adds `detect_album_siblings_cmd` — runs the sibling-detection pass
//! over the entire `albums` table, writes `variant_of` linkages, and persists
//! a sync report JSON.
//!
//! Plan 03 adds `get_album_detail_cmd` and `set_variant_preference_cmd` —
//! the frontend-facing pair that powers `AlbumDetailPage` and the UFO toggle.

use crate::database::albums::{
    get_album_by_slug, get_album_with_siblings, upsert_variant_preference, AlbumDetail,
};
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

#[cfg(test)]
mod tests {
    // The core detect_album_siblings logic is tested in
    // src/yeat/siblings.rs::tests. The core get_album_with_siblings +
    // upsert_variant_preference are tested in src/database/albums.rs::tests.
    // This module is a thin Tauri wrapper layer — no additional unit tests
    // needed.
}
