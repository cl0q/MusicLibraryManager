---
phase: 06-desktop-ui
plan: 05
subsystem: ui
tags: [react, react-router, wavesurfer.js, react-contexify, tauri]

# Dependency graph
requires:
  - phase: 06-03
    provides: "Library browser with virtualized table"
provides:
  - "Right-click context menu for library tracks with 6 actions"
  - "Track detail page with metadata panel and waveform visualization"
  - "Integration of Phase 3-5 components into unified router"
  - "Complete 7-route desktop UI application"
affects: [phase-7-enhancements, ui-polish, ux-improvements]

# Tech tracking
tech-stack:
  added: [wavesurfer.js, react-contexify]
  patterns: ["Context menu pattern with react-contexify", "WaveSurfer.js audio visualization", "Page wrapper components for unified layout", "convertFileSrc for Tauri file URLs"]

key-files:
  created:
    - ui/src/components/LibraryTable/RowContextMenu.tsx
    - ui/src/pages/TrackDetail.tsx
    - ui/src/components/TrackDetail/MetadataPanel.tsx
    - ui/src/components/TrackDetail/WaveformView.tsx
    - ui/src/pages/Playlists.tsx
    - ui/src/pages/PlaylistDetailPage.tsx
    - ui/src/pages/Sync.tsx
  modified:
    - ui/src/components/LibraryTable/LibraryTable.tsx
    - ui/src/App.tsx
    - ui/index.html

key-decisions:
  - "react-contexify for context menus - lightweight and dark mode compatible"
  - "wavesurfer.js for audio waveform visualization - established library with good React integration"
  - "Tauri opener plugin for Reveal in File Manager functionality"
  - "convertFileSrc from @tauri-apps/api/core for local audio file URLs"
  - "Add to Library action fetches available sync profiles for user selection"
  - "Page wrapper pattern for integrating existing Phase 3-5 components"
  - "Removed leftover Vite template CSS (App.css) for clean slate"
  - "color-scheme meta tag for proper OS dark mode detection"

patterns-established:
  - "Context menu integration: useContextMenu hook with Menu component, show() on onContextMenu event"
  - "Audio visualization: WaveSurfer.create() in useEffect with cleanup on unmount, convertFileSrc for Tauri URLs"
  - "Page wrappers: Thin wrapper components route existing components into MainLayout"
  - "Tauri file operations: invoke plugin:opener|reveal_item_in_dir for native file manager reveal"

# Metrics
duration: 101min
completed: 2026-02-04
---

# Phase 6 Plan 5: Context Menus, Track Detail View, and Component Integration Summary

**Complete desktop UI with context menus, track detail visualization, and unified 7-route navigation integrating all Phase 3-5 components**

## Performance

- **Duration:** 1h 41m (101 minutes)
- **Started:** 2026-02-04T18:48:52Z (first commit)
- **Completed:** 2026-02-04T20:29:18Z
- **Tasks:** 4 (3 auto + 1 human-verify checkpoint)
- **Files modified:** 11 (7 created, 4 modified)

## Accomplishments

- Library table right-click context menu with 6 actions (View Details, Add to Playlist, Download, Sync to Device, Add to Library, Reveal in File Manager)
- Track detail page with two-column metadata panel and interactive waveform visualization using wavesurfer.js
- Integration of Phase 3-5 components (PlaylistList, PlaylistDetail, SyncProfiles) into unified router with page wrappers
- All 7 routes working: /, /library, /library/:trackId, /playlists, /playlists/:id, /sync, /downloads
- Clean slate styling with Vite template CSS removed and color-scheme meta tag added

## Task Commits

Each task was committed atomically:

1. **Task 1: Create context menu for library table rows** - `ab9049e` (feat)
   - RowContextMenu component with 6 actions using react-contexify
   - Integration into LibraryTable with right-click handler
   - Toast notifications for user feedback

2. **Task 2: Create track detail page with waveform visualization** - `e829ee3` (feat)
   - MetadataPanel with 2-column grid layout
   - WaveformView with WaveSurfer.js and play/pause controls
   - TrackDetail page with back navigation
   - /library/:trackId route added

3. **Task 3: Integrate existing Playlists and Sync components** - `8651f9a` (feat)
   - Page wrapper components for Playlists, PlaylistDetail, Sync
   - Updated App.tsx router with actual components
   - All Phase 3-5 components now in unified layout

4. **Task 4: Human verification checkpoint** - `approved`
   - Dark mode follows OS preference verified
   - All routes navigable and functional
   - Context menu actions working correctly

