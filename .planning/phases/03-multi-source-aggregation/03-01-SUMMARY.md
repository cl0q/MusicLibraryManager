---
phase: 03-multi-source-aggregation
plan: 01
subsystem: auth, database
tags: [oauth2, keyring, sqlite, migration, keychain]

# Dependency graph
requires:
  - phase: 01-library-foundation
    provides: tracks table schema
provides:
  - sources table for multi-source tracking
  - track_sources many-to-many relationship table
  - last_sync_timestamps for incremental sync
  - variant_of column for remix/edit relationships
  - Schema versioning with PRAGMA user_version
  - OAuth token storage in system keychain
  - Proactive token refresh with 5-minute buffer
affects: [03-02, 03-03, 05-device-sync]

# Tech tracking
tech-stack:
  added: [oauth2 5.0, keyring 3.6, unicode-normalization 0.1]
  patterns: [versioned schema migrations, keychain token storage, proactive refresh]

key-files:
  created:
    - src-tauri/src/auth/mod.rs
    - src-tauri/src/auth/token_storage.rs
    - src-tauri/src/auth/token_refresh.rs
  modified:
    - src-tauri/src/database/schema.rs
    - src-tauri/Cargo.toml
    - src-tauri/src/lib.rs

key-decisions:
  - "Schema version 2 for Phase 3 tables (PRAGMA user_version)"
  - "Keychain service name: com.musiclibrarymanager"
  - "Proactive token refresh 5 minutes before expiration"
  - "TokenStorageError for explicit error handling vs generic errors"

patterns-established:
  - "Versioned migrations: PRAGMA user_version tracking, version-gated migrations in initialize_schema"
  - "Keychain key format: {source}_{user_id}_refresh"
  - "Token lifecycle: store refresh token in keychain, refresh access token proactively"

# Metrics
duration: 6min
completed: 2026-02-03
---

# Phase 3 Plan 1: Multi-Source Foundation Summary

**Extended database schema with sources/track_sources/last_sync_timestamps tables and OAuth token management via system keychain**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-02-03T22:30:00Z
- **Completed:** 2026-02-03T22:36:00Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Extended database schema with 3 new tables (sources, track_sources, last_sync_timestamps) and variant_of column
- Implemented versioned schema migrations using PRAGMA user_version (v1 -> v2)
- Created auth module with keychain-backed OAuth token storage
- Implemented TokenManager with proactive token refresh before expiration
- Added 18 new tests (10 schema, 8 auth) - all passing

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend database schema for multi-source tracking** - `77f94a5` (feat)
2. **Task 2: Implement OAuth token lifecycle management with keyring** - `493b7a2` (feat)

## Files Created/Modified
- `src-tauri/src/database/schema.rs` - Extended with Phase 3 tables and versioned migrations
- `src-tauri/Cargo.toml` - Added oauth2, keyring, unicode-normalization dependencies
- `src-tauri/src/lib.rs` - Added auth module declaration
- `src-tauri/src/auth/mod.rs` - Public exports for token storage/refresh
- `src-tauri/src/auth/token_storage.rs` - Keychain integration for refresh tokens
- `src-tauri/src/auth/token_refresh.rs` - OAuth token lifecycle management

## Decisions Made
- **Schema version 2:** Used PRAGMA user_version to track schema evolution, enabling safe migrations from v1 to v2
- **Keychain service name:** Used `com.musiclibrarymanager` as service identifier for keyring entries
- **Token refresh buffer:** 5 minutes proactive refresh before expiration (matches industry best practice)
- **ConfiguredClient type alias:** Created explicit type alias for oauth2::Client with correct generics for exchange_refresh_token support

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] oauth2 5.0 API changes**
- **Found during:** Task 2 (OAuth implementation)
- **Issue:** Plan used oauth2 4.x patterns; oauth2 5.0 uses type-state builder pattern requiring explicit endpoint types
- **Fix:** Added ConfiguredClient type alias with correct generic parameters, imported TokenResponse trait
- **Files modified:** src-tauri/src/auth/token_refresh.rs
- **Verification:** Build passes, tests pass
- **Committed in:** 493b7a2 (Task 2 commit)

**2. [Rule 3 - Blocking] thiserror struct variant syntax**
- **Found during:** Task 2 (TokenStorageError definition)
- **Issue:** Named struct fields in error variants caused compile error with thiserror
- **Fix:** Changed to tuple variant TokenNotFound(String, String)
- **Files modified:** src-tauri/src/auth/token_storage.rs
- **Verification:** Error display test passes
- **Committed in:** 493b7a2 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 blocking)
**Impact on plan:** Both fixes necessary to compile against current crate versions. No scope creep.

## Issues Encountered
None - both deviations were straightforward API compatibility fixes.

## User Setup Required
None - no external service configuration required. OAuth credentials will be needed when Spotify/SoundCloud integration is configured in subsequent plans.

## Next Phase Readiness
- Database schema ready for Spotify and SoundCloud track provenance tracking
- OAuth token infrastructure ready for both platforms
- Next plan (03-02) can implement Spotify API client
- Keychain tests marked #[ignore] for CI compatibility (require actual keychain access)

---
*Phase: 03-multi-source-aggregation*
*Completed: 2026-02-03*
