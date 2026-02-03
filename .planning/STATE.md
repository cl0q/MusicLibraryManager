# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-03)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 1 - Library Foundation (Rust rewrite)

## Current Position

Phase: 1 of 7 (Library Foundation)
Plan: 0 of ? in current phase
Status: Needs planning (Rust + Tauri rewrite)
Last activity: 2026-02-03 — Switched from Python to Rust + Tauri

Progress: [░░░░░░░░░░] 0%

## Tech Stack Change

**Previous:** Python with Mutagen, Whoosh, RapidFuzz
**Current:** Rust + Tauri with lofty, tantivy, strsim

The Python implementation has been archived to `_archive/python/`.
New project structure:
- `src-tauri/` — Rust backend
- `ui/` — React + TypeScript + Tailwind frontend

## Performance Metrics

**Velocity:**
- Total plans completed: 0 (reset for Rust rewrite)
- Average duration: N/A
- Total execution time: 0.0 hours

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **Rust for core logic** — Performance, reliability, single binary (2026-02-03)
- **Tauri for UI** — Web UI flexibility + Rust backend, native webview (2026-02-03)
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
- Need to replan for Rust ecosystem (different crates than Python libraries)
- lofty API differs from Mutagen — metadata extraction patterns will change
- tantivy differs from Whoosh — search indexing approach will change

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

Last session: 2026-02-03 (Rust + Tauri rewrite initiated)
Stopped at: Project structure created, ready for Phase 1 planning
Resume file: None

---
*Last updated: 2026-02-03 after Rust+Tauri rewrite decision*
