---
phase: 38-folder-device-sync-v2-0-macos-native
plan: "02"
subsystem: sync-service-layer
tags:
  - sync
  - service
  - viewmodel
  - transcode
  - tests
dependency_graph:
  requires:
    - 38-01
  provides:
    - SyncViewModel mutation methods
    - SyncService cancel/cleanup/M3U8/transcode extensions
    - TranscodeService/TranscodeCache bitrateKbps API
    - Wave-0 test suites (SyncViewModelTests, SyncServiceTests)
  affects:
    - 38-03 (UI plans depend on these VM mutation methods existing)
    - 38-04 (SyncService.cancelSync + progress tracking)
tech_stack:
  added:
    - TranscodeMode enum (keep_originals / aac_248 / aac_320)
    - v21_sync_profile_toggles DB migration (4 columns)
    - .syncProfileDidChange Notification.Name
  patterns:
    - Notification-post pattern (VM posts, views observe — VM never observes own notifications)
    - Transcode-mode branching switch (keepOriginals hardlink, aac248/aac320 TranscodeCache)
    - Cleanup-deletion safety guards (hasPrefix + resolvingSymlinksInPath)
key_files:
  created:
    - macos-app/MLMTests/ServiceTests/SyncServiceTests.swift
    - macos-app/MLMTests/ViewModelTests/SyncViewModelTests.swift
  modified:
    - macos-app/MLM/Services/Download/TranscodeService.swift
    - macos-app/MLM/Services/Sync/TranscodeCache.swift
    - macos-app/MLM/Services/Sync/SyncService.swift
    - macos-app/MLM/Database/SyncRepository.swift
    - macos-app/MLM/Database/DatabaseManager.swift
    - macos-app/MLM/Models/SyncProfile.swift
    - macos-app/MLM/ViewModels/SyncViewModel.swift
    - macos-app/MLM/Utilities/Notifications.swift
decisions:
  - "SyncRepository.database widened to any DatabaseWriter — needed for in-memory test setup (matches TrackRepository/PlaylistRepository pattern)"
  - "SyncRepository.databasePool renamed to databaseWriter — more accurate type name after widening"
  - "addTracksPostsNotification test uses real track insert (not id=999) — FK constraints active in inMemory tests cause GRDB to throw on non-existent trackId even with INSERT OR IGNORE"
  - "SyncProfile gets explicit convenience init with defaults — synthesized memberwise init not viable for test code with new optional fields"
  - "cancelSync flag checked after processed+=1 (not mid-transcode) — matches D-14 anti-pattern prohibition from RESEARCH.md"
metrics:
  duration: ~35 minutes
  completed: 2026-05-17
  tasks_completed: 3
  files_modified: 8
  files_created: 2
  tests_added: 11
  tests_passing: 153
---

# Phase 38 Plan 02: Service Layer + ViewModel Extensions Summary

**One-liner:** Service-layer gap-close: bitrateKbps in TranscodeService/Cache, 5 SyncViewModel mutation methods, SyncService cancel flag + cleanup-deletion + M3U8 gate + transcode-mode branching, 11 new tests (153 total passing).

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | TranscodeService bitrateKbps + TranscodeCache bitrate-suffixed filenames | 8289d75 | TranscodeService.swift, TranscodeCache.swift |
| 2+3 | SyncViewModel mutations + SyncService extensions + tests | 6ec5e5a | SyncViewModel.swift, SyncService.swift, SyncRepository.swift, SyncProfile.swift, DatabaseManager.swift, Notifications.swift, SyncViewModelTests.swift, SyncServiceTests.swift |

## What Was Built

### Task 1 — TranscodeService + TranscodeCache

- `TranscodeService.transcode(input:outputDir:bitrateKbps:248)` — `bitrateKbps` replaces hardcoded `Self.targetBitrate` in both the lossy-skip check and `runTranscode`'s `-b:a` ffmpeg flag
- `TranscodeCache.cachePath(trackId:bitrateKbps:)` — new overload returns `{trackId}_{bitrateKbps}.m4a` so 248k and 320k cached versions coexist on disk
- `TranscodeCache.ensureCached(track:bitrateKbps:248)` — uses bitrate-suffixed cache path; inlines existence check against bitrate-suffixed URL
- Legacy `cachePath(trackId:)` and `isCached(trackId:)` retained for backward compat

