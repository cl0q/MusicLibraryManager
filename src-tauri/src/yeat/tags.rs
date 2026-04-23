//! Pure-function tag inference for the Yeat taxonomy + a disk walker that
//! applies it across the library's Yeat root.
//!
//! All rules locked in `.planning/phases/20-tags-provenance/20-CONTEXT.md`
//! §Disk Walker & Inference Rules. This module has zero Tauri dependencies —
//! it takes paths in, returns structs out. Plan 20-03 wraps it in a Tauri
//! command and diffs its output against `track_tags` in the database.

use std::path::{Path, PathBuf};

/// Canonical tag key for the Yeat artist marker. Every file under the Yeat
/// root receives this static tag.
const ARTIST_KEY: &str = "artist";
/// Canonical tag key for the era dimension (normalized folder name).
const ERA_KEY: &str = "era";
/// Canonical tag key for the variant dimension (base / u / 0.5 / v1 / v2 / v4).
const VARIANT_KEY: &str = "variant";

/// Static artist tag value — every track under `00_Artist/Yeat/` is tagged
/// with this regardless of what the file's internal metadata says.
const YEAT_ARTIST_VALUE: &str = "yeat";

/// Prefix (relative to library root) under which Yeat-tagged files live.
/// Matches the Phase 12.1 invariant that `tracks.organized_path` is relative
/// to the library root, not the Yeat root.
const YEAT_PREFIX_FIRST: &str = "00_Artist";
const YEAT_PREFIX_SECOND: &str = "Yeat";

/// Audio file extensions the walker treats as track candidates (case-insensitive).
const AUDIO_EXTENSIONS: &[&str] = &["flac", "m4a", "mp3", "aac", "wav", "ogg", "opus"];

/// A single tag triple for a track. Matches the v15 `track_tags` table shape
/// (`track_id`, `tag_key`, `tag_value`) minus the `track_id` — that's assigned
/// when this is persisted against a specific DB row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct TagTriple {
    pub tag_key: String,
    pub tag_value: String,
}

impl TagTriple {
    /// Convenience constructor: `TagTriple::new("era", "aftrelyfe")`.
    fn new(tag_key: impl Into<String>, tag_value: impl Into<String>) -> Self {
        Self {
            tag_key: tag_key.into(),
            tag_value: tag_value.into(),
        }
    }
}

/// One entry produced by [`walk_yeat_root`] — a single audio file on disk,
/// with the path relative to the library root (NOT the Yeat root, so it
/// matches `tracks.organized_path` directly per the Phase 12.1 invariant)
/// and the tags inferred for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalkedTrack {
    /// Path relative to the library root, e.g. `"00_Artist/Yeat/AftërLyfe/Track 01.m4a"`.
    pub relative_path: PathBuf,
    /// Inferred tag triples — always three entries in order: artist, era, variant.
    pub tags: Vec<TagTriple>,
}

/// Normalize an era folder name to its canonical snake_case form.
///
/// Rules (locked in CONTEXT.md):
/// 1. Strip diacritics (AftërLyfe → AftreLyfe) via `deunicode`.
/// 2. Lowercase the whole string.
/// 3. Collapse any run of non-alphanumeric characters to a single underscore.
/// 4. Trim leading/trailing underscores.
///
/// Examples:
/// - `"AftërLyfe"` → `"afterlyfe"` (ë → e via Unicode-standard deunicoding)
/// - `"2 Alivë [Deluxe]"` → `"2_alive_deluxe"`
///
/// Note: the `20-CONTEXT.md` spec's worked example reads `"aftrelyfe"` —
/// that is a typo (r/e transposed). The documented rule ("strip diacritics
/// + lowercase") via `deunicode` (which applies Unicode-standard
/// transliteration, `ë` → `e`) produces `"afterlyfe"`.
pub fn normalize_era(folder_name: &str) -> String {
    let deunicoded = deunicode::deunicode(folder_name);
    let lowered = deunicoded.to_lowercase();

    // Fold non-alphanumeric chars to underscores, then collapse runs.
    let mut out = String::with_capacity(lowered.len());
    let mut last_was_underscore = false;
    for c in lowered.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            last_was_underscore = false;
        } else if !last_was_underscore {
            out.push('_');
            last_was_underscore = true;
        }
    }

    // Trim leading/trailing underscores.
    out.trim_matches('_').to_string()
}

