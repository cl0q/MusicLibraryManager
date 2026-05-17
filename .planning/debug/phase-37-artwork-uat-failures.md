---
status: resolved
trigger: Phase-37 UAT failures — artwork extraction not running, cover sizes wrong in 3 surfaces, manual refresh trigger ineffective
created: 2026-05-17
updated: 2026-05-17
---

# Phase 37 — Artwork UAT Failures

## Symptoms

### Expected behavior
After Phase 37 ships, the app should:
- Import a library → Embedded artwork extracted automatically via ffmpeg into `~/Library/Caches/com.mlm.artwork_cache/{trackId}_500.jpg` + `{trackId}_1200.jpg`
- LibraryTable Title column shows 18pt inline track cover; if no artwork yet, Solar-gradient + music.note fallback
- TrackDetailView header shows 56pt cover (real artwork when present)
- PlayerBar shows 40pt cover (real artwork when present)
- Phase 36 Playlist mosaic auto-cover continues working — ArtworkExtractor now routes through ffmpeg static API
- Settings → Maintenance → "Refresh embedded artwork" button triggers `ArtworkBackfillService.refreshMissing()` and the covers pop into the UI within seconds

### Actual behavior (user report)
1. **Artwork extraction not happening anywhere** — every cover surface shows the Solar-gradient + music.note FALLBACK, not real embedded artwork. This applies to LibraryTable, TrackDetailView, AND Playlists (Phase 36 mosaic regression).
2. **Cover sizes/layout wrong in 3 of 4 surfaces:**
   - LibraryTable Title column — "passt von der Größe nicht in der Liste" (size doesn't fit in the list — probably row-height / frame mismatch)
   - TrackDetailView "more info" — "schief" (crooked / off-aspect — likely aspect-ratio or frame mismatch)
   - Playlists (Phase 36 mosaic) — "passt auch nicht" (doesn't fit either)
   - **PlayerBar 40pt thumbnail — OK** ✓ (the one surface where 40pt frame + cornerRadius 5 lands correctly)
3. **Manual refresh trigger ineffective** — user reports doing a "Rescan in Settings" and no covers materialize.

## Evidence

- timestamp: 2026-05-17T18:00Z
  finding: ffmpeg IS at /opt/homebrew/bin/ffmpeg (symlink → brew cellar 8.1.1). NOT at ~/.local/bin or /usr/local/bin. ProcessRunner.findExecutable searches /opt/homebrew/bin — so ffmpeg IS found.
  implication: H4 eliminated. ffmpeg is available and findExecutable returns it.

- timestamp: 2026-05-17T18:00Z
  finding: Cache dir (~Library/Caches/com.mlm.artwork_cache/) EXISTS but is COMPLETELY EMPTY.
  implication: ArtworkService.init ran (created the dir), but extraction work never produced output. Root cause is in extractForTrack.

- timestamp: 2026-05-17T18:00Z
  finding: DB has 11491 tracks, 341 artwork rows, 10960 organized (library) tracks. fetchTracksWithoutArtwork query SQL is correct (LEFT JOIN + WHERE a.track_id IS NULL). ~10619 tracks eligible.
  implication: H3 eliminated. The query is correct; it returns thousands of rows. The problem is upstream — extractForTrack silently fails.

- timestamp: 2026-05-17T18:00Z
  finding: organizedPath is stored as a RELATIVE path (e.g., "Artist/Album/track.flac"). ArtworkBackfillService.extractForTrack used `URL(fileURLWithPath: organizedPath)` directly — no libraryRoot prefix.
  implication: H1/H4 root cause found. ffmpeg was called with a path that doesn't exist on disk → exits non-zero → extractEmbeddedArtwork returns nil → extractForTrack returns early → cache stays empty.

- timestamp: 2026-05-17T18:00Z
  finding: TrackCoverView had a hardcoded internal .frame(width: sizePoints, height: sizePoints) where sizePoints = 40 for .small and 128 for .large. Callers then applied their own .frame() (18×18 for LibraryTable, 56×56 for TrackDetailView). Two competing frames cause SwiftUI clipping to misbehave.
  implication: Bug 2 (layout). PlayerBar passed size: .small with frame: 40×40 — matched exactly, so PlayerBar looked fine. All other callers had mismatched frames.

## Eliminated Hypotheses

- H3: fetchTracksWithoutArtwork SQL is correct. Returns ~10619 rows as expected. Not the cause.
- H4: ffmpeg found at /opt/homebrew/bin/ffmpeg. ProcessRunner.findExecutable works. Not the cause.
- H1 (DI wiring): ArtworkBackfillService IS initialized in DependencyContainer.initialize() via await MainActor.run { ... }. Not the cause.

## Root Causes

### Bug 1 (PRIMARY — universal fallback): Relative `organizedPath` passed to ffmpeg without libraryRoot prefix

`organizedPath` is a relative path. `ArtworkBackfillService.extractForTrack` used it directly:
```swift
let trackURL = URL(fileURLWithPath: organizedPath)  // wrong — relative
```
ffmpeg sees a path like `Artist/Album/track.flac` resolved from the app's cwd — doesn't exist — exits non-zero — extraction returns nil — cache never populated. Same bug affected the D-14 self-healing path (`refreshSingleTrack` → `extractForTrack`).

PlaylistCoverService correctly resolved paths via `configRepository.getLibraryRoot()`. ArtworkBackfillService was missing `configRepository` entirely from its init.

### Bug 2 (layout — LibraryTable, TrackDetailView, Playlists): Competing `.frame()` modifiers

`TrackCoverView` applied `.frame(width: sizePoints, height: sizePoints)` internally where `sizePoints` was hardcoded (40 for `.small`, 128 for `.large`). Callers then added their own `.frame()`. SwiftUI applies the outer frame as a constraint, but the inner frame had already laid out the image at the wrong size — causing crop artifacts ("schief") and overflow ("passt nicht in der Liste"). PlayerBar worked by accident (`.small` → 40pt internal = 40pt caller frame, no mismatch).

## Resolution

### Fix 1: Add `configRepository` to `ArtworkBackfillService` and resolve absolute path

Files changed:
- `MLM/Services/Artwork/ArtworkBackfillService.swift` — added `configRepository: ConfigRepository` to init; `extractForTrack` now fetches library root and joins with `organizedPath`; adds file-existence guard before calling ffmpeg.
- `MLM/App/DependencyContainer.swift` — updated `ArtworkBackfillService` init call to pass `configRepository`.
- `MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift` — updated `makeService()` to pass `configRepository`.

### Fix 2: Remove internal `.frame()` from `TrackCoverView`

File changed:
- `MLM/Views/Shared/TrackCoverView.swift` — removed `.frame(width: sizePoints, height: sizePoints)` from body. The `sizePoints` switch is kept only for proportional fallback icon sizing (music.note). Callers own all sizing. `clipShape(RoundedRectangle)` still applied by the component.

### Verification

- `swift build` — Build complete, 0 errors, 1 pre-existing warning.
- `swift test` — 142/142 tests pass.

### Expected UAT result after fix

1. Artwork extraction: after next import (or manual "Refresh embedded artwork" in Maintenance), cache should populate with `{trackId}_500.jpg` and `{trackId}_1200.jpg` files.
2. Covers should appear incrementally in LibraryTable, TrackDetailView, PlayerBar as extraction completes.
3. Layout: LibraryTable 18pt, TrackDetailView 56pt, PlayerBar 40pt — all rendered at correct caller-specified sizes.
4. The 341 existing DB rows with missing cache files will trigger self-healing on next display.
