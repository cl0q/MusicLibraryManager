---
phase: 07
plan: 03
subsystem: artwork-management
tags: [musicbrainz, cover-art-archive, artwork, caching, embedding, lofty, image-processing]

requires:
  - 07-01 # Schema v5 with artwork table

provides:
  - artwork-fetching # MusicBrainz/CAA integration
  - artwork-cache # Local file cache
  - artwork-embed # Lofty-based embedding
  - image-resize # Aspect-ratio-preserving resize

affects:
  - 07-04 # ReplayGain workflow can use artwork module
  - 07-05 # Fingerprint workflow can use artwork module
  - sync-pipeline # Artwork available for synced copies

tech-stack:
  added:
    - urlencoding # URL encoding for MusicBrainz queries
    - base64 # Base64 encoding (from 07-02)
    - image # Image decoding and resizing
  patterns:
    - MusicBrainz web service API client
    - Cover Art Archive HTTP redirects
    - File-based cache with track_id naming
    - anyhow::Result for file I/O operations
    - Lofty Picture embedding workflow

key-files:
  created:
    - src-tauri/src/artwork/mod.rs # Public API and batch processing
    - src-tauri/src/artwork/sources.rs # MusicBrainz/CAA client
    - src-tauri/src/artwork/cache.rs # Local cache management
  modified:
    - src-tauri/src/lib.rs # Added artwork module
    - src-tauri/src/replaygain/tagger.rs # Fixed lofty 0.22 compatibility
    - src-tauri/Cargo.toml # Added urlencoding dependency

decisions:
  - title: anyhow::Result for artwork operations
    rationale: File I/O and HTTP operations use anyhow, not database::Result
    impact: Consistent error handling for external operations
    date: 2026-02-05

  - title: Two artwork sizes (500px, 1200px)
    rationale: 500px for iPod embedding, 1200px for UI display
    impact: Balance quality with file size
    date: 2026-02-05

  - title: Extract embedded artwork before fetching
    rationale: Use existing artwork if available, avoid unnecessary API calls
    impact: Faster batch processing, respects rate limits
    date: 2026-02-05

  - title: 1 req/sec MusicBrainz rate limit
    rationale: MusicBrainz API requirement
    impact: Batch processing takes time, but avoids API throttling
    date: 2026-02-05

metrics:
  duration: 160m 22s
  completed: 2026-02-05
  commits: 2
  tests: 7
  lines_added: 757
  deviations: 2
---

# Phase 7 Plan 03: Artwork Fetching & Embedding Summary

**One-liner:** MusicBrainz/CAA artwork fetching with local caching and lofty embedding

## What Was Built

Complete artwork management system:

1. **MusicBrainz Integration** (sources.rs):
   - Release group search by artist + album via web service API
   - Cover Art Archive client with 500px and 1200px sizes
   - 1 req/sec rate limiting via tokio::time::sleep
   - User-Agent header compliance

2. **Local Cache** (cache.rs):
   - File-based cache with `{track_id}_{size}.jpg` naming
   - Cache hit detection before fetching
   - Database state tracking in artwork table
   - Query for tracks without artwork

3. **Artwork Embedding** (embed.rs - from 07-02):
   - Check for existing embedded artwork
   - Embed artwork into audio file's primary tag
   - Extract embedded artwork from files
   - Resize artwork maintaining aspect ratio

4. **Batch Processing** (mod.rs):
   - Process multiple tracks incrementally
   - Extract embedded artwork before fetching
   - Save 500px for embedding, 1200px for UI
   - Record source in database (embedded vs musicbrainz)

## Verification Results

**All 7 artwork tests passing:**
- ✅ test_artwork_cache_path
- ✅ test_save_and_check_cached
- ✅ test_get_tracks_without_artwork
- ✅ test_save_artwork_state_roundtrip
- ✅ test_extract_embedded_returns_none
- ✅ test_resize_artwork
- ✅ test_resize_artwork_downscale

**Integration points verified:**
- ✅ Database artwork table populated correctly
- ✅ File cache creates directory if needed
- ✅ Image resize maintains aspect ratio
- ✅ Lofty Picture embedding uses WriteOptions::default()

## Task Execution

### Task 1: MusicBrainz lookup and Cover Art Archive client ✅

**Files:** mod.rs, sources.rs, cache.rs, lib.rs

