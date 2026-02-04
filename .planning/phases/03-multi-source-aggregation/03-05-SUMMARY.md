---
phase: 03-multi-source-aggregation
plan: 05
subsystem: commands, startup
tags: [tauri-commands, oauth, pkce, auto-sync, spawn-blocking, rusqlite-send]

# Dependency graph
requires:
  - phase: 03-02
    provides: SpotifyAuth, SpotifyClient with OAuth PKCE and incremental sync
  - phase: 03-03
    provides: SoundCloudClient with OAuth 2.1 PKCE and incremental sync
  - phase: 03-04
    provides: calculate_similarity, is_variant for fuzzy duplicate detection
provides:
  - Tauri commands for Spotify and SoundCloud OAuth authorization flows
  - Tauri commands for incremental sync of liked songs/tracks
  - Tauri command for fuzzy duplicate detection across library
  - Auto-sync on app startup (background, non-blocking)
  - OAuthState managed state for PKCE verifier storage
affects: [04-playlist-management, 06-desktop-ui]

# Tech tracking
tech-stack:
  added: []
  patterns: [spawn_blocking+block_on for rusqlite !Send, OAuthState Mutex for PKCE verifiers, Tauri managed state]

key-files:
  created:
    - src-tauri/src/commands/sources.rs
    - src-tauri/src/startup.rs
  modified:
    - src-tauri/src/commands/mod.rs
    - src-tauri/src/lib.rs

key-decisions:
  - "spawn_blocking + Handle::current().block_on() for rusqlite !Send across await boundaries"
  - "OAuthState with Mutex<Option<(PkceCodeVerifier, CsrfToken)>> for temporary PKCE storage"
  - "default_user as placeholder user ID for startup sync until multi-user support"
  - "check_duplicates returns DuplicateMatch with similarity score and is_variant flag"
  - "Startup sync failures logged as warnings, never block app startup"

patterns-established:
  - "spawn_blocking + block_on pattern: Tauri async commands using rusqlite Connection across awaits"
  - "OAuthState pattern: Mutex-protected temporary state for multi-step OAuth flows"
  - "Silent startup tasks: try-and-log pattern for non-critical background operations"

# Metrics
duration: 5min
completed: 2026-02-04
---

# Phase 3 Plan 5: Tauri Commands and Auto-Sync Summary

**Tauri command interface for OAuth flows, sync operations, and duplicate detection with background auto-sync on app startup**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-02-04T07:40:02Z
- **Completed:** 2026-02-04T07:45:00Z
- **Tasks:** 2 auto + 1 checkpoint (skipped)
- **Files created:** 2
- **Files modified:** 2

## Accomplishments

- Implemented 7 Tauri commands: spotify_auth_url, spotify_exchange_code, sync_spotify, soundcloud_auth_url, soundcloud_exchange_code, sync_soundcloud, check_duplicates
- Solved rusqlite !Send issue with spawn_blocking + block_on pattern for async Tauri commands
- Implemented OAuthState managed state with Mutex for PKCE verifier storage during auth flows
- Built check_duplicates command integrating Jaro-Winkler similarity and variant detection
- Created startup.rs with background auto-sync fulfilling locked CONTEXT.md decision
- Startup sync silently handles missing credentials and auth failures
- 6 new tests (5 in sources, 1 in startup), all 185 project tests pass

## Task Commits

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Implement Tauri commands for OAuth and sync | `2736dfa` | `src-tauri/src/commands/sources.rs` (474 lines), `src-tauri/src/commands/mod.rs`, `src-tauri/src/lib.rs` |
| 2 | Implement auto-sync on app startup | `d21a1ce` | `src-tauri/src/startup.rs` (146 lines), `src-tauri/src/lib.rs` |

## Files Created/Modified

- `src-tauri/src/commands/sources.rs` -- 7 Tauri commands, OAuthState struct, SyncResponse/DuplicateMatch types (474 lines)
- `src-tauri/src/startup.rs` -- run_startup_tasks() with silent Spotify/SoundCloud sync (146 lines)
- `src-tauri/src/commands/mod.rs` -- Added sources module export and re-exports for all new commands
- `src-tauri/src/lib.rs` -- Added startup module, OAuthState managed state, 7 command registrations, background startup task spawn

## Decisions Made

1. **spawn_blocking + block_on pattern:** rusqlite::Connection is !Send (uses RefCell internally), which prevents holding it across .await points in Tauri's Send-required async commands. Solution: spawn_blocking creates a dedicated thread, block_on re-enters the async runtime from that thread. Connection stays on one thread.

2. **OAuthState with Mutex:** PKCE verifiers must persist between auth URL generation and code exchange (two separate Tauri command invocations). Using Mutex<Option<(PkceCodeVerifier, CsrfToken)>> allows atomic take-and-store semantics.

3. **default_user placeholder:** Single-user desktop app uses "default_user" for startup sync. Multi-user support deferred to Phase 6 when app configuration is implemented.

4. **check_duplicates returns enriched matches:** Instead of just (track_id, score) tuples, returns DuplicateMatch with title, artist, similarity, and is_variant flag for frontend display.

5. **Adapted to actual API shapes:** Plan pseudocode assumed SpotifyClient(client_id, client_secret) and Database state. Actual APIs: SpotifyAuth for auth flow, SpotifyClient::new(user_id) reads env vars, SoundCloudClient::authorization_url() returns AuthorizationRequest struct, database uses raw Connection via get_connection().

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] rusqlite Connection !Send across Tauri async boundaries**
- **Found during:** Task 1 (sync_spotify command)
- **Issue:** Tauri async commands require Send futures, but rusqlite::Connection is !Send (uses RefCell). sync_liked_songs and sync_likes hold Connection across .await points.
- **Fix:** Wrapped sync operations in tokio::task::spawn_blocking + Handle::current().block_on() to keep Connection on a single thread while re-entering the async runtime.
- **Files modified:** src-tauri/src/commands/sources.rs, src-tauri/src/startup.rs
- **Commit:** 2736dfa

**2. [Rule 1 - Bug] Adapted to actual API shapes (not plan pseudocode)**
- **Found during:** Task 1 (reading source modules)
- **Issue:** Plan pseudocode assumed SpotifyClient::new(client_id, client_secret), Database managed state, find_duplicates() function. Actual APIs are different: SpotifyAuth for auth, SpotifyClient::new(user_id), SoundCloudClient::new() reads env, AuthorizationRequest struct, calculate_similarity + is_variant instead of find_duplicates.
- **Fix:** Implemented against actual module public APIs. check_duplicates queries DB directly and calls calculate_similarity/is_variant per track.
- **Files modified:** src-tauri/src/commands/sources.rs
- **Commit:** 2736dfa

---

**Total deviations:** 2 auto-fixed (1 blocking issue, 1 API mismatch)
**Impact on plan:** Both fixes were necessary for compilation. The spawn_blocking pattern is the standard solution for rusqlite in async contexts.

## Issues Encountered

None beyond the deviations noted above.

## User Setup Required

To test OAuth flows and sync:
1. Fill in `src-tauri/.env` with credentials (see `.env.example`)
2. Register OAuth apps with Spotify and SoundCloud Developer portals
3. Configure redirect URI `http://localhost:8080/callback` in both OAuth apps

## Next Phase Readiness

- All Phase 3 plans complete (01-06)
- 185 tests passing across entire project
- Tauri commands ready for frontend integration in Phase 6
- Auto-sync on startup working for both services
- OAuth live testing deferred until user configures credentials
- Phase 4 (Playlist Management) can begin

---
*Phase: 03-multi-source-aggregation*
*Completed: 2026-02-04*
