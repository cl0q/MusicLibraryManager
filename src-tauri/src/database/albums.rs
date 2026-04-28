//! Albums module — Phase 21 v16 schema. Provides:
//! - `Album` struct (mirrors the `albums` table row shape)
//! - `backfill_albums_from_tracks` — one-shot migration helper called from
//!   schema.rs `migrate_to_v16`. Aggregates DISTINCT (album_artist, album)
//!   from the tracks table and inserts one albums row per pair, parsing the
//!   variant suffix from the album title via `yeat::tags::detect_variant`.
//!
//! Plan 21-03 extends this module with query functions (`get_album_by_slug`,
//! `get_album_detail`) consumed by the Tauri command layer.

use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, Transaction};

use crate::database::connection::Result;
use crate::models::track::{Track, TrackMetadata};
use crate::yeat::tags::{detect_variant, normalize_era};

/// Album row — mirrors v16 `albums` table.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Album {
    pub id: i64,
    pub artist: String,
    pub album_artist: String,
    pub title: String,
    pub title_normalized: String,
    pub year: Option<i64>,
    pub cover_path: Option<String>,
    pub variant_of: Option<i64>,
    pub variant_kind: Option<String>,
}

/// Normalize an album title to its stem form — identical rules to
/// `normalize_era`, but additionally strips trailing variant tokens
/// (`[U]`, `0.5`, `V1`, `V2`, `V4`) so stems collapse across sibling albums.
///
/// Order of operations (matches Phase 20's `normalize_era` stack):
/// 1. `deunicode` (ë → e, é → e, etc.) — MUST happen first so token-splitting
///    on `is_ascii_alphanumeric` treats the text as pure ASCII.
/// 2. Lowercase.
/// 3. Strip locked variant tokens: `[u]`, `0.5`, word-bounded `v1`/`v2`/`v4`.
/// 4. Hand the stripped text off to `normalize_era` which folds runs of
///    non-alphanumeric into single underscores and trims edges.
///
/// Examples:
/// - `"AftërLyfe"` -> `"afterlyfe"`
/// - `"AftërLyfe [U]"` -> `"afterlyfe"` (same stem as base)
/// - `"Lyfestyle V1"` -> `"lyfestyle"`
pub fn normalize_title_stem(title: &str) -> String {
    // Step 1: deunicode + lowercase — matches the Phase 20 stack so stems
    // line up byte-for-byte with normalize_era output from that phase.
    let lower = deunicode::deunicode(title).to_lowercase();

    // Step 2: strip variant tokens. After deunicode every char is ASCII so
    // is_ascii_alphanumeric splits cleanly.
    let stripped = lower
        .replace("[u]", " ")
        .replace("0.5", " ")
        // Word-bounded V1/V2/V4 strip (matches detect_variant token logic).
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|tok| *tok != "v1" && *tok != "v2" && *tok != "v4")
        .collect::<Vec<&str>>()
        .join(" ");

    normalize_era(&stripped)
}

/// Map `detect_variant` output to `variant_kind` column value.
/// Returns None for "base", Some(kind) otherwise.
pub fn variant_kind_for_title(title: &str) -> Option<String> {
    match detect_variant(title).as_str() {
        "base" => None,
        kind => Some(kind.to_string()),
    }
}

