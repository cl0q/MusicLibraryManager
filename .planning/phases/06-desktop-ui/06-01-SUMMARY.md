---
phase: 06-desktop-ui
plan: 01
subsystem: ui
tags: [react, react-router, tailwind, tauri, sonner, typescript]

# Dependency graph
requires:
  - phase: 05-device-sync
    provides: Tauri commands for sync operations, existing React components (SyncProfiles, SyncPreview, PlaylistList, PlaylistDetail)
provides:
  - App shell with persistent sidebar navigation (5 sections: Dashboard, Library, Playlists, Sync, Downloads)
  - React Router configuration with nested routes
  - Expandable status bar with operation display at bottom
  - Toast notification system via Sonner
  - Type definitions for Track, Album, Artist, ActivityEvent, DownloadProgressEvent
  - Typed Tauri command wrappers
affects: [06-02-dashboard, 06-03-library-browser, 06-04-playlist-ui, 06-05-downloads-queue]

# Tech tracking
tech-stack:
  added: [react-router, sonner, react-contexify, @tanstack/react-table, @tanstack/react-virtual, wavesurfer.js, @tauri-apps/api]
  patterns: [React Router nested routes, persistent layout with Outlet, expandable status bar with click interaction, NavLink active state styling]

key-files:
  created:
    - ui/src/App.tsx
    - ui/src/layouts/MainLayout.tsx
    - ui/src/components/Sidebar/Sidebar.tsx
    - ui/src/components/StatusBar/StatusBar.tsx
    - ui/src/components/Notifications/ToastProvider.tsx
    - ui/src/types/library.ts
    - ui/src/types/events.ts
    - ui/src/utils/tauri-commands.ts
  modified:
    - ui/package.json
    - ui/src/components/SyncProfiles.tsx
    - ui/src/components/SyncPreview.tsx
    - ui/src/hooks/usePlaylists.ts
    - ui/src/components/Playlists/PlaylistDetail.tsx
    - ui/src/components/Playlists/PlaylistList.tsx

key-decisions:
  - "React Router for client-side navigation with nested routes"
  - "Sonner for toast notifications (clean, modern, good UX)"
  - "Sidebar fixed at 240px width, clean Spotify/Linear aesthetic"
  - "Status bar clickable header for expand/collapse (user discovery via click interaction)"
  - "Expanded status bar height: 240px (h-60) for detailed operation view"
  - "Placeholder operations data - will be connected to Tauri events in later plans"
  - "Light/dark mode support via Tailwind dark: classes throughout"

patterns-established:
  - "MainLayout wraps Sidebar + Outlet + StatusBar for persistent shell"
  - "NavLink with isActive callback for active route highlighting"
  - "Clickable header bar pattern for expand/collapse UI components"
  - "Smooth transitions with Tailwind transition-all duration-300 ease-in-out"
  - "Type-only imports with 'type' keyword for TypeScript verbatimModuleSyntax"

# Metrics
duration: 3m 55s
completed: 2026-02-04
---

# Phase 6 Plan 1: App Shell & Navigation Summary

**React Router app shell with persistent sidebar navigation (5 sections), expandable status bar with operation details, and toast notifications via Sonner**

## Performance

- **Duration:** 3 min 55 sec
- **Started:** 2026-02-04T18:32:41Z
- **Completed:** 2026-02-04T18:36:36Z
- **Tasks:** 3
- **Files modified:** 14 (8 created, 6 modified)

## Accomplishments
- Foundational UI infrastructure established with persistent navigation shell
- Five-section sidebar navigation with active state highlighting
- Expandable status bar at bottom (collapsed 40px, expanded 240px) with smooth animations
- Toast notification system integrated via Sonner
- Type definitions for Track, Album, Artist, ActivityEvent, DownloadProgressEvent
- Typed Tauri command wrappers for playlist, sync, search, import, and download operations
- Fixed existing Phase 4/5 components to use correct Tauri v2 API imports

## Task Commits

Each task was committed atomically:

1. **Task 1: Install dependencies and configure React Router** - `e2178ff` (feat)
2. **Task 2: Create MainLayout with persistent sidebar** - `2b3464e` (feat)
3. **Task 3: Create StatusBar with expand/collapse and ToastProvider** - `3fbbed5` (feat)

**Bug fixes (deviation):** `8f670f3` (fix: Tauri v2 API imports)

## Files Created/Modified

### Created
- `ui/src/App.tsx` - React Router configuration with 5 routes (/, /library, /playlists, /playlists/:id, /sync, /downloads)
- `ui/src/layouts/MainLayout.tsx` - Persistent layout with sidebar, content area (Outlet), and status bar
- `ui/src/components/Sidebar/Sidebar.tsx` - Five-section navigation with icons, labels, and active state highlighting
- `ui/src/components/StatusBar/StatusBar.tsx` - Expandable status bar with clickable header, operation details, progress bars
- `ui/src/components/Notifications/ToastProvider.tsx` - Sonner Toaster wrapper component
- `ui/src/types/library.ts` - Track, Album, Artist type definitions
- `ui/src/types/events.ts` - ActivityEvent, DownloadProgressEvent type definitions
- `ui/src/utils/tauri-commands.ts` - Typed wrappers for Tauri commands (playlists, sync, search, import, downloads)

