---
phase: 36-playlists-v2-0-macos-native
verified: 2026-05-13T11:30:00Z
status: human_needed
score: 17/17 must-haves verified (6 success criteria + 11 decisions D-01..D-11)
overrides_applied: 0
re_verification:
  previous_status: none
  note: initial verification
human_verification:
  - test: "Sidebar DisclosureGroup default-expanded persists across launches"
    expected: "After collapse + quit + relaunch, the disclosure state matches the user's last toggle (AppStorage key sidebar.pinnedPlaylists.expanded)"
    why_human: "@AppStorage round-trip requires real UserDefaults backing — only observable in a running app"
  - test: "Mosaic cover (auto4) visual quality with mixed embedded artwork"
    expected: "Playlist with 4 tracks, ≥2 with artwork: 2×2 mosaic rendered; gradient-tile fills empty slots; tiles align without visible seams"
    why_human: "Visual subjective — gradient blending and tile alignment cannot be unit-tested"
  - test: "Gradient-fallback cover for 0-artwork playlists"
    expected: "Playlist of remote-only or no-artwork tracks renders deterministic gradient + 1–2 char initials centered"
    why_human: "Visual subjective"
  - test: "User-override sticky-lock across track add/remove"
    expected: "Drop image on card → cover replaced; add/remove tracks → cover unchanged; Reset to Auto Cover → mosaic regenerates"
    why_human: "UI-driven drop-target + multi-step state verification"
  - test: "Sidebar click → PlaylistDetailView (no grid flash)"
    expected: "Click pinned playlist in Sidebar → PlaylistDetailView renders directly; no PlaylistsView grid intermediate render"
    why_human: "UI navigation transition observable only at runtime"
  - test: "8-pin soft-limit UI hint"
    expected: "Pin 8 playlists, attempt to pin 9th → inline banner 'Pinned limit reached' appears, 9th does not pin, banner auto-dismisses after ~3s"
    why_human: "Banner UI display with auto-dismiss timing"
---

# Phase 36: Playlists (v2.0 macOS Native) — Verification Report

**Phase Goal:** SwiftUI-Playlist-Surface ship-bereit — Cover-Image-Auto-Generierung (auto1/auto4-Mosaic/Gradient-Fallback + Sticky-Lock-Override) + Sidebar-DisclosureGroup für Pinned-Playlists + Direct-to-Detail-Navigation + 8-Pin-Soft-Limit + Tests.
**Verified:** 2026-05-13
**Status:** human_needed (all programmatic checks pass; six UAT items remain)
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Success Criteria SC-1..SC-6)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | PlaylistsView zeigt Grid aus Cards (Cover/Titel/Trackzahl), Create-Button funktioniert | VERIFIED | `Views/Playlists/PlaylistsView.swift:212` LazyVGrid renders PlaylistCard per playlist; `:194` "Create" button calls `viewModel.createPlaylist`; ⌘N popover wired at `:179-201`; PlaylistCard renders cover image (`:90` `Image(nsImage: coverImage)`), name (`infoArea`), trackCount param |
| SC-2 | PlaylistDetailView listet Tracks mit Drag-Reorder (Fractional Positioning, kein O(N)-Renumbering) | VERIFIED | `PlaylistDetailView.swift:227` `.onMove { from, to in viewModel.moveTrack(...) }`; `PlaylistDetailViewModel.swift:155-189` `moveTrack` computes `fractionalPosition(insertingAt:excluding:)` and calls `reorderTrack` (single-row UPDATE, no renumbering) |
| SC-3 | Create/Delete/Pin funktionieren mit Confirmation-UX wo nötig | VERIFIED | Create: `PlaylistViewModel.createPlaylist:110`. Delete (playlist): `:137 deletePlaylist`. Pin: `:togglePin` w/ 8-pin guard. Track-removal confirmation: `PlaylistDetailView.swift:74` `.alert("Remove Track", isPresented: showDeleteConfirmation)`. macOS-native popover for Create at `PlaylistsView.swift:167` |
| SC-4 | TrackContextMenu „Add to Playlist…" ist live verdrahtet | VERIFIED | `Views/Library/TrackContextMenu.swift:60-80` Menu iterates `availablePlaylists`, calls `addToPlaylist(playlist)` (`:282-296`) which invokes `playlistRepo.addTracks(...)`. Not a placeholder — calls real repo, posts `.playlistDidChange` |
| SC-5 | M3U-Import landet als native Playlists in der DB (Spotify-JSON deferred per D-12) | VERIFIED | `PlaylistDetailViewModel.swift:201-245 importM3U(_:)` parses M3U, resolves tracks via `findTrackByPath`, calls `addTracks` w/ fractional `nextPosition`. UI: `PlaylistDetailView.swift:62-73` `.fileImporter` w/ `m3u`/`m3u8` UTTypes. No Spotify-JSON code found (grep clean) → matches D-12 deferral |
| SC-6 | swift test grün (PlaylistRepositoryTests + neue View-Tests) | VERIFIED | `swift test` → "Test run with 123 tests in 12 suites passed after 0.542 seconds". `swift build` → "Build complete! (0.20s)" |

