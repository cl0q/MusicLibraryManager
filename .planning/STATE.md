# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 10 - Track Actions & More Info

## Current Position

Phase: 10 of 11 (Track Actions & More Info)
Plan: 3 of 3 in current phase
Status: Phase complete
Last activity: 2026-02-07 - Completed 10-03-PLAN.md

Progress: [████████░░░░░░░░░░░] 49/TBD total plans (v1.0: 39/39, v1.1: 10/TBD)

## Performance Metrics

**Velocity (v1.0):**
- Total plans completed: 39
- Total execution time: ~3 days
- Phases completed: 7

**Current Milestone (v1.1):**
- Plans completed: 10
- Average duration: 9 min
- Total execution time: ~93 min

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
- Phase 9-02: Remote nav item disabled: false (always accessible, per requirement REM-04)
- Phase 9-02: Badge updates via event listeners (import-complete, sync-complete, download-complete)
- Phase 9-02: Cloud icon for Remote item (consistent with network/streaming semantics)
- Phase 9-03: View parameter defaults to 'library' for backward compatibility with existing code
- Phase 9-03: Format column normalization shows 'Stream' for spotify/soundcloud, actual formats for local files
- Phase 10-01: TrackSelectionContext uses React Context pattern for shared multi-select state
- Phase 10-01: Multi-select uses Cmd/Ctrl+click toggle, Shift+click range (standard desktop UX)
- Phase 10-01: Inline confirmation uses 2-second green highlight (no toast popups per user requirement)
- Phase 10-01: File actions (Reveal/Copy Path) only shown when organized_path exists (local tracks only)
- Phase 10-02: More Info panel slides in from right with backdrop overlay (not modal dialog)
- Phase 10-02: Collapsible sections default to closed except Format Information
- Phase 10-02: Panel auto-loads ffprobe data with graceful fallback if backend not implemented
- Phase 10-03: Reuse track_analysis table from plan 10-02 (parallel execution, schema v8 already created)
- Phase 10-03: Platform-specific clipboard commands (pbcopy/xclip/clip.exe) for cross-platform support
- Phase 10-03: FFprobe errors gracefully handled with installation instructions

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
Stopped at: Completed 10-03-PLAN.md
Resume file: None

---
*Last updated: 2026-02-07 after 10-03 plan completion*
