---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: macOS Native
status: in_progress
stopped_at: Phase 2 complete — Shell & Navigation
last_updated: "2026-05-07T22:00:00.000Z"
last_activity: 2026-05-07
progress:
  total_phases: 20
  completed_phases: 2
  total_plans: 1
  completed_plans: 1
  percent: 10
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-07)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality — native macOS experience
**Current focus:** Phase 3 — Library Browser (next)
**Source of truth:** `macos-app/PLAN.md` + `.planning/ROADMAP.md` v2.0 section
**v1.4 source of truth (paused):** `.planning/REQUIREMENTS.md` v1.4 section + `.planning/ROADMAP.md` v1.4 section
**v1.3 source of truth (paused):** `.planning/REQUIREMENTS.md` v1.3 section + `.planning/ROADMAP.md` v1.3 section

## Current Position

Phase: 2 (Shell & Navigation) — COMPLETE
Next: Phase 3 (Library Browser)
Status: Shell layout shipped — NavigationSplitView + MiniPlayer + ActivityPanel + ⌘1-5 shortcuts
Last activity: 2026-05-07

## Phase 1 Summary (v2.0)

- **01-01** — Xcode/SPM project scaffold + GRDB database manager with 19 migrations + all core models (Track, Playlist, SyncProfile, Album, Source) + 7 repositories (Track, Playlist, Sync, Album, Source, Analysis, Config) + Solar theme tokens (Colors, Typography, Spacing) + entitlements + utilities (ProcessRunner, FileHelpers, Debouncer) + 326-line database test suite (10 tests covering schema, CRUD, FK cascades, migrations)

## Phase 2 Summary (v2.0)

- ContentView restructured: VStack layout integrating NavigationSplitView + MiniPlayerView (36px) + ActivityPanel (36px collapsed / 320px expanded)
- MiniPlayerView: empty-state shell — play icon + "No track playing" + progress bar placeholder + duration placeholder. Wired to Solar theme. Phase 5 connects PlaybackViewModel
- ActivityPanel: collapsible bottom panel with Operations/Logs tabs (segmented picker). Both tabs show empty-state placeholders. Phase 16 wires real data
- SidebarView Settings button wired to open Settings window (NSApp selector)
- ⌘1-5 keyboard shortcuts wired via FocusedSceneValue + CommandMenu in MLMApp
- Settings scene upgraded from bare Text to SettingsPlaceholderView with Solar styling
- FocusedValueKey pattern for cross-scene navigation state (SelectedSectionKey)

**Files created:** MiniPlayerView.swift, ActivityPanel.swift, OperationsTab.swift, LogsTab.swift
**Files modified:** ContentView.swift (major rework), SidebarView.swift, MLMApp.swift

## Phase 28 Summary (v1.4)

- **28-01** (ed5ee4c) — Tauri asset protocol wired: `protocol-asset` Cargo feature + `tauri.conf.json` `assetProtocol` block (scope `["/Volumes/Lexxar/Music/**", "$HOME/Music/**"]`, `csp: null` retained); `Cargo.lock` adds transitive `http-range 0.1.5`; D-04 grep returned 0 → `capabilities/default.json` untouched (Branch 1, expected outcome). Three-format DevTools fetch+canplay PASS in dev mode (FLAC `audio/x-flac` + AAC `audio/m4a` + MP3 `audio/mpeg`, all 206 + canplay).

**Methodology gap** (recorded in `.planning/phases/28-asset-protocol-setup/28-01-SUMMARY.md`): D-06's UI smoke test (right-click → More Info → waveform) couldn't run — `MoreInfoPanel` was redesigned (Solar) and explicitly scope-cut the waveform; `WaveformView` only mounts at `/library/:trackId` which is unreachable from production navigation. Verification fell back to a temporary debug script (`__phase28_test.ts`, removed before commit) running convertFileSrc + fetch(Range) + new Audio() in `bun tauri dev`. SC1/SC3 fully proven, SC2 deferred to Phase 29's first real consumer (spacebar preview), SC4 partial (csp confirmed; regression spot-check deferred).

**Open Question O-4 resolved:** WaveformView did NOT work in v1.0 production builds (latent bug confirmed by static analysis). Now wired correctly, but the only consumer is unreachable orphan code.
**Open Question O-5 resolved:** No `core:asset:*` capability needed in Tauri 2.10.1 (D-04 Branch 1).

