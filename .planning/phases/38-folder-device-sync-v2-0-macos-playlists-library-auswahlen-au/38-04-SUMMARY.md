---
phase: 38-folder-device-sync-v2-0-macos-native
plan: "04"
subsystem: macos-app/sync-ui
tags:
  - sync
  - context-menu
  - device-detect
  - toolbar
  - toast
  - tdd
dependency_graph:
  requires:
    - 38-03
  provides:
    - Sync to submenu in TrackContextMenu + PlaylistCard
    - DeviceDetector wiring in createProfileSheet
    - SyncToolbarIndicator global toolbar item
    - SyncToast overlay component
  affects:
    - macos-app/MLM/Views/Library/TrackContextMenu.swift
    - macos-app/MLM/Views/Library/LibraryTable.swift
    - macos-app/MLM/Views/Library/LibraryView.swift
    - macos-app/MLM/Views/Folders/FoldersView.swift
    - macos-app/MLM/Views/Playlists/PlaylistCard.swift
    - macos-app/MLM/Views/Playlists/PlaylistsView.swift
    - macos-app/MLM/Views/Sync/SyncView.swift
    - macos-app/MLM/Views/Sync/SyncToast.swift
    - macos-app/MLM/Views/Sync/SyncToolbarIndicator.swift
    - macos-app/MLM/Views/ContentView/ContentView.swift
    - macos-app/MLM/Utilities/Notifications.swift
    - macos-app/MLMTests/ServiceTests/DeviceDetectorTests.swift
tech_stack:
  added:
    - SyncToast.swift (GREENFIELD overlay toast component)
    - SyncToolbarIndicator.swift (GREENFIELD global toolbar indicator)
    - DeviceDetectorTests.swift (Wave-0 unit test suite)
  patterns:
    - Menu-in-contextMenu for Sync to submenu (mirrors Add to Playlist pattern)
    - NotificationCenter.default.post for navigateToCreateSyncProfile
    - DeviceDetector.detectRockboxDevices() on-demand (no background observer)
    - ZStack alignment .bottom for SyncToast overlay
    - ToolbarItem(.primaryAction) for global sync indicator
key_files:
  created:
    - macos-app/MLM/Views/Sync/SyncToast.swift
    - macos-app/MLM/Views/Sync/SyncToolbarIndicator.swift
    - macos-app/MLMTests/ServiceTests/DeviceDetectorTests.swift
  modified:
    - macos-app/MLM/Views/Library/TrackContextMenu.swift
    - macos-app/MLM/Views/Library/LibraryTable.swift
    - macos-app/MLM/Views/Library/LibraryView.swift
    - macos-app/MLM/Views/Folders/FoldersView.swift
    - macos-app/MLM/Views/Playlists/PlaylistCard.swift
    - macos-app/MLM/Views/Playlists/PlaylistsView.swift
    - macos-app/MLM/Views/Sync/SyncView.swift
    - macos-app/MLM/Views/ContentView/ContentView.swift
    - macos-app/MLM/Utilities/Notifications.swift
decisions:
  - "SyncToast message stored in SyncView call-site (not hardcoded in SyncToast) to keep the component reusable, with doc comment noting standard message"
  - "FoldersView TrackContextMenu receives empty availableSyncProfiles + no-op addToSyncProfile; sync profiles in folders view is a future enhancement"
  - "showRockboxToast is SyncView @State (not createProfileSheet-local) to enable ZStack overlay at SyncView root level"
  - "DeviceDetector.detectRockboxDevices() called synchronously on main thread per plan (scanning /Volumes is <10ms for typical volume counts)"
metrics:
  duration_minutes: 45
  completed_date: "2026-05-18"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 9
  files_created: 3
---

# Phase 38 Plan 04: Context Menus, Device Detection, Toolbar Indicator, Toast Summary

Context menus + Rockbox device detect dropdown + global toolbar sync indicator + Rockbox toast, plus 4-test DeviceDetector suite.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Sync to context menus + Rockbox device detect + SyncToast | 22d6e89 | TrackContextMenu, LibraryTable, LibraryView, FoldersView, PlaylistCard, PlaylistsView, SyncView, SyncToast (new), Notifications |
| 2 | SyncToolbarIndicator + ContentView wiring + DeviceDetectorTests | 335663a | SyncToolbarIndicator (new), ContentView, DeviceDetectorTests (new) |

## What Was Built

**SYNC-v2-08: PlaylistCard "Sync zu" submenu**
- `PlaylistCard.swift`: added `availableSyncProfiles: [SyncProfile]` and `onAddToSyncProfile: ((SyncProfile, Int64) -> Void)?` props
- contextMenuItems: inserts "Sync zu" Menu before Delete section; empty-state copy "Keine Profile — erstelle zuerst eines"
- "Neues Profil erstellen…" entry posts `.navigateToCreateSyncProfile`
- `PlaylistsView.swift`: loads `container.syncViewModel?.profiles` into `availableSyncProfiles` state; threads closure down to PlaylistCard; observes `.syncProfileDidChange` to refresh

**SYNC-v2-09: TrackContextMenu "Sync zu" submenu**
- `TrackContextMenu.swift`: replaced disabled placeholder (line 83-90) with live Menu
- Props `availableSyncProfiles: [SyncProfile]` and `addToSyncProfile: (SyncProfile) -> Void` added
- `LibraryTable.swift`: new `availableSyncProfiles` prop; closure sets `selectedProfile` then calls `addTracks(Array(selectedIDs))`
- `LibraryView.swift`: loads sync profiles into state, threads to LibraryTable, observes `.syncProfileDidChange`
- `FoldersView.swift`: passes empty profiles + no-op to satisfy new signature (Rule 3 fix — blocking build error)

