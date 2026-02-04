---
phase: 04-playlist-management
plan: 01
status: complete
subsystem: database
tags: [schema, models, rust, sqlite, fractional-indexing]
requires: [03-06]
provides:
  - playlist-schema-v3
  - playlist-models
affects: [04-02, 04-03, 04-04]
tech-stack:
  added: []
  patterns:
    - fractional-indexing-for-ordering
    - category-enum-for-playlist-types
    - cascade-delete-for-junction-tables
key-files:
  created:
    - src-tauri/src/models/playlist.rs
  modified:
    - src-tauri/src/database/schema.rs
    - src-tauri/src/models/mod.rs
decisions: []
metrics:
  duration: 2m 28s
  completed: 2026-02-04
---

# Phase 04 Plan 01: Schema and Models for Playlist Management Summary

**One-liner:** Database schema version 3 with playlists, playlist_tracks (fractional indexing), playlist_tags tables and corresponding Rust models with PlaylistCategory enum

## What Was Built

Extended the database schema to support playlist management with robust ordering through fractional indexing:

1. **PHASE4_SCHEMA_SQL constant** with three new tables:
   - `playlists` table: Stores playlist metadata with category (liked/smart/regular), flags (pinned, liked, smart), cover images, and optional source linkage
   - `playlist_tracks` table: Junction table with fractional indexing `position TEXT` column for stable ordering, UNIQUE(playlist_id, track_id) constraint to prevent duplicates
   - `playlist_tags` table: Flexible tagging system with composite primary key on (playlist_id, tag)

2. **Schema migration infrastructure**:
   - Updated CURRENT_SCHEMA_VERSION from 2 to 3
   - Added `migrate_to_v3` function following established Phase 3 pattern
   - Updated `initialize_schema` to apply Phase 4 migrations when upgrading from version 2

3. **Rust models** in `src-tauri/src/models/playlist.rs`:
   - `PlaylistCategory` enum with Liked, Smart, Regular variants
   - Display trait implementation for database serialization ("liked", "smart", "regular")
   - `from_str` parser for database deserialization
   - `Playlist` struct with all schema fields (12 fields total)
   - `PlaylistTrack` struct with fractional `position: String` field
   - `PlaylistTag` struct for tag associations
   - All models derive Serialize/Deserialize for Tauri command compatibility

4. **Test coverage**:
   - 5 new model tests for category parsing and serialization
   - All existing schema tests continue to pass (10 tests)
   - No compilation warnings

## Technical Decisions

**Fractional indexing for position:**
- Used TEXT column instead of INTEGER for flexible fractional values
- Eliminates rebalancing overhead when reordering tracks
- Supports unlimited reordering operations without gaps
- String sorting provides lexicographic ordering (e.g., "a0", "a0V", "a1")

**PlaylistCategory as enum:**
- Type-safe representation of playlist types
- Display trait maps to database string values
- Prevents invalid category values at type level

**Cascade deletion on foreign keys:**
- playlist_tracks CASCADE on playlist deletion (cleanup junction table)
- playlist_tags CASCADE on playlist deletion (cleanup tags)
- Playlist source_id SET NULL on source deletion (preserve playlist)

**Indexes for query performance:**
- `idx_playlist_category` on playlists(category) for filtering
- `idx_playlist_position` on playlist_tracks(playlist_id, position) for ordered retrieval
- `idx_tag` on playlist_tags(tag) for tag-based search

## Deviations from Plan

None - plan executed exactly as written.

## Testing Notes

**Schema verification:**
- All 10 existing schema tests pass
- migrate_to_v3 tested via initialize_schema idempotency
- Fresh database initializes to version 3
- Migration from v2 to v3 creates all Phase 4 tables

**Model verification:**
- Category enum Display/from_str round-trip tested
- JSON serialization verified for all models
- Fractional position stored as string confirmed in serialization test

## Next Phase Readiness

**Blockers:** None

**Concerns:**
- Fractional indexing implementation deferred to plan 04-02 (ordering logic, conflict resolution)
- Smart playlist rule engine deferred to future phase (plan executes rules)
- Cover image storage strategy not yet defined (local vs remote priority)

**Ready for:**
- 04-02: Core playlist operations (CRUD, track management)
- 04-03: Playlist ordering with fractional indexing implementation
- 04-04: Export to M3U8 format for device sync

## Changes by File

### src-tauri/src/database/schema.rs
**Lines changed:** +64 -2

- Added PHASE4_SCHEMA_SQL constant (45 lines)
- Updated CURRENT_SCHEMA_VERSION from 2 to 3
- Added migrate_to_v3 function
- Updated initialize_schema migration logic

**Key additions:**
- playlists table with category, flags, cover fields
- playlist_tracks table with TEXT position column
- playlist_tags table with composite primary key
- Three new indexes for query optimization

### src-tauri/src/models/playlist.rs
**Lines changed:** +166 (new file)

- PlaylistCategory enum with Display trait
- Playlist struct (12 fields)
- PlaylistTrack struct with fractional position
- PlaylistTag struct
- 5 unit tests for category and serialization

**Exports:** Playlist, PlaylistCategory, PlaylistTrack, PlaylistTag

### src-tauri/src/models/mod.rs
**Lines changed:** +4 -1

- Added `pub mod playlist;` declaration
- Exported all four playlist types in public API

## Performance Impact

**Database size:**
- Three new tables with indexes
- Minimal overhead (junction tables, no large TEXT fields)

**Query performance:**
- Indexes on category, position, tag enable fast filtering
- Fractional indexing eliminates rebalancing queries

**Compilation:**
- New models compile cleanly in 6.3s (no noticeable impact)
- 5 new tests add <10ms to test suite runtime

## Future Considerations

**Fractional indexing implementation:**
- Need ordering logic to generate positions between two tracks
- Conflict resolution strategy for concurrent updates
- Rebalancing strategy if positions grow too long

**Smart playlists:**
- Schema supports is_smart flag
- Rule storage and engine deferred to future phase
- Could use JSON column or separate rules table

**Cover images:**
- Schema has both local path and remote URL
- Need strategy for downloading, caching, fallbacks
- Image resizing/optimization for UI display

**Multi-user support:**
- Schema ready (source_id links playlists to user sources)
- Phase 6 will add user context to operations

## Commits

- `6a8adf3`: feat(04-01): extend database schema with Phase 4 playlist tables
- `5851a41`: feat(04-01): create Playlist, PlaylistTrack, PlaylistTag models
