---
phase: 05-device-sync
plan: 01
subsystem: database, sync
tags: [rusqlite, sqlite, schema-migration, sync-profiles, filter-rules, tauri-ipc]

# Dependency graph
requires:
  - phase: 04-playlist-management
    provides: Playlists table, playlist_tracks table for content resolution
  - phase: 03-multi-source-aggregation
    provides: Sources and track_sources tables for source-based filtering
provides:
  - Schema version 4 with five sync tables (sync_profiles, sync_profile_tracks, sync_profile_playlists, sync_profile_rules, sync_state)
  - SyncProfile model with get_all_track_ids() union resolution (manual + playlists + rules)
  - FilterRule support for genre, artist, bitrate, date_added, source, and tag filtering
  - SyncProfileDto and FilterRuleDto for Tauri IPC communication
  - Foundation for transcode cache, device operations, and M3U8 generation
affects: [05-02-transcode-cache, 05-03-m3u8-generation, 05-04-sync-operations]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Three-source union pattern for content resolution (manual + playlists + rules)"
    - "Query-based filter rules with field/operator/value structure"
    - "DTO pattern with computed statistics (track_count, manual_track_count, etc.)"

key-files:
  created:
    - src-tauri/src/database/schema.rs (Phase 5 schema constants and migration)
    - src-tauri/src/sync/mod.rs (Sync module entry point)
    - src-tauri/src/sync/profile.rs (SyncProfile model and CRUD operations)
    - src-tauri/src/models/sync.rs (Tauri IPC DTOs)
  modified:
    - src-tauri/src/lib.rs (Export sync module)
    - src-tauri/src/models/mod.rs (Export sync DTOs)

key-decisions:
  - "Schema version 4 for Phase 5 sync tables"
  - "Three-source union for profile content: manual tracks, playlists, and query rules"
  - "Profile content resolved at query time for dynamic smart-playlist-like behavior"
  - "DTO computed statistics include track_count as union size for accurate totals"

patterns-established:
  - "Sync profiles support three content sources for maximum flexibility"
  - "Filter rules use string field/operator/value for extensible query building"
  - "DTOs compute statistics on creation rather than storing in database"

# Metrics
duration: 53min
completed: 2026-02-04
---

# Phase 5 Plan 1: Sync Profile Model Summary

**Schema version 4 with five sync tables, SyncProfile model with union-based content resolution across manual tracks/playlists/rules, and Tauri IPC DTOs with computed statistics**

## Performance

- **Duration:** 53 min
- **Started:** 2026-02-04T20:36:37Z
- **Completed:** 2026-02-04T21:29:44Z
- **Tasks:** 3
- **Files modified:** 6 (4 created, 2 modified)

## Accomplishments
- Database schema version 4 with five sync tables for multi-device profile management
- SyncProfile model resolving track IDs as union of manual tracks, playlists, and query rules
- Filter rule system supporting genre, artist, bitrate, date_added, source, and tag filtering
- Tauri IPC DTOs with computed statistics for UI display (track_count, breakdown by source type)
- 9 unit tests covering profile CRUD, content resolution, and DTO conversion

## Task Commits

Each task was committed atomically:

1. **Task 1: Database schema for sync profiles and state tracking** - `3804b13` (feat)
   - Updated CURRENT_SCHEMA_VERSION from 3 to 4
   - Added PHASE5_SCHEMA_SQL with sync_profiles, sync_profile_tracks, sync_profile_playlists, sync_profile_rules, sync_state tables
   - Foreign keys with ON DELETE CASCADE for referential integrity
   - Indexes on frequently queried profile_id columns
   - Integrated migrate_to_v4() into initialize_schema()

2. **Task 2: Sync profile models and content resolution** - `f272736` (feat)
   - Created sync module with profile.rs
   - SyncProfile struct with name, output_folder, timestamps
   - FilterRule struct with field/operator/value for query-based selection
   - get_all_track_ids() method returning union of manual tracks, playlist tracks, and rule-matched tracks
   - apply_filter_rule() supporting 6 filter fields with various operators
   - CRUD functions: create_sync_profile, get_sync_profile, list_sync_profiles, delete_sync_profile
   - Content management: add_manual_track, remove_manual_track, add_playlist, remove_playlist, add_rule, remove_rule, get_profile_rules
   - 7 unit tests covering profile creation, deletion, manual tracks, playlists, rules, and union resolution

