---
phase: 10-track-actions-more-info
plan: 03
subsystem: backend-commands
tags: [file-operations, ffprobe, caching, clipboard]
dependency_graph:
  requires: [10-02]
  provides: [copy-to-clipboard-command, get-track-analysis-command]
  affects: [ui-context-menu, more-info-panel]
tech_stack:
  added: []
  patterns: [spawn-blocking, platform-specific-commands]
key_files:
  created:
    - src-tauri/src/commands/files.rs
    - src-tauri/src/commands/analysis.rs
  modified:
    - src-tauri/src/commands/mod.rs
    - src-tauri/src/lib.rs
    - src-tauri/src/search/query.rs
decisions:
  - decision: "Reuse track_analysis table created by plan 10-02"
    rationale: "Plans run in parallel, 10-02 already created schema v8 and track_analysis.rs"
    impact: "Task 2 skipped, no duplicate schema migration"
  - decision: "Use platform-specific clipboard commands (pbcopy, xclip, clip.exe)"
    rationale: "Cross-platform clipboard support without external dependencies"
    impact: "Works on macOS, Linux, Windows"
  - decision: "Add get_track_by_id helper to search/query.rs"
    rationale: "Needed for track retrieval in analysis command, follows existing pattern"
    impact: "Reusable query function for other commands"
metrics:
  duration: "387 seconds (~6 minutes)"
  completed_date: "2026-02-07"
  tasks_completed: 3
  commits: 2
---

# Phase 10 Plan 03: Backend File Operations & FFprobe Summary

**One-liner:** Copy to clipboard and FFprobe extraction commands with database caching for track analysis data.

## What Was Built

Implemented backend Tauri commands for file operations and track analysis:

1. **Copy to Clipboard Command** - Cross-platform clipboard support for copying file paths
2. **FFprobe Integration** - Extract technical metadata as JSON with database caching
3. **Track Analysis Caching** - Reuse track_analysis table created by plan 10-02

### Task Breakdown

| Task | Name                                    | Status    | Commit  | Notes                                      |
| ---- | --------------------------------------- | --------- | ------- | ------------------------------------------ |
| 1    | Create copy_to_clipboard command        | Complete  | b095c5a | Cross-platform clipboard (macOS/Linux/Win) |
| 2    | Add track_analysis table and DB ops     | Skipped   | N/A     | Already completed by plan 10-02 (dd49134)  |
| 3    | Create get_track_analysis with ffprobe  | Complete  | c796828 | FFprobe extraction with cache lookup       |

## Key Implementation Details

### Copy to Clipboard (Task 1)

- Platform-specific commands:
  - macOS: `pbcopy` (stdin pipe)
  - Linux: `xclip` (primary) or `xsel` (fallback)
  - Windows: `clip.exe`
- No external dependencies (uses std::process::Command)
- Registered in invoke_handler for frontend access

### FFprobe Integration (Task 3)

- Check cache first (track_analysis table lookup)
- Run ffprobe with `-print_format json -show_format -show_streams`
- Graceful error handling:
  - Missing ffprobe: "Install via: brew install ffmpeg"
  - Remote tracks: "Track has no local file (remote/undownloaded track)"
- Save results to cache for reuse (ISO 8601 timestamps)
- Uses spawn_blocking pattern for database and shell operations

### Database Query Helper

- Added `get_track_by_id()` to search/query.rs
- Follows existing pattern (get_all_tracks, get_library_tracks_only)
- Returns Option<Track> for safe handling of non-existent IDs

## Deviations from Plan

### Parallel Plan Coordination (Rule 3 - Blocking Issue)

**Task 2 was already completed by plan 10-02 (commit dd49134):**
- Schema v8 migration already exists
- track_analysis table already created
- track_analysis.rs module already implemented

**Resolution:** Skipped Task 2 entirely, reused existing implementation. This is correct behavior for parallel plan execution.

**Files modified:** None (all work done by 10-02)
**Commit:** N/A

## Integration Points

### Commands Registered

```rust
// lib.rs invoke_handler
commands::files::copy_to_clipboard
commands::analysis::get_track_analysis
commands::library_config::reveal_in_file_manager  // Already exists from Phase 8
```

### Frontend Integration

- `copy_to_clipboard(text: String)` - Copy file path to system clipboard
- `get_track_analysis(track_id: i64)` - Retrieve FFprobe data + fingerprint + spectrogram paths
- `reveal_in_file_manager(path: String)` - Open file manager with file selected (Phase 8 command)

### Database Schema

- track_analysis table (schema v8) - Created by plan 10-02
- Columns: track_id, ffprobe_output, fingerprint, spectrogram_path, analysis_timestamp
- Foreign key: track_id REFERENCES tracks(id) ON DELETE CASCADE

## Testing

### Build Verification
- `cargo build` in src-tauri: SUCCESS
- No compilation errors
- 4 warnings (unused imports in sources.rs, dead code in soundcloud.rs) - pre-existing

### Manual Testing Required
1. Right-click local track → Copy File Path → verify path in system clipboard (Cmd+V)
2. Right-click local track → More Info → verify FFprobe Output section shows JSON
3. Verify ffprobe data is cached (check track_analysis table after first load)
4. Remote tracks (organized_path IS NULL) should show error message
5. Without ffprobe installed: verify error message suggests `brew install ffmpeg`

## Next Phase Readiness

**Phase 10 Plan 03 Provides:**
- Backend commands for context menu actions (copy path, reveal file)
- FFprobe metadata extraction for More Info panel
- Database caching for performance

**Blocks:** None

**Blockers:** None

**Unresolved Questions:** None

## Self-Check: PASSED

**Created files exist:**
- FOUND: src-tauri/src/commands/files.rs
- FOUND: src-tauri/src/commands/analysis.rs

**Modified files updated:**
- FOUND: src-tauri/src/commands/mod.rs (analysis and files modules added)
- FOUND: src-tauri/src/lib.rs (commands registered)
- FOUND: src-tauri/src/search/query.rs (get_track_by_id added)

**Commits exist:**
- FOUND: b095c5a - feat(10-03): add copy_to_clipboard command
- FOUND: c796828 - feat(10-03): add get_track_analysis command with ffprobe integration

**Build verification:**
- cargo build: SUCCESS (warnings are pre-existing)
- No new errors introduced

**Plan 10-02 dependency:**
- VERIFIED: track_analysis table created in commit dd49134
- VERIFIED: schema v8 migration exists
- VERIFIED: track_analysis.rs module exists

---

*Plan executed: 2026-02-07*
*Duration: 6 minutes*
*Executor: GSD executor agent*
