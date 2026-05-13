---
phase: 36-playlists-v2-0-macos-native
plan: 02
subsystem: services + DI (playlist cover image pipeline)
tags: [playlist, cover-art, mosaic, gradient, AVURLAsset, NSBitmapImageRep, MainActor, GRDB]
dependency_graph:
  requires:
    - Plan 36-01 (cover_is_custom column + setCoverPath setter + moveTrack notification)
    - PlaylistRepository (already widened to `any DatabaseWriter` in Plan 01)
    - TrackRepository (already widened to `any DatabaseWriter`)
    - ConfigRepository (widened to `any DatabaseWriter` in this plan)
  provides:
    - ArtworkExtractor.extract(audioURL:) → Data?  (silent-nil contract)
    - GradientPalette.colors(forPlaylistId:) + .initials(for:)
    - MosaicCompositor.composeMosaicPNG / composeSingleCoverPNG / composeFallbackPNG
    - PlaylistCoverService — orchestrates auto1/auto4/fallback branch + sticky-lock + re-entry guard
    - DependencyContainer.playlistCoverService slot + conditional init
  affects:
    - Plan 03 (UI — PlaylistCard reads cover_image_path; Context-Menu calls setCustomCover/resetToAuto)
    - Plan 04 (verifier — full E2E gate via the new orchestrator)
tech_stack:
  added: []
  patterns:
    - "AVURLAsset(url:) for artwork extraction (non-deprecated AVAsset successor)"
    - "NSBitmapImageRep + NSGraphicsContext for off-screen PNG composition"
    - "NSColor system tokens + .blended(withFraction:of:) for adaptive gradient palette"
    - "any DatabaseWriter — third repository widening (Track, Playlist, Config) for in-memory test reach"
    - "@MainActor @Observable service held by DependencyContainer; nonisolated deinit via MainActor.assumeIsolated"
    - "NotificationCenter re-entry guard via userInfo[origin] tag + inFlight Set<Int64>"
    - "Swift Testing .serialized suite trait for tests sharing a filesystem path"
key_files:
  created:
    - macos-app/MLM/Services/Playlists/ArtworkExtractor.swift
    - macos-app/MLM/Services/Playlists/GradientPalette.swift
    - macos-app/MLM/Services/Playlists/MosaicCompositor.swift
    - macos-app/MLM/Services/Playlists/PlaylistCoverService.swift
    - macos-app/MLMTests/ServiceTests/PlaylistCoverUtilitiesTests.swift
    - macos-app/MLMTests/ServiceTests/PlaylistCoverServiceTests.swift
    - macos-app/MLMTests/Fixtures/playlist-cover-fixtures/README.md
  modified:
    - macos-app/MLM/App/DependencyContainer.swift
    - macos-app/MLM/Database/ConfigRepository.swift
decisions:
  - "ConfigRepository widened from DatabasePool to `any DatabaseWriter` (third repo to take this widening). Required so PlaylistCoverServiceTests can construct ConfigRepository against in-memory DatabaseQueue. Sole production caller passes DatabasePool which conforms — zero behavior change."
  - "PlaylistCoverService is @MainActor @Observable; deinit is nonisolated and reads observerToken via MainActor.assumeIsolated. The token is a stable opaque value once assigned in init, so the assumption is safe. Alternative (drop class-level @MainActor) would propagate isolation churn through every caller and contradict the plan spec."
  - "DependencyContainer wraps PlaylistCoverService construction in `await MainActor.run { ... }`. initialize() is async-not-isolated; the run-block hops onto the main actor for the construction. Mirrors the libraryRootObserver-callback dispatch pattern used 30 lines below."
  - "PlaylistCoverServiceTests carries the .serialized trait. The covers directory is a hardcoded `~/Library/Application Support/com.musiclibrary.app/playlist-covers/<id>.png` path; in-memory DBs each start ids at 1, so parallel tests race on the same filesystem file. Serializing the suite removes the race without faking the application-support path. Per-test defer-cleanup still applies."
  - "PlaylistCoverUtilitiesTests added (12 tests, NOT in the original plan) as the RED gate for Task 1's three pure utility files. Plan called for Task 1 to be `tdd=true` but didn't pre-list a test file path; this file covers the deterministic palette + initials + PNG-output contract."
