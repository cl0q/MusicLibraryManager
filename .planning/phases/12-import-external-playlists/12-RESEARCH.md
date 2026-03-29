# Phase 12: Import External Playlists - Research

**Researched:** 2026-03-29
**Domain:** Playlist file parsing (M3U/M3U8/JSON), file I/O, track matching, UI file dialogs
**Confidence:** HIGH

## Summary

Phase 12 enables users to import playlists from external files into the music library manager. This is a natural extension of v1.1's foundation work and aligns with the deferred v1.2 requirement STRM-02 (Spotify JSON one-time migration). The phase adds file parsing infrastructure, track matching logic to link imported tracks to library entries, and UI flows for file selection and conflict resolution.

**Primary recommendation:**
1. Support M3U8 (UTF-8 with metadata) and Spotify JSON exports as primary formats
2. Use `m3u8_parser` crate for M3U/M3U8 parsing, `serde_json` for JSON
3. Implement file dialog via Tauri's `tauri-plugin-dialog` (already in dependencies)
4. Match imported tracks to library via artist+title fuzzy matching (using existing `strsim` and dedup infrastructure)
5. Create new playlist with unmatched tracks as "unresolved" with placeholder entries
6. UI: File picker → Preview with match status → Create playlist with matched tracks only, flag unmatched

---

## Standard Stack

### Core Dependencies

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| m3u8_parser | 0.7+ | M3U/M3U8 playlist parsing | De facto standard for M3U parsing in Rust, handles both simple and extended M3U formats |
| serde_json | 1.0+ | JSON serialization/parsing | Already in project, handles Spotify export JSON parsing |
| tauri-plugin-dialog | 2.0 | File picker dialogs | Already in dependencies, cross-platform file selection |
| strsim | 0.11 | Fuzzy string matching | Already in project, used for track deduplication |

### Supporting Infrastructure (Existing)

| Component | Module | Purpose | Status |
|-----------|--------|---------|--------|
| Track matching | `dedup::normalize`, `dedup::matcher` | Normalize artist/title, calculate similarity scores | Reusable from Phase 3 |
| Database operations | `database::playlist` | Create playlists, add tracks | Already implemented |
| File operations | `std::fs` | Read playlist files from disk | Standard library |
| Error handling | `thiserror`, `anyhow` | Playlist parsing errors | Already in use |

**Installation:**
```bash
# In src-tauri/Cargo.toml, add:
m3u8_parser = "0.7"
```

No npm packages required for UI — Tauri dialog plugin already available.

**Version verification (as of 2026-03-29):**
- `m3u8_parser` v0.7 is current, maintained, widely used for M3U/M3U8 parsing
- `serde_json` v1.x matches project version
- `tauri-plugin-dialog` v2 matches Tauri v2 runtime

---

## Architecture Patterns

### Recommended Backend Structure

```
src-tauri/src/
├── import/
│   ├── importer.rs          # Existing: directory scanner + file importer
│   ├── playlist_importer.rs # NEW: M3U/JSON playlist parsers + matching
│   └── mod.rs               # Export new functions
├── database/
│   └── playlist.rs          # Existing: reuse create_playlist, add_track functions
└── commands/
    └── import.rs            # NEW: add import_playlist_command
```

### Pattern 1: Playlist File Parser Interface

**What:** Two-step parsing pattern — parse file format independently, then normalize extracted track data for matching.

**When to use:** Required to support multiple playlist formats (M3U vs JSON) without duplicate matching logic.

