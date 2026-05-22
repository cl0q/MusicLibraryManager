---
phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
plan: 04
subsystem: ui
tags: [swiftui, maintenance, artwork, testing, swift-testing]

requires:
  - phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
    plan: 02
    provides: ArtworkBackfillService.refreshMissing() public API + container.artworkBackfillService
  - phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
    plan: 01
    provides: ArtworkExtractor thin wrapper delegating to ArtworkService.extractEmbeddedArtwork (static)

provides:
  - MaintenanceView split: two distinct artwork buttons replacing the old single 'Fetch Artwork' button (D-16)
  - runArtworkEmbedded(): calls container.artworkBackfillService?.refreshMissing() — ffmpeg, no network
  - runArtworkMusicBrainz(): inline ArtworkService instantiation for MusicBrainz fetch — network, rate-limited
  - ArtworkExtractorTests.swift: 3 tests verifying static delegation contract (Phase 37 Plan 01 change)
  - Full test suite green: 142 tests in 16 suites, 0 failures

affects: [Phase 37 UAT, human verification of all 3 artwork surfaces + both maintenance buttons]

tech-stack:
  added: []
  patterns:
    - "Dual-button maintenance action split: distinct action identifiers for isRunning state management"
    - "Inline service instantiation for non-container services in maintenance views"
    - "Swift Testing @Suite + async tests for static delegation verification"

key-files:
  created:
    - macos-app/MLMTests/ServiceTests/ArtworkExtractorTests.swift
  modified:
    - macos-app/MLM/Views/Settings/MaintenanceView.swift

key-decisions:
  - "runArtworkEmbedded uses container.artworkBackfillService (no ArtworkService instantiation) — service handles cacheDir internally"
  - "runArtworkMusicBrainz instantiates ArtworkService inline (not on container) — mirrors former runArtwork() pattern exactly"
  - "isRunning action identifiers changed from 'artwork' to 'artwork-embedded'/'artwork-musicbrainz' — no UI regression since maintenanceRow is generic"
  - "ArtworkExtractorTests tests delegation via nil-return contract (non-existent URLs) — avoids needing real audio fixtures"

requirements-completed: [S-10]

duration: 2min
completed: 2026-05-16
---

# Phase 37 Plan 04: MaintenanceView split + ArtworkExtractorTests — Summary

**MaintenanceView 'Fetch Artwork' button split into 'Refresh embedded artwork' (ffmpeg, BackfillService) + 'Fetch from MusicBrainz' (inline ArtworkService) per D-16; ArtworkExtractorTests added verifying static delegation; 142/142 tests green**

## Performance

- **Duration:** 2 min
- **Started:** 2026-05-16T15:00:55Z
- **Completed:** 2026-05-16T15:03:33Z
- **Tasks:** 1 auto task (+ 1 human-verify UAT checkpoint pending)
- **Files modified:** 2

## Accomplishments

- Replaced single `runArtwork()` / "Fetch Artwork" button with two distinct maintenance actions (D-16)
- "Refresh embedded artwork" wired directly to `container.artworkBackfillService?.refreshMissing()` — no network, fast, uses BackfillService's TaskGroup(maxConcurrentTasks:4)
- "Fetch from MusicBrainz" uses inline `ArtworkService(cacheDir:)` instantiation matching the former `runArtwork()` pattern — network, rate-limited, user-explicit
- Created `ArtworkExtractorTests.swift` with 3 Swift Testing tests verifying static delegation contract post-Plan-01 refactor
- Full test suite: 142 tests in 16 suites, 0 failures (was 136 in 15 suites before this plan)

## Task Commits

1. **Task 1: Split MaintenanceView artwork buttons + update ArtworkExtractorTests** - `6e981cb` (feat)

## Files Created/Modified

- `macos-app/MLM/Views/Settings/MaintenanceView.swift` — Replaced single artwork button + `runArtwork()` with `runArtworkEmbedded()` + `runArtworkMusicBrainz()` + two buttons; action identifiers 'artwork-embedded'/'artwork-musicbrainz'
- `macos-app/MLMTests/ServiceTests/ArtworkExtractorTests.swift` — New: 3 Swift Testing tests for ArtworkExtractor thin-wrapper delegation contract (D-05, Plan 01)

## Decisions Made

