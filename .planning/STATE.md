# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 9 - Library/Remote Separation

## Current Position

Phase: 9 of 11 (Library/Remote Separation)
Plan: 1 of TBD in current phase
Status: In progress
Last activity: 2026-02-07 - Completed 09-01-PLAN.md

Progress: [████████░░░░░░░░░░░] 44/TBD total plans (v1.0: 39/39, v1.1: 5/TBD)

## Performance Metrics

**Velocity (v1.0):**
- Total plans completed: 39
- Total execution time: ~3 days
- Phases completed: 7

**Current Milestone (v1.1):**
- Plans completed: 5
- Average duration: 15 min
- Total execution time: ~75 min

*Updated after each plan completion*

## Tech Stack

**Backend (Rust):**
- rusqlite — SQLite database
- lofty — Audio metadata extraction
- tantivy — Full-text search
- symphonia — Audio decoding
- rusty-chromaprint — Acoustic fingerprinting
- ebur128 — ReplayGain analysis
- tokio — Async runtime
- uuid — Library ID generation (Phase 8)
- notify — Filesystem watching for mount detection (Phase 8)

**Frontend (Tauri + Web):**
- Tauri v2 — Desktop app framework
- TypeScript + React — UI components
- TanStack Table — Virtualized data grid
- shadcn/ui — Component library

**External tools:**
- ffmpeg — Audio transcoding
- yt-dlp — YouTube downloads
- scdl — SoundCloud downloads

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- v1.0: Rust + Tauri stack for performance and reliability
- v1.0: 248kbps AAC target for device copies
- v1.0: Fractional indexing for O(1) playlist reorder
- v1.1: Library = local files only, Remote = undownloaded staging (architectural shift)
- Phase 8-01: Store paths relative to library root for portability
- Phase 8-01: Marker file is visible mlm-library.json, not hidden dotfile
- Phase 8-02: Use notify crate's /Volumes watching instead of low-level fsevent bindings
- Phase 8-02: Mount detection runs in background thread, never blocks app startup
- Phase 9-01: download_status column uses NULL for never-downloaded, ISO 8601 timestamp for audit
- Phase 9-01: Remote view uses organized_path IS NULL for filtering (not download_status)
- Phase 9-01: INNER JOIN with track_sources ensures remote tracks have streaming source associations
- Phase 9-01: Partial index idx_organized_path_null optimizes remote view queries

### v1.1 Scope Decisions

- Library/Remote separation is core architectural fix
- SSD-based library required (external drive)
- Context menu responsiveness included
- Similar songs grouping deferred to v1.2
- Spotify JSON migration deferred to v1.2
- SoundCloud playlists deferred to v1.2

### Pending Todos

None yet.

### Blockers/Concerns

**From v1.0 user testing:**
- Hardcoded "default" user_id for source creation (needs proper user management)
- SoundCloud playlists not syncing (deferred to v1.2)

**v1.1 scope:**
- Library/Remote separation requires database refactor (track source vs. library state)
- Drive detection needs platform-specific logic (macOS/Windows/Linux)
- Context menu performance may need UI architecture changes

## Session Continuity

Last session: 2026-02-07
Stopped at: Completed 09-01-PLAN.md
Resume file: None

---
*Last updated: 2026-02-07 after 09-01 plan completion*
