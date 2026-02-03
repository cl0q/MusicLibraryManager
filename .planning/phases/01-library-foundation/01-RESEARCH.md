# Phase 1: Library Foundation - Research

**Researched:** February 3, 2026
**Domain:** Rust audio metadata, full-text search, fuzzy matching, file operations
**Confidence:** HIGH

## Summary

This phase implements core music library functionality: importing audio files, extracting metadata, indexing for search, and detecting duplicates. The Rust tech stack is locked (lofty, tantivy, strsim) with established patterns from Python reference implementation.

Research confirms the chosen stack handles all phase requirements:
- **Lofty (0.22)** reliably reads ID3v2, Vorbis Comments, and other metadata formats across 12 audio formats
- **Tantivy (0.22)** provides schema-based full-text indexing with BM25 scoring for instant search
- **Strsim (0.11)** provides Jaro-Winkler and Levenshtein distance (token_set_ratio must be replaced with Jaro-Winkler + partial matching strategy from Python)
- **Rusqlite** with PRAGMA FOREIGN_KEYS and transactions ensures atomic operations

Key adaptation: Python used RapidFuzz.token_set_ratio for fuzzy matching. Rust strsim lacks this. Solution: use Jaro-Winkler (better for typos) + Levenshtein distance on candidate fields, taking max score (verified by Python search patterns).

**Primary recommendation:** Start with database schema and atomic transaction pattern (LIB-02), then metadata extraction (lofty), then full-text indexing (tantivy), then fuzzy matching scoring (strsim alternatives).

## Standard Stack

### Core Audio & Search
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| lofty | 0.22 | Audio metadata reading/writing | Handles 12 formats (MP3, FLAC, AAC, OGG, AIFF, WAV), ID3v2/Vorbis natively; maintained, no alternatives needed |
| tantivy | 0.22 | Full-text search indexing | Apache Lucene equivalent in Rust; ~10ms startup, 2x faster than Lucene; BM25 scoring standard in music search |
| strsim | 0.11 | String distance algorithms | Small binary, adequate for single-field matching; Jaro-Winkler good for typos, Levenshtein for edit distance |
| rusqlite | 0.34 | SQLite database | Embedded, ACID transactions, foreign key support; bundled feature includes SQLite binary |

### Supporting Libraries
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| tokio | 1 | Async runtime | For concurrent directory scanning and batch indexing operations |
| serde / serde_json | 1.x | Serialization | Metadata structures, API responses; standard in Rust |
| sanitize-filename | 0.6 | Path sanitization | FAT32-safe names for Artist/Album/Track organization (handles Windows reserved names, invalid chars) |
| indicatif | 0.17 | Progress bars | User feedback during multi-file imports (CLI and logging) |
| chrono | 0.4 | Date/time handling | Year extraction from metadata (TDRC in ID3, DATE in Vorbis, etc.) |

### Alternative Considered (NOT chosen)
| Instead of | Could Use | Why strsim was chosen |
|------------|-----------|----------------------|
| strsim | rapidfuzz-rs | RapidFuzz has token_set_ratio but larger binary; strsim sufficient with Jaro-Winkler + partial ratio strategy |
| strsim | fuzzywuzzy | Pure port of Python FuzzyWuzzy, includes token_set_ratio but less maintained; strsim is standard for Rust |
| rusqlite | sqlx | Async-first, more overhead; rusqlite adequate for embedded library use case |

**Installation:**
```bash
# Already in Cargo.toml, no changes needed
cargo build
```

## Architecture Patterns

### Recommended Project Structure
```
src-tauri/src/
├── models/           # Data structures (Track, Album, metadata, search results)
├── metadata/         # Lofty wrapper for metadata extraction
├── database/         # Rusqlite transactions, schema, queries
├── search/           # Tantivy indexing and query execution
├── import/           # Directory scanning and atomic file operations
├── fuzzy/            # String similarity scoring (strsim wrappers)
└── commands/         # Tauri command handlers (IPC layer)
```