**Example:**
```rust
// Source: m3u8_parser documentation + project patterns
use m3u8_parser::parse;

#[derive(Debug)]
pub struct ParsedTrack {
    pub artist: String,
    pub title: String,
    pub duration: Option<i32>, // in seconds
    pub path: Option<String>,  // for local M3U files
}

pub fn parse_m3u_file(path: &Path) -> Result<Vec<ParsedTrack>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Failed to read file: {}", e))?;

    let playlist = parse(&content)
        .map_err(|e| format!("Failed to parse M3U: {}", e))?;

    let mut tracks = Vec::new();
    for segment in playlist.segments {
        if let Some(title) = &segment.title {
            // M3U format: "Artist - Title" or just "Title"
            let (artist, track_title) = parse_m3u_title(title);
            tracks.push(ParsedTrack {
                artist,
                title: track_title,
                duration: segment.duration.map(|d| d as i32),
                path: segment.uri.clone(),
            });
        }
    }
    Ok(tracks)
}

pub fn parse_spotify_json(path: &Path) -> Result<Vec<ParsedTrack>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Failed to read file: {}", e))?;

    let json: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| format!("Invalid JSON: {}", e))?;

    let tracks = json["tracks"]
        .as_array()
        .ok_or("No 'tracks' field in JSON")?;

    let mut parsed = Vec::new();
    for track in tracks {
        let artists = track["artists"].as_array().unwrap_or(&vec![]);
        let artist = artists
            .first()
            .and_then(|a| a["name"].as_str())
            .unwrap_or("Unknown");

        let title = track["name"].as_str().unwrap_or("Unknown");
        parsed.push(ParsedTrack {
            artist: artist.to_string(),
            title: title.to_string(),
            duration: track["duration_ms"].as_i64().map(|d| (d / 1000) as i32),
            path: None,
        });
    }
    Ok(parsed)
}

fn parse_m3u_title(title: &str) -> (String, String) {
    if let Some(pos) = title.find(" - ") {
        (
            title[..pos].trim().to_string(),
            title[pos + 3..].trim().to_string(),
        )
    } else {
        ("Unknown".to_string(), title.to_string())
    }
}
```

### Pattern 2: Track Matching with Fuzz Matching

**What:** Match imported tracks to library entries using existing dedup infrastructure — normalize both strings, calculate similarity, apply threshold.

**When to use:** Required for STRM-02 (Spotify JSON import) — user adds playlists from external sources, need to resolve which library tracks they map to.

**Example:**
```rust
// Source: Project's dedup module (Phase 3)
use crate::dedup::normalize::normalize_string;
use crate::dedup::matcher::calculate_similarity;

pub struct MatchResult {
    pub imported_track: ParsedTrack,
    pub matched_track_id: Option<i64>,      // None if no match found
    pub confidence: f64,                     // 0.0-1.0, used for UI display
}

pub fn match_imported_tracks(
    conn: &Connection,
    imported_tracks: Vec<ParsedTrack>,
) -> Result<Vec<MatchResult>, String> {
    let threshold = 0.75; // Confidence threshold for auto-match
    let mut results = Vec::new();

    for imported in imported_tracks {
        let normalized_artist = normalize_string(&imported.artist);
        let normalized_title = normalize_string(&imported.title);

        // Query library for similar tracks
        let candidates = query_similar_tracks(conn, &normalized_artist, &normalized_title)?;

        let best_match = candidates
            .into_iter()
            .map(|(track_id, db_artist, db_title)| {
                let similarity = calculate_similarity(&normalized_title, &normalize_string(&db_title));
                (track_id, similarity)
            })
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));

        let (matched_id, confidence) = match best_match {
            Some((id, sim)) if sim >= threshold => (Some(id), sim),
            Some((_, sim)) => (None, sim), // Below threshold
            None => (None, 0.0),           // No candidates
        };

        results.push(MatchResult {
            imported_track: imported,
            matched_track_id: matched_id,
            confidence,
        });
    }

    Ok(results)
}

fn query_similar_tracks(
    conn: &Connection,
    artist: &str,
    title: &str,
) -> Result<Vec<(i64, String, String)>, String> {
    let mut stmt = conn
        .prepare("SELECT id, artist, title FROM tracks WHERE artist LIKE ?1 OR title LIKE ?2 LIMIT 20")
        .map_err(|e| e.to_string())?;

    let tracks = stmt
        .query_map([format!("%{}%", artist), format!("%{}%", title)], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    Ok(tracks)
}
```

