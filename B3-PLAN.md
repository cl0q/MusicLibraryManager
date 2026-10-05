# B3 — Implementation plan for the approved redesign

**Branch:** `redesign/b3` (off `main` @ `91b4463`, tag `v0.9` = pre-redesign return point).
**Spec:** `design/b1/THOUGHTS.md` (§10 binding) + mockups in `design/b1/` + `design/b1/COVERAGE.md` (definition of done).
**Rules for every agent:** `UI-CONVENTIONS.md`, `CLAUDE.md`.
**Coordinator prompt:** `B3-FABLE-PROMPT.md`.

Status words: `planned` · `in progress` · `in review` · `merged` · `blocked` · `deferred`.

---

## 0. Baseline (2026-10-05, commit `c10493f`)

- `swift build`: clean (warnings only; after the bump to macOS 27 additional deprecation warnings in `AudioPlayer.swift`, `ReelsInboxView.swift`).
- `swift test`: Swift Testing **1604 tests in 155 suites passed**; XCTest **14 tests, 3 skipped, 0 failures**. Network-dependent tests log warnings (SoundCloud/DAB/Squid unreachable) but pass.
- Snapshot tests run only with `MLM_SNAPSHOTS=1`; 60 baselines (+1 file) under `MLMTests/Snapshots/__Snapshots__/macos27-arm64` describe the **old** UI.
- Toolchain: Swift 6.4, macOS 27.0 SDK, host macOS 27.0.

## 1. Working rules

- One work package = one worker = one branch/worktree `b3/<package-id>` off `redesign/b3`; the coordinator merges in dependency order after review (diff against acceptance checklist + conventions; `swift build` + `swift test` on the merge result).
- **Worker models (Oliver, 2026-10-05):** Opus 5.5 or cheaper. Opus for design-heavy and risky packages and for independent reviewers; Sonnet for mechanical/conformance packages.
- Risky logic (playback queue, sync, migrations, tag writing, Trash) gets a second, independent reviewer that receives code + spec, not the coordinator's conclusion.
- Shared files are edited only by the package that owns them or by the coordinator: `MLM/App/MLMApp.swift` (scenes, commands), the navigation model, `DependencyContainer.swift`, `DatabaseManager.swift` (migration registration), `Notifications.swift`.
- Migrations: numbers are reserved in §3; a package registers only its own number. Never edit an existing migration. Foreign keys stay disabled (manual cascades).
- No app launch, screenshots or AppleScript by agents. Oliver does the visual check after each wave from the checklist the coordinator sends.
- The branch builds and the app stays usable after every merge; a half-migrated surface stays behind its old entry point.

## 2. Waves and work packages

### Wave 0 — Preparation (coordinator)

| ID | Package | Owner | Status |
|---|---|---|---|
| W0-1 | Branch `redesign/b3`, commit design packet | coordinator | merged (`c10493f`) |
| W0-2 | Baseline build + tests recorded (§0) | coordinator | merged |
| W0-3 | B2: `UI-CONVENTIONS.md`, `CLAUDE.md`, superseded banner on `UI-GROUNDTRUTH.md` | worker (Opus) | merged |
| W0-4 | Deployment target macOS 27 (`Package.swift`, `scripts/run.sh` `LSMinimumSystemVersion`) | coordinator | merged (`a39fe32`) |
| W0-5 | Snapshot baselines: old baselines deleted, re-record per wave for finished surfaces | coordinator | merged |
| W0-6 | This plan | coordinator | merged |

### Wave 1 — Shell (sequential, one worker, then independent review)

Spec: `shell.html`, THOUGHTS §3, §7.1. Inventory: `design/inventory/shell.md`, `main.md`.

