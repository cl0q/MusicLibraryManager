---
phase: 36-playlists-v2-0-macos-native
plan: 01
subsystem: database + model + viewmodel
tags: [migration, playlist, cover-art-prep, schema-v20]
dependency_graph:
  requires:
    - schema v19 baseline (Phase 1 v2.0)
    - PlaylistRepository (existing)
    - Playlist model (existing)
    - PlaylistDetailViewModel (existing)
  provides:
    - migration v20 (cover_is_custom column)
    - Playlist.coverIsCustom field
    - PlaylistRepository.setCoverPath(id:path:isCustom:)
    - PlaylistRepository.fetchTracks deterministic tie-breaker
    - .playlistDidChange post inside moveTrack
  affects:
    - Plan 02 (PlaylistCoverService — consumes setCoverPath + observes moveTrack notification)
    - Plan 03 (Card context-menu "Reset to Auto Cover" — calls setCoverPath(path: nil, isCustom: false))
tech_stack:
  added: []
  patterns:
    - "Idempotent ALTER-TABLE migration with `db.columns(in:).contains` guard"
    - "any DatabaseWriter repository typing (matches TrackRepository pattern)"
    - "Atomic single-statement UPDATE for paired columns (cover_image_path + cover_is_custom)"
    - "userInfo: [playlistId:] payload on .playlistDidChange for targeted regen"
key_files:
  created:
    - macos-app/MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift
  modified:
    - macos-app/MLM/Database/DatabaseManager.swift
    - macos-app/MLM/Models/Playlist.swift
    - macos-app/MLM/Database/PlaylistRepository.swift
    - macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift
    - macos-app/MLMTests/DatabaseTests/DatabaseTests.swift
decisions:
  - "Register migration v20 once inside buildMigrator() — both production migrator and inMemoryMigrator share the same static factory, so single registration covers both. Plan expected ≥2 grep hits; codebase architecture only needs 1."
  - "Relax PlaylistRepository.database from concrete DatabasePool to `any DatabaseWriter` to enable in-memory DatabaseQueue tests. Matches TrackRepository pattern. All three production callers (DependencyContainer, SpotifyClient, SyncService) pass DatabasePool unchanged."
  - "moveTrack notification carries userInfo: [playlistId: Int64] for targeted cover regeneration in Plan 02. The four sibling mutators (addTracks, removeSelectedTracks, removeTrack, importM3U) keep their existing object-less posts — uniform userInfo enrichment is a Plan 02+ concern."
metrics:
  duration_seconds: 230
  duration_human: "~4 minutes"
  tasks_completed: 3
  files_created: 1
  files_modified: 5
  tests_added: 6
  completed_date: "2026-05-13T07:43:01Z"
---

# Phase 36 Plan 01: Schema-Migration v20 + Repository-Setter + moveTrack-Notification — Summary

One-liner: Migration v20 adds `playlists.cover_is_custom INTEGER NOT NULL DEFAULT 0`; `Playlist.coverIsCustom` round-trips through GRDB; new `PlaylistRepository.setCoverPath(id:path:isCustom:)` writes both columns atomically; `fetchTracks` gains `(position, added_at)` tie-breaker; `moveTrack` now posts `.playlistDidChange` with `playlistId` userInfo — laying the database foundation for Plan 02's `PlaylistCoverService`.

## Tasks

### Task 1 — Migration v20 + Playlist.coverIsCustom

- **Commit:** `fdc1fb4` (impl) preceded by `94c92ad` (RED test).
- **Files:**
  - `macos-app/MLM/Database/DatabaseManager.swift` — registered `v20_playlist_cover_custom` migration inside `buildMigrator()` (covers both production migrator and `inMemoryMigrator` since both share the same static factory).
  - `macos-app/MLM/Models/Playlist.swift` — added `coverIsCustom: Int = 0` stored property, `cover_is_custom` CodingKey, `Columns.coverIsCustom`, and `coverIsCustom: 0` to `createNative` factory.
- **Migration body:**
  ```swift
  migrator.registerMigration("v20_playlist_cover_custom") { db in
      if try !db.columns(in: "playlists").contains(where: { $0.name == "cover_is_custom" }) {
          try db.alter(table: "playlists") { t in
              t.add(column: "cover_is_custom", .integer).notNull().defaults(to: 0)
          }
      }
  }
  ```