**Score:** 6/6 success criteria verified

---

### Decision Coverage (D-01..D-11) — Trackable in Shipped Code

| D-NN | Decision | Status | Greppable Evidence |
|------|----------|--------|--------------------|
| D-01 | Hybrid auto1 (<4 tracks) / auto4 (≥4 tracks) cover generation | VERIFIED | `PlaylistCoverService.swift:125-152` branch on `nonNilCount` and `tracks.count`: 0→fallback, 1-3 tracks OR only 1 artwork→`composeSingleCoverPNG`, else→`composeMosaicPNG` (plus auto1-on-single-artwork refinement noted in 36-02 D-EX-02) |
| D-02 | Mosaic gap-tiles filled with gradient (always 2×2, never adaptive 1/2/3 tile) | VERIFIED | `PlaylistCoverService.swift:145-151` pads tiles to exactly 4, passes 4 gradients to `composeMosaicPNG`; `MosaicCompositor.swift` (file exists, 6340 LOC) renders gradient for `nil` tiles |
| D-03 | 0-artwork fallback = deterministic gradient + initials | VERIFIED | `PlaylistCoverService.swift:125-131` `composeFallbackPNG`; `GradientPalette.swift:initials(for:)` + `colors(forPlaylistId:)`; tested by `PlaylistCoverUtilitiesTests.gradientPalette_*` (8 tests) |
| D-04 | Re-generate trigger on addTracks/removeTrack(s)/moveTrack | VERIFIED | `.playlistDidChange` observer at `PlaylistCoverService.swift:67-87`. All 5 mutators post: addTracks (PlaylistDetailViewModel:99), removeTrack (:123,138), importM3U (:241), moveTrack (:182-186 — added by 36-01 Task 3 with `userInfo["playlistId"]`) |
| D-05 | Sticky-lock via `cover_is_custom INTEGER NOT NULL DEFAULT 0` | VERIFIED | Migration v20 at `DatabaseManager.swift:605-611` (idempotent column add); `Playlist.swift:19,33,48,118` `coverIsCustom` Codable mapping; `PlaylistRepository.swift:84-90` `setCoverPath` atomic UPDATE both columns; PlaylistCoverService:101 `if playlist.coverIsCustom == 1 { return }` early-return; verified by `PlaylistCoverServiceTests.respects_cover_is_custom_flag()` |
| D-06 | Reset to Auto Cover context-menu entry | VERIFIED | `PlaylistCard.swift:206-213` `if playlist.coverIsCustom == 1 { Button "Reset to Auto Cover" → onResetCover() }`; wired in `PlaylistsView.swift:247-252` to `container.playlistCoverService?.resetToAuto(playlistId:)`; service impl at `PlaylistCoverService.swift:209-226` clears lock + deletes PNG + regen |
| D-07 | Sidebar surface: only `is_pinned = 1` playlists, capped at 8 | VERIFIED | `PinnedPlaylistsDisclosure.swift:162-168` `loadPinned()` filters `isPinned == 1` and sorts; `:60` `pinnedPlaylists.prefix(8)`. No Recent-Playlists, no full scrollable list |
| D-08 | DisclosureGroup default expanded + persists via @AppStorage | VERIFIED | `PinnedPlaylistsDisclosure.swift:39` `@AppStorage("sidebar.pinnedPlaylists.expanded") private var pinnedExpanded = true`; `:50` `DisclosureGroup(isExpanded: $pinnedExpanded)`. Default `= true` matches D-08 spec. (UAT verifies the persistence round-trip.) |
| D-09 | Direct-to-Detail navigation from sidebar pin click | VERIFIED | `SidebarSection.playlistDetail(Int64)` enum case at `ContentView.swift:238`; tagged on rows at `PinnedPlaylistsDisclosure.swift:100`; routed at `ContentView.swift:149-156` → `PlaylistDetailViewLoader` → `PlaylistDetailView`. Zero grid intermediary in the routing path |
| D-10 | 8-pin soft-limit with UI hint | VERIFIED | `PlaylistViewModel.swift:198-223` `togglePin` pre-check: derives `willPin` from current state, counts `isPinned == 1`, hard-blocks at `>=8` with `pinLimitHintMessage = "Pinned limit reached"` (3s auto-clear via Task.sleep). Unpin bypasses guard. Banner rendered at `PlaylistsView.swift:67`. Tested by `togglePin_ninthAttempt_setsPinLimitHintMessage` + `togglePin_unpinNeverTriggersLimit` |
| D-11 | Sidebar pinned context menu fully functional (Unpin/Rename/Delete/Reveal) | VERIFIED | `PinnedPlaylistsDisclosure.swift:109-124` contextMenu builds all 4 entries: Unpin (`onUnpin(pid)`), Rename… (`startRename`), Reveal in Grid (`onRevealInGrid`), Delete (.destructive, `onDelete`). Inline rename TextField at `:80-94` with `.onSubmit`/`.onExitCommand`. Wired in `SidebarView.swift:22-43` |