| ID | Package | Depends on | Status |
|---|---|---|---|
| W1-1 | **Navigation model + sidebar + toolbar + scaffolding.** `SidebarDestination` + `NavigationStack` path (back/forward, ⌘[ ⌘]); sidebar sections Library · Inbox · Playlists · Sync, library footer (P-LIBFOOTER); constant toolbar (sidebar toggle, back/forward, Add menu skeleton, player in `.principal`, Activity item placeholder, inspector toggle, `.searchable`); system `.inspector` hosting the existing track detail (Info) and queue view (Queue) as modes; content scaffold (banner slot, scope-bar slot, status bar P-STATUSBAR with transient message API + Undo button, selection-bar slot); window title/subtitle; existing views re-hosted. Bottom Activity panel stays reachable until W3-ACT. | W0-3 | merged (`bee105f` + review fixes) |
| W1-2 | **Settings scene + commands skeleton.** SwiftUI `Settings` scene hosting the existing panes (replaces the AppKit window; deep-link binding); `.commands` with the DEC-038 menu structure and `FocusedValue`-driven enabling (items whose feature arrives later are present and disabled only if their target wave is noted in the plan — no dead items at the end); ⌘1…⌘6; removal of window-wide arrow-key seek monitor and the app-wide ⌘F monitor. | W1-1 | merged (+ review fixes) |

Contracts W1 must publish (file paths recorded here when merged): navigation model, `StatusBarCenter` (transient message + Undo), content scaffold view, focused-value keys for selection/commands, Settings deep link.

### Wave 2 — The daily loop (mostly sequential around the shared track table)

Spec: `library.html`, `player.html`, `queue.html`, `inspector.html`, `search.html`, `patterns-context-menus.html`, `patterns-dnd.html`. Inventory: `library.md`, `main.md`, `inspector.md`.

| ID | Package | Depends on | Migration | Status |
|---|---|---|---|---|
| W2-F | **Undo infrastructure + status-bar confirmation API** (DEC-041, DEC-016) — contract first, used by everything after | W1 | — | in review — merged, independent review running |
| W2-A | **Track table component + persisted availability** (DEC-012, DEC-014, DEC-051): column set + `TableColumnCustomization`, sortable Status, in-place refresh, `contextMenu(forSelectionType:primaryAction:)`, type-select; availability persisted, refreshed by scans and mount events; `MountObserver` wired for folders set after launch; drive-not-connected window banner | W1 | `v42_track_availability` | in progress (Opus, `b3/w2-a-track-table`) |
| W2-B | **All Tracks** (DEC-002, DEC-011, DEC-013): availability scope bar with live counts, no-album rendering, status bar counts | W2-A | — | planned |
| W2-C | **Playback** (DEC-008, DEC-009 as revised by §10 Q1, DEC-010, DEC-045, DEC-047): Return/double-click = play only; Space = preview only with the toolbar player's Preview state and resume; player state words; queue skips unplayable tracks (PP-MAIN-01); volume persisted; arrow-seek only during preview; media keys keep working | W2-A | — | planned |
| W2-D | **Queue panel** (DEC-006): Now playing / Next / History, reorder, remove, clear, save as playlist, persisted across relaunch | W2-C, W2-F | `v43_playback_queue` | planned |
| W2-E | **Inspector** (DEC-007): `Form`, tabs Details · Audio · File, follows selection, multi-edit with `Mixed`, commit keyed to the selection (PP-INSPECTOR-04), tag writing to files by default, queued while the drive is away | W2-A, W2-F | `v44_pending_tag_writes` | planned |
| W2-G | **Selection bar** (DEC-015, the one custom glass surface) + batch actions | W2-A, W2-F | — | planned |
| W2-H | **Drag & drop** (DEC-040): `Transferable` with internal IDs + file URLs; sidebar rows accept drops | W2-A, W2-G | — | planned |
| W2-I | **Search** (DEC-017, DEC-018): filter in place, scopes `This view · Library · Online`, tokens, link detection → quick add entry; online results never auto-saved (PP-MAIN-04); delete `UniversalSearchView` | W2-B | — | planned |

Parallelism: W2-F first (small). W2-A alone. Then W2-B ‖ W2-C ‖ W2-E (disjoint directories: Library / Player+Playback / TrackDetail). Then W2-D ‖ W2-G, then W2-H ‖ W2-I.
Independent review: W2-A (migration), W2-C + W2-D (queue logic), W2-E (tag writing).

