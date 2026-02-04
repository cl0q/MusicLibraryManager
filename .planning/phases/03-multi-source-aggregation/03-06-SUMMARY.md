---
phase: 03-multi-source-aggregation
plan: 06
subsystem: download
tags: [soundcloud, scdl, cli-wrapper, download-priority, aac, oauth]

# Dependency graph
requires:
  - phase: 02-download-infrastructure
    provides: "Download orchestrator with DAB + YouTube priority chain, retry queue, transcode pipeline"
  - phase: 03-multi-source-aggregation (plan 03)
    provides: "SoundCloud OAuth client, token storage, track sync"
provides:
  - "SoundCloud direct download via scdl CLI with Go+ authentication"
  - "Source-priority download chain: SoundCloud -> DAB -> YouTube"
  - "DownloadRequest extended with soundcloud_url and user_id fields"
affects:
  - "04-tauri-commands (SoundCloud download command wiring)"
  - "05-device-sync (downloaded files feed into sync pipeline)"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CLI wrapper pattern (scdl) matching youtube.rs and dab.rs patterns"
    - "Optional downloader in orchestrator (graceful degradation when CLI not installed)"
    - "Source-priority download chain with fallback"

key-files:
  created:
    - "src-tauri/src/download/soundcloud.rs"
  modified:
    - "src-tauri/src/download/mod.rs"
    - "src-tauri/src/download/orchestrator.rs"
    - "src-tauri/src/commands/download.rs"

key-decisions:
  - "SoundCloudDownloader optional in orchestrator - does not fail if scdl not installed"
  - "SoundCloud downloads to aac_dir (already AAC from scdl) rather than flac_dir"
  - "find_most_recent_audio_file for locating scdl output (scdl has unpredictable filenames)"

patterns-established:
  - "Optional CLI tool pattern: try to initialize, log info and continue without if unavailable"
  - "Source priority Step 0 before existing DAB/YouTube chain"

# Metrics
duration: 4min
completed: 2026-02-04
---

# Phase 3 Plan 6: SoundCloud Download Summary

**SoundCloud direct download via scdl CLI with Go+ auth token from keychain, integrated as priority source in download orchestrator**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-04T07:40:17Z
- **Completed:** 2026-02-04T07:44:05Z
- **Tasks:** 1 (documentation task skipped per instructions)
- **Files modified:** 4

## Accomplishments
- SoundCloud download module wrapping scdl CLI with --auth-token for 248kbps AAC
- Source priority chain extended: SoundCloud (Step 0) -> DAB (Step 1) -> YouTube (Step 2)
- SoundCloudDownloader is optional in orchestrator (graceful if scdl not installed)
- DownloadRequest extended with soundcloud_url and user_id for source routing
- 184 tests passing (6 new in soundcloud module, 3 new in orchestrator/commands)

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement SoundCloud download using scdl CLI** - `6466cc2` (feat)

**Plan metadata:** pending

## Files Created/Modified
- `src-tauri/src/download/soundcloud.rs` - SoundCloud download client wrapping scdl CLI (324 lines)
- `src-tauri/src/download/mod.rs` - Added soundcloud module export
- `src-tauri/src/download/orchestrator.rs` - Source priority with SoundCloud Step 0, extended DownloadRequest
- `src-tauri/src/commands/download.rs` - Updated tests for new DownloadRequest fields

## Decisions Made
- **SoundCloudDownloader optional in orchestrator** - scdl is an external Python tool that may not be installed; orchestrator initializes without it and skips SoundCloud downloads gracefully
- **Downloads to aac_dir not flac_dir** - SoundCloud Go+ produces 248kbps AAC already, no need to download to FLAC staging directory
- **find_most_recent_audio_file helper** - scdl generates filenames based on track title which may not match our naming convention; searching by most recent modified time is reliable

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Updated DownloadRequest in commands/download.rs tests**
- **Found during:** Task 1 (compilation)
- **Issue:** commands/download.rs tests constructed DownloadRequest without new soundcloud_url and user_id fields
- **Fix:** Added the new fields to all test DownloadRequest constructions, plus added a new test for SoundCloud serialization
- **Files modified:** src-tauri/src/commands/download.rs
- **Verification:** All 4 command tests pass
- **Committed in:** 6466cc2 (part of task commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Minor fix required for compilation with new struct fields. No scope creep.

## Issues Encountered
None

## User Setup Required
- `pip install scdl` required for SoundCloud direct downloads
- SoundCloud Go+ subscription required for 248kbps AAC quality
- OAuth flow must be completed to store access token in keychain

## Next Phase Readiness
- Phase 3 multi-source aggregation complete (all 6 plans done)
- Download infrastructure now supports three sources: SoundCloud, DAB, YouTube
- Source priority chain operational for both Spotify-sourced and SoundCloud-sourced tracks
- Ready for Phase 4 (Tauri commands wiring) or Phase 5 (device sync)

---
*Phase: 03-multi-source-aggregation*
*Completed: 2026-02-04*