/// Backfill the `albums` table from the existing `tracks` table.
///
/// Called once from `migrate_to_v16` inside the migration transaction.
/// After this runs, `tracks.album_id` is populated by a subsequent UPDATE
/// (see migrate_to_v16). This function:
/// 1. Selects DISTINCT (album_artist, album, MIN(artist), MIN(year))
///    from tracks (aggregating artist/year by min to get a stable value).
/// 2. For each pair, computes title_normalized + variant_kind.
/// 3. INSERT OR IGNORE into albums (on-conflict is silent because the
///    UNIQUE constraint may de-dupe legitimate repeats — caller's goal is
///    "ensure row exists", not strict-insert).
/// 4. Does NOT populate `variant_of` — that's Plan 02 (sibling detection).
///
/// Security (T-21-01): All INSERTs use rusqlite params — NEVER string
/// interpolation. Album titles and album_artist are user-controlled.
pub fn backfill_albums_from_tracks(tx: &Transaction) -> Result<usize> {
    // Phase 21.1: case-insensitive on album_artist so `Yeat` and `yeat` collapse
    // into a single albums row. `MIN(album_artist)` picks a deterministic
    // representative display value across casing variants. The `albums`
    // case-insensitive UNIQUE index (v17) is the second line of defense if
    // future drift somehow produces a casing-split pair here.
    let mut stmt = tx.prepare(
        "SELECT MIN(album_artist) AS album_artist, album, MIN(artist) AS artist, MIN(year) AS year
         FROM tracks
         WHERE album_artist IS NOT NULL AND album IS NOT NULL
           AND album_artist != '' AND album != ''
         GROUP BY LOWER(album_artist), album",
    )?;

    let rows: Vec<(String, String, String, Option<i64>)> = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                r.get::<_, Option<i64>>(3)?,
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();

    let mut inserted = 0usize;
    for (album_artist, title, artist, year) in rows {
        let title_normalized = normalize_title_stem(&title);
        let variant_kind = variant_kind_for_title(&title);

        let n = tx.execute(
            "INSERT OR IGNORE INTO albums
             (artist, album_artist, title, title_normalized, year, variant_kind)
             VALUES (?, ?, ?, ?, ?, ?)",
            params![artist, album_artist, title, title_normalized, year, variant_kind],
        )?;
        inserted += n;
    }

    Ok(inserted)
}

// ============================================================================
// Phase 21.1 — One-shot data remediation for v16 backfill drift.
// ============================================================================

/// One-time remediation for Phase 21.1. Called from `migrate_to_v17`.
///
/// Fixes two classes of stale data written by the v16 backfill running on a
/// pre-fix version of `normalize_title_stem`:
///
/// 1. `title_normalized` values that reflect pre-deunicode stripping (e.g.
///    `AftërLyfe` stored as `aft_rlyfe` instead of `afterlyfe`). We recompute
///    every row using the current `normalize_title_stem` + `variant_kind_for_title`.
/// 2. Duplicate album rows caused by case-variant `album_artist` (`Yeat` vs `yeat`).
///    We merge duplicate groups keyed by `(LOWER(album_artist), title_normalized,
///    IFNULL(variant_kind, ''))`, keeping the row with MIN(id). Any references
///    on `tracks.album_id` or `albums.variant_of` pointing at a non-kept row
///    are re-pointed to the kept id, and the duplicates are deleted.
///
/// Safe to call inside the `migrate_to_v17` transaction. Returns
/// `(renormalized, merged_groups, rows_deleted)` for logging.
///
/// Security (T-21.1-01): all UPDATEs + DELETEs use `rusqlite::params!` bound
/// parameters. No `format!`-built SQL with user-controlled values.
pub fn remediate_albums_data(tx: &Transaction) -> Result<(usize, usize, usize)> {
    // Step 0: drop the v16 case-sensitive UNIQUE index. It would otherwise
    // reject mid-loop UPDATEs in Step A — e.g. row `Yeat | AftërLyfe |
    // aft_rlyfe` renormalized to `afterlyfe` collides with a sibling row
    // already at `Yeat | * | afterlyfe`. The new CI index created at the
    // end of `migrate_to_v17` is strictly stronger (every CS-duplicate is
    // also a CI-duplicate after normalization), so the CS index is
    // redundant once remediation completes. DDL inside this transaction
    // rolls back with the rest if any later step fails.
    tx.execute_batch("DROP INDEX IF EXISTS idx_albums_unique_stem;")?;

    // Step A: recompute title_normalized and variant_kind for every row.
    // Read all rows first (borrow-safe), then UPDATE each by id.
    let rows: Vec<(i64, String)> = {
        let mut stmt = tx.prepare("SELECT id, title FROM albums")?;
        let mapped: Vec<(i64, String)> = stmt
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
            .filter_map(|r| r.ok())
            .collect();
        mapped
    };
    let mut renormalized = 0usize;
    for (id, title) in &rows {
        let new_norm = normalize_title_stem(title);
        let new_kind = variant_kind_for_title(title);
        let n = tx.execute(
            "UPDATE albums SET title_normalized = ?, variant_kind = ? WHERE id = ?",
            params![new_norm, new_kind, id],
        )?;
        renormalized += n;
    }

    // Step B: identify duplicate groups keyed by case-insensitive album_artist +
    // title_normalized + variant_kind (NULL treated as ''). Keep MIN(id), drop
    // the rest.
    let dupes: Vec<(i64, Vec<i64>)> = {
        let mut stmt = tx.prepare(
            "SELECT MIN(id) AS keep_id, GROUP_CONCAT(id) AS all_ids
             FROM albums
             GROUP BY LOWER(album_artist), title_normalized, IFNULL(variant_kind, '')
             HAVING COUNT(*) > 1",
        )?;
        let mapped: Vec<(i64, Vec<i64>)> = stmt
            .query_map([], |r| {
                let keep: i64 = r.get(0)?;
                let all: String = r.get(1)?;
                let all_ids: Vec<i64> = all
                    .split(',')
                    .filter_map(|s| s.trim().parse::<i64>().ok())
                    .collect();
                let drop_ids: Vec<i64> = all_ids.into_iter().filter(|id| *id != keep).collect();
                Ok((keep, drop_ids))
            })?
            .filter_map(|r| r.ok())
            .collect();
        mapped
    };

    let mut merged_groups = 0usize;
    let mut rows_deleted = 0usize;
    for (keep_id, drop_ids) in &dupes {
        if drop_ids.is_empty() {
            continue;
        }
        merged_groups += 1;

        // Re-point tracks.album_id from dropped rows -> keep_id.
        for drop_id in drop_ids {
            tx.execute(
                "UPDATE tracks SET album_id = ? WHERE album_id = ?",
                params![keep_id, drop_id],
            )?;
        }

        // Re-point albums.variant_of from dropped rows -> keep_id. MUST run
        // before the DELETE so FK constraints don't null the pointer.
        for drop_id in drop_ids {
            tx.execute(
                "UPDATE albums SET variant_of = ? WHERE variant_of = ?",
                params![keep_id, drop_id],
            )?;
        }

        // Delete the duplicate rows one at a time (keeps borrow checker happy
        // and avoids dynamic-params juggling). user_album_variant_pref
        // cascades via FK (acceptable per 21.1-CONTEXT: pre-remediation
        // preferences were unusable since no UFO toggle rendered).
        for drop_id in drop_ids {
            let n = tx.execute(
                "DELETE FROM albums WHERE id = ?",
                params![drop_id],
            )?;
            rows_deleted += n;
        }
    }

    log::info!(
        "albums.v17 remediation: renormalized={}, merged_groups={}, rows_deleted={}",
        renormalized,
        merged_groups,
        rows_deleted
    );

    Ok((renormalized, merged_groups, rows_deleted))
}

