---
phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
plan: 03
subsystem: ui
tags: [swiftui, nscache, artwork, solar-palette, nscache, notification-center, grdb]

# Dependency graph
requires:
  - phase: 37-02
    provides: ArtworkBackfillService with refreshSingleTrack, DependencyContainer.artworkBackfillService, .trackArtworkDidChange notification
  - phase: 37-01
    provides: ArtworkService.ArtworkSize enum, ArtworkService static extractEmbeddedArtwork, AnalysisRepository.fetchArtwork

provides:
  - "TrackArtworkCache: NSCache<NSNumber, NSImage> singleton, countLimit=200, scoped by trackId+size"
  - "TrackCoverView: reusable SwiftUI view with Solar gradient fallback, async disk load, self-healing (D-14)"
  - "LibraryTable Title column: 18pt inline cover thumbnail (Surface 1)"
  - "TrackDetailView header: 56pt TrackCoverView(size:.large) replacing music.note placeholder (Surface 2)"
  - "PlayerBar coverThumbnail: 40pt TrackCoverView(size:.small) replacing hardcoded placeholder (Surface 3)"
  - "TrackArtworkCacheTests (5 tests) + TrackCoverViewTests (6 tests)"

affects:
  - "37-04 (MaintenanceView wiring, same container)"
  - "Phase 38+ (any UI surface that needs per-track artwork)"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "NSCache singleton scoped by composite key (trackId * 10000 + size.rawValue) for O(1) lookup"
    - ".task(id: trackId) for lifecycle-safe async load that cancels on trackId change"
    - "Double-optional flatten pattern for container.analysisRepository?.fetchArtwork → Artwork??"
    - "ZStack overlay badge for now-playing state over artwork image"

key-files:
  created:
    - macos-app/MLM/Services/Common/TrackArtworkCache.swift
    - macos-app/MLM/Views/Shared/TrackCoverView.swift
    - macos-app/MLMTests/ServiceTests/TrackArtworkCacheTests.swift
    - macos-app/MLMTests/ViewTests/TrackCoverViewTests.swift
  modified:
    - macos-app/MLM/Views/Library/LibraryTable.swift
    - macos-app/MLM/Views/TrackDetail/TrackDetailView.swift
    - macos-app/MLM/Views/Player/PlayerBar.swift

key-decisions:
  - "D-09 honored: countLimit=200 caps memory at ~30MB for typical viewport; key = trackId*10000+size.rawValue prevents small/large collisions"
  - "D-11 honored: Solar gradient (mlmBase→mlmRaised topLeading→bottomTrailing) + music.note in mlmInkMuted as fallback"
  - "D-14 honored: fileExists check triggers refreshSingleTrack when DB row exists but file missing"
  - "D-17 honored: artworkPath/source not exposed in UI — TrackCoverView shows cover or fallback only"
  - "Now-playing state in TrackDetailView preserved as subtle waveform badge overlay over cover (not lost in swap)"
  - "TrackCoverView uses .task(id:) instead of .onAppear to cancel prior loads on trackId change"

requirements-completed: []

# Metrics
duration: 5min
completed: 2026-05-16
---

# Phase 37 Plan 03: TrackArtworkCache + TrackCoverView + 3 UI Surfaces Summary

**NSCache image cache singleton + SwiftUI TrackCoverView with Solar gradient fallback integrated into all three artwork surfaces (LibraryTable 18pt, TrackDetailView 56pt, PlayerBar 40pt)**

## Performance

- **Duration:** 5 min
- **Started:** 2026-05-16T15:01:32Z
- **Completed:** 2026-05-16T15:06:39Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments
- TrackArtworkCache: NSCache singleton with countLimit=200, composite key, invalidate-all-sizes API
- TrackCoverView: async image load (cache → DB → fileExists → NSImage), Solar fallback (D-11), self-healing (D-14), .trackArtworkDidChange observance (D-10)
- Three UI surfaces wired: LibraryTable (18pt, cornerRadius:4, spacing:8), TrackDetailView (56pt, cornerRadius:6, waveform overlay for now-playing), PlayerBar (40pt, cornerRadius:5)
- 11 tests passing: 5 TrackArtworkCacheTests + 6 TrackCoverViewTests

## Task Commits