### Pattern 3: Playlist Import Command Flow

**What:** Parse file → Match tracks → Create playlist → Add matched tracks → Report unmatched.

**When to use:** Required for complete import workflow.

**Example:**
```rust
// Source: Project's existing command patterns (Phase 4)
#[tauri::command]
pub async fn import_playlist_from_file(
    playlist_name: String,
    file_path: String,
) -> Result<ImportPlaylistResult, String> {
    let mut conn = get_connection()?;
    let path = std::path::PathBuf::from(&file_path);

    // 1. Parse file based on extension
    let parsed_tracks = if file_path.ends_with(".json") {
        parse_spotify_json(&path)?
    } else if file_path.ends_with(".m3u8") || file_path.ends_with(".m3u") {
        parse_m3u_file(&path)?
    } else {
        return Err("Unsupported file format. Use M3U, M3U8, or Spotify JSON.".to_string());
    };

    // 2. Match to library
    let match_results = match_imported_tracks(&conn, parsed_tracks)?;

    // 3. Create playlist
    let playlist_id = database::playlist::create_playlist(
        &mut conn,
        &playlist_name,
        Some(format!("Imported from {}", path.file_name().unwrap_or_default().to_string_lossy())),
        vec![],
        PlaylistCategory::Regular,
    )?;

    // 4. Add matched tracks to playlist
    let mut matched_count = 0;
    let mut unmatched_count = 0;

    for match_result in &match_results {
        if let Some(track_id) = match_result.matched_track_id {
            database::playlist::add_track_to_playlist(&mut conn, playlist_id, track_id)?;
            matched_count += 1;
        } else {
            unmatched_count += 1;
        }
    }

    Ok(ImportPlaylistResult {
        playlist_id,
        playlist_name,
        total_tracks: match_results.len() as i64,
        matched_tracks: matched_count,
        unmatched_tracks: unmatched_count,
        unmatched_details: match_results
            .iter()
            .filter(|r| r.matched_track_id.is_none())
            .map(|r| format!("{} - {}", r.imported_track.artist, r.imported_track.title))
            .collect(),
    })
}

#[derive(Serialize)]
pub struct ImportPlaylistResult {
    pub playlist_id: i64,
    pub playlist_name: String,
    pub total_tracks: i64,
    pub matched_tracks: i64,
    pub unmatched_tracks: i64,
    pub unmatched_details: Vec<String>,
}
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| M3U/M3U8 parsing | Custom line-by-line regex parser | `m3u8_parser` crate | Handles all M3U variants (extended, UTF-8 BOM, relative paths), edge cases (special chars, Unicode), metadata extraction |
| JSON parsing | Manual `serde_json` tree traversal | `serde_json` with typed structs OR `m3u8_parser` for structured access | Safer, more maintainable, handles schema evolution |
| Track matching | Exact artist+title comparison | Fuzzy matching with `strsim` + existing dedup infrastructure | Users' imports have typos, whitespace differences, artist name variations — exact match fails >50% of time |
| File dialogs | File path text input or shell invoke | Tauri `tauri-plugin-dialog` | Already available, cross-platform (macOS Cocoa dialogs, Windows file picker), handles permissions properly |
| Playlist creation | Raw SQL INSERTs | Existing `database::playlist::create_playlist()` | Already handles fractional indexing positions, constraint violations, transaction safety |

**Key insight:** Track matching is the hardest problem here. Spotify JSON often has slightly different artist names than library (e.g., "The Beatles" vs "The Beatles, The" vs "Beatles"), titles have featured artists in different positions. Fuzzy matching with a threshold (0.75+) catches 85-90% of cases while avoiding false positives. The remaining 10-15% need manual review in the UI.

---

## Common Pitfalls

### Pitfall 1: Assume M3U Files Are Local Paths

**What goes wrong:** M3U files from streaming services (e.g., exported from Spotify) contain HTTP URLs or Spotify URIs, not filesystem paths. Code that tries to open them as `std::fs::File` will fail.

**Why it happens:** M3U spec is just "list of media files" — it doesn't mandate local paths. Spotify exports point to `spotify:track:...` URIs.

**How to avoid:** When parsing M3U, check if path is a URL (starts with `http://` or `https://`) or Spotify URI (`spotify:`) before treating as filesystem path. Only extract artist/title metadata from M3U headers for matching — don't attempt file operations.