// ============================================================================
// Plan 21-03 — AlbumDetail payload + slug lookup + sibling/track queries +
// variant-preference UPSERT. Consumed by the Tauri command layer
// (commands/albums.rs::get_album_detail_cmd + set_variant_preference_cmd).
// ============================================================================

/// Pair: a sibling album + its own track list. Matches the TS shape
/// `{ album: Album; tracks: Track[] }` in `ui/src/types/library.ts`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SiblingWithTracks {
    pub album: Album,
    pub tracks: Vec<Track>,
}

/// The full payload returned by `get_album_detail_cmd`. Mirrors the
/// `AlbumDetail` TS interface. `album` is ALWAYS the base album (the row
/// whose `variant_of IS NULL`); `siblings` are the variants pointing at it.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AlbumDetail {
    pub album: Album,
    pub tracks: Vec<Track>,
    pub siblings: Vec<SiblingWithTracks>,
    pub selected_album_id: i64,
    pub is_yeat: bool,
}

/// Compute a URL slug for an album from (album_artist, title).
///
/// Rules (locked in 21-CONTEXT.md §Album Page Surfacing):
/// 1. Join with a space: `"{album_artist} {title}"`.
/// 2. Deunicode-transliterate diacritics (ë -> e) — same crate as
///    `normalize_era` in `yeat::tags` for consistency.
/// 3. Lowercase.
/// 4. Fold any run of non-alphanumeric characters to a single `-`.
/// 5. Trim leading/trailing `-`.
///
/// Frontend MUST produce the same slug for the same inputs (see
/// `ui/src/utils/slug.ts::computeSlug` created in Plan 21-04) — any
/// mismatch means the lookup silently misses.
///
/// Examples:
/// - `("Yeat", "AftërLyfe")` -> `"yeat-afterlyfe"`
/// - `("Yeat", "AftërLyfe [U]")` -> `"yeat-afterlyfe-u"`
/// - `("Playboi Carti", "I AM MUSIC")` -> `"playboi-carti-i-am-music"`
pub fn compute_album_slug(album_artist: &str, title: &str) -> String {
    let combined = format!("{} {}", album_artist, title);
    let deunicoded = deunicode::deunicode(&combined);
    let lowered = deunicoded.to_lowercase();

    let mut out = String::with_capacity(lowered.len());
    let mut last_was_dash = false;
    for c in lowered.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            last_was_dash = false;
        } else if !last_was_dash {
            out.push('-');
            last_was_dash = true;
        }
    }
    out.trim_matches('-').to_string()
}

