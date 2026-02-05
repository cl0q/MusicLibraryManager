# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Milestone v1.1 — Library Foundation & UX Polish

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-02-05 — Milestone v1.1 started

Progress: v1.0 complete (7 phases, 38 plans) | v1.1 requirements in progress

## Tech Stack

**Backend (Rust):**
- rusqlite — SQLite database
- lofty — Audio metadata extraction
- tantivy — Full-text search
- symphonia — Audio decoding
- rusty-chromaprint — Acoustic fingerprinting
- ebur128 — ReplayGain analysis
- tokio — Async runtime

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

All v1.0 decisions documented in PROJECT.md Key Decisions table with outcomes marked.

### v1.1 Scope Decisions

- Library/Remote separation is core architectural fix
- SSD-based library required (external drive)
- Context menu responsiveness included
- Similar songs grouping deferred
- Spotify JSON migration deferred
- SoundCloud playlists deferred

### Pending Todos

None — defining requirements.

### Blockers/Concerns

- Need to explore current codebase to understand what's implemented vs broken

## Session Continuity

Last session: 2026-02-05
Stopped at: Milestone v1.1 questioning complete, moving to requirements
Resume file: None

---
*Last updated: 2026-02-05 after v1.1 milestone start*