### Wave 3 — Areas (parallel workers, disjoint directories)

| ID | Package | Spec | Inventory | Migration | Status |
|---|---|---|---|---|---|
| W3-PL | Playlists: sidebar playlists + playlist folders + manual order, All Playlists grid, detail header / More / status sentence / failed scope, `Refresh from ‹Source›`, link + M3U sheets (PP-PLAYLISTS-01) | `playlists.html` | `playlists.md` | `v45_playlist_folders` | planned |
| W3-FOLD | Folders: hierarchical table, path bar, not-in-library files, import as Activity operation | `folders.html` | `library.md`, `main.md` | — | planned |
| W3-ACT | Activity: one operation registry for every job of inventory §10.1 (DEC-044), toolbar item states, popover, Activity window (Operations + Logs), results persisted; then remove the bottom panel | `activity.html` | `activity.md` | `v46_activity_operations` | planned |
| W3-LAUNCH | Launch & libraries: library picker with per-row states, loading phases, failure actions, adoption sheet, switch alert listing running work, in-window setup; library-file icon (variant A `.icns`, wired in `scripts/run.sh`) | `launch.html`, `library-icon.html` | `shell.md` | — | planned |
| W3-SET | Settings: eight tabs, backup schedule/retention (DEC-036), Sources accounts in place, download-tools status (DEC-037), deep links | `settings.html` | `settings.md` | — | planned |
| W3-ADD | Add & import: Add menu, Add from Link (⌘U), S-IMPORT sheet replacing the remote-playlists window, `Refresh from Sources`; imports queue instead of being rejected | `import.html` | `sources-review.md`, `main.md` | — | planned |
| W3-SYNC | Sync: profiles as sidebar rows, detail Content · Plan (incl. Skip) · Options · Last sync, per-profile results (PP-SYNC-01/02), device-removed handling, merged device-changes sheet, Eject | `sync.html` | `sync.md` | `v47_sync_profile_results` | planned |
| W3-REV | Review: duplicates with real consequences and bulk apply (DEC-028), conflicts, resolved; decisions stick across rescans (PP-SOURCES-01) | `review.html` | `sources-review.md` | `v48_review_decisions` | planned |
| W3-DISC | Discover: recommendations held out of All Tracks until kept (model flag), keyboard triage, Reels workbench, Similar as pushed view without the dangerous delete | `discover.html` | `discover.md` | `v49_pending_recommendations` | planned |
| W3-GEN | Genres: list + detail with suggestions, merge and Create ML export sheets; Genre Workshop leaves Settings | `genres.html` | `inspector.md`, `settings.md` | — | planned |

Order inside the wave: W3-ACT first or in the first batch (others register operations through its registry; until it lands they use the registry protocol stub the coordinator defines up front). Sidebar/commands edits needed by a package are made by the coordinator at merge time. Batches of at most 4 parallel workers.
Independent review: W3-SYNC, W3-REV (Trash), W3-ACT (persistence), all migrations.

### Wave 4 — Albums (Track C1 + C2, UI half of C3)

| ID | Package | Migration | Status |
|---|---|---|---|
| W4-1 | `album_tracks` join (disc, position) seeded from tags; album dedup pass (DEC-019) | `v50_album_tracks`, `v51_album_dedup` | planned |
| W4-2 | Album grid (V-ALB) + album detail (V-ALBD): fixed order, edition picker wired to `user_album_variant_pref`, edit-order mode, Go to Album links (DEC-020) | — | planned |
| W4-3 | Review ▸ Albums UI + `No album` confirmation; stop the source-as-album writes (C3). Backfill lookup only after Oliver confirms the metadata source | `v52_album_suggestions` | planned |

### Wave 5 — Conformance

