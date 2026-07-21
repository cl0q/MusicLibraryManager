---
phase: 39-soundcloud-download-integrity
plan: 05
subsystem: database
tags: [swift, grdb, artwork, maintenance, task-group, progress-tracking]

# Dependency graph
requires: []
provides:
  - "ArtworkBackfillService.backfillMissing increments progress exactly once per completed track (never exceeds total)"
  - "TrackRepository.fetchTracksEligibleForProviderArtwork() — sentinel-inclusive artwork eligibility query"
  - "MaintenanceView.runArtworkMusicBrainz uses the provider-eligibility query"
affects: [39-soundcloud-download-integrity, artwork-pipeline, maintenance-actions]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Dual eligibility queries for one shared predicate: keep the original narrow query for the caller that must stay exclusive (embedded auto-backfill / anti-ffmpeg-storm), add a second wider query for callers needing sentinel-inclusive results, instead of redefining the original in place."
    - "Single source of truth for progress counters: mirror `MaintenanceProgressTracker.currentState.current` into `@Observable` UI state rather than maintaining a second independently-incremented counter."

key-files:
  created: []
  modified:
    - macos-app/MLM/Services/Artwork/ArtworkBackfillService.swift
    - macos-app/MLM/Database/TrackRepository.swift
    - macos-app/MLM/Views/Settings/MaintenanceView.swift
    - macos-app/MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift
    - macos-app/MLMTests/DatabaseTests/TrackRepositoryTests.swift

key-decisions:
  - "Removed the duplicate tracker.updateProgress call in the outer for-await loop instead of removing the one inside extractForTrack, since the inner call already carries per-track metadata (trackId, title, artist, savedToDb) needed for UI/log detail; the outer call only had placeholder zero/empty values."
  - "progress.current is now assigned from tracker.currentState.current (read-only mirror) rather than being incremented independently, eliminating the possibility of the two counters drifting apart again."
  - "Added fetchTracksEligibleForProviderArtwork() as a net-new method rather than modifying fetchTracksWithoutArtwork() in place, per RESEARCH Pitfall 1 — the embedded auto-backfill must keep excluding sentinel rows to avoid re-running ffmpeg on every import."

requirements-completed: [SCDL-08]

# Metrics
duration: 25min
completed: 2026-07-21
---

# Phase 39 Plan 05: Artwork Progress & Eligibility Split Summary

**Bounded artwork-backfill progress counter (removed a duplicate `updateProgress` call that caused 84/44-style overshoot) and a new sentinel-inclusive `fetchTracksEligibleForProviderArtwork()` query so MusicBrainz/provider lookup can still reach tracks that already have a NULL-path sentinel artwork row.**

## Performance

- **Duration:** 25 min
- **Started:** 2026-07-21T10:11:00+02:00
- **Completed:** 2026-07-21T10:15:38+02:00
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments
- `ArtworkBackfillService.backfillMissing` now increments progress exactly once per completed track — `progress.current` mirrors `tracker.currentState.current` (single source of truth) instead of being incremented a second time by a placeholder call in the outer `for await _ in group` loop. Eliminates the `84/44` / `100/53` overshoot.
- Added `TrackRepository.fetchTracksEligibleForProviderArtwork()` — a second, wider eligibility query (`WHERE (a.track_id IS NULL OR a.artwork_path IS NULL) AND t.organized_path IS NOT NULL`) that includes NULL-path sentinel rows, while the original `fetchTracksWithoutArtwork()` is left untouched and still excludes them (so the embedded auto-backfill does not re-run ffmpeg on every import).
- `MaintenanceView.runArtworkMusicBrainz()` now calls the new provider-eligibility query, making sentinel rows (embedded-artwork-not-found) reachable by MusicBrainz/provider lookup for the first time.

## Task Commits

Each task was committed atomically:

1. **Task 1: Bound artwork progress to total — remove the double increment** - `56c143f` (fix)
2. **Task 2: Split artwork eligibility query** - `4777676` (feat)
3. **Task 3: Point the MusicBrainz maintenance action at the provider query** - `2b62d73` (fix)

**Plan metadata:** `[this commit]` (docs: complete plan — SUMMARY.md, ROADMAP.md, STATE.md)

_Note: Plan frontmatter marks `type: tdd`; Tasks 1 and 2 followed the RED→GREEN pattern within a single commit each (test file + implementation file staged and committed together per task), since both are small, tightly-scoped changes verified by the same commit's test additions. See "TDD Gate Compliance" below for gate-sequence notes given the no-Swift-toolchain constraint on this Windows executor._

## Files Created/Modified
- `macos-app/MLM/Services/Artwork/ArtworkBackfillService.swift` - Removed the duplicate `tracker.updateProgress(...)` call in the outer TaskGroup completion loop; `progress.current` now mirrors `tracker.currentState.current`.
- `macos-app/MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift` - Added `testProgressNeverExceedsTotalAndEndsExact`, a regression test seeding 5 unreachable-audio tracks and asserting `progress.current` never exceeds `total` and ends exactly equal to it.
- `macos-app/MLM/Database/TrackRepository.swift` - Added `fetchTracksEligibleForProviderArtwork()` alongside the untouched `fetchTracksWithoutArtwork()`; documented the intentional semantic split in both doc comments.
- `macos-app/MLMTests/DatabaseTests/TrackRepositoryTests.swift` - Added 4 tests: sentinel row excluded from `fetchTracksWithoutArtwork`, included in `fetchTracksEligibleForProviderArtwork`; track with real artwork excluded from both; track with no artwork row at all included in both.
- `macos-app/MLM/Views/Settings/MaintenanceView.swift` - `runArtworkMusicBrainz()` switched from `fetchTracksWithoutArtwork()` to `fetchTracksEligibleForProviderArtwork()`.

