---
phase: 09-library-remote-separation
plan: 02
subsystem: ui
tags: [typescript, react, sidebar-navigation, event-driven-ui, tauri-commands]

# Dependency graph
requires:
  - phase: 09-01
    provides: Backend query commands (get_library_tracks_only, get_remote_tracks_only, get_remote_track_count)
provides:
  - Remote navigation item in sidebar with badge count
  - TypeScript wrappers for library/remote query commands
  - Event-driven badge updates on import/sync/download events
affects: [09-03, 09-04, remote-view-implementation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Event-driven badge counts for real-time UI updates"
    - "Sidebar navigation follows mount-state independence pattern"

key-files:
  created: []
  modified:
    - ui/src/utils/tauri-commands.ts
    - ui/src/components/Sidebar/Sidebar.tsx

key-decisions:
  - "Remote nav item disabled: false (always accessible, per requirement REM-04)"
  - "Badge updates via event listeners (import-complete, sync-complete, download-complete)"
  - "Cloud icon for Remote item (consistent with network/streaming semantics)"

patterns-established:
  - "TypeScript wrapper functions follow camelCase naming (getRemoteTrackCount vs. get_remote_track_count)"
  - "Event-driven count updates prevent polling overhead for frequently changing data"

# Metrics
duration: 2min
completed: 2026-02-07
---

# Phase 9 Plan 02: Remote Sidebar Navigation Summary

**Sidebar Remote nav item with event-driven badge count updates for undownloaded streaming tracks**

## Performance

- **Duration:** 2 minutes
- **Started:** 2026-02-07T15:28:34Z
- **Completed:** 2026-02-07T15:30:49Z
- **Tasks:** 2/2
- **Files modified:** 2

## Accomplishments
- TypeScript wrappers for three new backend commands (getLibraryTracksOnly, getRemoteTracksOnly, getRemoteTrackCount)
- Remote navigation item in sidebar with badge count showing undownloaded track count
- Event-driven badge updates (import-complete, sync-complete, download-complete events)
- Remote item always accessible regardless of library mount state (disabled: false)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add TypeScript wrappers for new backend commands** - `398f840` (feat)
2. **Task 2: Add Remote nav item to Sidebar with badge count** - `fef7ea0` (feat)

## Files Created/Modified
- `ui/src/utils/tauri-commands.ts` - Added getLibraryTracksOnly, getRemoteTracksOnly, getRemoteTrackCount wrapper functions
- `ui/src/components/Sidebar/Sidebar.tsx` - Added Remote nav item with event-driven badge count state management

## Decisions Made
- **Remote always accessible:** Remote nav item has `disabled: false` (not dependent on isLibraryAvailable) per requirement REM-04, allowing users to view streaming tracks even when library drive is disconnected
- **Event-driven updates:** Badge count updates via window event listeners for import-complete, sync-complete, download-complete events instead of polling, reducing unnecessary backend calls
- **Cloud icon choice:** Selected cloud icon for Remote item to reinforce network/streaming semantics (consistent with Sources icon style)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Plan 03 (Remote view implementation):**
- Frontend has TypeScript wrappers for all backend query commands
- Sidebar navigation structure complete with Remote item at /remote path
- Badge count mechanism tested and working with event-driven updates
- UI follows mount-state independence pattern (Remote accessible when library drive disconnected)

**No blockers or concerns.**

---
*Phase: 09-library-remote-separation*
*Completed: 2026-02-07*

## Self-Check: PASSED