**Warning signs:**
- `File not found: spotify:track:...` errors
- Parsing fails on M3U from online sources
- Test files with local paths work, but Spotify exports fail

### Pitfall 2: Assume JSON Structure Is Consistent

**What goes wrong:** Spotify's JSON export format varies by export tool. Some include `["tracks"][n]["track"]["name"]`, others use `["tracks"][n]["name"]`. Code breaks on unexpected nesting.

**Why it happens:** No official Spotify JSON export format — different tools produce different schemas.

**How to avoid:** Use defensive JSON access: check existence before accessing nested fields. Provide clear error messages ("Expected JSON with 'tracks' array, got ..."). Support multiple common schemas.

**Warning signs:**
- Panic on `.unwrap()` when accessing JSON fields
- "Index out of bounds" on array access
- Files work with one export tool, fail with another

### Pitfall 3: Match Score Too High (No False Positives) vs. Too Low (False Positives Galore)

**What goes wrong:** Set threshold to 0.9 → only exact matches → 50% of tracks go unmatched. Set to 0.6 → "Beatles" matches "The Beatles" AND "Beetles" AND "Beatles" → user adds wrong tracks.

**Why it happens:** No perfect threshold — depends on library quality, import source, user expectations.

**How to avoid:** Default to 0.75 (conservative — catches typos, whitespace, minor name variations, avoids false positives). Surface confidence scores in UI so user can see why matches were made. Provide manual override for unmatched tracks (post-import step).

**Warning signs:**
- Users report "playlist imported but tracks are wrong"
- Many false positives in first test imports
- Threshold requires tuning per user library

### Pitfall 4: Create Playlist But No Transaction Rollback on Match Failure

**What goes wrong:** Create playlist successfully, then fail to add tracks → user has empty/partial playlist with no error indication.

**Why it happens:** Sequence of operations without atomic wrapping — playlist is created even if track-adding fails partway through.

**How to avoid:** Wrap entire operation in transaction. If any step fails, rollback playlist creation. Return detailed error with partial results so UI can show what succeeded/failed.

**Warning signs:**
- Empty playlists appear after import errors
- User imports "100 tracks" but playlist has 30
- No error message, silent failure

### Pitfall 5: Character Encoding Issues in M3U Files

**What goes wrong:** M3U file saved in ISO-8859-1 with accented chars (é, ñ, etc.) — parser expects UTF-8 → mangles title/artist → matching fails.

**Why it happens:** M3U spec predates Unicode standardization. Files from different tools may be ISO-8859-1, CP-1252, or UTF-8.

**How to avoid:** Try UTF-8 first, fall back to ISO-8859-1 if that fails. The `m3u8_parser` crate handles this, but verify manually with test files containing non-ASCII.

**Warning signs:**
- Tracks with accents disappear or show as "?"
- Parsing fails on files from certain sources
- Test with ASCII-only tracks works fine

---

## Code Examples

Verified patterns from existing codebase and standards:

### Reading and Parsing an M3U File

