---
phase: 36-playlists-v2-0-macos-native
plan: 04
subsystem: sidebar + routing (pinned playlists UX)
tags: [sidebar, DisclosureGroup, AppStorage, direct-routing, inline-rename, SwiftUI, FocusState]
dependency_graph:
  requires:
    - Plan 36-01 (PlaylistRepository.rename + togglePin + delete + fetchAll + fetch — all consumed by the disclosure)
    - SidebarSection enum baseline (Phase 2 v2.0)
    - PlaylistDetailView initializer signature (playlist:, onBack:, onTrackDoubleClick:)
  provides:
    - SidebarSection.playlistDetail(Int64) deep-link case
    - SidebarSection.topLevelCases static accessor (replaces synthesised CaseIterable.allCases)
    - PinnedPlaylistsDisclosure subcomponent (default-expanded DisclosureGroup + inline rename + per-row context menu)
    - PlaylistDetailViewLoader (async-fetch shim for sidebar→detail routing)
  affects:
    - PlaylistsView grid (Reveal in Grid action selects .playlists from sidebar callback)
    - All Phase 2-5 callers of SidebarSection.allCases (now route through .topLevelCases)
tech_stack:
  added: []
  patterns:
    - "Enum with associated value disables synthesised CaseIterable; static topLevelCases array fills the gap"
    - "DisclosureGroup + @AppStorage Bool for collapse persistence — native macOS sidebar idiom"
    - "Inline rename via @State renamingId + @FocusState + TextField.onSubmit/.onExitCommand (mirror of PlaylistCard pattern, scaled down for sidebar row)"
    - ".task + .onReceive(.playlistDidChange) — re-fetch pinned-list on any sibling mutation"
    - "Tag-based selection routing — SidebarSection.playlistDetail(id) flows through List(selection:) into ContentView.detailView's switch"
key_files:
  created:
    - macos-app/MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift
    - macos-app/MLM/Views/Playlists/PlaylistDetailViewLoader.swift
  modified:
    - macos-app/MLM/Views/ContentView/ContentView.swift
    - macos-app/MLM/Views/Sidebar/SidebarView.swift
    - macos-app/MLM/App/MLMApp.swift
decisions:
  - "keyboardShortcut widened from KeyEquivalent to KeyEquivalent? — .playlistDetail rows are not bound to ⌘1–5; only top-level cases carry a global shortcut. MLMApp's Navigate menu (sole keyboardShortcut caller) iterates topLevelCases and safe-unwraps with a '0' sentinel; the sentinel is never actually consumed because filtered cases never appear in the iteration."
  - "MLMApp.Navigate menu kept iterating SidebarSection in addition to SidebarView — both call sites had to swap allCases→topLevelCases together. CaseIterable's loss was not local to SidebarView."
  - "PinnedPlaylistsDisclosure owns its own loadPinned() + .playlistDidChange observer instead of accepting a [Playlist] prop. Keeps the component self-contained; SidebarView need not track pinned-list state. Refresh path: Plan 02's PlaylistCoverService post + Plan 01's moveTrack post + Plan 03's togglePin (when shipped) + this disclosure's own rename/unpin/delete all trigger the same observer."
  - "onUnpin and onDelete callbacks live in SidebarView (not the disclosure) so the disclosure stays presentation-only for those actions; they call playlistRepository.togglePin / .delete then explicitly post .playlistDidChange because those repo methods do NOT post the notification themselves. Rename is the exception — it stays inside the disclosure so the TextField + FocusState live where the row lives."
  - "PlaylistDetailViewLoader fetches by id on each .task(id:) change rather than holding a stale Playlist snapshot. Trade-off: one extra single-row SELECT per sidebar click; gain: rename/cover-regen updates surface immediately when the user returns to a detail view."
metrics:
  duration_seconds: 163
  duration_human: "~3 minutes"
  tasks_completed: 2
  files_created: 2
  files_modified: 3
  tests_added: 0
  completed_date: "2026-05-13T07:58:46Z"
---

# Phase 36 Plan 04: Sidebar Pinned-Playlists Disclosure + Direct-to-Detail Routing — Summary

One-liner: Sidebar gains a default-expanded DisclosureGroup under "Playlists" listing pinned playlists (≤8, name-sorted); clicking a child routes via `SidebarSection.playlistDetail(Int64)` → `PlaylistDetailViewLoader` → `PlaylistDetailView` (D-09); each row has a 4-entry context menu (Unpin / Rename… / Reveal in Grid / Delete) where Rename flips the row into a focused `TextField` that commits via `playlistRepository.rename(id:name:)` (D-11) — no grid round-trip.

## Enum refactor diff (Task 1)

`SidebarSection` shed `String, CaseIterable` (the new associated-value case `.playlistDetail(Int64)` makes `CaseIterable` un-synthesisable) and grew four things:

```swift
// Before:                                       // After:
enum SidebarSection:                              enum SidebarSection: Hashable, Identifiable {
    String, CaseIterable, Identifiable, Hashable {    case library
    case library                                      case playlists
    case playlists                                    case playlistDetail(Int64)   // NEW
    case folders                                      case folders
    case sync                                         case sync
    case sources                                      case sources
    var id: String { rawValue }                       // (rawValue removed — id explicit per case)

                                                      var id: String { switch self {
                                                          case .playlistDetail(let pid):
                                                              return "playlistDetail-\(pid)"
                                                          // ... others as before ...
                                                      } }

                                                      // NEW: manual replacement for CaseIterable
                                                      static let topLevelCases: [SidebarSection] = [
                                                          .library, .playlists, .folders, .sync, .sources
                                                      ]
                                                      // keyboardShortcut now returns KeyEquivalent?
```

label/icon/keyboardShortcut switches all handle `.playlistDetail` (returns empty string, `music.note.list`, and `nil` respectively).

## ContentView route insertion site

`Views/ContentView/ContentView.swift:148-156` — new switch arm between `.playlists` and `.folders`:

```swift
case .playlistDetail(let id):
    PlaylistDetailViewLoader(
        playlistId: id,
        onBack: { selectedSection = .playlists },
        onTrackDoubleClick: { track in
            handleTrackDoubleClick(track)
        }
    )
```

`onBack` routes the user back to the grid (preserves the parent surface for the cancel-style return) and `onTrackDoubleClick` reuses the existing `handleTrackDoubleClick` helper so detail-view track double-clicks open the inspector + auto-play exactly as they do from `LibraryView` / `PlaylistsView` / `FoldersView`.

## PlaylistDetailViewLoader lifecycle

`Views/Playlists/PlaylistDetailViewLoader.swift` — single `Group` with three branches gated by two `@State` vars (`playlist: Playlist?`, `loadFailed: Bool`):

```
.task(id: playlistId)               // fires on appear + on each id change
    loadFailed = false               // reset both before fetch — keeps the
    playlist = nil                   //   loader honest on rapid sidebar
    let repo = container.playlistRepository
                                       //   re-clicks
    let fetched = try await repo.fetch(id: playlistId)
    if let fetched { playlist = fetched }
    else { loadFailed = true }

branches:
    playlist != nil   → PlaylistDetailView(playlist:onBack:onTrackDoubleClick:)
    loadFailed        → triangle icon + "Playlist not found" + Back button
    default           → ProgressView (loading state)
```

Re-fetch on every id change is intentional — a stale `Playlist` snapshot could show old name/cover after a sibling rename. One extra row-read per click is cheap vs. the consistency win.

## DisclosureGroup integration site

`Views/Sidebar/SidebarView.swift:11-66` — body's `ForEach(SidebarSection.topLevelCases)` now branches on `.playlists`:

- `.playlists` → mounts `PinnedPlaylistsDisclosure(topLevelLabel:..., topLevelIcon:..., topLevelSection: .playlists, onUnpin:..., onDelete:..., onRevealInGrid:...)`. The three callbacks live in SidebarView so the disclosure stays presentation-only for non-rename actions; both `onUnpin` and `onDelete` call the repo method then explicitly post `.playlistDidChange` (the repo's `togglePin` / `delete` do NOT post themselves — verified before wiring).
- Other top-level cases (`.library`, `.folders`, `.sync`, `.sources`) keep their existing `HStack + Label + drive-disconnected-dot` layout verbatim.

## AppStorage key + default

| Key | Default | Type | Purpose |
|---|---|---|---|
| `sidebar.pinnedPlaylists.expanded` | `true` | `Bool` | Persists the user's collapse/expand state of the pinned disclosure across app restarts. Default expanded matches D-08. |

## D-11 inline-rename implementation

Three pieces of local state on `PinnedPlaylistsDisclosure`:

```swift
@State private var renamingId: Int64?       // nil = normal mode; set = rename mode for this row
@State private var renameText: String       // bound to the TextField
@FocusState private var renameFocused: Bool // grabs focus on TextField materialise
```

Row flip flow (per row in the ForEach):

```
normal mode (renamingId != pl.id):
    Label(pl.name, systemImage: "music.note.list")
        .tag(SidebarSection.playlistDetail(pl.id ?? -1))
        .contextMenu { ... "Rename…" → startRename(id:, currentName:) ... }
        .help(pl.name)

rename mode (renamingId == pl.id):
    HStack {
        Image(systemName: "music.note.list")
        TextField("", text: $renameText)
            .focused($renameFocused)
            .onSubmit { Task { await commitRename(id: pid) } }
            .onExitCommand { cancelRename() }
            .onAppear { renameFocused = true }
    }
    // NOT tagged — prevents selection swallow during edit
```

Commit path (`commitRename`):

```
trim whitespace
guard !empty && trimmed != currentName  // silently close on no-op
try await container.playlistRepository?.rename(id: id, name: trimmed)
NotificationCenter.default.post(name: .playlistDidChange, object: nil)
// .playlistDidChange → disclosure's .onReceive → loadPinned() → row updates with new name
renamingId = nil; renameText = ""; renameFocused = false
```

No grid redirect anywhere in this flow. Matches CONTEXT.md D-11's "funktional vollständig — keine künstliche Minimal-Variante" clause precisely.

## Verification

| Gate | Result |
|---|---|
| `swift build` | exits 0 |
| `swift test` (full suite) | **116/116 green** (no regression — Plan 36-01 + 36-02 tests all pass) |
| `grep -c 'case playlistDetail' ContentView.swift` | 1 (the enum case declaration) |
| `grep -c 'topLevelCases' ContentView.swift` | 2 (definition + doc-comment reference) |
| `grep -cE 'CaseIterable' ContentView.swift` | 2 — both inside `///` doc comments, NOT on the enum declaration |
| `grep -c 'allCases' SidebarView.swift` | 1 — inside `//` comment explaining the migration, NOT in active code |
| `grep -c 'topLevelCases' SidebarView.swift` | 2 (comment + active iteration) |
| `grep -c 'PinnedPlaylistsDisclosure' SidebarView.swift` | 2 (comment + mount site) |
| `grep -c 'DisclosureGroup' PinnedPlaylistsDisclosure.swift` | 2 |
| `grep -c 'sidebar.pinnedPlaylists.expanded'` | 1 |
| `grep -c 'SidebarSection.playlistDetail' PinnedPlaylistsDisclosure.swift` | 2 (doc comment + active tag) |
| `grep -c 'No pinned playlists'` | 2 (doc + active Text) |
| `grep -c '@State private var renamingId'` | 1 |
| `grep -c 'playlistRepository?.rename(id:'` | 1 |
| `grep -c '@FocusState'` | 1 |
| `grep -c 'TextField' PinnedPlaylistsDisclosure.swift` | 4 (doc + active) |
| `grep -c 'onExitCommand'` | 2 (doc + active) |
| `grep -c 'onReceive…playlistDidChange'` | 1 |
| `grep -c 'onRename:' SidebarView.swift` | 0 (rename is internal to the disclosure — D-11 correct) |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] MLMApp.Navigate menu also iterated `SidebarSection.allCases`**