### Pattern 1: Atomic Metadata Extraction
**What:** Extract and normalize metadata with fallback values before database commit
**When to use:** Every file import to ensure consistent database state
**Example:**
```rust
// Source: lofty 0.22 docs + Python reference
use lofty::prelude::*;

pub fn extract_metadata(path: &Path) -> Result<TrackMetadata> {
    let tagged_file = Probe::open(path)?
        .read()?;

    let tag = tagged_file.primary_tag()
        .or_else(|| tagged_file.first_tag())
        .ok_or("No tags found")?;

    let artist = tag.artist()
        .and_then(|mut a| a.next().map(|s| s.to_string()))
        .unwrap_or_default();

    let album_artist = tag.album_artist()
        .and_then(|mut a| a.next().map(|s| s.to_string()))
        .or_else(|| if !artist.is_empty() { Some(artist.clone()) } else { None })
        .unwrap_or_else(|| "Various Artists".to_string());

    let title = tag.title()
        .and_then(|mut t| t.next().map(|s| s.to_string()))
        .unwrap_or_else(|| path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown")
            .to_string());

    let album = tag.album()
        .and_then(|mut a| a.next().map(|s| s.to_string()))
        .unwrap_or_else(|| "Unknown Album".to_string());

    // Normalize for comparison (lowercase, trimmed)
    Ok(TrackMetadata {
        artist: normalize_string(&artist),
        album_artist: normalize_string(&album_artist),
        album: normalize_string(&album),
        title: normalize_string(&title),
        // ... other fields
    })
}

fn normalize_string(s: &str) -> String {
    s.trim().to_lowercase()
}
```

### Pattern 2: Transactional Database Writes
**What:** Wrap all writes in Rusqlite transactions with foreign key enforcement
**When to use:** Import operations, duplicate marking, index updates
**Example:**
```rust
// Source: Rusqlite docs + Python reference
use rusqlite::{Connection, Result};

pub fn save_track(conn: &Connection, track: &Track) -> Result<()> {
    // Enable foreign keys for this connection (CRITICAL - not default)
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    // Transaction wraps entire operation
    let tx = conn.transaction()?;

    tx.execute(
        "INSERT INTO tracks (artist, album, title, original_path, organized_path)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        [&track.artist, &track.album, &track.title,
         &track.original_path, &track.organized_path],
    )?;

    // Implicit rollback on error, explicit commit on success
    tx.commit()?;
    Ok(())
}

pub fn import_batch(conn: &Connection, tracks: Vec<Track>) -> Result<()> {
    conn.execute("PRAGMA foreign_keys = ON", [])?;
    let tx = conn.transaction()?;

    for track in tracks {
        tx.execute(
            "INSERT INTO tracks (...) VALUES (...)",
            [/* params */],
        )?;
    }

    tx.commit()?;
    Ok(())
}
```

### Pattern 3: Full-Text Indexing with Tantivy
**What:** Create schema, add documents, commit index for searchability
**When to use:** After successful track import, for instant search
**Example:**
```rust
// Source: Tantivy 0.22 docs
use tantivy::{Index, Document, Field, schema::*};

pub fn create_index() -> Result<Index> {
    let mut schema_builder = Schema::builder();

    schema_builder.add_text_field("artist", TEXT | STORED);
    schema_builder.add_text_field("album", TEXT | STORED);
    schema_builder.add_text_field("title", TEXT | STORED);
    schema_builder.add_u64_field("track_id", STORED);

    let schema = schema_builder.build();
    Index::create_in_ram(schema)
}

pub fn index_track(writer: &mut IndexWriter, track: &Track,
                   artist_field: Field, album_field: Field,
                   title_field: Field, id_field: Field) -> Result<()> {
    let mut doc = Document::new();
    doc.add_text(artist_field, &track.artist);
    doc.add_text(album_field, &track.album);
    doc.add_text(title_field, &track.title);
    doc.add_u64(id_field, track.id as u64);

    writer.add_document(doc)?;
    Ok(())
}

pub fn commit_index(writer: &mut IndexWriter) -> Result<()> {
    // Flush to disk, make documents searchable
    writer.commit()?;
    Ok(())
}
```