## v1.4 Phase Build Order (sequential, Standard execution)

1. **Phase 28** — Asset-Protocol Setup (un-breaks v1.0 WaveformView; non-optional prerequisite for Phase 29)
2. **Phase 29** — Inline Preview / Spacebar Playback (the verb; daily-driver multiplier)
3. **Phase 30** — Disk-Folder Explorer (independent surface; immediately benefits from Phase 29)
4. **Phase 31** — Native MLM Playlists (curation surface; the user's stated complaint answer)
5. **Phase 32** — Bulk-Add to Playlist (extends Phase 19 batch bar with Phase 31's playlists)
6. **Phase 33** — Polish & E2E (Solar pass, empty/error states, end-to-end daily-loop test)

## Phase 20 Summary (v1.3 — paused)

- **20-01** (c92cb46) — schema v15, `track_tags(track_id, tag_key, tag_value)` table + indexes + cascade delete
- **20-02** (1c1c8f4) — `yeat::tags` module: `infer_tags`, `walk_yeat_root`, `TagTriple`, era normalizer (deunicode-standard), variant suffix matcher
- **20-03** (cead494) — `backfill_yeat_tags_cmd` Tauri command + JSON sync report at `.planning/sync-reports/yeat-tags-*.json`, transactional UPSERT + reconcile-DELETE scoped to managed keys `(artist, era, variant)`

Tests: 421 passing / 0 failing / 23 ignored. Zero regressions from v1.2 baseline.

**Downstream note for Phase 21+:** era normalization uses standard `deunicode` transliteration, so `AftërLyfe` → `afterlyfe` (not `aftrelyfe` as originally written in CONTEXT — executor caught the typo, tests reflect actual behavior). Any phase that hardcodes era tag values must use the normalized form.

**Smoke test needed before milestone-close:** Mount `/Volumes/Lexxar` and invoke the backfill command against real Yeat library to verify walker handles production-scale data.

## Performance Metrics

**Velocity (v1.0):**

- Total plans completed: 39
- Total execution time: ~3 days
- Phases completed: 7

**v1.1 (shipped):**

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
- wavesurfer.js — Existing waveform renderer (v1.0 — fixed in v1.4 Phase 28)
- @hello-pangea/dnd — Drag-drop (already shipped; reused in v1.4)
- react-arborist — Virtualized folder tree (NEW for v1.4 Phase 30)

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
- [Phase 12.1-01]: Windows-style absolute paths explicitly detected since Path::is_absolute() returns false on Unix for drive-letter paths
- [Phase 12.1-01]: validate_organized_path is the single write-boundary guard for organized_path — called at entry of update_download_status
- [Phase 12.1]: reveal_in_file_manager now owns path resolution — takes relative organized_path, resolves via library root (not frontend responsibility)
- [Phase 12.1]: COALESCE(organized_path,'') in get_remote_tracks_only avoids NULL→String type failure in rusqlite without changing Track.organized_path to Option<String>

### v1.3 Scope Decisions (locked, paused state)

- Yeat-only first-class treatment — NOT a general "starred artists" system (deferred)
- DB is canonical for era/variant/tag; disk drift surfaces in sync reports, never silent DB rewrites
- `yëat typa shi` playlist stays separate — never unioned with Yeat discography in shuffle/play-all
- Unreleased UI is two components by sibling count: UFO toggle (exactly 2), Winamp cycler (3+)
- Era assignment uses fuzzy metadata + existing fingerprint module — NO ML model
- Rockbox m3u8 paths use `/<HDD0>/` prefix (required by Rockbox) — remap to library root on import
- Droppy iOS migration OUT OF SCOPE — iMazing recon 2026-04-23 yielded nothing extractable

### v1.4 Scope Decisions (locked at roadmap)

- Standard execution model (not autonomous) — UX work; user feels each phase before chaining
- Phase order is sequential: 28 → 29 → 30 → 31 → 32 → 33 (synthesis aggressive variant rejected in favor of sequential per Standard execution)
- No Yeat coupling — v1.4 code is unaware of artist/era/variant/`variant_of`/`track_tags` semantics
- No new aggregate tables — `artists` table stays reserved for v1.3 Phase 23
- Default position: no schema bumps in v1.4; if forced, v1.4 takes v18+ and v1.3 phases 22+ renumber on resume
- Native playlists are constrained: `source_id = NULL`, `external_id = NULL`, `is_smart = false`, `is_liked = false`, `category = 'regular'`
- Variant tracks (`AftërLyfe` and `AftërLyfe [U]`) are distinct in playlists; UFO toggle is display-only
- Playback is preview-grade — full media-player ambitions (queue, gapless, crossfade, EQ, scrobbling, lock-screen) stay OOS
- System volume is the single source of truth — no in-app volume slider
- Logical folders / collections deferred entirely from v1.4 (all four research streams agreed)
- Single npm dep added: `react-arborist@3.5.0`; zero new cargo crates; one Tauri config change (asset protocol)

### Roadmap Evolution

- v1.1: Phase 11.1 inserted (Functional & E2E Test Harness, URGENT); Phase 12 added (Import External Playlists); Phase 12.1 inserted (Consistent Path Resolution, URGENT)
- v1.2: Autonomous chain shipped phases 13-19; design CONTRACT.md locked before execution
- v1.3: Opened 2026-04-23 with 8 phases (20-27); Droppy recon dropped after iMazing came up empty
- v1.3: PAUSED 2026-05-04 mid-flight — phases 20/21/21.1 shipped; phases 22-27 retained as locked spec for resumption (see PROJECT.md "Paused Milestone" section)
- v1.4: Opened 2026-05-04 (Daily Driver) — daily-use loop (folder explorer + native MLM playlists + spacebar preview/playback). Reverses prior "no playback" Out-of-Scope decision (preview-grade only; full media-player ambitions stay OOS)
- v1.4: Roadmap created 2026-05-04 — 6 phases (28-33), 35 requirements mapped 100% (no orphans)
- v1.4: Phase 34 added 2026-05-07 (Rework Download Orchestrator) — drop AAC into artist dirs, retire `.mlm_staging/` as canonical home, migrate the 103 existing staging tracks. Driver: Phase 29 surfaced asset-protocol incompatibility with dot-dirs; interim scope fix shipped (commit `27d7e21`) but staging-as-home is the underlying smell.

### Pending Todos

- Backfill `.planning/phases/13-*` through `19-*` scaffolding (tech debt from v1.2 autonomous shipping — not blocking v1.4)
- `.planning/todos/pending/audio-analysis-ux-cleanup.md` — must complete BEFORE v1.3 resumes (locked dependency from PROJECT.md). v1.4 milestone-close should also surface position-string growth audit (PITFALLS P-2): `SELECT MAX(LENGTH(position)) FROM playlist_tracks`.

### Blockers/Concerns

**From v1.0 user testing (carried forward):**

- Hardcoded "default" user_id for source creation (needs proper user management)

**v1.3 scope (paused):**

- Schema adds `variant_of` column (Phase 21) and first-class Yeat artist flag (Phase 23) — migration care required
- UFO toggle animation fidelity — user wants exaggerated "spacey UFO opening", not literal iOS-15-button copy
- Winamp cycler visual style is designer's-choice — "surprise me, something completely different but cool"
- Fingerprint pass (Phase 25) depends on existing `src-tauri/src/fingerprint` module quality — no new fingerprint work
- v1.3 phases 22+ may need migration-version renumbering on resume if v1.4 takes any schema bump

**v1.4 open questions to resolve at phase kickoffs:**

- Phase 29 — Open Question O-1 (format prevalence — `SELECT format, COUNT(*) FROM tracks GROUP BY format` to lock audio-format strategy per PITFALLS A-1)
- Phase 30 — Open Question O-2 (NFC vs NFD normalization — verify `🔔 yëat typa shi` round-trip JS↔Rust per PITFALLS T-5)
- Phase 31 — Open Question O-3 (`PRAGMA foreign_keys = ON` audit at every `Connection::open` call site per PITFALLS P-3/P-4)
- Phase 28 — Open Question O-4 (does `WaveformView.tsx` work in production builds today, or only in `tauri dev`?) and O-5 (capability-file naming for asset protocol in Tauri v2 — `core:asset:default` or different?)

## Session Continuity

Last session: 2026-05-07T17:48:58.771Z
Stopped at: Phase 30 context gathered
Resume file: .planning/phases/30-disk-folder-explorer/30-CONTEXT.md

---
*Last updated: 2026-05-04 — v1.4 Daily Driver roadmap created (Phases 28-33); v1.3 Yeat Expansion remains paused*
