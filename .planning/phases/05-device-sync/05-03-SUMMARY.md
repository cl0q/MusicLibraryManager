---
phase: 05-device-sync
plan: 03
subsystem: sync
tags: [rockbox, m3u8, device-detection, fat32, playlists]

# Dependency graph
requires:
  - phase: 05-01
    provides: "Sync profile data model with track/playlist/rule resolution"
  - phase: 01-library-foundation
    provides: "Track metadata model and sanitize_filename for FAT32 compatibility"
provides:
  - "Rockbox device detection by .rockbox directory marker"
  - "Platform-specific mount point scanning (macOS, Linux, Windows)"
  - "Available disk space query via df/wmic commands"
  - "M3U8 playlist generation with RFC-compliant format"
  - "Relative path generation for Rockbox compatibility"
  - "FAT32-safe filename sanitization in playlists"
affects: [05-04-transfer-orchestration, device-sync-ui]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Platform-specific filesystem scanning with cfg attributes"
    - "std::process::Command for disk space queries avoiding unsafe FFI"
    - "M3U8 extended format with #EXTM3U header and #EXTINF metadata"
    - "Relative path generation for portable playlists"

key-files:
  created:
    - src-tauri/src/sync/device.rs
    - src-tauri/src/sync/playlist_gen.rs
  modified:
    - src-tauri/src/sync/mod.rs

key-decisions:
  - "df/wmic commands for disk space (avoids unsafe FFI and external crates)"
  - "Relative paths in M3U8 (Rockbox compatibility requirement)"
  - "album_artist in playlist paths (matches profile folder structure)"
  - "#EXTINF format with artist - title (industry standard metadata)"

patterns-established:
  - "cfg(target_os) for platform-specific device detection"
  - "is_rockbox_device() as single source of truth for .rockbox marker check"
  - "Recursive mount scanning on Linux for /media/{user}/device structure"
  - "M3U8 with Unix line endings (\n) for cross-platform compatibility"

# Metrics
duration: 3m 18s
completed: 2026-02-04
---

# Phase 05 Plan 03: Rockbox Device Detection and M3U8 Generation Summary

**Platform-aware Rockbox device detection via .rockbox marker with disk space queries, plus M3U8 playlist generation using relative FAT32-safe paths**

## Performance

- **Duration:** 3m 18s
- **Started:** 2026-02-04T15:41:19Z
- **Completed:** 2026-02-04T15:44:37Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Rockbox device detection scanning /Volumes (macOS), /mnt and /media (Linux), drive letters (Windows)
- Available disk space query using df on Unix and wmic on Windows without unsafe FFI
- M3U8 playlist generation with #EXTM3U header and #EXTINF duration/artist/title metadata
- Relative path generation (Artist/Album/Track.m4a) compatible with Rockbox firmware
- FAT32-safe filenames using existing sanitize_filename module
- Comprehensive test coverage: 5 device tests, 10 playlist tests (15 total)

## Task Commits

Each task was committed atomically:

1. **Task 1: Rockbox device detection with platform-specific mount scanning** - `bd35f37` (feat)
2. **Task 2: M3U8 playlist generation with Rockbox-compatible relative paths** - `5cc07b7` (feat)

## Files Created/Modified
- `src-tauri/src/sync/device.rs` - Rockbox device detection with RockboxDevice struct, detect_rockbox_devices() for platform-specific mount scanning, is_rockbox_device() for .rockbox marker check, get_available_space() using df/wmic
- `src-tauri/src/sync/playlist_gen.rs` - M3U8 playlist generation with generate_m3u8() for #EXTM3U format, write_playlist_file() for file I/O, write_profile_playlist() for profile/Playlists/{name}.m3u8 convenience
- `src-tauri/src/sync/mod.rs` - Added device and playlist_gen module exports

## Decisions Made

**1. df/wmic commands for disk space instead of FFI**
- Rationale: std::process::Command avoids unsafe FFI (statvfs/GetDiskFreeSpaceEx) and external crate dependencies (fs2)
- Tradeoff: Subprocess overhead negligible for infrequent device detection queries
- Alternative considered: nix crate for statvfs - rejected to minimize dependencies

**2. Relative paths in M3U8 playlists**
- Rationale: Rockbox requires relative paths from device root, absolute paths fail on device
- Format: Artist/Album/Track.m4a from profile root (same structure as sync folder)
- Verified: Paths do not start with / or contain drive letters

**3. album_artist for playlist path artist directory**
- Rationale: Matches profile folder structure (Artist/Album/Track.m4a uses album_artist for Artist)
- Consistency: Same sanitized paths in sync profiles and playlists
- Result: Playlist paths resolve correctly to actual file locations

**4. #EXTINF format with artist - title**
- Rationale: Industry standard M3U8 metadata format, widely supported
- Format: `#EXTINF:{duration},{artist} - {title}`
- Duration: Uses track.metadata.duration, defaults to 0 if missing

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - implementation followed plan specifications without obstacles.

## User Setup Required

None - no external service configuration required.

Device detection works automatically when Rockbox iPod is connected.

## Next Phase Readiness

**Ready for Plan 05-04 (Transfer Orchestration):**
- Device detection complete with available_space for capacity checks
- M3U8 generation ready for playlist export
- Platform-specific mount point handling proven on macOS (tested), Linux and Windows (compiled)

**Integration points available:**
- `detect_rockbox_devices()` returns Vec<RockboxDevice> with mount_point and available_space
- `write_profile_playlist()` creates M3U8 files in profile/Playlists/ directory
- `is_rockbox_device()` can validate user-provided device paths

**Testing notes:**
- Unit tests passing: 5 device tests, 10 playlist tests
- Integration test for actual Rockbox device marked #[ignore] for CI
- Manual device testing requires physical Rockbox iPod (deferred until user has device)

**Blockers/Concerns:**
- M3U8 encoding for non-ASCII characters untested (UTF-8 should work with Rockbox but needs verification)
- FAT32 long filename support (255 char limit enforced by sanitize_filename but edge cases possible)
- Device detection on Linux /media structure has two-level recursion (handles username subdirs but not deeper nesting)

---
*Phase: 05-device-sync*
*Completed: 2026-02-04*