### Task 2 — setCoverPath setter + fetchTracks tie-breaker + 5 cover tests

- **Commit:** `49861d8` (impl) preceded by `3399d64` (RED tests + DB-type relaxation).
- **Files:**
  - `macos-app/MLM/Database/PlaylistRepository.swift` — added `setCoverPath(id:path:isCustom:) async throws` and changed `fetchTracks` ORDER BY from `pt.position` to `pt.position, pt.added_at ASC`. Also relaxed `database` field from `DatabasePool` to `any DatabaseWriter`.
  - `macos-app/MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift` — new file with 5 `@Test` cases.
- **setCoverPath body:**
  ```swift
  func setCoverPath(id: Int64, path: String?, isCustom: Bool) async throws {
      try await database.write { db in
          try db.execute(
              sql: "UPDATE playlists SET cover_image_path = ?, cover_is_custom = ? WHERE id = ?",
              arguments: [path, isCustom ? 1 : 0, id]
          )
      }
  }
  ```
- **Tie-breaker rationale:** Phase 36 PATTERNS section #10 — `PlaylistCoverService` (Plan 02) picks the first 4 tracks for the 2×2 mosaic. When two `playlist_tracks` rows share an identical fractional position (rare-but-possible state), `added_at ASC` makes the selection stable across runs.

### Task 3 — moveTrack posts .playlistDidChange

- **Commit:** `c7c21d7`.
- **File:** `macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift`.
- **Change:** Added one `NotificationCenter.default.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": playlistId])` inside the `do` block of `moveTrack(from:to:)`, immediately after `await loadTracks()`. Closes the D-04 Re-Generate-Trigger gap: `moveTrack` was the only one of five mutators (addTracks, removeSelectedTracks, removeTrack, importM3U, moveTrack) that did not post.

## Verification

| Gate                                                    | Result |
| ------------------------------------------------------- | ------ |
| `swift test --filter PlaylistRepositoryCoverTests`      | 5/5 green |
| `swift test --filter DatabaseTests`                     | 14/14 green (no regression; existing 13 + 1 new) |
| `swift build`                                           | exits 0 |
| `grep -c 'v20_playlist_cover_custom' DatabaseManager.swift` | 1 (see deviation D-EX-01) |
| `grep -c 'coverIsCustom' Playlist.swift`                | 4 |
| `grep -c 'func setCoverPath' PlaylistRepository.swift`  | 1 |
| `grep -c 'ORDER BY pt.position, pt.added_at ASC' PlaylistRepository.swift` | 1 |
| `grep -c 'playlistDidChange' PlaylistDetailViewModel.swift` | 5 |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] PlaylistRepository typed against `DatabasePool` blocked in-memory tests**

- **Found during:** Task 2 RED phase — creating `PlaylistRepository(database: db)` with `db: DatabaseQueue` failed compile.
- **Issue:** Existing `PlaylistRepository.init(database: DatabasePool)` could not accept the `DatabaseQueue` returned by `DatabaseManager.inMemory()`.
- **Fix:** Changed field type and init parameter from `DatabasePool` to `any DatabaseWriter`. Matches the established `TrackRepository` pattern exactly (TrackRepository:33-38). All three production callers (`DependencyContainer.swift:78`, `SpotifyClient.swift:307`, `SyncService.swift:233`) pass `DatabasePool` instances which conform to `DatabaseWriter` — zero behavior change.
- **Files modified:** `macos-app/MLM/Database/PlaylistRepository.swift`
- **Commit:** `3399d64` (bundled with the RED test commit so the RED tests had a path to compile).

### Plan Expectation Adjustments (not bugs)

**2. [D-EX-01] Single migration registration covers both migrators**

- **Plan said:** Register v20 in BOTH the production `migrator` and `inMemoryMigrator` blocks; `grep -c 'v20_playlist_cover_custom'` ≥ 2.
- **Reality:** `DatabaseManager.buildMigrator()` is a single static factory method called by both `migrator` (production) and `inMemoryMigrator`. One registration inside `buildMigrator()` covers both migrators. Grep returns 1.
- **Verification this still works:** `DatabaseTests/playlistsTableHasCoverIsCustomColumn` uses `DatabaseManager.inMemory()` and passes — confirming the inMemory migrator picks up v20. The production migrator is the same code path.
- **No code-level fix needed:** the goal is achieved with one registration; the plan's grep gate was based on a stale read of the codebase architecture.