metrics:
  duration_seconds: 388
  duration_human: "~6.5 minutes"
  tasks_completed: 3
  files_created: 7
  files_modified: 2
  tests_added: 17
  completed_date: "2026-05-13T07:52:30Z"
---

# Phase 36 Plan 02: Cover-Image Pipeline (Services + DI + Tests) — Summary

One-liner: Four service files (ArtworkExtractor + GradientPalette + MosaicCompositor + PlaylistCoverService) compose embedded track artwork into 512×512 PNGs via three branches (auto1 / auto4 / fallback) and persist them through the Plan 01 `setCoverPath` setter; the orchestrator observes `.playlistDidChange`, honors `cover_is_custom = 1` sticky-locks, and uses a `userInfo["origin"] = "coverService"` tag plus `inFlight: Set<Int64>` to prevent regenerate loops.

## Service file map

| File | Purpose |
|------|---------|
| `MLM/Services/Playlists/ArtworkExtractor.swift` | `extract(audioURL:) async -> Data?` — `AVURLAsset.commonMetadata` + `.commonIdentifierArtwork` filter; silent-nil on every failure path |
| `MLM/Services/Playlists/GradientPalette.swift` | `colors(forPlaylistId:) -> (NSColor, NSColor)` — 4-entry palette indexed by `abs(id) % 4`; `initials(for:)` — first 2 grapheme clusters uppercased |
| `MLM/Services/Playlists/MosaicCompositor.swift` | Three entry points: `composeMosaicPNG` (D-02 gap-tile gradients) / `composeSingleCoverPNG` / `composeFallbackPNG` (D-03) — all produce 512×512 PNG via `NSBitmapImageRep` |
| `MLM/Services/Playlists/PlaylistCoverService.swift` | `@MainActor @Observable` orchestrator; `regenerateCover` / `setCustomCover` / `resetToAuto`; `.playlistDidChange` observer + re-entry guard |
| `MLM/App/DependencyContainer.swift` | `playlistCoverService` slot + conditional init wrapped in `MainActor.run` |

## Pipeline decision branches (D-01)

```
PlaylistCoverService.regenerateCover(playlistId:) →

  if coverIsCustom == 1                            → return (D-05 sticky-lock)
  load first 4 tracks (Plan 01's tie-broken order) → []NSImage?
  let nonNilCount = artworks.compactMap.count

  match nonNilCount {
    0                                              → composeFallbackPNG  (D-03 gradient + initials)
    1, or tracks.count < 4                         → composeSingleCoverPNG (D-01 auto1)
    ≥2 with tracks.count == 4                      → composeMosaicPNG    (D-01 auto4 + D-02 gradient gaps)
  }
  setCoverPath(id:, path: "playlist-covers/<id>.png", isCustom: false)
  post .playlistDidChange with userInfo[origin]="coverService", userInfo[playlistId]=id
```

Output cache path: `~/Library/Application Support/com.musiclibrary.app/playlist-covers/<id>.png`. Filename derived from `Int64` row id — no user-controlled segments (T-36-05 mitigation upheld).

## Re-entry guard mechanism (D-04)

Two layers:

1. **Origin tag.** Every notification the service emits carries `userInfo["origin"] = "coverService"`. The observer block's first line is:
   ```swift
   if (note.userInfo?["origin"] as? String) == "coverService" { return }
   ```
   So `regenerateCover` → emits .playlistDidChange → observer ignores → no recursion. Plan-01-posted notifications from `addTracks` / `removeTrack` / `moveTrack` etc. carry no origin tag and trigger normally.

2. **inFlight Set.** `Set<Int64>` of playlist ids currently being regenerated. Rapid duplicate calls (e.g. user adds three tracks in quick succession) coalesce: the second `regenerateCover(playlistId: 7)` call returns immediately while the first is in flight. Cleared via `defer { inFlight.remove(playlistId) }`.

