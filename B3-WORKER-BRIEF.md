# B3 — standing brief for every worker

You are implementing one work package of the approved redesign of MLM, a native macOS music library manager (SwiftUI + some AppKit, SwiftPM package, GRDB/SQLite, deployment target macOS 27, Swift 6.4, no Xcode project; the app bundle and its Info.plist are assembled by `scripts/run.sh`). The coordinator's message names your package, branch, files and acceptance checklist. This file holds everything that is the same for every package. Read it completely before you start.

## 1. Where the truth is

1. `CLAUDE.md` and `UI-CONVENTIONS.md` — the binding rulebook (rule IDs `UC-<AREA>-<nn>`; §22 "Never" is the review checklist; §23/§24 resolved contradictions and conventions set there).
2. `design/b1/THOUGHTS.md` — the design. **§10 "Oliver's answers" is binding and overrides everything else, including the mockups** (Space = preview only, never Play/Pause; macOS 27 only, Liquid Glass APIs unconditional, no `#available`; Activity = toolbar item + popover + window).
3. `design/b1/*.html` — mockups: rules, copy, order, states. Read the page source; element annotations (what / why / DEC / SwiftUI API) live in data attributes and `design/b1/assets/app.js`; `design/b1/assets/AUTHORING.md` explains the structure. The HTML/CSS is not a code template.
4. `design/b1/COVERAGE.md` — every inventory ID and what became of it: your scope checklist.
5. `design/inventory/*.md` — today's code per surface with file:line and the known problems (`PP-…`).
6. `B3-PLAN.md` — packages, the migration register (§3), implementation decisions `IMP-nnn` (§4), open questions (§5), and the wave log (§6) with **the contracts of every merged package**.

Where something is genuinely unspecified, choose the option most consistent with the principles (THOUGHTS §2) and the nearest pattern page, and list it in your report as a proposed `IMP` (question · choice · why · affected IDs). If an implementation finding contradicts a decision (an API does not exist on macOS 27 as assumed, a data-model limit), stop that part, describe the conflict and your recommendation in the report, and continue with the rest. Verify SwiftUI/AppKit API facts against the macOS 27 SDK interfaces (`$(xcrun --show-sdk-path)/System/Library/Frameworks/…/*.swiftinterface`) before building on them.

## 2. Contracts you build on (do not re-implement; read their doc comments)

| Need | Use |
|---|---|
| Navigation, pushed details, back/forward | `MLM/Views/Shell/NavigationModel.swift` (`SidebarDestination`, `DetailRoute`, `NavigationModel`), `DestinationView.swift` (`RouteView`) |
| Page frame: banner, header, scope bar, content, selection bar, status bar | `MLM/Views/Shell/ContentScaffold.swift`; scope bars: `ScopeBar.swift` (publishes View ▸ Filter) |
| Status-bar text and transient confirmations | `StatusBarCenter` (`.statusBarText`, `post(_:actions:)`) |
| Undo (one gesture = one step, status-bar `Undo`) | `MLM/Views/Shell/UndoCenter.swift` (`perform`, `performGroup`, `record`); existing undoable edits in `ShellEdits.swift` |
| Track lists (table, columns, sort, selection, context menu, keys, preview, drag source, selection bar) | `MLM/Views/TrackList/` — `TrackListTable(model:configuration:)`, `TrackListModel`, `TrackListConfiguration`, `TrackMenu` / `TrackMenuModel` / `TrackMenuActions`, `TrackListActions`; selection bar: wrap the scaffold with `.hostsTrackSelectionBar()` and pass `TrackSelectionBar()` |
| Track state words, availability, drive state | `TrackAvailability`, `TrackRowPresentation`, `LibraryDriveState`; scoped SQL counts in `MLM/Database/TrackScopeQueries.swift`; failure reasons in plain words: `DownloadFailureReasonText` |
| Menu bar | `MLM/App/Commands/MenuCatalog.swift` — an item of your package is switched from `.pending(owner:reason:)` to `.app` and wired in the menu's `Commands` file; selection commands read `FocusedValues.trackSelection` |
| Background jobs | `MLM/Services/Activity/ActivityCenter.swift` (`begin(…)` → handle; lanes; drive waits; `echo(for:)` for the inline echo) — every job that can take longer than ~2 s registers |
| Playback, queue, preview | `PlaybackViewModel` (`playTrack`, `playNext`, `addToQueue`, queue editing API), `playback.preview` (`PreviewCandidate`), `TrackCommandActions` |
| Search / in-place filter | `SearchPlace` + `SearchCoordinator.filter(for:)`, `SearchFilter` (`matches`, `matchesName`), `QuickAddRouter` |
| Drag & drop | `MLM/Services/DragDrop/` (`TrackDragItem`, `PlaylistDragItem`, `DropRules`), `.dropTarget(_:sayRefusal:)` in `MLM/Views/DragDrop/DropTargetModifier.swift` |
| Tag edits that may reach files | `TrackTagEdit.live(undo:).perform(…)` (`MLM/Services/Tags/`); writing is off unless the user enabled it |
| Settings deep links | `openSettings(tab:)`, `SettingsTab` (`MLM/Views/Settings/SettingsTab.swift`) |
| Notifications | `.trackMetadataDidChange` (tag/metadata edits), `.libraryFilesDidChange` (files added/moved/re-pointed — triggers a full file check), `.trackAvailabilityDidChange`, `.playlistDidChange`, `.libraryDidDeleteTracks` |
| Spacing | `MLM/Views/Shell/Spacing.swift` |