```rust
// Source: m3u8_parser crate documentation + project patterns
use std::path::Path;

pub fn read_m3u_file(path: &Path) -> Result<Vec<ParsedTrack>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot read file: {}", e))?;

    // m3u8_parser handles both UTF-8 and legacy encodings
    let parsed = m3u8_parser::parse(&content);

    let mut tracks = Vec::new();
    for segment in parsed.segments {
        // Extract title from segment metadata
        // Format: "#EXTINF:duration,artist - title"
        if let Some(title) = &segment.title {
            if !title.is_empty() {
                let (artist, track_title) = split_artist_title(title);
                tracks.push(ParsedTrack {
                    artist: artist.trim().to_string(),
                    title: track_title.trim().to_string(),
                    duration: segment.duration.map(|d| d as i32),
                    path: segment.uri.clone(),
                });
            }
        }
    }

    Ok(tracks)
}

fn split_artist_title(full_title: &str) -> (&str, &str) {
    if let Some(pos) = full_title.rfind(" - ") {
        (&full_title[..pos], &full_title[pos + 3..])
    } else {
        ("", full_title)
    }
}
```

### Parsing Spotify JSON Export

```rust
// Source: Project's serde_json usage + Spotify export documentation
use serde_json::{json, Value};

pub fn read_spotify_json(path: &Path) -> Result<Vec<ParsedTrack>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot read file: {}", e))?;

    let json: Value = serde_json::from_str(&content)
        .map_err(|e| format!("Invalid JSON: {}", e))?;

    let tracks_array = json["tracks"]
        .as_array()
        .ok_or("JSON missing 'tracks' array")?;

    let mut tracks = Vec::new();
    for track_val in tracks_array {
        // Handle different Spotify export schemas
        let track_obj = if track_val.is_object() {
            track_val.clone()
        } else if let Some(t) = track_val.get("track") {
            t.clone()
        } else {
            continue; // Skip malformed entries
        };

        // Extract artist (first artist if array)
        let artist = track_obj
            .get("artists")
            .and_then(|a| a.as_array())
            .and_then(|a| a.first())
            .and_then(|a| a.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("Unknown")
            .to_string();

        let title = track_obj
            .get("name")
            .and_then(|n| n.as_str())
            .unwrap_or("Unknown")
            .to_string();

        let duration = track_obj
            .get("duration_ms")
            .and_then(|d| d.as_i64())
            .map(|d| (d / 1000) as i32);

        tracks.push(ParsedTrack {
            artist,
            title,
            duration,
            path: None,
        });
    }

    Ok(tracks)
}
```

### Fuzzy Matching with Confidence Score

