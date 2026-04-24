//! Phase 21 Plan 02: sibling detection pass.
//!
//! Reads the v16 `albums` table plus Phase 20's `track_tags`, and for each
//! Yeat-scoped variant album finds its matching base in the same era + stem,
//! writing `albums.variant_of` accordingly. Emits a [`SiblingReport`] with
//! pairs/groups detected and ambiguous cases for user review.
//!
//! Match rule (locked in 21-CONTEXT.md §Sibling Detection):
//! - A candidate "variant album" is any `albums` row with `variant_kind IS NOT NULL`.
//! - A candidate "base album" is any `albums` row with `variant_kind IS NULL`.
//! - Match keys: (album_artist, title_normalized) must be equal AND the
//!   MAJORITY era of the variant's tracks must equal the MAJORITY era of the
//!   base's tracks (via `track_tags` tag_key='era').
//! - Yeat-only: BOTH albums must have ANY track with tag_key='artist' AND
//!   tag_value='yeat'. Non-Yeat albums never participate in matching.
//!
//! Ambiguous cases:
//! - Orphan variant: 0 candidate bases → variant_of stays NULL, logged in
//!   `ambiguous_siblings.orphan_variants`.
//! - Multi-base: >1 candidate bases (unique index on (album_artist,
//!   title_normalized, variant_kind) usually prevents this, but a corrupted
//!   DB could trigger it) → variant_of stays NULL, logged in
//!   `ambiguous_siblings.multi_base_candidates`.
//!
//! Idempotency: the UPDATE is `SET variant_of = ? WHERE id = ? AND
//! (variant_of IS NULL OR variant_of != ?)`. A re-run with identical data
//! mutates zero rows. All writes happen inside a single transaction.
//!
//! Security (T-21.02-01): All SQL queries use `rusqlite::params!` for parameter
//! binding. No `format!`-built SQL with user-controlled values.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use chrono::Utc;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

/// A variant album that had no matching base in the same era + stem.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrphanVariant {
    pub album_id: i64,
    pub album_artist: String,
    pub title: String,
    pub title_normalized: String,
    pub variant_kind: String,
    pub era: Option<String>, // None if the album has no era tag on any track
}

/// A variant album that matched MORE THAN ONE candidate base (indicates data
/// corruption — the unique index on (album_artist, title_normalized,
/// variant_kind IS NULL) should prevent multiple bases for the same stem).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MultiBaseCandidate {
    pub variant_album_id: i64,
    pub variant_title: String,
    pub candidate_base_ids: Vec<i64>,
}

/// The ambiguous-cases bucket inside a [`SiblingReport`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AmbiguousSiblings {
    pub orphan_variants: Vec<OrphanVariant>,
    pub multi_base_candidates: Vec<MultiBaseCandidate>,
}

/// The full report emitted by [`detect_album_siblings`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiblingReport {
    pub walked_at: String,
    pub albums_scanned: usize,
    pub pairs_detected: usize,  // count of 1-base + 1-variant linkages
    pub groups_detected: usize, // count of base rows that ended up with >=2 children
    pub ambiguous_siblings: AmbiguousSiblings,
    pub report_path: String, // populated by the Tauri wrapper after writing JSON
}

/// Row shape fetched by [`load_albums_with_era`]. Internal.
#[derive(Debug, Clone)]
struct AlbumRow {
    id: i64,
    album_artist: String,
    title: String,
    title_normalized: String,
    variant_kind: Option<String>,
    existing_variant_of: Option<i64>,
    era: Option<String>, // MAJORITY era across this album's tracks, None if no era tag
    is_yeat: bool,       // true if ANY track has tag_key='artist' AND tag_value='yeat'
}

