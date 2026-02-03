---
phase: 02-download-infrastructure
plan: 01
subsystem: download
tags: [reqwest, backoff, http, streaming, error-handling, dab-api]

# Dependency graph
requires:
  - phase: 01-library-foundation
    provides: Database schema and models for storing tracks
provides:
  - DAB Music API client with search and FLAC download
  - HTTP client wrapper with exponential backoff retry
  - Error classification pattern (permanent vs transient)
  - Streaming download with atomic writes
affects: [02-02-youtube-fallback, 02-03-unified-downloader]

# Tech tracking
tech-stack:
  added: [reqwest 0.12, backoff 0.4, futures-util 0.3]
  patterns:
    - Exponential backoff for HTTP retries
    - 404 as permanent error (no retry)
    - Streaming large files to disk
    - Atomic write pattern (temp file → rename)

key-files:
  created:
    - src-tauri/src/download/client.rs
    - src-tauri/src/download/dab.rs
    - src-tauri/src/download/mod.rs
  modified:
    - src-tauri/Cargo.toml
    - src-tauri/src/lib.rs

key-decisions:
  - "404 classified as permanent error (no retry, enables fallback)"
  - "Streaming downloads to avoid OOM on large FLAC files"
  - "Atomic writes via temp file + rename pattern"
  - "backoff crate for retry logic (battle-tested, eliminates timing bugs)"

patterns-established:
  - "Pattern 1: HttpClient.get_with_retry() classifies errors as permanent (404) vs transient (429, 5xx, network)"
  - "Pattern 2: DownloadResult enum signals NotFound for fallback trigger"
  - "Pattern 3: Stream to .tmp file, rename only on success, delete on interruption"

# Metrics
duration: 3min
completed: 2026-02-03
---

# Phase 02 Plan 01: DAB API Client Summary

**DAB Music API client with exponential backoff, streaming FLAC downloads, and 404-triggered fallback signaling**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-03T19:56:51Z
- **Completed:** 2026-02-03T20:00:34Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments
- HTTP client wrapper with automatic retry on transient errors (429, 5xx, network)
- DAB API client for searching tracks and downloading FLAC streams
- 404 returns NotFound (no retry) to enable YouTube fallback in next plan
- Streaming download pattern prevents OOM on large files
- Atomic write pattern ensures no partial files on interruption

## Task Commits

Each task was committed atomically:

1. **Task 1: Add HTTP client dependencies** - `bf67f47` (chore)
2. **Task 2: Create HTTP client wrapper with backoff retry** - `1502c24` (feat)
3. **Task 3: Implement DAB API client** - `2effdf0` (feat)

## Files Created/Modified
- `src-tauri/Cargo.toml` - Added reqwest, backoff, futures-util dependencies
- `src-tauri/src/lib.rs` - Added download module export
- `src-tauri/src/download/mod.rs` - Module exports for client and dab
- `src-tauri/src/download/client.rs` - HttpClient with exponential backoff and error classification
- `src-tauri/src/download/dab.rs` - DabClient with search_track() and download_stream()

## Decisions Made

**1. 404 as permanent error (no retry)**
- Rationale: Track not found should trigger YouTube fallback immediately, not waste time retrying
- Implementation: HttpClient classifies 404 as BackoffError::permanent
- Impact: Enables fast fallback path in plan 02-02

**2. Streaming downloads to disk**
- Rationale: FLAC files can be 30-50MB, loading into memory causes OOM
- Implementation: futures_util::StreamExt for chunked writes
- Impact: Scalable to large files, low memory footprint

**3. Atomic write pattern (temp file → rename)**
- Rationale: Interrupted downloads should not leave partial files
- Implementation: Stream to .tmp extension, rename only on success
- Impact: Idempotent downloads, clean failure handling

**4. backoff crate over manual retry loops**
- Rationale: Exponential backoff has subtle timing math (jitter, max intervals)
- Implementation: backoff::future::retry with ExponentialBackoff
- Impact: Battle-tested retry logic eliminates timing bugs

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Removed premature yt-dlp dependency**
- **Found during:** Task 2 (running tests)
- **Issue:** yt-dlp dependency (from plan 02-02) caused rusqlite version conflict - two versions of libsqlite3-sys cannot link to same native library
- **Fix:** Removed yt-dlp from Cargo.toml (will be added properly in plan 02-02 when needed)
- **Files modified:** src-tauri/Cargo.toml
- **Verification:** cargo test passes without dependency conflict
- **Committed in:** bf67f47 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (blocking issue)
**Impact on plan:** Necessary to unblock execution. yt-dlp will be added in plan 02-02 where it belongs.

## Issues Encountered
None - dependency conflict was auto-fixed per deviation Rule 3.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for plan 02-02 (YouTube fallback):**
- DabClient.download_stream() returns DownloadResult::NotFound on 404
- HttpClient retry pattern established and tested
- Streaming download pattern works for large files

**Blockers/concerns:**
- DAB API documentation gap noted in STATE.md - actual API endpoints may differ from plan assumptions
- Need integration tests with real DAB API once endpoint details confirmed
- YouTube client (plan 02-02) should follow same DownloadResult pattern for consistency

---
*Phase: 02-download-infrastructure*
*Completed: 2026-02-03*
