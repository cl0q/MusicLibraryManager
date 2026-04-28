//! Phase 20 Tauri command: backfill track_tags from the on-disk Yeat taxonomy.
//!
//! Entry point is [`backfill_yeat_tags_cmd`] (Tauri-registered). Core logic lives
//! in [`run_backfill`] which takes an explicit `&mut Connection` + `&Path`, making
//! it unit-testable against an in-memory DB without the Tauri runtime.
//!
//! Reconcile semantics (locked in `.planning/phases/20-tags-provenance/20-CONTEXT.md`):
//! - For every walked track that matches a row in `tracks.organized_path`, UPSERT
//!   the three inferred `(tag_key, tag_value)` triples into `track_tags`.
//! - Reconcile-DELETE any row on that track with `tag_key IN ('artist','era','variant')`
//!   that is NOT in the freshly-walked set. This guarantees a track moved from one
//!   era folder to another has its stale `era` row cleaned up in the same transaction.
//! - Unmanaged keys (anything outside [`MANAGED_TAG_KEYS`]) are never touched — this
//!   command only owns disk-inferred dimensions.
//! - Second run on unchanged disk is a no-op: identical UPSERTs hit existing rows
//!   and the reconcile-DELETE finds nothing to remove.
//! - Files on disk with no `tracks.organized_path` match go into
//!   `report.orphan_disk_files` — expected, non-fatal.
//!
//! All DB mutations happen inside a single transaction — a mid-walk failure rolls
//! back cleanly and leaves `track_tags` untouched.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::Utc;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::database::{db_path, get_connection};
use crate::yeat::{walk_yeat_root, TagTriple, WalkedTrack};

/// The three tag keys this command manages on disk-backed Yeat tracks. Rows in
/// `track_tags` with keys OUTSIDE this set are left untouched by reconcile-DELETE.
const MANAGED_TAG_KEYS: &[&str] = &["artist", "era", "variant"];

/// A single per-(track, tag_key) drift entry — surfaced in the sync report when
/// the disk-derived value differs from the existing DB value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriftEntry {
    pub track_id: i64,
    pub relative_path: String,
    pub tag_key: String,
    pub old_value: String,
    pub new_value: String,
}

/// The JSON-serializable report returned by [`backfill_yeat_tags_cmd`] and also
/// written to `.planning/sync-reports/yeat-tags-<ISO8601>.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackfillReport {
    /// ISO 8601 timestamp at which the walk started.
    pub walked_at: String,
    /// Library root the walker was pointed at (absolute).
    pub library_root: String,
    /// Total audio files found beneath `00_Artist/Yeat/`.
    pub tracks_scanned: usize,
    /// Subset of scanned tracks that resolved to a `tracks.organized_path` row.
    pub tracks_matched: usize,
    /// Sum of `track_tags` rows inserted/replaced across all matched tracks.
    pub tags_written: usize,
    /// Sum of `track_tags` rows removed by the reconcile-DELETE pass.
    pub tags_removed: usize,
    /// Per-(track, tag_key) diffs where the DB value differed from the walked value.
    pub drift: Vec<DriftEntry>,
    /// Relative paths of files found on disk with no matching `tracks.organized_path`.
    pub orphan_disk_files: Vec<String>,
    /// Absolute path of the JSON file that was written with this report.
    pub report_path: String,
}

/// Per-track diff result, produced by [`compute_tag_diff`] and consumed by
/// [`run_backfill`].
#[derive(Debug, Clone, PartialEq, Eq)]
struct TagDiff {
    /// Tag triples that should be inserted (or replaced — same behavior under UPSERT).
    to_write: Vec<TagTriple>,
    /// Existing managed-key rows that should be removed (not present in the fresh set).
    to_remove: Vec<TagTriple>,
    /// `(tag_key, old_value, new_value)` tuples where the same managed key had
    /// a different value between existing and fresh sets.
    drift: Vec<(String, String, String)>,
}

