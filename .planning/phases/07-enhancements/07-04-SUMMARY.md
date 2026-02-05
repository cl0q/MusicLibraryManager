---
phase: 07-enhancements
plan: 04
subsystem: audio-processing
tags: [replaygain, ebur128, loudness-normalization, lofty, tagging, sync]

# Dependency graph
requires:
  - phase: 07-01
    provides: Schema v5 with replaygain table and PCM decoder
  - phase: 05-04
    provides: Incremental sync orchestration with execute_sync pipeline
provides:
  - EBU R128 loudness analysis producing ReplayGain 2.0 gain/peak values
  - Database persistence for track and album gain values
  - ReplayGain tag writer using lofty (writes only to synced copies)
  - Sync pipeline integration for automatic tag writing
affects: [rockbox-playback, volume-normalization, audio-quality]

# Tech tracking
tech-stack:
  added: [ebur128]
  patterns:
    - "Best-effort tagging: sync continues even if RG values not calculated yet"
    - "Library originals stay pristine: tags written only during sync to copies"
    - "EBU R128 with -18 LUFS reference for ReplayGain 2.0 compliance"
    - "Album gain via loudness_global_multiple for multi-track analysis"

key-files:
  created:
    - src-tauri/src/replaygain/mod.rs
    - src-tauri/src/replaygain/analyzer.rs
    - src-tauri/src/replaygain/tagger.rs
  modified:
    - src-tauri/src/lib.rs
    - src-tauri/src/sync/progress.rs

key-decisions:
  - "ReplayGain 2.0 reference level: -18 LUFS (not -23 LUFS broadcast standard)"
  - "Best-effort tagging during sync: non-fatal if gain values not yet calculated"
  - "Library originals stay pristine: tags written only to synced copies in profile folders"
  - "Silence handling: clamp to +20 dB gain for -infinity loudness"

patterns-established:
  - "EBU R128 loudness analysis via ebur128 crate with Mode::I | Mode::TRUE_PEAK"
  - "Tag format: '{:.2} dB' for gain, '{:.6}' for peak (ReplayGain 2.0 spec)"
  - "Album gain via EbuR128::loudness_global_multiple with iterator over analyzers"
  - "Incremental batch analysis: get_unanalyzed_tracks identifies tracks needing processing"

# Metrics
duration: 159min
completed: 2026-02-05
---

# Phase 07 Plan 04: ReplayGain 2.0 Summary

**EBU R128 loudness analysis with -18 LUFS reference, database persistence for gain values, lofty tag writer integrated into sync pipeline for Rockbox volume normalization**

## Performance

- **Duration:** 2h 39m
- **Started:** 2026-02-05T11:12:58Z
- **Completed:** 2026-02-05T13:52:51Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- EBU R128 loudness analysis producing ReplayGain 2.0 gain and peak values with -18 LUFS reference
- Database persistence for track gain, album gain, and peak values in replaygain table
- ReplayGain tag writer using lofty with proper format ("{:.2} dB", "{:.6}")
- Sync pipeline integration: automatic tag writing to synced copies after file link
- Batch analysis with incremental processing (get_unanalyzed_tracks)
- 7 unit tests passing (5 analyzer, 2 tagger)

## Task Commits

Tasks were already committed in prior work (07-03 artifact creation):

1. **Task 1: EBU R128 loudness analysis and database storage** - Implemented in 086199e (feat)
   - analyzer.rs with analyze_loudness, analyze_track, analyze_album
   - Database functions: save_track_gain, save_album_gain, get_track_gain, get_unanalyzed_tracks
   - batch_analyze for multi-track processing with error handling
   - 5 unit tests for silence, full-scale, reference level, save/load, unanalyzed tracking

2. **Task 2: ReplayGain tag writer and sync pipeline integration** - Completed in 285dcbf (fix)
   - write_gain_tags: writes ReplayGain 2.0 tags via lofty ItemKey
   - read_gain_tags: parses tags back to f64 values
   - Sync integration in execute_sync: best-effort tagging after file link
   - get_album_gain helper for album gain retrieval
   - 2 tagger compile tests

_Note: Implementation was completed by prior execution agent during 07-03 artifact phase. This execution verified correctness and test coverage._

## Files Created/Modified
- `src-tauri/src/replaygain/mod.rs` - Public API for replaygain module
- `src-tauri/src/replaygain/analyzer.rs` - EBU R128 loudness analysis producing gain/peak values
- `src-tauri/src/replaygain/tagger.rs` - Write ReplayGain tags to synced files via lofty
- `src-tauri/src/sync/progress.rs` - Sync pipeline integration for automatic tag writing
- `src-tauri/src/lib.rs` - Added pub mod replaygain

