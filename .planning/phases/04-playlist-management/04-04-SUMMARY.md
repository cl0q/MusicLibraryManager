---
phase: 04-playlist-management
plan: 04
subsystem: playlist
tags: [spotify, soundcloud, playlist-import, deduplication, mirroring, add-only-semantics]

# Dependency graph
requires:
  - phase: 04-02
    provides: Fractional indexing and playlist CRUD operations
  - phase: 04-03
    provides: Liked playlist creation functions
  - phase: 03-multi-source-aggregation
    provides: Spotify and SoundCloud API clients, dedup module
provides:
  - Source playlist import functions (Spotify and SoundCloud)
  - Add-only mirrored playlist refresh semantics
  - Cross-source deduplication for imported tracks
  - Liked songs import to per-source liked playlists
affects: [05-device-sync, 06-ui]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Add-only mirroring: tracks added from source, never removed from local"
    - "find_or_create_track pattern: external_id first, then similarity matching"
    - "Source playlist refresh preserves manual reordering"

key-files:
  created: []
  modified:
    - src-tauri/src/database/playlist.rs
    - src-tauri/src/sources/spotify.rs
    - src-tauri/src/sources/soundcloud.rs

key-decisions:
  - "Add-only semantics for mirrored playlists: tracks removed from source remain in local playlist"
  - "Cross-source deduplication via similarity scoring (0.85 threshold)"
  - "find_or_create_track pattern: check external_id first, then fuzzy match by title/artist"
  - "Idempotent add_liked_track: safe to call multiple times with same track"

patterns-established:
  - "refresh_mirrored_playlist: add-only semantics, preserves existing track positions"
  - "find_or_create_track: external_id lookup → similarity search → create phantom track"
  - "Playlist import: create local playlist, link via external_id, add tracks with dedup"

# Metrics
duration: 200min
completed: 2026-02-04
---

# Phase 04 Plan 04: Source Playlist Import Summary

**Spotify and SoundCloud playlist import with add-only mirroring, cross-source deduplication, and manual reordering preservation**

## Performance

- **Duration:** 3h 20m
- **Started:** 2026-02-04T09:40:47Z
- **Completed:** 2026-02-04T12:59:42Z
- **Tasks:** 3
- **Files modified:** 3
- **Tests added:** 12 (5 playlist, 2 spotify, 2 soundcloud, 3 integration)

## Accomplishments

- Implemented add-only playlist mirroring that preserves manual reordering
- Built cross-source deduplication using similarity scoring (prevents duplicate downloads)
- Created playlist import functions for Spotify and SoundCloud with external_id tracking
- Enabled selective playlist import (user chooses which playlists to mirror)
- Implemented liked songs import to per-source liked playlists

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement refresh_mirrored_playlist with add-only semantics** - `dedb325` (feat)
2. **Task 2: Implement Spotify playlist import and refresh** - `cd815e9` (feat)
3. **Task 3: Implement SoundCloud playlist import and refresh** - `fc270b5` (feat)

## Files Created/Modified

- `src-tauri/src/database/playlist.rs` - Added refresh_mirrored_playlist (add-only semantics), add_liked_track (idempotent)
- `src-tauri/src/sources/spotify.rs` - Added get_playlist, get_playlist_tracks, find_or_create_track, import_spotify_playlist, import_spotify_liked_songs, refresh_spotify_playlist
- `src-tauri/src/sources/soundcloud.rs` - Added get_playlist, get_playlist_tracks, find_or_create_soundcloud_track, import_soundcloud_playlist, import_soundcloud_liked_songs, refresh_soundcloud_playlist

## Decisions Made

**1. Add-only semantics for mirrored playlists**
- Rationale: Tracks removed from source playlist stay in local playlist to preserve user's manual additions and prevent data loss
- Implementation: refresh_mirrored_playlist only adds new tracks, never removes existing ones
- Benefit: User can add local tracks to imported playlists without them being removed on refresh

**2. Cross-source deduplication with 0.85 similarity threshold**
- Rationale: Same track from Spotify and SoundCloud should reference one library track (no duplicate downloads)
- Implementation: find_or_create_track checks external_id first, then fuzzy matches title/artist using dedup module
- Threshold: 0.85 balances precision (avoiding false positives) and recall (catching variations)

**3. Idempotent add_liked_track function**
- Rationale: Liked songs sync may be called multiple times (incremental sync, retry on failure)
- Implementation: Check if track already in playlist before adding, skip if exists
- Benefit: Safe to call repeatedly without duplicate entries

**4. External_id format for playlist tracking**
- Format: `spotify:playlist:{id}` and `soundcloud:{id}`
- Stored in: playlists.external_id column
- Purpose: Enables refresh operations to fetch updated tracks from source

## Deviations from Plan

**1. [Rule 2 - Missing Critical] Added DatabaseError conversion for SpotifyError and SoundCloudError**
- **Found during:** Task 2 (Spotify playlist import compilation)
- **Issue:** create_playlist returns DatabaseError but import functions return SpotifyError/SoundCloudError - type mismatch prevents using ? operator
- **Fix:** Added `#[from] crate::database::connection::DatabaseError` variant to both error enums
- **Files modified:** src-tauri/src/sources/spotify.rs, src-tauri/src/sources/soundcloud.rs
- **Verification:** Compilation succeeds, tests pass
- **Committed in:** cd815e9, fc270b5 (Task 2 and 3 commits)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Auto-fix required for type system correctness. No scope creep.

## Issues Encountered

None - plan execution proceeded smoothly after error conversion fix.

## User Setup Required

None - no external service configuration required. Playlist import functions will be exposed via Tauri commands in Phase 6 UI implementation.

## Next Phase Readiness

**Ready for Phase 5 (Device Sync):**
- Playlist CRUD operations complete (04-02)
- Smart playlists and liked playlists working (04-03)
- Source playlist import functional (04-04)
- Playlist tagging implemented (04-05, pending)

**What's available:**
- refresh_mirrored_playlist: add-only semantics for syncing playlists from sources
- import_spotify_playlist, import_spotify_liked_songs: Spotify playlist import
- import_soundcloud_playlist, import_soundcloud_liked_songs: SoundCloud playlist import
- Cross-source deduplication prevents duplicate downloads

**Next steps:**
- Phase 04-05: Playlist tag management (final playlist management plan)
- Phase 05: Device sync with M3U8 export for Rockbox

---
*Phase: 04-playlist-management*
*Completed: 2026-02-04*
