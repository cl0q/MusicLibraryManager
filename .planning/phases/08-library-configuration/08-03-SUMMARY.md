---
phase: 08-library-configuration
plan: 03
subsystem: ui, settings
tags: [react, tailwind, settings-ui, first-run-wizard, library-setup]

# Dependency graph
requires:
  - phase: 08-01
    provides: Tauri commands for library configuration
provides:
  - Settings page with library folder picker and subfolder selection
  - FirstRunWizard modal for first-launch setup
  - LibrarySetup component reusable in both Settings and Wizard
  - TypeScript command wrappers for library config
  - Sidebar Settings navigation item
affects: [08-04-disconnected-state-ui]

# Tech tracking
tech-stack:
  added: []
  patterns: [native folder picker via Tauri dialog, subfolder checkbox selection]

key-files:
  created:
    - ui/src/pages/Settings.tsx
    - ui/src/components/Settings/LibrarySetup.tsx
    - ui/src/components/Settings/FirstRunWizard.tsx
  modified:
    - ui/src/utils/tauri-commands.ts
    - ui/src/App.tsx
    - ui/src/components/Sidebar/Sidebar.tsx
    - ui/src/pages/Sources.tsx

key-decisions:
  - "FirstRunWizard renders in App.tsx as fixed overlay outside RouterProvider"
  - "LibrarySetup component shared between Settings page and FirstRunWizard"
  - "Settings accessible via sidebar gear icon at bottom of nav list"
  - "Sources Local Library status checks actual get_library_config() state"
  - "Sources sync uses configured library root path, not random folder picker"

patterns-established:
  - "First-run config check on App mount with session-level wizard state"
  - "Native folder picker → subfolder listing → save flow"

# Metrics
duration: 25min
completed: 2026-02-07
---

# Phase 8 Plan 03: Settings UI & First-Run Wizard Summary

**Settings page with library folder picker, subfolder selection, download destination configuration, first-run wizard modal, and integration fixes for Sources page**

## Performance

- **Duration:** ~25 min (including checkpoint fixes)
- **Completed:** 2026-02-07
- **Tasks:** 2 auto + 1 checkpoint (with follow-up fixes)
- **Files modified:** 9

## Accomplishments
- Settings page with LibrarySetup component for library folder configuration
- Native OS folder picker opens via Tauri dialog plugin
- Subfolder checkboxes populate after folder selection
- Download destination separately configurable
- FirstRunWizard modal shows on first launch when library not configured
- Wizard can be skipped; library features remain disabled
- Settings accessible via sidebar gear icon
- Sources page correctly reflects actual library configuration state
- Sync uses configured library path instead of random folder picker
- Missing `reveal_in_file_manager` backend command added

## Task Commits

1. **Initial Settings UI implementation** - executor agent commits
2. **Integration fixes after checkpoint testing** - `42c879c` (fix: Sources page config integration, import_directory param)
3. **Reveal in file manager command** - `e1a4d91` (fix: add reveal_in_file_manager backend command)

## Files Created/Modified

### Created
- `ui/src/pages/Settings.tsx` - Settings page rendering LibrarySetup
- `ui/src/components/Settings/LibrarySetup.tsx` - Library setup form with folder picker, subfolder selection
- `ui/src/components/Settings/FirstRunWizard.tsx` - First-run modal wizard wrapping LibrarySetup

### Modified
- `ui/src/utils/tauri-commands.ts` - Added LibraryConfig interface, 6 command wrappers, fixed import_directory param name
- `ui/src/App.tsx` - Added wizard state check, Settings route, FirstRunWizard rendering
- `ui/src/components/Sidebar/Sidebar.tsx` - Added Settings nav item with gear icon
- `ui/src/pages/Sources.tsx` - Fixed Local Library status to check actual config, sync uses configured path
- `src-tauri/src/commands/library_config.rs` - Added reveal_in_file_manager command
- `src-tauri/src/lib.rs` - Registered reveal_in_file_manager command

## Checkpoint Issues Found & Fixed

### 1. import_directory parameter mismatch
- **Issue:** TypeScript wrapper sent `{ path }` but Rust command expects `{ directory }`
- **Error:** `command import_directory missing required key directory`
- **Fix:** Changed param name in tauri-commands.ts to match backend

### 2. Sources page hardcoded Local Library as "connected"
- **Issue:** Sources.tsx set `setLocalLibrary({ status: "connected" })` regardless of config
- **Fix:** Now checks `get_library_config()` and sets status based on `configured` flag

### 3. Sources sync opened random folder picker
- **Issue:** Sync handler used `openDialog({directory: true})` to pick any folder
- **Fix:** Uses configured library root path from `get_library_config()`

### 4. First-run wizard not appearing
- **Issue:** Stale test data in `music_library.db` made library appear configured
- **Fix:** Cleared stale app_config data; tests should use in-memory DB

### 5. Missing reveal_in_file_manager command
- **Issue:** RowContextMenu invoked command with no backend handler
- **Fix:** Added cross-platform command (macOS/Windows/Linux)

## Next Phase Readiness

**Ready for Phase 8 Plan 04 (Disconnected State UI):**
- Settings page and wizard fully functional
- Library configuration state correctly tracked
- Backend mount detection operational (from 08-02)
- Frontend needs LibraryMountContext to react to mount events

**No blockers or concerns.**

---
*Phase: 08-library-configuration*
*Completed: 2026-02-07*