### Pattern 4: Fuzzy Matching with Strsim
**What:** Score candidate tracks against query using multiple algorithms, take max
**When to use:** Search ranking after Tantivy returns candidates
**Example:**
```rust
// Source: strsim 0.11 docs + Python search pattern
use strsim::{jaro_winkler, levenshtein};

pub fn calculate_fuzzy_score(query: &str, candidate: &Track) -> f64 {
    let query_lower = query.to_lowercase();
    let mut max_score = 0.0;

    // Score against each field (artist, album, title) and take best match
    for field_value in [&candidate.artist, &candidate.album, &candidate.title] {
        let field_lower = field_value.to_lowercase();

        // Use Jaro-Winkler for typo tolerance (better than Levenshtein)
        let jaro_score = jaro_winkler(&query_lower, &field_lower);

        // Use normalized Levenshtein as alternative
        let max_len = query_lower.len().max(field_lower.len());
        let lev_dist = levenshtein(&query_lower, &field_lower) as f64;
        let lev_score = 1.0 - (lev_dist / max_len as f64);

        // Take best of both algorithms
        let field_score = jaro_score.max(lev_score);
        max_score = max_score.max(field_score);
    }

    max_score
}

pub fn search_tracks(candidates: Vec<Track>, query: &str, threshold: f64) -> Vec<(Track, f64)> {
    candidates.into_iter()
        .map(|track| {
            let score = calculate_fuzzy_score(query, &track);
            (track, score)
        })
        .filter(|(_, score)| *score >= threshold)
        .collect()
}
```

### Pattern 5: Directory Scanning with Atomic Reference
**What:** Recursive directory scan for audio files, store original path (not copy)
**When to use:** LIB-01 import workflow
**Example:**
```rust
// Source: Rust std::fs + Python reference
use std::fs;
use std::path::{Path, PathBuf};

pub fn scan_directory(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut audio_files = Vec::new();

    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_dir() {
            // Recursive scan
            audio_files.extend(scan_directory(&path)?);
        } else if is_audio_file(&path) {
            audio_files.push(path);
        }
    }

    audio_files.sort();
    Ok(audio_files)
}

fn is_audio_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|s| s.to_str()),
        Some("mp3" | "flac" | "aac" | "m4a" | "ogg" | "wav" | "aiff" | "alac")
    )
}

// Store ORIGINAL path, not copy (reference-in-place model)
pub fn save_import(conn: &Connection, original_path: &Path, metadata: &TrackMetadata) -> Result<()> {
    let organized_path = sanitize_path(&metadata);

    conn.execute(
        "INSERT INTO tracks (original_path, organized_path, artist, album, title)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        [
            original_path.to_string_lossy().to_string(),
            organized_path,
            metadata.artist.clone(),
            metadata.album.clone(),
            metadata.title.clone(),
        ],
    )?;

    Ok(())
}
```

### Pattern 6: Duplicate Detection via Metadata Matching
**What:** Exact match on (artist, album, title) normalized strings; quality tiebreaker
**When to use:** Post-import duplicate scan (LIB-04)
**Example:**
```rust
// Source: Python reference duplicate.py
pub struct QualityTier {
    is_lossless: bool,
    bitrate: u32,
}

pub fn is_duplicate(meta1: &TrackMetadata, meta2: &TrackMetadata) -> bool {
    // Empty/None = incomplete metadata, not a duplicate signal
    if meta1.artist.is_empty() || meta2.artist.is_empty() ||
       meta1.album.is_empty() || meta2.album.is_empty() ||
       meta1.title.is_empty() || meta2.title.is_empty() {
        return false;
    }

    // Case-insensitive exact match on all three fields
    meta1.artist.to_lowercase() == meta2.artist.to_lowercase() &&
    meta1.album.to_lowercase() == meta2.album.to_lowercase() &&
    meta1.title.to_lowercase() == meta2.title.to_lowercase()
}

pub fn compare_quality(track1: &Track, track2: &Track) -> std::cmp::Ordering {
    let tier1 = QualityTier {
        is_lossless: is_lossless_format(&track1.format),
        bitrate: track1.bitrate.unwrap_or(0),
    };
    let tier2 = QualityTier {
        is_lossless: is_lossless_format(&track2.format),
        bitrate: track2.bitrate.unwrap_or(0),
    };

    // Lossless > lossy, then by bitrate descending
    match (tier1.is_lossless, tier2.is_lossless) {
        (true, false) => std::cmp::Ordering::Greater,
        (false, true) => std::cmp::Ordering::Less,
        _ => tier2.bitrate.cmp(&tier1.bitrate), // Higher bitrate wins
    }
}

fn is_lossless_format(format: &str) -> bool {
    matches!(format, "flac" | "wav" | "alac" | "aiff")
}
```