| ID | Package | Status |
|---|---|---|
| W5-1 | Walk `COVERAGE.md` ID by ID + pattern pages; unify remaining sheets/alerts/menus/shortcuts/states | planned |
| W5-2 | Complete menu bar and Dock menu; three TipKit tips | planned |
| W5-3 | Accessibility pass (keyboard-only, VoiceOver labels, Reduce Transparency/Motion) | planned |
| W5-4 | Remove dead code, every `mlm*` colour token (25 tokens, ~1,300 uses today), German strings, banned words | planned |
| W5-5 | Re-record snapshot baselines; update `ROADMAP.md`, `UI-CONVENTIONS.md`; write `B3-CONFORMANCE.md` | planned |

## 3. Migration register

Latest existing: `v41_remote_provider_identity`. Reserved (a number is only used by its package; unused reservations are released, never reused for something else once shipped):

| Number | Package | Purpose |
|---|---|---|
| v42 | W2-A | Persisted track availability |
| v43 | W2-D | Persisted playback queue |
| v44 | W2-E | Pending tag writes (queued while the drive is away) |
| v45 | W3-PL | Playlist folders + manual playlist order |
| v46 | W3-ACT | Persisted Activity operations/results |
| v47 | W3-SYNC | Per-profile sync results |
| v48 | W3-REV | Sticky review decisions |
| v49 | W3-DISC | Pending-recommendation flag |
| v50 | W4-1 | `album_tracks` |
| v51 | W4-1 | Album dedup |
| v52 | W4-3 | Album suggestions / confirmed `No album` |

## 4. Decisions during implementation

