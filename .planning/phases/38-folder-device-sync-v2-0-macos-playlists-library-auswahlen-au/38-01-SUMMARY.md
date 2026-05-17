---
phase: 38-folder-device-sync-v2-0-macos-native
plan: "01"
subsystem: database-schema
tags: [migration, grdb, swift, sync-profiles, schema]
dependency_graph:
  requires: []
  provides:
    - v_sync_toggles migration in DatabaseManager.swift
    - TranscodeMode enum in SyncProfile.swift
    - SyncProfile.generateM3U8 / transcodeMode / fat32SafePaths / cleanupRemovedFiles fields
    - Notifications.syncProfileDidChange constant
    - MigrationTests Wave-0 (8 tests)
  affects:
    - macos-app/MLM/Database/DatabaseManager.swift
    - macos-app/MLM/Models/SyncProfile.swift
    - macos-app/MLM/Utilities/Notifications.swift
    - macos-app/MLMTests/MigrationTests.swift
tech_stack:
  added: []
  patterns:
    - GRDB per-column idempotence guard (same as v14_lufs_columns and v20_playlist_cover_custom)
    - Swift Testing @Suite / @Test (same as Phase 36/37 test suites)
key_files:
  created:
    - macos-app/MLMTests/MigrationTests.swift
  modified:
    - macos-app/MLM/Database/DatabaseManager.swift
    - macos-app/MLM/Models/SyncProfile.swift
    - macos-app/MLM/Utilities/Notifications.swift
decisions:
  - "TranscodeMode enum placed at file level (not nested inside SyncProfile) for direct import in tests and service code"
  - "Per-column idempotence guard used (not single multi-column guard) so partial migrations can resume cleanly"
  - "SyncProfile fields use Swift Bool for INTEGER columns — GRDB maps 0/1 natively via Codable"
metrics:
  duration: "~17 minutes"
  completed: "2026-05-17T21:03:43Z"
  tasks_completed: 2
  files_modified: 4
---

# Phase 38 Plan 01: Schema Foundation + Notifications Summary

**One-liner:** SQLite migration v_sync_toggles adds 4 toggle columns to sync_profiles with per-column guards; SyncProfile struct extended with Bool/String fields + TranscodeMode enum; Notifications.syncProfileDidChange declared; 8 MigrationTests pass.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 (RED) | MigrationTests failing stub | 7c7e1a4 | MLMTests/MigrationTests.swift (created) |
| 1 (GREEN) | v_sync_toggles migration + SyncProfile + TranscodeMode | cf461c3 | DatabaseManager.swift, SyncProfile.swift |
| 2 | Notifications.syncProfileDidChange | 2b8aa2b | Notifications.swift |

## What Was Built

### DatabaseManager.swift — Migration v_sync_toggles

Registered after `v_search_text_column` (the previous last migration). Each of the 4 columns gets its own `if try !db.columns(in:).contains` guard for idempotent partial-migration recovery:

- `generate_m3u8` — INTEGER NOT NULL DEFAULT 0 (emit M3U8 playlists for Rockbox)
- `transcode_mode` — TEXT NOT NULL DEFAULT 'keep_originals' (transcoding strategy)
- `fat32_safe_paths` — INTEGER NOT NULL DEFAULT 1 (PathSanitizer for FAT32 devices)
- `cleanup_removed_files` — INTEGER NOT NULL DEFAULT 1 (unlink files on removal)

### SyncProfile.swift

`TranscodeMode` enum added at **file level** (before the struct) with three cases:
- `keepOriginals = "keep_originals"`
- `aac248 = "aac_248"`
- `aac320 = "aac_320"`

Four new stored properties added to `SyncProfile` struct with Swift defaults matching DB defaults:
- `var generateM3U8: Bool = false`
- `var transcodeMode: String = "keep_originals"`
- `var fat32SafePaths: Bool = true`
- `var cleanupRemovedFiles: Bool = true`