/// Load every `albums` row enriched with (majority_era, is_yeat) derived from
/// `track_tags` via the `tracks.album_id` link (populated in Plan 21-01
/// migration).
///
/// Majority era: for each album, count distinct tag_value values where
/// tag_key='era' across its tracks. Pick the most common; ties broken by
/// lexicographic order for determinism.
fn load_albums_with_era(tx: &rusqlite::Transaction) -> Result<Vec<AlbumRow>, String> {
    // Step 1: load all albums.
    let mut stmt = tx
        .prepare(
            "SELECT id, album_artist, title, title_normalized, variant_kind, variant_of
             FROM albums
             ORDER BY id",
        )
        .map_err(|e| format!("prepare albums: {}", e))?;
    let base_rows: Vec<(i64, String, String, String, Option<String>, Option<i64>)> = stmt
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })
        .map_err(|e| format!("query albums: {}", e))?
        .filter_map(|r| r.ok())
        .collect();

    // Step 2: for each album, compute (majority_era, is_yeat) via two aggregate queries.
    let mut results = Vec::with_capacity(base_rows.len());
    for (id, album_artist, title, title_normalized, variant_kind, existing_variant_of) in base_rows
    {
        // Majority era among the album's tracks.
        let era: Option<String> = {
            let mut era_stmt = tx
                .prepare(
                    "SELECT tt.tag_value, COUNT(*) AS cnt
                     FROM track_tags tt
                     JOIN tracks t ON t.id = tt.track_id
                     WHERE t.album_id = ?1 AND tt.tag_key = 'era'
                     GROUP BY tt.tag_value
                     ORDER BY cnt DESC, tt.tag_value ASC
                     LIMIT 1",
                )
                .map_err(|e| format!("prepare era: {}", e))?;
            era_stmt
                .query_row(rusqlite::params![id], |r| r.get::<_, String>(0))
                .ok()
        };

        // Yeat-only gate: does ANY track on this album carry (artist=yeat)?
        let is_yeat: bool = {
            let mut yeat_stmt = tx
                .prepare(
                    "SELECT 1 FROM track_tags tt
                     JOIN tracks t ON t.id = tt.track_id
                     WHERE t.album_id = ?1
                       AND tt.tag_key = 'artist'
                       AND tt.tag_value = 'yeat'
                     LIMIT 1",
                )
                .map_err(|e| format!("prepare yeat: {}", e))?;
            yeat_stmt
                .query_row(rusqlite::params![id], |r| r.get::<_, i64>(0))
                .is_ok()
        };

        results.push(AlbumRow {
            id,
            album_artist,
            title,
            title_normalized,
            variant_kind,
            existing_variant_of,
            era,
            is_yeat,
        });
    }
    Ok(results)
}

/// Core sibling-detection entry point. Takes an owned `&mut Connection` (same
/// pattern as Phase 20's `run_backfill`), performs the full match + UPDATE
/// pass inside a single transaction, and returns the (unwritten-to-disk)
/// [`SiblingReport`]. The Tauri wrapper (in commands/albums.rs) is responsible
/// for persisting the JSON and setting `report.report_path`.
///
/// Transactional semantics (T-21.02-03): the entire match + UPDATE pass runs
/// inside `conn.transaction()`. Any SQL failure rolls back leaving
/// `albums.variant_of` unchanged.
pub fn detect_album_siblings(conn: &mut Connection) -> Result<SiblingReport, String> {
    let walked_at = Utc::now().to_rfc3339();
    let tx = conn
        .transaction()
        .map_err(|e| format!("begin tx: {}", e))?;

    let albums = load_albums_with_era(&tx)?;
    let albums_scanned = albums.len();

    // Partition albums into (yeat_base_map, yeat_variants).
    // base_map key: (album_artist, title_normalized, era) -> Vec<base_id>.
    //   Stored as Vec even though the unique index normally permits only 1 —
    //   we surface multi-base as an ambiguous case rather than silently picking one.
    let mut base_map: HashMap<(String, String, Option<String>), Vec<i64>> = HashMap::new();
    let mut variants: Vec<AlbumRow> = Vec::new();

    for a in &albums {
        if !a.is_yeat {
            continue;
        }
        match &a.variant_kind {
            None => {
                let key = (
                    a.album_artist.clone(),
                    a.title_normalized.clone(),
                    a.era.clone(),
                );
                base_map.entry(key).or_default().push(a.id);
            }
            Some(_) => {
                variants.push(a.clone());
            }
        }
    }

    let mut pairs_detected: usize = 0;
    let mut child_counts: HashMap<i64, usize> = HashMap::new();
    let mut ambiguous = AmbiguousSiblings::default();

    for variant in &variants {
        let key = (
            variant.album_artist.clone(),
            variant.title_normalized.clone(),
            variant.era.clone(),
        );
        match base_map.get(&key).map(|v| v.as_slice()) {
            None | Some([]) => {
                ambiguous.orphan_variants.push(OrphanVariant {
                    album_id: variant.id,
                    album_artist: variant.album_artist.clone(),
                    title: variant.title.clone(),
                    title_normalized: variant.title_normalized.clone(),
                    variant_kind: variant
                        .variant_kind
                        .clone()
                        .unwrap_or_else(|| "<none>".to_string()),
                    era: variant.era.clone(),
                });
            }
            Some(bases) if bases.len() > 1 => {
                ambiguous.multi_base_candidates.push(MultiBaseCandidate {
                    variant_album_id: variant.id,
                    variant_title: variant.title.clone(),
                    candidate_base_ids: bases.to_vec(),
                });
            }
            Some(bases) => {
                // Exactly one candidate base.
                let base_id = bases[0];

                // Idempotent UPDATE: only mutate if different.
                let changed = tx
                    .execute(
                        "UPDATE albums
                         SET variant_of = ?1
                         WHERE id = ?2
                           AND (variant_of IS NULL OR variant_of != ?1)",
                        rusqlite::params![base_id, variant.id],
                    )
                    .map_err(|e| format!("update variant_of: {}", e))?;
                if changed > 0 || variant.existing_variant_of == Some(base_id) {
                    // Count as a detected pair whether or not the UPDATE was a
                    // mutation (an existing-correct row is still a "detected"
                    // pair from the caller's perspective).
                    pairs_detected += 1;
                    *child_counts.entry(base_id).or_insert(0) += 1;
                }
            }
        }
    }

    let groups_detected = child_counts.values().filter(|&&c| c >= 2).count();

    tx.commit().map_err(|e| format!("commit tx: {}", e))?;

    Ok(SiblingReport {
        walked_at,
        albums_scanned,
        pairs_detected,
        groups_detected,
        ambiguous_siblings: ambiguous,
        report_path: String::new(), // filled by Tauri wrapper
    })
}

