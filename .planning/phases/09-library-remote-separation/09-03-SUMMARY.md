---
phase: 09-library-remote-separation
plan: 03
subsystem: ui
tags: [react, tanstack-table, routing, view-filtering]

# Dependency graph
requires:
  - phase: 09-01
    provides: Backend commands for library/remote filtering (get_library_tracks_only, get_remote_tracks_only)
  - phase: 09-02
    provides: TypeScript wrapper functions for backend commands (getLibraryTracksOnly, getRemoteTracksOnly)
provides:
  - Route-based view switching for library vs remote tracks
  - Unified LibraryBrowser component for both views
  - Format column normalization (Stream for streaming, audio format for local)
affects: [09-04-ui-indicators, future-navigation, search-filtering]

# Tech tracking
tech-stack:
  added: []
  patterns: [route-based-view-parameter, conditional-command-invocation]

key-files:
  created: []
  modified:
    - ui/src/hooks/useLibraryTracks.ts
    - ui/src/pages/LibraryBrowser.tsx
    - ui/src/App.tsx
    - ui/src/components/LibraryTable/LibraryTable.tsx

key-decisions:
  - "View parameter defaults to 'library' for backward compatibility with existing code"
  - "Format column normalization implemented to show 'Stream' for spotify/soundcloud, actual formats for local files"

patterns-established:
  - "View filtering via hook parameter that determines backend command"
  - "Route-driven data fetching using view prop passed from router"

# Metrics
duration: 2min
completed: 2026-02-07
---

# Phase 09 Plan 03: Library/Remote View Switching Summary

**Route-based view switching enables /library to show local files and /remote to show streaming tracks using same UI components with filtered data sources**

## Performance

- **Duration:** 2 minutes
- **Started:** 2026-02-07T15:29:13Z
- **Completed:** 2026-02-07T15:31:24Z
- **Tasks:** 4
- **Files modified:** 4

## Accomplishments
- useLibraryTracks hook now accepts view parameter ('library' | 'remote')
- LibraryBrowser component accepts view prop and passes to data hook
- /library and /remote routes defined in App router
- Format column displays audio format for local files, "Stream" for streaming tracks

## Task Commits

Each task was committed atomically:

1. **Task 1 & 2: Add view filtering to useLibraryTracks and LibraryBrowser** - `f650d01` (feat)
   - Updated hook signature to accept view parameter
   - Conditional command invocation based on view
   - LibraryBrowser accepts and passes view prop

2. **Task 3: Add /remote route** - `0dd59f0` (feat)
   - Added /remote route to App router
   - Explicit view parameters on both routes

3. **Task 4: Fix Format column** - `fef7ea0` (feat) [from parallel 09-02]
   - Format column normalization already implemented
   - Shows "Stream" for spotify/soundcloud sources
   - Shows actual audio format (FLAC, MP3, AAC) for local files

## Files Created/Modified
- `ui/src/hooks/useLibraryTracks.ts` - Added view parameter, conditional command invocation
- `ui/src/pages/LibraryBrowser.tsx` - Added view prop, passes to hook
- `ui/src/App.tsx` - Added /remote route definition
- `ui/src/components/LibraryTable/LibraryTable.tsx` - Format column normalization (from 09-02)

## Decisions Made

**View parameter backward compatibility:**
- Default to 'library' view when no parameter provided
- Ensures existing code calling useLibraryTracks() continues working
- Migration path: existing routes get explicit view="library" parameter

**Format column normalization:**
- Streaming sources (spotify, soundcloud) display as "Stream"
- Local files show actual audio format in uppercase
- Satisfies LVIEW-02 requirement for format column clarity

## Deviations from Plan

### Parallel Work Alignment

**Task 4 format column fix already implemented:**
- **Found during:** Task 4 execution
- **Context:** Parallel plan 09-02 already implemented format column normalization
- **Resolution:** Verified existing implementation matches requirements, no additional commit needed
- **Commit:** fef7ea0 (from 09-02)
- **Impact:** None - requirement satisfied, no duplicate work

---

**Total deviations:** 0 auto-fixed
**Impact on plan:** No deviations. One task completed by parallel plan, requirements fully satisfied.

## Issues Encountered

None - TypeScript compilation successful on first build for all tasks.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for next phase:**
- Library/Remote view switching fully functional
- Route-based filtering working correctly
- UI components reusable across both views
- Format column displays correctly for both view types

**For 09-04 (UI Indicators):**
- Navigation between /library and /remote works
- Table component can be extended with download indicators
- View state is deterministic from route path

**Verified:**
- TypeScript compiles without errors
- Routes defined and accessible
- Hook signature backward compatible
- Format display normalized

---
*Phase: 09-library-remote-separation*
*Completed: 2026-02-07*

## Self-Check: PASSED

All modified files exist and all commits verified in git history.