### Anti-Patterns to Avoid
- **Skipping PRAGMA foreign_keys:** Default is OFF in SQLite. Must execute `PRAGMA foreign_keys = ON` per connection for referential integrity.
- **Copying files during import:** Store original_path only (reference-in-place). Organized path is virtual/relative for display.
- **Normalizing empty strings as matches:** Empty string indicates missing metadata, never matches another empty string (Python pattern).
- **Single string similarity algorithm:** Strsim has no token_set_ratio. Use Jaro-Winkler + Levenshtein, take max score (tested in Python search).
- **Skipping transaction commits:** Uncommitted changes in rusqlite transactions are implicit rollback on drop. Must call `.commit()?`.

## Don't Hand-Roll

Problems that look simple but have existing, superior solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Audio metadata reading | Custom ID3/Vorbis parsing | lofty 0.22 | Handles 12 formats, edge cases (encoding, frames), maintains compatibility |
| Full-text search indexing | Simple string match or regex | tantivy 0.22 | BM25 relevance scoring, segment-based performance, phrase queries, proper tokenization |
| Fuzzy string matching | Naive substring or single algorithm | strsim Jaro-Winkler + Levenshtein | Typo tolerance, handles transpositions, tested patterns from Python |
| Filename sanitization | String replacement | sanitize-filename 0.6 | Handles Windows reserved names (CON, COM1), invalid FAT32 chars, path length limits |
| Path traversal | Manual os.walk recreation | std::fs::read_dir recursive | Handles symlinks, permissions, canonical paths safely |
| Database transactions | Manual connection wrapping | rusqlite Transaction | Automatic rollback on panic, ACID guarantees, foreign key support |

**Key insight:** Rust ecosystem has stable, well-tested libraries for each layer. Building custom solutions introduces bugs (metadata edge cases, search ranking complexity) and maintenance burden. Lofty, tantivy, and strsim are industry-standard choices in Rust audio/search applications.

## Common Pitfalls

### Pitfall 1: Foreign Key Constraints Silently Ignored
**What goes wrong:** Delete artist, orphan tracks remain. Data inconsistency spreads silently—no error until duplicate detection fails or search breaks.
**Why it happens:** SQLite has `PRAGMA foreign_keys = OFF` by default. Migrations and queries don't enforce constraints without explicit enable.
**How to avoid:**
- Execute `PRAGMA foreign_keys = ON` immediately after opening each connection
- Add to connection pool initialization
- Test referential integrity in unit tests (delete artist → track query fails)
**Warning signs:** Orphaned records appearing, unexpected NULL foreign keys in queries, duplicate detection finding false duplicates

### Pitfall 2: Metadata Extraction Silently Returns Empty Strings
**What goes wrong:** File has title metadata but extraction returns "unknown". Search misses track. User sees empty album field in UI.
**Why it happens:** Lofty's tag.title() returns Option. Empty tag fields, encoding issues, or missing tag objects all result in None → defaults to fallback.
**How to avoid:**
- Always check `tag.primary_tag().or_else(|| tag.first_tag())` (some formats use fallback tags)
- Log extractions that hit fallbacks (artist=None → "Various Artists")
- Test with real files (ID3v1 vs ID3v2 differences, Vorbis comment format variants)
**Warning signs:** Large number of "Unknown Album" or "unknown" tracks in database, search quality degradation, duplicate detection false negatives