| ID | Question | Choice | Why | Affected |
|---|---|---|---|---|
| IMP-001 | Which models run the workers? | Opus 5.5 at most; Sonnet for mechanical packages | Oliver, 2026-10-05 (cost) | all packages |
| IMP-017 | Undo contract details not fixed by UC §13 | Action names `New Playlist`, `New Playlist from Selection`, `Rename Sync Profile`; a failed undo/redo drops the step and posts `Couldn’t undo ‹action› — ‹cause›`; the status-bar `Undo` only acts while its step is on top of the stack; a restore that can't be exact (name taken, tracks gone) posts a note without `Undo`; adding only tracks already present registers no step (`All 3 tracks were already in “X”`); undo steps are scoped to the library id and dropped when the main window closes | Smallest behaviour consistent with UC-UNDO-08/09 and P8 | `UndoCenter`, all later packages |
| IMP-018 | New Playlist from Selection | No sheet: the playlist is created with the selection in display order and named inline in the sidebar; the window does not navigate | S-SEL-NEWPLAYLIST on `patterns-sheets-alerts.html`; P3 | S-SEL-NEWPLAYLIST |
| IMP-019 | Playlist names | One name space in the sidebar: rename refuses a name another playlist already has in any letter case | Avoids two rows reading the same | P-SIDEBAR |
| IMP-012 | Closing the main window | Does not quit (UC-WIN-01); every library flow, the Dock icon and Window ▸ MLM bring the one main window back | Convention; needed for the Activity and Settings windows to outlive the main window | W-MAIN, AppDelegate |
| IMP-013 | `InspectorCommands` | Not used: Info and Queue are two modes of one inspector with their own View-menu items (⌘I, ⌥⌘U); the system group would add a mode-less toggle on ⌃⌘I | One meaning per command | M-VIEW |
| IMP-014 | ⌫ in menus | Edit ▸ Delete and Remove from ‹Container› carry no ⌫ key equivalent; ⌫ is handled by the focused list (`onDeleteCommand`, W2-A) | A plain-⌫ menu key equivalent would take backspace from text fields | M-EDIT, M-TRACK, K-* |
| IMP-015 | Pending commands | Menu-bar items of later packages exist, disabled, with a user-facing help reason; one catalog (`MLM/App/Commands/MenuCatalog.swift`, `wiring = .pending(owner:reason:)`) is the checklist — a package wires its commands by switching them to `.app` | UC-MENU-02 (items never disappear), no dead items | all later packages |
| IMP-016 | Volume step for ⌘↑ / ⌘↓ | 0.1 (ten steps) | Unspecified; matches Music | M-PLAYBACK |
| IMP-004 | Back/Forward scope | Each sidebar destination keeps its own pushed path for the session; Back/Forward act only on pushed details; re-selecting the current row pops to root; a new push clears Forward | UC-TB-01 "pushed details"; Finder/Music behaviour | `NavigationModel`, all pushed routes |
| IMP-005 | Library name when no library file exists (legacy layout) | `MLM` | The only name such an install has until adoption | subtitle, P-LIBFOOTER |
| IMP-006 | Sidebar symbols (not specified in B1) | All Tracks `music.note`, Albums `square.stack`, Genres `guitars`, Review `checklist`, All Playlists `square.grid.2x2`, playlist `music.note.list` (Liked `heart`), sync profile `externaldrive`, footer `music.note.house` | Symbol choice was explicitly outside the B1 review | P-SIDEBAR |
| IMP-007 | Sync row for a connected, never-synced profile | `Connected` | The §15.8 word | P-SIDEBAR.N05–N08 |
| IMP-008 | Status-bar copy without a verbatim pattern | `Import started — “‹folder›”`, `Import finished — …`, `Couldn’t create the playlist — ‹cause›`, `Rockbox device detected — device defaults applied` (was a toast) | Nearest UC-STATUS-05 shape; toasts are banned | P-STATUSBAR, S-SYNC-TOAST |
| IMP-009 | Temporary homes until wave 3 | Sources page: pushed route `DetailRoute.sources`, reached by Add ▸ / File ▸ Import Playlist from Source… (⇧⌘I); the interim Library ▸ Sources item was removed in W1-2 (not in UC-MENU-05). Activity toolbar item toggles the old bottom panel. Add-menu items New Playlist Folder, Add from Link…, Import M3U…, Refresh from Sources are disabled with help text | Keeps every old feature reachable; removed by W3-ADD / W3-SET / W3-ACT / W3-PL | P-ADDMENU, V-SRC, P-ACTIVITY |
| IMP-010 | `Spacing` / `ShellMetrics` location | `MLM/Views/Shell/Spacing.swift` | `MLM/Theme` holds the tokens that W5 deletes | all packages |
| IMP-011 | Known gaps after W1-1, owned by later packages | Selection text in the status bar and Info following the selection (W2-A/W2-E); mount observer for a folder set after launch (W2-A); playlist row status line beyond sign-in (W3-PL); sync row `· n failed` and `n to add` for all profiles (W3-SYNC); Discover badge incl. reels, Review badge incl. album suggestions (W3-DISC, W4-3); toolbar collapse order UC-TB-03 (W1-2); pin UI in the grid (W3-PL) | Data or component arrives with that package | see packages |
| IMP-003 | Conventions the B1 packet left open (`UI-CONVENTIONS.md` §23 C1–C27 resolutions, §24 S1–S29) | Accepted as written by the coordinator after review; Oliver can overturn any of them by ID | Each follows the principles and the more specific/later pattern page; none changes behaviour Oliver approved in §10 | `UI-CONVENTIONS.md` |
| IMP-002 | Snapshot baselines during B3? | Recommended: delete the 60 old baselines in wave 0, re-record per wave for finished surfaces | They describe the old UI; keeping them makes every snapshot run fail without information | W0-5, W5-5 |

## 5. Open questions for Oliver (raised at the right moment)

| # | Question | When | Status |
|---|---|---|---|
| 1 | Delete the 60 old snapshot baselines now (recoverable from `v0.9`)? | wave 0 | answered 2026-10-05: yes |
| 2 | Album metadata source for the backfill (no MusicBrainz client exists) | before W4-3 lookup | open |
| 3 | Does `Remove from List` in the library picker need a confirmation? | W3-LAUNCH | open |
| 4 | History size of the Activity window | W3-ACT | open |
| 5 | May a partial re-import ever remove tracks from a linked playlist? (design: add-only) | W3-ADD / W3-PL | open |