Test 5 (`reentry_guard_skips_self_notifications`) proves layer 1 by posting a self-tagged notification and asserting the DB row stays untouched.

## Database init parameter type decision

`PlaylistCoverService.init(database: any DatabaseWriter, ...)` — same protocol type Plan 01 applied to PlaylistRepository.

- Production caller (`DependencyContainer.initialize`) passes `dbPool: DatabasePool` — flows through unchanged (DatabasePool conforms to DatabaseWriter).
- Test caller (`PlaylistCoverServiceTests.makeService`) passes `db: DatabaseQueue` returned by `DatabaseManager.inMemory()` — DatabaseQueue also conforms.
- Bonus: forced an inline widening of `ConfigRepository` (also DatabaseWriter) — every dependency of PlaylistCoverService now accepts either GRDB writer flavor. Future test additions don't need cast workarounds.

## Test count + green-suite confirmation

| Suite | Tests | Result |
|-------|-------|--------|
| PlaylistCoverUtilitiesTests | 12 | green |
| PlaylistCoverServiceTests | 5 | green |
| PlaylistRepositoryCoverTests (Plan 01) | 5 | green (no regression) |
| DatabaseTests | 14 | green (no regression) |
| TranscodeServiceTests | 3 | green |
| **Full suite** | **116** | **green** |

`cd macos-app && swift build` exits 0. `cd macos-app && swift test --filter PlaylistCoverServiceTests` exits 0.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] ConfigRepository typed against `DatabasePool` blocked in-memory tests**

- **Found during:** Task 3 RED phase. Test `makeService()` passes the in-memory `DatabaseQueue` to `ConfigRepository(database:)`, but the init required `DatabasePool`.
- **Issue:** Same root cause Plan 01 fixed for PlaylistRepository — concrete type prevents test wiring.
- **Fix:** Widened `ConfigRepository.database` from `DatabasePool` to `any DatabaseWriter`. Same precedent already shipped in `TrackRepository` (line 34) and `PlaylistRepository` (Plan 01).
- **Files modified:** `macos-app/MLM/Database/ConfigRepository.swift`
- **Commit:** `4243bd2` (bundled with the RED test commit).

**2. [Rule 1 — Bug] @MainActor deinit can't read MainActor-isolated property**

- **Found during:** Task 2 first compile after writing PlaylistCoverService.swift.
- **Issue:** Swift 5.10 strict concurrency: a `deinit` is nonisolated, but `observerToken` is MainActor-isolated → "main actor-isolated property 'observerToken' can not be referenced from a nonisolated context".
- **Fix:** `MainActor.assumeIsolated({ observerToken })`. The token is a stable opaque value once assigned in `init`, never mutated afterwards, so the assumption is safe. Alternative (drop class-level `@MainActor`) would propagate isolation churn through every caller.
- **Files modified:** `macos-app/MLM/Services/Playlists/PlaylistCoverService.swift`
- **Commit:** `1114d40`.

**3. [Rule 1 — Bug] Non-actor-isolated `initialize()` can't construct MainActor service**

- **Found during:** Same compile pass as #2.
- **Issue:** `DependencyContainer.initialize()` is `async throws` but NOT MainActor-isolated. Calling `PlaylistCoverService(...)` (MainActor-isolated init) directly failed: "main actor-isolated initializer ... cannot be called from outside of the actor".
- **Fix:** Wrap construction in `await MainActor.run { ... }`. Mirrors the pattern used 30 lines below where the `libraryRootObserver` callback dispatches work to `Task { @MainActor in }`.
- **Files modified:** `macos-app/MLM/App/DependencyContainer.swift`
- **Commit:** `1114d40`.

**4. [Rule 1 — Bug] Parallel test runs collide on shared `playlist-covers/<id>.png` filesystem path**