1. **Task 1: TrackArtworkCache + test scaffold** - `a094833` (feat)
2. **Task 2: TrackCoverView + view test scaffold** - `6e916bb` (feat)
3. **Task 3: Surface integrations (LibraryTable, TrackDetailView, PlayerBar)** - `bdc36e3` (docs, included in prior run's commit)

## Files Created/Modified
- `macos-app/MLM/Services/Common/TrackArtworkCache.swift` - NSCache<NSNumber, NSImage> wrapper singleton, countLimit=200
- `macos-app/MLM/Views/Shared/TrackCoverView.swift` - SwiftUI view: cache → DB → disk load; Solar fallback; self-healing
- `macos-app/MLMTests/ServiceTests/TrackArtworkCacheTests.swift` - 5 tests (testCacheHit, testEvictionUnderLimit, testInvalidateTrack + 2 stretch)
- `macos-app/MLMTests/ViewTests/TrackCoverViewTests.swift` - 6 tests (fallback, notification, file-miss, cache-hit, size-points)
- `macos-app/MLM/Views/Library/LibraryTable.swift` - Title column: TrackCoverView 18pt inline-left, HStack spacing:8, cornerRadius:4
- `macos-app/MLM/Views/TrackDetail/TrackDetailView.swift` - Header: 56pt TrackCoverView(size:.large) + waveform badge overlay
- `macos-app/MLM/Views/Player/PlayerBar.swift` - coverThumbnail: 40pt TrackCoverView(size:.small) replaces music.note placeholder

## Decisions Made
- TrackCoverView uses `.task(id: trackId)` lifecycle modifier to automatically cancel stale loads when the displayed track changes — more correct than `.onAppear` which doesn't react to prop changes
- The `artworkPath: String?` optional in the actual Artwork model (vs the plan's assumed `String`) required flatten pattern `(try? await repo?.fetch())??.artworkPath` — auto-fixed as Rule 1
- Now-playing waveform animation in TrackDetailView preserved as a small badge overlay on the cover (not removed), keeping visual state continuity per plan's "planner discretion" note

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] artworkPath is String? not String in Artwork model**
- **Found during:** Task 2 (TrackCoverView implementation)
- **Issue:** Plan interface showed `artworkPath: String` but actual `AppModels.swift` defines `var artworkPath: String?` — compile error on `!artworkRecord.artworkPath.isEmpty`
- **Fix:** Used optional flatten chain: `(try? await container.analysisRepository?.fetchArtwork(trackId:))??.artworkPath` then `guard let artworkPath`
- **Files modified:** `macos-app/MLM/Views/Shared/TrackCoverView.swift`
- **Verification:** `swift build` → Build complete
- **Committed in:** `6e916bb` (Task 2 feat commit)

---

**Total deviations:** 1 auto-fixed (1 Rule 1 bug — type mismatch between plan interface and actual model)
**Impact on plan:** Minor — nil-safety improvement only. No scope change, no behavioral difference.

## Issues Encountered
None — all compile errors were auto-fixed inline.

## Known Stubs
None — TrackCoverView loads real data from AnalysisRepository. Fallback gradient renders when no artwork exists (intended behavior, not a stub).

## Threat Flags
None — no new network endpoints or auth paths. artworkPath is read from DB and accessed only via FileManager/NSImage (no shell execution). T-37-01 and T-37-04 mitigations verified present (NSImage(contentsOfFile:) path, countLimit=200).

## Self-Check

### Files exist:
- `/Users/olli/schenanigans/MusicLibraryManager/macos-app/MLM/Services/Common/TrackArtworkCache.swift` — FOUND
- `/Users/olli/schenanigans/MusicLibraryManager/macos-app/MLM/Views/Shared/TrackCoverView.swift` — FOUND
- `/Users/olli/schenanigans/MusicLibraryManager/macos-app/MLMTests/ServiceTests/TrackArtworkCacheTests.swift` — FOUND
- `/Users/olli/schenanigans/MusicLibraryManager/macos-app/MLMTests/ViewTests/TrackCoverViewTests.swift` — FOUND

### Tests: `swift test --filter "TrackArtworkCacheTests|TrackCoverViewTests"` → 11 tests in 2 suites passed
### Build: `swift build` → Build complete

## Self-Check: PASSED

## Next Phase Readiness
- TrackCoverView and TrackArtworkCache complete — any Phase 38+ surface can reuse TrackCoverView
- Phase 37-04 (MaintenanceView button split) is the final plan in this phase; DependencyContainer already has artworkBackfillService wired

---
*Phase: 37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm*
*Completed: 2026-05-16*