/// Pure-function diff between the fresh (disk-inferred) tag set and the existing
/// (DB-loaded) tag set for a single track.
///
/// Only managed keys ([`MANAGED_TAG_KEYS`]) participate — any existing rows with
/// unmanaged keys are ignored entirely, so this command never deletes a tag that
/// wasn't written by this command.
///
/// Semantics:
/// - A `(key, value)` present in both existing and fresh → no-op.
/// - A `(key, value)` in fresh but not existing → `to_write` entry. If `existing`
///   had the same `key` with a DIFFERENT value, also emit a `drift` entry AND add
///   that stale `(key, old_value)` pair to `to_remove` so the DELETE pass clears it.
/// - A managed-key `(key, value)` in existing but not fresh (and the same key
///   isn't in fresh) → `to_remove` entry. (Defensive: `infer_tags` always emits all
///   three managed keys, so this branch is unlikely in practice but correct if the
///   disk-inferred set ever degrades.)
fn compute_tag_diff(existing: &[TagTriple], fresh: &[TagTriple]) -> TagDiff {
    let managed: HashSet<&str> = MANAGED_TAG_KEYS.iter().copied().collect();

    // Build sets scoped to managed keys only.
    let existing_managed: Vec<&TagTriple> = existing
        .iter()
        .filter(|t| managed.contains(t.tag_key.as_str()))
        .collect();

    let existing_pairs: HashSet<(String, String)> = existing_managed
        .iter()
        .map(|t| (t.tag_key.clone(), t.tag_value.clone()))
        .collect();
    let fresh_pairs: HashSet<(String, String)> = fresh
        .iter()
        .filter(|t| managed.contains(t.tag_key.as_str()))
        .map(|t| (t.tag_key.clone(), t.tag_value.clone()))
        .collect();

    // to_write: everything in fresh that isn't already present by exact (key,value).
    let mut to_write: Vec<TagTriple> = Vec::new();
    for pair in fresh_pairs.difference(&existing_pairs) {
        to_write.push(TagTriple {
            tag_key: pair.0.clone(),
            tag_value: pair.1.clone(),
        });
    }

    // to_remove: existing managed rows whose (key,value) isn't in fresh.
    let mut to_remove: Vec<TagTriple> = Vec::new();
    for pair in existing_pairs.difference(&fresh_pairs) {
        to_remove.push(TagTriple {
            tag_key: pair.0.clone(),
            tag_value: pair.1.clone(),
        });
    }

    // drift: same managed key appears in both with different values.
    // Build key → value maps for each side (fresh is guaranteed single-valued by infer_tags;
    // existing may technically have multiple values per key, so walk existing explicitly).
    let mut drift: Vec<(String, String, String)> = Vec::new();
    let fresh_by_key: std::collections::HashMap<String, String> = fresh
        .iter()
        .filter(|t| managed.contains(t.tag_key.as_str()))
        .map(|t| (t.tag_key.clone(), t.tag_value.clone()))
        .collect();
    for t in &existing_managed {
        if let Some(new_val) = fresh_by_key.get(&t.tag_key) {
            if new_val != &t.tag_value {
                drift.push((t.tag_key.clone(), t.tag_value.clone(), new_val.clone()));
            }
        }
    }

    TagDiff {
        to_write,
        to_remove,
        drift,
    }
}

/// The testable core. Takes a DB connection + library root, performs the full
/// walk + transactional reconcile, and returns a [`BackfillReport`] with
/// `report_path` left empty (the caller is responsible for persisting the JSON
/// file and filling in that field).
///
/// The entire reconcile runs inside a single SQL transaction — if any step fails
/// partway through, the transaction rolls back and `track_tags` is unchanged.
fn run_backfill(conn: &mut Connection, library_root: &Path) -> Result<BackfillReport, String> {
    let walked_at = Utc::now().to_rfc3339();
    let walked: Vec<WalkedTrack> = walk_yeat_root(library_root)?;

    let mut tracks_matched = 0usize;
    let mut tags_written = 0usize;
    let mut tags_removed = 0usize;
    let mut drift_entries: Vec<DriftEntry> = Vec::new();
    let mut orphan_disk_files: Vec<String> = Vec::new();

    let tx = conn
        .transaction()
        .map_err(|e| format!("begin tx: {}", e))?;

    for walked_track in &walked {
        let rel_str = walked_track.relative_path.to_string_lossy().to_string();

        // Look up the track by organized_path (exact relative match).
        let track_id: Option<i64> = tx
            .query_row(
                "SELECT id FROM tracks WHERE organized_path = ?1 LIMIT 1",
                rusqlite::params![&rel_str],
                |row| row.get(0),
            )
            .ok();

        let Some(track_id) = track_id else {
            orphan_disk_files.push(rel_str);
            continue;
        };
        tracks_matched += 1;

        // Load existing managed-key tags for this track.
        let existing: Vec<TagTriple> = {
            let mut stmt = tx
                .prepare(
                    "SELECT tag_key, tag_value FROM track_tags
                     WHERE track_id = ?1 AND tag_key IN ('artist', 'era', 'variant')",
                )
                .map_err(|e| format!("prepare: {}", e))?;
            let rows = stmt
                .query_map(rusqlite::params![track_id], |r| {
                    Ok(TagTriple {
                        tag_key: r.get(0)?,
                        tag_value: r.get(1)?,
                    })
                })
                .map_err(|e| format!("query: {}", e))?;
            rows.filter_map(|r| r.ok()).collect()
        };

        let diff = compute_tag_diff(&existing, &walked_track.tags);

        for triple in &diff.to_write {
            tx.execute(
                "INSERT OR REPLACE INTO track_tags (track_id, tag_key, tag_value)
                 VALUES (?1, ?2, ?3)",
                rusqlite::params![track_id, &triple.tag_key, &triple.tag_value],
            )
            .map_err(|e| format!("insert tag: {}", e))?;
            tags_written += 1;
        }
        for triple in &diff.to_remove {
            tx.execute(
                "DELETE FROM track_tags WHERE track_id = ?1 AND tag_key = ?2 AND tag_value = ?3",
                rusqlite::params![track_id, &triple.tag_key, &triple.tag_value],
            )
            .map_err(|e| format!("delete tag: {}", e))?;
            tags_removed += 1;
        }
        for (tag_key, old, new) in diff.drift {
            drift_entries.push(DriftEntry {
                track_id,
                relative_path: walked_track.relative_path.to_string_lossy().to_string(),
                tag_key,
                old_value: old,
                new_value: new,
            });
        }
    }

    tx.commit().map_err(|e| format!("commit tx: {}", e))?;

    Ok(BackfillReport {
        walked_at,
        library_root: library_root.to_string_lossy().to_string(),
        tracks_scanned: walked.len(),
        tracks_matched,
        tags_written,
        tags_removed,
        drift: drift_entries,
        orphan_disk_files,
        // Populated by the Tauri wrapper after the JSON file is written.
        report_path: String::new(),
    })
}