/// Look up an album row by its computed slug.
///
/// Computes the slug for every album on the fly and returns the first match.
/// For Phase 21 library sizes (≤ thousands of albums), the linear scan is
/// acceptable. If performance becomes an issue later, add a `slug TEXT`
/// column + index — do NOT prematurely optimize here.
///
/// Returns `Ok(None)` if no album matches.
///
/// Security (T-21.03-03): the slug is NEVER concatenated into SQL — only
/// compared via in-memory string equality against per-row computed slugs.
/// No path traversal vector because no filesystem access happens here.
pub fn get_album_by_slug(conn: &Connection, slug: &str) -> Result<Option<Album>> {
    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, title, title_normalized, year, cover_path, variant_of, variant_kind
         FROM albums",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(Album {
            id: r.get(0)?,
            artist: r.get(1)?,
            album_artist: r.get(2)?,
            title: r.get(3)?,
            title_normalized: r.get(4)?,
            year: r.get(5)?,
            cover_path: r.get(6)?,
            variant_of: r.get(7)?,
            variant_kind: r.get(8)?,
        })
    })?;

    for row in rows {
        let album = row?;
        if compute_album_slug(&album.album_artist, &album.title) == slug {
            return Ok(Some(album));
        }
    }
    Ok(None)
}

/// Fetch the track list for a given album id. Tracks are ordered by title
/// ASC (case-insensitive) for determinism — no `track_number` column exists
/// in the tracks table today. If a later phase adds one, update this
/// ORDER BY.
///
/// Hydrates the full `Track` struct including Phase 18 loudness columns so
/// the AlbumDetail payload matches the library table's Track shape.
pub fn get_album_tracks(conn: &Connection, album_id: i64) -> Result<Vec<Track>> {
    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, album, title, genre, year, bitrate, duration,
                format, original_path, organized_path, is_duplicate, date_added,
                lufs_i, lufs_range, true_peak, energy_bucket
         FROM tracks
         WHERE album_id = ?1
         ORDER BY title COLLATE NOCASE ASC, id ASC",
    )?;

    let rows = stmt.query_map(rusqlite::params![album_id], |r| {
        let metadata = TrackMetadata {
            artist: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
            album_artist: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            album: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            title: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
            genre: r.get(5)?,
            year: r.get::<_, Option<i64>>(6)?.map(|y| y as u32),
            bitrate: r.get::<_, Option<i64>>(7)?.map(|b| b as u32),
            duration: r.get::<_, Option<i64>>(8)?.map(|d| d as u32),
            format: r.get::<_, Option<String>>(9)?.unwrap_or_default(),
            original_path: r.get::<_, Option<String>>(10)?.unwrap_or_default(),
        };
        Ok(Track {
            id: Some(r.get::<_, i64>(0)?),
            metadata,
            organized_path: r.get::<_, Option<String>>(11)?,
            is_duplicate: r.get::<_, i64>(12).unwrap_or(0) != 0,
            date_added: r.get::<_, Option<String>>(13)?,
            lufs_i: r.get(14)?,
            lufs_range: r.get(15)?,
            true_peak: r.get(16)?,
            energy_bucket: r.get(17)?,
        })
    })?;

    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// Build the full [`AlbumDetail`] payload for an album, resolving to the BASE
