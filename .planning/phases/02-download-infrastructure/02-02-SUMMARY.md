---
phase: 02-download-infrastructure
plan: 02
subsystem: download-clients
tags: [youtube, yt-dlp, audio-extraction, fallback-source]

dependency_graph:
  requires:
    - 02-01-http-client
  provides:
    - youtube-audio-extraction
    - fallback-download-source
  affects:
    - 02-03-transcoding (will receive downloaded audio files)
    - 02-04-retry-queue (handles YouTube fallback errors)

tech_stack:
  added:
    - yt-dlp CLI (external dependency, not Rust crate)
  patterns:
    - CLI process invocation with tokio::process::Command
    - Async audio download with format selection
    - Result enum for Success/NotFound outcomes

key_files:
  created:
    - src-tauri/src/download/youtube.rs: "YouTube audio client with search and URL download"
  modified:
    - src-tauri/src/download/mod.rs: "Export youtube module"

decisions:
  - id: cli-invocation-over-crate
    what: Use tokio::process::Command to invoke yt-dlp CLI instead of yt-dlp Rust crate
    why: yt-dlp crate 1.4.x requires rusqlite 0.37, conflicts with our rusqlite 0.34
    impact: Equivalent functionality, requires yt-dlp CLI installed on system
    alternatives: Upgrade rusqlite to 0.37 (would require changes to existing library code)
  - id: ignore-integration-tests
    what: Mark integration tests with #[ignore] by default
    why: CI environments may not have yt-dlp CLI installed
    impact: Tests must be run manually with --ignored flag when yt-dlp available
    alternatives: Auto-install yt-dlp in CI (adds complexity)

metrics:
  duration: 4m
  lines_added: 305
  tests_added: 4
  completed: 2026-02-03
---

# Phase 02 Plan 02: YouTube Audio Extraction Summary

**One-liner:** YouTube fallback downloads via yt-dlp with bestaudio format selection and search-by-query

## What Was Built

Implemented YouTube audio extraction as a fallback source for tracks unavailable on DAB Music. The YoutubeClient provides two download methods:

1. **search_and_download**: Search YouTube and download first result
2. **download_by_url**: Download from specific YouTube URL

Both methods use yt-dlp CLI with `-f bestaudio` for best available audio quality, `-x` for audio extraction, and include video ID in filename for uniqueness.

## Architecture

**Core exports:**
- `YoutubeClient`: Main client struct
- `YoutubeDownloadResult`: Enum with Success(PathBuf) and NotFound variants

**Key behaviors:**
- Runtime check for yt-dlp CLI availability on initialization
- Helpful error message with installation instructions if CLI missing
- Search uses `ytsearch1:query` format (first result only)
- Output template includes title and video ID for unique filenames
- Parses yt-dlp output to extract downloaded file path
- Returns NotFound for "No video results" or "Unable to extract" errors

**Integration pattern:**
```rust
let client = YoutubeClient::new()?;
let result = client.search_and_download("Artist - Track", output_dir).await?;
match result {
    YoutubeDownloadResult::Success(path) => { /* process audio file */ }
    YoutubeDownloadResult::NotFound => { /* mark as unavailable */ }
}
```

## Testing Strategy

**Unit tests (always run):**
- `test_client_creation_without_yt_dlp`: Verifies error handling for missing CLI

**Integration tests (marked #[ignore]):**
- `test_verify_yt_dlp_available`: Checks yt-dlp CLI is installed
- `test_search_known_track`: Downloads "Daft Punk - Around the World"
- `test_download_by_url`: Downloads from known YouTube URL

Run integration tests with: `cargo test -- --ignored` (requires yt-dlp installed)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] yt-dlp crate dependency conflict**
- **Found during:** Task 1 (Add dependencies)
- **Issue:** yt-dlp crate 1.4.x requires rusqlite 0.37, conflicts with our rusqlite 0.34
- **Fix:** Implemented using tokio::process::Command for direct CLI invocation instead
- **Files modified:** src-tauri/src/download/youtube.rs (implementation approach)
- **Commit:** 42d4995

**2. [Rule 1 - Bug] Missing Debug trait on YoutubeClient**
- **Found during:** Task 2 (Testing)
- **Issue:** Test code couldn't unwrap Result<YoutubeClient> without Debug trait
- **Fix:** Added #[derive(Debug)] to YoutubeClient struct
- **Files modified:** src-tauri/src/download/youtube.rs
- **Commit:** 42d4995

**3. [Rule 2 - Missing Critical] Dead code warning on yt_dlp_path field**
- **Found during:** Task 2 (Compilation)
- **Issue:** Field reserved for future custom path support but unused currently
- **Fix:** Added #[allow(dead_code)] attribute to preserve field for future use
- **Files modified:** src-tauri/src/download/youtube.rs
- **Commit:** 42d4995

## Key Insights

**1. CLI invocation vs Rust crate tradeoff**
Direct CLI invocation requires yt-dlp installed on system but avoids dependency conflicts. This is acceptable because:
- yt-dlp is commonly installed for video/audio tasks
- Error message provides clear installation instructions
- Avoids forcing rusqlite upgrade across entire codebase

**2. Integration test isolation**
Marking tests with #[ignore] allows unit tests to run in CI without external dependencies while preserving integration tests for local verification.

**3. bestaudio format selection**
No quality threshold enforcement - accepts best available YouTube audio. This aligns with user decision to treat YouTube as "best effort" fallback for obscure tracks.

## Verification Checklist

- [x] `cargo test --package music-library-manager --lib download::youtube` passes (1/4 tests, 3 ignored)
- [x] YoutubeClient exports search_and_download and download_by_url methods
- [x] bestaudio format selection implemented in both methods
- [x] Error message for missing yt-dlp includes installation instructions
- [x] Downloaded files include video ID in filename
- [x] Integration tests documented for manual verification

## Next Phase Readiness

**Blockers:** None

**Prerequisites for 02-03 (Transcoding):**
- YouTube downloads produce audio files at output_dir location
- File paths returned in Success variant can be passed to transcoding
- NotFound variant signals track unavailable (no file to transcode)

**Known limitations:**
- Requires yt-dlp CLI installed on system
- No retry logic (will be handled by orchestrator in 02-04)
- No progress tracking during download (future enhancement)

## Related Files

**Generated artifacts:**
- .planning/phases/02-download-infrastructure/02-02-SUMMARY.md (this file)

**Dependencies:**
- 02-01-http-client: HTTP client infrastructure (backoff patterns for future DAB integration)

**Affects:**
- 02-03-transcoding: Will receive YouTube audio files for quality normalization
- 02-04-retry-queue: Will handle YouTube fallback failures and retries