`var transcodeModeEnum: TranscodeMode` computed property returns `TranscodeMode(rawValue: transcodeMode) ?? .keepOriginals`.

`CodingKeys` extended with all four snake_case mappings for GRDB Codable decoding.

### Notifications.swift

`syncProfileDidChange = Notification.Name("MLMSyncProfileDidChange")` added in `MARK: - Sync` section with full docstring (observers, userInfo["profileId"] key).

### MigrationTests.swift (new file)

8 `@Test` functions using Swift Testing framework + `DatabaseManager.inMemory()`:
1. `syncProfilesHasGenerateM3U8Column` — column existence
2. `syncProfilesHasTranscodeModeColumn` — column existence
3. `syncProfilesHasFat32SafePathsColumn` — column existence
4. `syncProfilesHasCleanupRemovedFilesColumn` — column existence
5. `defaultsAreCorrectOnInsert` — DB defaults materialized on raw INSERT
6. `migrationIsIdempotent` — two inMemory() calls, no duplicate columns
7. `syncProfileDecodesNewColumnsCorrectly` — full round-trip GRDB decoding
8. `transcodeModeEnumFallback` — unknown rawValue → nil; default SyncProfile → .keepOriginals

All 8 tests pass: `✔ Test run with 8 tests in 1 suite passed after 0.036 seconds.`

## Verification Results

```
# Build: passed
Build complete!

# v_sync_toggles migration registered: 2 occurrences (comment + migration name)
# generate_m3u8 column: 3 occurrences
# transcode_mode column: 3 occurrences
# fat32_safe_paths column: 3 occurrences
# cleanup_removed_files column: 3 occurrences

# SyncProfile new fields (generateM3U8|transcodeMode|fat32SafePaths|cleanupRemovedFiles): 11 occurrences
# TranscodeMode: 3 occurrences
# MLMSyncProfileDidChange: 1 occurrence

# MigrationTests: 8/8 passed, 0 failed
```

## Deviations from Plan

### Plan deviation: SPM project, not Xcode project

**Found during:** Task 2 implementation

**Issue:** The plan instructs adding MigrationTests.swift to the "MLMTests Xcode target" and updating `.pbxproj`. However, the project uses Swift Package Manager (`Package.swift`), not a `.xcodeproj` file. There is no `.pbxproj` to update.

**Fix:** SPM automatically includes all `.swift` files in the `MLMTests/` directory (defined as `path: "MLMTests"` in Package.swift). The file was placed in `macos-app/MLMTests/MigrationTests.swift` and picked up automatically — no `Package.swift` changes required.

**Impact:** None — tests ran and passed correctly. No files modified beyond those specified.

## TDD Gate Compliance

- RED gate: `test(38-01)` commit `7c7e1a4` — failing tests committed before implementation
- GREEN gate: `feat(38-01)` commit `cf461c3` — implementation makes all 8 tests pass
- REFACTOR: No cleanup needed — code was clean on first pass

## Known Stubs

None — no placeholder values or hardcoded empty data. All DB defaults are schema constants matching D-01 spec.

## Threat Surface Scan

No new network endpoints, auth paths, or trust boundaries introduced. Migration DDL uses hardcoded source constants only (no user input). In-memory test DB is isolated per test run. No threat flags beyond those already documented in the plan's threat model.

## Self-Check

- [x] `macos-app/MLM/Database/DatabaseManager.swift` — modified, contains `v_sync_toggles`
- [x] `macos-app/MLM/Models/SyncProfile.swift` — modified, contains `TranscodeMode` + 4 new fields
- [x] `macos-app/MLM/Utilities/Notifications.swift` — modified, contains `MLMSyncProfileDidChange`
- [x] `macos-app/MLMTests/MigrationTests.swift` — created, 8 tests pass
- [x] Commit `7c7e1a4` — RED test commit
- [x] Commit `cf461c3` — GREEN implementation commit
- [x] Commit `2b8aa2b` — Notifications commit

## Self-Check: PASSED