**3. [D-EX-02] Test INSERT column list expanded**

- **Plan said:** `INSERT INTO tracks (id, artist, title, original_path, format, date_added) VALUES ...`
- **Reality:** Migration `v1_core_tracks` makes `album_artist` and `album` NOT NULL, so the planned INSERT would fail at runtime.
- **Fix:** Test INSERT in `fetchTracks_tieBreaksByAddedAtAsc` now lists `(id, artist, album_artist, album, title, format, original_path, date_added)`. Matches the actual schema. Plan called this out explicitly in its "IMPORTANT" note at action step C of Task 2 — execution followed that guidance.

## Stub Tracking / Known Stubs

None. All new code paths are wired to real consumers (production migrator) or have direct test coverage. The `setCoverPath` setter has no consumer in this plan but is consumed by Plan 02 (PlaylistCoverService) which is on the same wave queue.

## Threat Flags

None. No new network endpoints, auth paths, file-access surface, or trust-boundary schema changes beyond what the threat model already covers (T-36-01..T-36-03 — all `accept` dispositions, no `mitigate` work owed).

## TDD Gate Compliance

| Gate | Commit | Status |
| ---- | ------ | ------ |
| RED (Task 1) — failing column test | `94c92ad` `test(36-01): add failing test for playlists.cover_is_custom column` | ✓ |
| GREEN (Task 1) — migration + model | `fdc1fb4` `feat(36-01): add migration v20 cover_is_custom + Playlist.coverIsCustom` | ✓ |
| RED (Task 2) — repo cover tests + DB type relaxation | `3399d64` `test(36-01): add PlaylistRepositoryCoverTests + relax repo DB type` | ✓ |
| GREEN (Task 2) — setter + tie-breaker | `49861d8` `feat(36-01): add setCoverPath setter + deterministic fetchTracks tie-breaker` | ✓ |
| Task 3 — non-TDD per plan | `c7c21d7` `feat(36-01): post .playlistDidChange after moveTrack reorder` | n/a (tdd not requested) |

All TDD gates present in the expected order. No REFACTOR commits needed — no code was structurally rearranged after green.

## Auth Gates / Manual Steps

None. Fully autonomous execution.

## Decisions Made

- **D-EX-01:** Single registration of v20 inside `buildMigrator()` is sufficient (both migrators share the factory).
- **D-EX-02:** `PlaylistRepository.database` typed as `any DatabaseWriter` (was `DatabasePool`) to enable in-memory tests; matches `TrackRepository` precedent.
- **D-EX-03:** moveTrack notification carries `userInfo: ["playlistId": playlistId]` so Plan 02's PlaylistCoverService can regenerate exactly one playlist instead of all on every reorder.

## Plan-Level Decision Citations Coverage

- **D-01 (Hybrid auto1/auto4):** schema + Codable mapping for `coverIsCustom` shipped; Plan 02 reads this flag to skip locked rows. ✓
- **D-04 (Re-Generate-Trigger):** `moveTrack` now posts `.playlistDidChange` — the previously-missing third trigger (addTracks/removeTracks/moveTrack). ✓
- **D-05 (Sticky-Lock):** column `cover_is_custom` + `setCoverPath(id:path:isCustom:)` setter shipped. ✓
- **D-06 (Reset to Auto Cover):** `setCoverPath(id:, path: nil, isCustom: false)` enables Plan 03's Card context-menu action. ✓

## Self-Check: PASSED

Verified files exist and commits are present.

- macos-app/MLM/Database/DatabaseManager.swift — modified (fdc1fb4)
- macos-app/MLM/Models/Playlist.swift — modified (fdc1fb4)
- macos-app/MLM/Database/PlaylistRepository.swift — modified (3399d64 + 49861d8)
- macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift — modified (c7c21d7)
- macos-app/MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift — created (3399d64)
- macos-app/MLMTests/DatabaseTests/DatabaseTests.swift — modified (94c92ad)

Commits:
- 94c92ad — test (RED Task 1)
- fdc1fb4 — feat (GREEN Task 1)
- 3399d64 — test (RED Task 2 + DB-type fix)
- 49861d8 — feat (GREEN Task 2)
- c7c21d7 — feat (Task 3)