### Task 2 — SyncRepository + SyncViewModel + SyncViewModelTests

**SyncProfile model:**
- 4 new fields: `generateM3U8: Bool`, `transcodeMode: String`, `fat32SafePaths: Bool`, `cleanupRemovedFiles: Bool`
- `transcodeModeEnum: TranscodeMode` typed accessor (enum: `keepOriginals`, `aac248`, `aac320`)
- Convenience `init` with defaults for testability
- v21_sync_profile_toggles migration

**SyncRepository:**
- Widened `init(database:)` to `any DatabaseWriter` (matches TrackRepository/PlaylistRepository pattern)
- `updateSettings` extended with 4 new optional toggle parameters

**SyncViewModel:**
- `profilePlaylists: [Playlist]` + `profileTracks: [Track]` properties
- `loadProfileContent(profileId:)` populates both from syncRepository
- `loadPreview(for:)` now calls `loadProfileContent` after loading preview
- `createProfile` extended with 4 optional toggle params → writes via `updateSettings`
- 5 mutation methods: `addPlaylists`, `addTracks`, `removePlaylists`, `removeTracks`, `updateProfileSettings` — all post `.syncProfileDidChange`
- `cancelSync()` delegates to `syncService.cancelSync()`
- `retryFailedTrack()` delegates to `syncService.executeSyncSingleTrack()`
- VM does NOT observe `.syncProfileDidChange` (views are observers)

**SyncViewModelTests (6 tests, all passing):**
- addPlaylistsPostsNotification, addTracksPostsNotification, removePlaylistsPostsNotification, updateProfileSettingsPostsNotification, cancelSyncDoesNotCrash, createProfileWithTogglesPersistsDefaults

### Task 3 — SyncService Extensions + SyncServiceTests

**SyncService:**
- `cancellationRequested: Bool`, `processed: Int`, `total: Int` instance properties
- `cancelSync()` sets flag; `executeSync` resets to false at start
- Cancel flag checked after `processed += 1` in both for-loops (not mid-transcode — D-14)
- Cleanup-deletion branch: `trashItem` → `removeItem` fallback, gated on `profile.cleanupRemovedFiles`
- Security guards: `hasPrefix(profile.outputFolder)` + `resolvingSymlinksInPath()` + re-check canonical path (T-38-02, T-38-03)
- Transcode-mode branching: `keepOriginals` hardlinks/copies source directly; `aac248`/`aac320` go through TranscodeCache
- M3U8 gate: `if profile.generateM3U8 { try await generatePlaylists(...) }`
- `executeSyncSingleTrack(profileId:trackId:)` — single-track retry helper

**SyncServiceTests (5 tests, all passing):**
- cancellationFlagResetsOnNewRun, cancelMidRunDoesNotCrash, m3u8GateOffSkipsGenerationOnNonExistentPath, transcodeModeEnumValuesCorrect, processedAndTotalInitializeToZeroAfterEmptySync

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] SyncRepository.database widened to `any DatabaseWriter`**
- **Found during:** Task 2 test execution
- **Issue:** `SyncRepository.init(database: DatabasePool)` caused compile errors in tests that use `DatabaseManager.inMemory()` which returns `DatabaseQueue`. Other repositories (TrackRepository, PlaylistRepository) already use `any DatabaseWriter`.
- **Fix:** Widened `database` property type and init parameter to `any DatabaseWriter`; renamed `databasePool` accessor to `databaseWriter`
- **Files modified:** SyncRepository.swift, SyncService.swift (updated reference from `.databasePool` to `.databaseWriter`)
- **Commit:** 6ec5e5a