- Kept `isRunning` as `String?` with action-specific identifiers rather than introducing separate Bool state per button — simpler, consistent with existing pattern across all maintenance rows
- `runArtworkEmbedded()` does not set its own `isRunning` loop because `ArtworkBackfillService.isBackfilling` owns that state; the `isRunning = "artwork-embedded"` before call / `nil` after still gives the button a disabled state while the await is in flight
- ArtworkExtractorTests uses nil-return contract (non-existent URLs return nil from both paths) as proxy for delegation — avoids needing fixture audio files in the test bundle

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed async test function missing `async` keyword**
- **Found during:** Task 1 (ArtworkExtractorTests.swift creation)
- **Issue:** `testNoAVFoundationDependency()` was declared `throws` but contained `await` calls — compile error
- **Fix:** Added `async` to the function signature (`async throws`)
- **Files modified:** macos-app/MLMTests/ServiceTests/ArtworkExtractorTests.swift
- **Verification:** `swift test` passes, all 3 new tests green
- **Committed in:** 6e981cb (Task 1 commit, fixed inline before commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — type error caught at compile time)
**Impact on plan:** Trivial fix, no scope change.

## Issues Encountered

None — plan executed cleanly after the async keyword fix.

## Known Stubs

None — both maintenance buttons wire to real service implementations. No placeholder data.

## Threat Flags

None — no new network endpoints or auth paths introduced beyond those in the plan's threat model (T-37-02: MusicBrainz requests to hardcoded endpoint; T-37-05: rate-limit enforced by ArtworkService).

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

Code changes complete. Human UAT required to confirm:
1. Settings → Maintenance shows two distinct artwork buttons
2. "Refresh embedded artwork" triggers ffmpeg backfill via ArtworkBackfillService
3. "Fetch from MusicBrainz" triggers network fetch (rate-limited)
4. Phase 36 playlist mosaics still render correctly (regression check)

---

## CHECKPOINT REACHED

**Type:** human-verify
**Plan:** 37-04
**Progress:** 1/1 auto tasks complete (UAT checkpoint pending)

### Completed Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Split MaintenanceView artwork buttons + ArtworkExtractorTests | 6e981cb | MaintenanceView.swift (2 new funcs + 2 new buttons), ArtworkExtractorTests.swift (3 new tests) |

### Current Task

**Task 2 (Checkpoint):** Human UAT — verify both buttons in running app + Phase 36 regression
**Status:** Awaiting verification

### UAT Script

Build and run the app:
```bash
cd /Users/olli/schenanigans/MusicLibraryManager/macos-app && swift build && open .build/debug/MLM.app
```
(or open macos-app/ in Xcode and press Run)

**Mark each item PASS or FAIL:**

1. **Settings Maintenance — two buttons visible:**
   - Settings → Maintenance tab
   - Two distinct buttons: **"Refresh embedded artwork"** and **"Fetch from MusicBrainz"** (not "Fetch Artwork")
   - Both show as separate rows in the Analysis section

2. **"Refresh embedded artwork" button works:**
   - Click "Refresh embedded artwork" — a ProgressView spinner should appear briefly while running
   - Result message should appear: "Embedded artwork: refresh complete"
   - No crash, no "not available" error

3. **"Fetch from MusicBrainz" button works:**
   - Click "Fetch from MusicBrainz"
   - Result message should show fetched/cached/notFound counts
   - (Network may be slow — just confirm it starts and returns a result)

4. **Phase 36 regression — playlist mosaics still render:**
   - Navigate to Playlists (sidebar or ⌘2)
   - Verify playlist covers / auto-mosaics still render correctly
   - No blank cards, no crashes

5. **Import trigger + cover pop-in (bonus — if a music folder is available):**
   - Settings → Library → Re-Scan (or import a folder with embedded-art files)
   - LibraryTable: tracks should first show Solar-gradient fallback, then covers pop in within seconds
   - After backfill: `ls ~/Library/Caches/com.mlm.artwork_cache/ | head -10` shows `{trackId}_500.jpg` + `{trackId}_1200.jpg`

6. **LibraryTable inline covers (Plan 03 — bonus check):**
   - Library view: small square cover thumbnail inline-left of each track title
   - For tracks without artwork: Solar gradient fallback visible

7. **PlayerBar + TrackDetailView covers (Plan 03 — bonus check):**
   - Start playback: PlayerBar shows 40pt cover at left
   - Click a track: TrackDetailView shows 56pt cover in header

### Awaiting

Type **"approved"** if all items pass, or describe any failures (e.g., "Item 2 fails — spinner never appears") so I can diagnose.

---
*Phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm*
*Completed: 2026-05-16*
