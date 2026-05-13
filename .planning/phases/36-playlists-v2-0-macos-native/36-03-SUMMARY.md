---
phase: 36-playlists-v2-0-macos-native
plan: 03
subsystem: playlists-ui
tags: [phase-36, plan-03, ui, playlist-card, pin-limit, cover-drop, banner, d-05, d-06, d-10]
dependency_graph:
  requires:
    - 36-01 (Playlist.coverIsCustom field + PlaylistRepository.setCoverPath setter)
    - 36-02 (PlaylistCoverService.setCustomCover / .resetToAuto + DI wiring)
    - 36-04 (.playlistDidChange observer in PinnedPlaylistsDisclosure consumes the new post)
  provides:
    - PlaylistCard cover-PNG rendering surface
    - PlaylistCard drag-drop target (Finder + in-app)
    - PlaylistCard "Reset to Auto Cover" context-menu entry
    - PlaylistViewModel 8-pin hard-block + transient hint state (pinLimitHintMessage)
    - PlaylistViewModel cover-drop rejection state (coverDropErrorMessage)
    - PlaylistsView pin-limit banner (3s auto-dismiss)
    - PlaylistsView drop-rejected banner (4s auto-dismiss)
  affects:
    - Sidebar PinnedPlaylistsDisclosure (now receives .playlistDidChange after togglePin)
tech_stack:
  added:
    - UTType (UniformTypeIdentifiers) used in PlaylistCard.handleDrop
  patterns:
    - "@Observable transient state + Task-based auto-clear (writable var, not private(set))"
    - "NSItemProvider.loadDataRepresentation for both .fileURL and .image branches"
    - "VStack-level @ViewBuilder banner functions with .transition(.move(.top).combined(with: .opacity))"
key_files:
  created:
    - macos-app/MLMTests/ViewModelTests/PlaylistViewModelTests.swift (136 LOC, 7 tests)
  modified:
    - macos-app/MLM/ViewModels/PlaylistViewModel.swift (+55 LOC)
    - macos-app/MLM/Views/Playlists/PlaylistCard.swift (~143 added, 18 deleted)
    - macos-app/MLM/Views/Playlists/PlaylistsView.swift (+96 LOC)
decisions:
  - "Test surface lives in MLMTests/ViewModelTests/ — new directory, matches DatabaseTests/ + ServiceTests/ convention; @MainActor-annotated struct test type so @MainActor methods can be called without per-call hops"
  - "pinLimitHintMessage + coverDropErrorMessage are `var` not `private(set) var` — the weak-self auto-clear Task needs to reset them without a setter method"
  - "8-pin pre-check derives willPin from playlists.first(where:).isPinned == 0 before the count check, so unpins always bypass the guard (T-36-12 mitigation)"
  - "Cover-image branch in iconArea takes precedence over the gradient fallback; pin indicator + source badge are overlaid on either branch (ZStack)"
  - "URL(dataRepresentation:relativeTo:isAbsolute:) needs explicit `relativeTo: nil` — Swift 5.10 / macOS 15 SDK doesn't allow defaulting that parameter"
  - "loadCoverImage uses (relPath as NSString).lastPathComponent before joining with coversDir — T-36-09 path-traversal mitigation"
  - "In-app .image drag persists raw image data to FileManager.default.temporaryDirectory so PlaylistCoverService.setCustomCover sees a uniform URL input regardless of whether the source was Finder or an in-app drag"
  - "Banner placement is BETWEEN the header bar and the Divider — pushes the grid down ~44pt while visible (UI-SPEC §8-pin banner position)"
metrics:
  duration_seconds: 217
  duration_human: "3m 37s"
  tasks_completed: 3
  files_modified: 3
  files_created: 1
  tests_added: 7
  total_suite_passing: "123 tests / 12 suites"
  completed_date: "2026-05-13"
---

# Phase 36 Plan 03: PlaylistCard UI Surfaces Summary

User-facing cover surface (drop-target + cached PNG render + Reset menu) and the 8-pin soft-limit hard-block + transient banner state — three SwiftUI files modified, one test suite added, full 123-test suite green.

## What Shipped

Cards render their cached cover PNGs straight from
`~/Library/Application Support/com.musiclibrary.app/playlist-covers/<id>.png`,
fall back to the category gradient + SF Symbol when the file is missing,
accept image drops from both Finder (`.fileURL`) and in-app drags (`.image`),
flash the `mlmAccent` stroke at `lineWidth: 2` while the drop is hovering,
expose "Reset to Auto Cover" in the context menu only when
`coverIsCustom == 1`, and bubble unsupported payloads through
`onCoverDropRejected` to the parent.