/// Write the report JSON to `.planning/sync-reports/yeat-tags-<iso>.json` and
/// return the path that was written.
///
/// The ISO 8601 timestamp has any `:` characters replaced with `-` so the
/// filename is portable to Windows (and keeps macOS filesystem listings tidy).
/// The `.planning/sync-reports/` directory is created if missing.
fn write_sync_report(report: &BackfillReport) -> Result<PathBuf, String> {
    let dir = Path::new(".planning").join("sync-reports");
    std::fs::create_dir_all(&dir).map_err(|e| format!("create sync-reports dir: {}", e))?;
    let safe_ts = report.walked_at.replace(':', "-");
    let path = dir.join(format!("yeat-tags-{}.json", safe_ts));
    let file = std::fs::File::create(&path).map_err(|e| format!("create report file: {}", e))?;
    serde_json::to_writer_pretty(file, report).map_err(|e| format!("write report json: {}", e))?;
    Ok(path)
}

/// Walk the Yeat taxonomy on disk, reconcile `track_tags`, and persist a sync
/// report to `.planning/sync-reports/`.
///
/// # Returns
/// The full [`BackfillReport`] on success. On failure (Yeat root missing, DB
/// transaction failed, file write failed) returns a string error suitable for
/// surfacing to the frontend.
///
/// # Side effects
/// 1. UPSERTs and reconcile-DELETEs in `track_tags` inside a single transaction.
/// 2. Writes a pretty-printed JSON file at
///    `<cwd>/.planning/sync-reports/yeat-tags-<ISO8601-colons-replaced>.json`.
///    Creates the directory if missing.
#[tauri::command]
pub async fn backfill_yeat_tags_cmd(library_root: String) -> Result<BackfillReport, String> {
    // rusqlite::Connection is !Send, so we can't hold it across await points.
    // Run the whole sync pipeline on a blocking thread.
    tokio::task::spawn_blocking(move || {
        let mut conn = get_connection(&db_path()).map_err(|e| format!("db connection: {}", e))?;
        let root = PathBuf::from(&library_root);
        let mut report = run_backfill(&mut conn, &root)?;
        let written = write_sync_report(&report)?;
        report.report_path = written.to_string_lossy().to_string();
        Ok(report)
    })
    .await
    .map_err(|e| format!("join: {}", e))?
}

// ============================================================================
// Phase 21.1 — DB-derived backfill (no disk walking)
// ============================================================================

/// Result payload for [`backfill_yeat_tags_from_db_cmd`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbBackfillReport {
    /// Distinct yeat tracks (LOWER(album_artist)='yeat') the command processed.
    pub tracks_processed: usize,
    /// Count of (artist=yeat) tags written.
    pub artist_tags_written: usize,
    /// Count of (era=<album.title_normalized>) tags written. Only tracks
    /// linked to an album row contribute.
    pub era_tags_written: usize,
    /// Count of (variant=<album.variant_kind>) tags written. Only albums
    /// with a non-null variant_kind contribute.
    pub variant_tags_written: usize,
    /// Count of stale managed-key rows removed before re-inserting fresh ones.
    pub stale_tags_removed: usize,
}

