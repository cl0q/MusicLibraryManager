---
phase: 07-enhancements
plan: 01
subsystem: database
tags: [rusty-chromaprint, ebur128, musicbrainz_rs, image, symphonia, schema-migration, pcm-decoder]

# Dependency graph
requires:
  - phase: 06-desktop-ui
    provides: Complete Tauri desktop application with React UI
  - phase: 05-device-sync
    provides: Schema v4 with sync profiles and state tracking
provides:
  - Schema v5 with fingerprints, artwork, replaygain, review_queue tables
  - Shared audio PCM decode pipeline (decode_to_pcm function)
  - Phase 7 crate dependencies: rusty-chromaprint, ebur128, musicbrainz_rs, image
affects: [fingerprinting, artwork-fetching, replaygain-analysis]

# Tech tracking
tech-stack:
  added: [rusty-chromaprint v0.3, ebur128 v0.1, musicbrainz_rs v0.12, image v0.25]
  patterns: [Symphonia-based PCM decoding with SampleBuffer::copy_interleaved_ref, Schema versioning v4→v5 migration]

key-files:
  created:
    - src-tauri/src/audio/mod.rs
    - src-tauri/src/audio/decoder.rs
  modified:
    - src-tauri/Cargo.toml
    - src-tauri/src/database/schema.rs
    - src-tauri/src/lib.rs

key-decisions:
  - "Clone codec_params to avoid borrow checker issues with format.next_packet() loop"
  - "Default to 44100Hz sample rate and 2 channels if codec params missing"
  - "Handle ResetRequired error by recreating decoder"
  - "Skip corrupted packets during decode instead of failing entire file"

patterns-established:
  - "Shared PCM decode infrastructure: Both fingerprinting and ReplayGain use audio::decode_to_pcm"
  - "Schema migration pattern: PHASE7_SCHEMA_SQL + migrate_to_v5() + version check in initialize_schema"

# Metrics
duration: 4min 20sec
completed: 2026-02-05
---

# Phase 07 Plan 01: Foundation Layer Summary

**Schema v5 migration with 4 enhancement tables, shared Symphonia PCM decoder returning interleaved i16 samples for fingerprinting and ReplayGain**

## Performance

- **Duration:** 4 min 20 sec
- **Started:** 2026-02-05T23:50:22Z
- **Completed:** 2026-02-05T23:54:42Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- Schema version 5 with fingerprints, artwork, replaygain, review_queue tables for all Phase 7 enhancements
- Shared audio PCM decoder (decode_to_pcm) using Symphonia that both fingerprinting and ReplayGain modules will use
- All Phase 7 crate dependencies added and compiling successfully
- Foundation layer complete for three enhancement features

## Task Commits

Each task was committed atomically:

1. **Task 1: Add Phase 7 dependencies and audio PCM decoder module** - `6299e55` (feat)
2. **Task 2: Add Phase 7 database schema migration (v4 to v5)** - `797de36` (feat)

## Files Created/Modified

- `src-tauri/Cargo.toml` - Added rusty-chromaprint, ebur128, musicbrainz_rs, image dependencies
- `src-tauri/Cargo.lock` - Locked Phase 7 dependency versions
- `src-tauri/src/audio/mod.rs` - Audio module with re-export of decode_to_pcm
- `src-tauri/src/audio/decoder.rs` - Symphonia-based PCM decoder returning (Vec<i16>, sample_rate, channels)
- `src-tauri/src/lib.rs` - Added audio module to public exports
- `src-tauri/src/database/schema.rs` - Schema v5 migration with 4 new tables and indexes

## Decisions Made

- **Clone codec_params before decode loop** - Cloning codec params before the packet loop avoids borrow checker errors from holding immutable borrow of format during format.next_packet() calls
- **Graceful handling of decode errors** - Skip corrupted packets with DecodeError instead of failing entire file, handle ResetRequired by recreating decoder
- **Default sample rate and channels** - Default to 44100Hz and 2 channels if codec params are None for robustness with unusual files
- **Shared decode infrastructure** - Single decode_to_pcm function used by both fingerprinting (Plan 02) and ReplayGain (Plan 03) to avoid code duplication

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**Borrow checker error in decoder loop**
- **Issue:** Initial implementation held reference to codec_params from format.tracks() while calling format.next_packet() mutably
- **Solution:** Clone codec_params before the loop to separate the lifetimes
- **Resolution time:** ~1 minute to identify and fix

## Next Phase Readiness

Foundation layer complete. Ready for:
- **Plan 02 (Fingerprinting):** Schema and decoder ready, can implement chromaprint fingerprinting with MusicBrainz/AcoustID lookup
- **Plan 03 (ReplayGain):** Schema and decoder ready, can implement EBU R128 loudness analysis
- **Plan 04 (Artwork):** Schema ready, can implement MusicBrainz artwork fetching with image processing

All dependencies compile successfully. No blockers for enhancement implementations.

---
*Phase: 07-enhancements*
*Completed: 2026-02-05*
