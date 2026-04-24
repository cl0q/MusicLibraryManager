//! Albums module — Phase 21 v16 schema. Provides:
//! - `Album` struct (mirrors the `albums` table row shape)
//! - `backfill_albums_from_tracks` — one-shot migration helper called from
//!   schema.rs `migrate_to_v16`. Aggregates DISTINCT (album_artist, album)
//!   from the tracks table and inserts one albums row per pair, parsing the
//!   variant suffix from the album title via `yeat::tags::detect_variant`.
//!
//! Plan 21-03 extends this module with query functions (`get_album_by_slug`,
//! `get_album_detail`) consumed by the Tauri command layer.

use rusqlite::{params, Transaction};

use crate::database::connection::Result;
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
    let mut stmt = tx.prepare(
        "SELECT album_artist, album, MIN(artist) AS artist, MIN(year) AS year
         FROM tracks
         WHERE album_artist IS NOT NULL AND album IS NOT NULL
           AND album_artist != '' AND album != ''
         GROUP BY album_artist, album",
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
}
