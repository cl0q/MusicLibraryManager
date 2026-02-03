---
phase: 02-download-infrastructure
plan: 03
subsystem: transcode
tags: [symphonia, ffmpeg, aac, audio-conversion, codec-detection]

# Dependency graph
requires:
  - phase: 01-library-foundation
    provides: Database schema and metadata extraction infrastructure
provides:
  - Audio format detection with Symphonia (codec, bitrate, lossless flag)
  - FFmpeg AAC transcoding wrapper with libfdk_aac support and fallback
  - Smart transcode orchestration (lossless always transcodes, lossy <248k preserved)
  - TranscodeResult enum for tracking transcode outcomes
affects: [02-04-dabmusic-download, 02-05-youtube-integration, 05-device-sync]

# Tech tracking
tech-stack:
  added: [symphonia 0.5.5 with all features]
  patterns: [atomic write pattern for transcode output, codec-based lossless detection, libfdk_aac with native aac fallback]

key-files:
  created:
    - src-tauri/src/transcode/mod.rs
    - src-tauri/src/transcode/format.rs
    - src-tauri/src/transcode/ffmpeg.rs
  modified:
    - src-tauri/Cargo.toml
    - src-tauri/src/lib.rs

key-decisions:
  - "Symphonia for codec detection instead of ffprobe (pure Rust, no subprocess overhead)"
  - "libfdk_aac as primary encoder with native aac fallback (quality vs availability tradeoff)"
  - "Preserve lossy files <248kbps (avoid quality loss from re-encoding)"
  - "Atomic write pattern with temp files prevents partial transcode outputs"

patterns-established:
  - "Codec-based lossless detection: FLAC/ALAC/WavPack identified from codec type not file extension"
  - "Bitrate calculation: bits_per_coded_sample * sample_rate * channels when available"
  - "Smart transcode decision: lossless→always, lossy<248k→skip, lossy>=248k→transcode"
  - "Error handling: preserve originals on failure, return Failed result not crash"

# Metrics
duration: 4m 52s
completed: 2026-02-03
---

# Phase 2 Plan 3: Audio Transcoding Summary

**Smart FLAC-to-AAC pipeline with codec detection using Symphonia, FFmpeg wrapper with libfdk_aac support, and decision logic that preserves low-bitrate lossy files to avoid quality loss**

## Performance

- **Duration:** 4m 52s
- **Started:** 2026-02-03T20:04:58Z
- **Completed:** 2026-02-03T20:09:49Z
- **Tasks:** 4
- **Files modified:** 5

## Accomplishments
- Audio format detection reads actual codec metadata from file headers (not extensions)
- FFmpeg transcoding wrapper with libfdk_aac availability check and fallback to native AAC
- Smart orchestration: lossless files always transcode, lossy <248kbps preserved, lossy >=248kbps reduced
- Atomic write pattern with temp files ensures no partial outputs on failure

## Task Commits

Each task was committed atomically:

1. **Task 1: Add audio format detection dependencies** - `7a24f66` (chore)
2. **Task 2: Implement audio format detection** - `b585c5b` (feat)
3. **Task 3: Implement FFmpeg AAC transcoding wrapper** - `43afd1f` (feat)
4. **Task 4: Implement transcode orchestration logic** - `d84f87a` (feat)

**Additional fix:** `876b56a` (fix) - Move test-only codec constants to cfg(test)

## Files Created/Modified

- `src-tauri/Cargo.toml` - Added symphonia 0.5.5 dependency with "all" features
- `src-tauri/src/transcode/mod.rs` - Module exports and transcode_audio orchestration function
- `src-tauri/src/transcode/format.rs` - AudioFormat struct and detect_format using Symphonia
- `src-tauri/src/transcode/ffmpeg.rs` - FFmpeg wrapper with libfdk_aac detection and transcode_to_aac
- `src-tauri/src/lib.rs` - Added transcode module registration

## Decisions Made

**Symphonia for codec detection:** Chosen over ffprobe subprocess approach. Symphonia is pure Rust with zero overhead, reads codec metadata directly from file headers (not file extensions), and supports all needed formats (FLAC, AAC, MP3, Opus) through feature flags.

**libfdk_aac with fallback:** Primary encoder for highest quality AAC, with automatic fallback to native FFmpeg AAC encoder if libfdk_aac not available. Logs warning when falling back to ensure user awareness of quality tradeoff.

**Lossy <248kbps preservation:** Critical decision to skip transcoding for already-lossy files below target bitrate. Re-encoding lossy audio causes cascading quality loss (generation loss). Better to keep original 128kbps MP3 than transcode to 248kbps AAC.

**Atomic write pattern:** Transcode to `{output}.tmp.m4a` first, rename to final path only on success. Prevents partial/corrupt files from failed transcodes. Failed transcodes delete temp file and return Failed result while preserving original.

**Bitrate calculation strategy:** Use bits_per_coded_sample * sample_rate * channels when available from Symphonia. For files without this metadata (variable bitrate, some formats), bitrate=None and transcode decision assumes high bitrate (safe default that won't skip needed transcodes).

## Deviations from Plan

**1. [Rule 1 - Bug] Fixed unused import warning**
- **Found during:** Final compilation check
- **Issue:** CODEC_TYPE_AAC, MP3, OPUS, VORBIS only used in test code but imported at module level
- **Fix:** Moved test-only codec constants to #[cfg(test)] conditional import
- **Files modified:** src-tauri/src/transcode/format.rs
- **Verification:** cargo check passes with no warnings
- **Committed in:** 876b56a (separate fix commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Cosmetic fix for compile warning. No functional changes.

## Issues Encountered

**Symphonia CodecType API mismatch:** Initial implementation assumed CodecType was an enum with variants like `CodecType::Flac`. Actual API uses constants like `CODEC_TYPE_FLAC`. Fixed by checking Symphonia source code in cargo registry and switching to constant-based comparisons.

**Bitrate field not directly available:** Symphonia's CodecParameters lacks direct bitrate field. Calculated from `bits_per_coded_sample * sample_rate * channels` when available, returns None otherwise. This aligns with reality - many formats have variable bitrate or don't store bitrate metadata in headers.

## User Setup Required

None - no external service configuration required.

**Note for future integration:** FFmpeg must be installed on user systems for transcode functionality. This will be documented in device sync setup (Phase 5). For Phase 2, transcode module is library code with no user-facing commands yet.

## Next Phase Readiness

**Ready for integration:** Transcode module complete with 7 passing tests. Can be integrated into download flows (dabmusic, YouTube) and device sync operations.

**FFmpeg availability:** Module gracefully handles missing libfdk_aac (fallback to native AAC), but requires ffmpeg binary in PATH. Future tasks should verify ffmpeg presence or provide clear error messages.

**Format support:** Current lossless detection covers FLAC, ALAC, WavPack. PCM/WAV formats could be added if needed (they'd be detected as PCM codec types by Symphonia). Not currently needed for streaming service downloads which use FLAC.

**Performance considerations:** Symphonia probing is fast (pure Rust, no subprocess), but FFmpeg transcode is CPU-intensive. Future device sync flows should consider transcoding in background tasks or parallel processing for batch operations.

---
*Phase: 02-download-infrastructure*
*Completed: 2026-02-03*