/// Write the sync report JSON to `.planning/sync-reports/album-siblings-<iso>.json`.
/// Mirrors Phase 20's `write_sync_report` — same directory, same timestamp
/// sanitization (`:` -> `-`).
pub fn write_sibling_report(report: &SiblingReport) -> Result<PathBuf, String> {
    let dir = Path::new(".planning").join("sync-reports");
    std::fs::create_dir_all(&dir).map_err(|e| format!("create sync-reports dir: {}", e))?;
    let safe_ts = report.walked_at.replace(':', "-");
    let path = dir.join(format!("album-siblings-{}.json", safe_ts));
    let file = std::fs::File::create(&path).map_err(|e| format!("create report file: {}", e))?;
    serde_json::to_writer_pretty(file, report).map_err(|e| format!("write report json: {}", e))?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::initialize_schema;
    use rusqlite::Connection;

    /// Insert a minimal `tracks` row + `albums` row (via backfill path). Returns album_id.
    fn seed_album(conn: &mut Connection, album_artist: &str, title: &str, relpath: &str) -> i64 {
        // Insert a track so the v16 backfill UPDATE-JOIN populates tracks.album_id.
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path)
             VALUES (?, ?, ?, 'Track', 'flac', ?, ?)",
            rusqlite::params![album_artist, album_artist, title, relpath, relpath],
        )
        .unwrap();

        // Re-run the backfill pieces by calling initialize_schema (idempotent) —
        // already at v16, so this won't re-run migrate_to_v16. We need to INSERT
        // the albums row + UPDATE tracks.album_id manually for the test.
        use crate::database::albums::{normalize_title_stem, variant_kind_for_title};
        let title_normalized = normalize_title_stem(title);
        let variant_kind = variant_kind_for_title(title);
        conn.execute(
            "INSERT OR IGNORE INTO albums (artist, album_artist, title, title_normalized, variant_kind)
             VALUES (?, ?, ?, ?, ?)",
            rusqlite::params![album_artist, album_artist, title, title_normalized, variant_kind],
        )
        .unwrap();
        let album_id: i64 = conn
            .query_row(
                "SELECT id FROM albums WHERE album_artist = ? AND title = ?",
                rusqlite::params![album_artist, title],
                |r| r.get(0),
            )
            .unwrap();
        conn.execute(
            "UPDATE tracks SET album_id = ? WHERE album_artist = ? AND album = ?",
            rusqlite::params![album_id, album_artist, title],
        )
        .unwrap();
        album_id
    }

    fn tag_track(conn: &Connection, album_id: i64, tag_key: &str, tag_value: &str) {
        let track_id: i64 = conn
            .query_row(
                "SELECT id FROM tracks WHERE album_id = ? LIMIT 1",
                rusqlite::params![album_id],
                |r| r.get(0),
            )
            .unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO track_tags (track_id, tag_key, tag_value) VALUES (?, ?, ?)",
            rusqlite::params![track_id, tag_key, tag_value],
        )
        .unwrap();
    }

    fn new_db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        initialize_schema(&mut conn).unwrap();
        conn
    }

    #[test]
    fn test_detect_pair_base_variant() {
        let mut conn = new_db();
        let base = seed_album(&mut conn, "Yeat", "AftërLyfe", "yeat/afterlyfe/01.flac");
        let variant = seed_album(&mut conn, "Yeat", "AftërLyfe [U]", "yeat/afterlyfe_u/01.flac");
        tag_track(&conn, base, "artist", "yeat");
        tag_track(&conn, base, "era", "afterlyfe");
        tag_track(&conn, variant, "artist", "yeat");
        tag_track(&conn, variant, "era", "afterlyfe");

        let report = detect_album_siblings(&mut conn).expect("detect");
        assert_eq!(report.pairs_detected, 1);
        assert_eq!(report.ambiguous_siblings.orphan_variants.len(), 0);

        let variant_of: Option<i64> = conn
            .query_row(
                "SELECT variant_of FROM albums WHERE id = ?",
                rusqlite::params![variant],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(variant_of, Some(base));

        // Base remains unlinked.
        let base_of: Option<i64> = conn
            .query_row(
                "SELECT variant_of FROM albums WHERE id = ?",
                rusqlite::params![base],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(base_of, None);
    }

    #[test]
    fn test_detect_triple_group() {
        let mut conn = new_db();
        let base = seed_album(&mut conn, "Yeat", "Lyfestyle", "yeat/lyfestyle/01.flac");
        let v1 = seed_album(&mut conn, "Yeat", "Lyfestyle V1", "yeat/lyfestyle_v1/01.flac");
        let v2 = seed_album(&mut conn, "Yeat", "Lyfestyle V2", "yeat/lyfestyle_v2/01.flac");
        for id in [base, v1, v2] {
            tag_track(&conn, id, "artist", "yeat");
            tag_track(&conn, id, "era", "lyfestyle");
        }

        let report = detect_album_siblings(&mut conn).expect("detect");
        assert_eq!(report.pairs_detected, 2, "both variants linked = 2 pairs");
        assert_eq!(report.groups_detected, 1, "base has 2 children = 1 group");

        for v in [v1, v2] {
            let of: Option<i64> = conn
                .query_row(
                    "SELECT variant_of FROM albums WHERE id = ?",
                    rusqlite::params![v],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(of, Some(base), "variant {} must point to base {}", v, base);
        }
    }

    #[test]
    fn test_orphan_variant_no_base() {
        let mut conn = new_db();
        let variant = seed_album(&mut conn, "Yeat", "Unreleased V1", "yeat/unreleased_v1/01.flac");
        tag_track(&conn, variant, "artist", "yeat");
        tag_track(&conn, variant, "era", "lyfestyle");

        let report = detect_album_siblings(&mut conn).expect("detect");
        assert_eq!(report.pairs_detected, 0);
        assert_eq!(report.ambiguous_siblings.orphan_variants.len(), 1);
        assert_eq!(report.ambiguous_siblings.orphan_variants[0].album_id, variant);
        assert_eq!(report.ambiguous_siblings.orphan_variants[0].variant_kind, "v1");

        let of: Option<i64> = conn
            .query_row(
                "SELECT variant_of FROM albums WHERE id = ?",
                rusqlite::params![variant],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(of, None);
    }

    #[test]
    fn test_cross_era_isolation() {
        // Same stem, different era — must NOT link.
        let mut conn = new_db();
        let base = seed_album(&mut conn, "Yeat", "Heat", "yeat/aftra/01.flac");
        let variant = seed_album(&mut conn, "Yeat", "Heat V1", "yeat/lyfea/01.flac");
        tag_track(&conn, base, "artist", "yeat");
        tag_track(&conn, base, "era", "afterlyfe");
        tag_track(&conn, variant, "artist", "yeat");
        tag_track(&conn, variant, "era", "lyfestyle");

        let report = detect_album_siblings(&mut conn).expect("detect");
        assert_eq!(report.pairs_detected, 0);
        assert_eq!(
            report.ambiguous_siblings.orphan_variants.len(),
            1,
            "variant has no same-era base = orphan"
        );
    }

    #[test]
    fn test_non_yeat_album_excluded() {
        let mut conn = new_db();
        let _drake_base = seed_album(&mut conn, "Drake", "For All the Dogs", "drake/fatd/01.flac");
        let _drake_variant = seed_album(
            &mut conn,
            "Drake",
            "For All the Dogs V1",
            "drake/fatd_v1/01.flac",
        );
        // No (artist=yeat) tags.

        let report = detect_album_siblings(&mut conn).expect("detect");
        assert_eq!(report.pairs_detected, 0, "non-Yeat excluded from matching");
        assert_eq!(report.ambiguous_siblings.orphan_variants.len(), 0);
    }

    #[test]
    fn test_idempotent_second_run() {
        let mut conn = new_db();
        let base = seed_album(&mut conn, "Yeat", "AftërLyfe", "yeat/afterlyfe/01.flac");
        let variant = seed_album(&mut conn, "Yeat", "AftërLyfe [U]", "yeat/afterlyfe_u/01.flac");
        tag_track(&conn, base, "artist", "yeat");
        tag_track(&conn, base, "era", "afterlyfe");
        tag_track(&conn, variant, "artist", "yeat");
        tag_track(&conn, variant, "era", "afterlyfe");

        let first = detect_album_siblings(&mut conn).expect("first");
        let second = detect_album_siblings(&mut conn).expect("second");

        assert_eq!(first.pairs_detected, second.pairs_detected);
        assert_eq!(first.groups_detected, second.groups_detected);
        assert_eq!(
            first.ambiguous_siblings.orphan_variants.len(),
            second.ambiguous_siblings.orphan_variants.len()
        );

        let of: Option<i64> = conn
            .query_row(
                "SELECT variant_of FROM albums WHERE id = ?",
                rusqlite::params![variant],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(of, Some(base));
    }

    #[test]
    fn test_report_json_shape() {
        let mut conn = new_db();
        let report = detect_album_siblings(&mut conn).expect("empty run");
        let json = serde_json::to_value(&report).unwrap();
        assert!(json.get("walked_at").is_some());
        assert!(json.get("albums_scanned").is_some());
        assert!(json.get("pairs_detected").is_some());
        assert!(json.get("groups_detected").is_some());
        assert!(json.get("ambiguous_siblings").is_some());
        assert!(json.get("report_path").is_some());
        let amb = json.get("ambiguous_siblings").unwrap();
        assert!(amb.get("orphan_variants").is_some());
        assert!(amb.get("multi_base_candidates").is_some());
    }

    #[test]
    fn test_multi_base_candidates_logged() {
        // Force-create two base rows with the same (album_artist, title_normalized, NULL)
        // by temporarily disabling the unique index — simulates a corrupted DB.
        let mut conn = new_db();
        conn.execute_batch("DROP INDEX IF EXISTS idx_albums_unique_stem;")
            .unwrap();

        conn.execute(
            "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_kind)
             VALUES ('Yeat', 'Yeat', 'AftërLyfe', 'afterlyfe', NULL)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_kind)
             VALUES ('Yeat', 'Yeat', 'AftërLyfe (alt)', 'afterlyfe', NULL)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_kind)
             VALUES ('Yeat', 'Yeat', 'AftërLyfe [U]', 'afterlyfe', 'u')",
            [],
        )
        .unwrap();

        // Need tracks + yeat + era tags for these 3 albums to participate.
        for title in ["AftërLyfe", "AftërLyfe (alt)", "AftërLyfe [U]"] {
            let album_id: i64 = conn
                .query_row(
                    "SELECT id FROM albums WHERE title = ?",
                    rusqlite::params![title],
                    |r| r.get(0),
                )
                .unwrap();
            let relpath = format!("yeat/{}/{}.flac", album_id, album_id);
            conn.execute(
                "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, album_id)
                 VALUES ('Yeat', 'Yeat', ?, 'Track', 'flac', ?, ?, ?)",
                rusqlite::params![title, relpath, relpath, album_id],
            )
            .unwrap();
            tag_track(&conn, album_id, "artist", "yeat");
            tag_track(&conn, album_id, "era", "afterlyfe");
        }

        let report = detect_album_siblings(&mut conn).expect("detect");
        assert_eq!(
            report.ambiguous_siblings.multi_base_candidates.len(),
            1,
            "variant with 2 candidate bases must be logged as ambiguous"
        );
        assert_eq!(
            report.ambiguous_siblings.multi_base_candidates[0]
                .candidate_base_ids
                .len(),
            2
        );
    }
}
