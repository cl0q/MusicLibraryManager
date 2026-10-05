# MLM — B1 design thinking

**Status:** proposal for Oliver's review, 2026-10-05. Written before the mockups; the mockups in this folder implement it.
**Inputs:** `design/B1-UI-INVENTORY.md` (+ area files), `todo_dump.md`, `ROADMAP.md` §3/§4/§6, `A0-LIBRARY-DEFINITION.md`, `UI-GROUNDTRUTH.md` Part 1, `sketches/`, `docs/audit/LIQUID-GLASS-PLAN.md`.
**IDs:** inventory IDs are reused unchanged (`V-LIB.E07`). New things get an `N` (`V-LIB.N01`) or a new screen ID (list in §3.3). Decisions are `DEC-001`…, all in §8.

Contents: [1 What MLM is for](#1-what-mlm-is-for-oliver) · [2 Principles](#2-design-principles) · [3 Information architecture](#3-information-architecture) · [4 Interaction model](#4-interaction-model) · [5 Liquid Glass](#5-liquid-glass--materials-strategy) · [6 Toolkit map](#6-swiftui--macos-toolkit-map) · [7 Per-area concepts](#7-per-area-concepts) · [8 Decision log](#8-decision-log) · [9 Questions](#9-questions-for-oliver)

---

## 1. What MLM is for Oliver

**The daily loop** is *navigate and listen in one surface*: open the window, land in the tracks, a playlist or a folder, arrow through rows, hear a track with the space bar, play it for real with Return, stack a few with Play Next, and drop a selection into a playlist. Everything in that loop must work from the keyboard, give immediate feedback, and never move the user somewhere he didn't ask to go (F-03, F-04, F-08, F-09).

**The chores** happen weekly or less and are all *long-running and fallible*: importing playlists from SoundCloud/YouTube/Spotify and downloading them (F-05, F-06), fixing failed downloads (F-07), reviewing duplicates and conflicts (F-12), triaging recommendations and reels (F-14, F-15), syncing to the iPod (F-10, F-11), backups and library files (F-16, F-17), analysis batches (F-22). They share one need: *say what is happening, where it ended up, and what to do about what failed.*

**Why it feels bad today** (inventory §11.1):

| Today | Evidence |
|---|---|
| The loop's centre is missing: no space-bar preview, no Play/Pause/Next shortcuts; double-click plays *and* opens the inspector; ⌘I is dead | PP-MAIN-02, PP-LIBRARY-02, PP-SHELL-01, PP-INSPECTOR-03 |
| Playback stalls on the first unplayable track; errors blame "the file" for everything | PP-MAIN-01, PP-MAIN-15 |
| The external drive is unplugged most of the time, but "not connected" is a 7 pt dot, then 12,000 red `File missing` chips | PP-SHELL-11, PP-LIBRARY-04, PP-PLAYLISTS-03 |
| Background work is invisible or lossy; a finished batch vanishes; wrong reasons (`Video unavailable` for everything) | PP-ACTIVITY-04/05/06/19 |
| The same thing has two names, two places or two behaviours (Importing/Downloading, Sync/Sync, search filters *or* opens a pane, ⌘N twice) | §8.7, PP-MAIN-31, PP-SHELL-04 |
| Structure is missing: playlists hide behind a grid and an 8-pin limit, albums don't exist, 48 % of tracks read `unknown album`, the open library has no name | PP-PLAYLISTS-38, F-24, PP-SHELL-07 |
| Tools live in odd places: a workspace inside Settings, an import flow in a second window, failures that say "open Settings" where nothing is | PP-INSPECTOR-26, F-05, PP-SETTINGS-41 |

The redesign is therefore mostly **subtraction and unification**: fewer places, one behaviour per gesture, one word per state, and one home for background work.

---

## 2. Design principles

| # | Principle | So in practice… |
|---|---|---|
| P1 | **The list is the app.** | Every destination is a native table, list or grid with the same selection, keyboard, context-menu and drag behaviour. Chrome stays quiet; content gets the space. |
| P2 | **One gesture, one meaning — everywhere.** | Space previews, Return/double-click plays, ⌘I shows info, ⌫ removes from the current container. No view redefines these. |
| P3 | **Nothing moves unless you ask.** | Playing never opens a panel; adding to a playlist never navigates; a finished job never steals focus. Confirmation appears where you already look (status bar) with Undo. |
| P4 | **States are sentences, placed once.** | A state is written in words at the highest level it applies to (drive → window banner, playlist → header, track → Status column). It is never repeated 12,000 times and never an unlabeled dot. |
| P5 | **Every long job has one home.** | Anything slower than ~2 s is an Activity operation with progress, result and a way to stop. The place that started it shows a short inline echo, not a second truth. |
| P6 | **Offline is normal.** | With the drive unplugged MLM is a fully usable catalogue: browse, search, edit tags, build playlists, queue downloads. Only actions that need the files are disabled — with the reason. |
| P7 | **System first, glass with a reason.** | Native containers, system colours, the user's accent. Liquid Glass only on the layer that floats above content (toolbar, sidebar, inspector, selection bar, transient UI). Content is never glass. |
| P8 | **Reversible by default.** | Edits, removals from playlists, review decisions and queue changes go through Undo. Irreversible things (Trash, restore, relaunch) get a consequence-stating confirmation. |

---

## 3. Information architecture

### 3.1 The window

One main window (`Window`, unchanged), three columns, native toolbar:

```
┌ toolbar: ◧  ‹ ›   [＋]        ⏮ ⏯ ⏭ │ cover · title · artist · scrubber │ 🔊 ☰        [Activity]  [ⓘ]  [Search]
├ sidebar ────────┬ content ──────────────────────────────────────────────┬ trailing column (optional)
│ Library         │ banner (only for window-level states)                  │  Info | Queue
│  All Tracks     │ scope bar (filters of this view)                       │
│  Albums         │ table / grid / detail                                  │
│  Genres         │                                                        │
│  Folders        │                                                        │
│ Inbox           │                                                        │
│  Discover    7  │                                                        │
│  Review     14  │                                                        │
│ Playlists       │ selection bar (glass, only with ≥2 selected)           │
│  ▸ Sets         │ status bar: counts · transient confirmation + Undo     │
│  Warm-up        │                                                        │
│ Sync            │                                                        │
│  iPod Classic   │                                                        │
│ ─ Main Library ▾│                                                        │
└─────────────────┴────────────────────────────────────────────────────────┴──────────────
```

- **Sidebar** (DEC-001…004): four sections. *Library* = ways to see the same tracks. *Inbox* = things waiting for a verdict (badges are counts of decisions, not alarms). *Playlists* = every playlist, user-ordered, with playlist folders. *Sync* = one row per sync profile with its state in words. The **footer** names the open library and the drive state and is the library switcher.
- **Toolbar**: sidebar toggle · back/forward · Add (＋) menu · player (`.principal`) with queue button · Activity item · inspector toggle · search field. Section actions (Play, Shuffle, Sync now…) live in the content header of the section, not in the toolbar, so the toolbar never changes shape (fixes P-TOOLBAR.E04 leaking).
- **Trailing column** (DEC-006/007): one system `.inspector` with two modes, *Info* (⌘I) and *Queue* (⌥⌘U). Never opens on its own.
- **No bottom Activity strip** (DEC-005): Activity is a toolbar item with a popover (Safari Downloads pattern) and an Activity window (Mail's Window ▸ Activity pattern) for the full list and the logs.

### 3.2 What is a section, an inspector, a sheet, a settings tab

| Kind | Rule | Examples |
|---|---|---|
| Sidebar destination | A collection the user browses or works through | All Tracks, Albums, Genres, Folders, Discover, Review, each playlist, each sync profile |
| Pushed detail (back button, ⌘[) | One item of a collection | Album detail, playlist detail (from the grid), genre detail, Similar to ‹track› |
| Trailing column | Facts about the selection or the play order | Info (single / multiple tracks), Queue |
| Popover | A glance, dismissed by clicking away | Activity, large cover, new playlist name |
| Sheet | A task with a beginning and an end that blocks the window briefly | Import playlist, new sync profile, link source, M3U preview, read device changes, new library |
| Alert | Consequence confirmation or a failure that needs acknowledgment | Move to Trash, restore, switch library |
| Auxiliary window | Reference that should stay visible next to the main window | Settings (⌘,), Activity (⌥⌘0) |
| Settings tab | A preference or a location, never a workspace or a job list | General, Library, Playback, Sources, Backup, Storage Location, Maintenance, Advanced |

### 3.3 Before / after

| Inventory (today) | After | Decision |
|---|---|---|
| P-SIDEBAR: `LIBRARY` (Library, Playlists+pinned, Folders, Sync, Sources) · `WORK` (Review, Discover) · footer Queue, Settings | Library (All Tracks, Albums, Genres, Folders) · Inbox (Discover, Review) · Playlists (all, with folders) · Sync (profiles) · footer = library switcher | DEC-001…004 |
| V-LIB with `Local`/`Remote` tabs | **All Tracks** with an availability scope bar (`All · Local · Not downloaded · Download failed · File missing`) | DEC-002, DEC-011 |
| — (no album UI) | **V-ALB** album grid → **V-ALBD** album detail (disc/track order, edition picker, other versions) | DEC-019…021 |
| ST-ADV Genre Workshop inside Settings | **V-GENRES** in the sidebar → genre detail with Suggested tracks; Merge and Export as commands | DEC-025 |
| V-PL grid + P-PINNED (max 8) | Playlists section in the sidebar (all playlists, folders, drop targets) + `All Playlists` grid | DEC-003 |
| V-PLD | Playlist detail with a real header; actions in a `More` menu; `Refresh from ‹Source›` | DEC-022, DEC-023 |
| V-FOLD (tree + two tables) | Folders as one hierarchical table (Finder list view) with a path bar | DEC-024 |
| V-QUEUE as 8th sidebar item | **Queue** mode of the trailing column, opened from the player | DEC-006 |
| P-INSPECTOR (HSplitView, 5 custom tabs, opens on double-click, follows now-playing) | System `.inspector`, ⌘I, follows the selection, edits many tracks at once; tabs Details · Audio · File | DEC-007, DEC-008 |
| S-GROOVE-SIMILAR (large sheet) | **V-SIMILAR** pushed view "Similar to ‹track›" | DEC-030 |
| V-SEARCH (two behaviours) + dead S-SEARCH-UNIVERSAL | System search field: filters the current view, scopes `This view · Library · Online`, tokens, link detection (**S-QUICKADD**) | DEC-017, DEC-018 |
| V-SRC as a sidebar section + W-REMOTE window | Accounts in Settings ▸ Sources; **S-IMPORT** sheet from the Add menu; `Refresh from sources` command | DEC-004, DEC-026 |
| V-SYNC list + V-SYNC-DETAIL | Sync profiles as sidebar rows; detail with Content · Plan · Options and per-profile results | DEC-027 |
| V-REV (Duplicates · Conflicts · Resolved) | Review with tabs Duplicates · Conflicts · **Albums** (album suggestions) · Resolved; bulk decisions; optional Trash | DEC-021, DEC-028 |
| V-DISC → V-INBOX / V-REELS | Discover with scopes Recommendations · Reels; keyboard triage; recommendations stay out of All Tracks until kept | DEC-029 |
| P-ACTIVITY bottom panel (Operations / Logs) | Toolbar Activity item + popover (**P-ACTIVITY**) and Activity window (**W-ACTIVITY**: Operations, Logs) | DEC-005, DEC-044 |
| V-LAUNCH-NOLIB / -CANTOPEN / -INVALID / -FAILED / -LOADING | One **library picker** (**V-PICKER**) with per-library states; loading with name and phase; failure with actions | DEC-031, DEC-032 |
| S-WIZARD scrim overlay | In-window setup, three steps, skippable, continues in the background | DEC-034 |
| W-SETTINGS (AppKit, 7 tabs) | SwiftUI `Settings` scene, 8 tabs, deep-linkable; Genre Workshop out; tools and backup schedule in | DEC-035…037 |
| No multi-selection affordance | **P-SELBAR** selection bar + **P-STATUSBAR** status bar | DEC-015, DEC-016 |

New screen IDs used by the mockups: `V-ALB`, `V-ALBD`, `V-GENRES`, `V-GENRED`, `V-SIMILAR`, `V-PICKER`, `V-SETUP`, `W-ACTIVITY`, `P-SELBAR`, `P-STATUSBAR`, `P-QUEUE`, `P-PREVIEW`, `P-LIBFOOTER`, `P-ADDMENU`, `S-IMPORT`, `S-QUICKADD`, `S-PLFOLDER-NEW`, `ICON-MLIBM`. Further sheets, alerts and menus added while mocking are listed at the end of `COVERAGE.md` ("New in this design").

---

## 4. Interaction model

### 4.1 Selection

- Every track list is a native `Table` with `Set<Track.ID>` selection: click, ⇧-click, ⌘-click, ⌘A, ↑/↓, ⇧↑/↓, type-to-select (first letters of Title; in grids the item name).
- Selection is **the** argument of every command: menus, toolbar, context menu, drag, inspector, space bar. A right-click outside the selection acts on that row only (`contextMenu(forSelectionType:)`).
- 1 selected → inspector shows it. ≥2 selected → inspector shows the multi-edit form; the **selection bar** (P-SELBAR) appears above the status bar with the five most-used batch actions and the selection's count and duration.
- Selection survives sort, filter and refresh; it is cleared only by navigating away. Tables never blink to a spinner on refresh (rows update in place).

### 4.2 Keyboard (complete map in `patterns-menus-shortcuts.html`)

| Key | Meaning everywhere |
|---|---|
| Space | **Preview** the selected track; Space again (or Esc) ends the preview and resumes what was playing. With no selection, or focus outside a list: Play/Pause. With several rows or a track without a file selected: nothing plays and the status bar says why. (DEC-009) |
| Return / double-click | **Play** the selected track; the rows after it become the queue context. Never opens anything. On a not-downloaded row: starts the download and says so in the status bar. (DEC-008) |
| ⌥Return | Play Next · ⌥⇧Return Add to Queue |
| ⌘I | Show/hide Info for the selection (trailing column) |
| ⌥⌘U | Show/hide Queue |
| ⌘L | Go to the current track (selects it in its playing context) |
| ⌘F | Search (system field); ⌥⌘F search the whole library |
| ⌫ | Remove from the current container (playlist, queue, sync profile) — undoable. In All Tracks ⌫ does nothing; ⌘⌫ = Remove from Library… (confirmation) |
| ⌘D | Download the selection's not-downloaded / failed tracks |
| ⌘N / ⇧⌘N / ⌥⌘N | New playlist (inline rename in the sidebar) / New playlist from selection / New playlist folder |
| ⌘U | Add from link… (S-QUICKADD) · ⇧⌘I Import playlist from source… · ⌘O Open library… |
| ⌘→ / ⌘← | Next / Previous track · ⌥⌘→ / ⌥⌘← seek ±10 s · ⌘↑ / ⌘↓ volume · ⌘. stop |
| ← / → | Only while previewing: seek ±5 s (Quick Look feel). Otherwise they belong to the focused control (outline expand/collapse, text caret). |
| ⌘1…⌘6 | All Tracks, Albums, Genres, Folders, Discover, Review · ⌘[ / ⌘] back / forward · ⌃⌘S sidebar · ⌥⌘0 Activity window · ⌘, Settings |
| ⌘R | Refresh the current view's source of truth (scan this folder, refresh this linked playlist, recompute this sync plan) — one meaning: *re-read from outside* |
| ⌘Z / ⇧⌘Z | Undo / Redo (see 4.6) |

Conflicts removed: ⌘N has one meaning; ⌘8 is gone; ⌘R is one concept; ⌘F is the system search command, scoped to the main window; plain ←/→ no longer steal keys from tables and text fields.

### 4.3 Double-click, Return, primary action

| On | Primary action |
|---|---|
| Local track | Play (queue = following rows of this view) |
| Not downloaded / Download failed track | Download (Retry) it; status bar: `Downloading "‹title›" — it will play when ready` with `Cancel` |
| File missing track | Status bar: `File missing — Locate… · Download again` (never a bare playback error) |
| Any track while the drive is not connected | Status bar: `Can't play — "Lexxar" is not connected` |
| Album / playlist / genre card or sidebar row | Open it (double-click a card's cover play-badge or ⌥-double-click: play it) |
| Folder row | Expand / collapse; ⌘↓ opens it as the root |
| Sync profile | Open it |
| Review group / recommendation / reel | Expand / select; Return = recommended action |

### 4.4 Context menus — one order rule (DEC-039)

Every context menu and every `More` (•••) menu uses the same groups in the same order; groups that don't apply disappear, they don't get disabled placeholders:

1. **Primary** — Play · Open
2. **Queue** — Play Next · Add to Queue
3. **Add to** — Add to Playlist ▸ · Add to Sync Profile ▸
4. **Info / edit** — Get Info · Rename · Go to Album · Go to Artist · Find Similar
5. **Fix** — Download · Retry Download · Refresh from ‹Source› · Locate File…
6. **Locate / share** — Show in Finder · Copy ▸ (Title — Artist, File Path, Link) · Share…
7. **Remove** — Remove from ‹Container› · Remove from Library… (always last, always separated)

Labels are verbs in Title Case as in every macOS menu (`Add to Playlist`, `Show in Finder`). With more than one target the count goes into a first, disabled header line (`3 tracks`), like Finder — not into every label.

### 4.5 Drag & drop (DEC-040; catalogue in `patterns-dnd.html`)

Tracks, albums, playlists and folders are `Transferable` with two representations: an internal one (IDs) and `public.file-url` for local files, so the same drag works inside MLM and into Finder, Mail or DJ software.

| Drag | Onto | Result |
|---|---|---|
| Tracks / album / folder | Sidebar playlist | Append (insertion line if hovering between rows of an open playlist) |
| Tracks | Sidebar `Playlists` header or empty area | New playlist from selection (inline name) |
| Tracks / playlist / album | Sidebar sync profile | Add to that profile |
| Tracks | Player | Play Next |
| Tracks | Queue panel | Insert at the drop line (top of `Next` = Play Next, further down = position in the queue) |
| Rows inside a playlist / queue / album-order editor | Same table | Reorder |
| Playlist | Playlist folder / between rows | Move / reorder |
| Audio files or folders from Finder | Any track list or the sidebar library section | Import (Activity operation) — onto a playlist: import and add |
| Image from Finder / browser | Playlist or album cover (grid, header, inspector) | Set cover |
| `.m3u` | Playlists section | Import as playlist (preview sheet) |
| Link (URL) | Window / search field | S-QUICKADD |
| `.mlibm` | Window or library picker | Open / switch library |
| Folder from Finder | A path field in Settings or setup | Set that location |

Spring-loading stays (system behaviour of `List` drop targets) but is never *required* — the sidebar rows accept the drop directly.

### 4.6 Undo (DEC-041)

`UndoManager` on the window. Undoable: tag edits (single and multi), add/remove/reorder in playlists and albums, playlist rename/move/delete (delete keeps the playlist restorable until quit), queue edits, review decisions, recommendation keep/dismiss, sync-profile content changes, genre merge. Not undoable (confirmed instead): Move to Trash, Remove from Library, restore backup, path migration (has its own rollback), switching library. After an undoable action the status bar shows what happened plus an `Undo` button for 8 s; Edit ▸ Undo names it (`Undo Add to "Warm-up"`).

### 4.7 Search (DEC-017/018)

- One system search field (`.searchable`, toolbar). **Typing always filters the current view in place** — tracks, albums, playlists, folders, genres, review groups. No results pane appears by surprise.
- A **scope bar** appears under the toolbar while searching: `This view` (default) · `Library` (everything, grouped: Tracks, Albums, Playlists, Folders) · `Online` (SoundCloud, YouTube, Spotify, DAB). Online results are never written to the library until the user presses `Download` or `Add` (fixes PP-MAIN-04).
- **Tokens**: typing `artist:`, `album:`, `genre:`, `year:`, `bpm:`, `is:` produces suggestions that become tokens (`genre: Techno`, `is: not downloaded`, `bpm: 120–128`). Suggestions also list recent searches.
- **Links**: pasting or dropping a URL shows a suggestion row instead of results — `Download track from YouTube` / `Import playlist from SoundCloud…` (S-QUICKADD / S-IMPORT). This is the path the four `sketches/` were about.
- The query belongs to the view: navigating away keeps it for when you come back in the same session; Esc clears it.

### 4.8 Background work feedback (DEC-044)

| Where | Shows |
|---|---|
| Toolbar **Activity item** | Idle: plain icon. Running: determinate ring + short text (`Downloading 12 of 44`). Needs attention: text `9 failed` stays until dismissed or fixed. Never only a colour. |
| **Activity popover** | Running (progress, Pause/Cancel), Needs attention (grouped by cause, `Retry all`, `Dismiss`), Recent (results with counts, kept across relaunch). Each row links to its subject. |
| **Activity window** | Full operations history and Logs (filters persist, `Export…`, deep link from a failure to its log lines). Available on every launch state. |
| **The place that started it** | A short echo: playlist header line `Importing · 12 of 44`, sync profile plan, settings job row. Same numbers, same words. |
| **Status bar** | The moment of starting and finishing: `Download started — 44 tracks` · `Import finished — 35 downloaded, 9 failed · Show`. |
| **Sidebar** | Counts for Inbox rows; state text under sync-profile rows; nothing for generic work. |

### 4.9 Empty, loading, error, offline (catalogue in `patterns-states.html`)

- **Empty** = `ContentUnavailableView` with one sentence and the one action that fills it (`Import music…`, `New playlist`, `Run scan`). Filtered-empty uses the system search variant plus `Clear filters`.
- **Loading** = content stays; a small spinner appears in the status bar after 300 ms. First load of a view shows redacted placeholder rows, never a full-pane spinner.
- **Error** = sentence + cause + one action (`Try again`, `Reconnect`, `Open Settings ▸ Sources`), `Details` disclosure for the raw text, link to the log lines.
- **Drive not connected** (DEC-014) = one banner at the top of the content column in every view that shows tracks: `"Lexxar" is not connected. You can browse, edit and queue downloads; playback and file actions are paused.` The sidebar footer repeats it in two words. Rows of local tracks are dimmed; the Status column stays empty; file actions are disabled with the reason in their help text. When the drive returns: status bar `"Lexxar" connected` + `Resume` if something was playing.
- **Huge data** = default; counts with thousands separators in the status bar; grids are lazy; no view requires scrolling to learn its state.

---

## 5. Liquid Glass & materials strategy

Glass is the **navigation and control layer that floats above content**. If a surface holds the user's data, it is not glass.

| Surface | Glass? | What it improves | macOS 26+ API | macOS 15 fallback |
|---|---|---|---|---|
| Toolbar incl. player, item groups | Yes (system) | Content scrolls under a legible control layer; groups read as units | Standard toolbar built with the 26 SDK; `ToolbarSpacer`, `.sharedBackgroundVisibility` for the player group | Standard unified toolbar (`.bar` material) |
| Sidebar | Yes (system) | Floats over content; artwork headers can extend beneath it | `NavigationSplitView` default; `.backgroundExtensionEffect()` on album/playlist header artwork | Standard sidebar vibrancy |
| Trailing column (Info / Queue) | Edge only (system) | Same layer as the sidebar; content inside is a plain `Form`/`List` | `.inspector` | `.inspector` (macOS 14+) |
| Scroll edge under the toolbar | Yes (system) | Table headers and rows stay readable while scrolling beneath the toolbar | `.scrollEdgeEffectStyle(.soft, for: .top)` | Default opaque bar edge |
| **Selection bar** (P-SELBAR) | Yes (custom, the one custom glass surface) | A transient control cluster floating above the rows it acts on | `GlassEffectContainer { … .glassEffect(.regular.interactive(), in: .capsule) }`, `.buttonStyle(.glass)` | `.background(.regularMaterial, in: .capsule)` + hairline stroke |
| Popovers, menus, sheets, alerts | System defaults | — | none (no custom `presentationBackground`) | same |
| Activity popover, Queue panel | System container only | — | — | — |
| Tables, lists, grids, album/playlist cards, banners, status chips, text, artwork, waveform | **No** | Data must not depend on what is behind it | Opaque content background; banners use a quiet tinted fill (`.quaternary`-level) | same |

**Hierarchy:** content (opaque) → window-level banner (opaque, tinted) → selection bar (glass, bottom) → sidebar/inspector/toolbar (system glass) → transient UI. Never glass on glass: nothing custom inside the toolbar gets its own material (the player has no background of its own — fixes the double-material risk in `LIQUID-GLASS-PLAN.md` §4).

**Colour:** system semantic colours only. The accent colour appears on selected controls, links and the now-playing marker — never as a background fill for areas. Status uses `.secondary` text plus an SF Symbol; only *Download failed* / *File missing* / errors use the system red/orange symbol tint, with text carrying the meaning. Source brands appear as a 6 pt dot before the source name, nothing more.

**Motion:** system transitions only. The selection bar morphs in with the container's glass transition (`glassEffectID`), symbol effects mark state changes (`.symbolEffect(.bounce)` on the Activity item when a job ends, `.variableColor` on the now-playing glyph). Everything honours Reduce Motion and Reduce Transparency (glass → opaque `windowBackground`).

**One isolation point:** a single `MLMGlass` helper owns every `#available(macOS 26, *)` check (`selectionBarBackground()`, `extendBackground()`), so availability checks are not sprinkled through views.

*Mockup note: the HTML approximates glass with `backdrop-filter: blur() saturate()`; real refraction and specular highlights can't be reproduced in a browser.*

---

## 6. SwiftUI / macOS toolkit map

| Tool | Verdict | Where / why |
|---|---|---|
| `NavigationSplitView` (2 columns) + `NavigationStack` in the detail | **Use** | Shell; pushed album/playlist/genre/similar details with back/forward |
| `List(selection:)` `.listStyle(.sidebar)`, `Section`, `DisclosureGroup`, `.badge`, `.onMove`, `.dropDestination` | **Use** | Sidebar incl. playlist folders and drop targets; system section headers (fixes PP-MAIN-43) |
| `Table` + `TableColumnCustomization` + `KeyPathComparator` sort | **Use** | Every track list; column show/hide/reorder persisted per view (`@SceneStorage`) |
| `DisclosureTableRow` / hierarchical `Table(children:)` | **Use** | Folders |
| `LazyVGrid` in `ScrollView` | **Use** | Albums, All Playlists, Genres (content, opaque) |
| `.inspector(isPresented:)` + `.inspectorColumnWidth` | **Use** | Info / Queue column |
| `Form` `.formStyle(.grouped)`, `LabeledContent`, `GroupBox` | **Use** | Inspector, Settings, sheets, sync options |
| `.searchable(text:tokens:…)`, `.searchScopes`, `.searchSuggestions` | **Use** | Search |
| `.toolbar` with `ToolbarItem(placement:)`, `ToolbarSpacer`, customizable toolbar (`.toolbar(id:)`) | **Use** | Shell; customization lets Oliver drop Add or Activity if he wants |
| `.commands`, `CommandMenu`, `FocusedValue` | **Use** | Menu bar driven by the focused selection, so every command has a menu item and enables correctly |
| `contextMenu(forSelectionType:menu:primaryAction:)` | **Use** | All tables: context menu + double-click/Return in one place |
| `.onKeyPress(.space)` on focused tables + `.focusable` | **Use** | Space preview |
| Quick Look (`QLPreviewPanel`, `.quickLookPreview`) | **Not used** | It is a floating panel (rejected chrome), can't be driven as a queue-aware audio preview, and shows remote tracks as nothing. The *behaviour* is copied (DEC-009/010), the panel is not. |
| `Transferable`, `.draggable`, `.dropDestination` | **Use** | §4.5 |
| `UndoManager` (`@Environment(\.undoManager)`) | **Use** | §4.6 |
| `ContentUnavailableView` (+ `.search`) | **Use** | Every empty / no-results / unavailable state |
| `ProgressView` (linear/circular), `Gauge` | **Use** | Activity rows, device capacity (`.gaugeStyle(.accessoryLinearCapacity)`), import progress |
| Swift Charts | **Use, narrowly** | Storage Location breakdown; sync plan size vs free space; BPM/energy histogram in a genre detail. Not in tables. |
| `Canvas` | **Use** | Waveform (Audio tab, preview scrubber) |
| SF Symbols + `.symbolEffect`, `.symbolVariant`, `.contentTransition(.symbolEffect(.replace))` | **Use** | Play/pause morph, now-playing, Activity completion |
| `ShareLink` | **Use** | Share a track file — the place where provenance stripping applies (L10) |
| `Settings` scene + `TabView` | **Use** | Replaces the AppKit settings window; `openSettings` + a tab binding for deep links (fixes PP-SHELL-33) |
| `Window(id: "activity")`, `openWindow` | **Use** | Activity window |
| `.fileImporter`, `.fileExporter`, `.fileDialogMessage` | **Use** | Every folder/file choice (replaces hand-rolled `NSOpenPanel`) |
| `.confirmationDialog` / `.alert` with roles | **Use** | All confirmations; destructive role, consequence text |
| `.navigationTitle` / `.navigationSubtitle` | **Use** | Title = current place; subtitle = `‹Library name›` + count |
| Now Playing / `MPRemoteCommandCenter` | **Keep** | Already wired; add like/skip nothing |
| Dock menu (`applicationDockMenu`) | **Use, small** | Play/Pause, Next, Previous, current title, Open Recent library |
| TipKit | **Use, three tips only** | Space-bar preview, drop on sidebar playlists, ⌘I. One at a time, never again after dismissal. |
| App Intents / Shortcuts | **Later** | `Add link to MLM`, `Play playlist`, `Back up library` are natural, but nothing in B1 depends on them |
| Spotlight (`CSSearchableItem`) | **Later** | Useful for tracks/playlists; needs a per-library index story first |
| `MenuBarExtra` mini player | **Not used** | Media keys + Now Playing + Dock menu cover it; a second player surface contradicts "one surface" |
| `.windowStyle(.hiddenTitleBar)`, custom chrome, floating overlays | **Banned** | Locked decision L2 |
| `TabView` in the main window | **Not used** | Sidebar is the navigation; tabs only in Settings and as segmented scopes |
| System notifications (`UNUserNotification`) | **Use, opt-in** | Only for jobs that finish while MLM is in the background (import, sync, backup failure). Off by default in Settings ▸ General. |

---

## 7. Per-area concepts

Each block: goals (inventory IDs) → concept → what changes → risks. Mockup file in brackets.

### 7.1 Shell: window, sidebar, toolbar [`shell.html`]
- **Goals:** P-SIDEBAR goals 1–4, V-MAIN-LAYOUT 1–4, G-LIB-CURRENT, G-DRIVE-OFFLINE.
- **Concept:** §3.1. Sidebar rows carry text state where critical: a sync profile row has a second line (`Not connected`, `12 to add`, `Synced 2 h ago`); Inbox rows have count badges. The footer (P-LIBFOOTER) reads `Main Library` / `Lexxar — not connected` and opens the library menu (Open Recent, Open Library…, New Library…, Show Library File in Finder, Library Settings…). Window subtitle repeats the library name.
- **Changes:** Queue, Settings and Sources leave the sidebar; playlists and sync profiles enter it; dots become words; toolbar is constant.
- **Risks:** a long playlist list pushes Sync down — sections are collapsible and their state persists; at 900 pt window width the player's text column collapses first, then Activity text, then Add.

### 7.2 All Tracks [`library.html`]
- **Goals:** V-LIB goals 1–10.
- **Concept:** one table of every track. Scope bar by availability with live counts (DEC-011); Status is a real, sortable column. Default columns: Title (cover + now-playing glyph), Artist, Album, Time, BPM, Energy, Genre, Added, Status; the rest via header right-click (DEC-012). Energy shows the number plus a quiet 5-step bar (DEC-046). `unknown album` and source names render as nothing (`—`) (DEC-013). Status bar: `12,935 tracks · 38 days · 412 GB` or `14 selected · 52 min`. The view has no header buttons: `Play` and `Shuffle` live in the Playback menu and act on the current view (`Shuffle All Tracks`), so the view stays a pure table.
- **Changes:** tabs → scopes; no spinner flash; failed rows show reason + attempts in help text and in the inspector's File tab; `Retry download` exists by name.
- **Risks:** per-row file-existence checks must go (availability becomes persisted state, refreshed by scans and mount events).

### 7.3 Albums — new [`albums.html`]
- **Goals:** F-24 1–5, WISH-06/07.
- **Concept:** **V-ALB** = cover grid, sortable (Artist, Title, Year, Recently added), scopes `All · Complete · Incomplete · Compilations`. Tracks without an album are *not* an album: a quiet footer line says `6,341 tracks have no album` with `Show` (All Tracks filtered by `is: no album`) and `Find albums…` (Review ▸ Albums). **V-ALBD** = header (cover, title, album artist, `2019 · Techno · 12 tracks · 58 min`, Play, Shuffle, More) and a fixed-order track list grouped by disc with track numbers; no sort headers. Tracks the album has but the library doesn't are shown greyed as `Not in library` with `Find` (only when a tracklist is known). **Editions** (DEC-020): a picker in the header subtitle (`Standard edition ▾`) lists variants (`Deluxe`, `2021 Remaster`); choosing one makes it the preferred edition (stored in `user_album_variant_pref`); an `Other versions` shelf at the bottom shows them as cards. `Edit Order` in More enters a reorder mode (drag rows, renumber) for albums whose numbers are missing.
- **Data model (DEC-019):** `album_tracks(album_id, track_id, disc, position)` mirroring `playlist_tracks`, seeded from file tags; the file tag is the import source, the join is the truth. A track can sit on more than one album (single + album).
- **Changes:** everything is new. Album column values become links (`Go to Album`).
- **Risks:** 8,020 album rows for 1,616 titles need the dedup pass before the grid is pleasant; until C1–C3 land, the grid shows only albums with ≥2 tracks or a known tracklist, to avoid 5,000 one-track "albums".

### 7.4 Genres — new home for the Genre Workshop [`genres.html`]
- **Goals:** V-LIB goal 6, F-21, PP-INSPECTOR-26.
- **Concept:** **V-GENRES** = list of genres with track counts (a browse dimension Oliver uses when picking for a set). **V-GENRED** = that genre's tracks plus a collapsible `Suggested tracks` section (similarity-based; preview with Space, `Add to genre` stages, `Save n changes` commits — undoable). `Merge genres…` acts on ≥2 selected genres (sheet with canonical name + preview table). `Export Create ML training set…` is File ▸ Export.
- **Changes:** leaves Settings; staged edits can't be lost by closing a window; German label gone.
- **Risks:** adds a sidebar row for a rare task — justified because the *browse* part is weekly.

### 7.5 Folders [`folders.html`]
- **Goals:** V-FOLD purpose, F-09, WISH-08.
- **Concept (DEC-024):** one hierarchical table like Finder's list view: folder rows with disclosure triangles and counts (`48 tracks`), track rows inside with the same columns as All Tracks. Path bar at the bottom (click to jump, drag target). Files on disk that aren't in the library appear inline, dimmed, Status `Not in library`, with a header line `14 files in this folder aren't in the library · Import` (Activity operation with result). `Managed by MLM` is a small secondary label on app-owned folders. ⌘R rescans the selected folder. Filter field (search scope `This view`) finds folders *and* tracks.
- **Changes:** tree + two tables → one table; import gets progress and a result; root-level files are reachable.
- **Risks:** moving/renaming folders from MLM stays out of scope (Show in Finder); the table must lazy-load children.

### 7.6 Playlists and playlist detail [`playlists.html`]
- **Goals:** V-PL, V-PLD goals; F-08, F-23; WISH-09/11; PP-PLAYLISTS-01/02/38/39.
- **Concept (DEC-003/022/023):** all playlists in the sidebar, user-ordered, in optional **playlist folders**; `All Playlists` opens the cover grid (sort: Manual, Name, Recently added, Recently played; filter by source and by `Needs attention`). Detail header: 160 pt cover (drop target), editable title, `44 tracks · 2 h 51 min · Linked to SoundCloud`, buttons `Play`, `Shuffle`, `More` (Download n missing, Refresh from SoundCloud, Add to Sync Profile ▸, Rename, Choose Cover…, Link Source…, Import M3U into This Playlist…, Delete Playlist…). One status sentence under the header when not healthy: `Importing · 12 of 44` / `Incomplete · 9 failed · Retry all · Show` / `Not downloaded · 44 tracks · Download all`. Table: `#` (manual order; dimmed and drag disabled with a hint while sorted otherwise), same columns as All Tracks, `Added` = added to this playlist. Scope bar `All · Download failed (9)` replaces the failed-tracks disclosure; the reason is the row's second line in that scope.
- **Changes:** pinning and its 8-limit disappear; `Sync` on a playlist becomes `Refresh from ‹Source›`; Play is always there (disabled with reason instead of hidden); M3U import says where it goes.
- **Risks:** a sidebar with 60+ playlists — folders and collapse state handle it; `All Playlists` remains for covers.

### 7.7 Queue [`queue.html`, in the shell]
- **Goals:** V-QUEUE purpose; PP-MAIN-36.
- **Concept (DEC-006):** trailing-column mode with three sections: `Now playing`, `Next` (Play Next items, then `From ‹context›`), `History`. Rows: cover, title, artist, time, Status text when unplayable. Reorder by drag, ⌫ removes, `Clear` button, `Save as Playlist…`. Persisted across relaunch. Unplayable items are skipped during playback with a status-bar note (`Skipped 2 tracks that aren't downloaded · Download`) (DEC-045).
- **Changes:** from a destination to a panel you can keep open while browsing; safe menu (no Remove from Library here).
- **Risks:** inspector and queue share one column — you can't see both; accepted (Music does the same).

### 7.8 Player and preview [`player.html`, in the shell]
- **Goals:** P-PLAYER goals 1–6; WISH-10.
- **Concept (DEC-009/010/045):** toolbar player = transport, cover (click → large cover popover), title/artist (click → ⌘L), scrubber with times, volume (persisted), queue button. States in words inside the title area: `Not playing`, `Preview`, `Can't play — not downloaded · Download`, `Can't play — file missing · Locate…`, `Can't play — "Lexxar" is not connected`. **Preview** (P-PREVIEW): Space on a selected track switches the player into a preview state — label `Preview`, the previewed title, a waveform scrubber starting at the track's hot spot (the analysed drop, else 0:30), hint `Space to stop · Return to play`. Arrowing to another row moves the preview with the selection. Ending the preview resumes the previous track where it was. The queue is untouched.
- **Variant B:** the preview appears as a bar docked above the status bar (wider waveform), the toolbar player keeps showing the paused main track.
- **Risks:** Space = preview takes the Music convention (Space = play/pause) away when a different row is selected — see Q1.

### 7.9 Search [`search.html`]
- §4.7. **Changes:** native field, one behaviour, scopes, tokens, link detection, no library pollution, results keep Status and sorting. **Risks:** `Library`-scope grouped results need a second layout (sections with `Show all`).

### 7.10 Track inspector [`inspector.html`]
- **Goals:** P-INSPECTOR purpose; F-13; PP-INSPECTOR-04/05/06.
- **Concept (DEC-007):** `Form` in the system inspector. Header: cover (drop target), title, artist, format line. Tabs (segmented): **Details** (Title, Artist, Album, Album artist, Track/Disc, Genre, Year, BPM, Comment; `In playlists` list with remove), **Audio** (waveform, energy, danceability, loudness as labeled values with `Analyze`, top-5 similar with `Show all` → V-SIMILAR), **File** (location, format, size, availability sentence with its fix action, source as `Linked to SoundCloud`, duplicate hint with a working link, `Diagnostics` disclosure replacing the Debug tab). Fields commit on Return/blur, never across a track change (the form is keyed to the selection). **Multiple selection:** same form, mixed values show `Mixed`, edits apply to all with one undo step. `Write tags to files` is a toggle in Settings ▸ Library (default on) so shared files carry the fix (and never the source).
- **Changes:** ⌘I works; no auto-follow of now-playing (⌘L then ⌘I does that); 5 tabs → 3; batch editing exists.
- **Risks:** tag writing touches files on the external drive — queued while offline (`3 tag changes waiting for "Lexxar"` in Activity).

### 7.11 Add menu, quick add and import [`import.html`]
- **Goals:** F-05, F-06, V-SRC, W-REMOTE; WISH-13.
- **Concept (DEC-004/018/026):** toolbar `＋` (P-ADDMENU): New Playlist, New Playlist Folder, — Add from Link… ⌘U, Import Playlist from Source… ⇧⌘I, Import Files or Folder…, Import M3U… — Refresh from Sources. **S-QUICKADD**: a small sheet (also what a pasted link in search opens): detected item (cover, title, source), `Download` / for playlists `Import…`; already-in-library is stated. **S-IMPORT**: one sheet, three steps — (1) source: connected accounts' playlists or a pasted URL; (2) preview table: every track with `In library` / `New`, choice `All · First n · Random n`, toggles `Download now` and `Keep linked to ‹Source›` (off = one-time import, WISH-13); (3) confirmation line → closes; progress continues on the playlist and in Activity. Sign-in problems appear in step 1 as `Sign-in expired · Reconnect` in place.
- **Changes:** second window gone; import result lives on the playlist; a second batch queues instead of being rejected.
- **Risks:** removing the Sources section costs discoverability of "pull my likes" — covered by the Add menu, the File menu and an optional schedule (Settings ▸ Sources).

### 7.12 Activity [`activity.html`]
- §4.8. **Concept (DEC-005/044):** P-ACTIVITY popover and W-ACTIVITY window. Every job kind in inventory §10.1 becomes an operation with a subject link, a result that persists, and honest controls (`Cancel after this track` when that is the truth; no Cancel when there is none). Failures are grouped by cause with the fix: `yt-dlp not found · Open Settings ▸ Sources`, `Sign-in expired (SoundCloud) · Reconnect`, `"Lexxar" not connected · 14 waiting`. Logs: level/source filters persist, pause is a labeled button, `Export…`, `Copy`.
- **Variant B:** keep a bottom bar, restyled as a status-bar-height strip (kept for comparison).
- **Risks:** a popover hides running work more than a strip — the toolbar item's text mitigates it.

### 7.13 Review [`review.html`]
- **Goals:** V-REV purpose; F-12; PP-SOURCES-01/11/16.
- **Concept (DEC-021/028):** tabs `Duplicates · Conflicts · Albums · Resolved`. A group is a list row that expands into a comparison table (one row per version: format, bitrate, duration, location, playlists using it; recommended one marked in words). Decisions: `Keep recommended` (default, Return), `Keep selected`, `Keep all — not duplicates`. What happens to the others is explicit and chosen once in the header: `Unkept versions: ○ stay in library, hidden from lists  ○ move to Trash` — playlists are re-pointed to the kept version either way. `Apply recommended to all 14…` for bulk. **Albums** tab: album suggestions for tracks without one (`Suggested: "Selected Ambient Works 85–92" — MusicBrainz, 96 % match`), accept/reject per row or in bulk, plus the place where YouTube mixes get `No album` on purpose.
- **Changes:** decisions stick and have consequences; scan is an Activity operation; resolved groups aren't re-proposed.
- **Risks:** moving files to Trash from Review is new behaviour — off by default.

### 7.14 Discover: recommendations, reels, similar [`discover.html`]
- **Goals:** V-INBOX, V-REELS, S-GROOVE-SIMILAR; F-14, F-15.
- **Concept (DEC-029/030):** Discover with scope `Recommendations · Reels`. **Recommendations**: list grouped by seed (`Because of "‹track›"`), Space previews (same preview as everywhere), `K` Keep, `⌫` Dismiss (to Trash, undoable until the Trash is emptied), status bar confirms. Recommendations don't appear in All Tracks until kept. `Find recommendations…` starts a search from here (seed = selection or now playing). **Reels**: master–detail; left list of videos with a state word (`New`, `Identified`, `Done`); right: the video frame, **Guesses** as a list with provenance (`File name`, `Shazam`, `Text in video`) — choosing one fills Artist/Title, nothing overwrites silently; **Results** per source with `Download` / `Add to Playlist ▸` and inline state. **V-SIMILAR**: `In library` and `Online` sections for a seed track; online rows have `Preview` (30 s stream) and `Download`; no Delete that can hit library tracks.
- **Risks:** "held outside the library" needs a flag in the track model (pending recommendation).

### 7.15 Sync [`sync.html`]
- **Goals:** V-SYNC, V-SYNC-DETAIL, S-SYNC-DEVICEINGEST; F-10, F-11.
- **Concept (DEC-027):** each profile is a sidebar row (drop target). Detail: header (name, destination path, `Connected` / `Not connected`, capacity gauge), `Sync now` + `More` (Read Playlist Changes from Device…, Rename, Duplicate, Change Destination…, Delete). Sections: **Content** (Playlists, Albums, Tracks — each with `Add…`), **Plan** (`Add 214 · Remove 12 · Skip 9 · 3.1 GB of 12 GB free`; `Skip` lists not-downloaded/missing tracks by name with `Download`), **Options** (format, playlists files, clean up, paths), **Last sync** (result and failures of *this* profile, `Retry failed`). While syncing: progress in the header, Pause/Cancel; device removal → `"iPod" was disconnected — 86 of 214 copied · Resume when connected`. **Device ingest** sheet: per playlist a diff (`+3 −1 on device`), per-entry checkboxes, `Apply` merges instead of replacing, undoable.
- **Risks:** library drive offline + device online = nothing to copy → Plan says so (`Can't sync — "Lexxar" is not connected`).

### 7.16 Settings [`settings.html`]
- **Goals:** ST-* purposes; F-16, F-19, F-20, F-22.
- **Concept (DEC-035…037):** `Settings` scene, tabs: **General** (Open the last library at launch; space bar behaviour; notifications), **Library** (library file: name, location, Show in Finder, Rename…; library folder: path, state, Change… with consequences sheet; import; write tags to files), **Playback** (normalisation with its dependency explained; history/queue sizes under `Advanced`), **Sources** (accounts with `Connected` / `Disconnected` / `Sign-in expired` + Connect/Reconnect/Disconnect in place; refresh schedule; **Download tools**: yt-dlp, ffmpeg, fpcalc, scdl with `Found 2025.09` / `Not found · How to install`; Qobuz cookie), **Backup** (schedule: Off/Daily/Weekly/On quit; keep last n; destination; list; Back Up Now; Restore…), **Storage Location** (grouped *In this library file* / *On this Mac* / *Library folder*, sizes chart, reachability), **Maintenance** (jobs as rows with coverage `9,412 of 12,935 analysed`, last run, `Run` → Activity; background processing; transcode cache; organized paths), **Advanced** (credentials file location, diagnostics, reset tips).
- **Changes:** Genre Workshop out; deep links (`Open Settings ▸ Sources`) land on the right tab; with no library open, per-library controls are disabled with one explanatory line.

### 7.17 Library picker, launch states, library switching [`launch.html`]
- **Goals:** V-LAUNCH-*, F-01, F-02, F-17; A0 D5; WISH-05.
- **Concept (DEC-031/032):** **V-PICKER** fills the window when no library is open: list of known libraries (icon, name, location, last opened, state in words: `Not connected — on "Lexxar"`, `Not found`), `Open`, and below `New Library…`, `Open Other…`, checkbox `Open the last library at launch`. A problem with one library is that row's state plus actions (`Try Again`, `Locate…`, `Remove from List`), not a separate screen. Loading: `Opening "Main Library"…` with a phase line (`Backing up before update…`, determinate). Failure: sentence, `Details`, actions `Try Again`, `Choose Another Library`, `Restore from Backup…`, `Show Logs`. Switching (menu, footer, Finder): if work is running, the alert lists it (`2 downloads and 1 sync will stop`) with `Switch and Relaunch` / `Cancel`.
- **Adoption (S-ADOPT):** stays a sheet over the picker with phases; `Not Now` returns to the picker with the old install listed as `Main Library (needs setup)`.

### 7.18 First run [`launch.html` → setup]
- **Concept (DEC-034):** **V-SETUP** inside the window, no scrim: (1) name and location of the library file (default Application Support, with the why in one line); (2) library folder — button or drop a folder; shows reachability; (3) `Scan and import` with progress and `Continue in Background`. `Set Up Later` leaves an empty All Tracks with an `Import music…` empty state.

### 7.19 Library-file icon [`library-icon.html`]
- **Concept (DEC-033):** a document-proportioned icon in the app icon's visual language but reading as *a collection*: a record crate seen from the front — three sleeve edges fanned behind a front sleeve that carries the MLM mark. Static `.icns`. Three variants shown (A crate, B stacked sleeves, C document with folded corner + mark); A recommended because it stays legible at 16 pt in Open Recent and the picker.

### 7.20 Sheets, alerts, menus, states, drag & drop [`patterns-*.html`]
- One catalogue page each. Sheets: title = the task, one primary button named by its verb (`Import 44 Tracks`), Cancel on Esc, errors inline above the buttons. Alerts: title states the question, message states the consequence, destructive role on the destructive button, never `OK` for a choice. Every inventory `S-`/`A-`/`CM-`/`M-`/`K-`/`D-` instance appears there in the unified pattern or is marked merged/removed in `COVERAGE.md`.

---

## 8. Decision log

| ID | Question | Options | Choice | Why | Affects |
|---|---|---|---|---|---|
| DEC-001 | Sidebar structure? | A: Library · Inbox · Playlists · Sync + library footer · B: today's 8 rows cleaned up | **A** | Groups by what the user does (browse / decide / collect / deliver); makes room for albums, playlists and devices | P-SIDEBAR, P-PINNED |
| DEC-002 | Name of the tracks row? | A: `All Tracks` under header `Library` · B: keep `Library` · C: `Songs` | **A** | "Library" now names the whole collection (and the library file); MLM says "track" everywhere. **Glossary change:** sidebar item `Library` → `All Tracks` | P-SIDEBAR.E01/E02, V-LIB.E01, M-NAVIGATE |
| DEC-003 | Where do playlists live? | A: all in the sidebar with folders; grid as `All Playlists` · B: grid + pinned (today) | **A** | One click to any playlist; rows are drop targets; removes the pin concept and its limit | P-PINNED, V-PL, CM-PL-CARD, S-PL-BANNER-PINLIMIT |
| DEC-004 | Sources as a destination? | A: accounts in Settings ▸ Sources, importing via Add menu · B: keep a `Sources` row | **A** | It is setup plus an entry point, not a place to browse; state problems surface where they matter | V-SRC, ST-SRC, K-NAV-SOURCES |
| DEC-005 | Where is Activity? | A: toolbar item + popover + Activity window · B: bottom strip | **A** | Calm by default, loud in words when needed; available without a library; frees 36 pt | P-ACTIVITY*, K-ACT-ESC |
| DEC-006 | Where is the Queue? | A: mode of the trailing column · B: sidebar row · C: popover | **A** | Stays open while browsing, accepts drops, not a destination | V-QUEUE, K-NAV-QUEUE, K-SIDEBAR-QUEUE8 |
| DEC-007 | Inspector behaviour? | A: system inspector, ⌘I, follows selection, multi-edit, 3 tabs · B: today's panel | **A** | Native, predictable, fixes the edit-into-wrong-track risk, enables bulk tagging | P-INSPECTOR*, K-LIBRARY-MOREINFO |
| DEC-008 | Double-click / Return? | A: play only · B: play + open inspector (today) | **A** | P2/P3 | V-LIB, V-PLD, V-FOLD, K-LIB-RETURN |
| DEC-009 | Space bar? | A: preview selection (Quick Look semantics), else play/pause · B: always play/pause, preview on ⌥Space · C: user setting, default A | **C (default A)** | It is the stated dream; the setting costs little and covers muscle memory | K-LIB-SPACE, M-PLAYBACK.E01 |
| DEC-010 | Where does the preview show? | A: the toolbar player enters a Preview state · B: bar above the status bar | **A** | No new surface, no overlay; one place to look | P-PLAYER, P-PREVIEW |
| DEC-011 | Local/Remote split? | A: availability scope bar with counts · B: two tabs | **A** | Uses the glossary states; makes failed/missing listable | V-LIB.E02 |
| DEC-012 | Columns? | A: 9 defaults + customization, Status sortable · B: fixed 13 | **A** | Quiet default, power on demand | V-LIB.E07–E19, V-TRACK-TABLE |
| DEC-013 | `unknown album` and source-as-album? | A: render as empty (`—`), filter `is: no album` · B: show the literal | **A** | It is the absence of a value; never an album entity (ROADMAP C-Q2) | V-LIB.E09, G-TRK-PLACEHOLDER |
| DEC-014 | Drive not connected? | A: one banner + footer text, rows dimmed, no chips · B: per-row state | **A** | P4. **State vocabulary change:** new window-level state `Drive not connected`; `File missing` is never used for it | G-DRIVE-OFFLINE, V-LIB.E03, P-SIDEBAR.E02 |
| DEC-015 | Multi-selection affordance? | A: glass selection bar at the bottom · B: context menu only | **A** | The wished batch bar; the legitimate custom glass surface | WISH-11, P-SELBAR |
| DEC-016 | Confirmations of silent actions? | A: status bar message + Undo · B: toasts · C: nothing | **A** | Native (Finder/Xcode feel), no overlay, one location | S-SYNC-TOAST, S-REV-UNDOTOAST |
| DEC-017 | Search behaviour? | A: always filter in place, scopes for wider · B: pane on Return (today) | **A** | One behaviour; `.searchable` | V-SEARCH, K-SEARCH-* |
| DEC-018 | Paste a link? | A: search suggestion + `Add from Link…` ⌘U sheet · B: separate universal panel | **A** | Revives F-06 without a second search UI | S-SEARCH-UNIVERSAL |
| DEC-019 | Album order model? | A: `album_tracks` join (disc, position), seeded from tags · B: `track_number` on tracks | **A** | A track can be on several albums; order editable without touching files | F-24, V-ALBD |
| DEC-020 | Edition chooser? | A: picker in the header + `Other versions` shelf · B: segmented strip under the header | **A** | Scales from 2 to 6 editions; familiar from Music | V-ALBD |
| DEC-021 | Tracks without album? | A: not an album; fixed via Review ▸ Albums suggestions · B: a synthetic "No album" album | **A** | Keeps the grid honest; gives C3 a home | V-ALB, V-REV |
| DEC-022 | Playlist actions? | A: Play, Shuffle, More menu · B: row of 6 buttons (today) | **A** | Calm header; same menu as the context menu | V-PLD.E05–E11 |
| DEC-023 | Words for playlist states? | `Importing · n of m`, `Incomplete · n failed`, **new** `Not downloaded · n tracks`; `Refresh from ‹Source›` replaces playlist "Sync" | adopt | One word per state. **Glossary change:** `Refresh` = pull from a source; `Sync` only for sync profiles | G-PL-*, V-PLD.E08/E13 |
| DEC-024 | Folders layout? | A: one hierarchical table + path bar · B: tree + tables | **A** | Finder muscle memory, fewer panes | V-FOLD |
| DEC-025 | Genre Workshop home? | A: `Genres` sidebar row with tools · B: Settings ▸ Advanced | **A** | A workspace is not a preference; browsing by genre is useful weekly | ST-ADV, ST-STUDIO-* |
| DEC-026 | Import UI? | A: one sheet in the main window · B: separate window | **A** | Single window; result lands on the playlist | W-REMOTE |
| DEC-027 | Sync profiles? | A: sidebar rows, plan with `Skip`, per-profile results · B: list-in-content | **A** | State at a glance; drop targets; fixes shared results | V-SYNC, V-SYNC-DETAIL |
| DEC-028 | Review consequences? | A: user chooses hidden vs Trash, playlists re-pointed, bulk apply · B: flag only (today) | **A** | Decisions must do something | V-REV |
| DEC-029 | Recommendations in the library? | A: held in Discover until kept · B: in library immediately | **A** | "Add to library" then means something | V-INBOX |
| DEC-030 | Similar tracks surface? | A: pushed view · B: sheet | **A** | Needs room, selection, preview and drag — a view's job | S-GROOVE-SIMILAR |
| DEC-031 | Library picker? | A: in-window list with per-row states; name in subtitle + footer · B: separate launcher window | **A** | One window; A0 D5 states visible | V-LAUNCH-*, PP-SHELL-07/08 |
| DEC-032 | Switching with running work? | A: alert lists what stops · B: silent relaunch | **A** | P8 | A-LIB-SWITCH |
| DEC-033 | Library-file icon? | A: record crate · B: stacked sleeves · C: document with mark | **A** | Reads as a collection, legible small | A0 D9 |
| DEC-034 | First run? | A: in-window setup, skippable, background import · B: scrim wizard | **A** | No dead end, native | S-WIZARD, S-NEWLIB |
| DEC-035 | Settings structure? | 8 tabs: General, Library, Playback, Sources, Backup, Storage Location, Maintenance, Advanced | adopt | Preferences only; deep links | W-SETTINGS, ST-* |
| DEC-036 | Backup controls? | Schedule (Off, Daily, Weekly, On quit) + keep last n (5/10/30/All) + destination | adopt | WISH-04 | ST-BACKUP |
| DEC-037 | External tools? | Status rows in Settings ▸ Sources ▸ Download tools | adopt | Failures finally point somewhere | G-TOOL-MISSING |
| DEC-038 | Menu bar? | MLM · File · Edit · View · Track · Playback · Library · Go · Window · Help | adopt | A `Track` menu makes every selection command discoverable; `Navigate` → `Go` | M-* |
| DEC-039 | Context-menu order? | Primary · Queue · Add to · Info · Fix · Locate/Share · Remove | adopt | Same place for the same thing | CM-* |
| DEC-040 | Drag payload? | Internal IDs + file URLs; sidebar rows accept drops | adopt | Works inside and out | D-* |
| DEC-041 | Undo scope? | §4.6 | adopt | P8 | — |
| DEC-042 | Glass policy? | §5: system chrome + one custom surface (selection bar) | adopt | P7 | — |
| DEC-043 | Colour? | System semantic colours; accent on controls only; brand = 6 pt dot | adopt | L1 | V-TRACK-PRIMITIVES |
| DEC-044 | Background work rule? | Every job > 2 s is an Activity operation; results persist; inline echo uses the same words | adopt | P5 | §10.1 jobs |
| DEC-045 | Unplayable track in the queue? | A: skip + say so · B: stop with error | **A** | Fixes the stall | P-PLAYER, PP-MAIN-01 |
| DEC-046 | Energy / Dance? | A: number + quiet 5-step bar, sortable · B: glyph only | **A** | Self-explanatory, no custom colour | V-TRACK-PRIMITIVES.E04/E05 |
| DEC-047 | Arrow-key seeking? | A: only during preview; ⌥⌘←/→ otherwise · B: window-wide (today) | **A** | Keys belong to the focused control | K-WIN-SEEKBACK/FWD |
| DEC-048 | Section actions in the toolbar? | A: none; toolbar is constant · B: per-section items | **A** | Calm, no leaking items | P-TOOLBAR.E04/E05 |
| DEC-049 | Deleting a playlist? | A: confirmation alert *and* restorable with Undo until quit · B: Undo only | **A** | It is the one playlist action that loses curation work; the alert states the consequence | A-PL-DELETE, A-SIDEBAR-DELETEPL |
| DEC-050 | Dismissing a recommendation / removing from a playlist, queue or sync profile? | A: no alert, status-bar message with Undo · B: confirmation | **A** | Triage must be fast; the file goes to the Trash and can be put back | A-INBOX-DELETE, A-PLD-REMOVE, A-SYNC-REMOVECONTENT |
| DEC-051 | Dim `Download failed` rows (UI-GROUNDTRUTH §1.6)? | A: no — dimming means only "file not reachable now" (drive not connected, not in library) · B: keep 60 % dimming | **A** | One visual meaning for dimming. **State vocabulary change** | G-TRK-FAILED, V-TRACK-PRIMITIVES.E01 |
| DEC-052 | Default button of destructive alerts? | A: Cancel is the default (Return), the destructive button must be clicked · B: destructive default | **A** | macOS convention; prevents Return-through accidents | A-* |
| DEC-053 | ⌘↓ / ⌘↑? | Volume everywhere, except on a focused folder row in Folders where ⌘↓ opens the folder as root (Finder) | adopt | Both conventions are strong; scope resolves it | K-* |

---

## 9. Questions for Oliver

| # | Question | My recommendation |
|---|---|---|
| Q1 | **Space bar:** preview the selected track (Finder feel) or always play/pause (Music feel)? | Preview by default, setting to switch (DEC-009). Try `library.html` — press Space on a row. |
| Q2 | **Activity:** are you comfortable losing the always-visible bottom strip for a toolbar item + popover + window? | Yes (DEC-005); variant B is on `activity.html` for comparison. |
| Q3 | **Sources leaves the sidebar** — accounts in Settings, importing from the ＋ menu. Do you open Sources often enough to want a row? | Remove the row (DEC-004). |
| Q4 | **Review may move unkept duplicates to the Trash** (your choice per session, default off). OK to let Review touch files? | Yes, opt-in (DEC-028). |
| Q5 | **Recommendations stay out of All Tracks until kept.** Or should downloads from Discover count as library tracks immediately? | Hold them (DEC-029). |
| Q6 | **YouTube mixes / live sets / video-only uploads:** album stays empty (`No album` is a deliberate, accepted value) with the channel as artist? | Yes — "No album" can be confirmed in Review ▸ Albums so it stops being suggested (ROADMAP C-Q1). |
| Q7 | **Write tag edits to the files** by default (so shared/synced copies are correct), never writing the source anywhere? | Yes, on by default, queued while the drive is away (ROADMAP C-Q4: sharing strips nothing extra because the source never is in the tags). |
| Q8 | **Library-file icon:** crate (A), sleeves (B) or document (C)? | A. |
| Q9 | **Genres as a sidebar row** — worth a permanent place? | Yes; if not, it becomes a scope of All Tracks and the tools move to the Library menu. |
| Q11 | **Album and playlist cards:** single click selects and double-click opens (Finder, as mocked), or single click opens (Music)? | Select / double-click — consistent with every other list and needed for multi-selection and drag. |
| Q12 | **Similar ▸ Online:** `Download` puts a suggestion into Discover for a verdict; should there also be `Keep` (download straight into the library)? | Yes, both — as mocked on `discover.html#similar`. |
| Q13 | **Sync profile menu:** add `Eject "‹device›"`? MLM has no eject today. | Yes — it ends the sync flow where it happens. |
| Q10 | **Raise the deployment target to macOS 26?** Everything here works on 15 with fallbacks, but the selection bar and header extension only *shine* on 26+. | Keep 15 for B3, revisit after. |

---

## 10. Oliver's answers — 2026-10-05 (binding; override anything above and any mockup that disagrees)

**Verdict:** the design is approved as the basis for implementation ("halt dich daran für die Implementierung"). The app state before the redesign is tagged **`v0.9`** (commit `91b4463`, pushed).

| # | Answer | Consequence |
|---|---|---|
| Q1 | **Space is preview only.** Playback control is the job of the media keys in the top row of the Mac keyboard. | **DEC-009 revised:** Space never means Play/Pause. With a previewable track selected: start/stop preview. Otherwise Space does nothing (status bar says why when a selection can't be previewed). No "Space bar" setting. Play/Pause = media keys (already wired through `MPRemoteCommandCenter`), the toolbar button, the Playback menu and the Dock menu; the Playback ▸ Play/Pause menu item carries **no** Space shortcut. |
| Q2 | Activity = variant A (toolbar item + popover + Activity window). | DEC-005 A confirmed. Variant `P-ACTIVITY/B` is dropped. |
| Q3 | Sources leaves the sidebar. | DEC-004 A confirmed. |
| Q4 | Review may move unkept duplicates to the Trash. | DEC-028 confirmed (opt-in per session, default "stay in library, hidden"). |
| Q5 | Recommendations stay out of All Tracks until kept. | DEC-029 confirmed. |
| Q6 | YouTube mixes / live sets / video-only uploads keep an empty album; "No album" can be confirmed in Review ▸ Albums. | DEC-021 + ROADMAP C-Q1 settled. |
| Q7 | Tag edits are written to the files by default; the source never goes into tags. | §7.10 confirmed; ROADMAP C-Q4 settled. |
| Q8 | Library-file icon: variant A (record crate). | DEC-033 A confirmed. |
| Q9 | Genres is a sidebar row. | DEC-025 A confirmed. |
| Q10 | **Deployment target: macOS 27.** | **DEC-042 revised:** no macOS 15 fallbacks. Liquid Glass APIs (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `backgroundExtensionEffect`, `scrollEdgeEffectStyle`, `ToolbarSpacer`) are used unconditionally; no `#available` checks and no `MLMGlass` availability helper. Every "macOS 15 fallback" note in §5, §6 and in mockup annotations is obsolete. `Package.swift` moves to `.macOS("27.0")`. Reduce Transparency / Reduce Motion handling stays. |
| Q11 | Cards: single click selects, double-click opens. | §4.3 confirmed. |
| Q12 | Similar ▸ Online offers both `Download` (into Discover for a verdict) and `Keep` (straight into the library). | As mocked on `discover.html#similar`. |
| Q13 | `Eject "‹device›"` in the sync profile menu: **yes**. | `CM-SYNC-PROFILE.N01` is in scope; also offer it in the profile's `More` menu and after a finished sync. |

**Variants settled by approving the recommendations:** `P-PREVIEW/A` (preview in the toolbar player, DEC-010), `V-ALBD/A` (edition popup + Other versions, DEC-020), `V-FOLD/A` (hierarchical table, DEC-024), `P-ACTIVITY/A`, `ICON-MLIBM/A`.

**Known deltas between the mockups and these answers** (the mockups were not regenerated; this section wins):
- `settings.html` ▸ General still shows a "Space bar" choice; `player.html`, `patterns-menus-shortcuts.html` and §4.2 still describe "else Play/Pause" and a ⌥Space alternative → all removed by Q1.
- Annotations and §5/§6 mention macOS 15 fallbacks (`.regularMaterial`, `.bar`) → removed by Q10.
- Variant B views (`activity.html`, `player.html`, `albums.html`, `folders.html`) and icon variants B/C are reference only.