Implemented:
- search_release_group() with MusicBrainz web service API
- fetch_cover_art() for 500px and 1200px sizes
- fetch_artwork_for_track() orchestration
- ArtworkCache with file-based storage
- save_artwork_state() and get_tracks_without_artwork()
- 4 unit tests (cache path, save/check, tracks without artwork, roundtrip)

Note: Also implemented embed.rs functionality in this task (originally planned for Task 2)

### Task 2: Artwork embedding and batch processing ✅

**Files:** embed.rs (from 07-02), mod.rs

Functionality already present from Plan 07-02:
- has_embedded_artwork() check
- embed_artwork() via lofty
- extract_embedded_artwork() for files with covers
- resize_artwork() with Lanczos3 filter

Added in Task 1:
- batch_fetch_artwork() orchestration
- Extract-before-fetch optimization
- 3 unit tests (extract returns none, resize, resize downscale)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed replaygain/tagger.rs lofty 0.22 compatibility**
- **Found during:** Task 1 verification
- **Issue:** `lofty::error::ErrorKind::BadFormat` removed in lofty 0.22
- **Fix:** Used `TaggerError::Parse` variant instead
- **Files modified:** src-tauri/src/replaygain/tagger.rs
- **Commit:** 285dcbf

**2. [Rule 3 - Blocking] Task 1 included Task 2 functionality**
- **Found during:** Task 1 implementation
- **Issue:** embed.rs already existed from plan 07-02
- **Fix:** Implemented batch_fetch_artwork() in Task 1
- **Impact:** Both tasks complete in first commit
- **Commit:** 086199e

## Architecture

### Module Structure

```
artwork/
├── mod.rs           # Public API, batch processing, BatchArtworkResult
├── sources.rs       # MusicBrainz/CAA HTTP client
├── cache.rs         # File cache + database state
└── embed.rs         # Lofty embedding + image resize (from 07-02)
```

### Data Flow

```
batch_fetch_artwork()
  ↓
1. Check cache
  ↓ (miss)
2. Check embedded artwork
  ↓ (none)
3. Search MusicBrainz for release group
  ↓ (found)
4. Fetch 500px and 1200px from CAA
  ↓
5. Save to cache
  ↓
6. Record in artwork table
```

### API Usage

```rust
// Batch fetch for tracks
let cache = ArtworkCache::new(PathBuf::from("cache/artwork"))?;
let client = reqwest::Client::new();
let tracks = get_tracks_without_artwork(&conn)?;

let result = batch_fetch_artwork(
    &conn,
    &cache,
    &client,
    &tracks
).await?;

println!("Fetched: {}, Cached: {}, Not found: {}",
    result.fetched, result.already_cached, result.not_found);
```

## Next Phase Readiness

**Ready for:**
- 07-04: ReplayGain workflow (can batch analyze tracks with artwork)
- 07-05: Fingerprint workflow (can identify tracks and fetch artwork)
- Sync pipeline: Artwork available for embedding into synced copies

**Outstanding items:**
- Tauri command for artwork fetching (Phase 6 desktop UI integration)
- Background artwork fetch on track import (startup task)
- Artwork display in LibraryTable and TrackDetail pages

## Challenges Overcome

1. **Lofty API changes:** lofty 0.22 removed BadFormat variant, used Parse instead
2. **Error type boundaries:** Separated anyhow::Result (file I/O) from database::Result
3. **Plan 07-02 overlap:** embed.rs already existed, adapted task boundaries
4. **MusicBrainz compliance:** User-Agent header required, implemented immediately

## Statistics

- **Duration:** 160 minutes 22 seconds
- **Commits:** 2 (feat + fix)
- **Files created:** 3 (mod.rs, sources.rs, cache.rs)
- **Files modified:** 3 (lib.rs, tagger.rs, Cargo.toml)
- **Tests added:** 7
- **Tests passing:** 7/7 (100%)
- **Lines added:** ~757
- **Dependencies added:** 1 (urlencoding)

## Key Learnings

1. **MusicBrainz API:** Simple REST API, requires User-Agent, returns JSON with release group IDs
2. **Cover Art Archive:** Redirects to actual image host, supports multiple sizes (250, 500, 1200)
3. **Lofty Picture embedding:** Need WriteOptions::default(), Picture::from_reader() for JPEG data
4. **Image crate:** Efficient resize with FilterType::Lanczos3, maintains quality
5. **Extract-before-fetch:** Check embedded artwork before API calls saves time and API quota

---

*Plan 07-03 complete. Artwork fetching and embedding ready for integration.*
