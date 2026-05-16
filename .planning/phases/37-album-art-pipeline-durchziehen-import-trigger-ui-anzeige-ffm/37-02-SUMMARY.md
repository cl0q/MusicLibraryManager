---
phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
plan: "02"
subsystem: services
tags: [swift, swiftui, artwork, ffmpeg, grdb, notification-center, task-group, macos]

# Dependency graph
requires:
  - phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
    plan: "01"
    provides: "ArtworkService.extractEmbeddedArtwork (static async) + ArtworkService.saveResized (internal) + .trackArtworkDidChange notification"
provides:
  - "@MainActor @Observable ArtworkBackfillService with inFlight coalescing and TaskGroup(maxConcurrentTasks: 4)"
  - "DependencyContainer.artworkBackfillService property + initialization"
  - "ArtworkBackfillServiceTests (5 passing unit tests)"
  - "AnalysisRepository widened to accept any DatabaseWriter (enables in-memory tests)"
affects:
  - "37-03 (TrackCoverView uses refreshSingleTrack for self-healing)"
  - "37-04 (MaintenanceView calls refreshMissing)"
  - "37-05 (ArtworkExtractor thin-wrapper already updated in 37-01)"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "@MainActor @Observable service with NotificationCenter observer and inFlight Set<Int64> coalescing (Phase-36 PlaylistCoverService twin)"
    - "TaskGroup with manual concurrent-task cap (seed N tasks, pump one per completion)"
    - "TDD red→green cycle for async Swift service tests"

key-files:
  created:
    - macos-app/MLM/Services/Artwork/ArtworkBackfillService.swift
    - macos-app/MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift
  modified:
    - macos-app/MLM/App/DependencyContainer.swift
    - macos-app/MLM/Database/AnalysisRepository.swift

key-decisions:
  - "Used TrackRepository.fetchTracksWithoutArtwork() (Path A) instead of inline SQL — method already exists in repo"
  - "Used TrackRepository.fetchTrack(id:) for refreshSingleTrack (Path A — method confirmed to exist)"
  - "AnalysisRepository widened from DatabasePool to any DatabaseWriter to enable in-memory test DatabaseQueue"
  - "artworkService instance held by BackfillService (not singleton) to share same cache dir as MaintenanceView.runArtwork"

patterns-established:
  - "ArtworkBackfillService.init(database:trackRepository:analysisRepository:) — mirror of PlaylistCoverService.init"
  - "DependencyContainer.artworkBackfillService — initialized after playlistCoverService block via await MainActor.run { }"

requirements-completed: []

# Metrics
duration: 3min
completed: 2026-05-16
---

# Phase 37 Plan 02: ArtworkBackfillService + DependencyContainer Wiring Summary

**@MainActor @Observable ArtworkBackfillService wired into DependencyContainer — observes .libraryDidImport and runs TaskGroup(maxConcurrentTasks: 4) ffmpeg backfill with per-track .trackArtworkDidChange notifications**

## Performance

- **Duration:** 3 min
- **Started:** 2026-05-16T14:21:34Z
- **Completed:** 2026-05-16T14:24:54Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- `ArtworkBackfillService` created as direct Phase-36 `PlaylistCoverService` twin: `@MainActor @Observable`, notification observer, `inFlight: Set<Int64>` coalescing, `deinit` token cleanup
- `DependencyContainer.artworkBackfillService` initialized after `playlistCoverService` block using `await MainActor.run { }` pattern
- 5 unit tests written and passing: `testObservesLibraryDidImport`, `testConcurrencyLimit`, `testCoalescesDuplicateRequests`, `testNotificationPosting`, `testFfmpegMissingDebugLog`
- `AnalysisRepository` widened to `any DatabaseWriter` enabling in-memory `DatabaseQueue` in tests (Rule 2 deviation)

## Task Commits

Each task was committed atomically:

1. **Task 1: Wave-0 test scaffold (TDD RED)** - `46fcd55` (test)
2. **Task 2: ArtworkBackfillService + DependencyContainer wiring (TDD GREEN)** - `9625df6` (feat)