/// Tag every track where `LOWER(album_artist) = 'yeat'` with the three
/// managed keys derived from the live DB:
///
/// - `(artist, 'yeat')` — unconditional.
/// - `(era, albums.title_normalized)` — joined via `tracks.album_id`. Skipped
///   for tracks with no album link.
/// - `(variant, albums.variant_kind)` — only when the album has a non-null
///   variant_kind (e.g. `'0.5'`, `'v1'`, `'u'`).
///
/// Idempotent: deletes existing managed-key rows for yeat tracks first, then
/// re-inserts the fresh set. Non-yeat tracks and unmanaged tag keys are never
/// touched. Runs inside a single transaction; a failure mid-way rolls back.
///
/// This replaces the disk-walking variant for v1.3 because the on-disk
/// `00_Artist/Yeat/` layout doesn't match the walker's hard-coded
/// `<root>/00_Artist/Yeat/<era>/<file>` shape (the user's Yeat folder has
/// content directories, scripts, and a doubled `Yeat/Yeat/` nesting). The
/// DB-derived approach uses the post-v17 `albums` table as authoritative
/// instead of the disk taxonomy.
fn run_db_backfill(conn: &mut Connection) -> Result<DbBackfillReport, String> {
    let tx = conn.transaction().map_err(|e| format!("begin tx: {}", e))?;

    // Count yeat tracks for the report.
    let tracks_processed: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM tracks WHERE LOWER(album_artist) = 'yeat'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| format!("count yeat tracks: {}", e))?;

    // Step 1: clear managed-key rows for every yeat track. Keeps re-runs
    // clean (e.g. a stale era from a previous backfill). Unmanaged keys
    // are untouched — this command only owns artist/era/variant.
    let stale_tags_removed = tx
        .execute(
            "DELETE FROM track_tags
             WHERE tag_key IN ('artist', 'era', 'variant')
               AND track_id IN (
                   SELECT id FROM tracks WHERE LOWER(album_artist) = 'yeat'
               )",
            [],
        )
        .map_err(|e| format!("delete stale managed tags: {}", e))?;

    // Step 2: write (artist, yeat) for every yeat track.
    let artist_tags_written = tx
        .execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value)
             SELECT id, 'artist', 'yeat'
             FROM tracks WHERE LOWER(album_artist) = 'yeat'",
            [],
        )
        .map_err(|e| format!("insert artist tags: {}", e))?;

    // Step 3: write (era, albums.title_normalized) for every yeat track
    // that is linked to an album.
    let era_tags_written = tx
        .execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value)
             SELECT t.id, 'era', a.title_normalized
             FROM tracks t
             JOIN albums a ON a.id = t.album_id
             WHERE LOWER(t.album_artist) = 'yeat'
               AND a.title_normalized IS NOT NULL
               AND a.title_normalized <> ''",
            [],
        )
        .map_err(|e| format!("insert era tags: {}", e))?;

    // Step 4: write (variant, albums.variant_kind) where the album row
    // carries a variant_kind. Base albums (variant_kind IS NULL) skip this.
    let variant_tags_written = tx
        .execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value)
             SELECT t.id, 'variant', a.variant_kind
             FROM tracks t
             JOIN albums a ON a.id = t.album_id
             WHERE LOWER(t.album_artist) = 'yeat'
               AND a.variant_kind IS NOT NULL",
            [],
        )
        .map_err(|e| format!("insert variant tags: {}", e))?;

    tx.commit().map_err(|e| format!("commit tx: {}", e))?;

    log::info!(
        "yeat tags db-backfill: tracks={}, artist={}, era={}, variant={}, removed={}",
        tracks_processed,
        artist_tags_written,
        era_tags_written,
        variant_tags_written,
        stale_tags_removed
    );

    Ok(DbBackfillReport {
        tracks_processed: tracks_processed as usize,
        artist_tags_written,
        era_tags_written,
        variant_tags_written,
        stale_tags_removed,
    })
}