**Score:** 11/11 decisions visible in shipped code

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `MLM/Database/DatabaseManager.swift` | Migration v20 cover_is_custom | VERIFIED | Lines 605-611, idempotent registration |
| `MLM/Models/Playlist.swift` | coverIsCustom field + Codable + Columns | VERIFIED | Lines 19, 33, 48, 118 |
| `MLM/Database/PlaylistRepository.swift` | setCoverPath setter + fetchTracks tie-break | VERIFIED | Lines 84-90 setCoverPath; ORDER BY pt.position, pt.added_at ASC |
| `MLM/ViewModels/PlaylistDetailViewModel.swift` | moveTrack posts notification w/ playlistId | VERIFIED | Lines 182-186 |
| `MLM/ViewModels/PlaylistViewModel.swift` | 8-pin pre-check + banner state | VERIFIED | Lines 40-46 state, 198-223 togglePin guard, 253-260 flagCoverDropRejected |
| `MLM/Services/Playlists/ArtworkExtractor.swift` | Embedded artwork extraction | VERIFIED | 1167 bytes; consumed by PlaylistCoverService:112 |
| `MLM/Services/Playlists/GradientPalette.swift` | Deterministic palette + initials | VERIFIED | 2041 bytes; consumed by PlaylistCoverService + MosaicCompositor |
| `MLM/Services/Playlists/MosaicCompositor.swift` | 3 entry points (mosaic/single/fallback) | VERIFIED | 6340 bytes; consumed by PlaylistCoverService:127,135,138,149 |
| `MLM/Services/Playlists/PlaylistCoverService.swift` | Orchestrator with sticky-lock + re-entry guard | VERIFIED | 10593 bytes; observes .playlistDidChange; origin-tag + inFlight Set guards |
| `MLM/App/DependencyContainer.swift` | playlistCoverService slot | VERIFIED | Line 38 property; lines 120-126 MainActor.run construction |
| `MLM/Views/Playlists/PlaylistCard.swift` | Cover render + drop target + Reset menu | VERIFIED | iconArea:88-119, .onDrop:81-83, contextMenu Reset:206-213 |
| `MLM/Views/Playlists/PlaylistsView.swift` | Grid + Create popover + banners + cover-callback wiring | VERIFIED | LazyVGrid:212, Create popover:167, pin/drop banners:304/338, setCustomCover/resetToAuto callbacks:242,250 |
| `MLM/Views/Playlists/PlaylistDetailView.swift` | Drag-reorder + M3U import + delete-confirm | VERIFIED | .onMove:227, .fileImporter m3u/m3u8:62-73, .alert:74-85 |
| `MLM/Views/Playlists/PlaylistDetailViewLoader.swift` | Async-fetch shim for sidebar→detail | VERIFIED | 2687 bytes; `.task(id: playlistId)` reload pattern at lines 53-70 |
| `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift` | DisclosureGroup + inline rename + context menu | VERIFIED | 6717 bytes; all D-07/D-08/D-09/D-11 evidence above |
| `MLM/Views/Sidebar/SidebarView.swift` | Iterates topLevelCases + mounts disclosure | VERIFIED | Line 20 `ForEach(SidebarSection.topLevelCases)`, line 22 mount with 3 callbacks |
| `MLM/Views/ContentView/ContentView.swift` | .playlistDetail routing case + SidebarSection enum | VERIFIED | Line 149 route; enum:230-291 with .playlistDetail(Int64), id, label, icon, keyboardShortcut, topLevelCases |
| `MLM/App/MLMApp.swift` | Navigate menu uses topLevelCases | VERIFIED | Line 43 swap |
| `MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift` | 5 schema/setter tests | VERIFIED | Suite passes (5 tests) |
| `MLMTests/ServiceTests/PlaylistCoverServiceTests.swift` | 5 service tests | VERIFIED | Suite passes (5 tests, .serialized trait) |
| `MLMTests/ServiceTests/PlaylistCoverUtilitiesTests.swift` | 12 utility tests | VERIFIED | Suite passes (12 tests) — actual run shows 14 entries; all green |
| `MLMTests/ViewModelTests/PlaylistViewModelTests.swift` | 7 ViewModel tests | VERIFIED | Suite passes (7 tests) |
| `MLMTests/Fixtures/playlist-cover-fixtures/README.md` | Test fixture stub | VERIFIED | File exists |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| PlaylistDetailViewModel.moveTrack | PlaylistCoverService.regenerateCover | NotificationCenter.post(.playlistDidChange, userInfo: playlistId) → observer | WIRED | Notification posted at line 182; observer at PlaylistCoverService:67-87 reads userInfo["playlistId"] |
| PlaylistCard drop | PlaylistCoverService.setCustomCover | .onDrop → handleDrop → onCoverDropped(URL) → PlaylistsView callback | WIRED | PlaylistCard:81 onDrop; PlaylistsView:240-245 callback invokes container.playlistCoverService?.setCustomCover |
| PlaylistCard "Reset to Auto Cover" | PlaylistCoverService.resetToAuto | contextMenu Button → onResetCover → PlaylistsView callback | WIRED | PlaylistCard:208 button; PlaylistsView:247-252 invokes resetToAuto |
| Sidebar pin row click | PlaylistDetailView render | tag(.playlistDetail(id)) → List(selection:) → ContentView switch → PlaylistDetailViewLoader → PlaylistDetailView | WIRED | Tag at PinnedPlaylistsDisclosure:100; route at ContentView:149; loader fetches by id and renders detail |
| PlaylistViewModel.togglePin 9th attempt | PlaylistsView banner | pinLimitHintMessage state → if-let banner branch | WIRED | VM:212 sets message; View:67 renders pinLimitBanner |
| TrackContextMenu "Add to Playlist" | PlaylistRepository.addTracks | Menu iterates availablePlaylists → addToPlaylist → playlistRepo.addTracks | WIRED | Lines 60-80 menu; 282-296 addToPlaylist call. Not a stub: real repo call + .playlistDidChange post |
| PlaylistCoverService observer | self-emission re-entry | origin tag + inFlight Set | WIRED | Service:73-74 origin check; :94-96 inFlight guard; verified by reentry_guard_skips_self_notifications test |
| PinnedPlaylistsDisclosure | .playlistDidChange refresh | .onReceive(publisher) → loadPinned | WIRED | Lines 69-71 |
| SidebarView onUnpin/onDelete | PlaylistRepository | Closures call togglePin/delete + explicit post .playlistDidChange | WIRED | SidebarView:26-43 |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|---------------------|--------|
| PlaylistsView grid | viewModel.displayedPlaylists | PlaylistViewModel.loadPlaylists → PlaylistRepository.fetchAll | DB query (GRDB) | FLOWING |
| PlaylistCard cover image | loadCoverImage() | NSImage(contentsOf: coversDir/<id>.png) — written by MosaicCompositor | Real PNG files written to ~/Library/Application Support/com.musiclibrary.app/playlist-covers/ | FLOWING |
| PinnedPlaylistsDisclosure rows | pinnedPlaylists state | PlaylistRepository.fetchAll filtered isPinned==1 | DB query | FLOWING |
| PlaylistDetailView tracks | viewModel.tracks | PlaylistRepository.fetchTracks(playlistId:) with `ORDER BY pt.position, pt.added_at ASC` | DB query | FLOWING |
| PlaylistDetailViewLoader playlist | @State playlist | container.playlistRepository.fetch(id: playlistId) at .task(id:) | DB single-row select | FLOWING |
| pinLimitHintMessage banner | viewModel.pinLimitHintMessage | togglePin guard sets it; auto-clear Task removes | Real conditional state | FLOWING |