/// Detect the variant for a given folder or file name per the locked priority:
/// 1. Case-insensitive substring `"[U]"` → `"u"`
/// 2. Case-insensitive substring `"0.5"` → `"0.5"`
/// 3. Token match (word-boundary) `V1` | `V2` | `V4` → `"v1"` | `"v2"` | `"v4"`
/// 4. Otherwise → `"base"`
///
/// The `[U]` and `0.5` checks tolerate surrounding whitespace/brackets.
/// The V-match splits on non-alphanumeric characters so `V10` (non-variant)
/// does NOT match `V1`.
pub fn detect_variant(name: &str) -> String {
    let lower = name.to_lowercase();

    if lower.contains("[u]") {
        return "u".to_string();
    }
    if lower.contains("0.5") {
        return "0.5".to_string();
    }

    // Token-match for V1/V2/V4: split on any non-alphanumeric boundary.
    for token in lower.split(|c: char| !c.is_ascii_alphanumeric()) {
        match token {
            "v1" => return "v1".to_string(),
            "v2" => return "v2".to_string(),
            "v4" => return "v4".to_string(),
            _ => {}
        }
    }

    "base".to_string()
}

/// Infer the full tag set for a single file path.
///
/// `relative_path` is relative to the **library root** (not the Yeat root),
/// e.g. `"00_Artist/Yeat/AftërLyfe [U]/Track 03.m4a"`. This matches
/// `tracks.organized_path` directly.
///
/// Returns exactly three tag triples in this order: artist, era, variant.
/// Returns an empty `Vec` if:
/// - The path does not start with `00_Artist/Yeat/`
/// - There are fewer than 2 path components after `Yeat/` (loose file at the
///   Yeat root, no era/album structure)
///
/// Variant detection precedence: if the album folder yields a non-`base`
/// variant, that always wins over the file-stem variant.
pub fn infer_tags(relative_path: &Path) -> Vec<TagTriple> {
    let components: Vec<&std::ffi::OsStr> =
        relative_path.components().map(|c| c.as_os_str()).collect();

    // Must start with 00_Artist/Yeat/
    if components.len() < 2 {
        return vec![];
    }
    if components[0] != YEAT_PREFIX_FIRST || components[1] != YEAT_PREFIX_SECOND {
        return vec![];
    }

    // Remaining components AFTER "00_Artist/Yeat/".
    let remaining = &components[2..];

    // Need at least era folder + file. Pure loose file at the Yeat root
    // (remaining.len() == 1) is not a valid backfill target.
    if remaining.len() < 2 {
        return vec![];
    }

    // Era is always the first component after Yeat/.
    let era_raw = remaining[0].to_string_lossy();
    let era_normalized = normalize_era(&era_raw);

    // Album folder: second-to-last component. For `era/album/track.m4a` that
    // is `remaining[remaining.len() - 2]`. For the degenerate `era/track.m4a`
    // (only two components after Yeat/), the era folder IS the album folder.
    let album_raw: String = if remaining.len() == 2 {
        era_raw.to_string()
    } else {
        remaining[remaining.len() - 2].to_string_lossy().to_string()
    };

    // Variant detection: album folder takes precedence; if base, fall through
    // to the file stem.
    let album_variant = detect_variant(&album_raw);
    let variant = if album_variant == "base" {
        let file_stem = relative_path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        detect_variant(&file_stem)
    } else {
        album_variant
    };

    vec![
        TagTriple::new(ARTIST_KEY, YEAT_ARTIST_VALUE),
        TagTriple::new(ERA_KEY, era_normalized),
        TagTriple::new(VARIANT_KEY, variant),
    ]
}

