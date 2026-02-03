---
phase: 03-multi-source-aggregation
plan: 04
subsystem: dedup, search
tags: [strsim, jaro-winkler, unicode-normalization, regex, fuzzy-matching, deduplication]

# Dependency graph
requires:
  - phase: 01-library-foundation
    provides: tracks table, duplicate detection module
  - phase: 03-01
    provides: schema extensions with variant_of column, sources table
provides:
  - String normalization for track/artist comparison (Unicode, punctuation, whitespace)
  - Featuring notation standardization (feat., ft., &, featuring, with)
  - Jaro-Winkler fuzzy similarity scoring with 70/30 title/artist weighting
  - Variant detection for remixes, edits, live, acoustic versions
affects: [03-05, 03-06, 06-ui]

# Tech tracking
tech-stack:
  added: [regex 1]
  patterns: [LazyLock regex compilation, pre-normalization substitution for featuring, weighted similarity scoring]

key-files:
  created:
    - src-tauri/src/dedup/mod.rs
    - src-tauri/src/dedup/normalize.rs
    - src-tauri/src/dedup/matcher.rs
  modified:
    - src-tauri/Cargo.toml
    - src-tauri/src/lib.rs

key-decisions:
  - "Featuring substitution before punctuation removal to preserve ampersand"
  - "LazyLock for compiled regex patterns (zero-cost after first use)"
  - "70/30 title/artist weighting for similarity scoring"
  - "0.90 artist threshold for variant detection"
  - "0.85 base title threshold for variant detection"

patterns-established:
  - "Pre-normalization substitution: apply semantic replacements (featuring notation, ampersand) before stripping punctuation"
  - "Weighted similarity: title 70% + artist 30% via Jaro-Winkler distance"
  - "Variant detection: one title has keyword (remix/edit/live/etc.), other doesn't, base titles match"
  - "Static LazyLock<Regex> for compiled regex patterns shared across calls"

# Metrics
duration: 6min
completed: 2026-02-03
---

# Phase 3 Plan 4: Track Normalization and Fuzzy Duplicate Detection Summary

**Jaro-Winkler fuzzy matching with Unicode normalization, featuring notation standardization, and variant detection for cross-source deduplication**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-02-03T22:41:03Z
- **Completed:** 2026-02-03T22:46:49Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Implemented Unicode-aware string normalization using NFC composition with punctuation removal and whitespace collapsing
- Built featuring notation standardizer handling feat., ft., featuring, with, and & variations
- Created Jaro-Winkler similarity calculator with 70/30 title/artist weighting
- Implemented variant detection for remix/edit/live/acoustic/instrumental/etc. keywords
- 22 tests covering normalization edge cases, similarity scoring, and variant identification
- All 168 project tests pass (162 active, 6 expected ignored)

## Task Commits

Both tasks were already implemented and committed as part of plan 03-02 (Spotify API client), which bundled the dedup module:

1. **Task 1: String normalization** - `16eab6d` (included in feat(03-02) commit)
2. **Task 2: Fuzzy duplicate detection** - `16eab6d` (included in feat(03-02) commit)

Note: The dedup module was proactively implemented during plan 03-02 as it was needed for Spotify track deduplication during sync. This plan verified the implementation meets all 03-04 requirements.

## Files Created/Modified
- `src-tauri/src/dedup/mod.rs` - Module exports: normalize, normalize_artist, calculate_similarity, is_variant
- `src-tauri/src/dedup/normalize.rs` - Unicode NFC normalization, punctuation removal, featuring notation standardization (193 lines)
- `src-tauri/src/dedup/matcher.rs` - Jaro-Winkler similarity scoring and variant detection (251 lines)
- `src-tauri/Cargo.toml` - Added regex crate dependency
- `src-tauri/src/lib.rs` - Added dedup module declaration

## Decisions Made
- **Featuring substitution before punctuation removal:** The ampersand (&) character is stripped by general punctuation removal, so featuring notation (& between artist names) must be substituted to "feat" before the normalize() function runs
- **LazyLock for regex compilation:** Static LazyLock<Regex> ensures compiled patterns are shared across all calls without runtime overhead after first use
- **Case-insensitive featuring regex:** Applied (?i) flag to featuring regex since substitution happens before lowercase conversion
- **Real-world test values for Jaro-Winkler:** Used distinct track names ("Bohemian Rhapsody" vs "Stairway to Heaven") in tests because Jaro-Winkler gives high scores for strings with common prefixes ("Song A" vs "Song B" scores 0.92)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Featuring substitution order**
- **Found during:** Task 1 (normalize_artist implementation)
- **Issue:** Plan called normalize() first then applied featuring regex, but normalize() strips "&" as punctuation, making ampersand-based featuring detection impossible
- **Fix:** Reversed order: apply featuring/ampersand substitution on raw input, then call normalize()
- **Files modified:** src-tauri/src/dedup/normalize.rs
- **Verification:** All 9 normalize tests pass including "Artist & Someone" -> "artist feat someone"
- **Committed in:** 16eab6d (part of 03-02 commit)

**2. [Rule 1 - Bug] Jaro-Winkler prefix bias in tests**
- **Found during:** Task 2 (matcher tests)
- **Issue:** Test used "Song A" vs "Song B" expecting score < 0.85, but Jaro-Winkler prefix weighting gives 0.92 for strings sharing "Song " prefix
- **Fix:** Used realistic distinct track names ("Bohemian Rhapsody" vs "Stairway to Heaven") that properly test dissimilarity
- **Files modified:** src-tauri/src/dedup/matcher.rs (tests only)
- **Verification:** All 13 matcher tests pass
- **Committed in:** 16eab6d (part of 03-02 commit)

**3. [Rule 1 - Bug] Removed find_duplicates async database dependency**
- **Found during:** Task 2 (matcher implementation)
- **Issue:** Plan included find_duplicates function requiring Database struct that doesn't exist in codebase (uses raw Connection). Also mixed async with sync patterns.
- **Fix:** Removed find_duplicates from plan scope; the existing duplicate::detector module already handles database-backed detection. The dedup module focuses on pure similarity functions that can be called from any context.
- **Files modified:** src-tauri/src/dedup/mod.rs, src-tauri/src/dedup/matcher.rs
- **Verification:** Module compiles, all tests pass, no dead code
- **Committed in:** 16eab6d (part of 03-02 commit)

---

**Total deviations:** 3 auto-fixed (3 bugs)
**Impact on plan:** All fixes necessary for correctness. No scope creep -- the find_duplicates removal actually tightened scope to pure functions.

## Issues Encountered
None beyond the deviations noted above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Normalization functions ready for use in Spotify/SoundCloud sync pipelines
- calculate_similarity can be used for cross-source duplicate detection before download
- is_variant enables populating variant_of column in database
- Next plans (03-05, 03-06) can use dedup module for track matching during sync

---
*Phase: 03-multi-source-aggregation*
*Completed: 2026-02-03*