- **Found during:** Task 3 first GREEN test run. `fallback_with_zero_tracks_writes_PNG` failed `img?.size.width == 512` once, then passed when run in isolation.
- **Issue:** Each test makes its own in-memory DB, so playlist ids reset to 1 in every test. All five tests then race on the same filesystem path `~/Library/Application Support/com.musiclibrary.app/playlist-covers/1.png` — one test's `defer { FileManager.removeItem }` deletes another test's file mid-read.
- **Fix:** Added `.serialized` trait to the `@Suite` declaration. The tests now run sequentially. The covers-dir path stays unchanged (matches production); per-test cleanup still applies. This is a test-isolation patch, not a service bug — the service is correct under all production usage where playlist ids are globally unique.
- **Files modified:** `macos-app/MLMTests/ServiceTests/PlaylistCoverServiceTests.swift`
- **Commit:** `1114d40`.

### Plan Expectation Adjustments (not bugs)

**5. [D-EX-01] Added PlaylistCoverUtilitiesTests (12 tests) for Task 1 TDD gate**

- **Plan said:** Task 1 is `tdd="true"` but explicitly lists only Task 3's `PlaylistCoverServiceTests.swift` as a test file.
- **Reality:** TDD gate needs a separate RED test file for the pure utilities — they have no DB dependency and shouldn't ride on the service test setup. Added `MLMTests/ServiceTests/PlaylistCoverUtilitiesTests.swift` (12 @Tests covering GradientPalette palette + initials, MosaicCompositor PNG output for all 3 branches, ArtworkExtractor silent-nil contract).
- **No code-level fix needed:** the plan's `tdd="true"` directive is honored by the dedicated utility test file.
- **Commits:** `42eb182` (RED) → `0a68c97` (GREEN).

**6. [D-EX-02] `tracks.count < 4 || nonNilCount == 1` ternary for auto1 vs auto4**

- **Plan said:** D-01 reads "playlists with 1-3 tracks render single-cover; ≥4 tracks render 2×2 mosaic".
- **Implementation choice:** A playlist with 4 tracks but only ONE of them has extractable artwork would fall through the strict `tracks.count < 4` branch into the mosaic path with 1 image + 3 gradient gaps — visually noisy. Added `|| nonNilCount == 1` to route that case through `composeSingleCoverPNG` instead. Plan UI-SPEC §"Mosaic geometry" line 53 hints at this ("if only one tile has art, the mosaic looks broken"), so this is a UI-SPEC fidelity improvement, not a plan deviation.
- **No code-level fix needed:** branch behavior is still under D-01's umbrella; the plan's behavior list was at the playlist-track-count level, not artwork-availability level.

## Stub Tracking / Known Stubs

None. All new code paths have real consumers:
- `ArtworkExtractor` → consumed by `PlaylistCoverService.regenerateCover`
- `GradientPalette` → consumed by `MosaicCompositor.composeFallbackPNG` and `PlaylistCoverService.regenerateCover`
- `MosaicCompositor` → consumed by all three `PlaylistCoverService` entry points
- `PlaylistCoverService` → wired into `DependencyContainer`, observes `.playlistDidChange` from all 5 mutators (Plan 01 closed the moveTrack gap)

The `PlaylistCoverService` itself has no UI consumer in this plan — Plan 03 (`PlaylistCard` + Context-Menu) will read `cover_image_path` and call `setCustomCover` / `resetToAuto`. That's expected handoff to the next plan in the same wave queue, not a stub.

## Threat Flags

None. The threat model in 36-02-PLAN.md covers all new surface:
- T-36-04 (image-format spoofing in `setCustomCover`) — `NSImage(contentsOf:)` is the only decoder; macOS ImageIO sandboxes its decoders.
- T-36-05 (path traversal via id) — `Int64` from SQLite, no separators possible.
- T-36-06 (notification re-entry loop) — mitigated via the two-layer guard; verified by test 5.
- T-36-07, T-36-08 — accepted dispositions in the plan, no mitigation owed.

No new endpoints, no new auth paths, no schema changes (Plan 01 owned that).

## TDD Gate Compliance

