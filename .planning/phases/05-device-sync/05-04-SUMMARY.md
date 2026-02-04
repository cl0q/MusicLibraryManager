---
phase: 05-device-sync
plan: 04
subsystem: sync
tags: [rust, incremental-sync, state-tracking, orchestration, preview, m3u8]

requires:
  - "05-01: Sync profile model with get_all_track_ids()"
  - "05-02: Transcode cache with link_to_profile()"
  - "05-03: Rockbox device detection and M3U8 generation"

provides:
  - "Sync preview computation (dry-run mode)"
  - "Incremental sync execution with state persistence"
  - "Complete sync orchestration (files + playlists)"
  - "Space validation with 50MB buffer"
  - "Resumption support via sync_state table"

affects:
  - "05-05: Tauri commands will use preview_sync() and sync_profile_to_folder()"
  - "Phase 6: UI will display SyncPreview before committing"

tech-stack:
  added: []
  patterns:
    - "Dry-run preview before execution"
    - "SHA256 checksums for change detection"
    - "Incremental sync via sync_state comparison"
    - "High-level orchestration functions (preview_sync, sync_profile_to_folder)"

key-files:
  created:
    - src-tauri/src/sync/progress.rs: "Sync preview, execution, and state tracking (551 lines)"
  modified:
    - src-tauri/src/sync/mod.rs: "Added orchestration functions and progress module export"

decisions:
  - decision: "50MB space buffer required"
    rationale: "Safety margin for filesystem metadata and unexpected overhead"
    impact: "Prevents out-of-space failures during sync"
    alternatives: ["10MB buffer (too small for safety)", "100MB buffer (unnecessarily restrictive)"]

  - decision: "SHA256 checksums for change detection"
    rationale: "Industry standard cryptographic hash, detects file changes reliably"
    impact: "Enables incremental sync - only changed files re-synced"
    alternatives: ["File size + mtime (unreliable across filesystems)", "MD5 (deprecated)"]

  - decision: "Sync preview returns full file list"
    rationale: "User needs to see exactly what will be synced before committing"
    impact: "Enables informed decision-making, shows space impact"
    alternatives: ["Only return counts (insufficient detail)", "Stream results (complex for preview)"]

  - decision: "Clean stale sync_state entries automatically"
    rationale: "Tracks removed from profile should not remain in sync_state"
    impact: "Keeps sync_state accurate, enables correct incremental sync"
    alternatives: ["Manual cleanup (error-prone)", "Keep stale entries (bloat, incorrect previews)"]

metrics:
  tests: 9
  files_created: 1
  files_modified: 1
  lines_added: 788
  duration: "14m 25s"
  completed: 2026-02-04
---

# Phase 5 Plan 04: Incremental Sync Orchestration Summary

**One-liner:** Incremental sync engine with SHA256-based change detection, dry-run preview, space validation, and complete orchestration of files and M3U8 playlists.

## What Was Built

### Core Functionality

**Sync Preview (Dry-Run Mode):**
- `compute_sync_preview()` compares profile content against sync_state table
- Identifies files to add (new or changed via checksum comparison)
- Identifies files to remove (no longer in profile)
- Calculates total size impact (new size - removed size)
- Validates device has sufficient space (needed + 50MB buffer)
- Returns `SyncPreview` with full file lists for user review

**Incremental Sync Execution:**
- `execute_sync()` performs actual file operations based on preview
- Blocks if insufficient space (prevents out-of-space failures)
- Removes stale files no longer in profile
- Links/copies files from cache to profile folder via `TranscodeCache`
- Updates sync_state for each successful operation (checksum, size, timestamp)
- Returns `SyncResult` with success/failure counts

**Sync State Tracking:**
- `update_sync_state()` persists SHA256 checksums after sync
- `get_synced_tracks()` queries current sync_state for incremental detection
- `needs_sync()` compares checksums to detect changed files
- `clean_removed_tracks()` removes stale sync_state entries

**Orchestration Functions:**
- `preview_sync()` high-level function: load profile, create cache, compute preview
- `sync_profile_to_folder()` complete workflow: preview → execute files → generate M3U8 playlists
- `sync_playlists()` generates M3U8 for all playlists in profile (internal)

### Implementation Details

**Data Structures:**
```rust
pub struct SyncPreview {
    pub files_to_add: Vec<FilePreview>,
    pub files_to_remove: Vec<String>,
    pub total_new_size: u64,
    pub total_remove_size: u64,
    pub device_available_space: Option<u64>,
    pub has_sufficient_space: bool,
}

pub struct SyncResult {
    pub synced_count: usize,
    pub failed_count: usize,
    pub failed_tracks: Vec<(i64, String)>,
}
```

**Incremental Sync Logic:**
1. Get profile track IDs via `profile.get_all_track_ids()` (union of manual + playlists + rules)
2. Get currently synced tracks from sync_state table
3. For each track in profile:
   - If not in sync_state → needs sync
   - If in sync_state but checksum changed → needs sync
   - If in sync_state with matching checksum → skip (already synced)
4. For tracks in sync_state but not in profile → mark for removal
5. Execute file operations and update sync_state

**Space Validation:**
- Calculate net space needed: `total_new_size - total_remove_size`
- Require 50MB buffer over needed space
- Block sync if insufficient space

**Resumption Support:**
- Interrupted sync can be re-run without re-syncing completed files
- sync_state tracks which files completed successfully
- Preview computation automatically skips already-synced files

## Testing

**9 Unit Tests (all passing):**