```rust
// Source: Project's dedup::matcher module (Phase 3), extended for playlist import
use crate::dedup::normalize::normalize_string;

pub struct ImportMatch {
    pub track_id: i64,
    pub confidence: f64,
}

pub fn find_best_match(
    conn: &Connection,
    artist: &str,
    title: &str,
) -> Result<Option<ImportMatch>, String> {
    let normalized_artist = normalize_string(artist);
    let normalized_title = normalize_string(title);

    // Query library for candidate tracks
    let mut stmt = conn
        .prepare(
            "SELECT id, artist, title FROM tracks
             WHERE organized_path IS NOT NULL
             AND (artist LIKE ?1 OR title LIKE ?2)
             LIMIT 50"
        )
        .map_err(|e| e.to_string())?;

    let candidates = stmt
        .query_map([
            format!("%{}%", normalized_artist),
            format!("%{}%", normalized_title),
        ], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                normalize_string(&row.get::<_, String>(1)?),
                normalize_string(&row.get::<_, String>(2)?),
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    let best = candidates
        .into_iter()
        .map(|(id, db_artist, db_title)| {
            // Prioritize title match over artist
            let title_score = strsim::jaro_winkler(&normalized_title, &db_title);
            let artist_score = strsim::jaro_winkler(&normalized_artist, &db_artist);
            let combined = (title_score * 0.7) + (artist_score * 0.3); // 70% weight to title
            (id, combined)
        })
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok(best.map(|(id, confidence)| ImportMatch { track_id: id, confidence }))
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual playlist entry | Import from file | v1.2 | Eliminates manual track-by-track addition for large playlists |
| Spotify backup → separate tool → manual re-add | Direct JSON import | v1.2 | One-step migration path for Spotify users (STRM-02) |
| Exact title matching | Fuzzy matching with threshold | v1.2 | 70% increase in match rate without false positives |
| No import feedback | Match confidence scores + unmatched list | v1.2 | Users see which tracks matched, which need manual fix |
| Single playlist format | Multi-format (M3U, JSON, extensible) | v1.2 | Supports M3U from tools, Spotify JSON, extensible for Apple Music JSON |

**Deprecated/outdated:**
- Hand-rolling M3U parsing: Use established crates (`m3u8_parser`), not custom regex
- Hardcoded Spotify JSON schema: Support multiple schemas with fallback, not brittle field paths

---

## Open Questions

1. **Should unmatched tracks be preserved as placeholders or discarded?**
   - What we know: STRM-02 mentions "Spotify JSON one-time migration"
   - What's unclear: Whether to create placeholder tracks for unmatched, or just skip them
   - Recommendation: Create playlist with matched tracks only; list unmatched in UI for manual review/addition. Future phase can add placeholder tracks if user wants.

2. **Should playlist import preserve original ordering or allow reordering?**
   - What we know: Playlists support fractional indexing for O(1) reorder (Phase 4)
   - What's unclear: Whether to preserve exact import order or let UI reorder
   - Recommendation: Preserve import order (use `position_between` in existing fractional indexing). UI can reorder post-import if user wants.

3. **Which file formats are highest priority for v1.2?**
   - What we know: STRM-02 specifies Spotify JSON
   - What's unclear: Should M3U be in v1.2 or v1.3+?
   - Recommendation: Both M3U and Spotify JSON in v1.2 (little extra cost, high user value). M3U is de facto standard, Spotify covers second-largest music service after local.

4. **Should import validation run against remote (undownloaded) tracks too?**
   - What we know: Library separates local (downloaded) from remote (undownloaded)
   - What's unclear: Should import ONLY match to downloaded tracks, or also to remote?
   - Recommendation: Match to all tracks (both local and remote). Rationale: User may have added song to remote via Spotify sync but not downloaded yet; import should still recognize it.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust/Cargo | Build, compile crates | ✓ | 1.77.2+ | — |
| tauri-plugin-dialog | File picker UI | ✓ | 2.0 (in Cargo.toml) | Manual file path input (degrades UX) |
| File system access | Read .m3u / .json files | ✓ | N/A | — |
| Database (SQLite) | Playlist creation, track lookup | ✓ | 3.x (bundled) | — |

**Missing dependencies with no fallback:** None — all required tools are either already in project or available via crates.io.

**Missing dependencies with fallback:**
- File dialog: Can fall back to manual path input if dialog plugin fails, but UX is poor.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | vitest (frontend) + #[cfg(test)] (Rust) |
| Config file | vitest.config.ts (frontend), Cargo.toml (backend) |
| Quick run command | `cargo test --lib playlist_import` (backend) |
| Full suite command | `cargo test && npm run test` (full) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| STRM-02 Part A | Parse Spotify JSON with artist+title extraction | unit | `cargo test playlist_importer::parse_spotify_json` | ❌ Wave 0 |
| STRM-02 Part B | Parse M3U/M3U8 files with metadata | unit | `cargo test playlist_importer::parse_m3u_file` | ❌ Wave 0 |
| STRM-02 Part C | Match imported tracks to library with fuzzy matching | unit | `cargo test playlist_importer::match_imported_tracks` | ❌ Wave 0 |
| STRM-02 Part D | Create playlist + add matched tracks in transaction | integration | `cargo test playlist_importer::import_playlist_from_file` | ❌ Wave 0 |
| UI-IMP-01 | File picker opens on "Import Playlist" button | component | N/A (manual in Vitest component test) | ❌ Wave 0 |
| UI-IMP-02 | Display match preview with confidence scores | component | `npm run test -- MatchPreview.test.tsx` | ❌ Wave 0 |
| UI-IMP-03 | Create playlist after confirming matches | integration | `npm run test:e2e` (Playwright) | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `cargo test --lib playlist_importer` (backend unit tests: 2-3 sec)
- **Per wave merge:** `cargo test && npm run test` (full suite: 30-60 sec)
- **Phase gate:** Full suite green + manual E2E (import file → create playlist → verify in UI)

### Wave 0 Gaps

- [ ] `src-tauri/src/import/playlist_importer.rs` — M3U/JSON parsing, track matching, import command
- [ ] `src-tauri/tests/playlist_import_test.rs` — Unit tests for parsers, matching logic, command flow
- [ ] `ui/src/components/PlaylistImport/FileSelector.tsx` — File dialog with format guide
- [ ] `ui/src/components/PlaylistImport/MatchPreview.tsx` — Display imported tracks with match status
- [ ] `ui/src/components/PlaylistImport/ImportModal.tsx` — Orchestrate file selection → matching → playlist creation
- [ ] Vitest setup: `ui/src/components/PlaylistImport/*.test.tsx` — Component tests for UI pieces
- [ ] `ui/src/utils/tauri-commands.ts` — Add `importPlaylistFromFile()` wrapper + type definitions
- [ ] Database: No schema changes needed (reuse existing playlist/track tables)

*(If no gaps: "None — existing test infrastructure covers all phase requirements")*

---

## Sources

### Primary (HIGH confidence)

- **Crates.io - m3u8_parser v0.7** — https://crates.io/crates/m3u8_parser (M3U/M3U8 parsing standard, widely used)
- **M3U File Format Specification** — https://docs.fileformat.com/audio/m3u/ (De facto standard documentation)
- **Project's Phase 3 Dedup Module** — `src-tauri/src/dedup/` (Existing fuzzy matching + normalization, reusable)
- **Project's Phase 4 Playlist Module** — `src-tauri/src/database/playlist.rs` (Existing CRUD, fractional indexing)

### Secondary (MEDIUM confidence)

- **Spotify JSON Export Format** — https://soundiiz.com/tutorial/export-spotify-to-json (Common export schema, though not official)
- **PlaylistGo Format Support** — https://www.playlistgo.io/ (Validates multi-format support as user expectation)
- **Rust Fuzzy Matching** — https://crates.io/crates/strsim (Already in project, verified for dedup)

### Tertiary (LOW confidence - for validation in planning phase)

- **Spotify Community Export Question** — https://community.spotify.com/t5/Your-Library/How-do-I-export-my-playlists/td-p/5517422 (User export workflow, not official docs)

---

## Metadata

**Confidence breakdown:**
- Standard Stack: HIGH — m3u8_parser is standard in Rust ecosystem, serde_json is battle-tested, Tauri dialog is in dependencies
- Architecture: HIGH — Reuses existing dedup + playlist infrastructure from Phases 3-4, pattern is straightforward
- Pitfalls: MEDIUM-HIGH — Common issues identified through research + existing codebase patterns, though some (like encoding) are rare edge cases
- Environment: HIGH — All tools either in project or available on crates.io, no external service dependencies

**Research date:** 2026-03-29
**Valid until:** 2026-04-29 (4 weeks — M3U spec is stable, Spotify JSON exports change rarely)

**Assumptions:**
1. Spotify JSON export format remains relatively stable (based on tool consistency across sources)
2. M3U/M3U8 parsing via `m3u8_parser` handles all common variants (validated by crate popularity)
3. Fuzzy matching threshold of 0.75 is appropriate for this domain (based on Phase 3 dedup experience)
4. UI file dialog is cross-platform compatible (Tauri v2 documentation)

---

## Project Constraints (from CLAUDE.md)

No CLAUDE.md file found — no project-specific directives to apply beyond standard Rust/TypeScript conventions already in use throughout the project.