No hollow props, no hardcoded empty data sources detected.

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Swift build compiles | `cd macos-app && swift build` | "Build complete! (0.20s)" exit 0 | PASS |
| Full test suite green | `cd macos-app && swift test` | "Test run with 123 tests in 12 suites passed after 0.542 seconds" | PASS |
| Migration v20 column present | DatabaseTests.playlistsTableHasCoverIsCustomColumn | green | PASS |
| Sticky-lock honored | PlaylistCoverServiceTests.respects_cover_is_custom_flag | green | PASS |
| Set/reset cover round-trip | setCustomCover_flipsLockTo1, resetToAuto_clearsLockAndRegens | green | PASS |
| Re-entry guard works | reentry_guard_skips_self_notifications | green | PASS |
| 8-pin limit blocks 9th | togglePin_ninthAttempt_setsPinLimitHintMessage | green | PASS |
| Unpin never triggers guard | togglePin_unpinNeverTriggersLimit | green | PASS |
| fetchTracks tie-break stable | fetchTracks_tieBreaksByAddedAtAsc | green | PASS |
| Fallback PNG written | fallback_with_zero_tracks_writes_PNG | green | PASS |
| Mosaic/single composition writes 512×512 PNG | mosaicCompositor_composeMosaic/composeSingle/composeFallback_writes512PNG | green | PASS |