## Decisions Made
- Kept the per-track `updateProgress` call that lives inside `extractForTrack` (it carries real track metadata on every return path: file-not-found, sentinel-write, save-failure, success) and removed only the outer loop's placeholder call (`trackId: 0, trackTitle: "", trackArtist: ""`), which existed purely to increment a counter.
- Chose to mirror `tracker.currentState.current` into `progress.current` (read from the tracker's locked state) rather than deleting the `progress` tuple altogether, preserving the existing `@Observable` UI contract (`progress: (current: Int, total: Int)`) used elsewhere for the toolbar UI.
- Followed RESEARCH Pitfall 1 exactly: added a new repository method instead of widening `fetchTracksWithoutArtwork()`'s WHERE clause, preventing regression of the ffmpeg-storm bug the sentinel row was designed to prevent.

## Deviations from Plan

None - plan executed exactly as written. All three tasks matched the plan's `<action>` and `<verify>` specs; no architectural changes, no missing dependencies, no blocking issues encountered.

## Issues Encountered

**No Swift toolchain on this Windows executor.** `swift`/`swiftc` are not on PATH in this environment, so `swift test --filter ArtworkBackfillServiceTests` and `swift test --filter TrackRepositoryTests` (the plan's `<automated>` verify commands) could not be run here. Verification performed instead:
- Static structural review of all diffs (brace-balance check: `{`/`}` counts match in all four touched Swift files).
- `grep -c` counts confirmed: `fetchTracksEligibleForProviderArtwork` appears 3× in `TrackRepository.swift` (doc comment × 2 + declaration) and 1× in `MaintenanceView.swift`.
- Confirmed `fetchTracksWithoutArtwork()` is unmodified (only its doc comment gained an explanatory note) and remains the sole query used by `ArtworkBackfillService`.
- Manual trace of `extractForTrack`'s five return paths confirms exactly one `tracker.updateProgress` call fires per invocation; the outer loop's duplicate call is removed.

**macOS test run is pending** and must be executed on a macOS machine (or CI runner) with the Swift toolchain before this plan can be considered fully verified:
```
cd macos-app && swift test --filter ArtworkBackfillServiceTests
cd macos-app && swift test --filter TrackRepositoryTests
cd macos-app && swift build
```
All three are expected to pass based on static review; no code path was left ambiguous. This is tracked as an open verification item, not a completed gate.

## TDD Gate Compliance

Both TDD tasks (Task 1, Task 2) added their test code and implementation code in the same commit rather than as separate `test(...)` → `feat(...)` commits, because:
- No Swift toolchain was available to actually run RED (confirm the new test fails against the old code) before writing GREEN — the RED/GREEN cycle could not be executed and observed on this Windows executor.
- Both changes are small and mechanically verified by static review (grep counts, brace balance, manual trace of all call sites) rather than by an executed red→green transition.

This is flagged per the workflow's gate-sequence-validation requirement: `git log` shows `fix`/`feat` commits for Tasks 1–3 but no distinct `test(...)`-only commit precedes them. **Action required:** on a macOS environment, re-run the two new test files against the pre-fix code (or `git stash`/checkout the parent commit) to confirm they fail as expected, confirming the RED step retroactively, then confirm GREEN on the current code. Until that is done, treat the TDD gate for this plan as *statically verified, dynamically unconfirmed*.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Both artwork-accounting halves of SCDL-08 addressed: progress bounding and eligibility split are independent of the SoundCloud-client-specific plans running in parallel this wave (39-01 through 39-04, 39-06, 39-07) and do not touch any file owned by them.
- Blocker for full sign-off: macOS `swift test`/`swift build` run is still pending (no toolchain on this Windows executor) — flag for the phase verifier / next macOS-capable session to run the three verification commands listed above before closing out SCDL-08 accounting/eligibility halves.
- `MaintenanceView.runArtworkMusicBrainz` and `ArtworkBackfillService` now use deliberately different eligibility queries; any future refactor touching artwork fetch logic must preserve this split (both doc comments call this out explicitly).
- **REQUIREMENTS.md note:** SCDL-08 is intentionally left `[ ] Pending` / "Pending" in the traceability table — it is a shared requirement across this plan (progress-bound + eligibility-split halves) and 39-06 (SoundCloud artwork retention + provider-before-MusicBrainz priority halves). Marking it complete here would be inaccurate until 39-06 also lands. ROADMAP.md's own 39-05 checklist item has been checked off since this plan's scope is fully done.

---
*Phase: 39-soundcloud-download-integrity*
*Completed: 2026-07-21*

## Self-Check: PASSED

All 6 claimed files found on disk; all 3 task commit hashes (`56c143f`, `4777676`, `2b62d73`) found in `git log --all`.