**2. [Rule 1 - Bug] `addTracksPostsNotification` test used non-existent track ID**
- **Found during:** Task 2 test run
- **Issue:** Plan's test used `trackId = 999` with comment "INSERT OR IGNORE means no crash", but with `foreignKeysEnabled = true` in in-memory DBs, GRDB throws FK constraint violation before the INSERT reaches the OR IGNORE clause. Result: error branch caught, notification never posted, test fails.
- **Fix:** Test now inserts a real track and uses its actual ID.
- **Files modified:** SyncViewModelTests.swift
- **Commit:** 6ec5e5a

**3. [Rule 1 - Bug] `AppLogger.warning()` does not exist**
- **Found during:** Task 3 build
- **Issue:** Plan's action code used `AppLogger.shared.warning(...)` but AppLogger only has `log(level:)`, `info()`, and `error()`.
- **Fix:** Replaced with `AppLogger.shared.log(..., level: .warning, source: "sync")`
- **Files modified:** SyncService.swift
- **Commit:** 6ec5e5a

**4. [Rule 2 - Missing Critical] SyncProfile had no convenience init**
- **Found during:** Task 2 test compile
- **Issue:** The test code `var profile = SyncProfile(name:outputFolder:playlistPathPrefix:)` required a convenience init (4 new fields made memberwise init incompatible with test's 3-param call).
- **Fix:** Added explicit convenience init to SyncProfile with defaults for all new fields.
- **Files modified:** SyncProfile.swift
- **Commit:** 6ec5e5a

**5. [Rule 2 - Missing] `.syncProfileDidChange` notification name not registered**
- **Found during:** Task 2 build
- **Issue:** SyncViewModel referenced `.syncProfileDidChange` but it was not in Notifications.swift.
- **Fix:** Added the notification name with full documentation comment.
- **Files modified:** Notifications.swift
- **Commit:** 6ec5e5a

## Threat Surface Scan

All mitigations from the plan's threat register were implemented:

| Threat ID | Mitigation Status | Implementation Location |
|-----------|------------------|------------------------|
| T-38-02 | Applied | SyncService.executeSync — `hasPrefix(profile.outputFolder)` guard before trashItem |
| T-38-03 | Applied | SyncService.executeSync — `url.resolvingSymlinksInPath()` + canonical path re-check |
| T-38-04 | Accept (Wave 2) | No service-layer changes needed |
| T-38-01 | Accept | DB FK constraint handles non-existent trackId at repository level |

No new threat surface introduced by this plan.

## Self-Check

### Files Created/Modified

- [x] `macos-app/MLMTests/ServiceTests/SyncServiceTests.swift` — FOUND
- [x] `macos-app/MLMTests/ViewModelTests/SyncViewModelTests.swift` — FOUND
- [x] `macos-app/MLM/Services/Download/TranscodeService.swift` — modified (bitrateKbps)
- [x] `macos-app/MLM/Services/Sync/TranscodeCache.swift` — modified (bitrateKbps + bitrate-suffixed paths)
- [x] `macos-app/MLM/Services/Sync/SyncService.swift` — modified (cancel + cleanup + M3U8 gate + transcode-mode)
- [x] `macos-app/MLM/Database/SyncRepository.swift` — modified (any DatabaseWriter + extended updateSettings)
- [x] `macos-app/MLM/Database/DatabaseManager.swift` — modified (v21 migration)
- [x] `macos-app/MLM/Models/SyncProfile.swift` — modified (4 new fields + TranscodeMode enum + convenience init)
- [x] `macos-app/MLM/ViewModels/SyncViewModel.swift` — modified (5 mutation methods + profilePlaylists/Tracks + cancelSync)
- [x] `macos-app/MLM/Utilities/Notifications.swift` — modified (.syncProfileDidChange added)

### Commits

- [x] `8289d75` — feat(38-02): add bitrateKbps param to TranscodeService + bitrate-suffixed cache filenames
- [x] `6ec5e5a` — feat(38-02): SyncViewModel mutations + SyncService cancel/cleanup/M3U8/transcode + tests

### Test Results

- SyncViewModelTests: 6/6 passed
- SyncServiceTests: 5/5 passed
- Full suite: 153/153 passed

## Self-Check: PASSED