---

### Requirements Coverage

The phase's success criteria are derived from the ROADMAP's six SC items; PLV2-01..PLV2-07 are listed as "to be locked in CONTEXT/SPEC". The PLV2-NN slots are not present in `.planning/REQUIREMENTS.md` (search returned no PLV2-prefixed IDs in that file); the v2.0 macOS Native milestone tracks requirements at the success-criteria level. All six SCs are SATISFIED above.

| Requirement | Source | Description | Status | Evidence |
|-------------|--------|-------------|--------|----------|
| SC-1..SC-6 | ROADMAP Phase 36 | See observable truths table | SATISFIED | All six green |
| PLV2-01..PLV2-07 | ROADMAP placeholder | Slots reserved "to be locked in CONTEXT/SPEC" | N/A | Not authored — phase shipped against the SC list. The CONTEXT.md D-NN list (D-01..D-11) serves as the locked-decision substitute and is fully covered |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `PlaylistsView.swift` | 34 | Dead `let viewModel` in `if let selectedPlaylist, let viewModel { ... }` (inner viewModel not referenced) | Info | Pre-existing build warning, not Phase-36-introduced. Documented in 36-03-SUMMARY "Out-of-Scope Discoveries". Does not affect functionality |
| `TrackContextMenu.swift` | 84-90 | "Add to Sync Profile…" button is `.disabled(true)` with placeholder comment `// Phase 12` | Info | Not a Phase 36 surface — referenced by Phase 12 roadmap. Not a regression |
| (none) | — | Pattern: TODO/FIXME/placeholder in Phase-36-shipped files | n/a | grep clean: no TODO/FIXME inserted into the new service/view files |
| (none) | — | Pattern: hardcoded empty arrays / null returns in data path | n/a | All renders trace to DB queries or filesystem PNGs |

