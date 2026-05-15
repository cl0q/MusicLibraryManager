---
phase: 37
slug: album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-15
---

# Phase 37 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (built-in; same as Phase 36 PlaylistCoverServiceTests) |
| **Config file** | macos-app/MLM/MLMTests/Info.plist (standard, exists from Phase 1) |
| **Quick run command** | `swift test --filter ArtworkBackfillServiceTests` |
| **Full suite command** | `cd macos-app && swift test` |
| **Estimated runtime** | ~15-25 seconds (quick filter); ~60-90 seconds (full suite incl. UI snapshots) |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter ArtworkBackfillServiceTests` (or the test filter matching the task's surface — TrackCoverViewTests for UI tasks, etc.)
- **After every plan wave:** Run `cd macos-app && swift test` (full suite — must include ProcessRunner integration coverage)
- **Before `/gsd-verify-work`:** Full suite green + manual UI smoke test (import ~10 tracks, verify covers appear in LibraryTable + TrackDetailView + PlayerBar)
- **Max feedback latency:** 90 seconds (full suite)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 37-01-01 | 01 | 1 | S-3 (ffmpeg extraction works) | — | ArtworkService.extractEmbeddedArtwork(from:) returns Data for valid files, nil if ffmpeg missing | unit | `swift test --filter ArtworkServiceTests/testStaticEmbeddedExtraction` | ✅ (Phase 1, needs update for static method) | ⬜ pending |
| 37-01-02 | 01 | 1 | S-9 (ArtworkExtractor wraps ffmpeg) | — | ArtworkExtractor.extract delegates to ArtworkService.extractEmbeddedArtwork | unit | `swift test --filter ArtworkExtractorTests/testCallsArtworkService` | ✅ (Phase 36, needs update for static method) | ⬜ pending |
| 37-02-01 | 02 | 2 | S-1 (auto-trigger on import) | T-37-01 (subprocess injection) | .libraryDidImport posts → service enqueues; ffmpeg args hardcoded, only URL is dynamic (safe via Process.arguments array) | unit | `swift test --filter ArtworkBackfillServiceTests/testObservesLibraryDidImport` | ❌ Wave 0 | ⬜ pending |
| 37-02-02 | 02 | 2 | S-2 (concurrency limit) | T-37-05 (DoS via TaskGroup) | TaskGroup bounded to 4 concurrent ffmpeg subprocesses | unit | `swift test --filter ArtworkBackfillServiceTests/testConcurrencyLimit` | ❌ Wave 0 | ⬜ pending |
| 37-02-03 | 02 | 2 | — | — | inFlight Set coalesces duplicate enqueue requests | unit | `swift test --filter ArtworkBackfillServiceTests/testCoalescesDuplicateRequests` | ❌ Wave 0 | ⬜ pending |
| 37-02-04 | 02 | 2 | S-4 (notification posts per-track) | — | .trackArtworkDidChange fires with userInfo[trackId, artworkPath] after each extract | unit | `swift test --filter ArtworkBackfillServiceTests/testNotificationPosting` | ❌ Wave 0 | ⬜ pending |
| 37-02-05 | 02 | 2 | — | T-37-02 (ffmpeg missing) | ffmpeg missing → AppLogger.warn + nil return; no crash, no error to user | unit | `swift test --filter ArtworkBackfillServiceTests/testFfmpegMissingDebugLog` | ❌ Wave 0 | ⬜ pending |
| 37-03-01 | 03 | 3 | S-5 (LibraryTable shows covers) | — | TrackCoverView renders cached image | unit | `swift test --filter TrackCoverViewTests/testRendersCachedImage` | ❌ Wave 0 | ⬜ pending |
| 37-03-02 | 03 | 3 | S-5 | — | TrackCoverView renders disk-loaded image | unit | `swift test --filter TrackCoverViewTests/testRendersFromDisk` | ❌ Wave 0 | ⬜ pending |
| 37-03-03 | 03 | 3 | S-5 | — | Fallback gradient + music.note renders on file miss | unit/snapshot | `swift test --filter TrackCoverViewTests/testRendersGradientFallback` | ❌ Wave 0 | ⬜ pending |
| 37-03-04 | 03 | 3 | S-8 (file-existence check / self-healing) | — | TrackCoverView calls service.refreshSingleTrack when DB row exists but file missing | unit | `swift test --filter TrackCoverViewTests/testFileMissTriggersSelfHealing` | ❌ Wave 0 | ⬜ pending |
| 37-03-05 | 03 | 3 | — | — | .trackArtworkDidChange notification invalidates cache + reloads | unit | `swift test --filter TrackCoverViewTests/testNotificationTriggersReload` | ❌ Wave 0 | ⬜ pending |
| 37-03-06 | 03 | 3 | — | T-37-04 (memory exhaustion) | NSCache wrapper enforces countLimit 200; evicts when exceeded | unit | `swift test --filter TrackArtworkCacheTests/testEvictionUnderLimit` | ❌ Wave 0 | ⬜ pending |
| 37-03-07 | 03 | 3 | — | — | invalidate(forTrackId:) removes both 500 + 1200 entries | unit | `swift test --filter TrackArtworkCacheTests/testInvalidateTrack` | ❌ Wave 0 | ⬜ pending |
| 37-03-08 | 03 | 3 | S-6 (TrackDetailView shows cover) | — | TrackDetailView header replaces music.note placeholder with TrackCoverView(.large) | snapshot | manual / build inspect | ✅ (header exists, partial) | ⬜ pending |
| 37-03-09 | 03 | 3 | S-7 (PlayerBar shows cover) | — | PlayerBar.coverThumbnail replaced with TrackCoverView(.small) | snapshot | manual / build inspect | ✅ (placeholder exists) | ⬜ pending |
| 37-03-10 | 03 | 3 | S-5 | — | LibraryTable Title column has inline TrackCoverView before text | snapshot | manual / build inspect | ✅ (Title col exists, partial) | ⬜ pending |
| 37-04-01 | 04 | 3 | S-10 (Maintenance buttons split) | — | Settings → Maintenance shows two distinct buttons: "Refresh embedded artwork" + "Fetch from MusicBrainz" | manual | UI smoke test (see Manual-Only) | ❌ Wave 0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Required test scaffolds to create BEFORE implementation tasks proceed:

- [ ] `macos-app/MLMTests/Services/ArtworkBackfillServiceTests.swift` — unit tests for @MainActor @Observable service (testObservesLibraryDidImport, testConcurrencyLimit, testCoalescesDuplicateRequests, testNotificationPosting, testFfmpegMissingDebugLog)
- [ ] `macos-app/MLMTests/Views/TrackCoverViewTests.swift` — SwiftUI view tests (testRendersCachedImage, testRendersFromDisk, testRendersGradientFallback, testFileMissTriggersSelfHealing, testNotificationTriggersReload)
- [ ] `macos-app/MLMTests/Services/TrackArtworkCacheTests.swift` — NSCache wrapper tests (testCacheHit, testEvictionUnderLimit, testInvalidateTrack)
- [ ] Update `macos-app/MLMTests/Services/ArtworkExtractorTests.swift` (Phase 36) — adjust to call static `ArtworkService.extractEmbeddedArtwork`
- [ ] Update `macos-app/MLMTests/Services/ArtworkServiceTests.swift` (or create if missing) — add `testStaticEmbeddedExtraction` for the new static API surface

No new test config files required — reuse existing test bundle setup from Phase 1.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Auto-trigger end-to-end on real library | S-1 (auto-trigger) | Requires real ffmpeg + real audio files; integration of import-pipeline + backfill-service + UI notification. Unit tests cover isolated pieces but not the full chain. | 1) Wipe `~/Library/Caches/com.mlm.artwork_cache/`. 2) Settings → Library → Re-Scan. 3) Observe LibraryTable: tracks first show Solar-gradient fallback, then covers progressively pop in. 4) Verify `~/Library/Caches/com.mlm.artwork_cache/{trackId}_500.jpg` + `_1200.jpg` files exist for tracks with embedded art. 5) Tracks without embedded art keep Solar fallback (verify DB: no artwork row OR artwork row + missing file = re-attempt). |
| Maintenance "Refresh embedded artwork" button | S-10 (Maintenance split) | UI interaction + subprocess execution + progress display | 1) Wipe cache dir. 2) Settings → Maintenance → click "Refresh embedded artwork". 3) Verify progress shown, completes without errors, cache populated. 4) Verify "Fetch from MusicBrainz" remains separate button with rate-limit behavior intact. |
| TrackDetailView cover (128pt min) | S-6 | Visual fidelity; cover must be sharp on Retina | Open TrackDetailView for a track with embedded art. Verify cover renders at ≥128pt from 1200px source (sharp on Retina). Trigger fallback path: rename cache file, reopen detail — should show Solar gradient briefly, then re-extract + show cover (self-healing D-14). |
| PlayerBar cover (40pt thumbnail) | S-7 | Visual integration with transport controls | Start playback. Verify PlayerBar's left coverThumbnail shows the playing track's cover at 40pt (was hardcoded music.note before phase). Verify it updates when track changes (next/prev). Fallback test: play track without embedded art — Solar gradient renders. |
| Library scrolling performance | — | Frame-rate observable only at runtime | Scroll LibraryTable rapidly through 1000+ tracks. Verify no frame drops, no memory growth beyond NSCache limit (~200 entries × ~150KB ≈ 30MB working set). |
| Phase 36 mosaic still works | S (Phase 36 regression) | Integration of ArtworkExtractor refactor with PlaylistCoverService | Open Playlists view. Verify existing playlist covers still render correctly (auto-mosaic + gradient fallback). Add tracks to a playlist; verify cover regenerates (PlaylistCoverService still observes .playlistDidChange, calls ArtworkExtractor → now routed through static ArtworkService.extractEmbeddedArtwork). |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (5 test files listed above)
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s (full suite)
- [ ] `nyquist_compliant: true` set in frontmatter (after planner verifies coverage)

**Approval:** pending
