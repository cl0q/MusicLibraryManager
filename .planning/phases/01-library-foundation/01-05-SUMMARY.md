---
phase: 01-library-foundation
plan: 05
subsystem: search
tags: [whoosh, rapidfuzz, full-text-search, fuzzy-matching, python]

# Dependency graph
requires:
  - phase: 01-01
    provides: database schema with files and metadata tables
  - phase: 01-03
    provides: metadata extraction for search indexing
provides:
  - Whoosh full-text search indexing
  - RapidFuzz fuzzy matching engine
  - SearchResult and SearchResponse data models
  - CLI for search testing
affects: [UI search, playlist filtering, sync operations]

# Tech tracking
tech-stack:
  added: [whoosh, rapidfuzz]
  patterns: [two-phase search (Whoosh candidates + RapidFuzz scoring), per-field fuzzy scoring]

key-files:
  created:
    - src/search/__init__.py
    - src/search/indexer.py
    - src/search/models.py
    - src/search/engine.py

key-decisions:
  - "token_set_ratio + partial_ratio for best typo/substring handling"
  - "Whoosh FuzzyTermPlugin (~1 edit distance) for typo candidates"
  - "Per-field scoring with max() for accurate substring matching"
  - "StemmingAnalyzer for better term matching (running matches run)"

patterns-established:
  - "Two-phase search: Whoosh for fast candidate retrieval, RapidFuzz for precision scoring"
  - "Configurable threshold via SEARCH_FUZZY_THRESHOLD (default 80)"

# Metrics
duration: 7min
completed: 2026-02-03
---

# Phase 1 Plan 5: Full-Text Search Summary

**Whoosh full-text search with RapidFuzz fuzzy matching enabling instant library search with typo tolerance and word reordering**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-03T14:16:13Z
- **Completed:** 2026-02-03T14:23:02Z
- **Tasks:** 3
- **Files created:** 4

## Accomplishments
- Whoosh index with schema supporting artist, album_artist, album, title, genre, year, comments
- Fuzzy search combining token_set_ratio and partial_ratio for robust matching
- Search results with timing, scoring, and proper sorting
- CLI interface for testing: `python -m src.search.engine <query>`

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Whoosh full-text indexer** - `64732b2` (feat)
2. **Task 2: Create search result data models** - `8da624f` (feat)
3. **Task 3: Build search engine with fuzzy matching** - `3621fd5` (feat)

## Files Created
- `src/search/__init__.py` - Module exports
- `src/search/indexer.py` - Whoosh indexing (create_index, index_library, reindex_library)
- `src/search/models.py` - SearchResult and SearchResponse dataclasses
- `src/search/engine.py` - Search engine with fuzzy matching and CLI

## Decisions Made

1. **Changed from token_sort_ratio to token_set_ratio + partial_ratio:**
   - token_sort_ratio penalizes length differences too heavily
   - token_set_ratio handles word subsets well ("dzem" in "Dzem - Koszmarna Noc")
   - partial_ratio adds typo tolerance for partial matches
   - Combined approach gives best results for music search use case

2. **Added Whoosh FuzzyTermPlugin for typo candidate retrieval:**
   - Without fuzzy Whoosh queries, typos wouldn't find any candidates
   - ~1 edit distance allows finding candidates like "djem" -> "dzem"
   - RapidFuzz still does final scoring/filtering

3. **Per-field scoring instead of combined text:**
   - Scoring against combined "artist album title" text dilutes matches
   - Per-field scoring with max() ensures exact field matches score high
   - "dzem" scores 100% against title field alone

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Changed from token_sort_ratio to combined scoring**
- **Found during:** Task 3 (Build search engine)
- **Issue:** token_sort_ratio scoring too low for valid matches (33% for "dzem" vs "Dzem - Koszmarna Noc")
- **Fix:** Combined token_set_ratio + partial_ratio with per-field scoring
- **Files modified:** src/search/engine.py
- **Verification:** Search for "dzem" now returns correct result with 100% score
- **Committed in:** 3621fd5

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Algorithm adjustment necessary for correct search behavior. Plan specified token_sort_ratio but real-world data required more robust approach.

## Issues Encountered
- Initial implementation returned 0 results for valid queries due to token_sort_ratio length penalty
- Resolved by switching to combined scoring algorithm

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Search infrastructure complete and tested
- Ready for UI integration with instant search
- Index will grow incrementally as files are imported (index_library handles unindexed files)

---
*Phase: 01-library-foundation*
*Completed: 2026-02-03*