- **Found during:** Task 1, after dropping CaseIterable from the enum.
- **Issue:** Removing `CaseIterable` broke not just `SidebarView` (expected — Task 2 fixes it) but ALSO `App/MLMApp.swift:43` (`ForEach(SidebarSection.allCases) { section in ...keyboardShortcut(section.keyboardShortcut) }`). The plan's `<read_first>` list mentioned `SidebarView.swift` but did not flag this second call site.
- **Fix:** Swap `.allCases` → `.topLevelCases`; safe-unwrap the now-optional `keyboardShortcut` with a `"0"` sentinel (the sentinel never actually fires because only top-level cases — all with a non-nil shortcut — appear in the iteration).
- **Files modified:** `macos-app/MLM/App/MLMApp.swift`
- **Commit:** `4d1e4dc` (bundled with Task 1 — without this fix, Task 1 alone wouldn't compile even with Task 2 also applied).

### Plan Expectation Adjustments (not bugs)

**2. [D-EX-01] `keyboardShortcut` widened to `KeyEquivalent?` (was `KeyEquivalent`)**

- **Plan said:** "If `keyboardShortcut`'s return type is non-optional, check whether any caller force-unwraps it. If so, widen to `KeyEquivalent?` and return `nil` for `.playlistDetail`." (Task 1 action step 4.)
- **Reality:** Only one caller exists (`MLMApp.swift:47`) and it does not force-unwrap; widening is a no-op for it after the `?? "0"` sentinel. Widened anyway because returning `KeyEquivalent("\0")` or similar dummy from the new case would be semantically misleading.
- **No code-level fix needed:** the plan explicitly anticipated this.

**3. [D-EX-02] `id` switch made explicit per-case (no `rawValue`)**

- **Plan said:** Rewrite `var id: String` to handle the payload.
- **Implementation choice:** Dropped the `String` raw type entirely (the enum no longer needs `String` as raw — `id` is computed per-case and `Identifiable.id` returns a `String`). Drops one layer of synthesised-but-now-unused conformance.
- **No code-level fix needed:** identical observable behaviour, cleaner declaration.

## Stub Tracking / Known Stubs

None. All new code paths have real consumers:
- `PinnedPlaylistsDisclosure` → mounted by `SidebarView` for the `.playlists` row
- `PlaylistDetailViewLoader` → routed from `ContentView.detailView`'s `.playlistDetail(Int64)` case
- `SidebarSection.playlistDetail(Int64)` → produced by `PinnedPlaylistsDisclosure`'s tag, consumed by `ContentView`'s switch
- `SidebarSection.topLevelCases` → consumed by `SidebarView`, `MLMApp` Navigate menu

No empty/mock data paths. The pinned-list loader gracefully renders the empty-state caption when `pinnedPlaylists.isEmpty` is true (this is correct behaviour, not a stub).

## Threat Flags

None. The plan's `<threat_model>` covers T-36-13..T-36-16 — no new surface introduced beyond what was anticipated:
- `.playlistDetail(Int64)` payload: id is DB-sourced; non-existent ids surface as "Playlist not found" via the loader (T-36-13 mitigated by design).
- Pinned-list reload: bounded by `prefix(8)`, single SELECT — accept disposition holds (T-36-14).
- `.help(pl.name)` tooltip: just the playlist name, already visible (T-36-15 accept holds).
- Inline rename TextField: trims whitespace, rejects empty/unchanged names locally; repo's `rename` is parameterised SQL (T-36-16 mitigation upheld).

No network endpoints, no auth paths, no schema changes.

## TDD Gate Compliance

Plan 36-04 is NOT marked `type: tdd` in the frontmatter (it's a UI-routing plan, not a behaviour plan), and both tasks have `type="auto"` without `tdd="true"`. No RED/GREEN gates expected. The existing 116-test suite serves as the regression gate — all green.

## Auth Gates / Manual Steps

None. Fully autonomous execution.

## Decisions Made

- **D-EX-01:** `MLMApp.Navigate` menu must also swap `allCases` → `topLevelCases`; the loss of `CaseIterable` was not local to SidebarView.
- **D-EX-02:** `keyboardShortcut` returns `KeyEquivalent?` (was non-optional); only `MLMApp.Navigate` reads it.
- **D-EX-03:** `SidebarSection` no longer carries a `String` raw type — the `id` computation is explicit per-case so the raw-type machinery is unused weight.
- **D-EX-04:** `onUnpin` and `onDelete` callbacks live in SidebarView; rename stays inside `PinnedPlaylistsDisclosure`. Split reasoning: rename owns local `@FocusState` + TextField state that must live where the row is rendered; unpin/delete are stateless one-shots that fit naturally as call-site closures.
- **D-EX-05:** SidebarView posts `.playlistDidChange` explicitly after `togglePin` / `delete` because the repo methods do NOT post themselves (verified via grep of `PlaylistRepository.swift`). Without these explicit posts, the disclosure would not refresh after the action.

## Plan-Level Decision Citations Coverage

- **D-07 (Sidebar pinned-only surface):** `PinnedPlaylistsDisclosure.loadPinned` filters `isPinned == 1`, `prefix(8)` — no Recent list, no full list. ✓
- **D-08 (DisclosureGroup default-expanded + AppStorage):** `@AppStorage("sidebar.pinnedPlaylists.expanded") = true` drives `DisclosureGroup(isExpanded:)`. Native macOS persistence. ✓
- **D-09 (Direct-to-Detail routing):** `Label.tag(SidebarSection.playlistDetail(pl.id))` → `List(selection:)` binding → `ContentView.detailView` switch → `PlaylistDetailViewLoader` → `PlaylistDetailView`. Zero grid intermediary. ✓
- **D-11 (Sidebar context-menu fully functional):** All four entries wired — Unpin (repo.togglePin + post), Rename (inline TextField + onSubmit → repo.rename + post), Reveal in Grid (selectedSection = .playlists), Delete (repo.delete + post, .destructive role). Inline rename is the BLOCKER FIX — no grid redirect. ✓

## Self-Check: PASSED

Verified files exist and commits are present.

Files:
- macos-app/MLM/Views/ContentView/ContentView.swift — modified (4d1e4dc)
- macos-app/MLM/App/MLMApp.swift — modified (4d1e4dc)
- macos-app/MLM/Views/Playlists/PlaylistDetailViewLoader.swift — created (4d1e4dc)
- macos-app/MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift — created (9897c10)
- macos-app/MLM/Views/Sidebar/SidebarView.swift — modified (9897c10)

Commits:
- 4d1e4dc — feat(36-04): extend SidebarSection enum with .playlistDetail + add PlaylistDetailViewLoader
- 9897c10 — feat(36-04): add PinnedPlaylistsDisclosure with inline rename + integrate into SidebarView

Build + tests:
- swift build — exits 0
- swift test — 116/116 green (no regression)