`PlaylistViewModel.togglePin` now hard-blocks the 9th pin attempt with
`pinLimitHintMessage = "Pinned limit reached"` (3-second auto-clear via
`Task.sleep(for: .seconds(3))`), posts `.playlistDidChange` after a
successful flip so the sidebar disclosure refreshes (Plan 04 contract),
and exposes `flagCoverDropRejected()` which sets
`coverDropErrorMessage = "Couldn't read that image. Try a PNG or JPEG file."`
for 4 seconds.

`PlaylistsView` renders both banners as inline rows between the header
and the divider — pin-limit banner with the warning-triangle glyph + body
"Unpin one playlist before pinning another. (Maximum: 8)", drop-rejected
banner with `xmark.octagon.fill` + the rejection copy, both with a 3pt
`mlmWarning` accent bar and `mlmRaised` background. Combined-element
accessibility labels read out the full state.

## Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 (RED) | Add failing PlaylistViewModel tests | `02be839` | MLMTests/ViewModelTests/PlaylistViewModelTests.swift |
| 1 (GREEN) | Enforce 8-pin limit + cover-drop banner state | `62586a1` | MLM/ViewModels/PlaylistViewModel.swift |
| 2 | Render cached cover + drop-target + Reset menu | `249ab2e` | MLM/Views/Playlists/PlaylistCard.swift |
| 3 | Wire cover callbacks + render banners | `d56cd76` | MLM/Views/Playlists/PlaylistsView.swift |

## ViewModel Pre-Check Insertion Site

The 8-pin guard lives at the very top of `PlaylistViewModel.togglePin(id:)`:

```swift
guard let target = playlists.first(where: { $0.id == id }) else { return }
let willPin = target.isPinned == 0

if willPin {
    let pinnedCount = playlists.filter { $0.isPinned == 1 }.count
    if pinnedCount >= 8 {
        pinLimitHintMessage = "Pinned limit reached"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.pinLimitHintMessage = nil
        }
        return  // hard block — no repo call, no notification
    }
}
```

`willPin` is derived before the count check so unpins never reach the guard
(T-36-12 spoofing mitigation). The auto-clear `Task` captures `[weak self]`
so a deinit during the 3-second window doesn't leak.

## ViewModel `flagCoverDropRejected()` Auto-Clear

```swift
@MainActor
func flagCoverDropRejected() {
    coverDropErrorMessage = "Couldn't read that image. Try a PNG or JPEG file."
    Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(4))
        self?.coverDropErrorMessage = nil
    }
}
```

Same weak-self pattern, 4-second timer per UI-SPEC line 174 ("auto-dismisses
after 4s" — longer than the 3s pin banner because the rejection message is
single-line and informational, not a guard-rail).

## Card Cover Loader Path

```swift
private func loadCoverImage() -> NSImage? {
    guard let relPath = playlist.coverImagePath else { return nil }
    let fileName = (relPath as NSString).lastPathComponent
    let url = coversDir.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return NSImage(contentsOf: url)
}

private var coversDir: URL {
    FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.musiclibrary.app")
        .appendingPathComponent("playlist-covers")
}
```

`lastPathComponent` strips any directory component from the DB-stored relative
path before joining with `coversDir`, so a malicious `coverImagePath` of
`../../../../etc/passwd` reduces to `passwd`, which won't exist under
`playlist-covers/` and falls through to the gradient branch (T-36-09 mitigation).

## Drop-Target Visual Feedback

```swift
.overlay(
    RoundedRectangle(cornerRadius: 8)
        .stroke(strokeColor, lineWidth: isDropTargeted ? 2 : 1)
)
.animation(.easeInOut(duration: 0.12), value: isDropTargeted)

private var strokeColor: Color {
    if isDropTargeted { return .mlmAccent }
    return isHovered ? .mlmEdge : .mlmEdgeSubtle
}
```

Accent stroke wins over hover state; the 120ms ease-in-out keeps the
flash feeling tactile rather than instantaneous.

## Drop Handler Branches

`handleDrop(providers:)` resolves on three layered conditions:

1. **`.fileURL` provider (Finder drop)** — `loadDataRepresentation(for: .fileURL)`,
   then `URL(dataRepresentation:relativeTo:isAbsolute:)` with a fallback to
   `URL(string:)` over the raw UTF-8 bytes. Forwards to `onCoverDropped`.
2. **`.image` provider (in-app drag)** — `loadDataRepresentation(for: .image)`,
   writes the raw data to `FileManager.default.temporaryDirectory/inapp_cover_<uuid>`,
   then forwards that temp URL to `onCoverDropped` so the service has a uniform
   URL input regardless of source.
3. **Anything else** — fires `onCoverDropRejected()` synchronously, returns `false`.

Decoding failure in either branch routes back to `onCoverDropRejected` via
`Task { @MainActor in ... }` (the data-loading closure is off-main).

## Reset Menu Visibility Rule

```swift
if playlist.coverIsCustom == 1 {
    Button {
        onResetCover()
    } label: {
        Label("Reset to Auto Cover", systemImage: "arrow.counterclockwise")
    }
}
```

Inserted between the Pin/Unpin button and the destructive `Divider`. The
literal `== 1` check matches `coverIsCustom`'s `Int` representation in the
GRDB row (1 = locked, 0 = auto). D-06.

## Banner Visuals & Accessibility

Both banners follow the UI-SPEC §"8-pin Soft-Limit Hint UI" structure:
3pt-wide `mlmWarning` leading bar → 14pt warning glyph (triangle for
pin-limit, octagon-X for drop-rejection) → text stack → trailing `Spacer()`.
Background `Color.mlmRaised`, padding 12 horizontal / 8 vertical.

Pin-limit banner accessibility label (combined-element):
> "Pin limit reached. Maximum eight pinned playlists. Unpin one to free a slot."

Drop-rejected banner accessibility label (interpolates the message):
> "Cover drop rejected. Couldn't read that image. Try a PNG or JPEG file."

`gridContent` wraps the conditional banners in
`.animation(.easeInOut(duration: 0.2), value: viewModel.pinLimitHintMessage)`
and the same for `coverDropErrorMessage`, so the auto-clear collapses smoothly
when the timer fires.

## Test Surface Added

`macos-app/MLMTests/ViewModelTests/PlaylistViewModelTests.swift` — new
directory, 7 tests, all passing:

- `pinLimitHintMessage_startsNil`
- `coverDropErrorMessage_startsNil`
- `togglePin_ninthAttempt_setsPinLimitHintMessage` — seeds 8 pinned, adds
  a 9th, verifies the message is set AND `isPinned` did not flip
- `togglePin_unpinNeverTriggersLimit` — seeds 8 pinned, unpins one of
  them, verifies the limit never trips
- `togglePin_withinLimit_succeedsWithoutHint` — seeds 3 pinned, adds a
  4th, verifies the pin succeeds and the hint stays nil
- `flagCoverDropRejected_setsBannerCopy` — verifies the literal UI-SPEC
  line 174 copy
- `togglePin_success_postsPlaylistDidChange` — verifies the local pin
  flip in tandem with the notification post (the notification subscription
  ordering is best-effort because the post lands inside the same Task
  hop; the test focuses on the observable state mutation)

## Deviations from Plan

### Auto-Fixed Issues

**1. [Rule 1 — Bug] URL(dataRepresentation:isAbsolute:) compile error**

- **Found during:** Task 2 build
- **Issue:** Swift 5.10 / macOS 15 SDK requires the explicit
  `relativeTo:` parameter (no default value), so the spec's
  `URL(dataRepresentation: data, isAbsolute: true)` failed to compile.
- **Fix:** Added `relativeTo: nil` as the second argument, matching
  the Foundation signature `init?(dataRepresentation:relativeTo:isAbsolute:)`.
- **Files modified:** `macos-app/MLM/Views/Playlists/PlaylistCard.swift:273`
- **Commit:** `249ab2e`

### Out-of-Scope Discoveries

`PlaylistsView.swift:34` carries a pre-existing dead-let warning:
`if let selectedPlaylist, let viewModel { ... }` — the inner `viewModel` is
not referenced inside the if-branch (the body navigates to
`PlaylistDetailView` using the outer `selectedPlaylist`). Not modified per
scope-boundary rule; surfaces as a `[#no-usage]` warning every build.

## Test Coverage