**Plan metadata:** (docs commit — see below)

_Note: TDD plan — test commit followed by feat commit_

## Files Created/Modified

- `macos-app/MLM/Services/Artwork/ArtworkBackfillService.swift` — New: @MainActor @Observable background orchestrator; observes .libraryDidImport; backfillMissing() runs TaskGroup(maxConcurrentTasks: 4); refreshMissing() + refreshSingleTrack() public; extractForTrack() calls ArtworkService.extractEmbeddedArtwork → saveResized → AnalysisRepository.saveArtwork → posts .trackArtworkDidChange
- `macos-app/MLM/App/DependencyContainer.swift` — Modified: added artworkBackfillService property + init block after playlistCoverService
- `macos-app/MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift` — New: 5 unit tests (TDD RED→GREEN)
- `macos-app/MLM/Database/AnalysisRepository.swift` — Modified: init widened from DatabasePool to any DatabaseWriter

## Decisions Made

- **Path A for refreshSingleTrack**: `TrackRepository.fetchTrack(id:)` confirmed to exist at line 63; used directly
- **fetchTracksWithoutArtwork() reuse**: existing method in TrackRepository (line 460) fetches tracks missing artwork rows — no inline SQL needed
- **artworkService instance in init**: ArtworkService is `final` with `init(cacheDir:)`; BackfillService holds its own instance initialized to the same cache dir as MaintenanceView
- **AnalysisRepository widened**: `init(database: any DatabaseWriter)` replaces `init(database: DatabasePool)` — both production (DatabasePool) and tests (DatabaseQueue) work; all usages confirmed to use read/write protocol methods only

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] AnalysisRepository.init widened to accept any DatabaseWriter**
- **Found during:** Task 2 (ArtworkBackfillService implementation)
- **Issue:** `AnalysisRepository.init(database: DatabasePool)` takes `DatabasePool` specifically. `DatabaseManager.inMemory()` returns `DatabaseQueue`. Test `makeService()` would fail to compile; also prevents `ArtworkBackfillService.init` from accepting `any DatabaseWriter` as intended.
- **Fix:** Changed `private let database: DatabasePool` and `init(database: DatabasePool)` to `any DatabaseWriter`. AnalysisRepository only uses `.read` and `.write` protocol methods, so `DatabasePool` and `DatabaseQueue` both work identically.
- **Files modified:** `macos-app/MLM/Database/AnalysisRepository.swift`
- **Verification:** `swift build` passes; all 5 tests pass; existing tests unaffected
- **Committed in:** `9625df6` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Essential correctness fix — enables testability and proper protocol abstraction. No scope creep.

## Issues Encountered

None — the libraryDidImport count in the plan's verification grep (`→ 1`) refers to the meaningful occurrence in `startObserving()`; actual grep count is 4 including doc comments. The code is correct.

## Known Stubs

None — `ArtworkBackfillService` is fully wired. No hardcoded empty values or placeholders in critical paths. `isBackfilling`, `progress`, `inFlight` are real state. `extractForTrack` calls real ArtworkService and AnalysisRepository APIs.

## Threat Surface Scan

No new network endpoints, auth paths, or trust boundary changes introduced. `ArtworkBackfillService.extractForTrack` calls `ArtworkService.extractEmbeddedArtwork(from: trackURL)` where `trackURL` is constructed from DB-stored `organized_path`. T-37-02 (ffmpeg argument injection) is mitigated — URL.path passed as Process.arguments array element, no shell interpretation. T-37-05 (TaskGroup resource exhaustion) mitigated by `maxConcurrentTasks: 4`.

## Next Phase Readiness

- `ArtworkBackfillService` is fully implemented and wired — ready for Plan 03 (`TrackCoverView`) to call `refreshSingleTrack(trackId:)` and Plan 04 (`MaintenanceView` split) to call `refreshMissing()`
- No blockers

---
*Phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm*
*Completed: 2026-05-16*
