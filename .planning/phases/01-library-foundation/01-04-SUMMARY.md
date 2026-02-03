---
phase: 01
plan: 04
subsystem: search
tags: [tantivy, strsim, fuzzy-matching, full-text-search]

dependency-graph:
  requires: [01-01, 01-02]
  provides: [search-index, fuzzy-query, search-command]
  affects: [01-05, 06-ui]

tech-stack:
  added: [tantivy, strsim]
  patterns: [two-pass-search, multi-strategy-scoring]

key-files:
  created:
    - src-tauri/src/search/mod.rs
    - src-tauri/src/search/indexer.rs
    - src-tauri/src/search/query.rs
    - src-tauri/src/commands/search.rs
  modified:
    - src-tauri/src/commands/mod.rs
    - src-tauri/src/lib.rs
    - src-tauri/Cargo.toml

decisions:
  - id: two-pass-search
    choice: "Database LIKE for candidates, fuzzy scoring for ranking"
    rationale: "Tantivy index not integrated with import flow yet; LIKE provides fast initial filter"
    alternatives: ["Tantivy-only", "In-memory scan all tracks"]
  - id: multi-strategy-scoring
    choice: "Combine Jaro-Winkler + Levenshtein + token matching"
    rationale: "Different algorithms excel at different error types"
    alternatives: ["Jaro-Winkler only", "Levenshtein only"]
  - id: fuzzy-threshold
    choice: "0.75 threshold"
    rationale: "Balances precision/recall, slightly relaxed from Python's 0.80 for Jaro-Winkler characteristics"
    alternatives: ["0.80", "0.70"]

metrics:
  duration: 6m 6s
  completed: 2026-02-03
---

# Phase 01 Plan 04: Full-Text Search Summary

Tantivy indexer with schema for artist/album/title, fuzzy query using Jaro-Winkler + Levenshtein + token matching via strsim

## What Was Built

### Search Index (indexer.rs)
- `SearchIndex` struct holding Tantivy index and field references
- `create_index(path)` - Creates persistent Tantivy index with schema:
  - `artist`: TEXT | STORED
  - `album`: TEXT | STORED
  - `title`: TEXT | STORED
  - `track_id`: u64 STORED
- `open_index(path)` - Opens existing index
- `index_track(writer, track, index)` - Adds track document
- `commit_index(writer)` - Persists changes atomically

### Fuzzy Search Query (query.rs)
- `search_tracks(conn, query)` - Two-pass search:
  1. Database LIKE query for candidate retrieval (max 100)
  2. Multi-strategy fuzzy scoring:
     - Full string: Jaro-Winkler + Levenshtein
     - Substring containment with coverage bonus
     - Token-based word matching for multi-word queries
- `SearchResult` struct with track and score (0.0-1.0)
- Results filtered by 0.75 threshold, sorted by score descending

### Tauri Command (commands/search.rs)
- `search_library(query)` - Async command for frontend integration
- Returns `Vec<SearchResult>` as JSON
- Registered in invoke_handler

## Key Implementation Details

### Fuzzy Scoring Strategy
```rust
fn score_field(query: &str, field: &str) -> f64 {
    // Strategy 1: Full string fuzzy match
    let full_score = jaro_winkler(query, field).max(normalize_levenshtein(query, field));

    // Strategy 2: Substring containment
    let substring_score = if field.contains(query) {
        0.8 + (coverage * 0.2)  // High score for exact substrings
    } else { 0.0 };

    // Strategy 3: Token-based matching
    let token_score = score_tokens(query, field);  // Handles "beatls" vs "the beatles"

    full_score.max(substring_score).max(token_score)
}
```

### Limitation: LIKE vs Tantivy
The current implementation uses SQL LIKE for candidate retrieval, which cannot find typo matches like "beatls" for "Beatles" (typo is not a substring). Full typo tolerance requires Tantivy integration in the candidate retrieval phase. This is acceptable for Phase 1 foundation.

## Test Coverage

13 new tests added:
- Indexer: create_index, index_track, open_existing_index
- Query: normalize_levenshtein, calculate_fuzzy_score, empty_query, no_matches, exact_match, fuzzy_match, sorted_by_score, case_insensitive, multiple_fields
- Command: search_result_serializable

## Dependencies Added

| Crate | Version | Purpose |
|-------|---------|---------|
| tantivy | 0.22 | Full-text search indexing |
| strsim | 0.11 | String similarity algorithms |

## Commits

| Hash | Message |
|------|---------|
| 37b52fe | feat(01-03): add Tauri command handler for import workflow (included search foundation) |
| 922236b | feat(01-04): implement search query with fuzzy scoring using strsim |

## Deviations from Plan

### [Rule 3 - Blocking] Search module already existed

The search module (indexer.rs, mod.rs, query.rs stub) was already created in commit 37b52fe as part of plan 01-03. Task 1 work was already committed. Continued with Task 2 implementation.

## Next Phase Readiness

**Ready for 01-05 (Duplicate Detection):**
- SearchResult provides scored matches for duplicate candidates
- Tantivy index available for potential duplicate detection via similarity
- Database query patterns established for multi-field matching

**Deferred to Phase 6 (UI):**
- Database path configuration (currently hardcoded to `music_library.db`)
- Index path configuration (indexer uses `./search_index/`)
- Tantivy integration with import flow (index tracks on import)

---
*Generated by GSD execute-plan workflow*