- **New:** `PlaylistViewModelTests` (7 tests, all green)
- **Preserved:** `PlaylistRepositoryCoverTests` (Plan 01, 5 tests), `PlaylistCoverServiceTests` (Plan 02, 10 tests), `PlaylistCoverUtilitiesTests` (Plan 02, 26 tests), all other suites
- **Total:** 123 tests / 12 suites passing

## Verification Gates Run

| Gate | File | Result |
|------|------|--------|
| `grep -c 'pinLimitHintMessage'` | `PlaylistViewModel.swift` | 4 (decl, set, set-nil, return) |
| `grep -c 'coverDropErrorMessage'` | `PlaylistViewModel.swift` | 3 (decl, set, set-nil) |
| `grep -c 'pinnedCount >= 8'` | `PlaylistViewModel.swift` | 1 |
| `grep -c 'flagCoverDropRejected'` | `PlaylistViewModel.swift` | 3 |
| `grep -c 'playlistDidChange'` | `PlaylistViewModel.swift` | 5 (4 existing + 1 new in togglePin) |
| `grep -c 'loadCoverImage'` | `PlaylistCard.swift` | 2 |
| `grep -c 'onCoverDropped'` | `PlaylistCard.swift` | 4 |
| `grep -c 'onCoverDropRejected'` | `PlaylistCard.swift` | 7 |
| `grep -c 'Reset to Auto Cover'` | `PlaylistCard.swift` | 2 (string + comment) |
| `grep -c 'isDropTargeted'` | `PlaylistCard.swift` | 5 |
| `grep -c 'applicationSupportDirectory'` | `PlaylistCard.swift` | 1 |
| `grep -c 'playlist-covers'` | `PlaylistCard.swift` | 4 |
| `grep -c 'coverIsCustom == 1'` | `PlaylistCard.swift` | 1 |
| `grep -c 'onCoverDropped'` | `PlaylistsView.swift` | 1 |
| `grep -c 'flagCoverDropRejected'` | `PlaylistsView.swift` | 2 |
| `grep -c 'Pinned limit reached'` | `PlaylistsView.swift` | 1 |
| `grep -c 'coverDropErrorBanner'` | `PlaylistsView.swift` | 2 |
| `grep -c 'setCustomCover'` | `PlaylistsView.swift` | 1 |
| `grep -c 'resetToAuto'` | `PlaylistsView.swift` | 1 |
| `swift build` | full crate | exit 0 |
| `swift test` | full suite | 123/123 passing |

## TDD Gate Compliance

Plan 36-03 Task 1 carries `tdd="true"`. Gate sequence verified in git log:

1. RED: `02be839 test(36-03): add failing PlaylistViewModel tests...`
2. GREEN: `62586a1 feat(36-03): enforce 8-pin limit...`

No REFACTOR commit was needed — the implementation landed clean on first pass.
Tasks 2 and 3 are pure UI wiring (`type="auto"` without `tdd`), so they
ship as single feat commits.

## Manual Smoke Items (not covered by automated verify)

Listed in 36-VALIDATION.md "Manual-Only" — these need a human in front of
the running app:

- Pin 8 playlists, then click pin on the 9th → banner appears, auto-dismisses after ~3s, 9th playlist stays unpinned
- Drag a PNG from Finder onto a card → border flashes accent stroke, card cover replaces with the dropped image, "Reset to Auto Cover" appears in the right-click menu
- Drag a `.txt` file onto a card → drop-rejected banner appears, auto-dismisses after ~4s, card cover unchanged
- Right-click a card with `cover_is_custom == 1` → "Reset to Auto Cover" entry visible; click it → card reverts to the auto-generated mosaic/gradient
- Right-click a card with `cover_is_custom == 0` → "Reset to Auto Cover" entry absent

## Self-Check: PASSED

- [x] `macos-app/MLM/ViewModels/PlaylistViewModel.swift` modified (verified)
- [x] `macos-app/MLM/Views/Playlists/PlaylistCard.swift` modified (verified)
- [x] `macos-app/MLM/Views/Playlists/PlaylistsView.swift` modified (verified)
- [x] `macos-app/MLMTests/ViewModelTests/PlaylistViewModelTests.swift` created (verified)
- [x] Commit `02be839` in log
- [x] Commit `62586a1` in log
- [x] Commit `249ab2e` in log
- [x] Commit `d56cd76` in log
- [x] `swift build` exits 0
- [x] `swift test` exits 0 (123/123 passing)
- [x] No Phase 35 files touched (Waveform*, TrackDetailView, PlayerBar untouched — verified via git diff scope)