/// row if `album_id` points at a variant.
///
/// Steps:
/// 1. Load the album by id.
/// 2. If `album.variant_of IS NOT NULL`, re-load by that id — we always
///    return the base as `detail.album`.
/// 3. Load tracks for the base.
/// 4. Load every album row where `variant_of = base.id`; for each, load
///    its tracks.
/// 5. Compute `is_yeat` = OR over (base tracks ∪ sibling tracks) of "has a
///    `track_tags` row with tag_key='artist' AND tag_value='yeat'".
/// 6. Look up `user_album_variant_pref` for (user_id, base.id);
///    `selected_album_id` = row's selected_album_id if present, else base.id.
pub fn get_album_with_siblings(
    conn: &Connection,
    album_id: i64,
    user_id: &str,
) -> Result<Option<AlbumDetail>> {
    // Step 1: load the album by id.
    let starting = conn
        .query_row(
            "SELECT id, artist, album_artist, title, title_normalized, year, cover_path, variant_of, variant_kind
             FROM albums WHERE id = ?1",
            rusqlite::params![album_id],
            |r| {
                Ok(Album {
                    id: r.get(0)?,
                    artist: r.get(1)?,
                    album_artist: r.get(2)?,
                    title: r.get(3)?,
                    title_normalized: r.get(4)?,
                    year: r.get(5)?,
                    cover_path: r.get(6)?,
                    variant_of: r.get(7)?,
                    variant_kind: r.get(8)?,
                })
            },
        )
        .optional()?;

    let starting = match starting {
        Some(a) => a,
        None => return Ok(None),
    };

    // Step 2: resolve to base if this is a variant.
    let base = if let Some(base_id) = starting.variant_of {
        conn.query_row(
            "SELECT id, artist, album_artist, title, title_normalized, year, cover_path, variant_of, variant_kind
             FROM albums WHERE id = ?1",
            rusqlite::params![base_id],
            |r| {
                Ok(Album {
                    id: r.get(0)?,
                    artist: r.get(1)?,
                    album_artist: r.get(2)?,
                    title: r.get(3)?,
                    title_normalized: r.get(4)?,
                    year: r.get(5)?,
                    cover_path: r.get(6)?,
                    variant_of: r.get(7)?,
                    variant_kind: r.get(8)?,
                })
            },
        )
        .optional()?
        .unwrap_or(starting) // If base was deleted, fall back to the variant itself.
    } else {
        starting
    };

    // Step 3: base tracks.
    let base_tracks = get_album_tracks(conn, base.id)?;

    // Step 4: siblings (variant_of = base.id) + their tracks.
    let sibling_albums: Vec<Album> = {
        let mut stmt = conn.prepare(
            "SELECT id, artist, album_artist, title, title_normalized, year, cover_path, variant_of, variant_kind
             FROM albums WHERE variant_of = ?1
             ORDER BY variant_kind ASC, id ASC",
        )?;
        let rows = stmt.query_map(rusqlite::params![base.id], |r| {
            Ok(Album {
                id: r.get(0)?,
                artist: r.get(1)?,
                album_artist: r.get(2)?,
                title: r.get(3)?,
                title_normalized: r.get(4)?,
                year: r.get(5)?,
                cover_path: r.get(6)?,
                variant_of: r.get(7)?,
                variant_kind: r.get(8)?,
            })
        })?;
        rows.filter_map(|r| r.ok()).collect()
    };

    let mut siblings: Vec<SiblingWithTracks> = Vec::with_capacity(sibling_albums.len());
    for sa in sibling_albums {
        let t = get_album_tracks(conn, sa.id)?;
        siblings.push(SiblingWithTracks { album: sa, tracks: t });
    }

    // Step 5: is_yeat — any track on base OR a sibling with (artist=yeat).
    let all_album_ids: Vec<i64> = std::iter::once(base.id)
        .chain(siblings.iter().map(|s| s.album.id))
        .collect();
    let is_yeat = album_set_has_yeat_tag(conn, &all_album_ids)?;

    // Step 6: selected_album_id from user_album_variant_pref, default = base.id.
    let selected_album_id = get_variant_preference(conn, user_id, base.id)?
        .unwrap_or(base.id);

    Ok(Some(AlbumDetail {
        album: base,
        tracks: base_tracks,
        siblings,
        selected_album_id,
        is_yeat,
    }))
}