### Modified
- `ui/package.json` - Added react-router, sonner, react-contexify, @tanstack/react-table, @tanstack/react-virtual, wavesurfer.js, @tauri-apps/api
- `ui/src/components/SyncProfiles.tsx` - Fixed Tauri import (api/tauri → api/core), removed unused React import
- `ui/src/components/SyncPreview.tsx` - Fixed Tauri import, removed unused React import
- `ui/src/hooks/usePlaylists.ts` - Fixed Tauri import
- `ui/src/components/Playlists/PlaylistDetail.tsx` - Fixed Tauri import, added type-only imports, fixed NodeJS.Timeout → ReturnType<typeof setTimeout>
- `ui/src/components/Playlists/PlaylistList.tsx` - Fixed Tauri import, added type-only imports

## Decisions Made

1. **React Router for navigation** - Client-side routing with nested routes, clean URL structure
2. **Sonner for toasts** - Modern, clean UX, good developer experience, built-in dark mode support
3. **Sidebar width: 240px** - Standard width for side navigation, balances visibility with content space
4. **Status bar expand/collapse via click** - User discovery through interaction, no dedicated expand button cluttering UI
5. **Expanded height: 240px** - Enough space for 5-7 operations visible without dominating screen
6. **Placeholder operations** - Status bar shows static placeholder data, will be connected to Tauri events in later plans
7. **Type-only imports** - Used `type` keyword for TypeScript verbatimModuleSyntax compliance

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed incorrect Tauri v2 API imports**
- **Found during:** Task 1 (Build verification)
- **Issue:** Existing Phase 4/5 components using `@tauri-apps/api/tauri` import (Tauri v1 API), breaking build with "Cannot find module" errors. Tauri v2 uses `@tauri-apps/api/core` for invoke function.
- **Fix:** Updated imports in 5 files (SyncProfiles.tsx, SyncPreview.tsx, usePlaylists.ts, PlaylistDetail.tsx, PlaylistList.tsx) to use correct Tauri v2 import path
- **Files modified:** ui/src/components/SyncProfiles.tsx, ui/src/components/SyncPreview.tsx, ui/src/hooks/usePlaylists.ts, ui/src/components/Playlists/PlaylistDetail.tsx, ui/src/components/Playlists/PlaylistList.tsx
- **Verification:** Build passed after fix, TypeScript errors resolved
- **Committed in:** `8f670f3` (separate commit for bug fix)

**2. [Rule 1 - Bug] Removed unused React imports**
- **Found during:** Task 1 (Build verification)
- **Issue:** Components importing `React` but not using it (React 19 auto-imports JSX transform). TypeScript error: "'React' is declared but its value is never read"
- **Fix:** Removed `React` from imports, kept only specific hooks (useState, useEffect, etc.)
- **Files modified:** Same 5 files as above
- **Verification:** Build passed, no unused import warnings
- **Committed in:** `8f670f3` (same bug fix commit)

**3. [Rule 1 - Bug] Fixed TypeScript verbatimModuleSyntax type import errors**
- **Found during:** Task 1 (Build verification)
- **Issue:** TypeScript config has `verbatimModuleSyntax: true` requiring explicit type-only imports. Errors: "'DropResult' is a type and must be imported using a type-only import"
- **Fix:** Changed `import { Type }` to `import { type Type }` for DropResult, Playlist, Track in PlaylistDetail.tsx and PlaylistList.tsx
- **Files modified:** PlaylistDetail.tsx, PlaylistList.tsx
- **Verification:** Build passed, TypeScript verbatimModuleSyntax satisfied
- **Committed in:** `8f670f3` (same bug fix commit)

**4. [Rule 1 - Bug] Fixed NodeJS.Timeout type error**
- **Found during:** Task 1 (Build verification)
- **Issue:** `NodeJS.Timeout` type not found. TypeScript error: "Cannot find namespace 'NodeJS'"
- **Fix:** Changed `NodeJS.Timeout` to `ReturnType<typeof setTimeout>` (standard TypeScript pattern for timer types)
- **Files modified:** PlaylistDetail.tsx
- **Verification:** Build passed, type error resolved
- **Committed in:** `8f670f3` (same bug fix commit)

---

**Total deviations:** 4 auto-fixed (all Rule 1 - Bugs in existing Phase 4/5 components)
**Impact on plan:** All auto-fixes necessary for build correctness. These were pre-existing bugs from Phase 4/5 that blocked Plan 06-01 execution. No scope creep - only fixed broken imports and TypeScript errors preventing compilation.

## Issues Encountered

None - plan executed smoothly after fixing pre-existing component bugs.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Plan 06-02 (Dashboard):**
- App shell complete with working navigation
- Sidebar navigation functional
- Status bar ready to receive operation data from Tauri events
- Toast notification system ready to use
- Type definitions in place for Track, ActivityEvent, DownloadProgressEvent

**Ready for Plan 06-03 (Library Browser):**
- MainLayout Outlet ready to render library table component
- Type definitions for Track created
- Tauri command wrappers for search_library ready

**Ready for Plan 06-04 (Playlist UI Integration):**
- Existing PlaylistList and PlaylistDetail components now importable (bugs fixed)
- Playlists route configured in router

**Ready for Plan 06-05 (Downloads Queue):**
- Downloads route configured
- Status bar ready to display download operations
- Type definitions for DownloadProgressEvent created

**Blockers/Concerns:** None

---
*Phase: 06-desktop-ui*
*Completed: 2026-02-04*
