# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 8 - Library Configuration & Drive Detection

## Current Position

Phase: 8 of 11 (Library Configuration & Drive Detection)
Plan: 2 of 4 in current phase
Status: In progress
Last activity: 2026-02-07 - Completed 08-02-PLAN.md

Progress: [███████░░░░░░░░░░░░] 41/TBD total plans (v1.0: 39/39, v1.1: 2/TBD)

## Performance Metrics

**Velocity (v1.0):**
- Total plans completed: 39
- Total execution time: ~3 days
- Phases completed: 7

**Current Milestone (v1.1):**
- Plans completed: 2
- Average duration: 10 min
- Total execution time: 20 min

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
Stopped at: Completed 08-02-PLAN.md (Mount Detection)
Resume file: None

---
*Last updated: 2026-02-07 after 08-02 plan completion*
