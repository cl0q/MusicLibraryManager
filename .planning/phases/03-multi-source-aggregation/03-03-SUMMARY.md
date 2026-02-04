---
phase: 03-multi-source-aggregation
plan: 03
subsystem: sources, auth
tags: [soundcloud, oauth2.1, pkce, incremental-sync, api-client]

# Dependency graph
requires:
  - phase: 03-multi-source-aggregation
    provides: schema extensions (sources, track_sources, last_sync_timestamps), OAuth token management (TokenManager, keychain storage)
provides:
  - SoundCloud API client with OAuth 2.1 PKCE flow
  - Incremental sync for liked tracks and playlists
  - Track provenance via track_sources table
  - sync_soundcloud_library convenience function
affects: [03-cross-source-dedup, 05-device-sync, 06-ui]

# Tech tracking
tech-stack:
  added: []
  patterns: [OAuth 2.1 mandatory PKCE, paginated collection sync, rate limit handling with Retry-After]

key-files:
  created:
    - src-tauri/src/sources/soundcloud.rs
  modified:
    - src-tauri/src/sources/mod.rs

key-decisions:
  - "OAuth 2.1 with mandatory PKCE S256 for SoundCloud (deadline passed Oct 1, 2024)"
  - "non-expiring scope for persistent API access"
  - "Likes ordered newest-first enables early termination in incremental sync"
  - "external_id format: soundcloud:{track_id} for provenance tracking"
  - "Env-var race condition fix: use explicit credentials in tests, not global env vars"

patterns-established:
  - "Paginated collection sync: while let Some(ref url) = next_url with next_href cursor"
  - "Rate limit handling: check 429 status, parse Retry-After header, return typed error"
  - "Track insertion with dedup: check external_id in track_sources before inserting"
  - "API client pattern: struct with token_manager, ensure_token() before each API call"

# Metrics
duration: 6min
completed: 2026-02-04
---

# Phase 3 Plan 3: SoundCloud Integration Summary

**SoundCloud API client with OAuth 2.1 mandatory PKCE, incremental sync for likes/playlists, rate limiting, and track provenance via track_sources table**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-02-03T22:40:37Z
- **Completed:** 2026-02-03T22:46:19Z (implementation); 2026-02-04T07:35:44Z (finalized)
- **Tasks:** 1 of 2 (Task 2 was human-action checkpoint, skipped)
- **Files modified:** 2

## Accomplishments
- Implemented SoundCloud API client with OAuth 2.1 Authorization Code flow using mandatory PKCE (S256)
- Incremental sync for liked tracks via `/me/favorites` with timestamp-based cutoff
- Playlist sync via `/me/playlists` with lazy track fetching
- Rate limiting with Retry-After header parsing and typed `RateLimited` error
- Track provenance via `INSERT INTO track_sources` with `soundcloud:{id}` external IDs
- Proactive token refresh via existing `TokenManager::ensure_valid_token` integration
- 9 unit tests passing, 1 integration test marked `#[ignore]`

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement SoundCloud API client with OAuth 2.1 and incremental sync** - `9e1d604` (feat)

**Task 2 (checkpoint:human-action):** OAuth authorization skipped -- will be tested when user configures `.env` credentials and Plan 05 wires up Tauri commands.

## Files Created/Modified
- `src-tauri/src/sources/soundcloud.rs` - SoundCloud API client: OAuth 2.1 PKCE, incremental sync, rate limiting, track insertion (870 lines)
- `src-tauri/src/sources/mod.rs` - Updated to export SoundCloud module (replaced non-existent Spotify placeholder)

## Decisions Made
- **OAuth 2.1 with mandatory PKCE S256:** SoundCloud requires PKCE since Oct 1, 2024; always generate `PkceCodeChallenge::new_random_sha256()`
- **non-expiring scope:** SoundCloud scope for persistent API access without re-authorization
- **Newest-first ordering enables early termination:** Since `/me/favorites` returns likes newest-first, incremental sync stops as soon as it hits a track older than `last_sync` timestamp
- **external_id format `soundcloud:{id}`:** Consistent provenance tracking in track_sources table, parallel to Spotify's `spotify:track:{id}` format
- **Explicit credentials in tests:** Avoided env-var race conditions in parallel test execution by using `with_credentials()` and direct `BasicClient` construction instead of `set_var`/`remove_var`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing Spotify module placeholder**
- **Found during:** Task 1 (sources/mod.rs update)
- **Issue:** mod.rs declared `pub mod spotify;` and `pub use spotify::{SpotifyClient, SpotifyError};` but no spotify.rs file existed (from an earlier incomplete plan execution)
- **Fix:** Replaced with SoundCloud declarations; Spotify module was added by the concurrent 03-02 plan execution
- **Files modified:** src-tauri/src/sources/mod.rs
- **Verification:** Build passes, no missing module errors
- **Committed in:** 9e1d604

**2. [Rule 1 - Bug] Moved value in while loop**
- **Found during:** Task 1 (compilation)
- **Issue:** `while let Some(url) = next_url` moved the String value, causing borrow-after-move in the loop
- **Fix:** Changed to `while let Some(ref url) = next_url` for both sync_likes and sync_playlists
- **Files modified:** src-tauri/src/sources/soundcloud.rs
- **Verification:** Compiles without errors
- **Committed in:** 9e1d604

**3. [Rule 3 - Blocking] Missing OptionalExtension import**
- **Found during:** Task 1 (compilation)
- **Issue:** `.optional()` method on rusqlite Result requires `use rusqlite::OptionalExtension`
- **Fix:** Added import
- **Files modified:** src-tauri/src/sources/soundcloud.rs
- **Verification:** Compiles without errors
- **Committed in:** 9e1d604

**4. [Rule 1 - Bug] Env-var race condition in parallel tests**
- **Found during:** Task 1 (test execution)
- **Issue:** `test_client_creation_missing_env` removed env vars while `test_authorization_url_with_pkce` tried to read them (parallel test execution)
- **Fix:** Refactored to use explicit credential construction instead of global env vars; tested URL components directly via `BasicClient`
- **Files modified:** src-tauri/src/sources/soundcloud.rs
- **Verification:** All 9 tests pass consistently
- **Committed in:** 9e1d604

---

**Total deviations:** 4 auto-fixed (2 blocking, 2 bugs)
**Impact on plan:** All fixes necessary for compilation and test reliability. No scope creep.

## Issues Encountered
None beyond the auto-fixed deviations above.

## User Setup Required
SoundCloud OAuth credentials needed before live sync:
- `SOUNDCLOUD_CLIENT_ID` and `SOUNDCLOUD_CLIENT_SECRET` in `.env` file (loaded by dotenvy at app startup)
- SoundCloud Developer Portal: register app with redirect URI `http://localhost:8080/callback`
- OAuth authorization flow will be wired up in Plan 05 (Tauri commands)

## Next Phase Readiness
- SoundCloud API client ready for integration with Tauri commands (Plan 05)
- Credentials loaded from `.env` via dotenvy (no shell env vars needed)
- Token management integrates with existing keychain infrastructure from 03-01
- Track insertion pattern creates provenance records in track_sources table
- Integration test available when credentials are configured

---
*Phase: 03-multi-source-aggregation*
*Completed: 2026-02-04*