**Cleanup fix:** `2ffdfcd` (fix: remove leftover Vite template CSS and add color-scheme meta)

**Plan metadata:** (to be committed)

## Files Created/Modified

**Created:**
- `ui/src/components/LibraryTable/RowContextMenu.tsx` - Context menu with 6 actions using react-contexify
- `ui/src/pages/TrackDetail.tsx` - Track detail page with back navigation and metadata/waveform panels
- `ui/src/components/TrackDetail/MetadataPanel.tsx` - Two-column metadata display with semantic HTML
- `ui/src/components/TrackDetail/WaveformView.tsx` - WaveSurfer.js audio waveform visualization with controls
- `ui/src/pages/Playlists.tsx` - Wrapper page for PlaylistList component
- `ui/src/pages/PlaylistDetailPage.tsx` - Wrapper page for PlaylistDetail component with navigation
- `ui/src/pages/Sync.tsx` - Wrapper page for SyncProfiles component

**Modified:**
- `ui/src/components/LibraryTable/LibraryTable.tsx` - Added context menu integration with right-click handler
- `ui/src/App.tsx` - Updated router with all 7 routes using actual components
- `ui/index.html` - Added color-scheme meta tag, updated title
- `ui/src/App.css` - Deleted (leftover Vite template styles)

## Decisions Made

1. **react-contexify for context menus** - Lightweight library with excellent dark mode support and React integration, simpler than building custom menu positioning logic

2. **wavesurfer.js for audio visualization** - Established library with proven track record, handles various audio formats, easy React integration with useEffect cleanup pattern

3. **Tauri opener plugin for file manager reveal** - Native cross-platform file manager integration via `plugin:opener|reveal_item_in_dir` command

4. **convertFileSrc for audio URLs** - Tauri v2 API function converts local file paths to Tauri-compatible URLs for WaveSurfer.js to load

5. **Add to Library fetches sync profiles** - Context menu action lists available sync profiles, enables future profile selection for track assignment

6. **Page wrapper pattern** - Created thin wrapper components (Playlists.tsx, PlaylistDetailPage.tsx, Sync.tsx) to integrate Phase 3-5 components into MainLayout without modifying originals

7. **Removed Vite template CSS** - App.css contained unused Vite boilerplate styles, deleted for clean slate

8. **color-scheme meta tag** - Added to index.html for proper OS-level dark mode detection, ensures Tailwind dark mode works correctly

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed leftover Vite template CSS and added color-scheme meta**
- **Found during:** Human verification checkpoint (Task 4)
- **Issue:** App.css contained unused Vite boilerplate styles that weren't referenced anywhere. Missing color-scheme meta tag prevented proper OS dark mode detection.
- **Fix:** Deleted ui/src/App.css entirely. Added `<meta name="color-scheme" content="dark light" />` to ui/index.html for OS-level dark mode support. Updated page title to "Music Library Manager".
- **Files modified:** ui/src/App.css (deleted), ui/index.html
- **Verification:** Dark mode now properly follows OS preference, no unused CSS files in project
- **Committed in:** `2ffdfcd` (separate cleanup commit)

---

**Total deviations:** 1 auto-fixed (1 bug/cleanup)
**Impact on plan:** Cleanup fix improved code hygiene and fixed dark mode detection. No scope changes.

## Issues Encountered

None - all planned functionality implemented successfully. WaveSurfer.js integration worked smoothly with convertFileSrc for Tauri file URLs. Context menu positioning and styling matched design intent on first implementation.

## User Setup Required

None - no external service configuration required. All UI components use existing Tauri commands from Phase 3-5 backends.

## Next Phase Readiness

**Phase 6 Complete - Ready for Phase 7 Enhancements:**
- Desktop UI fully functional with all 7 sections navigable
- All Phase 3-5 backend functionality accessible through UI
- Foundation established for quality-of-life improvements:
  - Acoustic fingerprinting UI could integrate into track detail page
  - Album artwork display ready for metadata panel
  - ReplayGain controls could be added to playback interface

**Phase 6 Deliverables Verified:**
- Dashboard with stats cards and activity feed ✓
- Library browser with virtualized table ✓
- Context menus with 6 actions ✓
- Track detail with waveform ✓
- Downloads page with real-time progress ✓
- Playlists management UI ✓
- Sync profile UI ✓
- Light/dark mode support ✓

**No blockers for Phase 7.**

---
*Phase: 06-desktop-ui*
*Completed: 2026-02-04*