## Decisions Made

**1. ReplayGain 2.0 reference level: -18 LUFS**
- Rationale: ReplayGain 2.0 standard uses -18 LUFS reference, not -23 LUFS broadcast standard
- Implementation: `gain = -18.0 - loudness` in analyze_loudness function
- Verification: test_replaygain_reference_level validates formula correctness

**2. Best-effort tagging during sync**
- Rationale: Gain analysis may not be done yet; sync should continue regardless
- Implementation: Skip silently if get_track_gain returns None, log warning if write fails
- Result: Non-fatal - sync succeeds even if RG tagging fails

**3. Library originals stay pristine**
- Rationale: Tags should only be written to synced copies for Rockbox playback
- Implementation: write_gain_tags called in execute_sync after file link to profile folder
- Guarantee: Library originals in tracks table never modified

**4. Silence handling: clamp to +20 dB**
- Rationale: EBU R128 returns -infinity loudness for silence, which would cause invalid gain
- Implementation: `if loudness.is_infinite() || loudness < -70.0 { return Ok((20.0, 0.0)); }`
- Verification: test_analyze_loudness_silence validates clamping behavior

## Deviations from Plan

None - plan executed exactly as written. Pre-existing compilation errors in fingerprint and artwork modules were fixed as blocking issues (Rule 3) during environment setup.

## Issues Encountered

**1. Pre-existing compilation errors**
- **Issue:** fingerprint/matcher.rs used `seg.length` instead of `seg.items_count` (rusty-chromaprint API change)
- **Fix:** Updated field references to match current API
- **Status:** Fixed as part of environment setup (Rule 3 - blocking)

**2. Pre-existing lofty API changes**
- **Issue:** artwork/embed.rs missing WriteOptions parameter for save_to_path
- **Fix:** Added WriteOptions::default() parameter
- **Status:** Fixed as part of environment setup (Rule 3 - blocking)

**3. ebur128 API discovery**
- **Issue:** Initially used incorrect ebur128::loudness_global_multiple (free function instead of method)
- **Fix:** Changed to EbuR128::loudness_global_multiple(album_analyzers.iter())
- **Status:** Corrected during implementation

## User Setup Required

None - no external service configuration required.

## Verification Results

All tests passing:
```
test replaygain::analyzer::tests::test_analyze_loudness_silence ... ok
test replaygain::analyzer::tests::test_analyze_loudness_full_scale ... ok
test replaygain::analyzer::tests::test_replaygain_reference_level ... ok
test replaygain::analyzer::tests::test_save_and_load_track_gain ... ok
test replaygain::analyzer::tests::test_get_unanalyzed_tracks ... ok
test replaygain::tagger::tests::test_write_gain_tags_compiles ... ok
test replaygain::tagger::tests::test_read_gain_tags_compiles ... ok
test sync::progress::tests::test_execute_sync_links_files ... ok
test sync::progress::tests::test_execute_sync_updates_state ... ok
```

**Key verifications:**
- Gain calculation uses -18 LUFS reference (test_replaygain_reference_level)
- Silence handled gracefully with +20 dB clamp (test_analyze_loudness_silence)
- Full-scale audio produces negative gain (test_analyze_loudness_full_scale)
- Database persistence works correctly (test_save_and_load_track_gain)
- Incremental processing identifies unanalyzed tracks (test_get_unanalyzed_tracks)
- Sync pipeline continues normally even without gain values (test_execute_sync_*)

## Next Phase Readiness

**Ready for:**
- Phase 07-05: User can now run batch_analyze on library tracks to populate gain values
- Phase 07-06: Rockbox iPod can read ReplayGain tags from synced M4A files for volume normalization

**Integration points:**
- analyze_track: Called manually or via background job to compute gain for individual tracks
- analyze_album: Groups tracks by album for album-level gain calculation
- batch_analyze: Processes multiple tracks with error handling for large libraries
- Sync pipeline: Automatically writes tags to synced copies when gain values exist

**Performance notes:**
- EBU R128 analysis requires full PCM decode (shared with fingerprinting via decode_to_pcm)
- Album gain analysis processes all album tracks sequentially (may take time for large albums)
- Database queries optimized with LEFT JOIN for get_unanalyzed_tracks

**Future enhancements:**
- Background job to automatically analyze new imports
- UI for triggering batch analysis with progress tracking
- Album grouping strategy (currently via external logic)

---
*Phase: 07-enhancements*
*Plan: 04*
*Completed: 2026-02-05*