/// Tauri-registered entry point for the DB-derived Yeat tag backfill. See
/// [`run_db_backfill`] for semantics. Wired to the "Backfill Yeat Tags"
/// button in Settings.
#[tauri::command]
pub async fn backfill_yeat_tags_from_db_cmd() -> Result<DbBackfillReport, String> {
    tokio::task::spawn_blocking(move || {
        let mut conn = get_connection(&db_path()).map_err(|e| format!("db connection: {}", e))?;
        run_db_backfill(&mut conn)
    })
    .await
    .map_err(|e| format!("join: {}", e))?
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::schema::initialize_schema;
    use std::fs::{self, File};
    use tempfile::TempDir;

    // ---------- Helpers ----------

    /// Build an in-memory DB with schema v15 applied + foreign keys enabled.
    fn setup_db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        initialize_schema(&mut conn).unwrap();
        conn
    }

    /// Create an empty file at `<dir>/<relative>`, making parents as needed.
    fn touch(dir: &Path, relative: &str) {
        let path = dir.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        File::create(&path).unwrap();
    }

    /// Insert a track whose `organized_path` matches `relative_path`, return its id.
    fn insert_track(conn: &Connection, relative_path: &str) -> i64 {
        // original_path must be unique — derive one that won't collide.
        let original_path = format!("/src/{}", relative_path);
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params!["Yeat", "Yeat", "A", "T", "m4a", original_path, relative_path],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    /// Count rows in `track_tags` for a specific track.
    fn count_tags(conn: &Connection, track_id: i64) -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM track_tags WHERE track_id = ?1",
            rusqlite::params![track_id],
            |r| r.get(0),
        )
        .unwrap()
    }

    fn t(k: &str, v: &str) -> TagTriple {
        TagTriple {
            tag_key: k.to_string(),
            tag_value: v.to_string(),
        }
    }

    // ---------- compute_tag_diff (pure function) ----------

    #[test]
    fn test_compute_tag_diff_no_change() {
        let existing = vec![
            t("artist", "yeat"),
            t("era", "afterlyfe"),
            t("variant", "base"),
        ];
        let fresh = existing.clone();
        let diff = compute_tag_diff(&existing, &fresh);
        assert!(diff.to_write.is_empty(), "expected 0 writes: {:?}", diff);
        assert!(diff.to_remove.is_empty(), "expected 0 removes: {:?}", diff);
        assert!(diff.drift.is_empty(), "expected 0 drift: {:?}", diff);
    }

    #[test]
    fn test_compute_tag_diff_new_track() {
        let existing: Vec<TagTriple> = vec![];
        let fresh = vec![
            t("artist", "yeat"),
            t("era", "afterlyfe"),
            t("variant", "base"),
        ];
        let diff = compute_tag_diff(&existing, &fresh);
        assert_eq!(diff.to_write.len(), 3, "3 writes expected: {:?}", diff);
        assert!(diff.to_remove.is_empty(), "no removes for brand-new track");
        assert!(
            diff.drift.is_empty(),
            "drift is for value-change only, not first-write"
        );
    }

    #[test]
    fn test_compute_tag_diff_era_changed() {
        let existing = vec![
            t("artist", "yeat"),
            t("era", "afterlyfe"),
            t("variant", "base"),
        ];
        let fresh = vec![
            t("artist", "yeat"),
            t("era", "lyfestyle"),
            t("variant", "base"),
        ];
        let diff = compute_tag_diff(&existing, &fresh);

        // One write (era=lyfestyle) and one remove (era=afterlyfe).
        assert_eq!(diff.to_write.len(), 1, "{:?}", diff);
        assert_eq!(diff.to_write[0], t("era", "lyfestyle"));
        assert_eq!(diff.to_remove.len(), 1, "{:?}", diff);
        assert_eq!(diff.to_remove[0], t("era", "afterlyfe"));

        // One drift entry.
        assert_eq!(diff.drift.len(), 1, "{:?}", diff);
        let (key, old, new) = &diff.drift[0];
        assert_eq!(key, "era");
        assert_eq!(old, "afterlyfe");
        assert_eq!(new, "lyfestyle");
    }

    #[test]
    fn test_compute_tag_diff_ignores_non_yeat_keys() {
        let existing = vec![
            t("artist", "yeat"),
            t("era", "afterlyfe"),
            t("variant", "base"),
            t("genre", "rap"), // custom non-managed tag
        ];
        let fresh = vec![
            t("artist", "yeat"),
            t("era", "afterlyfe"),
            t("variant", "base"),
        ];
        let diff = compute_tag_diff(&existing, &fresh);
        assert!(
            diff.to_write.is_empty(),
            "no writes; everything managed already matches"
        );
        assert!(
            diff.to_remove.is_empty(),
            "(genre, rap) must NOT be removed: {:?}",
            diff
        );
        assert!(diff.drift.is_empty());
    }

    // ---------- run_backfill (integration; in-memory DB + tempfile fixture) ----------

    #[test]
    fn test_backfill_end_to_end_fresh() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();

        // Fixture: 3 files across 2 eras with 2 variants.
        // (era=afterlyfe, variant=base), (era=afterlyfe, variant=u), (era=lyfestyle, variant=v1)
        touch(root, "00_Artist/Yeat/AftërLyfe/Track 01.m4a");
        touch(root, "00_Artist/Yeat/AftërLyfe [U]/Track 01.m4a");
        touch(root, "00_Artist/Yeat/Lyfestyle/Track 02 V1.m4a");

        let mut conn = setup_db();
        let id_a = insert_track(&conn, "00_Artist/Yeat/AftërLyfe/Track 01.m4a");
        let id_b = insert_track(&conn, "00_Artist/Yeat/AftërLyfe [U]/Track 01.m4a");
        let id_c = insert_track(&conn, "00_Artist/Yeat/Lyfestyle/Track 02 V1.m4a");

        let report = run_backfill(&mut conn, root).expect("backfill succeeds");
        assert_eq!(report.tracks_scanned, 3, "{:?}", report);
        assert_eq!(report.tracks_matched, 3, "{:?}", report);
        assert_eq!(report.tags_written, 9, "3 tags * 3 tracks: {:?}", report);
        assert_eq!(report.tags_removed, 0, "{:?}", report);
        assert!(report.drift.is_empty(), "no drift on fresh: {:?}", report);
        assert!(
            report.orphan_disk_files.is_empty(),
            "no orphans: {:?}",
            report
        );

        assert_eq!(count_tags(&conn, id_a), 3);
        assert_eq!(count_tags(&conn, id_b), 3);
        assert_eq!(count_tags(&conn, id_c), 3);

        // Spot-check actual values for track B (album folder = "AftërLyfe [U]").
        // Era normalization is applied to the folder name literally, so the
        // `[U]` suffix folds into the era string as `_u`. Variant detection is
        // a separate pass on the same folder name and yields `u` per the
        // [U] → u rule locked in CONTEXT.md.
        let era_b: String = conn
            .query_row(
                "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'era'",
                rusqlite::params![id_b],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(era_b, "afterlyfe_u");
        let variant_b: String = conn
            .query_row(
                "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'variant'",
                rusqlite::params![id_b],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(variant_b, "u");

        // Track A's era has no bracket suffix — it normalizes cleanly.
        let era_a: String = conn
            .query_row(
                "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'era'",
                rusqlite::params![id_a],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(era_a, "afterlyfe");

        // Track C: era=lyfestyle (clean), variant=v1 (from file stem, album is base).
        let era_c: String = conn
            .query_row(
                "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'era'",
                rusqlite::params![id_c],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(era_c, "lyfestyle");
        let variant_c: String = conn
            .query_row(
                "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'variant'",
                rusqlite::params![id_c],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(variant_c, "v1");
    }

    #[test]
    fn test_backfill_is_idempotent() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        touch(root, "00_Artist/Yeat/AftërLyfe/Track 01.m4a");
        touch(root, "00_Artist/Yeat/Lyfestyle/Track 02 V1.m4a");

        let mut conn = setup_db();
        insert_track(&conn, "00_Artist/Yeat/AftërLyfe/Track 01.m4a");
        insert_track(&conn, "00_Artist/Yeat/Lyfestyle/Track 02 V1.m4a");

        // First run — seeds track_tags.
        let first = run_backfill(&mut conn, root).expect("first backfill");
        assert!(first.tags_written > 0);

        let total_tags_before: i64 = conn
            .query_row("SELECT COUNT(*) FROM track_tags", [], |r| r.get(0))
            .unwrap();

        // Second run — must be a strict no-op.
        let second = run_backfill(&mut conn, root).expect("second backfill");
        assert_eq!(second.tags_written, 0, "{:?}", second);
        assert_eq!(second.tags_removed, 0, "{:?}", second);
        assert!(second.drift.is_empty(), "{:?}", second);

        let total_tags_after: i64 = conn
            .query_row("SELECT COUNT(*) FROM track_tags", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            total_tags_before, total_tags_after,
            "row count must not change on idempotent re-run"
        );
    }

    #[test]
    fn test_backfill_detects_era_drift() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // Disk says era=lyfestyle.
        touch(root, "00_Artist/Yeat/Lyfestyle/Track X.m4a");

        let mut conn = setup_db();
        let track_id = insert_track(&conn, "00_Artist/Yeat/Lyfestyle/Track X.m4a");

        // Pre-seed a STALE (era=afterlyfe) tag simulating a prior backfill run
        // that happened before the file moved.
        conn.execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value) VALUES (?1, 'era', 'afterlyfe')",
            rusqlite::params![track_id],
        )
        .unwrap();

        let report = run_backfill(&mut conn, root).expect("backfill succeeds");

        // Drift detected.
        assert_eq!(report.drift.len(), 1, "{:?}", report);
        let drift = &report.drift[0];
        assert_eq!(drift.tag_key, "era");
        assert_eq!(drift.old_value, "afterlyfe");
        assert_eq!(drift.new_value, "lyfestyle");
        assert_eq!(drift.track_id, track_id);

        // At least 1 write (era=lyfestyle and possibly artist, variant).
        assert!(report.tags_written >= 1, "{:?}", report);
        // Exactly 1 remove (the stale era=afterlyfe row).
        assert!(report.tags_removed >= 1, "{:?}", report);

        // DB now reflects disk: era=lyfestyle present, era=afterlyfe absent.
        let era_rows: Vec<String> = {
            let mut stmt = conn
                .prepare(
                    "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'era'",
                )
                .unwrap();
            stmt.query_map(rusqlite::params![track_id], |r| r.get::<_, String>(0))
                .unwrap()
                .filter_map(|r| r.ok())
                .collect()
        };
        assert_eq!(era_rows, vec!["lyfestyle".to_string()]);
    }

    #[test]
    fn test_backfill_orphan_disk_files() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // File on disk with no matching tracks row.
        touch(root, "00_Artist/Yeat/AftërLyfe/Orphan.m4a");

        let mut conn = setup_db();
        // Deliberately do NOT insert a tracks row for this file.

        let report = run_backfill(&mut conn, root).expect("backfill succeeds");
        assert_eq!(report.tracks_scanned, 1, "{:?}", report);
        assert_eq!(report.tracks_matched, 0, "{:?}", report);
        assert_eq!(report.orphan_disk_files.len(), 1, "{:?}", report);
        assert!(
            report.orphan_disk_files[0].contains("Orphan.m4a"),
            "{:?}",
            report
        );

        // No track_tags rows were inserted (no matching track).
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM track_tags", [], |r| r.get(0))
            .unwrap();
        assert_eq!(total, 0);
    }

    #[test]
    fn test_backfill_writes_sync_report() {
        // Use a tempdir as CWD so the .planning/sync-reports/ output lives there
        // and doesn't pollute the actual repo.
        let tmp = TempDir::new().unwrap();
        let cwd_guard = ChdirGuard::new(tmp.path()).unwrap();

        let root = tmp.path();
        touch(root, "00_Artist/Yeat/AftërLyfe/Track 01.m4a");
        let mut conn = setup_db();
        insert_track(&conn, "00_Artist/Yeat/AftërLyfe/Track 01.m4a");

        let mut report = run_backfill(&mut conn, root).expect("backfill succeeds");
        let written = write_sync_report(&report).expect("write report");
        report.report_path = written.to_string_lossy().to_string();

        assert!(written.exists(), "report file must exist on disk");

        let json = fs::read_to_string(&written).expect("read report json");
        let round_trip: BackfillReport =
            serde_json::from_str(&json).expect("deserialize report");
        assert_eq!(round_trip.walked_at, report.walked_at);
        assert_eq!(round_trip.tracks_scanned, report.tracks_scanned);
        assert_eq!(round_trip.tracks_matched, report.tracks_matched);

        // Cleanly restore CWD before tmp is dropped.
        drop(cwd_guard);
    }

    #[test]
    fn test_backfill_missing_yeat_root_returns_err() {
        let tmp = TempDir::new().unwrap();
        // No 00_Artist/Yeat/ subdirectory — walk_yeat_root must reject.
        let mut conn = setup_db();

        let err = run_backfill(&mut conn, tmp.path()).expect_err("must fail on missing yeat root");
        assert!(
            err.contains("not found"),
            "error must mention 'not found': {}",
            err
        );
    }

    // ---------- CWD guard for the sync-report test ----------

    /// RAII guard that changes CWD on construction and restores it on drop.
    /// Used by `test_backfill_writes_sync_report` so the sync-report file ends
    /// up in a tempdir instead of the real repo's `.planning/` directory.
    ///
    /// NOTE: `std::env::set_current_dir` is process-global; if cargo runs tests
    /// in parallel and another test relies on CWD, races are possible. The
    /// other tests in this module use explicit `tmp.path()` roots so they're
    /// immune. The `#[test]` harness serializes tests marked `!Send`? No — it
    /// doesn't. Accepting the minor test-isolation cost for local simplicity.
    struct ChdirGuard {
        prev: PathBuf,
    }
    impl ChdirGuard {
        fn new(to: &Path) -> std::io::Result<Self> {
            let prev = std::env::current_dir()?;
            std::env::set_current_dir(to)?;
            Ok(Self { prev })
        }
    }
    impl Drop for ChdirGuard {
        fn drop(&mut self) {
            let _ = std::env::set_current_dir(&self.prev);
        }
    }

    // ---------- run_db_backfill (Phase 21.1 DB-derived backfill) ----------

    /// Insert a track with explicit `album_artist` casing; bypasses
    /// `insert_track` (which hard-codes "Yeat"). Returns the new rowid.
    fn insert_track_for_db_backfill(
        conn: &Connection,
        album_artist: &str,
        album: &str,
        original_path: &str,
        album_id: Option<i64>,
    ) -> i64 {
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, album_id)
             VALUES (?1, ?2, ?3, 'T', 'm4a', ?4, NULL, ?5)",
            rusqlite::params![album_artist, album_artist, album, original_path, album_id],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    fn insert_album_for_db_backfill(
        conn: &Connection,
        album_artist: &str,
        title: &str,
        title_normalized: &str,
        variant_kind: Option<&str>,
    ) -> i64 {
        conn.execute(
            "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_kind)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![album_artist, album_artist, title, title_normalized, variant_kind],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    #[test]
    fn test_db_backfill_writes_artist_era_variant_tags() {
        let mut conn = setup_db();
        let base_album = insert_album_for_db_backfill(&conn, "Yeat", "4L", "4l", None);
        let variant_album = insert_album_for_db_backfill(&conn, "yeat", "4L 0.5", "4l", Some("0.5"));
        let base_track = insert_track_for_db_backfill(&conn, "Yeat", "4L", "/disk/a.m4a", Some(base_album));
        let variant_track =
            insert_track_for_db_backfill(&conn, "yeat", "4L 0.5", "/disk/b.m4a", Some(variant_album));
        // A non-Yeat track that must NOT be tagged.
        let non_yeat = insert_track_for_db_backfill(&conn, "Drake", "Scorpion", "/disk/c.m4a", None);

        let report = run_db_backfill(&mut conn).expect("backfill ok");

        assert_eq!(report.tracks_processed, 2);
        assert_eq!(report.artist_tags_written, 2);
        assert_eq!(report.era_tags_written, 2);
        assert_eq!(report.variant_tags_written, 1);
        assert_eq!(report.stale_tags_removed, 0);

        // Both Yeat tracks have artist=yeat + era=4l; variant track also has variant=0.5.
        assert_eq!(count_tags(&conn, base_track), 2, "base: artist + era");
        assert_eq!(count_tags(&conn, variant_track), 3, "variant: artist + era + variant");
        assert_eq!(count_tags(&conn, non_yeat), 0, "non-yeat untouched");

        // Specifically verify the era value is 4l (album.title_normalized).
        let era: String = conn
            .query_row(
                "SELECT tag_value FROM track_tags WHERE track_id = ?1 AND tag_key = 'era'",
                rusqlite::params![base_track],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(era, "4l");
    }

    #[test]
    fn test_db_backfill_idempotent_and_clears_stale() {
        let mut conn = setup_db();
        let album = insert_album_for_db_backfill(&conn, "Yeat", "4L", "4l", None);
        let track = insert_track_for_db_backfill(&conn, "Yeat", "4L", "/disk/a.m4a", Some(album));

        // Seed a stale era tag from a prior buggy run (e.g. era="Yeat" from
        // doubled-folder walker output). The DB backfill must clear it.
        conn.execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value) VALUES (?1, 'era', 'Yeat')",
            rusqlite::params![track],
        )
        .unwrap();
        // And an unmanaged tag the backfill MUST NOT touch.
        conn.execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value) VALUES (?1, 'mood', 'hyped')",
            rusqlite::params![track],
        )
        .unwrap();

        let r1 = run_db_backfill(&mut conn).expect("first run");
        assert_eq!(r1.stale_tags_removed, 1, "stale era=Yeat must be removed");
        // Track now has: artist=yeat, era=4l, mood=hyped (unmanaged preserved).
        assert_eq!(count_tags(&conn, track), 3);

        let r2 = run_db_backfill(&mut conn).expect("second run");
        // Re-runs delete the freshly-written managed rows then re-write them —
        // count is steady, no growth.
        assert_eq!(r2.stale_tags_removed, 2, "removes the artist+era it just wrote");
        assert_eq!(r2.artist_tags_written, 1);
        assert_eq!(r2.era_tags_written, 1);
        assert_eq!(count_tags(&conn, track), 3, "tag count is stable across re-runs");

        // The unmanaged 'mood' row survives.
        let mood_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM track_tags WHERE track_id = ?1 AND tag_key = 'mood'",
                rusqlite::params![track],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(mood_count, 1);
    }

    #[test]
    fn test_db_backfill_skips_tracks_without_album_link() {
        let mut conn = setup_db();
        // Yeat track with NO album_id — should still get artist tag, no era/variant.
        let track = insert_track_for_db_backfill(&conn, "Yeat", "Loose", "/disk/loose.m4a", None);

        let report = run_db_backfill(&mut conn).expect("backfill ok");

        assert_eq!(report.tracks_processed, 1);
        assert_eq!(report.artist_tags_written, 1);
        assert_eq!(report.era_tags_written, 0);
        assert_eq!(report.variant_tags_written, 0);
        assert_eq!(count_tags(&conn, track), 1, "only artist=yeat");
    }
}