## 3. Non-negotiables

- **The design is decided.** Implement it; do not redesign.
- **Native macOS, system first:** semantic colours (`.primary/.secondary/.tertiary/.tint`; system red/orange only as a symbol tint for failure states, with text carrying the meaning), system materials, system fonts, native containers (`NavigationSplitView`, `Table`, `List`, `Form`, `.inspector`, `Settings`), SF Symbols. No custom palette, no hex colours, **no `mlm*` colour tokens or custom fonts in new or rebuilt code** — replace them where you rebuild a file. Source brand colours only as the 6 pt dot.
- **Native toolbar stays;** one main `Window`; auxiliary windows only Settings, Activity, Help ▸ Keyboard Shortcuts. No floating panels, no overlays, **no toasts** — confirmations go to the status bar.
- **Liquid Glass:** the selection bar is the only custom glass surface. Never glass or material on content. No `#available`.
- **Critical states are text;** exact vocabulary from `UI-CONVENTIONS.md` §15–§17. English UI only, no emoji, no German strings, Title Case for buttons and menu items, `…` only where a dialog or sheet follows, typographic quotes around names, `Show in Finder` (never "Reveal").
- **Space is preview only** on a focused track list; Space and plain Return are never menu key equivalents; no app-wide key monitors.
- **Nothing moves unless asked (P3):** playing, adding, dropping or finishing a job never navigates, never opens a panel, never steals focus.
- **Reversible by default (P8):** undoable actions go through `UndoCenter` without a confirmation; irreversible ones (Trash, Remove from Library, restore, relaunch, sign-out) get a consequence-stating alert with Cancel as the default button and the destructive role on the destructive button.
- **Offline is normal (P6):** with the library drive not connected, browsing/editing/queueing works; file actions are disabled with the reason; nothing is marked failed or missing because of the drive; work that needs the drive waits.
- **Data safety:** foreign keys stay disabled (test-locked) — write manual cascades. Every schema change is exactly the new numbered GRDB migration assigned to your package in `B3-PLAN.md` §3 (register it after the latest existing migration; never edit an existing one; pre-migration backups must keep working). Never read `~/Library/Application Support/MLM/.env` or anything under `~/Library/Application Support/com.musiclibrary.app/`. Never touch the live library, a live database or `/Volumes/Lexxar`. Tests use temporary databases, temporary folders, an injected `UserDefaults` suite, fakes for network/audio — no test hits the network or the real audio device.
- **No app launch, no screenshots, no AppleScript / UI scripting.** Verify by `swift build` and `swift test` only.
- **Fix — don't port — known logic bugs** on the surfaces you touch (the `PP-…` registers), and say so.
- **Every feature reachable before stays reachable** unless the design removes it (name the design ID). No dead (enabled but inert) controls or menu items; menu-bar items never disappear (disabled with a reason instead); context menus never show placeholders.
- **Tests must not be load-sensitive:** injectable clocks/sleeps, no tight wall-clock assertions, no reliance on `NotificationCenter.default` traffic from other suites (inject a center or filter by your own objects), helpers that wait must fail on timeout.
- **Git:** work on the branch named in your brief, created from `redesign/b3`; small commits that each build and pass their tests, in the repo's style (`feat(scope): …`, `fix(scope): …`, `refactor(scope): …`, `test(scope): …`, `docs(scope): …`). **No `Co-Authored-By` lines, no "Generated with" lines.** Never push. Never commit to `main`, never touch tag `v0.9`. If `redesign/b3` moves while you work and the coordinator tells you, `git merge redesign/b3` into your branch and resolve conflicts keeping both sides' intent.
- **Shared files** — `MLM/App/MLMApp.swift`, `NavigationModel.swift`, `DependencyContainer.swift`, `DatabaseManager.swift`, `Notifications.swift`, `MenuCatalog.swift`, `SidebarView.swift`, `ContentView.swift` — get only the small, additive edits your package needs; say exactly what you changed there.
- **Snapshot inventory:** `MLMTests/Snapshots/SnapshotHarnessTests.swift` + `SnapshotFixtures.swift` count the production view files. Register every view file you add or remove and report your new counts (other branches change them too). Do not record snapshots.

## 4. Verification you must run and report

1. `swift build` — no new warnings in files you added or rebuilt.
2. Full `swift test`, **twice**. It prints two runner summaries (Swift Testing and XCTest): report both lines for both runs, and name the suites you added or changed with their state. If a test fails, rerun its suite alone and report both results; never edit a test that is not yours to make it pass without saying so.

## 5. Report format (your final message)

1. Branch and commit list (hash + subject).
2. What was built, per design ID / rule ID (for area packages: go through the `COVERAGE.md` rows of your surfaces — implemented / removed by design / owned by ‹package›).
3. Contracts for later packages: file paths, public API, how to adopt.
4. Migration: exact DDL, backfill, tests (if any).
5. Logic bugs fixed (`PP-…`), removed code, tests ported or dropped (and why).
6. Sentences you introduced that are not verbatim in `UI-CONVENTIONS.md` or the mockups.
7. Deviations with reason; proposed `IMP` decisions; any conflict with a `DEC`; edits to shared files; new snapshot-inventory counts.
8. What the owner should check in the running app (he is the only one who can see it).
9. Verification output.
