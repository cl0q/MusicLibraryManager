---
phase: 09-library-remote-separation
plan: 01
subsystem: database
tags: [rusqlite, sqlite, schema-migration, query-filtering, tauri-commands]

# Dependency graph
requires:
  - phase: 08-library-configuration
    provides: Phase 8 schema v6 with app_config table
provides:
  - Schema v7 migration with download_status column and partial index
  - Query functions for library-only and remote-only track filtering
  - Tauri commands for frontend Library/Remote view separation
affects: [09-02, 09-03, frontend-library-remote-ui]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Partial indexes for NULL-based filtering optimization"
    - "Versioned schema migrations with column existence checks"

key-files:
  created: []
  modified:
    - src-tauri/src/database/schema.rs
    - src-tauri/src/search/query.rs
    - src-tauri/src/commands/search.rs
    - src-tauri/src/commands/mod.rs
    - src-tauri/src/lib.rs

key-decisions:
  - "download_status column uses NULL for never-downloaded, ISO 8601 timestamp for audit (not used for filtering)"
  - "Remote view uses organized_path IS NULL instead of download_status for filtering"
  - "INNER JOIN with track_sources ensures remote tracks have streaming source associations"
  - "Partial index idx_organized_path_null optimizes WHERE organized_path IS NULL queries"

patterns-established:
  - "Query layer (search/query.rs) provides DbResult<T>, command layer (commands/*.rs) wraps with Result<T, String> for Tauri"
  - "Three-tier architecture: query functions → Tauri commands → frontend invoke()"

# Metrics
duration: 5min
completed: 2026-02-07
---

# Phase 9 Plan 01: Backend Query Filtering Summary

**Schema v7 migration with download_status column, library/remote query functions, and Tauri commands for filtered views**

## Performance

- **Duration:** 5 minutes
- **Started:** 2026-02-07T15:20:39Z
- **Completed:** 2026-02-07T15:25:38Z
- **Tasks:** 3/3
- **Files modified:** 5

## Accomplishments
- Database schema v7 with download_status column and partial index for remote query optimization
- Query functions for library-only (organized_path IS NOT NULL) and remote-only (organized_path IS NULL with track_sources) filtering
- Tauri commands registered and callable from frontend for Library/Remote view separation

## Task Commits

Each task was committed atomically:

1. **Task 1: Add download_status column migration (schema v7)** - `ea3fd1a` (feat)
2. **Task 2: Create library-only and remote-only query functions** - `dda27d9` (feat)
3. **Task 3: Create Tauri commands for library/remote filtering** - `2489a83` (feat)

## Files Created/Modified
- `src-tauri/src/database/schema.rs` - Added schema v7 migration with download_status column, PHASE9_SCHEMA_SQL constant, migrate_to_v7 function, and test
- `src-tauri/src/search/query.rs` - Added get_library_tracks_only, get_remote_tracks_only, count_remote_tracks query functions
- `src-tauri/src/commands/search.rs` - Added three new Tauri commands wrapping query functions
- `src-tauri/src/commands/mod.rs` - Exported new commands for registration
- `src-tauri/src/lib.rs` - Registered commands in invoke_handler for frontend access

## Decisions Made
- **download_status column semantics:** NULL for local imports and not-yet-downloaded remote tracks, ISO 8601 timestamp when streaming track is downloaded (used for audit/tracking in Phase 11 download flow, NOT for filtering in Phase 9)
- **Filtering strategy:** Use organized_path IS NULL (not download_status) for remote view queries, ensuring cleaner separation logic
- **Remote track validation:** INNER JOIN with track_sources ensures remote tracks have streaming source associations, avoiding orphaned tracks without sources (pitfall #1 from research)
- **Index optimization:** Created partial index idx_organized_path_null on tracks(organized_path) WHERE organized_path IS NULL for remote view query performance

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Plan 02 (Frontend Library/Remote views):**
- Backend commands available: get_library_tracks_only, get_remote_tracks_only, get_remote_track_count
- Database schema supports filtering: organized_path column, partial index created
- Query performance optimized: idx_organized_path_null speeds up remote view queries

**No blockers or concerns.**

---
*Phase: 09-library-remote-separation*
*Completed: 2026-02-07*

## Self-Check: PASSED