1. `test_compute_sync_preview_new_profile` - Empty sync_state = all tracks need sync
2. `test_compute_sync_preview_incremental` - Only new/changed tracks need sync
3. `test_space_validation_blocks_insufficient` - Preview detects insufficient space
4. `test_execute_sync_blocks_insufficient_space` - Execute fails with insufficient space
5. `test_execute_sync_links_files` - Files linked from cache to profile
6. `test_execute_sync_updates_state` - sync_state updated with checksums
7. `test_clean_removed_tracks` - Stale sync_state entries removed
8. `test_preview_sync_returns_accurate_counts` - High-level preview function works
9. `test_sync_profile_to_folder_complete_workflow` - Full workflow syncs files and M3U8

**Test Coverage:**
- Preview computation with empty and populated sync_state
- Space validation (sufficient and insufficient)
- File operations (linking, directory creation)
- State persistence (checksums, timestamps)
- Stale entry cleanup
- Complete orchestration (files + playlists)

## Verification

**Success Criteria Verification:**

✓ **compute_sync_preview accurately calculates files to add, remove, and space requirements**
- Test `test_compute_sync_preview_new_profile` verifies all tracks identified for new profile
- Test `test_compute_sync_preview_incremental` verifies only changed tracks identified
- Preview includes total_new_size and total_remove_size

✓ **execute_sync links files from cache to profile folder and updates sync_state**
- Test `test_execute_sync_links_files` verifies files created in profile folder
- Test `test_execute_sync_updates_state` verifies sync_state updated with SHA256 checksums

✓ **Sync is incremental—only new or changed files are processed**
- Test `test_compute_sync_preview_incremental` proves already-synced files skipped
- Checksum comparison via `needs_sync()` detects file changes

✓ **Sync blocks if insufficient device space (50MB buffer enforced)**
- Test `test_space_validation_blocks_insufficient` proves preview detects insufficient space
- Test `test_execute_sync_blocks_insufficient_space` proves execution blocks

✓ **M3U8 playlists generated for all playlists in profile after file sync**
- Test `test_sync_profile_to_folder_complete_workflow` verifies M3U8 files created
- `sync_playlists()` queries sync_profile_playlists and calls `write_profile_playlist()`

✓ **Resumption works—interrupted sync can be re-run without re-syncing completed files**
- sync_state tracks completed files
- `needs_sync()` checks sync_state before adding to files_to_add
- Resuming sync skips already-synced tracks

**All 54 sync module tests passing.**

## Integration with Existing System

**Uses from Phase 05-01 (Sync Profile Model):**
- `SyncProfile::get_all_track_ids()` - Union of manual tracks + playlists + rules
- `get_sync_profile()` - Load profile by ID

**Uses from Phase 05-02 (Transcode Cache):**
- `TranscodeCache::get_cache_path()` - Deterministic cache file paths
- `TranscodeCache::link_to_profile()` - Platform-aware file linking (hardlink on Unix, copy on Windows)
- `TranscodeCache::compute_checksum()` - SHA256 for change detection
- `TranscodeCache::build_profile_path()` - Generate profile-specific paths

**Uses from Phase 05-03 (M3U8 Generation):**
- `write_profile_playlist()` - Generate M3U8 files with relative paths
- `get_playlist_tracks()` - Query tracks in playlist

**Provides to Phase 05-05 (Tauri Commands):**
- `preview_sync()` - Tauri command will expose this for UI
- `sync_profile_to_folder()` - Tauri command will execute sync

## Deviations from Plan

None - plan executed exactly as written.

## Next Phase Readiness

**Ready for Plan 05-05 (Tauri Commands):**
- ✓ Preview and sync functions implemented
- ✓ Data structures serializable (derive Serialize)
- ✓ Error handling via anyhow::Result
- ✓ All functionality tested

**Known Limitations:**
- No actual iPod for integration testing (unit tests use mock filesystems)
- M3U8 UTF-8 encoding with Rockbox untested on device
- FAT32 long filename edge cases not tested with actual device

**Technical Debt:**
None.

**Future Enhancements:**
- Progress callbacks for UI (currently fire-and-forget)
- Parallel file linking (currently sequential)
- Transactional sync (rollback on failure)
- Bandwidth limiting for network-mounted profiles

## Performance Notes

**Preview Computation:**
- O(n) where n = number of tracks in profile
- Requires checksum computation for changed file detection
- Database queries use indexes (profile_id, track_id)

**Sync Execution:**
- Sequential file operations (reliable, simple error handling)
- Hardlinks on Unix (instant, no disk usage)
- Copies on Windows (slower, uses disk space)

**Resumption:**
- Checksum comparison skips unchanged files
- sync_state queries use indexed columns
- No need to recompute profile track IDs

**Measured Performance:**
- 9 unit tests complete in 0.02s
- All 54 sync module tests complete in 0.12s

## Code Quality

**Rust Best Practices:**
- ✓ Comprehensive error handling via anyhow::Result
- ✓ No unsafe code
- ✓ Proper resource cleanup (temp dirs in tests)
- ✓ Database queries use prepared statements
- ✓ Type-safe enums for categories

**Documentation:**
- ✓ Module-level documentation
- ✓ Function documentation with arguments and returns
- ✓ Inline comments for complex logic

**Test Quality:**
- ✓ Tests use in-memory database (fast, isolated)
- ✓ Temp directories for filesystem tests
- ✓ Comprehensive coverage of success and error paths
- ✓ Integration tests verify complete workflows

---

**Phase 5 Plan 04 Status:** ✅ COMPLETE

All tasks executed, all tests passing, ready for Plan 05-05 (Tauri Commands).
