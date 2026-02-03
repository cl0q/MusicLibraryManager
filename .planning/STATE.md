# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-03)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 1 - Library Foundation (Rust rewrite)

## Current Position

Phase: 1 of 7 (Library Foundation)
Plan: 4 of 5 in current phase
Status: In progress
Last activity: 2026-02-03 — Completed 01-04-PLAN.md (Full-Text Search)

Progress: [████████░░] 80%

## Tech Stack Change

**Previous:** Python with Mutagen, Whoosh, RapidFuzz
**Current:** Rust + Tauri with lofty, tantivy, strsim

The Python implementation has been archived to `_archive/python/`.
New project structure:
- `src-tauri/` — Rust backend
- `ui/` — React + TypeScript + Tailwind frontend

## Performance Metrics

**Velocity:**
- Total plans completed: 4
- Average duration: 4m 58s
- Total execution time: 0.33 hours

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **Rust for core logic** — Performance, reliability, single binary (2026-02-03)
- **Tauri for UI** — Web UI flexibility + Rust backend, native webview (2026-02-03)
- **Single tracks table for Phase 1** — Albums/Artists normalization deferred to Phase 7 (2026-02-03)
- **&mut Connection for transactions** — rusqlite transaction() requires mutable borrow (2026-02-03)
- **Lofty ItemKey for album artist** — Cross-format extraction via ItemKey::AlbumArtist (2026-02-03)
- **Manual reserved name prefix** — windows:false + manual _CON prefix, sanitize-filename removes names otherwise (2026-02-03)
- **Continue scanning on subdir errors** — Warnings printed but doesn't halt scan (2026-02-03)
- **50-file batch size** — Matches Python implementation for incremental commits (2026-02-03)
- **Database path hardcoded for now** — `music_library.db` in cwd, Phase 6 makes configurable (2026-02-03)
- **Two-pass search** — Database LIKE for candidates, fuzzy scoring for ranking (2026-02-03)
- **Multi-strategy scoring** — Jaro-Winkler + Levenshtein + token matching for different error types (2026-02-03)
- **0.75 fuzzy threshold** — Balances precision/recall, relaxed from Python's 0.80 for Jaro-Winkler (2026-02-03)
- 248kbps AAC target (matches SoundCloud Go+ quality)
- Rockbox for iPod (enables direct filesystem sync)
- YouTube as fallback (acceptable quality tradeoff)

### Learnings from Python Implementation

Preserved context from prior Python implementation (archived):

**Database patterns:**
- Context manager pattern for connections with foreign key enforcement
- Transaction-wrapped writes for atomicity
- Format quality hierarchy: lossy < lossless, then by bitrate

**Sanitization patterns:**
- Underscore prefix for Windows reserved names (_CON not CON_)
- Underscore replacement for invalid chars (readable output)
- Return 'unknown' placeholder for empty/invalid input

**Import patterns:**
- Metadata fallbacks: album_artist -> artist -> "Various Artists"
- Continue-on-error: collect failures and report at end
- Reference-in-place model: store original paths, no file copying

**Duplicate detection patterns:**
- File ID as tiebreaker when timestamps equal
- AIFF in lossless formats alongside FLAC/WAV/ALAC
- Empty strings not equal for matching (indicates missing metadata)

**Search patterns:**
- token_set_ratio + partial_ratio for typo/substring handling
- Per-field scoring with max() for accuracy

### Pending Todos

None yet.

### Blockers/Concerns

**Phase 1 (Library Foundation):**
- ~~lofty API differs from Mutagen~~ RESOLVED: Using ItemKey::AlbumArtist for album artist
- ~~tantivy differs from Whoosh~~ RESOLVED: Tantivy indexer built, LIKE-based candidate retrieval for now

**Phase 2 (Download Infrastructure):**
- dabmusic.xyz API documentation gap (HIGH severity) — needs investigation during planning
- Must implement idempotency patterns to avoid "gambling whether runs work" problem

**Phase 3 (Multi-Source Aggregation):**
- Apple Music MusicKit authentication flow needs hands-on testing
- SoundCloud unofficial API carries breakage risk (MEDIUM-HIGH) — requires abstraction layer

**Phase 5 (Device Sync):**
- Rockbox M3U8 compatibility specifics unknown (relative vs absolute paths, encoding)
- Need actual iPod for filesystem testing (FAT32, character encoding edge cases)

## Session Continuity

Last session: 2026-02-03T15:27:00Z
Stopped at: Completed 01-04-PLAN.md
Resume file: None

---
*Last updated: 2026-02-03 after completing 01-04-PLAN.md*