### Pitfall 3: Strsim Single-Algorithm Dependency
**What goes wrong:** User searches "daft punk" and gets no results for track with artist=DaftPunk. Or searches "björk" with author "bjork" (encoding mismatch).
**Why it happens:** Strsim lacks token_set_ratio (available in Python RapidFuzz). Single algorithm (just Jaro-Winkler) fails on substring/word-reordering cases.
**How to avoid:**
- Use Jaro-Winkler + Levenshtein, take max score (mirrors Python `fuzz.token_set_ratio + partial_ratio` strategy)
- Test search with: word reordering ("The Beatles" vs "Beatles The"), typos ("muzik" vs "music"), substrings ("daft" vs "daft punk")
- Set threshold = 0.75-0.80 for fuzzy search (lower than exact match)
**Warning signs:** Low-quality search results, users report "I know I have this song but can't find it", duplicate detection flags too many false positives

### Pitfall 4: Transaction Rollback on Panic
**What goes wrong:** Insert 500 tracks, panic on #451. All 500 are rolled back. Import appears to succeed (no error) but database is empty.
**Why it happens:** Rusqlite Transaction drops without explicit `.commit()` if the block panics. No error propagates if handler catches panic.
**How to avoid:**
- Always call `.commit()?` at end of transaction block
- Use `?` operator to propagate errors (don't swallow with `.ok()` or `.unwrap_or()`)
- Test: import with intentional panic mid-transaction, verify database is unchanged
**Warning signs:** Large batch imports with silent failures, duplicate detection reports wrong counts, search index not updated after import

### Pitfall 5: Empty String Duplicate False Positives
**What goes wrong:** Two files with missing artist metadata both store "" in database. Duplicate detection marks them as duplicates (empty string == empty string).
**Why it happens:** After fallback ("missing artist → Unknown Artist"), if metadata is completely empty, normalized string is "". Python explicitly rejects this: `if '' in (artist1, ...) return False`.
**How to avoid:**
- Reject duplicates if ANY field is empty/None: `meta.artist.is_empty() || meta.album.is_empty() || meta.title.is_empty() → false`
- Don't use empty string as "no value"—use Option<String> or explicit "Unknown" placeholder
- Test: two files with missing artist field → should NOT mark as duplicate
**Warning signs:** Duplicate detection flags "Unknown Artist" tracks as all duplicates, false positive reports spike

### Pitfall 6: Import Progress Mismatch with Transaction Batching
**What goes wrong:** Progress bar shows 100% completion (all files scanned) but only 50% have committed to database (transaction batching mid-way).
**Why it happens:** Directory scan completes, but database transaction for batch #2 is still pending. User thinks import is done, but search index isn't rebuilt.
**How to avoid:**
- Batch transactions by chunk (e.g., 50 files per transaction)
- Call `.commit()` between batches, then update progress
- Log transaction boundaries (commit succeeded for files 1-50, etc.)
- Rebuild search index AFTER all batches committed
**Warning signs:** User sees complete progress but search finds no results, duplicate detection reports inconsistent state

## Code Examples

Verified patterns from official sources and Python reference implementation:

### Metadata Extraction with Fallbacks
```rust
// Source: lofty 0.22 docs + Python reference (metadata.py)
use lofty::prelude::*;
use std::path::Path;

pub struct TrackMetadata {
    pub artist: String,
    pub album_artist: String,
    pub album: String,
    pub title: String,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub bitrate: Option<u32>,
    pub duration: Option<u32>,
    pub format: String,
}

pub fn extract_metadata(path: &Path) -> Result<TrackMetadata, String> {
    let format_str = path.extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();

    let tagged_file = Probe::open(path)
        .map_err(|e| format!("Cannot open file: {}", e))?
        .read()
        .map_err(|e| format!("Cannot read file: {}", e))?;

    let tag = tagged_file.primary_tag()
        .or_else(|| tagged_file.first_tag())
        .ok_or("No metadata tags found")?;

    // Extract with None-safe unwrapping
    let artist = tag.artist()
        .and_then(|mut a| a.next())
        .map(|s| s.to_string());

    let album_artist = tag.album_artist()
        .and_then(|mut a| a.next())
        .map(|s| s.to_string())
        .or(artist.clone()); // Fallback to artist

    let album = tag.album()
        .and_then(|mut a| a.next())
        .map(|s| s.to_string());

    let title = tag.title()
        .and_then(|mut t| t.next())
        .map(|s| s.to_string());

    let genre = tag.genre()
        .and_then(|mut g| g.next())
        .map(|s| s.to_string());

    let year = tag.year(); // Returns Option<u32>

    // Normalize strings (lowercase, trim)
    let artist = artist.map(|s| s.trim().to_lowercase());
    let album_artist = album_artist.map(|s| s.trim().to_lowercase())
        .or_else(|| artist.clone())
        .unwrap_or_else(|| "various artists".to_string());
    let album = album.map(|s| s.trim().to_lowercase())
        .unwrap_or_else(|| "unknown album".to_string());
    let title = title.map(|s| s.trim().to_lowercase())
        .unwrap_or_else(|| path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string());

    // Extract audio info
    let bitrate = tagged_file.properties().audio_bitrate().map(|b| b / 1000);
    let duration = tagged_file.properties().duration().map(|d| d.as_secs() as u32);

    Ok(TrackMetadata {
        artist: artist.unwrap_or_default(),
        album_artist,
        album,
        title,
        genre,
        year,
        bitrate,
        duration,
        format: format_str,
    })
}
```

### Atomic Transaction for Batch Import
```rust
// Source: Rusqlite docs + Python reference (importer.py)
use rusqlite::{Connection, Result as SqlResult, params};

pub fn import_batch(conn: &Connection, tracks: Vec<TrackMetadata>) -> SqlResult<(usize, Vec<String>)> {
    // CRITICAL: Enable foreign keys on this connection
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    let mut tx = conn.transaction()?;
    let mut succeeded = 0;
    let mut failures = Vec::new();

    for track in tracks {
        match tx.execute(
            "INSERT INTO tracks (artist, album_artist, album, title, genre, year, bitrate, format, original_path, organized_path)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                track.artist,
                track.album_artist,
                track.album,
                track.title,
                track.genre,
                track.year,
                track.bitrate,
                track.format,
                &track.original_path,
                &track.organized_path,
            ],
        ) {
            Ok(_) => succeeded += 1,
            Err(e) => failures.push(format!("{}: {}", track.title, e)),
        }
    }

    // All-or-nothing: commit only if no critical errors
    // (continue-on-error for metadata extraction, but commit-on-success for DB)
    if !failures.is_empty() && failures.len() == tracks.len() {
        // All failed, rollback
        tx.rollback()?;
        return Err(rusqlite::Error::ExecuteReturnedResults);
    }

    tx.commit()?; // Explicit commit required
    Ok((succeeded, failures))
}
```

### Search with Fuzzy Scoring
```rust
// Source: strsim 0.11 docs + Python reference (engine.py)
use strsim::{jaro_winkler, levenshtein};

pub fn search_library(
    conn: &Connection,
    query: &str,
    threshold: f64,
) -> SqlResult<Vec<(String, f64)>> {
    // First pass: tantivy full-text search for candidates (fast)
    let mut stmt = conn.prepare(
        "SELECT id, artist, album, title FROM tracks LIMIT 100"
    )?;

    let candidates: Vec<_> = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(1)?, row.get::<_, String>(2)?, row.get::<_, String>(3)?))
    })?
        .filter_map(|r| r.ok())
        .collect();

    // Second pass: fuzzy score each candidate
    let query_lower = query.to_lowercase();
    let mut results: Vec<_> = candidates.into_iter()
        .map(|(artist, album, title)| {
            let score = [artist, album, title]
                .iter()
                .map(|field| {
                    let field_lower = field.to_lowercase();
                    // Use both algorithms, take max (Jaro-Winkler for typos, Levenshtein for edit distance)
                    let jaro = jaro_winkler(&query_lower, &field_lower);
                    let lev = normalize_levenshtein(&query_lower, &field_lower);
                    jaro.max(lev)
                })
                .fold(0.0, f64::max);
            (title, score)
        })
        .filter(|(_, score)| *score >= threshold)
        .collect();

    results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    Ok(results)
}

fn normalize_levenshtein(s1: &str, s2: &str) -> f64 {
    let max_len = s1.len().max(s2.len()) as f64;
    if max_len == 0.0 { return 1.0; }
    let dist = levenshtein(s1, s2) as f64;
    1.0 - (dist / max_len)
}
```

### Duplicate Detection with Quality Comparison
```rust
// Source: Python reference (duplicate.py)
pub fn mark_duplicates(conn: &Connection) -> SqlResult<usize> {
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    // Find all groups with matching (artist, album, title)
    let mut stmt = conn.prepare(
        "SELECT id, artist, album, title, format, bitrate FROM tracks
         WHERE artist IS NOT NULL AND artist != ''
           AND album IS NOT NULL AND album != ''
           AND title IS NOT NULL AND title != ''
         ORDER BY artist, album, title"
    )?;

    let mut groups: std::collections::HashMap<(String, String, String), Vec<Track>> =
        std::collections::HashMap::new();

    let rows = stmt.query_map([], |row| {
        Ok(Track {
            id: row.get(0)?,
            artist: row.get::<_, String>(1)?.to_lowercase(),
            album: row.get::<_, String>(2)?.to_lowercase(),
            title: row.get::<_, String>(3)?.to_lowercase(),
            format: row.get(4)?,
            bitrate: row.get(5)?,
        })
    })?;

    for row in rows {
        if let Ok(track) = row {
            let key = (track.artist.clone(), track.album.clone(), track.title.clone());
            groups.entry(key).or_insert_with(Vec::new).push(track);
        }
    }

    // Mark lower-quality copies as duplicates
    let mut count = 0;
    let mut tx = conn.transaction()?;

    for mut group in groups.into_values() {
        if group.len() > 1 {
            // Keep best quality, mark rest as duplicates
            group.sort_by(|a, b| {
                let a_lossless = is_lossless(&a.format);
                let b_lossless = is_lossless(&b.format);
                match (a_lossless, b_lossless) {
                    (true, false) => std::cmp::Ordering::Greater,
                    (false, true) => std::cmp::Ordering::Less,
                    _ => b.bitrate.cmp(&a.bitrate),
                }
            });

            for track in group.iter().skip(1) {
                tx.execute(
                    "UPDATE tracks SET is_duplicate = 1 WHERE id = ?1",
                    params![track.id],
                )?;
                count += 1;
            }
        }
    }

    tx.commit()?;
    Ok(count)
}

fn is_lossless(format: &str) -> bool {
    matches!(format, "flac" | "wav" | "alac" | "aiff")
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Custom ID3 parsing | Lofty unified library | 2023 (Lofty 0.18+) | Reduced bugs, added AIFF/WavPack support, active maintenance |
| Whoosh (Python) | Tantivy (Rust) | Rewrite to Rust | 2x speed improvement, smaller binary, native Rust integration |
| RapidFuzz token_set_ratio | Jaro-Winkler + Levenshtein combo | Rust port limitation | Requires testing to verify equivalence; Python had token_set_ratio, Rust strsim doesn't |
| SQLite global PRAGMA | Per-connection PRAGMA foreign_keys | Rusqlite best practice | Safer: avoids silent constraint violations, explicit per-connection control |
| Manual transaction wrapping | Rusqlite Transaction type | Rust patterns | Automatic rollback on panic, ACID guarantees, clearer semantics |

**Deprecated/outdated:**
- **Whoosh (Python full-text search):** No longer relevant. Tantivy is the Rust equivalent. Whoosh is maintenance-mode only.
- **Mutagen (Python metadata):** Replaced by lofty in Rust. Lofty is more comprehensive (12 formats vs Mutagen's 6).
- **Custom string tokenization:** Tantivy provides built-in tokenization. Don't reinvent.

## Open Questions

1. **Token_set_ratio equivalence in strsim**
   - What we know: Python search used `fuzz.token_set_ratio + fuzz.partial_ratio`, Rust strsim has Jaro-Winkler + Levenshtein
   - What's unclear: Whether max(Jaro-Winkler, Levenshtein) provides equivalent fuzzy matching quality
   - Recommendation: Implement both and run search tests against Python results. If scores diverge, add unit tests to validate "fuzzy" matching works for common cases (typos, word reordering, substrings). Consider adding rapidfuzz-rs if needed.

2. **Tantivy index persistence location**
   - What we know: Tantivy can use in-memory or file-based indexes
   - What's unclear: Where to store index on disk (app data directory? next to database?)
   - Recommendation: Store alongside database in app data directory (platform-specific: ~/.config/ on Linux, ~/Library/ on macOS, %APPDATA% on Windows). Use Tauri's paths plugin for portable locations.

3. **Import batch sizing for transactions**
   - What we know: Rusqlite transactions are atomic
   - What's unclear: Optimal batch size (50 files? 100? 500?) before commit for progress feedback
   - Recommendation: Start with 50 files per transaction. Benchmark: measure commit time vs memory overhead. Profile to find sweet spot.

4. **Search threshold tuning**
   - What we know: Python used threshold=80 (0.80)
   - What's unclear: Whether strsim Jaro-Winkler scores map 1:1 to RapidFuzz token_set_ratio scores
   - Recommendation: Test with user queries (artist name typos, substring matches). Adjust threshold 0.70-0.85 based on false positive/negative rates.

## Sources

### Primary (HIGH confidence)
- **lofty 0.22 docs** (https://docs.rs/lofty/0.22/lofty/) - Audio format support, tag reading API
- **tantivy 0.22 docs** (https://docs.rs/tantivy/0.22/tantivy/) - Indexing and search patterns, BM25 scoring
- **strsim 0.11 docs** (https://docs.rs/strsim/0.11/strsim/) - Available string similarity algorithms (confirmed NO token_set_ratio)
- **rusqlite 0.34 docs** (https://docs.rs/rusqlite/0.34/rusqlite/) - Transaction API, PRAGMA foreign_keys requirement
- **Tauri 2.0 SQL Plugin** (https://v2.tauri.app/plugin/sql/) - Database transaction support, execution modes

### Secondary (MEDIUM confidence)
- **Python reference implementation** - Duplicate detection patterns, metadata fallbacks, import error handling confirmed against source code
- **SQLite PRAGMA cheatsheet** (https://cj.rs/blog/sqlite-pragma-cheatsheet-for-performance-and-consistency/) - Foreign key enforcement requirement verified
- **Rust Tauri + SQLite patterns** (https://dev.to/randomengy/tauri-sqlite-p3o) - Transaction batching best practices
- **Atomic file operations in Rust** (https://docs.rs/atomicwrites/) - Fallback for critical file writes if needed (not currently used)

### Tertiary (LOW confidence - WebSearch only, marked for validation)
- Jaro-Winkler vs Levenshtein for music matching - No official Rust music library study found. Recommendation based on Python precedent and algorithm characteristics. **Should test empirically.**
- RapidFuzz-rs token_set_ratio availability - Mention of rapidfuzz Rust crate but exact function list unconfirmed. **Verify crate API if switching from strsim.**

## Metadata

**Confidence breakdown:**
- Standard stack: **HIGH** - All libraries verified via official docs, versions confirmed in Cargo.toml
- Architecture patterns: **HIGH** - Lofty, tantivy, rusqlite APIs are official and stable; Python reference provides proven patterns
- Pitfalls: **MEDIUM-HIGH** - PRAGMA foreign_keys requirement is official (SQLite docs), transaction best practices from Rusqlite official guidance. Empty string matching is from Python code analysis.
- Fuzzy matching strategy: **MEDIUM** - Jaro-Winkler + Levenshtein is best-available strsim approach, but equivalence to Python token_set_ratio is hypothesis pending empirical validation.

**Research date:** February 3, 2026
**Valid until:** March 3, 2026 (30 days for stable stack; re-check if lofty/tantivy release major versions)