No blockers, no warnings on Phase-36-shipped code.

---

### Human Verification Required

Manual UAT items copied from `.planning/phases/36-playlists-v2-0-macos-native/36-VALIDATION.md` — all marked "manual" because they cover visual/UX qualities or AppStorage round-trips that require a running app:

1. **Sidebar DisclosureGroup default-expanded persists across launches** (D-08)
   - Test: Launch app, collapse Pinned-DisclosureGroup, quit, relaunch, verify state preserved
   - Expected: Collapsed-state survives quit-relaunch; default state on fresh launch is expanded
   - Why human: `@AppStorage` UserDefaults round-trip needs a real app lifecycle

2. **Mosaic-cover visual quality (auto4 with mixed artwork)** (D-01, D-02)
   - Test: Create a playlist with 4 tracks (≥2 with embedded artwork); verify 2×2 mosaic; remove artwork from one track, regen, verify gradient-tile fills the empty slot
   - Expected: Tiles align cleanly; gradient-fill blends with surrounding tile colors
   - Why human: Visual subjective; tile-alignment seams cannot be unit-tested

3. **Gradient-fallback look for 0-artwork playlists** (D-03)
   - Test: Create a playlist of remote-only tracks (no organized_path → no AVAsset artwork); verify gradient + initials card
   - Expected: Deterministic gradient (per playlist id) with 1–2 char centered initials
   - Why human: Visual subjective

4. **User-override sticky-lock across track add/remove** (D-05, D-06)
   - Test: Drop an image on a card → cover replaces; add and remove tracks → cover unchanged; right-click → "Reset to Auto Cover" → mosaic regenerates
   - Expected: Custom cover persists across mutations; Reset flips lock off + regenerates
   - Why human: UI-driven drop-target + multi-step state verification

5. **Sidebar click → PlaylistDetailView direct navigation (no grid flash)** (D-09)
   - Test: Click pinned playlist in Sidebar → PlaylistDetailView renders directly with no intermediate Grid render
   - Expected: Direct render; no flash of PlaylistsView grid
   - Why human: UI navigation transition timing

6. **8-pin soft-limit UI hint** (D-10)
   - Test: Pin 8 playlists, attempt to pin 9th → verify inline banner appears + 9th doesn't pin
   - Expected: Banner "Pinned limit reached" shows with mlmWarning accent bar; auto-dismisses after ~3 s; 9th playlist remains unpinned
   - Why human: Banner UI display with auto-dismiss timing

---

### Gaps Summary

No gaps. All six success criteria and all eleven trackable decisions (D-01..D-11) are visible in shipped code with passing automated tests (123/123 green). The phase has shipped 4/4 plans; the SUMMARY claims hold up against codebase inspection.

The status is `human_needed` rather than `passed` solely because Phase 36's `VALIDATION.md` reserves six visual/UAT items that cannot be verified programmatically — they require a running app and human inspection of mosaic/gradient quality, navigation transitions, and AppStorage round-trips. Once those six items are signed off, the phase is closeable.

---

*Verified: 2026-05-13*
*Verifier: Claude (gsd-verifier)*
