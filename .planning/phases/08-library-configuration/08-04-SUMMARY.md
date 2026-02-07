---
phase: 08-library-configuration
plan: 04
subsystem: ui, contexts
tags: [react-context, tauri-events, mount-detection, sidebar, library-browser]

# Dependency graph
requires:
  - phase: 08-02
    provides: MountDetector backend with Tauri events
  - phase: 08-03
    provides: Settings UI, FirstRunWizard, LibrarySetup
provides:
  - LibraryMountContext for app-wide mount state
  - Sidebar mount-aware Library item styling
  - LibraryBrowser disconnected empty state
  - Auto-refresh on drive reconnection
affects: [09-library-remote-separation]

# Tech tracking
tech-stack:
  added: []
  patterns: [React context with Tauri event listener, window custom events for cross-component communication]

key-files:
  created:
    - ui/src/contexts/LibraryMountContext.tsx
  modified:
    - ui/src/layouts/MainLayout.tsx
    - ui/src/components/Sidebar/Sidebar.tsx
    - ui/src/pages/LibraryBrowser.tsx
    - ui/src/hooks/useLibraryTracks.ts
    - ui/src/components/Settings/LibrarySetup.tsx

key-decisions:
  - "Window custom events (library-configured, library-reconnected) for cross-component communication"
  - "LibraryMountProvider wraps MainLayout, not App (wizard is outside)"
  - "Library nav item stays clickable when grayed out (shows empty state with instructions)"

# Metrics
duration: 30min
completed: 2026-02-07
---

# Phase 8 Plan 04: Disconnected State UI Summary

**LibraryMountContext providing app-wide mount state, sidebar mount-aware styling, library disconnected empty state, and auto-refresh on reconnection**

## Accomplishments
- LibraryMountContext created with provider and useLibraryMount hook
- Provider subscribes to Tauri `library-mount-changed` events
- Mount state initialized from backend on app load
- Provider wrapped around app layout in MainLayout.tsx
- Sidebar Library item grayed out when drive disconnected or not configured
- LibraryBrowser shows empty state with "Open Settings" button
- Different messages for "not configured" vs "disconnected" states
- Drive reconnection triggers silent library refresh
- Sources page unaffected by library mount state (LCFG-04)

## Checkpoint Issues Found & Fixed

### 1. Mount state not refreshing after library configuration
- **Issue:** After saving config in Settings, LibraryMountContext kept stale state
- **Fix:** LibrarySetup dispatches `library-configured` window event; context listens and re-checks

### 2. Import failing for 27k files due to duplicate handling
- **Issue:** `INSERT` on tracks with UNIQUE original_path caused entire batch of 50 to fail when any duplicate existed
- **Fix:** Changed to `INSERT OR IGNORE`, duplicates silently skipped

---
*Phase: 08-library-configuration*
*Completed: 2026-02-07*