3. **Task 3: Sync DTOs for Tauri IPC** - `0182742` (feat)
   - SyncProfileDto with computed statistics (track_count, manual_track_count, playlist_count, rule_count)
   - from_profile() method computing all counts via database queries
   - FilterRuleDto with bidirectional conversion to/from FilterRule
   - 2 unit tests for DTO creation and conversion
   - Exported sync module from models/mod.rs

## Files Created/Modified
- `src-tauri/src/database/schema.rs` - Added PHASE5_SCHEMA_SQL constant with five sync tables, migrate_to_v4() function, version 4 migration logic
- `src-tauri/src/sync/mod.rs` - Module entry point with profile submodule (cache, device, playlist_gen, progress stubbed for future plans)
- `src-tauri/src/sync/profile.rs` - SyncProfile and FilterRule models, get_all_track_ids() union resolution, CRUD functions, 7 unit tests
- `src-tauri/src/models/sync.rs` - SyncProfileDto and FilterRuleDto for Tauri IPC, conversion functions, 2 unit tests
- `src-tauri/src/lib.rs` - Export sync module
- `src-tauri/src/models/mod.rs` - Export SyncProfileDto and FilterRuleDto

## Decisions Made
- **Schema version 4 for Phase 5** - Bumped from version 3 (playlists) to version 4 (sync profiles), following established migration pattern
- **Three-source union for profile content** - Manual tracks, playlists, and query rules combined via HashSet for deduplicated track IDs
- **Query-time content resolution** - get_all_track_ids() computes union on each call rather than caching, enabling dynamic smart-playlist-like behavior as library changes
- **Field/operator/value filter rule structure** - Extensible query pattern supporting eq/ne/gt/lt/contains/in operators across 6 filter fields
- **DTO computed statistics** - SyncProfileDto.from_profile() runs database queries to compute track counts rather than storing redundant data
- **rusqlite::Result for collect()** - Used rusqlite's Result type instead of custom Result alias to properly handle query_map iterator conversions

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed Result type mismatch in collect() calls**
- **Found during:** Task 2 (Sync profile models compilation)
- **Issue:** collect() calls used `Result<Vec<T>, _>` but custom Result type alias only takes one generic argument
- **Fix:** Changed all collect() calls to use `rusqlite::Result<Vec<T>>` for proper type inference from query_map iterators
- **Files modified:** src-tauri/src/sync/profile.rs (6 collect() calls)
- **Verification:** cargo build succeeded, all 7 sync profile tests passed
- **Committed in:** f272736 (Task 2 commit)

**2. [Rule 1 - Bug] Fixed test assertion order for alphabetically sorted profiles**
- **Found during:** Task 2 (Sync profile tests)
- **Issue:** test_list_sync_profiles expected "iPod" before "iPhone" but list_sync_profiles() sorts by name (iPhone < iPod)
- **Fix:** Corrected test assertions to match actual alphabetical ordering
- **Files modified:** src-tauri/src/sync/profile.rs (test_list_sync_profiles)
- **Verification:** Test now passes with correct alphabetical order
- **Committed in:** f272736 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both auto-fixes were necessary for compilation and correct test behavior. No scope changes.

## Issues Encountered
- Rust's Result type alias pattern requires careful handling - `Result<T>` expands to `Result<T, DatabaseError>`, so collect() cannot infer two generic arguments. Solution: explicitly use rusqlite::Result for query_map collections.
- Alphabetical sorting behavior can cause test failures if test data isn't ordered correctly. Always sort test expectations to match query ORDER BY clauses.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Sync profile foundation complete with schema, models, and DTOs
- Ready for Plan 05-02 (Transcode Cache) to implement shared AAC cache with hardlink/copy logic
- Ready for Plan 05-03 (M3U8 Generation) to generate playlists from profile content
- Ready for Plan 05-04 (Sync Operations) to orchestrate full device sync workflow
- All 9 unit tests passing, schema migration verified at version 4

---
*Phase: 05-device-sync*
*Completed: 2026-02-04*