/// Returns true iff ANY track in ANY of the given albums carries a
/// `track_tags (tag_key='artist', tag_value='yeat')` row.
///
/// Security (T-21.03-01): the `format!` only builds the placeholder list
/// (`?, ?, ?, …`) — album id values are always bound via
/// `rusqlite::params_from_iter`. Zero injection surface.
fn album_set_has_yeat_tag(conn: &Connection, album_ids: &[i64]) -> Result<bool> {
    if album_ids.is_empty() {
        return Ok(false);
    }
    let placeholders: String = (0..album_ids.len()).map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!(
        "SELECT 1 FROM track_tags tt
         JOIN tracks t ON t.id = tt.track_id
         WHERE t.album_id IN ({})
           AND tt.tag_key = 'artist'
           AND tt.tag_value = 'yeat'
         LIMIT 1",
        placeholders
    );
    let mut stmt = conn.prepare(&sql)?;
    let params_vec: Vec<&dyn rusqlite::ToSql> = album_ids
        .iter()
        .map(|id| id as &dyn rusqlite::ToSql)
        .collect();
    let found = stmt
        .query_row(rusqlite::params_from_iter(params_vec), |r| r.get::<_, i64>(0))
        .optional()?;
    Ok(found.is_some())
}

/// UPSERT the user's variant selection for a given base album.
///
/// Validates that `selected_album_id` is either equal to `base_album_id` OR
/// a row where `variant_of = base_album_id`. Returns an error if the caller
/// passes an unrelated album.
///
/// Error variant: uses `rusqlite::Error::InvalidQuery.into()` for domain
/// validation failures — mirrors `database/playlist.rs:484` since
/// `DatabaseError` only carries `Sqlite(rusqlite::Error)` and
/// `Connection(String)` variants (LOCKED per 21-03 plan §STEP 2).
pub fn upsert_variant_preference(
    conn: &Connection,
    user_id: &str,
    base_album_id: i64,
    selected_album_id: i64,
) -> Result<()> {
    // Validate selected_album_id.
    let is_valid: bool = if selected_album_id == base_album_id {
        true
    } else {
        conn.query_row(
            "SELECT 1 FROM albums WHERE id = ?1 AND variant_of = ?2",
            rusqlite::params![selected_album_id, base_album_id],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
        .is_some()
    };
    if !is_valid {
        log::warn!(
            "set_variant_preference: selected_album_id {} is neither the base {} nor a variant of it",
            selected_album_id,
            base_album_id
        );
        return Err(rusqlite::Error::InvalidQuery.into());
    }

    let updated_at = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO user_album_variant_pref (user_id, base_album_id, selected_album_id, updated_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(user_id, base_album_id) DO UPDATE SET
             selected_album_id = excluded.selected_album_id,
             updated_at = excluded.updated_at",
        rusqlite::params![user_id, base_album_id, selected_album_id, updated_at],
    )?;
    Ok(())
}

/// Read the user's variant selection for a given base album. Returns
/// `Ok(None)` when no preference row exists (caller defaults to base).
pub fn get_variant_preference(
    conn: &Connection,
    user_id: &str,
    base_album_id: i64,
) -> Result<Option<i64>> {
    conn.query_row(
        "SELECT selected_album_id FROM user_album_variant_pref
         WHERE user_id = ?1 AND base_album_id = ?2",
        rusqlite::params![user_id, base_album_id],
        |r| r.get::<_, i64>(0),
    )
    .optional()
    .map_err(|e| e.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_title_stem_base() {
        assert_eq!(normalize_title_stem("AftërLyfe"), "afterlyfe");
    }

    #[test]
    fn test_normalize_title_stem_strips_u_bracket() {
        assert_eq!(normalize_title_stem("AftërLyfe [U]"), "afterlyfe");
    }

    #[test]
    fn test_normalize_title_stem_strips_half() {
        assert_eq!(normalize_title_stem("4L 0.5"), "4l");
    }

    #[test]
    fn test_normalize_title_stem_strips_v1() {
        assert_eq!(normalize_title_stem("Lyfestyle V1"), "lyfestyle");
    }

    #[test]
    fn test_normalize_title_stem_strips_v2() {
        assert_eq!(normalize_title_stem("Lyfestyle V2"), "lyfestyle");
    }

    #[test]
    fn test_normalize_title_stem_strips_v4() {
        assert_eq!(normalize_title_stem("Lyfestyle V4"), "lyfestyle");
    }

    #[test]
    fn test_variant_kind_base_is_none() {
        assert_eq!(variant_kind_for_title("AftërLyfe"), None);
    }

    #[test]
    fn test_variant_kind_u() {
        assert_eq!(variant_kind_for_title("AftërLyfe [U]"), Some("u".to_string()));
    }

    #[test]
    fn test_variant_kind_v2() {
        assert_eq!(variant_kind_for_title("Lyfestyle V2"), Some("v2".to_string()));
    }

    #[test]
    fn test_variant_kind_half() {
        assert_eq!(variant_kind_for_title("4L 0.5"), Some("0.5".to_string()));
    }

    // ========================================================================
    // Plan 21-03 tests — slug computation, slug lookup, sibling/track queries,
    // is_yeat gate, variant-preference UPSERT/GET.
    // ========================================================================

    use crate::database::initialize_schema;
    use rusqlite::Connection;

    /// In-memory DB with v16 schema applied + foreign keys enabled.
    fn prepared_conn() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        initialize_schema(&mut conn).unwrap();
        conn
    }

    /// Insert an album row, return its id.
    fn insert_album(
        conn: &Connection,
        album_artist: &str,
        title: &str,
        variant_of: Option<i64>,
        variant_kind: Option<&str>,
    ) -> i64 {
        let title_norm = normalize_title_stem(title);
        conn.execute(
            "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_of, variant_kind)
             VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params![album_artist, album_artist, title, title_norm, variant_of, variant_kind],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    /// Insert a track row linked to `album_id`. Returns its id.
    fn insert_track(conn: &Connection, album_id: i64, title: &str, relpath: &str) -> i64 {
        conn.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, album_id)
             VALUES ('Yeat', 'Yeat', 'X', ?, 'flac', ?, ?, ?)",
            rusqlite::params![title, relpath, relpath, album_id],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    // ---------- compute_album_slug (pure) ----------

    #[test]
    fn test_compute_album_slug_basic() {
        assert_eq!(compute_album_slug("Yeat", "AftërLyfe"), "yeat-afterlyfe");
    }

    #[test]
    fn test_compute_album_slug_variant() {
        assert_eq!(compute_album_slug("Yeat", "AftërLyfe [U]"), "yeat-afterlyfe-u");
    }

    #[test]
    fn test_compute_album_slug_spaces_and_punct() {
        assert_eq!(
            compute_album_slug("Playboi Carti", "I AM MUSIC"),
            "playboi-carti-i-am-music"
        );
    }

    // ---------- get_album_by_slug ----------

    #[test]
    fn test_get_album_by_slug_returns_variant_row_not_base() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "AftërLyfe", None, None);
        let var = insert_album(&conn, "Yeat", "AftërLyfe [U]", Some(base), Some("u"));
        let hit = get_album_by_slug(&conn, "yeat-afterlyfe-u")
            .unwrap()
            .expect("variant slug hit");
        assert_eq!(hit.id, var);
        assert_eq!(hit.variant_of, Some(base));
    }

    #[test]
    fn test_get_album_by_slug_no_match_returns_none() {
        let conn = prepared_conn();
        let hit = get_album_by_slug(&conn, "nonexistent-album").unwrap();
        assert!(hit.is_none());
    }

    // ---------- get_album_with_siblings ----------

    #[test]
    fn test_get_album_with_siblings_resolves_variant_to_base() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "AftërLyfe", None, None);
        let var = insert_album(&conn, "Yeat", "AftërLyfe [U]", Some(base), Some("u"));
        insert_track(&conn, base, "Base Track", "a/b.flac");
        insert_track(&conn, var, "Variant Track", "a/c.flac");

        // Query by variant id — should return base + [variant].
        let detail = get_album_with_siblings(&conn, var, "default")
            .unwrap()
            .expect("detail");
        assert_eq!(detail.album.id, base, "album field must be base, not variant");
        assert_eq!(detail.tracks.len(), 1);
        assert_eq!(detail.tracks[0].metadata.title, "Base Track");
        assert_eq!(detail.siblings.len(), 1);
        assert_eq!(detail.siblings[0].album.id, var);
        assert_eq!(detail.siblings[0].tracks.len(), 1);
        assert_eq!(detail.selected_album_id, base, "default selection = base");
    }

    #[test]
    fn test_get_album_with_siblings_no_siblings() {
        let conn = prepared_conn();
        let solo = insert_album(&conn, "Yeat", "Lyfestyle", None, None);
        insert_track(&conn, solo, "Track 1", "yeat/lyfe/1.flac");
        let detail = get_album_with_siblings(&conn, solo, "default")
            .unwrap()
            .expect("detail");
        assert_eq!(detail.siblings.len(), 0);
        assert_eq!(detail.tracks.len(), 1);
    }

    #[test]
    fn test_get_album_tracks_ordered_by_title() {
        let conn = prepared_conn();
        let a = insert_album(&conn, "Yeat", "TestOrder", None, None);
        insert_track(&conn, a, "Charlie", "t/c.flac");
        insert_track(&conn, a, "alpha", "t/a.flac");
        insert_track(&conn, a, "Bravo", "t/b.flac");
        let tracks = get_album_tracks(&conn, a).unwrap();
        assert_eq!(tracks.len(), 3);
        let titles: Vec<&str> = tracks.iter().map(|t| t.metadata.title.as_str()).collect();
        // Case-insensitive ASC.
        assert_eq!(titles, vec!["alpha", "Bravo", "Charlie"]);
    }

    // ---------- is_yeat gate ----------

    #[test]
    fn test_is_yeat_true_when_any_sibling_has_yeat_tag() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "AftërLyfe", None, None);
        let var = insert_album(&conn, "Yeat", "AftërLyfe [U]", Some(base), Some("u"));
        let base_tid = insert_track(&conn, base, "t1", "a/1.flac");
        // Only the variant's track has the yeat tag.
        let var_tid = insert_track(&conn, var, "t2", "a/2.flac");
        conn.execute(
            "INSERT INTO track_tags (track_id, tag_key, tag_value) VALUES (?, 'artist', 'yeat')",
            rusqlite::params![var_tid],
        )
        .unwrap();
        let _ = base_tid;

        let detail = get_album_with_siblings(&conn, base, "default")
            .unwrap()
            .expect("detail");
        assert!(
            detail.is_yeat,
            "is_yeat must be true when any sibling track has artist=yeat"
        );
    }

    #[test]
    fn test_is_yeat_false_when_no_yeat_tags() {
        let conn = prepared_conn();
        let solo = insert_album(&conn, "Drake", "Scorpion", None, None);
        insert_track(&conn, solo, "God's Plan", "drake/g.flac");
        let detail = get_album_with_siblings(&conn, solo, "default")
            .unwrap()
            .expect("detail");
        assert!(!detail.is_yeat);
    }

    // ---------- upsert_variant_preference + get_variant_preference ----------

    #[test]
    fn test_upsert_variant_preference_insert_then_update() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "AftërLyfe", None, None);
        let var = insert_album(&conn, "Yeat", "AftërLyfe [U]", Some(base), Some("u"));

        upsert_variant_preference(&conn, "default", base, var).unwrap();
        let got = get_variant_preference(&conn, "default", base).unwrap();
        assert_eq!(got, Some(var));

        // Update: switch back to base.
        upsert_variant_preference(&conn, "default", base, base).unwrap();
        let got = get_variant_preference(&conn, "default", base).unwrap();
        assert_eq!(got, Some(base));

        // Assert only one row exists per (user_id, base_album_id).
        let row_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM user_album_variant_pref WHERE user_id = 'default' AND base_album_id = ?",
                rusqlite::params![base],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(row_count, 1);
    }

    #[test]
    fn test_upsert_variant_preference_rejects_unrelated_album() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "AftërLyfe", None, None);
        let unrelated = insert_album(&conn, "Drake", "Scorpion", None, None);

        let result = upsert_variant_preference(&conn, "default", base, unrelated);
        assert!(result.is_err(), "unrelated album must be rejected");
    }

    #[test]
    fn test_get_variant_preference_no_row_returns_none() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "AftërLyfe", None, None);
        let got = get_variant_preference(&conn, "default", base).unwrap();
        assert_eq!(got, None);
    }

    // ---------- AlbumDetail JSON shape ----------

    #[test]
    fn test_album_detail_json_shape() {
        let conn = prepared_conn();
        let base = insert_album(&conn, "Yeat", "Test", None, None);
        let detail = get_album_with_siblings(&conn, base, "default")
            .unwrap()
            .expect("detail");
        let json = serde_json::to_value(&detail).unwrap();
        assert!(json.get("album").is_some());
        assert!(json.get("tracks").is_some());
        assert!(json.get("siblings").is_some());
        assert!(json.get("selected_album_id").is_some());
        assert!(json.get("is_yeat").is_some());
    }
}