## 6. Wave log

_(per wave: merged packages with commits, contract file paths, what Oliver should check, feedback by ID)_

### Wave 2

- **W2-F** merged (branch `b3/w2-f-undo`, 7 commits). Tests on the merge result: Swift Testing 1774 tests / 176 suites passed; XCTest 14 tests, 3 skipped, 0 failures. Independent review running.
- **W2-F contract:** `MLM/Views/Shell/UndoCenter.swift` (`UndoCenter.perform` / `performGroup` / `record`, `FocusedValues.undoCenter`, usage example in the file's doc comment), `MLM/Views/Shell/ShellEdits.swift`, `PlaylistRepository` undo section (snapshot / restore / exact-row helpers). Adoption owed: W2-A (context menu add-to-playlist, remove from playlist), W2-D (queue edits), W2-E (tag edits), W2-G, W2-H, W3-PL, W3-SYNC, W3-REV, W3-DISC, W3-GEN, W4-2.
- Open: ⌘⌫ on the destructive button of the sidebar delete alerts (UC-KEY-34) is not set — decide after Oliver has tried the `Remove from Library…` alert (key-repeat risk).

### Wave 1

- **W1-1** merged `bee105f` (branch `b3/w1-1-shell`, 4 commits). Tests on the merge result: Swift Testing 1633 tests / 159 suites passed; XCTest 14 tests, 3 skipped, 0 failures. Independent review: 1 blocker (B1 sync profile page vs `selectedProfile`), 11 should-fix; fix round merged (5 commits: sync page agreement B1, search pane above pushed details, one meaning for ⇧⌘I/⌘N, drive Try Again through the mount path, sidebar reload ordering, empty Sync section, sign-in line, gated ⌘R). Tests on the merge result: Swift Testing 1658 tests / 164 suites passed; XCTest 14 tests, 3 skipped, 0 failures.
- **W1-2** merged (branch `b3/w1-2-settings-commands`, 7 commits). Tests on the merge result: Swift Testing 1705 tests / 170 suites passed; XCTest 14 tests, 3 skipped, 0 failures. Independent review: 2 blockers (B1 `Remove from Library…` skipped its confirmation for not-downloaded tracks; B2 library flows invisible while the main window is closed), 6 should-fix; fix round merged (7 commits). Tests on the merge result: Swift Testing 1725 tests / 173 suites passed; XCTest 14 tests, 3 skipped, 0 failures. **Wave 1 complete 2026-10-05**; checklist sent to Oliver.
- **W1-2 contracts:** `MLM/App/Commands/MenuCatalog.swift` (every menu item, key, pending owner), `TrackSelection.swift` (`FocusedValues.trackSelection`, `TrackCommandTarget`, `TrackCommandState`), `MLM/Views/Settings/SettingsTab.swift` (`SettingsTab`, `SettingsRouter`, `openSettings(tab:)`), `KeyboardMap` (Help ▸ Keyboard Shortcuts).
- Deferred from the review: a `‹Source› sign-in expired` line for a *rejected refresh token* needs a refresh-failure state in the auth services (W3-SET); only unreadable stored sign-ins show today.
- **Contracts (all under `MLM/Views/Shell/`):** `NavigationModel.swift` (`SidebarDestination`, `DetailRoute`, `NavigationModel`; focused values `navigationModel`, `trailingColumn`, `statusBarCenter`, `shellActions`, `playbackViewModel`), `TrailingColumnState.swift`, `StatusBarCenter.swift` (`post(_:actions:)`, `StatusAction.undo`, `beginLoading`/`endLoading`, `.statusBarText(_:)`), `ContentScaffold.swift` (`ContentScaffold(showsDriveBanner:content:header:scopeBar:selectionBar:)`, `StatusBar`, `DriveBanner`, `LibraryDriveState`), `ShellActions.swift`, `SidebarModel.swift`, `DestinationView.swift` (`RouteView` — add a pushed route here), `Spacing.swift`.