| Gate | Commit | Status |
| ---- | ------ | ------ |
| RED Task 1 — failing utility tests | `42eb182` `test(36-02): add failing tests for ArtworkExtractor + GradientPalette + MosaicCompositor` | green |
| GREEN Task 1 — three utility files | `0a68c97` `feat(36-02): add ArtworkExtractor + GradientPalette + MosaicCompositor utilities` | green |
| RED Tasks 2+3 — failing service tests + ConfigRepo widening | `4243bd2` `test(36-02): add failing PlaylistCoverServiceTests + relax ConfigRepository DB type` | green |
| GREEN Tasks 2+3 — PlaylistCoverService + DI wiring | `1114d40` `feat(36-02): add PlaylistCoverService orchestrator + wire into DependencyContainer` | green |

All gates present in expected order. No REFACTOR commits needed — code shipped clean on first GREEN.

## Auth Gates / Manual Steps

None. Fully autonomous execution.

## Decisions Made

- **D-EX-01:** ConfigRepository.database widened to `any DatabaseWriter` (third repo following the pattern). All three of PlaylistCoverService's repository dependencies now accept DatabasePool or DatabaseQueue.
- **D-EX-02:** `MainActor.assumeIsolated` in deinit for observer-token cleanup. Token is set once in init, never mutated; the assumption is safe.
- **D-EX-03:** `await MainActor.run { ... }` in DependencyContainer for the @MainActor service construction. Matches `Task { @MainActor in }` callback pattern used elsewhere in the same file.
- **D-EX-04:** `.serialized` trait on `PlaylistCoverServiceTests` — required because the covers cache directory is a single shared filesystem path; in-memory DB ids reset per test causing path collisions under parallel runs.

## Plan-Level Decision Citations Coverage

- **D-01 (Hybrid auto1/auto4 selection):** `regenerateCover` branches on `nonNilCount` and `tracks.count` — fallback (0 art) / single (1-3 tracks OR only 1 art available) / 2×2 mosaic (≥4 tracks with ≥2 art). ✓
- **D-02 (Mosaic gap-tile gradient):** `composeMosaicPNG` fills nil tiles via `drawGradient(from: palette.start, to: palette.end, in: slotRect)` using the playlist's deterministic palette. ✓
- **D-03 (Spotify-style fallback):** `composeFallbackPNG` renders a `topLeading→bottomTrailing` linear gradient + `GradientPalette.initials(for: playlist.name)` centered with system bold weight, 95% white opacity. ✓
- **D-04 (Re-Generate-Trigger):** PlaylistCoverService observes `.playlistDidChange` and consumes the `userInfo["playlistId"]` payload Plan 01 added; re-entry guarded via the `origin` tag + `inFlight` set. ✓
- **D-05 (Sticky-Lock skip):** `regenerateCover` early-returns when `playlist.coverIsCustom == 1`; verified by test 2. ✓
- **D-06 (Reset to Auto Cover):** `resetToAuto(playlistId:)` clears the lock via `setCoverPath(path: nil, isCustom: false)`, deletes the cached PNG, and calls `regenerateCover` — Plan 03's context-menu hooks into this exact method. ✓

## Self-Check: PASSED

Verified files exist and commits are present.

Files:
- macos-app/MLM/Services/Playlists/ArtworkExtractor.swift — created (0a68c97)
- macos-app/MLM/Services/Playlists/GradientPalette.swift — created (0a68c97)
- macos-app/MLM/Services/Playlists/MosaicCompositor.swift — created (0a68c97)
- macos-app/MLM/Services/Playlists/PlaylistCoverService.swift — created (1114d40)
- macos-app/MLM/App/DependencyContainer.swift — modified (1114d40)
- macos-app/MLM/Database/ConfigRepository.swift — modified (4243bd2)
- macos-app/MLMTests/ServiceTests/PlaylistCoverUtilitiesTests.swift — created (42eb182)
- macos-app/MLMTests/ServiceTests/PlaylistCoverServiceTests.swift — created (4243bd2 + 1114d40)
- macos-app/MLMTests/Fixtures/playlist-cover-fixtures/README.md — created (4243bd2)

Commits:
- 42eb182 — test (RED Task 1)
- 0a68c97 — feat (GREEN Task 1)
- 4243bd2 — test (RED Tasks 2+3 + ConfigRepo widening)
- 1114d40 — feat (GREEN Tasks 2+3)
