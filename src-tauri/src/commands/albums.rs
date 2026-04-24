//! Phase 21 Tauri commands for the albums subsystem.
//!
//! Plan 02 adds `detect_album_siblings_cmd` — runs the sibling-detection pass
//! over the entire `albums` table, writes `variant_of` linkages, and persists
//! a sync report JSON.
//!
//! Plan 03 will extend this file with `get_album_detail_cmd` and
//! `set_variant_preference_cmd`.

use crate::database::{db_path, get_connection};
use crate::yeat::{detect_album_siblings, write_sibling_report, SiblingReport};

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

#[cfg(test)]
mod tests {
    // The core detect_album_siblings logic is tested in
    // src/yeat/siblings.rs::tests. This module is a thin Tauri wrapper —
    // no additional unit tests needed. Integration smoke for the JSON
    // write path is covered by the write_sibling_report test in Task 1.
}