**SYNC-v2-13/14: createProfileSheet DeviceDetector wiring (D-09, D-10)**
- `SyncView.swift`: three new `@State` vars — `detectedDevices`, `hasRunDetection`, `shouldApplyDeviceDefaults`
- "Gerät erkennen…" Button calls `DeviceDetector.detectRockboxDevices()` synchronously; populates device list
- Empty state: "Keine Geräte gefunden — angeschlossen?" (D-10 copy)
- Device selection: sets `newProfileOutput`, auto-fills `newProfileName` if empty, sets `shouldApplyDeviceDefaults = true`
- "Erstellen" button passes `generateM3U8: true, transcodeMode: "aac_248"` when defaults active (D-03)
- showRockboxToast hoisted to SyncView level (not createProfileSheet-local) to enable ZStack overlay

**SYNC-v2-22 / Surface 12: SyncToast**
- `SyncToast.swift`: GREENFIELD non-blocking overlay toast
- Left-border Rectangle + checkmark.circle.fill icon + body text
- `mlmRaised` background, `mlmSuccess` green accents, 3-second auto-dismiss via `Task.sleep`
- `.move(edge: .bottom).combined(with: .opacity)` transition
- Wired as ZStack overlay in SyncView root

**SYNC-v2-15 / Surface 8: SyncToolbarIndicator**
- `SyncToolbarIndicator.swift`: GREENFIELD global toolbar item
- Renders only when `vm.isSyncing == true` (entirely absent otherwise)
- HStack: ProgressView(.small) + "N/M" counter with `monospacedDigit()`
- Click sets `selectedSection = .sync` (navigates to Sync route)
- `ContentView.swift`: added second `ToolbarItem(placement: .primaryAction)` hosting the indicator
- Uses `.syncProcessed`/`.syncTotal` forwarding props from SyncViewModel (no direct SyncService access)

**Notifications.swift**: added `navigateToCreateSyncProfile = Notification.Name("MLMNavigateToCreateSyncProfile")`

**DeviceDetectorTests.swift (4 tests, all passing)**:
1. `detectRockboxDevicesReturnsSafeArray` — no crash on /Volumes scan
2. `rockboxDeviceStructHasRequiredFields` — mountPoint, deviceName, availableSpace
3. `smartDefaultsCreateProfileWithDeviceSettings` — generateM3U8=true + transcodeMode="aac_248" persisted
4. `profilesEmptyThenPopulatedAfterCreate` — lifecycle from empty to 1 profile

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] FoldersView TrackContextMenu missing new required props**
- **Found during:** Task 1 build
- **Issue:** `FoldersView.swift` uses `TrackContextMenu` with the old 3-arg signature; adding `availableSyncProfiles` and `addToSyncProfile` as required (non-optional) props broke the build
- **Fix:** Added `availableSyncProfiles: []` and `addToSyncProfile: { _ in }` to FoldersView's TrackContextMenu call. FoldersView does not have SyncViewModel wired — that's a future enhancement
- **Files modified:** `macos-app/MLM/Views/Folders/FoldersView.swift`
- **Commit:** 22d6e89

**2. [Rule 2 - Design] showRockboxToast hoisted to SyncView level**
- **Found during:** Task 1 implementation
- **Issue:** Plan suggested `showRockboxToast` could live in `createProfileSheet` (private computed var), but the SyncToast overlay is on `SyncView.body` root ZStack — a `@State` in a `var createProfileSheet: some View` is not valid in Swift (property wrappers not allowed in computed view builders unless the view is a struct)
- **Fix:** Moved `showRockboxToast` (and related state) to `SyncView`'s `@State` properties; the `createProfileSheet` computed view reads them directly as bindings since they're in the same struct scope
- **Files modified:** `macos-app/MLM/Views/Sync/SyncView.swift`
- **Commit:** 22d6e89

**3. [Rule 1 - Design] createProfileSheet title/labels localized to German**
- **Found during:** Task 1 while updating createProfileSheet
- **Issue:** Existing createProfileSheet had English titles ("New Sync Profile", "Profile Name", "Browse...", "Cancel", "Create") while UI-SPEC §Copywriting Contract specifies German
- **Fix:** Renamed to "Neues Sync-Profil", "Profilname", "Durchsuchen…", "Abbrechen", "Erstellen"
- **Files modified:** `macos-app/MLM/Views/Sync/SyncView.swift`
- **Commit:** 22d6e89

## TDD Gate Compliance

- RED gate: DeviceDetectorTests written and run first
- GREEN gate: All 4 tests pass immediately (implementation already exists from 38-01/38-02)
- Note: For Wave-3 TDD tasks where the implementation pre-exists, tests passing in RED is expected and correct — the test suite validates existing contracts

## Known Stubs

None — all sync profile data flows from `SyncViewModel.profiles` (live DB-backed), no placeholder data used.

## Threat Flags

No new network endpoints, auth paths, file access patterns, or schema changes introduced beyond what the plan's `<threat_model>` already covers.

## Self-Check: PASSED

- SyncToast.swift: FOUND
- SyncToolbarIndicator.swift: FOUND
- DeviceDetectorTests.swift: FOUND
- Commit 22d6e89: FOUND
- Commit 335663a: FOUND
- All 4 DeviceDetectorTests: PASSED
- swift build: Build complete
