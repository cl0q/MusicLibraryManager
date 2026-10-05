# App shell, windows, menus, launch & library files

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): APP, WIN, MENU, LAUNCH, LIBFILE, WIZ · Files covered: `MLM/App/MLMApp.swift`, `MLM/App/AppDelegate.swift`, `MLM/App/LibraryCommands.swift`, `MLM/App/DependencyContainer.swift` (UI-relevant parts), `MLM/Views/Shared/LibraryLaunchStateView.swift`, `MLM/Views/Shared/LibraryAdoptionSheet.swift`, `MLM/Views/Shared/NewLibrarySheet.swift`, `MLM/Views/Shared/FirstRunWizard.swift`, `MLM/Services/Library/*` (7 files), `MLM/Services/Mount/MountObserver.swift`, `MLM/Utilities/*` (9 files); plus the launch/library-file wiring inside `MLM/Views/ContentView/ContentView.swift` (root routing, `LibraryFilePresentation`, error/loading views, ⌘F monitor — read for context, shared with main.md)

Reading guide for the designer: MLM has **one main window** (W-MAIN) whose *content* is either the working app (sidebar + detail + toolbar + activity bar, owned by main.md) or one of several **launch states** (no library open, library can't be opened, loading, failed). A "library" is a single file (`.mlibm`, "Library file") that holds the database; only one library is open per process, and **switching libraries quits and relaunches MLM**. Settings and the remote-playlists browser are **separate AppKit windows**. The menu bar is mostly defined in `MLMApp.swift`; several menu items are currently dead (see M-LIBRARY).

---

## Surfaces

### W-MAIN — Main window ("MLM")
- Reached via: app launch (only window created automatically) · Finder double-click on a library file (reuses this window, never opens a second one) · Window menu (system-provided entry, *inferred*) · Leads to: P-SIDEBAR, P-TOOLBAR, P-PLAYER, P-ACTIVITY, P-INSPECTOR, all V-* sections; launch states V-LAUNCH-NOLIB, V-LAUNCH-CANTOPEN, V-LAUNCH-INVALID, V-LAUNCH-LOADING, V-LAUNCH-FAILED; sheets S-ADOPT, S-NEWLIB, S-WIZARD; alerts A-LIB-SWITCH, A-LIB-COPY, A-LIBFILE-CANTOPEN, A-LIBFILE-INVALID.
- Code: `MLM/App/MLMApp.swift:60-76` (scene, size, style), `MLM/App/MLMApp.swift:67-72,197-230` (window-wide ←/→ seek), `MLM/Views/ContentView/ContentView.swift:63-123` (root routing between launch states and the working app), `MLM/Views/ContentView/ContentView.swift:230-284` (working layout, owned by main.md), `MLM/App/AppDelegate.swift:28-60` (launch, open-file, quit-on-last-window).
- Purpose: the one place where Oliver browses, listens and manages his library; before a library is open it shows why not and how to get one.
- User goals:
  1. Open MLM and land in the last library, ready to browse and play — daily.
  2. Keep listening while navigating sections (playback lives in the toolbar of this window) — daily.
  3. Understand at a glance whether the music drive is connected — daily (drive is often unplugged; product fact).
  4. Know which library is open (Main vs. a small dev/subset library on the Mac) — weekly (*inferred* from `todo_dump.md:5` multi-library wish; today the name is not shown in this window).
  5. Switch to another library file (Finder double-click, File menu) — rare.
- What the user wants to see, in priority order:
  1. The library content (tracks / playlists) of the open library.
  2. What is playing and playback controls.
  3. Whether the music drive is connected (affects whether anything can play).
  4. Which library file is open (name), and that it is the intended one.
  5. Background activity (downloads, imports, sync) — via the activity bar.
- Elements today:
  - W-MAIN.E01 Window title `MLM` (scene title; never shows the library name) — `MLM/App/MLMApp.swift:63`.
  - W-MAIN.E02 Unified title bar + native toolbar (`.windowStyle(.titleBar)`, `.windowToolbarStyle(.unified)`) holding P-PLAYER (`.principal`) and the global search field (`.primaryAction`) — `MLM/App/MLMApp.swift:74-75`, `MLM/Views/ContentView/ContentView.swift:254-271`.
  - W-MAIN.E03 Content area: either the working layout (sidebar | detail | optional inspector, activity bar at the bottom, `MLM/Views/ContentView/ContentView.swift:230-284`) or one launch state (see V-LAUNCH-*), decided at `MLM/Views/ContentView/ContentView.swift:64-121`.
  - W-MAIN.E04 Window-wide first-run overlay S-WIZARD (dimmed backdrop over the working layout) — `MLM/Views/ContentView/ContentView.swift:69-86`.
  - W-MAIN.E05 Size: minimum 900×600, default 1200×800 — `MLM/App/MLMApp.swift:66,76`.
- Interactions:
  - Keyboard: K-WIN-SEEKBACK / K-WIN-SEEKFWD (bare ←/→ seek ±5 s with hold-to-repeat, anywhere in the window unless a focused control consumes arrows); all menu shortcuts (M-*); ⌘F focuses global search via an app-wide key monitor (area-local main.md, see index §6.3).
  - Opening a `.mlibm` from Finder while this window shows a library → A-LIB-SWITCH (`MLM/Services/Library/LibraryLaunchCoordinator.swift:217-220`).
  - Closing the window quits MLM when it is the last window (`MLM/App/AppDelegate.swift:58-60`). If Settings or a remote-playlists window is still open, MLM keeps running without the main window (*inferred*; reopening relies on the system Window menu entry SwiftUI adds for `Window` scenes — not verifiable from code, "Unresolved from code").
  - No drag & drop onto the window itself at shell level (see D- section).
- States:
  - default: working layout (`isInitialized == true`).
  - resolving / library loading: V-LAUNCH-LOADING `Loading Library...` (`MLM/Views/ContentView/ContentView.swift:119-120,497-507`).
  - no library: V-LAUNCH-NOLIB. Library unavailable / mismatch: V-LAUNCH-CANTOPEN. Not a valid file: V-LAUNCH-INVALID. Finder copy: A-LIB-COPY (window-content form).
  - legacy install found: empty window background with S-ADOPT on top (`MLM/Views/ContentView/ContentView.swift:97-108`).
  - error: V-LAUNCH-FAILED `Failed to Initialize` (`MLM/Views/ContentView/ContentView.swift:95-96,477-493`).
  - no library folder configured yet: S-WIZARD overlay over the (empty) working layout.
  - drive not connected: no window-level state; only a 7 pt red dot on the sidebar `Library` row with tooltip `Library drive disconnected` (`MLM/Views/Sidebar/SidebarView.swift:135-143`) and a banner inside V-LIB (`MLM/Views/Library/LibraryView.swift:77-89`); playback is paused on unmount (`MLM/Views/ContentView/ContentView.swift:127-133`). See index §8.
  - huge data: V-LIB stays mounted (hidden by opacity) across section switches to avoid a ~0.5 s rebuild of the ~12k-row table (`MLM/Views/ContentView/ContentView.swift:340-352`).
  - background work: shown in P-ACTIVITY only.
- Data scale / performance notes: 12,935 tracks (ROADMAP §1). The hidden-but-alive Library table means its keyboard shortcut (⌘R re-scan) stays active in every section (index §6.3 conflict).
- Pain points today:
  - The open library's name is never shown in this window (title is always `MLM`, `MLM/App/MLMApp.swift:63`); only Settings → Library shows it (`MLM/Views/Settings/LibrarySetupView.swift:23-37`). With multiple libraries (`todo_dump.md:5`) Oliver can't tell which one he is in.
  - Drive-disconnected state is near-invisible outside V-LIB (a colour dot + tooltip; violates "critical states always text" product rule).
  - Root views use custom colours (`Color.mlmBase`) and custom fonts on launch/error views (`MLM/Views/ContentView/ContentView.swift:477-507`), not system appearance.
- Related flows: first-launch, daily-listening, switch-library, drive-unplugged, adopt-legacy (area flow), relaunch (area flow).
- Constraints / locked decisions: single `Window("MLM", id: "main")` scene (A3, `MLM/App/MLMApp.swift:61-63`); native toolbar stays, no `.hiddenTitleBar`, no floating player (ROADMAP §6.2); one active library per process, switching relaunches (A0 D4, ROADMAP A3 decision 1); English only; native macOS look.
- Open questions for the designer:
  - Where (if anywhere) should the open library's name live in the main window (title, subtitle, sidebar header)?
  - Should launch states (no library / can't open / loading / failed) share one consistent full-window layout, and how do they relate to the future library picker (B1)?
  - How should the window behave when closed while Settings is open — quit, or keep MLM running with a way back?
  - How prominent must "drive not connected" be at window level vs. inside individual sections?

### W-SETTINGS — Settings window (shell only; tabs ST-* belong to settings.md)
- Reached via: `Settings…` ⌘, in the app menu (M-APP.E02 / K-APP-SETTINGS, `MLM/App/MLMApp.swift:82-91`) · sidebar footer `Settings` (`MLM/Views/Sidebar/SidebarView.swift:225-241`, P-SIDEBAR) · `Open Settings` buttons in a failed-download row of V-PLD (`MLM/Views/Playlists/PlaylistDetailView.swift:623-626`) and in W-REMOTE (`MLM/Views/Sources/RemotePlaylistsView.swift:130-133,202-207`) · `Reconnect` in ST-SRC (`MLM/Views/Settings/SourcesSetupView.swift:144-146`) · Leads to: ST-LIB, ST-SRC, ST-MAINT, ST-BACKUP, ST-STORAGE, ST-PLAYBACK, ST-ADV.
- Code: `MLM/App/AppDelegate.swift:15-19,62-84` (window creation), `MLM/Views/Settings/SettingsView.swift:9-12` (tab selection persisted in `@AppStorage("settings.selectedTab")`).
- Purpose: one separate window for all preferences and storage/backup/library-file information.
- User goals:
  1. Fix a source sign-in or setting that a screen told him to fix ("Open Settings") — weekly.
  2. Check/change library folder, backup, storage locations — rare.
  3. Toggle `Open the last library at launch` (ST-LIB) — rare.
- What the user wants to see: the tab relevant to the reason he opened it; then the rest.
- Elements today:
  - W-SETTINGS.E01 Window title `Settings` (`MLM/App/AppDelegate.swift:75`).
  - W-SETTINGS.E02 Standard title bar with close / minimise / zoom; resizable (`MLM/App/AppDelegate.swift:76`).
  - W-SETTINGS.E03 Content: `SettingsView` tab view (7 tabs, owned by settings.md) at content size 720×560, minimum 600×500 (`MLM/App/AppDelegate.swift:69-77`).
- Interactions: opening when already open just brings it to front and activates MLM (`MLM/App/AppDelegate.swift:68,82-83`); created lazily once per process, centred on first open, kept in memory when closed (`isReleasedWhenClosed = false`, `MLM/App/AppDelegate.swift:78-79`); no frame autosave, so position is not remembered across launches (no `setFrameAutosaveName` anywhere in `MLM/`). No deep-linking: every entry point opens the last-used tab, never the relevant one (`showSettingsWindow()` takes no tab argument, `MLM/App/AppDelegate.swift:67`). ⌘F pressed in this window is swallowed by the main window's app-wide ⌘F monitor (`MLM/Views/ContentView/ContentView.swift:290-303`, index §6.3).
- States: before a library is open, Settings opens anyway (⌘, works in every launch state); tab content shows "available once the library has loaded" placeholders (owned by settings.md). Not tied to a library: a library switch relaunches the app and closes it.
- Data scale: n/a.
- Pain points today:
  - `Open Settings` / `Reconnect` buttons cannot open the relevant tab (`MLM/App/AppDelegate.swift:67`), so the user lands on whatever tab was last used.
  - If `AppDelegate.shared` is nil the menu item silently does nothing (error only in Logs, `MLM/App/MLMApp.swift:84-87`).
  - Implemented as AppKit window because "every SwiftUI-native path … failed in practice" (`MLM/App/AppDelegate.swift:15-18`) — so it does not get standard Settings-scene behaviour (e.g. toolbar-style tab switching, automatic frame restore) (*inferred*).
- Related flows: settings-changes, switch-library (toggle), backup-restore (via ST-BACKUP).
- Constraints: window title `Settings` (UI-GROUNDTRUTH §3.14, §5.1); tab order fixed (brief).
- Open questions for the designer:
  - Should callers be able to open Settings at a specific tab (e.g. `Reconnect` → Sources)?
  - Should Settings be a standard macOS Settings window (toolbar tabs, fixed width per tab) or a resizable window?
  - Should the window remember its position/size?

### Window shell of W-REMOTE (remote playlists window; full entry in sources-review.md)
- Reached via: Sources (V-SRC) `MLM/Views/Sources/SourcesView.swift:276,380` · Leads to: content RemotePlaylistsView (sources-review.md), W-SETTINGS via `Open Settings`.
- Code: `MLM/App/AppDelegate.swift:21-26,86-143`; titles `MLM/Views/Sources/RemotePlaylistsView.swift:11-17`.
- Purpose: separate window to browse/import one source's playlists.
- Shell facts: AppKit `NSWindow`, titled/closable/miniaturizable/resizable, 760×620 content (also the minimum), centred (`MLM/App/AppDelegate.swift:112-121,133`); title per source: `SoundCloud Playlists`, `Spotify Playlists`, `Import YouTube Playlist`. **Only one at a time**: requesting the same source focuses it; requesting a different source closes the current one and builds a new one (`MLM/App/AppDelegate.swift:99-109`) — any in-progress state in the closed window is lost (*inferred*). Content can close the window itself via `onRequestClose` (`MLM/App/AppDelegate.swift:123-131`). Not frame-autosaved.
- States / pain points / open questions: see sources-review.md draft. Shell-level open question: should two sources' playlist windows be able to coexist?

### Window list (every window/panel the app can show)
| ID | Kind | Created at | Notes |
|---|---|---|---|
| W-MAIN | SwiftUI `Window` scene, single instance | `MLM/App/MLMApp.swift:63-76` | Quits app when last window closes (`MLM/App/AppDelegate.swift:58-60`) |
| W-SETTINGS | AppKit `NSWindow` via `NSWindowController` | `MLM/App/AppDelegate.swift:66-84` | Lazily created, reused |
| W-REMOTE | AppKit `NSWindow` via `NSWindowController` | `MLM/App/AppDelegate.swift:97-143` | One at a time, replaced per source |
| S-LIBFILE-OPEN | `NSOpenPanel` (app-modal) | `MLM/App/LibraryCommands.swift:45-61` | Open Library… |
| S-WIZ-FOLDER | `NSOpenPanel` (app-modal) | `MLM/Views/Shared/FirstRunWizard.swift:335-348` | Library folder choice |
| NSAlert(s) for track deletion | AppKit alerts | `MLM/Views/Library/TrackContextMenu.swift:225,317` | Owned by library.md (CM-TRACK) |
| SwiftUI sheets/alerts on W-MAIN | sheets | `MLM/Views/ContentView/ContentView.swift:87-94,193-198,735-758` | Universal search (main.md), selection sheets (library.md), library-file sheets/alerts (this draft) |

There is no `MenuBarExtra`, no `WindowGroup`, no SwiftUI `Settings` scene, no custom Dock menu (grep of `MLM/` for `MenuBarExtra|WindowGroup|applicationDockMenu` is empty).

### V-LAUNCH-NOLIB — "No library open"
- Reached via: launch when the registry has libraries but `Open the last library at launch` is off (`MLM/Services/Library/LibraryLaunchResolver.swift:46-48`) · launch on a first run (behind S-NEWLIB, `MLM/Services/Library/LibraryLaunchCoordinator.swift:184-186`) · after `OK`/`Cancel` on any launch problem (`MLM/Services/Library/LibraryLaunchCoordinator.swift:200-206`) · Leads to: S-NEWLIB (`New Library…`), S-LIBFILE-OPEN (`Open Library…`) → W-MAIN working layout or V-LAUNCH-CANTOPEN / V-LAUNCH-INVALID / A-LIB-COPY.
- Code: `MLM/Views/Shared/LibraryLaunchStateView.swift:63-80`, routing `MLM/Views/ContentView/ContentView.swift:109-118`, state `MLM/Services/Library/LibraryLaunchCoordinator.swift:15-32,155-192`.
- Purpose: tell the user no library is open and let him create one or open an existing library file.
- User goals:
  1. Pick which library to open at launch when "remember last library" is off — rare today, potentially daily for a multi-library user (`todo_dump.md:5`: "MLM starts … shows an empty view with a disk icon and asking the user for which lib to open").
  2. Create the first library — rare.
- What the user wants to see: 1. the libraries he has (names, where they are, whether available — Not found / Not connected); 2. a way to open one in one click; 3. create new; 4. open a library file from elsewhere.
- Elements today:
  - V-LAUNCH-NOLIB.E01 System "content unavailable" layout with SF Symbol `opticaldisc` and title `No library open`.
  - V-LAUNCH-NOLIB.E02 Description `Create a new library or open an existing library file.`
  - V-LAUNCH-NOLIB.E03 Button `New Library…` → S-NEWLIB with name `New Library` (or `Main Library` on first run) (`MLM/Services/Library/LibraryLaunchCoordinator.swift:297-299`).
  - V-LAUNCH-NOLIB.E04 Button `Open Library…` → S-LIBFILE-OPEN → opens directly (no relaunch) (`MLM/Views/ContentView/ContentView.swift:114`).
- Interactions: buttons only. File menu `Open Recent` ▸ (M-FILE.E04) is the only place listing known libraries. No drag & drop of a `.mlibm` onto this view (expected, missing — D-LIBFILE-WINDOWDROP).
- States: default as above; there is no list/empty distinction because no list exists. Background: none.
- Data scale: registry is small (1–few libraries).
- Pain points today: the screen does not list registered libraries — choosing one requires the File → Open Recent submenu or a file dialog (`MLM/Views/Shared/LibraryLaunchStateView.swift:63-80`; code comment calls it a "Minimal native placeholder — the real library picker is B1", line 5-6). Uses custom background `Color.mlmBase` (`MLM/Views/Shared/LibraryLaunchStateView.swift:18`).
- Related flows: first-launch, switch-library.
- Constraints: A0 D5 (picker shows registry entries incl. missing/unmounted states — B1); UI-GROUNDTRUTH §3.17 copy approved (ROADMAP A3 decision 8).
- Open questions for the designer:
  - Should this become the library picker (list of registry entries with availability), and what does each entry show (name, path, last opened, track count, Not found / Not connected)?
  - Should removing a stale library entry or revealing it in Finder be possible here?
  - What is the first-run variant: this screen with a sheet on top (today), or a dedicated welcome?

### V-LAUNCH-CANTOPEN — "‹name›" can't be opened (window-content form)
- Reached via: launch when the last library is unavailable (`MLM/Services/Library/LibraryLaunchResolver.swift:49-52`) · opening/choosing a library file while no library is open that is missing or whose identity doesn't match (`MLM/Services/Library/LibraryLaunchCoordinator.swift:445-466`) · `Try again` that still fails · Leads to: retry → W-MAIN; S-NEWLIB; S-LIBFILE-OPEN; Finder; V-LAUNCH-NOLIB (`OK`). The same problems while a library is already open appear as A-LIBFILE-CANTOPEN instead.
- Code: `MLM/Views/Shared/LibraryLaunchStateView.swift:24-47,74-80`; decisions `MLM/Services/Library/LibraryRegistry.swift:119-129` (availability), `MLM/Services/Library/LibraryPackage.swift:215-255` (validation), `MLM/Services/Library/LibraryLaunchCoordinator.swift:194-206,445-484`.
- Purpose: explain why the expected library didn't open and offer the way out.
- User goals:
  1. Plug in the drive and continue (library file on external disk) — weekly if he moves the `.mlibm` to the external disk (A0 D1 allows it).
  2. Re-locate a moved library file — rare.
  3. Understand a corruption/mismatch without losing data — rare.
- What the user wants to see: which library, why (not connected vs. moved vs. mismatch), where it was last seen (path/volume), and the single action that fixes it.
- Elements today (three variants):
  - Not connected (`availability == .notConnected`): E01 symbol `opticaldisc`, title `"‹name›" can't be opened`; E02 text `The library file is on a disk that isn't connected. Connect the disk, then try again.`; E03 `Try again` (re-runs the whole launch resolution, `MLM/Services/Library/LibraryLaunchCoordinator.swift:195-197`); E04 `New Library…`; E05 `Open Library…`.
  - Not found: same title; E02 `The library file isn't where MLM last found it. Open it from its new location, or create a new library.`; buttons E04/E05 only (no `Try again`).
  - Mismatch: E06 symbol `exclamationmark.triangle`, title `"‹name›" can't be opened`; E07 text `The library file and its database don't belong together. This can happen when files inside a library file were replaced. MLM didn't change anything.`; E08 `Show in Finder` (reveals the `.mlibm`); E09 `OK` → V-LAUNCH-NOLIB.
- Interactions: buttons only; no automatic retry when the disk is mounted (MountObserver does not exist yet at this point — it is created only after a library opens, `MLM/App/DependencyContainer.swift:376-388`).
- States: as listed; the path/volume of the missing file is not shown anywhere.
- Pain points: no path or volume name shown, so "which disk?" is unanswered (`MLM/Views/Shared/LibraryLaunchStateView.swift:24-36`); `Try again` must be clicked manually after plugging in; button order differs from UI-GROUNDTRUTH §3.17 (`Try again` · `Open Library…` · `New Library…` there; code `Try again` · `New Library…` · `Open Library…`, `MLM/Views/Shared/LibraryLaunchStateView.swift:32-35,74-80`).
- Related flows: switch-library, drive-unplugged (library file on external disk).
- Constraints: identity mismatch is shown, never repaired silently (ROADMAP A3 decision 2, A0 D5); copy per §3.17.
- Open questions for the designer: Should the screen show the last-known path / disk name? Should it wait for the disk and open automatically? Is "mismatch" understandable without technical detail, and should there be a `Details` disclosure?

### V-LAUNCH-INVALID — "‹name›" isn't a valid library file.
- Reached via: opening a `.mlibm` with no database inside, an unreadable/newer manifest, or a registry write failure, while no library is open (`MLM/Services/Library/LibraryLaunchCoordinator.swift:445-484`); also when `Open as separate library` fails (`MLM/Services/Library/LibraryLaunchCoordinator.swift:247-252`) · Leads to: V-LAUNCH-NOLIB.
- Code: `MLM/Views/Shared/LibraryLaunchStateView.swift:48-53`.
- Elements: E01 symbol `exclamationmark.triangle`, title `"‹name›" isn't a valid library file.` (no description); E02 `OK` → V-LAUNCH-NOLIB.
- Purpose / goals: tell the user this file can't be used — rare.
- States: single. Pain points: one message covers several different causes (no DB, newer manifest version, registry not writable) — the user can't tell "damaged" from "made by a newer MLM" (`MLM/Services/Library/LibraryLaunchCoordinator.swift:464-466,478-482`); no `Show in Finder`, no `Details`.
- Related flows: switch-library. Constraints: §3.17 copy. Open questions: should "made by a newer MLM" have its own wording? Should the file be revealable from here?

### V-LAUNCH-LOADING — "Loading Library..."
- Reached via: every launch while the coordinator resolves and while the database/services initialise; also while an interrupted adoption is silently finished or rolled back (`MLM/Services/Library/LibraryLaunchCoordinator.swift:155-157,379-399`) · Leads to: W-MAIN working layout or any other launch state.
- Code: `MLM/Views/ContentView/ContentView.swift:119-120,497-507`.
- Elements: E01 large spinner; E02 text `Loading Library...` (three ASCII dots).
- States: indeterminate only; no library name, no step, no cancel. Duration depends on DB open + service setup (`MLM/App/DependencyContainer.swift:147-417`).
- Pain points: if `Open Library…` is used while this state persists after a failure, the request is queued and never handled (`MLM/Services/Library/LibraryLaunchCoordinator.swift:221-222` — the queue is drained only at `start()` end, line 150-152); copy uses `...` instead of `…`.
- Open questions: Should loading name the library being opened and say when it is finishing an interrupted library-file setup?

### V-LAUNCH-FAILED — "Failed to Initialize"
- Reached via: any error while opening the library or loading the registry (`reportFailure` → `DependencyContainer.reportInitializationFailure`, `MLM/Services/Library/LibraryLaunchCoordinator.swift:136-141,159-164,429-441`, `MLM/App/DependencyContainer.swift:99-107`); also a New Library creation failure at launch (`MLM/Services/Library/LibraryLaunchCoordinator.swift:326-332`); a registry written by a newer MLM (`MLM/Services/Library/LibraryRegistry.swift:159-187`).
- Code: `MLM/Views/ContentView/ContentView.swift:95-96,477-493`.
- Elements: E01 symbol `exclamationmark.triangle.fill` in error colour; E02 title `Failed to Initialize`; E03 raw `error.localizedDescription`.
- Interactions: none — no retry, no `Open Library…`, no `Show Logs`, no quit button. File menu items remain but `Open Library…` may be queued forever (see V-LAUNCH-LOADING).
- Pain points: dead end with technical text (violates UI-GROUNDTRUTH §1.7 rule 4 "plain-language cause + one action"); LOGIC-003's "offer explicit recovery" part still open (the "error never reaches the screen" part is fixed by `reportInitializationFailure`).
- Open questions: What recovery actions belong here (retry, open another library, restore a backup, show logs)?

---

## Context menus
None owned by this area. (No custom Dock menu exists — see M-DOCK.)

## Sheets, popovers, panels, alerts

### S-ADOPT — "Set up your library file"
- Trigger: launch when the pre-A3 loose database still exists and no adoption is in progress (`MLM/Services/Library/LibraryLaunchResolver.swift:40-42`); asked **at every launch** until done (ROADMAP A3 decision 13). Presented as a non-dismissable sheet over an empty window (`MLM/Views/ContentView/ContentView.swift:97-108`, `.interactiveDismissDisabled()` `MLM/Views/Shared/LibraryAdoptionSheet.swift:31`).
- Code: `MLM/Views/Shared/LibraryAdoptionSheet.swift:6-119`; actions `MLM/Services/Library/LibraryLaunchCoordinator.swift:338-376`; engine `MLM/Services/Library/LibraryAdoption.swift:97-129`.
- Content (width 440):
  - E01 title `Set up your library file`.
  - E02 explanation `MLM now keeps your library — tracks, playlists, settings and playlist covers — in a single library file that you can move and back up as one item. MLM backs up first, then copies your library into the new file. Audio files are not moved.`
  - E03 field `Name` (prefilled `Main Library`) + muted line `Saved as "‹name›.mlibm" in MLM's folder in your user Library.`
  - E04 `Not now` (Esc / cancel) → opens the old layout this launch (`declineAdoption`, `MLM/Services/Library/LibraryLaunchCoordinator.swift:369-372`).
  - E05 `Create library file` (Return / default; disabled when name empty) → runs adoption.
  - E06 running: small spinner + phase text `Backing up…` → `Creating library file…` → `Checking…` (explanation stays visible; no buttons, no cancel).
  - E07 success text `Your library is now stored in "‹file›". The previous files were moved to a folder named "legacy-adopted-…" — you can delete it once everything looks right.`
  - E08 `Show in Finder` (reveals the new `.mlibm`).
  - E09 `Done` (Return) → opens the new library (`MLM/Services/Library/LibraryLaunchCoordinator.swift:362-366`).
  - E10 failure label (symbol + text) `The library file couldn't be created. Your library was not changed.`
  - E11 `Details` disclosure with selectable raw error text.
  - E12 `Not now` (Esc) — as E04.
  - E13 `Try again` (Return) — reruns with the last typed name (the name field is not visible in this state).
- Consequences: Create = journaled copy (backup → `VACUUM INTO` staging → verify → rename → registry → re-point → move legacy files into `legacy-adopted-<timestamp>/`) (`MLM/Services/Library/LibraryAdoption.swift:10-21,173-275`). A failure after the point of no return opens the new library anyway, no message (`MLM/Services/Library/LibraryLaunchCoordinator.swift:350-355`). An interrupted adoption is finished/undone silently on next launch behind V-LAUNCH-LOADING (`MLM/Services/Library/LibraryLaunchCoordinator.swift:379-399`).
- Cancel/escape: Esc = `Not now` in offer/failed states; no escape while running.
- Error handling: E10/E11 with Details (matches §1.7 rule 4).
- Notes: a library file double-clicked in Finder while this sheet is up is ignored entirely, not queued (`MLM/Services/Library/LibraryLaunchCoordinator.swift:223-225`, despite the comment "can be opened afterwards"). Choosing `Not now` opens the old database even if other libraries exist (ROADMAP A3 decision 13).

### S-NEWLIB — "New Library"
- Trigger: File → `New Library…` (M-FILE.E02), `New Library…` in V-LAUNCH-NOLIB / V-LAUNCH-CANTOPEN / A-LIBFILE-CANTOPEN, and automatically on first run with `Main Library` (`MLM/Services/Library/LibraryLaunchCoordinator.swift:184-186,297-299`). Presented as a sheet on W-MAIN (`MLM/Views/ContentView/ContentView.swift:735-741`).
- Code: `MLM/Views/Shared/NewLibrarySheet.swift:5-39`; action `MLM/Services/Library/LibraryLaunchCoordinator.swift:307-334`; file creation `MLM/Services/Library/LibraryPackage.swift:89-122`.
- Content (width 380): E01 title `New Library`; E02 field `Name` (prefill `Main Library` on first run, otherwise `New Library`); E03 text `A library keeps its own tracks, playlists and settings. Audio files stay where they are.`; E04 `Cancel` (Esc, role cancel); E05 `Create` (Return; disabled when name empty).
- Consequences of `Create`: always creates `<name>.mlibm` in the default folder (Application Support `…/libraries/`, numbered ` 2`, ` 3` if taken; `/` and `:` replaced by `-`) — no location choice. No library open → opens it immediately (then S-WIZARD because it has no library folder). A library open → registers it, then shows A-LIB-SWITCH; **Cancel there leaves the new, empty library registered** (appears in Open Recent) (`MLM/Services/Library/LibraryLaunchCoordinator.swift:317-322`).
- Errors: while a library is open, a creation failure shows A-LIBFILE-INVALID `"‹name›" isn't a valid library file.` — wrong message for a create failure (`MLM/Services/Library/LibraryLaunchCoordinator.swift:327-329`); at launch it goes to V-LAUNCH-FAILED (`:330-331`). The final file name is not shown before creating (unlike S-ADOPT E03).

### S-WIZARD — First-run wizard (window overlay)
- Reached via: automatically whenever the open library has no library folder (`hasLibraryRoot == false`, `MLM/Views/ContentView/ContentView.swift:84-86`; set at `MLM/App/DependencyContainer.swift:376-378`) — i.e. first run after S-NEWLIB, and **every newly created library**. Not reachable manually. Leads to: S-WIZ-FOLDER; W-MAIN working layout.
- Code: `MLM/Views/Shared/FirstRunWizard.swift:14-370`; overlay `MLM/Views/ContentView/ContentView.swift:69-82`; import engine `MLM/ViewModels/ImportViewModel.swift:75-90,96+`.
- Purpose: point the new library at the music folder and import it.
- User goals: 1. choose the music folder (e.g. the external drive or a small local subset) — rare; 2. see that the import worked (counts) — rare; 3. understand MLM will create managed folders — rare.
- What the user wants to see: which folder is chosen; progress with counts; result (imported / already there / failed) and what failed.
- Elements today (fixed 520×420 card, custom-styled: rounded corners, drop shadow, accent-filled buttons, gradient icon, over a 60 % black scrim):
  - Step 1 Welcome: E01 icon `music.note.house.fill` (gradient); E02 `Welcome to MLM` / `Music Library Manager`; E03 `To get started, point MLM at your music library folder.\nMLM will scan it for audio files and organize your collection.`; E04 `Get Started`.
  - Step 2 Select folder: E05 icon `folder.badge.plus`, heading `Select Library Folder`, text `Choose the folder that contains your music files.\nMLM supports MP3, FLAC, AAC, M4A, OGG, WAV, AIFF, and ALAC.`; E06 chosen path (mono, middle-truncated) once picked; E07 `Choose Folder...` / `Change Folder...` → S-WIZ-FOLDER; E08 `Scan & Import` (only after a folder is chosen) → saves the folder as library root, posts `.libraryRootDidChange`, starts import.
  - Step 3 Scanning: E09 phase text, `‹processed› / ‹total› files`, current file name (middle-truncated); E10 determinate progress bar (or spinner + `Preparing...` before first progress); E11 `Cancel` → back to step 2 (root already saved; partial import kept).
  - Step 4 Done: E12 icon `checkmark.circle.fill`, `Import Complete` + rows `‹n› tracks imported`, `‹n› already in library` (if >0), `‹n› failed` (if >0); E13 error line (red) if the import reported an error; E14 `MLM will create folders like "Downloads (SoundCloud)" inside your library when you import from sources — see Settings → Library for details.`; E15 `Open Library` → closes the wizard.
- Interactions: buttons only; no close/skip/back on step 1–2; no Esc handling; no drag & drop of a folder (expected, missing — D-WIZ-FOLDERDROP); the whole working window is covered and blocked.
- States: default steps; error shown only on Done (title still says `Import Complete` even with an error, `MLM/Views/Shared/FirstRunWizard.swift:246-285`); no "which files failed" list; if services are missing the wizard silently does nothing (`MLM/Views/Shared/FirstRunWizard.swift:325-333`). Import also appears as an operation in P-ACTIVITY (ImportViewModel uses `activityViewModel`, `MLM/ViewModels/ImportViewModel.swift:147-163`).
- Data scale: a 13k-track library scan runs inside this modal card.
- Pain points: not skippable — a library without a music folder is impossible (blocks a "dev library first, folder later" use, *inferred* from `todo_dump.md:5`); custom non-native styling (accent fills, gradient, shadow, `Color.mlm*`) contradicts the locked native look; button `Open Library` collides with File → `Open Library…` (different meaning: here it only closes the wizard) — violates "one meaning per word"; title-case `Get Started` and ASCII `...` violate §1.7; after the wizard sets the folder, **drive monitoring is not started until the next launch** (MountObserver is only created during `initialize`, `MLM/App/DependencyContainer.swift:376-388`; the root-change observer only re-wires downloads, `:390-410`).
- Related flows: first-launch, switch-library (new library), settings-changes (library folder).
- Constraints: 4-step structure is "solid — keep" (UI-GROUNDTRUTH §3.16); copy approved.
- Open questions for the designer: Should the wizard be skippable or resumable? Should it be a sheet/window instead of an overlay card? Where should failed files from the initial import be inspectable? Should it name the library it is setting up?

### S-LIBFILE-OPEN — Open Library… file panel
- Trigger: File → `Open Library…` ⌘O (M-FILE.E03); `Open Library…` buttons in V-LAUNCH-NOLIB, V-LAUNCH-CANTOPEN, A-LIBFILE-CANTOPEN.
- Code: `MLM/App/LibraryCommands.swift:43-61`.
- Content: system `NSOpenPanel`, single selection. In the app bundle (document type registered by `scripts/run.sh:110-143`) only `.mlibm` library files are selectable; when run via `swift run` the type is unknown and the panel lets you choose folders instead. No title/message/prompt text set.
- Buttons: system `Open` / `Cancel`. Consequence: library open → A-LIB-SWITCH (or nothing if it is the current library — silent, `MLM/Services/Library/LibraryLaunchCoordinator.swift:218-219`); no library open → opens directly. Cancel → nothing.

### S-WIZ-FOLDER — library folder panel
- Trigger: S-WIZARD.E07. Code: `MLM/Views/Shared/FirstRunWizard.swift:335-348`.
- Content: `NSOpenPanel` titled `Select Music Library Folder`, message `Choose the root folder of your music library`, folders only, single, `New Folder` allowed. `Open`/`Cancel` (system). Result fills S-WIZARD.E06.

### A-LIB-SWITCH — "Switch to "‹name›"?"
- Trigger: while a library is open — Finder double-click / Open With / drop on Dock icon of another `.mlibm` (`MLM/App/AppDelegate.swift:47-52`), File → `Open Library…`, File → `Open Recent` ▸ item, or after S-NEWLIB created one (`MLM/Services/Library/LibraryLaunchCoordinator.swift:211-229,317-322`).
- Code: `MLM/Views/ContentView/ContentView.swift:742-750`; `MLM/Services/Library/LibraryLaunchCoordinator.swift:231-242,405-415`; relaunch `MLM/Services/Backup/BackupService.swift:344-379`.
- Content: title `Switch to "‹name›"?` (name = file name without extension, not the manifest name), message `MLM relaunches to open this library. Finish active downloads and syncs first.`
- Buttons: `Relaunch` (default) → validates the file first; if fine, remembers it for the next launch (one-shot, works even when "open last library" is off, `MLM/Services/Library/LibraryLaunchCoordinator.swift:67-85`) and quits + relaunches; if not, shows A-LIBFILE-CANTOPEN / A-LIBFILE-INVALID / A-LIB-COPY and stays. `Cancel` (cancel role) → nothing.
- Notes: the warning is text only — MLM does not check for running downloads/syncs, and quitting does not ask (`applicationWillTerminate` is empty, no `applicationShouldTerminate`, `MLM/App/AppDelegate.swift:54-56`). If termination is cancelled the relaunch helper is stopped after 5 s and an error is logged only (`MLM/Services/Backup/BackupService.swift:373-377`). Only the first `.mlibm` of a multi-file open is used (`MLM/App/AppDelegate.swift:48`).

### A-LIB-COPY — "‹name›" is a copy of "‹original›" (library-file copy prompt)
- Trigger: opening a `.mlibm` whose library id belongs to another registered library file that still exists (a Finder copy) (`MLM/Services/Library/LibraryLaunchCoordinator.swift:469-474`). Two presentations: window content when no library is open (`MLM/Views/Shared/LibraryLaunchStateView.swift:54-62`), alert while a library is open (`MLM/Views/ContentView/ContentView.swift:751-758,766,780-781,793-795`).
- Content: title `"‹name›" is a copy of "‹original›"` (symbol `doc.on.doc` in window form); message `To open it, MLM makes the copy a separate library. "‹original›" is not changed.`
- Buttons: `Open as separate library` → writes a new identity into the copy (database + manifest, `MLM/Services/Library/LibraryPackage.swift:149-168`), then opens it (no library open) or switches with relaunch **without** a further A-LIB-SWITCH confirmation (`MLM/Services/Library/LibraryLaunchCoordinator.swift:245-259`); `Cancel` (cancel role) → V-LAUNCH-NOLIB or dismiss alert.
- Error: identity rewrite fails → V-LAUNCH-INVALID / A-LIBFILE-INVALID.
- Note: ROADMAP A3 decision 12 said the copy "still needs approval"; current copy matches UI-GROUNDTRUTH §3.17/§5.6.

### A-LIBFILE-CANTOPEN — can't be opened (alert form, while a library is open)
- Trigger: `Relaunch` in A-LIB-SWITCH (or Open as separate library) on a file that is missing / not connected / mismatched (`MLM/Services/Library/LibraryLaunchCoordinator.swift:232-238`).
- Code: `MLM/Views/ContentView/ContentView.swift:751-809`.
- Content: title `"‹name›" can't be opened`; message `The library file is on a disk that isn't connected. Connect the disk, then try again.` / `The library file isn't where MLM last found it. Open it from its new location, or create a new library.` / (mismatch) `The library file and its database don't belong together. This can happen when files inside a library file were replaced. MLM didn't change anything.`
- Buttons: unavailable → `Open Library…` (→ S-LIBFILE-OPEN) · `New Library…` (→ S-NEWLIB) · `Cancel`; mismatch → `Show in Finder` · `OK`. No `Try again` in alert form even for "not connected" (differs from V-LAUNCH-CANTOPEN).
- Note: Open Recent entries that are Not found / Not connected are already disabled, so this alert mostly appears via Finder double-click or the open panel.

### A-LIBFILE-INVALID — isn't a valid library file (alert form)
- Trigger: as A-LIBFILE-CANTOPEN for invalid files, and for a failed `New Library…` creation while a library is open (`MLM/Services/Library/LibraryLaunchCoordinator.swift:327-329`). Code: `MLM/Views/ContentView/ContentView.swift:765,806-807`.
- Content: title `"‹name›" isn't a valid library file.`, no message. Button `OK` (cancel role).

## Menu items & keyboard shortcuts (area-local)

Menu-bar order (SwiftUI default placement of `CommandMenu`s between View and Window, *inferred*): **MLM · File · Edit · View · Navigate · Playback · Library · Window · Help**. All custom menus are defined in `MLM/App/MLMApp.swift:77-191`. Items whose action depends on the main window use `@FocusedBinding`/`@FocusedValue` (`MLM/App/MLMApp.swift:54-58`, published at `MLM/Views/ContentView/ContentView.swift:124-125`): when Settings or W-REMOTE is the key window they do nothing / are disabled (*inferred* from focused-value semantics).

### M-APP — "MLM" (application menu)
- M-APP.E01 `About MLM` — system-provided (not in code).
- M-APP.E02 `Settings…` ⌘, (K-APP-SETTINGS) — replaces the system Settings item; opens/focuses W-SETTINGS; always enabled, works in every launch state (`MLM/App/MLMApp.swift:82-91`).
- M-APP.E03… `Services` ▸, `Hide MLM` ⌘H, `Hide Others` ⌥⌘H, `Show All`, `Quit MLM` ⌘Q — system-provided. Quit never asks, even during downloads/sync/adoption (`MLM/App/AppDelegate.swift:54-56`).

### M-FILE — "File"
- System `New` item removed (`CommandGroup(replacing: .newItem) {}`, `MLM/App/MLMApp.swift:79`).
- M-FILE.E01 `New Playlist` ⌘N (K-FILE-NEWPLAYLIST) — creates a playlist named `Untitled Playlist` immediately (no name prompt), posts `.playlistDidChange`, switches to Playlists (V-PL) (`MLM/App/MLMApp.swift:95-98,234-242`). Always enabled; with no library open it silently does nothing; errors are swallowed (`try?`).
- separator.
- M-FILE.E02 `New Library…` (no shortcut) → S-NEWLIB (`MLM/App/LibraryCommands.swift:11-13`). Always enabled.
- M-FILE.E03 `Open Library…` ⌘O (K-FILE-OPENLIB) → S-LIBFILE-OPEN → A-LIB-SWITCH / direct open (`MLM/App/LibraryCommands.swift:15-20`). Always enabled.
- M-FILE.E04 `Open Recent` ▸ — submenu of the *other* registered libraries, most recently opened first; each item `‹name›`, or disabled `‹name› — Not found` / `‹name› — Not connected`; whole submenu disabled when empty; no `Clear Menu` (`MLM/App/LibraryCommands.swift:22-40`, list `MLM/Services/Library/LibraryLaunchCoordinator.swift:274-282`, order `MLM/Services/Library/LibraryRegistry.swift:80-89`). Availability is computed only at launch/open time — a disk connected later stays "Not connected" until the next relaunch (*inferred* from the only call sites of `refreshRegistryState`, `MLM/Services/Library/LibraryLaunchCoordinator.swift:165,321,435`).
- M-FILE.E05 `Close` ⌘W and other standard File items — system-provided (*inferred*).

### M-EDIT — "Edit"
Not customised — system standard (Undo/Redo/Cut/Copy/Paste/Delete/Select All, plus system additions). No app-specific Undo exists in MLM (*inferred*: no `UndoManager` use found in shell files). ⌘F (Find) is not in this menu; it is intercepted by a key monitor (index §6.3).

### M-VIEW — "View"
Not customised. No `SidebarCommands()` or `ToolbarCommands()` in `.commands` (`MLM/App/MLMApp.swift:77-191`), so standard `Show/Hide Sidebar` / toolbar items are likely absent; only system items such as `Enter Full Screen` appear (*inferred*, "Unresolved from code"). No item for the inspector, activity panel or search.

### M-NAVIGATE — "Navigate"
Built from `SidebarSection.topLevelCases` (`MLM/App/MLMApp.swift:107-116`, `MLM/Views/ContentView/ContentView.swift:573-629`). Each item selects the sidebar section in the focused main window. Always enabled (also on launch screens, where it changes an invisible selection).
- M-NAVIGATE.E01 `Library` ⌘1 (K-NAV-LIBRARY)
- M-NAVIGATE.E02 `Playlists` ⌘2 (K-NAV-PLAYLISTS)
- M-NAVIGATE.E03 `Folders` ⌘3 (K-NAV-FOLDERS)
- M-NAVIGATE.E04 `Sync` ⌘4 (K-NAV-SYNC)
- M-NAVIGATE.E05 `Sources` ⌘5 (K-NAV-SOURCES)
- M-NAVIGATE.E06 `Review` ⌘6 (K-NAV-REVIEW)
- M-NAVIGATE.E07 `Discover` ⌘7 (K-NAV-DISCOVER)
- M-NAVIGATE.E08 `Queue` ⌘8 (K-NAV-QUEUE) — duplicated by the sidebar queue footer button's own ⌘8 (`MLM/Views/Sidebar/SidebarView.swift:198-221`).
No separators; pinned playlists are not in the menu. Comment says "⌘1–⌘7" (`MLM/App/MLMApp.swift:106`).

### M-PLAYBACK — "Playback"
(`MLM/App/MLMApp.swift:119-163`; all items disabled unless a track is loaded in the focused window's player, `playbackVM?.hasTrack`.)
- M-PLAYBACK.E01 `Play` / `Pause` (title follows state) — **no shortcut**; toggles playback.
- M-PLAYBACK.E02 `Stop` ⌘. (K-PLAYBACK-STOP).
- separator.
- M-PLAYBACK.E03 `Previous Track` — no shortcut.
- M-PLAYBACK.E04 `Next Track` — no shortcut.
- separator.
- M-PLAYBACK.E05 `Skip Back 10s` ⌘← (K-PLAYBACK-SKIPBACK).
- M-PLAYBACK.E06 `Skip Forward 10s` ⌘→ (K-PLAYBACK-SKIPFWD).

### M-LIBRARY — "Library"
(`MLM/App/MLMApp.swift:165-190`; always enabled.)
- M-LIBRARY.E01 `Search Library` (no shortcut shown) → posts `.searchCommandTriggered` → focuses the toolbar search field (V-SEARCH, `MLM/Views/ContentView/ContentView.swift:159-161`). ⌘F does the same through a key monitor but is not shown on this item.
- separator.
- M-LIBRARY.E02 `Import from Folder…` ⌘⇧I (K-LIBRARY-IMPORT) → posts `.showImportDialog` — **nobody observes it: the item does nothing** (grep: only the post at `MLM/App/MLMApp.swift:175-177`).
- separator.
- M-LIBRARY.E03 `More Info` ⌘I (K-LIBRARY-MOREINFO) → posts `.showTrackDetail` — **nobody observes it: does nothing**; the inspector opens only via double-click/other routes (`MLM/Views/ContentView/ContentView.swift:172-192,394-404`).

### M-WINDOW — "Window"
Not customised — system standard (Minimize ⌘M, Zoom, tiling items, Bring All to Front, list of open windows: `MLM`, `Settings`, remote window title) (*inferred*).

### M-HELP — "Help"
Not customised — system default with search field and `MLM Help`, which has no help book (*inferred*: no help bundle in `scripts/run.sh` Info.plist, `scripts/run.sh:95-145`).

### M-DOCK — Dock menu
No custom Dock menu (`applicationDockMenu` not implemented in `MLM/App/AppDelegate.swift`). Only the system Dock menu (window list, Options, Show All Windows, Hide, Quit). Dropping a `.mlibm` on the Dock icon routes like a Finder open (D-LIBFILE-OPEN).

### K- entries (global, defined in menus or at window level)
| ID | Combo | Label | Scope | Action | Code | Conflicts / notes |
|---|---|---|---|---|---|---|
| K-APP-SETTINGS | ⌘, | `Settings…` | global menu | open/focus W-SETTINGS | `MLM/App/MLMApp.swift:82-91` | — |
| K-FILE-NEWPLAYLIST | ⌘N | `New Playlist` | global menu | create `Untitled Playlist`, go to V-PL | `MLM/App/MLMApp.swift:95-98` | **Duplicate**: V-PL's `New Playlist` button also binds ⌘N and opens a naming popover instead (`MLM/Views/Playlists/PlaylistsView.swift:230-248`) — two meanings |
| K-FILE-OPENLIB | ⌘O | `Open Library…` | global menu | S-LIBFILE-OPEN | `MLM/App/LibraryCommands.swift:15-20` | — |
| K-NAV-LIBRARY | ⌘1 | `Library` | global menu, acts on main window | select section | `MLM/App/MLMApp.swift:107-116`, `MLM/Views/ContentView/ContentView.swift:617-629` | — |
| K-NAV-PLAYLISTS | ⌘2 | `Playlists` | 〃 | 〃 | 〃 | — |
| K-NAV-FOLDERS | ⌘3 | `Folders` | 〃 | 〃 | 〃 | — |
| K-NAV-SYNC | ⌘4 | `Sync` | 〃 | 〃 | 〃 | — |
| K-NAV-SOURCES | ⌘5 | `Sources` | 〃 | 〃 | 〃 | — |
| K-NAV-REVIEW | ⌘6 | `Review` | 〃 | 〃 | 〃 | — |
| K-NAV-DISCOVER | ⌘7 | `Discover` | 〃 | 〃 | 〃 | — |
| K-NAV-QUEUE | ⌘8 | `Queue` | 〃 | 〃 | 〃 | Duplicate binding on sidebar queue footer (`MLM/Views/Sidebar/SidebarView.swift:218`), same meaning |
| K-PLAYBACK-STOP | ⌘. | `Stop` | global menu, needs a loaded track | stop | `MLM/App/MLMApp.swift:125-129` | ⌘. is also the macOS "cancel" chord in dialogs (*inferred* minor) |
| K-PLAYBACK-SKIPBACK | ⌘← | `Skip Back 10s` | global menu, needs a loaded track | seek −10 s | `MLM/App/MLMApp.swift:145-152` | Overrides text-field "move to line start" while a track is loaded (menu key equivalents win over text editing, *inferred*) |
| K-PLAYBACK-SKIPFWD | ⌘→ | `Skip Forward 10s` | 〃 | seek +10 s | `MLM/App/MLMApp.swift:154-161` | Same text-field conflict (⌘→ = line end) |
| K-LIBRARY-IMPORT | ⌘⇧I | `Import from Folder…` | global menu | posts `.showImportDialog` — no effect | `MLM/App/MLMApp.swift:174-179` | Dead |
| K-LIBRARY-MOREINFO | ⌘I | `More Info` | global menu | posts `.showTrackDetail` — no effect | `MLM/App/MLMApp.swift:183-188` | Dead; UI-GROUNDTRUTH §2.1 says ⌘I opens/closes the inspector |
| K-WIN-SEEKBACK | ← (hold repeats) | — (no menu item) | main window, when focus doesn't consume arrows, no ⌘/⌥/⌃ | seek −5 s, then every 100 ms after 500 ms hold | `MLM/App/MLMApp.swift:67-69,197-230`, `MLM/App/MLMApp.swift:7-40` | Undiscoverable (no menu item); competes with list/table/grid arrow navigation (*inferred*) |
| K-WIN-SEEKFWD | → (hold repeats) | — | 〃 | seek +5 s | `MLM/App/MLMApp.swift:70-72,197-230` | 〃 |

Sheet keys in this area: S-ADOPT `Not now` = Esc, `Create library file` / `Done` / `Try again` = Return; S-NEWLIB `Cancel` = Esc, `Create` = Return (`MLM/Views/Shared/LibraryAdoptionSheet.swift:55-57,94,113-115`, `MLM/Views/Shared/NewLibrarySheet.swift:29-31`). S-WIZARD has no keyboard handling.

## Drag & drop
- **D-LIBFILE-OPEN** — Finder → MLM: double-click / Open With / drop a `.mlibm` on the MLM Dock icon. Payload: file URL with extension `mlibm` (UTI `com.ilczuk.mlm.library`, document type registered only in the bundled app, `scripts/run.sh:110-143`). Handler `MLM/App/AppDelegate.swift:45-52` → `MLM/Services/Library/LibraryLaunchCoordinator.swift:210-229`: at launch → opens it (wins over the remembered library, `MLM/Services/Library/LibraryLaunchResolver.swift:37-39`); while resolving → queued; while S-ADOPT is offered → ignored; while a library is open → A-LIB-SWITCH (same file → silently nothing); on a launch screen → opens directly. Feedback: none during drag (system Dock highlight only). Multiple files: only the first `.mlibm` is used.
- **D-LIBFILE-WINDOWDROP** — *expected, missing*: dropping a `.mlibm` onto the main window (esp. V-LAUNCH-NOLIB) does nothing (no `onDrop` in the shell or `LibraryLaunchStateView`). Evidence: Finder-style apps (Photos/Music libraries) accept library drops; A0 D9 "import by double-click" path.
- **D-WIZ-FOLDERDROP** — *expected, missing*: dropping a music folder onto S-WIZARD step 2 is not supported (`MLM/Views/Shared/FirstRunWizard.swift:109-181` has no drop target). Evidence: standard macOS folder-choice affordance.

---

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Drive not connected**: decided by MountObserver (DiskArbitration) for the library folder's `/Volumes/<name>` (`MLM/Services/Mount/MountObserver.swift:46-50,109-193`); the shell pauses playback on unmount and flips `isLibraryDriveMounted` (`MLM/Views/ContentView/ContentView.swift:126-137`). No shell-level text; see index §8.
- **Library loading / failed / no library / can't be opened / adoption pending**: all owned here (V-LAUNCH-*, S-ADOPT, A-LIB-*) — index §8.
- **Library file on a disconnected disk**: `Not connected` (launch screen, Open Recent suffix), `Not found` — `MLM/Services/Library/LibraryRegistry.swift:119-129`.
- **Source disconnected/expired**: not shown in shell; sidebar dot (P-SIDEBAR, main.md).
- **Background processing**: shell shows nothing; the launch backup runs silently (log only, `MLM/App/DependencyContainer.swift:321-331`).

### Background work touchpoints

| Work | Where it surfaces | User control |
|---|---|---|
| Legacy adoption (backup + copy + verify) | S-ADOPT E06 phases `Backing up…`/`Creating library file…`/`Checking…`; result E07/E10 | none while running; Not now / Try again after failure |
| Interrupted adoption resume/rollback at launch | V-LAUNCH-LOADING only (no text about it); Logs (`MLM/Services/Library/LibraryLaunchCoordinator.swift:385,388,392`) | none |
| Launch backup (≤1/day) | nowhere in UI; Logs only (`MLM/App/DependencyContainer.swift:321-331`) | none (Settings → Backup, settings.md) |
| Registry rebuild / corrupt registry preserved | nowhere (not even logged; `MLM/Services/Library/LibraryRegistry.swift:167-194`) | none |
| Manifest repair on open | nowhere (not logged; `MLM/Services/Library/LibraryPackage.swift:245-253`) | none |
| First-run import | S-WIZARD step 3 (progress, count, current file) + P-ACTIVITY operation | `Cancel` (back to folder step) |
| Relaunch on switch | instant quit; no "Relaunching…" UI; failure → Logs only (`MLM/Services/Backup/BackupService.swift:344-379`) | Cancel in A-LIB-SWITCH |
| Transcode-cache relocation | P-ACTIVITY (`MLM/App/DependencyContainer.swift:423-504`; owned by settings.md/ACTIVITY) | Activity Cancel misleading (LOGIC-013) |

### Flow notes

- **first-launch** (no legacy DB, no registry): 1. app opens → V-LAUNCH-LOADING; 2. V-LAUNCH-NOLIB with S-NEWLIB on top, name `Main Library` (intent: "just start") — the "No library open" text behind a "create your first library" sheet is contradictory; 3. `Create` → library created in Application Support (no location choice) → opens; 4. S-WIZARD overlay: Get Started → Choose Folder → Scan & Import → progress → Import Complete → `Open Library` (name clash with File → Open Library…); 5. working window. Breaks: Cancel on S-NEWLIB leaves the user on V-LAUNCH-NOLIB (fine); wizard cannot be skipped; drive monitoring not active until next launch.
- **adopt-legacy** (area flow, Oliver's real first A3 launch): 1. V-LAUNCH-LOADING; 2. blank window + S-ADOPT; 3. `Create library file` → phases → success → `Show in Finder` / `Done`; 4. library opens. Or `Not now` → old layout opens, asked again next launch. Breaks: a Finder-opened library file during S-ADOPT is dropped.
- **switch-library**: 1. File → Open Recent ▸ ‹name› / Open Library… ⌘O / Finder double-click; 2. A-LIB-SWITCH (`Relaunch`); 3. validation → quit → relaunch → V-LAUNCH-LOADING → new library (or A-LIBFILE-CANTOPEN / A-LIB-COPY / A-LIBFILE-INVALID and stay). New library: File → New Library… → S-NEWLIB → A-LIB-SWITCH → relaunch → S-WIZARD. Breaks: no visible indicator of the current library after relaunch except Settings → Library; Open Recent availability stale; no check for running downloads/syncs; no picker list on V-LAUNCH-NOLIB when "open last library" is off; no way to remove/rename libraries in-app.
- **drive-unplugged**: 1. Oliver ejects/unplugs the drive while playing; 2. playback pauses (no message), sidebar Library row gets a red dot, V-LIB shows `Library drive is disconnected. Local tracks remain visible but cannot be played.`; 3. replug → state clears silently, playback not resumed. If the *library file* itself is on the unplugged disk: next launch → V-LAUNCH-CANTOPEN "not connected" → `Try again`. Breaks: no detection if the folder was set after launch (wizard/Settings); state invisible in other sections apart from the dot.
- **settings-changes**: ⌘, / sidebar Settings → W-SETTINGS opens at last tab regardless of why it was opened.
- **find-fast**: ⌘F (key monitor) or Library → Search Library focuses toolbar search (V-SEARCH, main.md). Breaks: ⌘F in Settings/remote windows also jumps to the main window's search; menu item shows no ⌘F.
- **daily-listening** (keyboard parts): ←/→ seek 5 s, ⌘←/⌘→ 10 s, ⌘. stop; **no Space play/pause, no shortcut for Play/Pause, Next, Previous** (wish: spacebar preview, `.planning/research/v1.4-daily-driver/FEATURES.md:114-115`).
- **relaunch** (area flow, shared with backup restore in ST-BACKUP): quit is immediate; the relaunched app shows V-LAUNCH-LOADING; Settings window is not restored.

### Unresolved from code

- Exact system-provided menu contents (About/Services/Hide items, Edit, View — esp. whether `Show Sidebar` / toolbar items exist without `SidebarCommands`/`ToolbarCommands` — Window list, Help) cannot be read from code; verifying requires running the app (forbidden).
- Whether the main window can be reopened after being closed while Settings is open (SwiftUI `Window` scenes normally get a Window-menu entry; clicking the Dock icon may or may not reopen it — no `applicationShouldHandleReopen`).
- Whether bare ←/→ seek fires while a table/grid has focus, or is consumed by list navigation.
- Which ⌘R handler wins when both the hidden Library re-scan button and Sync profile `Refresh` are in the hierarchy; same for ⌘N (menu vs Playlists button — menu usually wins).
- Whether `New Library…` from the File menu during S-ADOPT can present a second sheet (two sheets on one hierarchy).
- Whether ⌘←/⌘→ menu shortcuts actually steal the keys from focused text fields on macOS 15+ (behaviour depends on AppKit key-equivalent dispatch).
- Main window frame persistence across launches (SwiftUI default state restoration; not configured in code).
- Notification user-visible effects for services (ArtworkBackfill, PlaylistCoverService) are described from their observer code only.