/// Case-insensitive audio-extension filter.
fn is_audio_ext(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| {
            let lower = e.to_ascii_lowercase();
            AUDIO_EXTENSIONS.iter().any(|ext| *ext == lower)
        })
        .unwrap_or(false)
}

/// Walk the Yeat root directory and infer tags for every audio file beneath it.
///
/// `library_root` is the absolute library root (e.g. `/Volumes/Lexxar/Music`).
/// The walker joins `library_root + 00_Artist/Yeat` and:
/// - Returns `Err` with a descriptive message if the Yeat root does not exist
///   or is not a directory. The message includes the attempted path so the
///   user can diagnose an unmounted external drive.
/// - Recursively walks, filtering to audio-extension files (case-insensitive).
///   Directories and non-audio files are skipped silently.
/// - Strips `library_root` from each absolute path so the resulting
///   `relative_path` matches `tracks.organized_path` directly.
/// - Calls [`infer_tags`] on each file and collects the non-empty results.
///
/// Per-entry errors (e.g. permission denied mid-walk, `strip_prefix` failure)
/// are logged via the `log` crate and the offending entry is skipped — a
/// partial walk is better than aborting, matching the disk-drift-is-a-report
/// -not-an-error spirit of CONTEXT.
pub fn walk_yeat_root(library_root: &Path) -> Result<Vec<WalkedTrack>, String> {
    let yeat_root = library_root.join(YEAT_PREFIX_FIRST).join(YEAT_PREFIX_SECOND);

    if !yeat_root.exists() || !yeat_root.is_dir() {
        return Err(format!(
            "Yeat root not found: {} (is the external drive mounted?)",
            yeat_root.display()
        ));
    }

    let mut results: Vec<WalkedTrack> = Vec::new();

    for entry in walkdir::WalkDir::new(&yeat_root).into_iter() {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                log::warn!("walk_yeat_root: skipping entry due to error: {}", e);
                continue;
            }
        };

        if !entry.file_type().is_file() {
            continue;
        }

        let absolute = entry.path();
        if !is_audio_ext(absolute) {
            continue;
        }

        let relative = match absolute.strip_prefix(library_root) {
            Ok(r) => r.to_path_buf(),
            Err(e) => {
                log::warn!(
                    "walk_yeat_root: strip_prefix failed for {}: {}",
                    absolute.display(),
                    e
                );
                continue;
            }
        };

        let tags = infer_tags(&relative);
        if tags.is_empty() {
            log::debug!(
                "walk_yeat_root: inference returned no tags for {} (skipped)",
                relative.display()
            );
            continue;
        }

        results.push(WalkedTrack {
            relative_path: relative,
            tags,
        });
    }

    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::path::Path;
    use tempfile::TempDir;

    // ---------- normalize_era ----------

    #[test]
    fn test_normalize_era_basic() {
        // deunicode applies Unicode-standard transliteration: ë → e.
        // The CONTEXT.md worked example reads "aftrelyfe" but that is a typo
        // (r/e transposed) — the documented process produces "afterlyfe".
        // See Deviations in 20-02-SUMMARY.md.
        assert_eq!(normalize_era("AftërLyfe"), "afterlyfe");
    }

    #[test]
    fn test_normalize_era_whitespace() {
        assert_eq!(normalize_era("Up 2 Më"), "up_2_me");
    }

    #[test]
    fn test_normalize_era_already_snake() {
        assert_eq!(normalize_era("lyfestyle"), "lyfestyle");
    }

    #[test]
    fn test_normalize_era_brackets_and_dashes() {
        assert_eq!(normalize_era("2 Alivë [Deluxe]"), "2_alive_deluxe");
    }

    #[test]
    fn test_normalize_era_trims_underscores() {
        assert_eq!(normalize_era("  Hello  "), "hello");
    }

    #[test]
    fn test_normalize_era_collapses_multiple_separators() {
        assert_eq!(normalize_era("a---b___c"), "a_b_c");
    }

    #[test]
    fn test_normalize_era_empty() {
        assert_eq!(normalize_era(""), "");
    }

    // ---------- detect_variant ----------

    #[test]
    fn test_detect_variant_base() {
        assert_eq!(detect_variant("AftërLyfe"), "base");
    }

    #[test]
    fn test_detect_variant_u_brackets() {
        assert_eq!(detect_variant("AftërLyfe [U]"), "u");
    }

    #[test]
    fn test_detect_variant_u_lowercase() {
        assert_eq!(detect_variant("aftrelyfe [u]"), "u");
    }

    #[test]
    fn test_detect_variant_half() {
        assert_eq!(detect_variant("4L 0.5"), "0.5");
    }

    #[test]
    fn test_detect_variant_v1() {
        assert_eq!(detect_variant("Lyfestyle V1"), "v1");
    }

    #[test]
    fn test_detect_variant_v2() {
        assert_eq!(detect_variant("Lyfestyle V2"), "v2");
    }

    #[test]
    fn test_detect_variant_v4() {
        assert_eq!(detect_variant("Lyfestyle V4"), "v4");
    }

    #[test]
    fn test_detect_variant_v3_ignored_as_base() {
        // V3 is NOT in the locked variant set — must fall through to base.
        assert_eq!(detect_variant("Lyfestyle V3"), "base");
    }

    #[test]
    fn test_detect_variant_priority_u_over_half() {
        // [U] has higher priority than 0.5.
        assert_eq!(detect_variant("AftërLyfe [U] 0.5"), "u");
    }

    #[test]
    fn test_detect_variant_priority_half_over_v1() {
        // 0.5 has higher priority than V1.
        assert_eq!(detect_variant("Lyfestyle 0.5 V1"), "0.5");
    }

    #[test]
    fn test_detect_variant_v1_not_matching_v10() {
        // Word-boundary: V10 is NOT V1.
        assert_eq!(detect_variant("Track V10"), "base");
    }

    #[test]
    fn test_detect_variant_v1_in_file() {
        // File extensions and surrounding punctuation shouldn't block the match.
        assert_eq!(detect_variant("Track 03 V1.m4a"), "v1");
    }

    // ---------- infer_tags ----------

    fn tag(key: &str, value: &str) -> TagTriple {
        TagTriple::new(key, value)
    }

    #[test]
    fn test_infer_tags_simple_base() {
        let tags = infer_tags(Path::new("00_Artist/Yeat/AftërLyfe/Track 01.m4a"));
        assert_eq!(
            tags,
            vec![
                tag("artist", "yeat"),
                tag("era", "afterlyfe"),
                tag("variant", "base"),
            ]
        );
    }

    #[test]
    fn test_infer_tags_album_u_precedence() {
        let tags = infer_tags(Path::new("00_Artist/Yeat/AftërLyfe [U]/Track 01.m4a"));
        // Album folder wins: variant = u regardless of file stem.
        assert!(tags.contains(&tag("variant", "u")), "expected variant=u in {:?}", tags);
        assert!(tags.contains(&tag("artist", "yeat")));
    }

    #[test]
    fn test_infer_tags_file_variant_when_album_base() {
        // Album folder "Lyfestyle" is base → fall through to file stem V1.
        let tags = infer_tags(Path::new("00_Artist/Yeat/Lyfestyle/Track 03 V1.m4a"));
        assert!(tags.contains(&tag("variant", "v1")), "expected variant=v1 in {:?}", tags);
    }

    #[test]
    fn test_infer_tags_album_u_beats_file_v1() {
        // Album [U] takes precedence over file stem V1.
        let tags = infer_tags(Path::new("00_Artist/Yeat/AftërLyfe [U]/Track 03 V1.m4a"));
        assert!(tags.contains(&tag("variant", "u")), "expected variant=u in {:?}", tags);
    }

    #[test]
    fn test_infer_tags_path_outside_yeat_returns_empty() {
        let tags = infer_tags(Path::new("00_Artist/Playboi Carti/song.m4a"));
        assert_eq!(tags, Vec::<TagTriple>::new());
    }

    #[test]
    fn test_infer_tags_path_at_yeat_root_no_album_returns_empty() {
        // Loose file directly at the Yeat root: not a valid backfill target.
        let tags = infer_tags(Path::new("00_Artist/Yeat/loose_track.m4a"));
        assert_eq!(tags, Vec::<TagTriple>::new());
    }

    #[test]
    fn test_infer_tags_era_normalization_applied() {
        let tags = infer_tags(Path::new("00_Artist/Yeat/AftërLyfe/x.m4a"));
        let era_tag = tags.iter().find(|t| t.tag_key == "era").expect("era tag present");
        assert_eq!(era_tag.tag_value, "afterlyfe");
    }

    // ---------- walk_yeat_root ----------

    /// Helper: create an empty file at `path`, creating parents as needed.
    fn touch(path: &Path) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parents");
        }
        File::create(path).expect("create file");
    }

    #[test]
    fn test_walk_yeat_root_missing_root_returns_err() {
        let tmp = TempDir::new().unwrap();
        // No 00_Artist/Yeat/ subfolder inside tmp.
        let result = walk_yeat_root(tmp.path());
        assert!(result.is_err());
        let err = result.err().unwrap();
        assert!(
            err.contains("Yeat root not found"),
            "error message should include 'Yeat root not found': {}",
            err
        );
        // Must include the attempted path so the user can diagnose.
        assert!(
            err.contains(&tmp.path().display().to_string()),
            "error message should include attempted path: {}",
            err
        );
    }

    #[test]
    fn test_walk_yeat_root_empty_yeat_returns_ok_empty() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("00_Artist").join("Yeat")).unwrap();
        let result = walk_yeat_root(tmp.path()).expect("empty walk should succeed");
        assert_eq!(result.len(), 0);
    }

    #[test]
    fn test_walk_yeat_root_fixture() {
        let tmp = TempDir::new().unwrap();
        let yeat = tmp.path().join("00_Artist").join("Yeat");

        touch(&yeat.join("aftrelyfe").join("Track 01.m4a"));
        touch(&yeat.join("aftrelyfe [U]").join("Track 01.m4a"));
        touch(&yeat.join("lyfestyle").join("Track 02 V1.m4a"));
        touch(&yeat.join("lyfestyle").join("notes.txt")); // non-audio, must be skipped

        let walked = walk_yeat_root(tmp.path()).expect("walk succeeds");
        assert_eq!(walked.len(), 3, "exactly 3 audio files: got {:?}", walked);

        // Every walked track has artist=yeat.
        for w in &walked {
            assert!(
                w.tags.contains(&tag("artist", "yeat")),
                "missing artist=yeat in {:?}",
                w
            );
        }

        // Find each by its relative path suffix and assert expected variant.
        let find_variant = |needle: &str| -> String {
            walked
                .iter()
                .find(|w| w.relative_path.to_string_lossy().contains(needle))
                .and_then(|w| w.tags.iter().find(|t| t.tag_key == "variant"))
                .map(|t| t.tag_value.clone())
                .unwrap_or_else(|| panic!("no walked track matching {}", needle))
        };

        assert_eq!(find_variant("aftrelyfe/Track 01.m4a"), "base");
        assert_eq!(find_variant("aftrelyfe [U]"), "u");
        assert_eq!(find_variant("Track 02 V1.m4a"), "v1");
    }

    #[test]
    fn test_walk_yeat_root_extensions_case_insensitive() {
        let tmp = TempDir::new().unwrap();
        let yeat = tmp.path().join("00_Artist").join("Yeat");
        // Uppercase extension — must still be included.
        touch(&yeat.join("aftrelyfe").join("Track.FLAC"));

        let walked = walk_yeat_root(tmp.path()).expect("walk succeeds");
        assert_eq!(walked.len(), 1, "uppercase FLAC should be included: {:?}", walked);
        assert!(walked[0].tags.contains(&tag("artist", "yeat")));
    }
}
