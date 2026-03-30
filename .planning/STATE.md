---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Library Foundation & UX Polish
status: executing
stopped_at: Completed 11.1-02-PLAN.md
last_updated: "2026-03-30T18:36:03.741Z"
last_activity: 2026-03-30
progress:
  total_phases: 6
  completed_phases: 4
  total_plans: 20
  completed_plans: 18
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 12 — import-external-playlists

## Current Position

Phase: 12
Plan: Not started
Status: Executing Phase 12
Last activity: 2026-03-30

Progress: [█████████░░░░░░░░░░] 51/TBD total plans (v1.0: 39/39, v1.1: 12/TBD)

## Performance Metrics

**Velocity (v1.0):**

- Total plans completed: 39
- Total execution time: ~3 days
- Phases completed: 7

**Current Milestone (v1.1):**

- Plans completed: 12
- Average duration: 8 min
- Total execution time: ~102 min

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
- Phase 11-01: Event-based progress streaming (not IPC channels) for Tauri v2 compatibility
- Phase 11-01: BatchResult tracks downloaded_track_ids to avoid passing Connection to async functions
- Phase 11-01: Database updates happen after batch completes (not per-track) for Send/Sync compliance
- Phase 11-02: Download action only visible for Remote tracks (organized_path IS NULL check)
- Phase 11-02: DownloadProgress uses event listeners for real-time updates (not polling)
- Phase 11-02: LibraryConfig fetched on-demand in download handler (not via context)
- [Phase 11.1-01]: serde_json added to dev-dependencies explicitly even though it is already a regular dep, for test intent clarity
- [Phase 11.1-01]: test_search_not_found marked #[ignore] not deleted to preserve live API test for manual use
- [Phase 11.1-03]: Mock @tauri-apps/api/event directly in tests — mockWindows does not implement transformCallback required by listen()
- [Phase 11.1-03]: LibraryTable tests check column headers (not row data) — react-virtual needs real layout to render rows, happy-dom returns 0
- [Phase 11.1]: No DabClient HTTP mocks in integration tests — network tests remain #[ignore] in dab.rs until trait abstraction added

### v1.1 Scope Decisions

- Library/Remote separation is core architectural fix
- SSD-based library required (external drive)
- Context menu responsiveness included
- Similar songs grouping deferred to v1.2
- Spotify JSON migration deferred to v1.2
- SoundCloud playlists deferred to v1.2

### Roadmap Evolution

- Phase 11.1 inserted after Phase 11: Functional & E2E Test Harness (URGENT)
- Phase 12 added: Import External Playlists

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

Last session: 2026-03-22T13:58:01.272Z
Stopped at: Completed 11.1-02-PLAN.md
Resume file: None

---
*Last updated: 2026-02-09 after 11-02 plan completion*
