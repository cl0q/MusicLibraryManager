# MLM — UI Conventions (B2)

**Status:** binding for all B3 work, 2026-10-05. Supersedes `UI-GROUNDTRUTH.md` (kept for history).
**Source:** the approved B1 design packet `design/b1/` — `THOUGHTS.md` (§10 binding), the pattern pages `patterns-*.html`, `shell.html`, `library.html` and the area pages. Every rule cites its source: `DEC-nnn` = `THOUGHTS.md` §8 decision, `§n.n` = `THOUGHTS.md` section, `§10 Qn` = Oliver's binding answer, a page name = the mockup page and element ID.
**Audience:** every agent that writes, reviews or refactors MLM UI code. Rules are imperative and checkable in a code review.
**Platform:** macOS 27 deployment target (`Package.swift` `.macOS("27.0")`), SwiftUI first, AppKit only where SwiftUI has no equivalent.

Contents: [0 Using this file](#0-using-this-file) · [1 Precedence](#1-precedence-and-the-unspecified) · [2 Principles](#2-principles) · [3 Colour](#3-colour-and-semantic-styles) · [4 Type and spacing](#4-typography-and-spacing) · [5 Materials](#5-materials-liquid-glass-and-motion) · [6 Window and shell](#6-window-and-shell) · [7 Track table](#7-track-table-contract) · [8 Scope bar, status bar, selection bar](#8-scope-bars-status-bar-selection-bar) · [9 Interaction](#9-interaction-selection-keyboard-primary-action-menu-bar-dock) · [10 Context menus](#10-context-menus) · [11 Drag and drop](#11-drag-and-drop) · [12 Sheets and alerts](#12-sheets-popovers-alerts-file-panels) · [13 Undo](#13-undo) · [14 Background work](#14-background-work-activity) · [15 State vocabulary](#15-state-vocabulary) · [16 Glossary](#16-glossary) · [17 Copy](#17-copy-rules) · [18 Empty, loading, error, offline](#18-empty-loading-error-offline) · [19 Toolkit map](#19-toolkit-map) · [20 Accessibility](#20-accessibility) · [21 Engineering constraints](#21-standing-engineering-constraints) · [22 Never list](#22-never--the-review-checklist) · [23 Resolved contradictions](#23-resolved-contradictions-in-the-packet) · [24 Set by this document](#24-set-by-this-document)

---

## 0. Using this file

**Rule IDs.** Every rule has an ID `UC-<AREA>-<nn>`. Cite it in reviews, commit messages and `B3-PLAN.md` (`violates UC-TABLE-07`). IDs are stable: a removed rule keeps its number, marked *(retired)*; new rules are appended.

| Area code | Section | Area code | Section |
|---|---|---|---|
| `PREC` | 1 Precedence | `SEL` | 9.1 Selection |
| `PRIN` | 2 Principles | `KEY` | 9.2 Keyboard |
| `COLOR` | 3 Colour | `PRIM` | 9.3 Primary action |
| `TYPE` | 4.1 Typography | `MENU` | 9.4 Menu bar |
| `SPACE` | 4.2 Spacing and metrics | `DOCK` | 9.5 Dock menu |
| `GLASS` | 5 Materials | `CM` | 10 Context menus |
| `MOTION` | 5.4 Motion | `DND` | 11 Drag and drop |
| `WIN` | 6.1 Window and scenes | `SHEET` | 12 Sheets, popovers, alerts, panels |
| `TB` | 6.2 Toolbar | `UNDO` | 13 Undo |
| `SIDE` | 6.3 Sidebar | `JOB` | 14 Background work |
| `TRAIL` | 6.4 Trailing column | `STATE` | 15 State vocabulary |
| `LAYOUT` | 6.5 Content scaffolding | `GLOSS` | 16 Glossary |
| `SURF` | 6.6 Surface kinds | `COPY` | 17 Copy |
| `TABLE` | 7 Track table | `EMPTY` | 18 Empty / loading / error / offline |
| `SCOPE` | 8.1 Scope bars | `KIT` | 19 Toolkit map |
| `STATUS` | 8.2 Status bar | `A11Y` | 20 Accessibility |
| `SELBAR` | 8.3 Selection bar | `ENG` | 21 Engineering constraints |
| `SEARCH` | 9.6 Search | `NEVER` | 22 Never list |

**Placeholders in copy.** `‹name›` = a value inserted at runtime; `“Lexxar”` = the example name of the library drive (always the real volume name in the app); `“Warm-up”` = an example playlist; `“iPod Classic”` = an example sync profile.

---

## 1. Precedence and the unspecified

| ID | Rule |
|---|---|
| UC-PREC-01 | When sources disagree, apply this order: **`THOUGHTS.md` §10 (Oliver's answers) > this file > the rest of `THOUGHTS.md` > the mockup pages and their annotations.** (§10 header) |
| UC-PREC-02 | §10 bites in three places; the mockups are wrong there and must not be copied: **Space** is preview only, never Play/Pause, and there is no "Space bar" setting (`player.html` K-LIB-SPACE table, `patterns-menus-shortcuts.html` M-PLAYBACK.E01 and K-LIB-SPACE rows, `settings.html` ST-GENERAL.N01 and the Playback-tab pointer); **macOS 15 fallbacks** do not exist (THOUGHTS §5 table column, §5 "One isolation point", `data-fb-api` texts with `.regularMaterial` / `.bar`); **variant B** views (`activity.html` P-ACTIVITY/B, `player.html` P-PREVIEW.N05, `albums.html`, `folders.html`) and icon variants B/C are reference only. (§10 Q1, Q2, Q10, "Known deltas") |
| UC-PREC-03 | The mockups are HTML/CSS stand-ins. Take rules, copy, order and states from them; never port their pixel values, colours, CSS effects or JS behaviour into Swift. Glass in the mockups is `backdrop-filter`; real glass comes from the system. (§5 mockup note, `AUTHORING.md`) |
| UC-PREC-04 | If something you need is not specified anywhere: choose what fits the principles (§2) and the nearest existing pattern in this file, implement it, and record it as `IMP-nnn` in `B3-PLAN.md` §4 (question, choice, why, affected packages). Never invent a new surface kind, colour, glass surface, state word or shortcut without an `IMP` entry. (B3-PLAN §4) |
| UC-PREC-05 | Rules marked *(unspecified in B1 — convention set here)* were decided by this file, not by the design packet. They bind like any other rule; the list is in §24 for the coordinator's review. |
| UC-PREC-06 | `UI-GROUNDTRUTH.md` is superseded. Where it still differs from this file (sentence-case buttons, `mlm*` colour tokens, 36 pt rows, `Preview` = sync plan, dimmed failed rows, blue/green status text), this file wins. (DEC-043, DEC-051, ROADMAP §3 B2) |

---

## 2. Principles

| ID | Principle | In one line |
|---|---|---|
| UC-PRIN-01 | P1 The list is the app | Every destination is a native table, list or grid with the same selection, keyboard, context-menu and drag behaviour; chrome stays quiet. |
| UC-PRIN-02 | P2 One gesture, one meaning — everywhere | Space previews, Return/double-click plays, ⌘I shows Info, ⌫ removes from the current container; no view redefines them. |
| UC-PRIN-03 | P3 Nothing moves unless you ask | Playing never opens a panel, adding never navigates, a finished job never steals focus; confirmation goes to the status bar with Undo. |
| UC-PRIN-04 | P4 States are sentences, placed once | A state is words at the highest level it applies to (drive → banner, playlist → header, track → Status column), never repeated per row, never an unlabeled dot. |
| UC-PRIN-05 | P5 Every long job has one home | Anything slower than ~2 s is an Activity operation with progress, result and a way to stop; the starting place shows a short echo in the same words. |
| UC-PRIN-06 | P6 Offline is normal | With the drive unplugged MLM is a full catalogue; only file actions are disabled, each with its reason. |
| UC-PRIN-07 | P7 System first, glass with a reason | Native containers, system colours, the user's accent; Liquid Glass only on the floating control layer; content is never glass. |
| UC-PRIN-08 | P8 Reversible by default | Edits and removals go through Undo; irreversible things get a consequence-stating confirmation. |

(§2)

---

## 3. Colour and semantic styles

| ID | Rule |
|---|---|
| UC-COLOR-01 | Use only system semantic styles: `.primary`, `.secondary`, `.tertiary`, `.quaternary`, `.tint` (the user's accent), `.separator`, `.background`, and `Color(nsColor:)` with a semantic `NSColor` (`windowBackgroundColor`, `controlBackgroundColor`, `textBackgroundColor`). (DEC-043, §5 Colour) |
| UC-COLOR-02 | No hex values, no `Color(red:green:blue:)`, no custom palettes, no asset-catalog colours, no opacity tricks to invent a new colour. The only literal colours allowed are the four source brand colours of UC-COLOR-07. (DEC-043) |
| UC-COLOR-03 | The `mlm*` tokens in `MLM/Theme/Colors.swift` (`mlmBase`, `mlmSurface`, `mlmRaised`, `mlmEdge`, `mlmEdgeSubtle`, `mlmInk*`, `mlmAccent*`, `mlmActive`, `mlmSuccess`, `mlmAttention`, `mlmWarning`, `mlmError`, `mlmOverlay`, `mlmEnergyOpacity`, `mlmSoundCloud`, `mlmSpotify`, `mlmAppleMusic`, `mlmBrand*`) are deprecated. New code never references them; a surface rebuilt in B3 removes its uses; the file is deleted once the last use is gone. (DEC-043) |
| UC-COLOR-04 | The accent (`.tint`) appears only on selected controls, links, the now-playing marker, determinate progress and the drop-target ring — never as a background fill of an area, a row or a header. (§5 Colour) |
| UC-COLOR-05 | Status text is `.secondary` plus an SF Symbol. Only these states tint their **symbol** (the text stays `.secondary` or `.primary`): `Download failed` and other "needs action" states → system orange; `File missing`, `Failed` (job), `Not found` (library file) and errors → system red; `Connected` / `Found ‹version›` → system green. Use `.foregroundStyle(.orange)` / `.red` / `.green` on the `Image` only. The full list is the "Colour role" column of §15. (DEC-043, `patterns-states.html` PATTERN-STATES.N02, N04) |
| UC-COLOR-06 | Never carry meaning by colour alone: every tinted symbol sits next to its word (UC-A11Y-04). No blue "Running" text, no green "Completed" text. (DEC-043, `patterns-states.html` N04) |
| UC-COLOR-07 | A source brand appears only as a 6 pt filled circle immediately before the source name (`Linked to SoundCloud`, Source column in Discover). Brand values are the existing adaptive ones from `Colors.swift` (SoundCloud `#FF5500`, Spotify `#1DB954`, YouTube `#FF0000`, Apple Music `#FA243C`, each slightly darker in Dark Mode), moved into one `SourceBrand` type that exposes only the dot; other sources (DAB, Last.fm, Qobuz) use a `.tertiary` dot. *(unspecified in B1 — convention set here: the mockup's CSS values are approximations)* Never colour the source name, a capsule or a row with a brand colour. (DEC-043, `mlm.css` `.srcdot`) |
| UC-COLOR-08 | Data visualisation (Energy/Dance bars, waveform, capacity gauge, Swift Charts) uses `.secondary` / `.quaternary` and `.tint` only — no ramps, no status hues. (DEC-046, §6 Swift Charts) |
| UC-COLOR-09 | Destructive menu items and buttons get their colour from `role: .destructive`, never from a manual `.red`. (DEC-039, `patterns-context-menus.html` PATTERN-CM.N05) |
| UC-COLOR-10 | The drive-not-connected banner uses a quiet tinted fill at the `.quaternary` level with an orange symbol; it is opaque. Error banners inside a view use the same construction with a red symbol. (§5 surface table, `patterns-states.html` PATTERN-STATES.N18) |

---

## 4. Typography and spacing

### 4.1 Typography

| ID | Rule |
|---|---|
| UC-TYPE-01 | Use system text styles only (`.font(.body)` etc.), optionally with `.weight(_:)`. No `.font(.system(size:))`, no custom fonts, no point sizes. The role mapping below is derived from the mockups' consistent sizes (13 / 12 / 11 / 10 / 15 / 17 / 20 / 26 px map to the macOS styles body / callout / subheadline / caption / title3 / title2 / title / largeTitle). *(unspecified in B1 — convention set here)* |
| UC-TYPE-02 | Do not style what the system styles: sidebar section headers, table column headers, menu items, alerts, popover/sheet chrome, `ContentUnavailableView`, `Form` section headers, badges and tooltips use the system defaults. (§6 "system section headers") |
| UC-TYPE-03 | Monospaced digits (`.monospacedDigit()`) for every time, duration, count, BPM, kbps, size, percentage and `n of m` that can change or sits in a column. (`mlm.css` `.num`, UI-GROUNDTRUTH §1.3 `data`) |
| UC-TYPE-04 | Never italic for placeholder values; an absent value is `—` in `.tertiary` (UC-TABLE-11). (DEC-013) |

| Role | Style | Notes |
|---|---|---|
| Table cell (all columns) | `.body` | Title in `.primary`; Album / Added in `.secondary` (`mlm.css` `td.dim`) |
| Second line in a row (failure reason, sidebar state, queue artist) | `.subheadline`, `.secondary` | |
| Sidebar row name | system sidebar style (`.body`) | |
| Sidebar badge | `.badge(_:)` | system |
| Scope bar buttons | `.callout`; count in `.tertiary` | |
| View header title inside the content (rare; most views use the window title) | `.title.weight(.bold)` | |
| Detail header title (album, playlist, sync profile) | `.largeTitle.weight(.bold)` | |
| Detail header kind label (`Playlist`, `Album`) | `.subheadline.weight(.semibold)`, `.secondary` | |
| Facts line under a header (`44 tracks · 2 h 51 min · Linked to SoundCloud`) | `.body`, `.secondary` | |
| Header status sentence (`Incomplete · 9 failed`) | `.callout` | |
| Window banner | `.callout`; the subject (`“Lexxar” is not connected.`) `.weight(.semibold)` | |
| Status bar | `.subheadline`, `.secondary`; a transient message in `.primary` | |
| Selection bar | count `.body.weight(.semibold)`, duration `.subheadline` `.secondary` | |
| Player title / state line | `.callout.weight(.semibold)` / `.subheadline` `.secondary` | |
| Player times | `.caption`, `.monospacedDigit()`, `.secondary` | |
| Sheet title | `.title3.weight(.semibold)` | |
| Sheet body, form labels | `.body` | |
| Help / remark lines in forms and sheets | `.subheadline`, `.secondary` | |
| Inline error under a field or above sheet buttons | `.callout`, red symbol + `.primary` text | UC-COLOR-05 |
| Card name / card subtitle (grids) | `.body.weight(.medium)` / `.subheadline` `.secondary` | |
| Empty / unavailable states | `ContentUnavailableView` | system |
| Log text (Activity ▸ Logs) | `.body.monospaced()` | only place for monospaced text |

### 4.2 Spacing and metrics

*(unspecified in B1 as tokens — values derived from the mockups' consistent values, convention set here)*

| ID | Rule |
|---|---|
| UC-SPACE-01 | Use system spacing first: default `HStack`/`VStack` spacing, `Form(.grouped)`, `List`, `Table`, `.padding()` without arguments. Explicit values come only from this scale: **4 · 6 · 8 · 12 · 16 · 20 pt**. Name them once (`enum Spacing { static let xxs = 4.0, xs = 6.0, s = 8.0, m = 12.0, l = 16.0, xl = 20.0 }`); no other literals in layout code. |
| UC-SPACE-02 | Content column horizontal inset: 20 pt (headers, scope bar, grids, detail headers). (`mlm.css` `.vhead`, `.scopebar`, `.dhead`, `.grid`, `.pad`) |
| UC-SPACE-03 | Fixed metrics (from the mockups): sidebar width min 200 / ideal 232 pt; trailing column min 280 / ideal 300 / max 360 pt; track-table cover thumbnail 20 pt (corner 4); toolbar player cover 28 pt; detail header artwork 160 pt (corner 9); grid card min 150 pt, adaptive 150–190 pt, gaps 20 (rows) × 16 (columns); status bar height 24 pt; selection bar floats 12 pt above the status bar; Info header cover 54 pt; large-cover popover 300 pt. (`shell.html` V-MAIN-LAYOUT.E01/E03, `mlm.css`, `playlists.html` V-PL grid, `player.html` S-PLAYER-COVER) |
| UC-SPACE-04 | Corner radii come from the system shapes (`.capsule`, `RoundedRectangle(cornerRadius:style: .continuous)` with 4 / 7 / 9 pt for thumbnail / card art / header art). No other radii. |
| UC-SPACE-05 | Density: tables are dense (UC-TABLE-15); nothing gets extra padding to "breathe". Huge data is the default case. (§4.9 Huge data) |

---

## 5. Materials, Liquid Glass and motion

Glass is the navigation and control layer that floats above content. If a surface holds the user's data, it is not glass. (§5, DEC-042 as revised by §10 Q10)

### 5.1 Surface table (macOS 27 only)

| ID | Surface | Glass | API (used unconditionally) |
|---|---|---|---|
| UC-GLASS-01 | Toolbar incl. player and item groups | System | Standard `.toolbar` on a `Window`; `ToolbarSpacer` between groups; `.sharedBackgroundVisibility(.hidden)` only where the player group must not get an extra shared background. Nothing custom inside the toolbar gets its own material — the player has no background of its own. |
| UC-GLASS-02 | Sidebar | System | `NavigationSplitView` default sidebar. `.backgroundExtensionEffect()` only on album / playlist header artwork so it extends under the sidebar. |
| UC-GLASS-03 | Trailing column (Info / Queue) | System edge only | `.inspector(isPresented:)`; its content is a plain `Form` / `List`. |
| UC-GLASS-04 | Scroll edge under the toolbar | System | `.scrollEdgeEffectStyle(.soft, for: .top)` on scroll views and tables under the toolbar. |
| UC-GLASS-05 | **Selection bar** (P-SELBAR) | **Custom — the only custom glass surface** | `GlassEffectContainer { HStack { … } .glassEffect(.regular.interactive(), in: .capsule) }`; appear/disappear via `.glassEffectID(_:in:)` with a `@Namespace`. Buttons inside the capsule use `.buttonStyle(.borderless)` (see UC-GLASS-08). |
| UC-GLASS-06 | Popovers, menus, sheets, alerts, Activity popover, Queue panel, tips | System defaults | No `presentationBackground`, no `.background(…Material)`, no custom container chrome. |
| UC-GLASS-07 | Tables, lists, grids, cards, artwork, waveform, banners, status text, headers, status bar, forms | **Never glass** | Opaque content background (system default of the container). Banner: opaque quiet tinted fill (UC-COLOR-10). |

| ID | Rule |
|---|---|
| UC-GLASS-08 | Never glass on glass. Nothing with `.glassEffect` or `.buttonStyle(.glass)` sits inside a surface that is already glass (toolbar, sidebar, the selection-bar capsule, popovers, sheets, menus). This is why the selection bar's buttons are borderless inside the glass capsule. `.buttonStyle(.glass)` is allowed only for a standalone floating control on content — B1 has none; adding one needs an `IMP` entry. (§5 Hierarchy; see §23 C4) |
| UC-GLASS-09 | Layer order, bottom to top: content (opaque) → window banner (opaque, tinted) → selection bar (glass, bottom) → sidebar / trailing column / toolbar (system glass) → transient UI (menus, popovers, sheets, alerts). (§5 Hierarchy) |
| UC-GLASS-10 | No `#available(macOS 26, *)` / `#available(macOS 27, *)` checks around glass APIs, no `if #unavailable`, no compiler-version checks, no `MLMGlass` helper or any other availability wrapper. Glass APIs are called directly. (§10 Q10) |
| UC-GLASS-11 | Never use `.background(.regularMaterial)` / `.ultraThinMaterial` / `.bar` as a stand-in for glass, and never `glassBackgroundEffect(displayMode:)` (visionOS only). (§10 Q10, LIQUID-GLASS-PLAN §2) |
| UC-GLASS-12 | No `.windowStyle(.hiddenTitleBar)`, no custom title bar, no custom window background, no `NSVisualEffectView` added by MLM. (§6 Banned, L2, ROADMAP §6.2) |

### 5.2 Reduce Transparency

| ID | Rule |
|---|---|
| UC-GLASS-13 | System surfaces handle Reduce Transparency themselves; do nothing for them. |
| UC-GLASS-14 | The selection bar reads `@Environment(\.accessibilityReduceTransparency)`; when true it replaces `.glassEffect` with an opaque `.background(Color(nsColor: .windowBackgroundColor), in: .capsule)` plus `.overlay(Capsule().strokeBorder(.separator))`. This is an environment branch, not an availability check. (§5 Motion, §10 Q10 "Reduce Transparency handling stays") |

### 5.3 What is never glass (checklist)

Tables, lists, grids, album/playlist cards, headers, banners, status chips/text, the status bar, artwork, waveforms, forms, sheet bodies, the Info and Queue content. (§5 table last row)

### 5.4 Motion

| ID | Rule |
|---|---|
| UC-MOTION-01 | System transitions only. No custom spring curves, no bespoke keyframe animation, no pulsing outlines, no shake except the system behaviour of a text field. (§5 Motion, `patterns-dnd.html` PATTERN-DND.N02) |
| UC-MOTION-02 | Allowed effects, nothing else: the selection bar morphs in/out with its glass transition (`glassEffectID`); the Activity item's symbol `.symbolEffect(.bounce, value:)` once when a job ends; the now-playing glyph `.symbolEffect(.variableColor.iterative)` while playing (static while paused); Play/Pause morph `.contentTransition(.symbolEffect(.replace))`. (§5 Motion, `activity.html` P-ACTIVITY) |
| UC-MOTION-03 | Read `@Environment(\.accessibilityReduceMotion)`: when true, no symbol effects, no glass morph (the selection bar appears/disappears with an opacity change or instantly), no animated scrolling to a row. (§5 Motion, §10 Q10) |
| UC-MOTION-04 | Rows update in place without animation flicker; never animate a table to a spinner and back (UC-TABLE-09). (§4.1) |

---

## 6. Window and shell

### 6.1 Window and scenes

| ID | Rule |
|---|---|
| UC-WIN-01 | Exactly one main window: a `Window` scene (not `WindowGroup`). Opening a library file, the Dock icon or Window ▸ ‹main window› always brings this one window forward; closing it (⌘W) does not quit. (§3.1, M-FILE.E05, commit `74ccd3b`) |
| UC-WIN-02 | Auxiliary windows, and only these: `Settings` scene (⌘,) and `Window("Activity", id: "activity")` (⌥⌘0, Window ▸ Activity), plus the Help ▸ Keyboard Shortcuts window. No second main window, no import window, no floating panels. (§3.2, DEC-005, DEC-026, DEC-035, M-HELP.N02) |
| UC-WIN-03 | Settings is a SwiftUI `Settings { TabView(selection:) }` with 8 tabs in this order: **General · Library · Playback · Sources · Backup · Storage Location · Maintenance · Advanced**; each tab `Label(_, systemImage:)`; deep links open a specific tab (`openSettings` + a tab binding). The window title is the selected tab's name. No AppKit settings window. (DEC-035, `settings.html` W-SETTINGS) |
| UC-WIN-04 | Settings ▸ General contains *Open the last library at launch* and the opt-in *Notify me when background work finishes*. It contains **no Space-bar choice**; the Playback tab has no Space-bar pointer. (§10 Q1, `settings.html` ST-GENERAL — delta) |
| UC-WIN-05 | With no library open, per-library settings are disabled and one line at the top says `No library is open. Settings that belong to a library are dimmed until you open one.` with `Choose Library…`; app-wide settings keep working. (`settings.html` W-SETTINGS.N01) |
| UC-WIN-06 | Title = the current place (`.navigationTitle`: `All Tracks`, `Warm-up`, `Similar to “Glass Circuit”`). Subtitle (`.navigationSubtitle`) = `‹Library name› · ‹count of the current place›` (`Main Library · 12,935 tracks`; a filtered grid: `Main Library · 6 of 28 playlists`). Outside the window it reads `‹Place› — ‹Library name›` (Window menu, Mission Control). With no library open the title is `MLM`. (§6 `.navigationTitle`, `patterns-states.html` G-LIB-CURRENT; see §23 C11) |
| UC-WIN-07 | Launch states (no library, opening, failed, setup) live inside the same main window: no sidebar, no player, no search; the toolbar shows only the title and the Activity item. (`launch.html` main window note, DEC-031, DEC-034) |
| UC-WIN-08 | Use `.windowToolbarStyle(.unified)`. Never `.hiddenTitleBar`, custom chrome or a floating player. (§6 Banned, ROADMAP §6.2) |

### 6.2 Toolbar

| ID | Rule |
|---|---|
| UC-TB-01 | The toolbar is constant in every section. Items, in this order: **sidebar toggle** (system) · **Back / Forward** (pushed details, ⌘[ ⌘]) · **Add** (＋ menu, P-ADDMENU) · flexible space · **player** (`ToolbarItem(placement: .principal)`, includes the queue button) · flexible space · **Activity item** · **Info toggle** (ⓘ, ⌘I) · **search field** (`.searchable`). (§3.1, DEC-048, `shell.html` P-TOOLBAR) |
| UC-TB-02 | No section-specific toolbar items: Play, Shuffle, Sync Now, Scan, Refresh, counters live in the content header, the Playback/Library/Track menus or the status bar. (DEC-048, P-TOOLBAR.E04/E05 removed) |
| UC-TB-03 | Narrow windows give way in this fixed order: (1) the player's title/artist column, (2) the Activity item's text, (3) the Add button moves into the overflow menu. Transport, scrubber, queue button, Info and search never collapse. (§7.1, `shell.html` P-TOOLBAR) |
| UC-TB-04 | The toolbar is customizable (`.toolbar(id:)`): the user may remove Add and Activity; nothing else changes it. View ▸ Customize Toolbar… exists. (§6, M-VIEW.N09) |
| UC-TB-05 | Add menu (＋), exactly: `New Playlist ⌘N` · `New Playlist Folder ⌥⌘N` · — · `Add from Link… ⌘U` · `Import Playlist from Source… ⇧⌘I` · `Import Files or Folder…` · `Import M3U…` · — · `Refresh from Sources`. With no source connected `Refresh from Sources` is disabled with help `No source is connected`. (`patterns-context-menus.html` P-ADDMENU, `shell.html` P-ADDMENU.N01) |
| UC-TB-06 | Player anatomy, left to right: Previous · Play/Pause · Next · cover (28 pt; click → large-cover popover; draggable as the track) · title / state line + artist line + scrubber (click title → Go to Current Track ⌘L) · elapsed / duration (hidden when idle) · volume button (popover with slider; level persisted; ⌘↑/⌘↓) · queue button (toggles the Queue column). The player has no background of its own. (§7.8, `player.html` P-PLAYER.E01–E10, N01) |
| UC-TB-07 | Player states are words in the title area, exactly: `Not playing` · `Preview` (tag before the previewed title; second line `Space to stop · Return to play`; waveform scrubber) · `Can’t play — not downloaded · Download` · `Can’t play — file missing · Locate…` · `Can’t play — “Lexxar” is not connected`. An online result previews as `Preview · from YouTube`. (§7.8, DEC-045, `patterns-states.html` G-PLAYBACK-ERROR) |
| UC-TB-08 | The toolbar player is a drop target: tracks dropped on it = Play Next (UC-DND matrix). (DEC-040, D-LIB-TO-QUEUE) |
| UC-TB-09 | Previous restarts the current track when more than 3 s have played, else goes to the previous track. Next skips unplayable tracks and says so in the status bar. (`player.html` E01/E03, DEC-045) |

### 6.3 Sidebar

| ID | Rule |
|---|---|
| UC-SIDE-01 | `List(selection:)` with `.listStyle(.sidebar)`, four system `Section`s in this order: **Library** (All Tracks ⌘1, Albums ⌘2, Genres ⌘3, Folders ⌘4) · **Inbox** (Discover ⌘5, Review ⌘6) · **Playlists** (All Playlists, then playlist folders and playlists in the user's order) · **Sync** (one row per sync profile, user-ordered). No other rows: no Sources, Queue, Settings or Search rows. (DEC-001…004, DEC-006, DEC-027) |
| UC-SIDE-02 | Section headers are system headers (not uppercase, not hand-styled), collapsible via `Section(isExpanded:)`; expansion state of sections and playlist folders persists per library. A collapsed section still accepts drops. (`shell.html` P-SIDEBAR, P-SIDEBAR.N09) |
| UC-SIDE-03 | Only the Playlists and Sync section headers show a ＋ on hover. Playlists ＋ is a menu (`New Playlist ⌘N`, `New Playlist Folder ⌥⌘N`); Sync ＋ opens New Sync Profile… (help `New Sync Profile…`). (P-SIDEBAR.E03/add, `sync.html` header) |
| UC-SIDE-04 | Row anatomy: SF Symbol + name on one line, truncated at the tail. A second line (`.subheadline`, `.secondary`) appears **only** to state a condition; a trailing `.badge(n)` appears **only** on Inbox rows. Never a coloured dot. (§7.1, P4, `shell.html` P-SIDEBAR.N04) |
| UC-SIDE-05 | Inbox badges count decisions waiting: Discover = recommendations + reels waiting for a verdict; Review = duplicate groups + conflicts + album suggestions. Plain number with thousands separators; zero shows nothing; no capsule colour. (P-SIDEBAR.E08/E09) |
| UC-SIDE-06 | Playlist rows have a second line only when not healthy, in the playlist status words of §15.5 (`Importing · 12 of 44`, `Incomplete · 9 failed`, `Not downloaded · 61 tracks`, `SoundCloud sign-in expired`). (DEC-023, P-SIDEBAR.N04/N12/N13) |
| UC-SIDE-07 | Sync profile rows always have a second line with the profile state (§15.8): `Not connected` · `‹n› to add` · `Syncing ‹n› of ‹m›` (with a thin linear `ProgressView` under the text) · `Synced ‹relative time›` · `Synced ‹relative time› · ‹n› failed`. (DEC-027, P-SIDEBAR.N05–N08, N14) |
| UC-SIDE-08 | Playlist folders are `DisclosureGroup` rows; they group playlists, accept dropped playlists (move) and tracks (new playlist inside), and remember their expand state. Deleting a folder moves its playlists up one level. (DEC-003, P-SIDEBAR.N03) |
| UC-SIDE-09 | Rename is inline in the row (TextField + `@FocusState`): ⌘N / ＋ create a row already in rename mode; Return on a selected playlist, folder or profile row starts rename; Return commits; Esc reverts (UC-KEY-20). A failed rename keeps the field open with the typed text and one sentence under it. (K-SIDEBAR-RENAME, P-PINNED.E04, P-SIDEBAR.N16) |
| UC-SIDE-10 | Footer (`.safeAreaInset(edge: .bottom)` with a `Menu`): first line the library name, second line `12,935 tracks`, or `“Lexxar” — not connected` while the drive is away (nothing for a boot-volume library folder). Middle truncation; help shows the full name and the library file path. Menu items: `Open Recent` header, known libraries (open one checked, unreachable ones disabled with `— Not connected` / `— Not found`), — , `Open Library… ⌘O`, `New Library…`, — , `Show Library File in Finder`, `Library Settings…`. (P-LIBFOOTER, P-LIBFOOTER.N01–N03, DEC-031) |
| UC-SIDE-11 | Every playlist, playlist folder and sync profile row is a drop target; fixed rows (All Tracks … Review) never take tracks (Finder files onto the Library section = import). (DEC-040, PATTERN-DND.N03) |
| UC-SIDE-12 | Type-to-select works in the focused sidebar; ⌘1…⌘6 select the six fixed rows; playlists and profiles have no number shortcuts. (K-SIDEBAR-NAV) |

### 6.4 Trailing column (Info / Queue)

| ID | Rule |
|---|---|
| UC-TRAIL-01 | One system `.inspector(isPresented:)` with `.inspectorColumnWidth(min: 280, ideal: 300, max: 360)`, two modes switched by a segmented `Picker` at its top: **Info** (⌘I, ⓘ toolbar button) and **Queue** (⌥⌘U, the player's queue button). Each button opens the column in its mode and closes it when pressed again in that mode. Info and Queue are never visible together. Width and open state are remembered. (DEC-006, DEC-007, `shell.html` V-MAIN-LAYOUT.E03/N05) |
| UC-TRAIL-02 | The column never opens by itself: not on double-click, not on play, not on selection. (DEC-007, DEC-008, P3) |
| UC-TRAIL-03 | Info follows the selection (never the playing track). No selection: `No selection` / `Select a track to see and edit its details.` One track: its form. Several: the same form, differing fields show `Mixed`, edits apply to all with one undo step, header `‹n› tracks selected` / `‹duration› · edits apply to all`. Tabs (segmented): **Details · Audio · File**. (§7.10, DEC-007, app.js inspectorAuto) |
| UC-TRAIL-04 | Info fields commit on Return or when focus leaves, never across a change of selection (the form is keyed to the selected IDs); Tab moves to the next field; Esc reverts the field. An invalid value keeps the field open with the reason; a save failure is a line under the field with `Try Again`. (§7.10, K-META-EDIT-RETURN/ESC, A-META-SAVEERROR) |
| UC-TRAIL-05 | Queue sections: `Now playing` · `Next` (Play Next items, then `From “‹context›”`) · `History` (most recent first). Rows: cover, title, artist, time; a state word only when the row can't play. Reorder by drag, ⌫ removes (undoable), `Clear` (Next), `Save as Playlist…`. Persisted across relaunch. (§7.7, DEC-006, `queue.html`) |

### 6.5 Content scaffolding

| ID | Rule |
|---|---|
| UC-LAYOUT-01 | Every content view stacks, top to bottom: **banner slot** (window-level state, `.safeAreaInset(edge: .top)`) → **detail header** (only for pushed details and sync profiles) → **header status sentence** (only when the shown thing is not healthy) → **scope bar** → **content** (table / list / grid / form) → **selection bar** (overlay, only with ≥ 2 selected) → **status bar** (`.safeAreaInset(edge: .bottom)`). Nothing else is stacked above or below the content. (§3.1, `shell.html` V-MAIN-LAYOUT.E02) |
| UC-LAYOUT-02 | The banner slot shows only window-level states: the drive (UC-STATE drive table) and, on a sync-profile page, an interrupted sync. One banner at a time; it appears in every view that lists tracks. (DEC-014, PATTERN-STATES.N03) |
| UC-LAYOUT-03 | While searching, the system search scope bar (`This view · Library · Online`) appears under the toolbar above the view's own scope bar; the two combine. (§4.7, `search.html`) |
| UC-LAYOUT-04 | The selection bar is drawn over the content (it does not shrink the table) and never covers the status bar. (UC-SELBAR-01) |
| UC-LAYOUT-05 | Navigation: `NavigationSplitView` (sidebar + detail) with a `NavigationStack` in the detail. Sidebar rows are destinations; album, playlist (from the grid), genre and Similar details are pushed (Back ⌘[ returns to where the user came from). (§6, §3.2) |
| UC-LAYOUT-06 | Detail headers (playlist, album): 160 pt artwork (drop target, `.backgroundExtensionEffect()`), kind label, editable title, facts line, then buttons `Play` (`.borderedProminent`) · `Shuffle` · `More` (•••, same builder as the context menu). Play and Shuffle are always present; when nothing can play they are disabled with the reason next to them and in `.help`. (DEC-022, `playlists.html` V-PLD, `albums.html` V-ALBD) |

### 6.6 Surface kinds

| ID | Kind | Use it for (rule) | Examples |
|---|---|---|---|
| UC-SURF-01 | Sidebar destination | A collection the user browses or works through | All Tracks, Albums, Genres, Folders, Discover, Review, each playlist, each sync profile |
| UC-SURF-02 | Pushed detail (Back, ⌘[) | One item of a collection, or a view that needs a table, selection, preview and drag | Album detail, playlist detail from the grid, genre detail, `Similar to ‹track›` |
| UC-SURF-03 | Trailing column | Facts about the selection or the play order | Info (one / several tracks), Queue |
| UC-SURF-04 | Nothing — in place | Something can be named or fixed where it is | New playlist (inline name), rename, a failed save (line under the field), a refused cover drop (sentence on the card, 5 s) |
| UC-SURF-05 | Status-bar message | Something just happened and can be undone, or a row action failed with one obvious fix | `Removed 9 tracks from “Warm-up” — the files stay in the library · Undo` |
| UC-SURF-06 | Popover | A glance, dismissed by clicking away or Esc; no decision that matters | Activity, large cover, volume, keyframe still, How to Install, Save Queue as Playlist (the one naming popover) |
| UC-SURF-07 | Sheet | A task with a beginning and an end that needs input or a preview first; blocks the window briefly | Import playlist, Add from Link, link source, M3U preview, new sync profile, read device changes, new library, merge genres, edit album info |
| UC-SURF-08 | Alert | The consequence can't be undone (Trash, restore, relaunch, sign-out), or MLM can't continue without an answer | Remove from Library, Delete Playlist, Restore backup, Switch library, Disconnect source |
| UC-SURF-09 | System file panel | Choosing a file or folder | Open Library…, library folder, sync destination, M3U file, backup folder |
| UC-SURF-10 | Auxiliary window | Reference that stays visible next to the main window | Settings (⌘,), Activity (⌥⌘0) |
| UC-SURF-11 | Settings tab | A preference or a location — never a workspace, a job list or a tool | General … Advanced (UC-WIN-03) |

If two kinds fit, the upper row in this table wins. (§3.2, `patterns-sheets-alerts.html` PATTERN-SHEETS.N01)

---

## 7. Track-table contract

Applies to every list of tracks: All Tracks, album / playlist / genre detail, Folders (track rows), search results, Similar ▸ In library, sync-profile content, Review version rows, Discover recommendations, sheet preview tables. (DEC-012, P1)

| ID | Rule |
|---|---|
| UC-TABLE-01 | Use a native SwiftUI `Table(_:selection:sortOrder:columnCustomization:)` with `selection: Binding<Set<Track.ID>>`. No `List` of custom rows, no `LazyVStack` tables, no `NSTableView` wrappers for track lists. Folders uses the hierarchical `Table(_:children:…)` / `DisclosureTableRow`. (§4.1, §6, DEC-024) |
| UC-TABLE-02 | Default columns, in this order: **Title** (cover + now-playing glyph + title), **Artist**, **Album**, **Time**, **BPM**, **Energy**, **Genre**, **Added**, **Status**. Optional (off by default): **Dance**, **Year**, **Format**, **kbps**. In containers with an own order (playlist, queue, album) `#` is the first column. Title cannot be hidden. (DEC-012, §7.2, app.js COLS) |
| UC-TABLE-03 | Column show/hide and reorder through `TableColumnCustomization`, persisted per view with `@SceneStorage`. The header context menu lists the hideable columns (`Artist, Album, Time, BPM, Energy, Dance, Genre, Year, Format, kbps, Added, Status`) with check marks, then `Auto Size All Columns`; View ▸ Columns shows the same list. (DEC-012, V-TRACK-TABLE.N01, M-VIEW.N04) |
| UC-TABLE-04 | Every column is sortable by clicking its header (`KeyPathComparator`), including **Status** and Energy/Dance; View ▸ Sort By mirrors it (with `Ascending` / `Descending`). In a playlist the first Sort By entry is `Playlist Order`; album detail has no sort headers (fixed disc/track order). Sort order is persisted per view. (DEC-011, DEC-012, M-VIEW.N05, §7.3) |
| UC-TABLE-05 | In a playlist sorted by anything but `#`: `#` is dimmed but keeps showing the playlist position (no renumbering), drag-to-reorder is off, and one line above the table says `Sorted by ‹Column› — reordering is off · Sort by #`. Dropping tracks from elsewhere still works (they are appended, and the status message says so). (`playlists.html` reorder hint, D-PLD-REORDER, D-PLD-INSERT) |
| UC-TABLE-06 | Context menu and primary action come from one modifier: `.contextMenu(forSelectionType: Track.ID.self, menu:, primaryAction:)`. The primary action (double-click / Return) follows UC-PRIM. A right-click on a row outside the selection acts on that row only and leaves the selection unchanged. (§4.1, §6, PATTERN-CM.N07) |
| UC-TABLE-07 | Type-to-select jumps to the first row whose Title starts with the typed letters. (§4.1, PATTERN-MENUS.N07) |
| UC-TABLE-08 | Selection survives sort, filter, search and refresh; it is cleared only by navigating away. Scroll position survives refresh. (§4.1) |
| UC-TABLE-09 | Refresh updates rows in place — never replace the table by a spinner or placeholder after the first load. The first load of a view shows `.redacted(reason: .placeholder)` rows under the real header and scope bar; later work shows only the status-bar spinner (UC-STATUS-06). (§4.1, §4.9, PATTERN-STATES.N12/N13) |
| UC-TABLE-10 | Row dimming (`.foregroundStyle(.tertiary)` on text, artwork at reduced opacity) means exactly one thing: **the file isn't reachable now** — local and file-missing rows while the drive is not connected, and `Not in library` rows (Folders files, album tracklist). `Download failed` and `Not downloaded` rows are **not** dimmed. (DEC-051, DEC-014) |
| UC-TABLE-11 | Absent values render as `—` in `.tertiary`: no album, `unknown album`, a source name stored as album (`youtube`, `soundcloud likes`, …), missing BPM / year / energy. Never show the placeholder literal, never italic. Filter for them with the token `is: no album`. (DEC-013, G-TRK-PLACEHOLDER) |
| UC-TABLE-12 | Status column content (one `Label`, `.secondary` text, symbol per UC-COLOR-05; empty = fine): Local → empty · `Downloading…` with a small `ProgressView` (updates in place row by row) · `Not downloaded` (`icloud`) · `Download failed` (`exclamationmark.arrow.circlepath`, orange symbol) · `File missing` (`doc.questionmark`, red symbol) · `Not in library` (`doc.badge.plus`, row dimmed; Folders / album detail only). Drive not connected: local and file-missing rows show an empty Status (never `File missing` because of the drive); `Not downloaded` / `Download failed` keep their word. Folder rows in Folders: `‹n› not in library` or `Can’t read this folder`. (DEC-011, DEC-014, `patterns-states.html` N04, `folders.html` Status column) |
| UC-TABLE-13 | In the `Download failed` scope (and only there) a failed row has a second line under the title: `‹reason› · ‹n› attempts left` (`.subheadline`, `.secondary`). The reason is also the row's help text and is shown in Info ▸ File. (§7.2, G-TRK-FAILED, DEC-011) |
| UC-TABLE-14 | Energy (and Dance) = the number (monospaced digits) followed by a quiet 5-step bar: filled steps `.secondary`, empty steps `.quaternary`; no colour ramp; `—` when not analysed. (DEC-046, app.js `meter`) |
| UC-TABLE-15 | Row density: one line per row, `.body` text, 20 pt cover thumbnail; no extra vertical padding (rows come out at the mockup's ~28 pt). Two-line rows only for UC-TABLE-13. Use the system's alternating row backgrounds. (`mlm.css` `.table td`, `tr.tall`) |
| UC-TABLE-16 | Now playing: the playing row's Title cell shows a now-playing glyph (`speaker.wave.2.fill`, `.foregroundStyle(.tint)`, `.symbolEffect(.variableColor.iterative)` while playing, static while paused) between cover and title, and the title text in `.tint`. No other row decoration. *(glyph name unspecified in B1 — convention set here)* (§5 Motion, `mlm.css` `tr.playing`) |
| UC-TABLE-17 | Not-downloaded / failed rows show a neutral placeholder thumbnail (`music.note` on `.quaternary`), never a broken image. (app.js COLS.title) |
| UC-TABLE-18 | `Album` column values are links to the album (`Go to Album`) when an album exists. (§7.3) |
| UC-TABLE-19 | `Added` means "added to the library" in library views and "added to this playlist" in a playlist. (§7.6) |
| UC-TABLE-20 | Availability is persisted state (refreshed by scans and mount events). Rendering a row must never touch the disk: no `FileManager.fileExists` per row, per cell or per scroll. (§7.2 Risks, W2-A) |
| UC-TABLE-21 | Counts shown with a table (scope counts, status bar) come from SQL aggregates, not from counting loaded rows. Tables load lazily. (PATTERN-STATES.N21) |
| UC-TABLE-22 | Inline editing in tables is not used for track fields; edit in Info (⌘I). Rename-in-place exists only for playlists, folders, sync profiles, the playlist header title and cards. (§7.10, DEC-003) |

---

## 8. Scope bars, status bar, selection bar

### 8.1 Scope bars

| ID | Rule |
|---|---|
| UC-SCOPE-01 | A scope bar filters the current view in place. It sits in the content column under the banner slot and detail header (`.safeAreaInset(edge: .top)`), uses scope buttons or `Picker(.segmented)`, and each scope shows its live count (thousands separators, `.tertiary`). Counts follow the active search. (DEC-011, `library.html` V-LIB.E02) |
| UC-SCOPE-02 | Scope words are the glossary state words, verbatim. Scope sets: **All Tracks** `All · Local · Not downloaded · Download failed · File missing` · **Albums** `All · Complete · Incomplete · Compilations` · **All Playlists** `All` + sources + `Needs attention` · **Playlist detail** `All · Download failed (n)` (shown only when something failed) · **Discover** `Recommendations · Reels` · **Review** `Duplicates · Conflicts · Albums · Resolved` · **Activity window** `All · Running · Needs attention · Finished`. (DEC-011, DEC-019, DEC-023, DEC-029, DEC-021/028, `activity.html` P-ACTIVITY-OPS.E02) |
| UC-SCOPE-03 | View ▸ Filter lists the current view's scopes as menu items (same words). (M-VIEW.N06) |
| UC-SCOPE-04 | `Needs attention` (playlists) covers every playlist that is not fully playable for a reason the user can fix: `Incomplete · n failed`, `Not downloaded · n tracks`, `Sign-in expired`. A running import is not "attention". (`playlists.html` V-PL scope) |
| UC-SCOPE-05 | The chosen scope is remembered per view while the app runs. *(persistence beyond the session unspecified in B1 — convention set here: `@SceneStorage`)* |

### 8.2 Status bar

| ID | Rule |
|---|---|
| UC-STATUS-01 | Every main-window content view has a 24 pt status bar (`.safeAreaInset(edge: .bottom)`, opaque, top separator). It shows counts by default and transient messages on top. It is the only place for "it happened" confirmations — no toasts, no floating panels, no banners for confirmations. (DEC-016, P-STATUSBAR) |
| UC-STATUS-02 | Default text for a track view: `‹n› tracks · ‹total duration› · ‹total size›` (`12,935 tracks · 38 days · 412 GB`). Grids: `‹n› albums` / `‹n› playlists` / `‹n› genres`, `‹shown› of ‹total›` while filtered. *(grid wording unspecified in B1 — convention set here)* (§7.2, §4.9) |
| UC-STATUS-03 | With a selection: `‹n› selected · ‹duration›` (`14 selected · 52 min`). (§7.2; see §23 C12) |
| UC-STATUS-04 | Transient message = what happened (+ the consequence that used to need an alert, + counts of what was skipped) + at most two plain buttons (`Undo`, `Show`, `Try Again`, `Download`, `Locate…`, `Cancel`, `Resume`). It replaces the default text for **8 s**, then the default returns; a newer message replaces an older one at once. `Undo` in the message and Edit ▸ Undo do the same thing; after 8 s ⌘Z still works. (DEC-016, §4.6, PATTERN-SHEETS.N06) |
| UC-STATUS-05 | Patterns (verbatim shapes): `Added 3 tracks to “Warm-up” · Undo` · `Added 2 tracks to “Warm-up” · 1 was already in it · Undo` · `Removed 9 tracks from “Warm-up” — the files stay in the library · Undo` · `Playing next: 3 tracks · Undo` · `Download started — 44 tracks` · `Import finished — 35 downloaded, 9 failed · Show` · `Downloading “‹title›” — it will play when it’s ready · Cancel` · `Skipped 2 tracks that aren’t downloaded · Download` · `Couldn’t dismiss “‹title›” — the file is in use by another app. · Try Again` · `“Lexxar” connected. · Resume`. (`patterns-states.html`, `patterns-dnd.html` PATTERN-DND.N04, `patterns-sheets-alerts.html`) |
| UC-STATUS-06 | Loading: when a refresh or background read of the current view takes longer than 300 ms, a small `ProgressView().controlSize(.small)` with a short phase text (`Refreshing from SoundCloud…`) appears at the left of the status bar; nothing appears for faster work. (§4.9, PATTERN-STATES.N13) |
| UC-STATUS-07 | Space / Return refusals are status-bar messages (`Space previews one track. Select a single track.`, `Can’t preview — not downloaded. Press ⌘D to download.`, `Can’t preview — file missing.`, `Can’t preview — “Lexxar” is not connected.`, `Can’t play — “Lexxar” is not connected.`). (§10 Q1, `player.html` K-LIB-SPACE, §4.3) |

### 8.3 Selection bar

| ID | Rule |
|---|---|
| UC-SELBAR-01 | Appears when ≥ 2 rows are selected in a track list; disappears below 2. Floats centred over the bottom of the content, 12 pt above the status bar; it never moves the table. (DEC-015, §4.1, `mlm.css` `.selbar`) |
| UC-SELBAR-02 | Content, left to right: count `‹n› selected` (semibold) with the total duration (`.secondary`) · `Play Next` · `Add to Playlist ▾` (the CM-SUB-PLAYLIST builder) · `Edit Info` (opens Info with the multi-edit form = ⌘I) · `Download` (only when the selection contains Not downloaded / Download failed tracks) · `More` (•••, the multi-selection track menu minus these four actions). (§4.1, app.js P-SELBAR.N01–N05, PATTERN-CM.N06) |
| UC-SELBAR-03 | Its actions confirm in the status bar with Undo like any other route to the same command. (DEC-016) |
| UC-SELBAR-04 | Construction is UC-GLASS-05 / UC-GLASS-08 / UC-GLASS-14; it is the only custom glass in the app. (DEC-015, DEC-042) |
| UC-SELBAR-05 | Not shown in grids, the sidebar, the queue or sheets. *(unspecified in B1 for non-track lists — convention set here)* |

---

## 9. Interaction: selection, keyboard, primary action, menu bar, Dock

### 9.1 Selection

| ID | Rule |
|---|---|
| UC-SEL-01 | Every list supports click, ⇧-click, ⌘-click, ⌘A, ⇧⌘A, ↑/↓, ⇧↑/↓ and type-to-select (Title in track lists; the name in grids and the sidebar). Grids also move with ←/→. (§4.1, PATTERN-MENUS.N07) |
| UC-SEL-02 | The selection is the argument of every command: menu bar, context menu, selection bar, drag, Info, Space. Commands read it through `FocusedValue`, never through a global "current track". (§4.1, DEC-038) |
| UC-SEL-03 | One selected track → Info shows it; ≥ 2 → Info shows the multi-edit form and the selection bar appears. (§4.1, DEC-007, DEC-015) |
| UC-SEL-04 | Cards (album, playlist, genre grids): single click selects, double-click / Return opens; multi-selection and drag work as in tables. (§10 Q11) |
| UC-SEL-05 | Selection survives sort, filter, search and refresh; navigating away clears it. Page Up/Down, Home/End scroll without changing it. (§4.1, PATTERN-MENUS.N07) |

### 9.2 Keyboard map (complete; §4.2 and `patterns-menus-shortcuts.html` corrected by §10 Q1)

| ID | Key | Command | Scope | Menu item |
|---|---|---|---|---|
| UC-KEY-01 | Space | **Preview** the one selected previewable track from its hot spot (analysed drop, else 0:30); the playing track pauses and keeps its position; the queue is untouched. Space again or Esc ends the preview and resumes. **Never Play/Pause.** With nothing previewable selected Space does nothing; when the selection can't be previewed the status bar says why (UC-STATUS-07). In a text field: types a space. On a focused button/checkbox: presses it (system). | Focused track list (tracks, queue, recommendations, Similar, Review versions, sheet tables); Reels list: previews the selected video | Track ▸ Preview |
| UC-KEY-02 | ↩ / double-click | Primary action (§9.3); on a track: Play — the rows after it become the queue context. Never opens anything. | Focused list | Track ▸ Play |
| UC-KEY-03 | ⌥↩ · ⌥⇧↩ | Play Next · Add to Queue | Focused list | Track |
| UC-KEY-04 | Esc | Belongs to the innermost cancellable thing, in this order: preview → inline edit → search text and tokens → popover → sheet. Nothing global. | — | — |
| UC-KEY-05 | ← / → | Only while previewing: seek ±5 s (hold repeats). Otherwise they belong to the focused control (outline expand/collapse, grid movement, text caret). | Preview | — |
| UC-KEY-06 | ↑ / ↓ while previewing | The preview moves with the selection (each track from its own hot spot). ↩ while previewing plays that track for real from the previewed position. | Preview | — |
| UC-KEY-07 | ⌘→ / ⌘← | Next / Previous (a focused text field keeps line end / start) | Main window | Playback |
| UC-KEY-08 | ⌥⌘→ / ⌥⌘← | Skip Forward / Back 10 Seconds | Main window | Playback |
| UC-KEY-09 | ⌘↑ / ⌘↓ | Volume Up / Down — except in Folders with a folder row selected, where ⌘↓ opens the folder as root (DEC-053) | Main window | Playback |
| UC-KEY-10 | ⌘. | Stop; in a sheet or alert: Cancel | Main window | Playback ▸ Stop |
| UC-KEY-11 | ⌘L | Go to Current Track (selects it in its playing context) | Main window | View |
| UC-KEY-12 | ⌘I | Show / hide Info for the selection | Main window | View ▸ Show Info (owns the key) · Track ▸ Get Info (same command) |
| UC-KEY-13 | ⌥⌘U | Show / hide Queue | Main window | View ▸ Show Queue |
| UC-KEY-14 | ⌘D | Download / Retry Download the selection's not-downloaded / failed tracks; with nothing selected in a playlist: all of the playlist's not-downloaded tracks (`playlists.html` Download n) | Selection | Track ▸ Download |
| UC-KEY-15 | ⌘R | Re-read from outside, titled per view: `Scan Library Folder` (All Tracks, Albums, Genres) · `Scan This Folder` (Folders) · `Refresh from ‹Source›` (linked playlist) · `Recompute Plan` (sync profile) · `Run Scan` (Review); disabled where nothing outside can be re-read | Current view | Track ▸ Refresh from Source |
| UC-KEY-16 | ⇧⌘R | Show in Finder | Selection with files | Track |
| UC-KEY-17 | ⌫ | Remove from the current container (playlist, queue, sync profile, genre) — undoable; Discover: Dismiss; Reels: Delete Reel…; Review ▸ Albums: Reject. **Nothing in All Tracks.** | Focused list | Edit ▸ Delete · Track ▸ Remove from … |
| UC-KEY-18 | ⌘⌫ | Remove from Library… (confirmation); in a confirmation alert: its destructive button | Selection | Track |
| UC-KEY-19 | ⌘A · ⇧⌘A · ⌘C · ⌘X · ⌘V · ⌘Z · ⇧⌘Z | Select All · Deselect All · Copy (tracks + `Title — Artist` lines) · Cut · Paste (tracks into a playlist at the selection; a link in the search field → suggestion) · Undo ‹action› · Redo | Focused list / text | Edit |
| UC-KEY-20 | ↩ / Esc / Tab in a text field | Commit / revert to the value before the edit / commit and go to the next field. Space, ←, →, ⌘←, ⌘→ edit text — never preview, seek or skip. | Text fields, inline rename, Info | — |
| UC-KEY-21 | ⌘N · ⇧⌘N · ⌥⌘N | New Playlist (inline name in the sidebar) · New Playlist from Selection · New Playlist Folder | Library open | File |
| UC-KEY-22 | ⌘U · ⇧⌘I · ⌘O | Add from Link… · Import Playlist from Source… · Open Library… | ⌘U/⇧⌘I: library open; ⌘O: always | File |
| UC-KEY-23 | ⌘1 … ⌘6 | All Tracks · Albums · Genres · Folders · Discover · Review (⌘7, ⌘8 unassigned) | Main window, library open | Go |
| UC-KEY-24 | ⌘[ · ⌘] | Back · Forward | Main window | Go |
| UC-KEY-25 | ⌘F · ⌥⌘F | Search (filters the current view) · Search Library. In the Activity window ⌘F focuses the log search; Settings and sheets keep their own ⌘F. | Main window | Edit ▸ Find |
| UC-KEY-26 | ⌃⌘S · ⌃⌘F | Show/Hide Sidebar · Enter/Exit Full Screen | Main / key window | View |
| UC-KEY-27 | ⌥⌘0 · ⌘, · ⌘? | Activity window · Settings… · MLM Help | Always | Window · MLM · Help |
| UC-KEY-28 | ⌘W · ⌘M · ⌘H · ⌥⌘H · ⌘Q | Close Window · Minimize · Hide MLM · Hide Others · Quit MLM (asks only when work is running) | System | File · Window · MLM |
| UC-KEY-29 | K | Keep the selected recommendation | Discover ▸ Recommendations | — (context menu) |
| UC-KEY-30 | → (Review group) · ↩ (Review group) | Show Comparison (expand) · Keep Recommended / Apply Merge | Review group rows | — (context menu) |
| UC-KEY-31 | ⌘S | Save ‹n› Changes (staged genre edits) | Genre detail with staged changes | — (button) |
| UC-KEY-32 | ⌥↑ / ⌥↓ | Move the row | Albums ▸ Edit Order | — |
| UC-KEY-33 | → / ← · ⌥→ / ⌥← · ⌘↓ (outline) | Expand / collapse (← on a child goes to its parent) · expand / collapse everything inside · open the folder as root | Folders, sidebar folders, Review groups | — |
| UC-KEY-34 | ↩ / Esc / ⌘. / ⌘⌫ / Tab in a sheet or alert | The primary button (never a destructive one) / Cancel / Cancel / the destructive button of a confirmation / next field | Sheets, alerts | — |
| UC-KEY-35 | Media keys | Play/Pause, Next, Previous via `MPRemoteCommandCenter` — the only keyboard Play/Pause. | System | — |

| ID | Rule |
|---|---|
| UC-KEY-36 | Every key with a menu item is defined once, as that item's key equivalent (`.keyboardShortcut` in `.commands`). Keys without a menu item belong to the focused control (`.onKeyPress` on the focused `Table` / `List`, `contextMenu(…primaryAction:)` for Return). No `NSEvent` local monitors for app shortcuts. (PATTERN-MENUS.N02, K-SEARCH-CMDF) |
| UC-KEY-37 | Never bind Space or plain Return as a menu key equivalent. Track ▸ Play / Track ▸ Preview do not register ↩ / Space; the keys are handled by the focused list. Playback ▸ Play/Pause has **no** shortcut. (§10 Q1, UC-KEY-01/02) *(display of ↩ / Space next to those items is optional — convention set here)* |
| UC-KEY-38 | Playback keys never fire while a text field has focus. (PATTERN-MENUS.N06) |
| UC-KEY-39 | No shortcut may be added, reassigned or given a second meaning without an `IMP` entry. Conflicts resolved for good: ⌘N one meaning; ⌘R one concept; ⌘F a normal menu key of the main window; ⌘8 gone; plain ←/→ not window-wide. (§4.2, PATTERN-MENUS.N03) |

### 9.3 Primary action (double-click / Return) per row kind

The primary action is always the first item of the row's context menu, except where noted. Playing never opens Info. (DEC-008, §4.3, PATTERN-MENUS.N04)

| ID | On | Double-click / ↩ | Status bar |
|---|---|---|---|
| UC-PRIM-01 | Local track | Play; queue = following rows of this view | — |
| UC-PRIM-02 | Not downloaded / Download failed track | Download (Retry); it plays when ready | `Downloading “‹title›” — it will play when it’s ready · Cancel` |
| UC-PRIM-03 | File missing track | Nothing plays | `File missing — Locate… · Download Again` |
| UC-PRIM-04 | Any local track while the drive is not connected | Nothing plays | `Can’t play — “Lexxar” is not connected.` |
| UC-PRIM-05 | Album / playlist / genre card or sidebar row | Open it; double-click the card's cover play badge or ⌥-double-click: play it | — |
| UC-PRIM-06 | Folder row (Folders) | Expand / collapse; ⌘↓ opens it as root (its context menu starts with `Open ⌘↓`, the exception to "first item") | — |
| UC-PRIM-07 | File not in the library (Folders) | Import it | `Importing 1 file…` → `Imported “‹title›”` |
| UC-PRIM-08 | Sync profile row | Open it; ↩ on the already selected sidebar row: rename | — |
| UC-PRIM-09 | Review group | Double-click / →: expand the comparison; ↩: the recommended action (`Keep Recommended` / `Apply Merge`) | `Kept the recommended version · Undo` |
| UC-PRIM-10 | Recommendation | Play it (it stays held in Discover; playing does not keep it); K keeps; ⌫ dismisses | `Added “‹title›” to the library · Undo` (Keep) |
| UC-PRIM-11 | Reel | Select it and show its detail; Space previews the video | — |
| UC-PRIM-12 | Queue row | Jump to it (play now; rows before it move to History) | — |
| UC-PRIM-13 | Activity operation | Open its subject (playlist, sync profile, tracks) | — |
| UC-PRIM-14 | Library row in the picker | Open the library | — |
| UC-PRIM-15 | Backup row (Settings) | Nothing — `Restore…` is an explicit button | — |
| UC-PRIM-16 | Online result (Search ▸ Online, Similar ▸ Online) | Preview (30 s stream); `Download` / `Keep` are explicit | — |

### 9.4 Menu bar (DEC-038)

| ID | Rule |
|---|---|
| UC-MENU-01 | Ten menus in this order: **MLM · File · Edit · View · Track · Playback · Library · Go · Window · Help**. Built with `.commands` on the main `Window` scene (`CommandMenu`, `CommandGroup`, `SidebarCommands()`, `ToolbarCommands()`, `InspectorCommands()`), driven by `FocusedValue`. (DEC-038, PATTERN-MENUS.N01) |
| UC-MENU-02 | Menu-bar items never disappear: a command that can't run now is disabled (unlike context menus). Every command in the app has a menu-bar item. No dead items: an item that is enabled works. (PATTERN-MENUS.N01) |
| UC-MENU-03 | Titles name their subject where it helps: `Undo Add to “Warm-up”`, `Refresh from SoundCloud`, `Shuffle All Tracks`, `Shuffle “Warm-up”`, `Remove from “Warm-up”`, `Hide Sidebar` / `Show Sidebar`, `Show Info` / `Hide Info`, `Retry Download`, `Download 3 Tracks`. (PATTERN-MENUS.N01) |
| UC-MENU-04 | With Settings or the Activity window in front, selection commands are disabled. With no library open only these work: File ▸ New Library…, Open Library…, Open Recent; MLM ▸ Settings…; Window ▸ Activity; Help. (PATTERN-MENUS.N01) |
| UC-MENU-05 | Contents, exactly (— = separator): |

| Menu | Items |
|---|---|
| **MLM** | About MLM · — · Settings… ⌘, · — · Services ▸ · — · Hide MLM ⌘H · Hide Others ⌥⌘H · Show All · — · Quit MLM ⌘Q (only with running work: alert `Quit MLM?` listing what stops, buttons `Quit` / `Cancel`) |
| **File** | New Playlist ⌘N · New Playlist from Selection ⇧⌘N · New Playlist Folder ⌥⌘N · New Sync Profile… · — · Add from Link… ⌘U · Import Playlist from Source… ⇧⌘I · Import Files or Folder… · Import M3U… · Export ▸ (Playlist as M3U… · Create ML Training Set…) · — · New Library… · Open Library… ⌘O · Open Recent ▸ (libraries with `— Not connected` / `— Not found` suffix, open one checked, live; — ; Clear Menu) · Show Library File in Finder · — · Close Window ⌘W |
| **Edit** | Undo ‹action› ⌘Z · Redo ⇧⌘Z · — · Cut ⌘X · Copy ⌘C · Paste ⌘V · Delete ⌫ (= Remove from ‹Container›; nothing in All Tracks) · Select All ⌘A · Deselect All ⇧⌘A · — · Find ▸ (Search ⌘F · Search Library ⌥⌘F) · system items (AutoFill, Start Dictation, Emoji & Symbols) |
| **View** | Hide/Show Sidebar ⌃⌘S · Show/Hide Info ⌘I · Show/Hide Queue ⌥⌘U · — · Columns ▸ · Sort By ▸ (columns; in a playlist `Playlist Order` first; — ; Ascending · Descending) · Filter ▸ (the view's scopes) · — · Go to Current Track ⌘L · — · Enter Full Screen ⌃⌘F · Customize Toolbar… |
| **Track** | Play · Preview · Play Next ⌥↩ · Add to Queue ⌥⇧↩ · — · Add to Playlist ▸ · Add to Sync Profile ▸ · — · Get Info ⌘I · Go to Album · Go to Artist · Find Similar · — · Download ⌘D (title adapts) · Locate File… · Refresh from Source ⌘R (title adapts, UC-KEY-15) · — · Show in Finder ⇧⌘R · Copy ▸ · Share… · — · Remove from ‹Container› ⌫ (disabled in All Tracks) · Remove from Library… ⌘⌫. With an album, playlist or folder selected the items act on its tracks. |
| **Playback** | Play / Pause (title follows the state; **no shortcut**) · Stop ⌘. · — · Next ⌘→ · Previous ⌘← · Skip Forward 10 Seconds ⌥⌘→ · Skip Back 10 Seconds ⌥⌘← · — · Volume Up ⌘↑ · Volume Down ⌘↓ · — · Shuffle ‹current view› · Repeat ▸ (Off · All · One) · — · Play ‹current view› (from the first row or from the selection). Enabled with nothing loaded: Play plays the current view. |
| **Library** | Refresh from Sources · Scan Library Folder · — · Find Duplicates · Find Albums · — · Maintenance ▸ (Fingerprint All Tracks · ReplayGain Analysis · Danceability Analysis · Similarity Analysis · — · Refresh Embedded Artwork · Fetch Artwork from MusicBrainz · Reread Tags from Files · — · Maintenance Settings…; a running job reads `‹Job› (Running)` and is disabled) · Back Up Now · — · Library Settings… |
| **Go** | All Tracks ⌘1 · Albums ⌘2 · Genres ⌘3 · Folders ⌘4 · Discover ⌘5 · Review ⌘6 · — · Back ⌘[ · Forward ⌘] · — · Playlists ▸ (All Playlists · — · playlist folders as submenus, playlists in sidebar order) · Sync Profiles ▸ (profiles in sidebar order) |
| **Window** | Minimize ⌘M · Zoom · (system tiling items) · — · Activity ⌥⌘0 · — · Bring All to Front · — · window list (`‹Place› — ‹Library name›`, `Activity`, `Settings`) |
| **Help** | Search (system) · MLM Help ⌘? · Keyboard Shortcuts (window with the map of §9.2) · — · Show Tips Again |

(`patterns-menus-shortcuts.html` M-APP … M-HELP, corrected by §10 Q1; `Find Duplicates` / `Find Albums` without ellipsis per UC-COPY-05, see §23 C20)

### 9.5 Dock menu

| ID | Rule |
|---|---|
| UC-DOCK-01 | `applicationDockMenu(_:)` returns, in order: the now-playing line `‹Title› — ‹Artist›` as a disabled header (`Not playing` when idle) · Play / Pause (title follows state) · Next · Previous · — · `Open Recent` header · the other known libraries with their state suffix (unreachable ones disabled). The system appends its own items. No mini player, no `MenuBarExtra`. (§6, M-DOCK) |

### 9.6 Search

| ID | Rule |
|---|---|
| UC-SEARCH-01 | One system search field (`.searchable` on the `NavigationSplitView`, in the toolbar). Typing always filters the current view in place — tracks, albums, playlists, folders, genres, review groups. No results pane, nothing navigates. (DEC-017, §4.7) |
| UC-SEARCH-02 | While searching, `.searchScopes($scope, activation: .onSearchPresentation)` shows `This view` (default, always restored) · `Library` (everything, grouped: Tracks, Albums, Playlists, Folders; sections without hits are left out) · `Online` (SoundCloud, YouTube, Spotify, DAB). (§4.7, `search.html`) |
| UC-SEARCH-03 | Online results are transient: nothing is written to the library until the user presses `Download` or `Add` / `Keep`. (§4.7, DEC-013) |
| UC-SEARCH-04 | Tokens: typing `artist:`, `album:`, `genre:`, `year:`, `bpm:`, `is:` offers library values that become tokens (`genre: Techno`, `is: not downloaded`, `is: no album`, `bpm: 120–128`); different kinds combine with AND, values of one kind with OR. Suggestions also list recent searches. (§4.7, `search.html` token suggestions) |
| UC-SEARCH-05 | A pasted or dropped URL shows suggestion rows instead of results: `Download track from YouTube — “‹title›”` / `Import playlist from SoundCloud… (44 tracks)` / `Add from Link… ⌘U`, leading to S-QUICKADD / S-IMPORT. (DEC-018) |
| UC-SEARCH-06 | Return confirms the first suggestion if one is shown, else moves focus to the filtered rows. Esc clears text and tokens, returns the scope to `This view`, keeps selection and scroll position. The query belongs to the view for the session. (K-SEARCH-RETURN, K-SEARCH-ESC, §4.7) |
| UC-SEARCH-07 | No results: `ContentUnavailableView.search(text:)` with `Clear Filters` and the escalation buttons `Search the Library` / `Search Online`; the scope bar and its counts stay visible. (DEC-017, PATTERN-STATES.N11) |

---

## 10. Context menus

### 10.1 Rules

| ID | Rule |
|---|---|
| UC-CM-01 | Every context menu and every `More` (•••) menu uses these groups, in this order, separated by dividers; a menu is a subset, never a reordering. Groups that don't apply disappear — no disabled placeholders. (DEC-039, §4.4, PATTERN-CM.N01/N02) |

| # | Group | Items, in this order | Shown when |
|---|---|---|---|
| 1 | Primary | Play · Preview · Open | Always first; the ↩ action is the first item |
| 2 | Queue | Play Next · Add to Queue | The subject contains tracks |
| 3 | Add to | Add to Playlist ▸ · Add to Sync Profile ▸ | The subject can be collected |
| 4 | Info / edit | Get Info · Rename · Choose Cover… · Move to Folder ▸ · Go to Album · Go to Artist · Find Similar | Per subject; "Go to" only with one subject |
| 5 | Fix | Download · Retry Download · Refresh from ‹Source› · Locate File… · Scan This Folder | Only when something can be fixed or fetched |
| 6 | Locate / share | Show in Finder · Copy ▸ · Share… | Show in Finder / Share… need a file; Copy ▸ always |
| 7 | Remove | Remove from ‹Container› · Remove from Library… / Delete ‹Thing›… | Always last, behind a separator; the irreversible item is the very last |

| ID | Rule |
|---|---|
| UC-CM-02 | Build each subject's menu once (`TrackMenu`, `PlaylistMenu`, `AlbumMenu`, `FolderMenu`, `GenreMenu`, `SyncProfileMenu`, …) as a `@ViewBuilder` of `Section`s; the context menu, the header `More` menu, the selection bar's `More` and the Track menu use the same builder. `More` omits what the header shows as buttons (Play, Shuffle, Sync Now) and may add detail-only commands (`Import M3U into This Playlist…`, `Edit Order`). (DEC-022, PATTERN-CM.N06) |
| UC-CM-03 | Labels are Title Case verbs (`Add to Playlist`, `Show in Finder`, `Remove from Library…`); `…` only when the command asks for more before acting (sheet, file panel, confirmation); glossary words only. (DEC-039, PATTERN-CM.N04) |
| UC-CM-04 | With ≥ 2 subjects the menu starts with a disabled header line with the count (`3 tracks`, `2 playlists`, `3 genres`); labels never carry the count, except when an item applies to part of the selection (`Download 1 Not-Downloaded Track`). Items that need one subject (Preview, Go to …, Rename, Choose Cover…, Link Source…, Open) disappear. (PATTERN-CM.N03, CM-TRACK multi) |
| UC-CM-05 | The only disabled items: file actions while the drive is not connected (Play, Preview, Show in Finder, Share…, Remove from Library…, Scan This Folder, Import Files). They stay visible, disabled, under a header line `“Lexxar” is not connected`, and carry the same sentence as help text. Not-downloaded tracks keep their normal menu (Download is queued). (DEC-014, PATTERN-CM.N02, CM-TRACK/drive-off) |
| UC-CM-06 | Shortcuts shown next to items when one exists (↩, Space, ⌥↩, ⌥⇧↩, ⌘I, ⌘D, ⌘R, ⇧⌘R, ⌫, ⌘⌫) — the context menu teaches the keyboard. No icons except the Play and Download glyphs; never an icon as the only label. (PATTERN-CM.N04) |
| UC-CM-07 | The reversible removal comes first in the Remove group, in normal colour (`Remove from Playlist ⌫`, undoable, no question); the irreversible one last with `role: .destructive` and `…` (`Remove from Library… ⌘⌫`, `Delete Playlist…`). Remove from Library does not exist in the Queue or in a sync profile. (PATTERN-CM.N05, CM-QUEUE, CM-SYNC-TRACKROW) |
| UC-CM-08 | Container names are real: `Remove from “Warm-up”` where containers are mixed, `Remove from Playlist` inside one playlist, `Remove from “iPod Classic”` in a profile. The current playlist is left out of its own Add to Playlist ▸. (PATTERN-CM.N04, CM-TRACK in a playlist) |
| UC-CM-09 | Choosing an item that changes something silently confirms in the status bar with Undo; nothing navigates unless the verb says so (Open, Go to …, Show …). (PATTERN-CM.N04, P3) |
| UC-CM-10 | Inline rename fields use the system text menu; MLM adds nothing (Esc cancels). Log text uses the system text menu plus `Show Only “‹Source›” Lines` and `Show Only This Operation`. (CM-SIDEBAR-PINNEDRENAME, CM-LOGS-TEXT) |

### 10.2 Subject catalogue (items in order; `—` = separator; `[cond]` = only when the condition holds)

| Subject (ID) | Menu |
|---|---|
| Track, local (`CM-TRACK`) | Play ↩ · Preview Space — Play Next ⌥↩ · Add to Queue ⌥⇧↩ — Add to Playlist ▸ · Add to Sync Profile ▸ — Get Info ⌘I · Go to Album [has album] · Go to Artist · Find Similar — Show in Finder ⇧⌘R · Copy ▸ · Share… — Remove from ‹Container› ⌫ [in a container] · Remove from Library… ⌘⌫ |
| Track, several (`CM-TRACK multi`) | header `‹n› tracks` · Play — Play Next · Add to Queue — Add to Playlist ▸ · Add to Sync Profile ▸ — Get Info — Download ‹n› Not-Downloaded Track(s) [some] — Show in Finder · Copy ▸ · Share… — Remove from Library… |
| Track, Not downloaded | Play (downloads, then plays) — Queue group — Add to — Get Info · Go to … · Find Similar — Download ⌘D — Copy ▸ (Title — Artist, Link) — Remove from Library… |
| Track, Download failed | Play (retries, then plays) — Queue — Add to — Info group — Retry Download ⌘D · Locate File… — Copy ▸ — Remove from Library… |
| Track, File missing | Add to Playlist ▸ · Add to Sync Profile ▸ — Get Info · Go to … · Find Similar — Locate File… · Download Again [has a source] — Copy ▸ — Remove from Library… |
| Queue row (`CM-QUEUE`) | Play ↩ · Preview — Play Next · Move to End of Queue — Add to — Get Info · Go to Album · Go to Artist · Find Similar · Show in “‹context›” — Download [not downloaded] — Show in Finder · Copy ▸ · Share… — Remove from Queue ⌫ |
| History / Now playing row (`CM-QUEUE.N01`) | Play — Play Next · Add to Queue — Add to — Get Info · Go to Album · Find Similar — Show in Finder · Copy ▸ — Clear History |
| File not in library, Folders (`V-FOLD.N02/menu`) | Import File / Import ‹n› Files — Show in Finder · Copy Path |
| Folder row (`CM-FOLD-TREE`) | Open ⌘↓ · Play — Play Next · Add to Queue — Add to Playlist ▸ (New Playlist from Folder first) · Add to Sync Profile ▸ — Scan This Folder ⌘R · Import Files [has files not in library] — Show in Finder ⇧⌘R · Copy Path (no Remove group) |
| Sidebar playlist row (`CM-SIDEBAR-PINNED`) | Play — Play Next · Add to Queue — Add to Sync Profile ▸ — Rename · Move to Folder ▸ — Download ‹n› Tracks [has not-downloaded] · Refresh from ‹Source› [linked] — Show in All Playlists — Delete Playlist… |
| Playlist card (`CM-PL-CARD`) | Open ↩ · Play — Play Next · Add to Queue — Add to Sync Profile ▸ — Rename · Choose Cover… · Use Automatic Cover [custom cover] · Move to Folder ▸ — Download ‹n› Tracks · Show Failed Downloads [failed] · Refresh from ‹Source› [linked] · Link Source… — Delete Playlist… |
| Playlist ▸ More (`V-PLD.N01/menu`) | Play Next · Add to Queue — Add to Sync Profile ▸ — Rename · Choose Cover… · Use Automatic Cover · Move to Folder ▸ — Download ‹n› Tracks · Refresh from ‹Source› ⌘R · Link Source… · Import M3U into This Playlist… — Delete Playlist… |
| Playlist cover (`V-PLD.E02/menu`) | Choose Cover… · Use Automatic Cover [custom] |
| Playlist folder (`P-SIDEBAR.N03/menu`) | New Playlist in Folder — Rename — Delete Folder… |
| Album card (`CM-ALB-CARD`) | Play — Play Next · Add to Queue — Add to Playlist ▸ · Add to Sync Profile ▸ — Get Info · Go to Artist — Download ‹n› Tracks [some not downloaded] — Show in Finder — Remove from Library… |
| Album ▸ More (`CM-ALBD-MORE`) | Play Next · Add to Queue — Add to Playlist ▸ · Add to Sync Profile ▸ — Edit Album Info… · Choose Cover… · Edit Order · Merge with Another Album… — Download ‹n› Tracks — Show in Finder — Remove from Library… |
| Album row "Not in library" (`CM-ALBD-ABSENT`) | Find Online · Use a Track from the Library… — Copy Title — Artist |
| Genre row (`CM-GENRE-ROW`) | Open ↩ · Play — Play Next · Add to Queue — Add to Playlist ▸ · Add to Sync Profile ▸ — Rename Genre… [one] · Merge Genres… [≥ 2] |
| Genre ▸ More (`CM-GENRED-MORE`); Genres list ▸ More | Play Next · Add to Queue — Add to Playlist ▸ · Add to Sync Profile ▸ — Rename Genre… · Merge with Another Genre… ; list: Export Create ML Training Set… |
| Genre detail track / suggestion (`CM-STUDIO-GENRETRACK`, `CM-STUDIO-SUGGESTION`) | Track menu + `Use as Reference for Suggestions` (Info group) and `Remove from “‹Genre›” ⌫` before Remove from Library…; suggestion: `Add to “‹Genre›”` first in Add to, `Not This Genre` in Remove |
| Sync profile row / More (`CM-SYNC-PROFILE`, `V-SYNC-DETAIL.N10`) | Open · Sync Now — Rename · Duplicate · Change Destination… · Read Playlist Changes from Device… · Recompute Plan ⌘R — Show in Finder · Eject “‹DEVICE›” [removable] — Delete Sync Profile… (More omits Open and Sync Now) |
| Playlist / album in a profile (`CM-SYNC-PLROW`) | Open — Add to Sync Profile ▸ — Download Not-Downloaded Tracks [plan skips some] — Remove from “‹profile›” ⌫ |
| Track in a profile (`CM-SYNC-TRACKROW`) | Track menu without Fix; Remove group = `Remove from “‹profile›” ⌫` only |
| File in a plan (`CM-SYNC-PREVIEWFILE`) | Play — Get Info — Show Library File in Finder · Show on Device in Finder [copied] · Copy ▸ — Remove from “‹profile›” |
| Failed sync track (`CM-SYNC-FAILED`) | Play — Play Next · Add to Queue — Get Info — Retry — Show in Finder · Copy ▸ |
| Recommendation (`V-INBOX.N07`) | Preview — Keep K · Keep and Add to Playlist ▸ — Go to Seed Track · Find Similar — Show in Finder · Copy ▸ — Dismiss ⌫ |
| Online suggestion (`V-SIMILAR.N08`) | Preview — Download · Keep · Keep and Add to Playlist ▸ — Open on ‹Source› · Copy Link |
| Reel (`V-REELS.N09`) | Play Video — Identify Again · Mark as Done — Show in Finder · Copy ▸ — Delete Reel… ⌫ |
| Reel text fragment (`CM-REELS-TEXTPILL`) | Use as Artist · Use as Title · Use as “Artist – Title” (disabled when it can't be split) — Copy |
| Review duplicate group (`CM-REV-GROUP`) | Keep Recommended ↩ · Show Comparison → — Show Versions in All Tracks — Keep All — Not Duplicates — Copy |
| Review conflict group | Apply Merge ↩ · Show Comparison → — Show Versions in All Tracks — Different Versions — Keep Both — Copy |
| Review version (`CM-REV-VERSION`) | Play · Preview — Play Next · Add to Queue — Add to Playlist ▸ — Get Info · Show in All Tracks — Keep This Version — Show in Finder · Copy ▸ — Remove from Library… |
| Review album suggestion (`CM-REV-ALBUM`) | Play · Preview — Get Info · Show Suggested Album — Accept ↩ · Choose Another Album… · No Album · Reject ⌫ — Show in Finder · Copy ▸ |
| Activity operation (`CM-OPS-ROW`) | Show ‹Subject› (Show Playlist / Show Sync Profile / Show in All Tracks) — Retry Failed · Pause · Cancel / Cancel after This Track (honest) — Show in Logs · Copy Summary — Remove from History |
| Backup row (`ST-BACKUP.N04`) | Restore… — Show in Finder |
| Library row in the picker (`V-PICKER.N14`) | Open — Rename… — Show in Finder · Copy Path — Remove from List (not destructive: the file is untouched) |
| Column header (`V-TRACK-TABLE.N01`) | UC-TABLE-03 |
| Footer / Add menu | UC-SIDE-10 / UC-TB-05 |

### 10.3 Shared submenus (one builder each, the same everywhere)

| ID | Submenu | Items |
|---|---|---|
| UC-CM-11 | **CM-SUB-PLAYLIST** Add to Playlist ▸ | `New Playlist… ⇧⌘N` (new sidebar row in rename mode with the tracks in display order) — `Recent` (the three playlists used last) — the sidebar structure (folders as submenus, playlists in sidebar order). The current playlist is left out. Status bar: `Added ‹n› tracks to “‹playlist›” · Undo`; tracks already in it are skipped and counted. Used by context menus, Track menu, selection bar and Reels results. |
| UC-CM-12 | **CM-SUB-SYNC** Add to Sync Profile ▸ | The profiles (with their state as a second word when it matters) — `New Sync Profile…` (the S-SYNC-NEWPROFILE sheet with the selection as first content; primary button `Create and Add ‹n› Tracks`). Nothing navigates. Status bar: `Added ‹n› tracks to “‹profile›” · Undo`. |
| UC-CM-13 | **CM-SUB-COPY** Copy ▸ | `Title — Artist` (one line per track) · `File Path` (plain path, one per line, absent without a file) · `Link` (source URL, absent without a source). Other subjects adapt: folder → `Copy Path` (no submenu), review group → `Title — Artist`, operation → `Copy Summary`. ⌘C on a selection copies `Title — Artist` lines. |
| UC-CM-14 | **CM-SUB-MOVE** Move to Folder ▸ | `No Folder` · the playlist folders (check mark on the current one) — `New Playlist Folder…` (creates it and moves the playlist). Undoable. |

---

## 11. Drag and drop

### 11.1 Rules

| ID | Rule |
|---|---|
| UC-DND-01 | Tracks, albums, playlists, folders and genres are `Transferable` with two representations: an internal one (`CodableRepresentation` with an exported UTType, carrying IDs in display order + the source container) and `ProxyRepresentation(exporting: \.fileURL)` → `public.file-url` for local files. The UTType is declared in Info.plist. (DEC-040, PATTERN-DND.N01) |
| UC-DND-02 | The file-URL representation is offered only for tracks that have a file and while the drive is connected. Tracks without a file are left out of drags to Finder/other apps and counted in the status bar (`Copied 2 files · 1 track isn’t downloaded and was left out`). With the drive not connected nothing leaves MLM: `Can’t copy files — “Lexxar” is not connected`. The source is never written into what leaves MLM. (PATTERN-DND.N01, N05, D-LIB-TO-FINDER) |
| UC-DND-03 | Drop feedback is system-drawn only: accent ring for "onto", insertion line for "between", the drag image is the first row with a count badge, the cursor shows copy (+) / move / not allowed. Targets that can't take the drag show no ring and the not-allowed cursor. No pulsing, no banners. (PATTERN-DND.N02) |
| UC-DND-04 | Sidebar rows accept drops directly; spring-loading stays as the system offers it on valid targets but is never required. (DEC-040, §4.5, PATTERN-DND.N03) |
| UC-DND-05 | Every drop confirms in the status bar with Undo (8 s and Edit ▸ Undo), or — for imports — starts an Activity operation with a result. Nothing navigates; the open view does not switch. Skipped items are counted in the same sentence. "Add" never duplicates. (DEC-016, PATTERN-DND.N04) |
| UC-DND-06 | Not drag sources: fixed sidebar rows; the toolbar player (it is a drop target); Review groups, Activity operations, backups, picker rows, Settings rows; "Not in library" rows (Folders file rows drag to Finder as files only); account playlists in the import sheet; folder rows as a *move* on disk. (PATTERN-DND.N05) |
| UC-DND-07 | Drags between playlists copy (the source keeps its rows; cursor +). Moving = drop, then ⌫ in the source. (D-PLD-ROWS-OUT) |
| UC-DND-08 | Every folder/file choice that has a panel also accepts the dropped folder/file on its field, row or view. (PATTERN-SHEETS.N08) |

### 11.2 Matrix (rows = dragged, columns = target; `—` = no ring, not-allowed cursor)

| Dragged ↓ / onto → | Sidebar playlist | Playlists header / empty sidebar area / All Playlists background | Playlist folder | Sync profile | Playlist detail table | Player / Queue column | Genre row | Cover well | Finder / other apps | Window | Path field (Settings, setup, sheets) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Tracks | Append | New playlist from the selection (inline name) | New playlist inside | Add to the profile | Insert at the line · same playlist: reorder | Player: Play Next · Queue: top half Play Next, bottom half Add to Queue at the line | Set genre | — | Copies the files | — | — |
| Album | Append (album order) | New playlist named after the album | New playlist inside | Add the album | Insert its tracks | Play Next · Add to Queue | — | — | Copies its files | — | — |
| Playlist | Append its tracks | Between rows: reorder · empty area / header: move to top level | Move into the folder | Add the playlist | Insert its tracks | Play Next · Add to Queue | — | — | Copies its files (playlist order) | — | — |
| Folder (Folders) | Append every track inside | New playlist named after the folder | New playlist inside | Add its tracks | Insert its tracks | Play Next · Add to Queue | — | — | The folder | — | — |
| Genre | Append its tracks | New playlist named after the genre | New playlist inside | Add its tracks | Insert its tracks | Play Next · Add to Queue | — | — | — | — | — |
| Queue rows | Append | New playlist from the rows | New playlist inside | Add | Insert at the line | Reorder (insertion line) | — | — | Copies the files | — | — |
| Recommendation | Keep and add | Keep, new playlist | Keep, new playlist inside | Keep and add | Keep and insert | Play Next · Add to Queue (not kept) | — | — | Copies the file | — | — |
| Reel result / online result | Download and add (row shows Not downloaded → Downloading…) | Download, new playlist | — | — | Download and insert | — | — | — | The link (`public.url`) | — | — |
| Finder audio files / folders | Import and add | Import, new playlist (folder name) | Import, new playlist inside | — | Import and insert at the line | — | — | — | — | Import (any track list, Library section, Folders: into that folder) | — |
| Finder / browser image | — | — | — | — | — | — | — | Set cover (playlist, album, Info track artwork); non-images: no ring | — | — | — |
| `.m3u` / `.m3u8` | Import into this playlist (preview sheet) | Import as a new playlist (preview sheet) | Import as a new playlist inside | — | Import into this playlist (preview sheet) | — | — | — | — | Import as a new playlist (preview sheet) | — |
| Link (URL) | Add from Link…, target = this playlist | Playlist link: import sheet at step 2 | — | — | Add from Link…, target = this playlist | — | — | — | — | Add from Link… · playlist link: import sheet · Reels: fetch the reel | — |
| `.mlibm` library file | — | — | — | — | — | — | — | — | — | Open / switch library (also picker, Dock icon) | — |
| Finder folder / disk | — | — | — | — | — | — | — | — | — | (as audio folder: import) | Set that location (library folder, backup folder, cache, export destination, sync destination, setup step 2) |

Also: Reels list accepts `.mp4` / `.mov` files, folders and links (import / fetch as an Activity operation); a reel row drags out as its video file; Review version rows, Similar ▸ In library rows and the Info header cover drag as tracks. (PATTERN-DND.N06, §4.5, D-* entries)

---

## 12. Sheets, popovers, alerts, file panels

### 12.1 Sheets

| ID | Rule |
|---|---|
| UC-SHEET-01 | A sheet is `.sheet { Form { … }.formStyle(.grouped) }` in the main window. Title = the task and its object (`Import “Old iPod — On-The-Go 1.m3u8” into “Warm-up”`, `Link “Warm-up” to a Source`, `New Sync Profile`), never the app name or a bare noun. (§7.20, PATTERN-SHEETS.N02) |
| UC-SHEET-02 | First sentence = what will happen, in numbers (`38 tracks will be added to the end of “Warm-up”. Nothing is removed or reordered.`). No instructions the controls already give. (PATTERN-SHEETS.N02) |
| UC-SHEET-03 | Exactly one primary button, `.keyboardShortcut(.defaultAction)`, named by verb + count (`Add 38 Tracks`, `Import 44 Tracks`, `Create and Add 3 Tracks`, `Apply 5 Changes and Create 1 Playlist`, `Merge 3 Genres`); disabled until the sheet is valid — a sheet never closes and then fails. (§7.20, PATTERN-SHEETS.N02) |
| UC-SHEET-04 | `Cancel` (`.keyboardShortcut(.cancelAction)`) is always present and always works (Esc, ⌘.), also while the sheet is checking something. Multi-step sheets add `Back`. A sheet that waits for the browser (S-SRC-OAUTH) has no primary button. (PATTERN-SHEETS.N02, S-SRC-OAUTH) |
| UC-SHEET-05 | Errors appear inline, directly above the buttons, as a sentence with the cause (`A library named “New Library” already exists there. Choose another name.`). Never a second alert on top of a sheet; the sheet stays open. (§7.20, PATTERN-SHEETS.N07) |
| UC-SHEET-06 | The footer's left side may carry one quiet remark (`You can undo this.`, `Goes to All Tracks · progress in Activity`, `Runs in Activity`). (PATTERN-SHEETS.N02) |
| UC-SHEET-07 | A sheet shows progress only for work that ends within about 10 s (checking a link, reading a playlist, comparing a folder): a phase sentence + `ProgressView` (determinate when a total is known), Cancel enabled, primary disabled until done. Longer work is handed to Activity: the sheet closes on the primary button, the status bar marks the start, the starting place echoes it. (DEC-044, PATTERN-SHEETS.N03/N04) |
| UC-SHEET-08 | `.interactiveDismissDisabled()` only while a sheet runs a phase that must not be interrupted (S-ADOPT). (S-ADOPT) |

### 12.2 Popovers

| ID | Rule |
|---|---|
| UC-SHEET-09 | A popover (`.popover`) is a glance: dismissed by clicking away or Esc, system container, no custom background, no decision that matters. (PATTERN-SHEETS.N01) |
| UC-SHEET-10 | Popovers in B1, and only these: Activity · large cover (300 pt, names, `Go to Album`, `Go to Current Track ⌘L`; cover draggable) · volume (slider, `⌘↑ / ⌘↓ · remembered between launches`) · reel keyframe still · How to Install · Save Queue as Playlist (name field, `Cancel` / `Create`, Return creates — the one naming popover) · TipKit tips. New playlists are named inline, never in a popover. (DEC-010, DEC-006, P-QUEUE.N15, S-PL-NEWPLAYLIST; see §23 C7, C8) |

### 12.3 Alerts

| ID | Rule |
|---|---|
| UC-SHEET-11 | Use an alert only when the consequence can't be undone (Trash, restore, relaunch, sign-out, delete a sync profile, delete a reel, clear cache) or MLM can't continue without an answer. Build with `.alert(_:isPresented:actions:message:)` / `.confirmationDialog(_:isPresented:titleVisibility: .visible…)` and `Button(role:)`. (§3.2, PATTERN-SHEETS.N05) |
| UC-SHEET-12 | Title = the question, with the object's name and count: `Delete “Warm-up”?`, `Remove 14 tracks from the library?`, `Switch to “Laptop Subset”?`. Never `Are you sure?`. (§7.20, PATTERN-SHEETS.N05) |
| UC-SHEET-13 | Message = the consequence: what goes, what stays, how to get it back, in numbers (`Their files move to the Trash and they are removed from 3 playlists and 1 sync profile. You can put the files back from the Trash.`). Running work that will stop is listed, not asked about. `This cannot be undone.` is not a consequence and is not used. (PATTERN-SHEETS.N05) |
| UC-SHEET-14 | Buttons are verbs (`Move to Trash`, `Delete Playlist`, `Restore and Relaunch`, `Switch and Relaunch`, `Disconnect`, `Clear Cache`). The destructive one has `role: .destructive`. `OK` appears only where there is nothing to choose (a failure to acknowledge); never `OK` for a choice. Non-destructive confirmations (Clear the log view, Keep Recommended in n Groups when only hiding) have no destructive role. (§7.20, DEC-028, A-LOGS-CLEAR) |
| UC-SHEET-15 | Default button (Return): when the action is destructive, **Cancel is the default** and the destructive button must be clicked (or ⌘⌫); when the action is harmless the primary is the default (`Switch and Relaunch`, `Try Again`). Esc = Cancel, always. (DEC-052, PATTERN-SHEETS.N05, PATTERN-MENUS.N05) |
| UC-SHEET-16 | A failure is an alert only when MLM can't continue without the answer (`Restore didn’t finish` · one button `Relaunch`; `‹n› of ‹m› tracks couldn’t be removed` with `Show the ‹n› Tracks` / `OK` and a `Details` disclosure). Every other failure is a sentence where it happened (UC-SHEET-17). (PATTERN-SHEETS.N05/N07) |

### 12.4 Where failures go

| ID | The attempt was made in | The failure appears | Example |
|---|---|---|---|
| UC-SHEET-17 | A text field (rename, tag edit) | Under the field; the field stays open with the typed text | `Couldn’t save this change — the library database is busy. Try Again` |
| UC-SHEET-18 | A sheet | Inline above the buttons; the sheet stays | `A library named “New Library” already exists there. Choose another name.` |
| UC-SHEET-19 | A row action or shortcut | Status bar: what failed — the cause · the fix | `Couldn’t dismiss “Glue (Hammer Remix)” — the file is in use by another app. Try Again` |
| UC-SHEET-20 | A background job | Activity ▸ Needs attention, grouped by cause, plus the echo where it started | `yt-dlp not found — 4 downloads waiting` |
| UC-SHEET-21 | A header action of the shown thing (refresh, link) | One line in the view header with the action; clears on the next success or ✕ | `Couldn’t refresh from SoundCloud · SoundCloud didn’t answer. The playlist is unchanged. · Try Again · Details` |
| UC-SHEET-22 | Something MLM can't continue from | Alert with one way forward | `Restore didn’t finish` · `Relaunch` |
| UC-SHEET-23 | A drop that was refused | A sentence where it was dropped (card: 5 s) or in the status bar | `Couldn’t use “notes.txt” as a cover. Drop a PNG, JPEG or HEIC image.` |

(PATTERN-SHEETS.N07, S-PL-BANNER-COVERDROP, PATTERN-STATES.N16)

### 12.5 System file panels

| ID | Rule |
|---|---|
| UC-SHEET-24 | Every file or folder choice is the system panel via `.fileImporter(isPresented:allowedContentTypes:…)` / `.fileExporter`, with `.fileDialogMessage(_:)` saying what is being chosen; only selectable types enabled; the default button is the system's. No hand-rolled `NSOpenPanel` / `NSSavePanel`. (PATTERN-SHEETS.N08, §6) |
| UC-SHEET-25 | Message lines, verbatim: Open Library… `Choose a library file.` · library folder `Choose the folder that contains your music.` · import `Choose audio files or a folder to import.` · backups `Choose a folder for backups.` · transcode cache `Choose a folder for the transcode cache.` · Create ML `Choose a folder for the Create ML training set` · sync destination `Choose the folder or disk to sync to.` · M3U `Choose an M3U playlist to import into “‹playlist›”.` · Reels `Choose video files or a folder of videos.` (PATTERN-SHEETS.N08 table) |

---

## 13. Undo

| ID | Rule |
|---|---|
| UC-UNDO-01 | One `UndoManager` per main window (`@Environment(\.undoManager)`). Every undoable action registers an undo with an action name; Edit ▸ Undo shows `Undo ‹action name›`. (DEC-041, §4.6) |
| UC-UNDO-02 | **Undoable** (no confirmation): tag edits (single and multi, one step per commit), artwork set, add / remove / reorder in playlists and albums, playlist rename / move / delete (delete restorable until quit), playlist folder create / rename / delete, link a playlist to a source, import an M3U into a playlist, apply device playlist changes, queue edits, Review decisions, recommendation Keep / Dismiss (Dismiss until the Trash is emptied), sync-profile content changes, genre merge, album merge, album edit, cover changes, New Playlist / New Playlist from Selection (undo removes it). (DEC-041, §4.6, PATTERN-SHEETS.N06 table) |
| UC-UNDO-03 | **Not undoable — confirmed instead** (UC-SHEET-11): Move to Trash / Remove from Library, remove an album from the library, delete a reel, delete a sync profile, restore a backup, switch library (relaunch), disconnect a source, path migration and its rollback (own rollback), clear the transcode cache, clear waiting analyses, clear the Qobuz cookie. (DEC-041, PATTERN-SHEETS.N06 table) |
| UC-UNDO-04 | Decision rule: if MLM can undo it, do it at once, confirm in the status bar with `Undo` for 8 s and register it — **don't ask**. If it can't be undone inside MLM, ask with a consequence-stating alert — and don't pretend it is undoable. (DEC-016, DEC-041, DEC-050) |
| UC-UNDO-05 | Exceptions that both confirm and stay undoable: **Delete Playlist** (alert, because it also leaves sync profiles; restorable with Undo until MLM quits — DEC-049); bulk decisions touching many items at once — `Keep the recommended version in ‹n› groups?` (A-REV-APPLYALL) and `Set the album for ‹n› tracks?` (A-REV-ALBBULK) — whose message says `You can undo this in one step.` When Apply Recommended moves files to the Trash, its button gets the destructive role. (DEC-049, DEC-028, DEC-021) |
| UC-UNDO-06 | No confirmation, ever, for: removing tracks from a playlist (any count), the queue or a sync profile; dismissing a recommendation. (DEC-050) |
| UC-UNDO-07 | Action names are Title Case verb phrases with the real object: `Add to “Warm-up”`, `Remove from “Warm-up”`, `Rename Playlist`, `Delete “Warm-up”`, `Edit Tags`, `Set Artwork`, `Reorder “Warm-up”`, `Keep Recommended`, `Dismiss Recommendation`, `Merge Genres`, `Move to “Sets”`. *(names other than `Add to “Warm-up”` unspecified in B1 — convention set here)* (DEC-041, M-EDIT.N01) |
| UC-UNDO-08 | One user gesture = one undo step (a multi-track tag edit, a drop of 40 tracks, Apply Recommended to All, a merge). (DEC-041, §7.10) |
| UC-UNDO-09 | The status-bar `Undo` button and ⌘Z perform the same undo; a second confirmation never appears. (DEC-016) |

---

## 14. Background work (Activity)

| ID | Rule |
|---|---|
| UC-JOB-01 | Every job that can take longer than ~2 s is an **Activity operation** — downloads, imports, refreshes from sources, scans, analysis batches, sync, backups (incl. pre-update and launch backups), artwork backfill, tag writes queued for the drive, Reels fetches, transcode-cache moves, path migration, Create ML export, duplicate / album finding. Automatic ones are marked `Automatic`. No silent background work with lasting effects. (DEC-044, P5, G-JOB-SILENT) |
| UC-JOB-02 | An operation has: a kind, a subject (with a link to it), a state word (UC-STATE job table), progress with numbers when countable, a result that persists across relaunch (last 200 operations, in the library file), per-item outcomes with plain reasons, and honest controls. (DEC-044, `activity.html` P-ACTIVITY-OPS.E04/N02) |
| UC-JOB-03 | Honest controls: offer `Pause` only if it really pauses, `Cancel` only if it really stops, `Cancel after This Track` (or `… after the current file`) when that is the truth; no Cancel when there is none. A second import queues instead of being rejected. (§7.12, §7.11) |
| UC-JOB-04 | **Toolbar Activity item** (`ToolbarItem` + `.popover`): idle = plain symbol, no text, no dot; running = determinate circular `ProgressView(value:).controlSize(.small)` + short text `‹Verb›ing ‹n› of ‹m›` (`Downloading 12 of 44`), with several jobs the oldest running one + `+‹k›`; waiting = `‹n› waiting for “Lexxar”`; needs attention = `‹n› failed` stays until dismissed or fixed (shown after the running text, separated by `·`). Never colour only. One `.symbolEffect(.bounce)` when a job ends. Present in every launch state. (DEC-005, DEC-044, §4.8, G-BG-ACTIVE; see §23 C14) |
| UC-JOB-05 | **Activity popover** (system container): sections `Running` (each with progress, numbers, Pause / Cancel as honest), `Needs attention` (grouped by cause, each group with its one fix — `Reconnect`, `Open Settings ▸ Sources`, `Retry All` — and `Dismiss`), `Recent` (results with counts and time); footer `Open Activity Window ⌥⌘0`. Each row links to its subject. (§4.8, P-ACTIVITY-OPS) |
| UC-JOB-06 | **Activity window** (`Window(id: "activity")`, ⌥⌘0, available in every launch state): tabs `Operations · Logs` (remembered). Operations: scope `All · Running · Needs attention · Finished` with live counts, `Retry All`, a table (kind · operation with subject link · State · progress · started · result · controls) and the per-item detail of the selected row. Logs: level filter (`All · Info and above · Warnings and above · Errors · Debug only`) and source filter, both persisted; search (⌘F); labelled `Pause` / `Resume` with state text (`Live` / `Paused · ‹n› new lines held`); `Wrap lines` checkbox; `Copy`; `Export…`; `Show Log File in Finder`; `Clear…` (confirmed); a deep link from a failure (`Show in Logs`) pre-filters to that operation with `Show All Lines` to return. (DEC-005, §7.12, `activity.html`) |
| UC-JOB-07 | **Inline echo** at the place that started the job uses the same words and numbers as Activity: playlist header and sidebar row `Importing · 12 of 44`; sync profile header and row `Syncing 86 of 214`; Review `Scan running` progress; Settings ▸ Maintenance job rows with coverage (`9,412 of 12,935 analysed`). Never a second, different count. (§4.8, DEC-044) |
| UC-JOB-08 | **Status bar** marks start and end only: `‹Kind› started — ‹n› ‹items› · Show in Activity`, `‹Kind› finished — ‹results› · Show`. (§4.8, PATTERN-SHEETS.N04) |
| UC-JOB-09 | **Sidebar**: counts only for Inbox badges; state text under sync-profile rows and unhealthy playlist rows; nothing for generic work. (§4.8) |
| UC-JOB-10 | Work that needs the drive waits while it is not connected and says so (`“Lexxar” not connected · 14 waiting` in Needs attention; `3 tag changes waiting for “Lexxar”`), then starts by itself when the drive returns. Never mark items failed or missing because of the drive. (DEC-014, PATTERN-STATES.N18–N20) |
| UC-JOB-11 | Failures are grouped by cause with the fix: `yt-dlp not found · Open Settings ▸ Sources`, `Sign-in expired (SoundCloud) · Reconnect`, `“Lexxar” not connected · 14 waiting`. Reasons are the real cause in plain words (never `Video unavailable` for everything). (§7.12) |
| UC-JOB-12 | A finished job never steals focus, opens a window or navigates. System notifications only when MLM is not frontmost and only if the user opted in (Settings ▸ General, off by default), for import, sync and backup results/failures. (P3, §6 notifications) |

---

## 15. State vocabulary

One word per meaning, spelled exactly as here in tables, headers, sidebar, Info, menus, Activity and code-facing enums' display strings. Symbols are SF Symbols; colour roles per UC-COLOR-05 (symbol tint only). "Fix" = the one action offered with the state. Changes against `UI-GROUNDTRUTH.md` §1.6 are applied (DEC-014, DEC-023, DEC-051). (`patterns-states.html` PATTERN-STATES.N04, P4)

| ID | Rule |
|---|---|
| UC-STATE-01 | A state is written once, at the highest level it applies to; lower levels go quiet: drive → window banner (+ footer two words), and then rows show nothing; library file → picker row; source sign-in → Settings ▸ Sources (+ echo where it blocks); playlist → header status sentence (+ sidebar second line, card subtitle), rows keep their own Status; sync profile / device → sidebar second line + profile header; track → Status column + Info ▸ File; job → Activity. (PATTERN-STATES.N01) |
| UC-STATE-02 | The eight places a state may appear: window banner · view header status line · Status column · sidebar second line (badges for Inbox) · sidebar footer · status bar · toolbar Activity item · Info ▸ File · player title area. No ninth place: no toasts, floating panels, sidebar dots, bottom strips, full-pane spinners. (PATTERN-STATES.N03) |
| UC-STATE-03 | Model each family as an enum with one display string per case (`TrackAvailability`, `PlaylistStatus`, `SourceStatus`, `JobStatus`, `DeviceStatus`, `ToolStatus`, `LibraryFileStatus`); views never build state strings ad hoc. (PATTERN-STATES.N04 api) |

### 15.1 Library file and launch

| Word / sentence (verbatim) | Symbol, colour | Where | Fix |
|---|---|---|---|
| `Opening “‹name›”…` + phase line (`Reading the library…`, `Backing up before update… 62 %`, `Finishing library file setup…` + `The setup was interrupted last time.`) | small `ProgressView`, determinate when known | Main window (launch) | — |
| `“‹name›” couldn’t be opened` / message names the cause and what is safe | — | Launch failure (`ContentUnavailableView`) | `Try Again` · `Choose Another Library` · `Restore from Backup…` · `Show Logs` + `Details` |
| (no word) — available library | — | Picker row: `‹n› tracks · last opened ‹date›` | `Open` |
| `Not found` | `questionmark.folder`, red | Picker row, Open Recent suffix `— Not found` (live) | `Locate…` · `Remove from List` |
| `Not connected — on “‹disk›”` | `externaldrive.badge.xmark`, orange | Picker row; Open Recent suffix `— Not connected` | `Try Again` (becomes available by itself when the disk appears) |
| `“‹name›” can’t be opened` + `The library file and its database don’t belong together. … MLM didn’t change anything.` | — | Picker row / alert | `Show in Finder` · `Restore from Backup…` · `OK` |
| `“‹file›” isn’t a valid library file` + cause + `MLM didn’t change it.` | — | Launch view / alert | `Choose Another Library` · `Show in Finder` (alert: `OK` · `Show in Finder`) |
| `“‹copy›” is a copy of “‹original›”` | — | Alert | `Open as Separate Library` · `Cancel` |
| `‹name› (needs setup)` + `‹n› tracks · not yet a library file` | — | Picker row (old install) | `Set Up…` (· `Open`) |
| `Switch to “‹name›”?` + list of work that will stop | — | Alert | `Switch and Relaunch` · `Cancel` |
| `‹library name›` (always named) | — | Window subtitle + sidebar footer | — |
| `The library “‹name›” couldn’t be created` | — | Alert (only after the sheet closed) | `Choose Another Location…` · `Cancel` |

### 15.2 Library folder and drive

| Word / sentence (verbatim) | Symbol, colour | Where | Fix |
|---|---|---|---|
| **Drive not connected** (state name, not shown): banner `“Lexxar” is not connected. You can browse, edit and queue downloads; playback and file actions are paused.` | `externaldrive.badge.xmark`, orange; quiet tinted opaque banner | Window banner in every view that lists tracks | `Try Again` |
| `“Lexxar” — not connected` | — | Sidebar footer second line | — |
| `Can’t play — “Lexxar” is not connected` | — | Player, help text of disabled Play/Shuffle and file actions, context-menu header `“Lexxar” is not connected` | none — resumes by itself |
| `“Lexxar” was disconnected — playback paused at ‹time›.` | — | Status bar at the moment it happens | — |
| `“Lexxar” connected.` | — | Status bar when it returns | `Resume` (only if something was playing) |
| (nothing) — library folder on the Mac's own disk | — | No banner; footer shows the track count | — |
| `Not found` (library folder gone on a connected disk) | red symbol | Settings ▸ Library state line | `Locate…` |
| `Connected — on this Mac` / `Connected` | — | Settings ▸ Library state line | `Change…` |
| `No library folder` / `This library has no library folder yet, so there are no folders to show. Choose one in Settings ▸ Library.` / Settings: `No library folder set` | — | Folders (`ContentUnavailableView`), Settings ▸ Library | `Open Settings ▸ Library` |

`File missing` is **never** used for an unplugged drive. (DEC-014)

### 15.3 Sources, credentials, tools

| Word (verbatim) | Symbol, colour | Where | Fix |
|---|---|---|---|
| `Connected` (`· as ‹account› · last refreshed ‹time›`) | `checkmark.circle`, green | Settings ▸ Sources, import sheet | `Disconnect` |
| `Disconnected` (`· public playlists and links work without an account`) | — | Settings ▸ Sources, import sheet | `Connect` |
| `Sign-in expired` (also covers an unreadable keychain sign-in, with its own sentence) | `exclamationmark.triangle`, orange | Settings ▸ Sources, import sheet step 1, Activity group, playlist header | `Reconnect` (keychain once, then browser sign-in) |
| `‹Source› sign-in expired` + `‹n› tracks can’t be downloaded and Refresh is paused until you sign in again.` | `person.crop.circle.badge.exclamationmark`, orange | Playlist header status line (takes precedence over other playlist states) | `Reconnect` |
| `Not available yet` | dimmed row | Apple Music in Settings ▸ Sources | none |
| `Credentials file not found` + `‹Sources› can’t be connected without it.` | — | Settings ▸ Sources | `Show Where It Goes` |
| Qobuz access cookie: `Active · saved ‹time›` · `Expired — renew` · `Not configured` · `Active (set in the credentials file)` + consequence | — | Settings ▸ Sources | `Save` · `Clear…` |
| `Found ‹version›` (`Found — 2026.09.12 at /opt/homebrew/bin/yt-dlp`) | `checkmark.circle`, green | Settings ▸ Sources ▸ Download tools | — |
| `Not found` + what stops working | `exclamationmark.triangle`, orange | Download tools, Activity group (`yt-dlp not found — 4 downloads waiting`) | `How to Install` / `Open Settings ▸ Sources` |

Retired: `Not connected` for a source, `Token inaccessible`, `‹Source› disconnected — reconnect in Settings`. (G-SRC-*, DEC-037)

### 15.4 Track availability

| Word (verbatim) | Symbol, colour | Where | Fix |
|---|---|---|---|
| (nothing) = Local | — | Status column empty; scope `Local` | — |
| `Downloading…` | small `ProgressView` (`arrow.down.circle` where a spinner can't be used), secondary | Status column, Info ▸ File (same word) | `Cancel` (status bar / Activity) |
| `Not downloaded` | `icloud`, secondary | Status column, scope, Review, Info | `Download` (⌘D, Return) |
| `Download failed` (+ `‹reason› · ‹n› attempts left` in its scope and Info) | `exclamationmark.arrow.circlepath`, orange | Status column, scope, Info ▸ File | `Retry Download` (⌘D) · `Locate File…` |
| `File missing` (only while its drive is connected) | `doc.questionmark`, red | Status column, scope, Info ▸ File | `Locate…` · `Download Again` |
| `Not in library` | `doc.badge.plus`, secondary, row dimmed | Folders (files on disk), album detail (known tracklist) | `Import` / `Find` |
| `In library` | — | Similar ▸ Online, import preview | `Show` |
| `New` | — | Import preview (track not yet in library) | — |
| `Possible duplicate of “‹title›” (‹format›, ‹kbps› kbps).` | — | Info ▸ File | `Show in Review` |
| `—` | `.tertiary` | Absent album / value | `is: no album` filter; Review ▸ Albums |

Rows are dimmed only per UC-TABLE-10; `Download failed` rows are not dimmed. (DEC-051)

### 15.5 Playlist status (header status sentence; same words in the sidebar second line and card subtitle)

| Word (verbatim) | Symbol, colour | Fix | Precedence |
|---|---|---|---|
| (nothing) — healthy; facts line `‹n› tracks · ‹duration›` | — | — | — |
| `Linked to ‹Source›` (facts line, 6 pt brand dot) | brand dot | `Refresh from ‹Source›` | not a status |
| `‹Source› sign-in expired` | orange | `Reconnect` | 1 |
| `Importing · ‹n› of ‹m›` | `ProgressView`, secondary | `Show in Activity` | 2 |
| `Incomplete · ‹n› failed` | `exclamationmark.triangle`, orange | `Retry All` · `Show` (switches to scope `Download failed`) | 3 |
| `Not downloaded · ‹n› tracks` | `icloud`, secondary | `Download All` | 4 |
| `Sorted by ‹Column› — reordering is off` | — | `Sort by #` | (table hint, not a status) |
| `This playlist is empty. Drag tracks here or use Add to Playlist.` | — | — | empty state |
| `Playlist not found` (deleted elsewhere / creation undone) | — | — | view state |

With the drive not connected the playlist adds nothing of its own; Play / Shuffle stay, disabled with `Can’t play — “Lexxar” is not connected`. (DEC-023, G-PL-*)

### 15.6 Jobs (Activity)

| Word (verbatim) | Symbol, colour | Where |
|---|---|---|
| `Queued` (reason in Progress, e.g. `212 waiting`) | `clock`, secondary | Activity State column |
| `Running` | `ProgressView`, secondary; accent ring in the toolbar | Activity, toolbar item |
| `Paused` (by MLM with its reason: `Waiting — paused while downloads run`) | `pause.circle`, secondary | Activity |
| `Completed` (result may carry failures: `35 downloaded · 9 failed`) | `checkmark.circle`, secondary | Activity ▸ Finished / Recent |
| `Failed` (cause + one action) | `xmark.octagon`, red | Activity ▸ Needs attention |
| `Cancelled` | `xmark.circle`, secondary | Activity ▸ Finished / Recent |
| Per-item words: `Downloaded` · `Downloading…` · `Queued` · `Download failed` · `Skipped — already downloaded` | — | Operation detail |
| `‹n› failed` | — | Toolbar Activity item (needs attention) |

Exactly these six job words. Retired: `Stalled`, lowercase enum names, blue/green text. (G-JOB-STATUS, DEC-044)

### 15.7 Player

| Sentence (verbatim) | Fix |
|---|---|
| `Not playing` | — |
| `Preview` (tag) + `Space to stop · Return to play`; online: `Preview · from YouTube` | — |
| `Can’t play — not downloaded` | `Download` |
| `Can’t play — file missing` | `Locate…` |
| `Can’t play — “Lexxar” is not connected` | — |
| `Skipped ‹n› tracks that aren’t downloaded` (status bar, queue playback) | `Download` |

Retired: `Playback unavailable: … file could not be found on disk.` (DEC-045, G-PLAYBACK-ERROR)

### 15.8 Sync profiles and devices

| Word / sentence (verbatim) | Symbol, colour | Where | Fix |
|---|---|---|---|
| `Connected` (`· ‹n› to add`) | `checkmark.circle`, green | Profile header, sidebar second line | `Sync Now` |
| `Not connected` (header adds `· last connected ‹date›`) | `eject`, secondary | Sidebar second line, header; Sync Now disabled with `Connect “‹DEVICE›” to sync.` | — |
| `‹n› to add` | — | Sidebar second line | `Sync Now` |
| `Syncing ‹n› of ‹m›` (+ current file) | thin linear `ProgressView` | Sidebar, header, Activity | `Pause` · `Cancel` |
| `Synced ‹relative time›` | — | Sidebar second line | — |
| `Synced ‹relative time› · ‹n› failed` | — | Sidebar second line → opens Last sync | `Retry Failed` |
| `Folder not found on ‹DEVICE›` | — | Header | `Change Destination…` |
| `Not enough space — ‹x› GB needed, ‹y› GB free after removals` | — | Header, beside disabled Sync Now | — |
| `Can’t sync — “Lexxar” is not connected` | — | Plan, banner on the profile page | — |
| `“‹DEVICE›” was disconnected — ‹n› of ‹m› copied` | — | Window banner on the profile page (interrupted sync) | `Resume When Connected` |
| Plan: `Add ‹n› · Remove ‹n› · Skip ‹n› · ‹x› GB of ‹y› GB free`; `Remove 0 — Clean up is off` | — | Plan section | `Download` (per skipped track) |
| `Applies to the next sync` | — | Options while syncing | — |

### 15.9 Discover, Review, Albums, Folders, Reels

| Word (verbatim) | Where |
|---|---|
| Reels: `New` (nothing decided) · `Identified` (artist and title set) · `Done` (downloaded, added or marked by hand) | Reel list |
| Recommendations: `Because of “‹track›”` (group) · match `92 % match` (plain text, no capsule) | Discover |
| Review: `recommended` (in words in the comparison) · tabs `Duplicates · Conflicts · Albums · Resolved` · session choice `Unkept versions: ○ Stay in library, hidden from lists ○ Move to Trash` | Review |
| Review ▸ Albums: `Suggested: “‹album›” — ‹provider›, ‹n› % match` · `No album` (deliberate, confirmed) | Review |
| Albums: `Complete` · `Incomplete` (tracklist known, ≥ 1 track not in library) · `Compilations` · footer `‹n› tracks have no album · Show · Find Albums…` | Albums |
| Album edition picker: `‹Edition› edition ▾`; shelf `Other versions` | Album detail |
| Folders: `Managed by MLM` (small secondary label) · `‹n› files in this folder aren’t in the library · Import` | Folders |

---

## 16. Glossary

The only user-facing words for these concepts. UI-GROUNDTRUTH §1.5 carried forward with the DEC changes applied. (DEC-002, DEC-023, DEC-014, DEC-025, DEC-027, P4)

| ID | Rule |
|---|---|
| UC-GLOSS-01 | Use the term in the first column, never a word from the last column. A new concept gets a glossary row (via `IMP`) before it gets UI. |

| Term | Meaning | Never |
|---|---|---|
| **Library** | A collection of tracks, playlists and their settings, stored in one library file; also the sidebar section that holds All Tracks, Albums, Genres, Folders | Database, Profile, Workspace |
| **All Tracks** | Sidebar item / view with every track of the open library (DEC-002 — was `Library`) | Library (for the row), Songs |
| **Library file** | The `.mlibm` file holding a library's database, playlist covers and settings; states `Not found`, `Not connected` | Package, Bundle, Database file, Library folder |
| **Library folder** | The folder containing the music files (library root) | Audio library, Music root |
| **Track** | One song/recording entry | Song (in UI), Item, Entry, `Track #123` |
| **Album** | A release with a fixed disc/track order; a track can be on several | — |
| **Edition** / **Other versions** | Variants of an album (`Deluxe`, `2021 Remaster`); the shelf listing them | Variant (in UI) |
| **No album** | A deliberate empty album (mixes, live sets), confirmed in Review ▸ Albums | Unknown album, the source name as album |
| **Genres** | Sidebar view for browsing and cleaning genres (DEC-025) | Genre Workshop (retired as a UI word), Groove Studio |
| **Folders** | The library folder as laid out on disk | — |
| **Inbox** | Sidebar section with Discover and Review | Work |
| **Discover** | Recommendations + Reels | Swarm Intelligence |
| **Recommendation** | A suggested track held in Discover until kept | Neighbor, Swarm recommendation |
| **Keep** / **Dismiss** | Take a recommendation into the library / throw it away (to the Trash, undoable) | Delete (for a recommendation), thumbs |
| **Reels** | Identify music in saved videos | Reels Inbox |
| **Similar** | Track similarity: `Find Similar`, `Similar to ‹track›` | Groove, Groove Studio |
| **Review** | Duplicates · Conflicts · Albums · Resolved | Duplicate Review |
| **Duplicate group** | N versions of one recording | Track A / Track B pairs |
| **Metadata conflict** | Same recording, disagreeing fields | — |
| **Playlist** | Any playlist, local or linked | Synced playlist |
| **Playlist folder** | A sidebar folder grouping playlists (DEC-003) | Group, Pin |
| **Linked to ‹Source›** | Playlist/track originates from a source and can be refreshed | Synced, cloud icon, brand-coloured source label |
| **Refresh from ‹Source›** | Pull new tracks from the source of a linked playlist; `Refresh from Sources` = all (DEC-023) | Sync (for playlists), Update |
| **Sync** / **Sync profile** | Copy to a device or folder; a target + rules (DEC-023, DEC-027) | Sync to, Export (for sync) |
| **Device** / **Destination** | The disk / folder a sync profile writes to | Output folder |
| **Plan** | The computed sync changes `Add · Remove · Skip` (was "Preview" in UI-GROUNDTRUTH) | Preview (for the plan) |
| **Preview** | Listening to the selected track from its hot spot with Space (DEC-009/010) | Quick Look, Peek |
| **Queue** | Play order: `Now playing`, `Next`, `History` (DEC-006) | Up Next (as a destination) |
| **Info** | The trailing-column mode for the selection; command `Get Info` (DEC-007) | Inspector, More Info, Details panel (in UI) |
| **Activity** | The toolbar item, popover and window for background work (DEC-005) | Activity panel, Jobs, Tasks |
| **Operation** | One unit of background work in Activity | Job (in UI) |
| **Not downloaded** / **Download failed** / **File missing** / **Downloading…** | Track availability (§15.4) | Stream, Remote, `download failed` (lowercase), Missing (for not downloaded) |
| **Download** / **Retry Download** / **Download Again** | Fetch a not-downloaded track / retry a failed one / re-fetch a missing file | Download missing (for not-downloaded tracks) |
| **Locate…** / **Locate File…** | Point MLM at a file or library file that moved | Reveal issue |
| **Show in Finder** | Reveal in Finder | Reveal, Reveal in Finder, Open in Finder |
| **Remove from ‹Container›** / **Remove from Library…** | Undoable container removal / Trash, confirmed | Delete (for tracks) |
| **Backup** / **Restore** / **Rollback** | Saved copy of the library database + covers / replace with a backup / undo of the organized-path migration only | Snapshot, Export, Import |
| **Storage Location** | Settings tab showing where MLM keeps files | Storage, Data, Locations |
| **Background processing** | Concurrency preference: Conservative / Standard / Fast | Turbo, CPU-Leistung |
| **Managed by MLM** | App-owned folders/files | `00_Artists`, `01_SoundCloud` |
| **Credentials file** | File with client IDs; MLM shows its location, never its contents | env file, `.env`, Secrets |
| **Source** names | `SoundCloud`, `YouTube`, `Spotify`, `Apple Music`, `DAB`, `Last.fm`, `Qobuz` | upper-case `SOUNDCLOUD`, `LASTFM` |

| ID | Rule |
|---|---|
| UC-GLOSS-02 | Banned in every user-facing string: `Turbo`, `Swarm`, `Vector Gravity`, `Warp Embeddings`, `Drop-Fokus`, `Groove`, `Groove Studio`, `Neighbor`, `Genre Workshop`, `kept_higher_quality`, `flagged`, `fingerprint_dedup`, raw IDs (`Track #123`), lowercase enum names, `Stream`, `Reveal`, `Sync` for a playlist, `Sync to`, `Re-scan`, `Pin` / `Unpin`, `Token inaccessible`, `Loading Library...`, `Failed to Initialize`, `Playback unavailable`, `Error` as a title, `Are you sure?`, `This cannot be undone.`, the literals `unknown album` / `youtube` / `soundcloud likes` as values, any German string. (UI-GROUNDTRUTH §1.5, PATTERN-STATES.N04 retired words, §8.7 drift) |
| UC-GLOSS-03 | "drive", "volume", "mount", "database", "registry", "job", "token", "WAL" are not UI words; name the thing (`“Lexxar”`, `the library file`, `sign-in`). Exception: sentences that must explain a database failure (`The library database didn’t answer.`). (PATTERN-STATES.N15, G-LIB-FAILED) |

---

## 17. Copy rules

| ID | Rule |
|---|---|
| UC-COPY-01 | English only, every string, including logs shown in Activity, help text and accessibility labels. Any German string is a defect. No emoji. (UI-GROUNDTRUTH §1.7, `AUTHORING.md` rules for content) |
| UC-COPY-02 | **Title Case** for menu items, buttons, tab names, window/sheet titles that are command names, and undo action names, as macOS does (`Add to Playlist`, `Show in Finder`, `Retry All`, `Download All`, `Keep Recommended`). This replaces UI-GROUNDTRUTH §1.7 rule 2 (sentence case). Articles, short prepositions and conjunctions stay lowercase (`Add to Queue`, `Go to Current Track`, `Show in “Warm-up”`). (§4.4, `AUTHORING.md`, PATTERN-CM.N04) |
| UC-COPY-03 | **Sentence case** for messages, alerts' titles (questions), banner and status sentences, form labels and toggles (`Open the last library at launch`, `Write tag changes to files`), help text, empty states, scope and state words (`Not downloaded`, `Needs attention`), section headers (`Now playing`, `Needs attention`). (`AUTHORING.md`, PATTERN-STATES.N04) |
| UC-COPY-04 | Sentences end with a period; buttons, menu items, labels, state words, column headers and titles don't. Status-bar messages are sentence fragments without a final period unless they contain two sentences. *(punctuation of status-bar fragments unspecified in B1 — convention set here)* |
| UC-COPY-05 | `…` (U+2026, never three dots) only on a command that asks for more before it acts: opens a sheet, a file panel, a confirmation alert or a settings window (`Import M3U…`, `Remove from Library…`, `Settings…`, `Library Settings…`). Commands that act at once have none (`Find Duplicates`, `Back Up Now`, `Rename` inline). Progress phrases end in `…` (`Opening “Main Library”…`, `Checking link…`, `Downloading…`). (PATTERN-CM.N04, M-* items) |
| UC-COPY-06 | Names of user things are in typographic double quotes `“…”` (U+201C/U+201D): libraries, playlists, folders, sync profiles, devices, drives, tracks, files (`“Lexxar”`, `“Warm-up”`, `“IMG_4471.mov”`). Apostrophes are `’` (U+2019): `Can’t`, `couldn’t`, `isn’t`. Never straight `"` or `'` in UI strings. (mockup copy throughout) *(character choice unspecified as a rule in B1 — convention set here)* |
| UC-COPY-07 | `Show in Finder`, never "Reveal". `Get Info`, never "More Info". `Refresh from ‹Source›`, never "Sync" for a playlist. `Add to Sync Profile`, never "Sync to". (DEC-023, PATTERN-CM.N04) |
| UC-COPY-08 | Separators: `·` (U+00B7 with spaces) between facts and between a statement and its actions (`44 tracks · 2 h 51 min`, `Incomplete · 9 failed · Retry All · Show`); `—` (U+2014 with spaces) between what happened and its consequence or cause (`Removed 9 tracks from “Warm-up” — the files stay in the library`, `Can’t play — file missing`); `–` (U+2013) for ranges (`bpm: 120–128`); `▸` for paths in prose (`Settings ▸ Sources`). (mockup copy) |
| UC-COPY-09 | Numbers: `Text(n, format: .number)` — locale thousands separators (`12,935`); counts with their noun and correct plural (`1 track`, `2 tracks`) via automatic grammar agreement or String Catalog plural variants, never `track(s)`; progress `‹n› of ‹m›`; percentages `62 %` from a `.percent` format; no symbols for counts (`9 failed`, not `⚠9`). (§4.9 Huge data, UI-GROUNDTRUTH §1.7.3) |
| UC-COPY-10 | Times and durations: track time `m:ss` (`h:mm:ss` from one hour); totals < 90 min `52 min`, < 24 h `2 h 51 min`, ≥ 24 h `38 days`; elapsed / duration in the player `1:12 / 5:48`. Sizes with `ByteCountFormatStyle` (`412 GB`, `124.8 MB`). Dates and times with `Date.FormatStyle` in the user's locale (abbreviated month, `4 Oct 2026, 08:57` style); relative times with `Date.RelativeFormatStyle` (`2 hours ago`, `yesterday`). Never hand-built date strings. (app.js `fmtTime`/`fmtDur`, §7.2) *(exact formatter choice unspecified in B1 — convention set here)* |
| UC-COPY-11 | Error anatomy: a sentence that says what couldn't be done · the cause in plain words (and what is safe: `Your music and your library file are not affected.`) · **one** action that helps (`Try Again`, `Reconnect`, `Open Settings ▸ Sources`, `Locate…`) · a `Details` disclosure with the raw text and a way to its log lines (`Show Logs` / `Show in Logs`). No error codes in the sentence, no "Error" title, no OK-only dead ends. (§4.9, PATTERN-STATES.N15–N17) |
| UC-COPY-12 | Confirmations state the consequence in numbers, not the action (UC-SHEET-13). Status messages say what happened plus what was skipped (`· 1 was already in it`). (DEC-016, PATTERN-DND.N04) |
| UC-COPY-13 | Disabled controls explain themselves: `.help(reason)` on every disabled button/menu item, and next to primary buttons the reason is also written (`Connect “IPOD CLASSIC” to sync.`). (DEC-014, PATTERN-STATES.N19, `sync.html` Sync Now) |
| UC-COPY-14 | Say "you" sparingly and never "please", "oops", "sorry", "simply", "just". MLM speaks about itself as `MLM`. (mockup copy) *(unspecified in B1 — convention set here)* |
| UC-COPY-15 | Implementation jargon never reaches the UI (enum cases, table names, `LUFS` without explanation, `Temperature 0.0–1.0`); use the words the design chose (`Close · Balanced · Wide`, `Normalize loudness`). (UI-GROUNDTRUTH §1.1.3, `genres.html` suggestion controls, ST-PLAYBACK.E03) |

---

## 18. Empty, loading, error, offline

| ID | Rule |
|---|---|
| UC-EMPTY-01 | **Empty (first use):** `ContentUnavailableView { Label } description: { Text } actions: { … }` with one sentence and the one action that fills the view; drop targets stay active on it. Never a blank pane. Catalogue: All Tracks `No tracks yet` / `Import music from a folder, or import a playlist from SoundCloud, YouTube or Spotify. You can also drop files here.` · `Import Files or Folder…` · `Import Playlist from Source…`; Playlist `This playlist is empty. Drag tracks here or use Add to Playlist.`; Review ▸ Duplicates `No duplicates to review.` · `Run Scan`; Discover `No recommendations waiting.` · `Find Recommendations…`; Sync `No sync profiles yet.` · `New Sync Profile…`; Folders `No library folder` · `Open Settings ▸ Library`; Info `No selection`. (§4.9, PATTERN-STATES.N10 table, V-LIB.E22) |
| UC-EMPTY-02 | **Empty (filtered):** `ContentUnavailableView.search(text:)` naming the query, plus `Clear Filters` (and `Search the Library` / `Search Online` for search). The scope bar and its counts stay visible. It never looks like an empty library. (§4.9, PATTERN-STATES.N11) |
| UC-EMPTY-03 | Lists that keep their shape when empty (the Queue's three sections, Activity's sections) show one sentence inside each empty section instead of a full-pane view. (`queue.html` V-QUEUE.E04) |
| UC-EMPTY-04 | **Loading:** content stays. Only the first load of a view shows `.redacted(reason: .placeholder)` rows/cards under the real header and scope bar; later refreshes update in place with the status-bar spinner after 300 ms (UC-STATUS-06). Countable work shows determinate progress with the same numbers as Activity. Never a full-pane spinner, never an anonymous spinner. (§4.9, PATTERN-STATES.N12–N14) |
| UC-EMPTY-05 | **Error (whole view):** `ContentUnavailableView` with the sentence + cause + what is safe, actions `Try Again` and `Show Logs`, and `DisclosureGroup("Details")` with the raw text. **Error of the shown thing:** one line in its header (UC-SHEET-21). **Error of an action:** status bar (UC-SHEET-19). (§4.9, PATTERN-STATES.N15–N17) |
| UC-EMPTY-06 | **Offline (drive not connected):** one banner per window (UC-LAYOUT-02, §15.2) in every view that lists tracks; footer two words; local rows dimmed with an empty Status; file actions disabled with the reason as help text and as the menu header line; everything that only touches the catalogue works (browse, search, edit tags — written later, build playlists, queue downloads, sync-profile content). When the drive returns: banner goes, rows return in place, status bar `“Lexxar” connected.` with `Resume` only if something was playing; waiting work starts by itself; nothing auto-plays. (DEC-014, P6, F-18) |
| UC-EMPTY-07 | Screen-specific offline additions are one line under the banner that names only the extra consequence for this screen (Discover: Dismiss needs the file; Albums: Play/Shuffle disabled). (`discover.html` drive-off hint, `albums.html` offline line) |
| UC-EMPTY-08 | **Huge data is the default:** 12,935 tracks, 8,020 album rows, 60+ playlists. Counts with thousands separators in the status bar and scope bar; grids lazy; no view requires scrolling to learn its state (totals, failures, progress live in the header, scope bar or status bar). (§4.9, PATTERN-STATES.N21) |
| UC-EMPTY-09 | **Launch states** (no library, opening, failed, invalid, copy, adoption) are in the main window per §15.1, never a separate launcher window; the Activity item and window work in all of them. (DEC-031, `launch.html`) |

---

## 19. Toolkit map

| ID | Tool | Verdict | Where / why |
|---|---|---|---|
| UC-KIT-01 | `NavigationSplitView` (2 columns) + `NavigationStack` in the detail | Use | Shell; pushed details with Back/Forward |
| UC-KIT-02 | `List(selection:)` `.listStyle(.sidebar)`, `Section(isExpanded:)`, `DisclosureGroup`, `.badge`, `.onMove`, `.dropDestination` | Use | Sidebar incl. playlist folders and drop targets |
| UC-KIT-03 | `Table` + `TableColumnCustomization` + `KeyPathComparator`; `Table(_:children:)` / `DisclosureTableRow` | Use | Every track list; Folders |
| UC-KIT-04 | `LazyVGrid` in `ScrollView` | Use | Albums, All Playlists, Genres grids (opaque content) |
| UC-KIT-05 | `.inspector(isPresented:)` + `.inspectorColumnWidth` | Use | Info / Queue |
| UC-KIT-06 | `Form` `.formStyle(.grouped)`, `LabeledContent`, `GroupBox` | Use | Info, Settings, sheets, sync options |
| UC-KIT-07 | `.searchable(text:tokens:…)`, `.searchScopes(_:activation:)`, `.searchSuggestions` | Use | Search |
| UC-KIT-08 | `.toolbar(id:)`, `ToolbarItem(placement:)`, `ToolbarSpacer`, `.sharedBackgroundVisibility` | Use | Shell toolbar (customizable) |
| UC-KIT-09 | `.commands`, `CommandMenu`, `CommandGroup`, `FocusedValue`, `SidebarCommands`, `ToolbarCommands`, `InspectorCommands` | Use | Menu bar |
| UC-KIT-10 | `contextMenu(forSelectionType:menu:primaryAction:)` | Use | All tables and grids |
| UC-KIT-11 | `.onKeyPress(.space)` on focused tables + `.focusable` | Use | Space preview |
| UC-KIT-12 | `Transferable`, `.draggable`, `.dropDestination` | Use | §11 |
| UC-KIT-13 | `UndoManager` (`@Environment(\.undoManager)`) | Use | §13 |
| UC-KIT-14 | `ContentUnavailableView` (+ `.search(text:)`) | Use | Every empty / no-results / unavailable state |
| UC-KIT-15 | `ProgressView` (linear / circular, `.controlSize(.small)`), `Gauge` (`.gaugeStyle(.accessoryLinearCapacity)`) | Use | Activity rows, device capacity, import progress |
| UC-KIT-16 | Swift Charts | Use, narrowly | Storage Location breakdown, sync size vs free space, BPM/energy histogram in a genre detail. Never in tables |
| UC-KIT-17 | `Canvas` | Use | Waveform (Info ▸ Audio, preview scrubber) |
| UC-KIT-18 | SF Symbols + `.symbolEffect`, `.symbolVariant`, `.contentTransition(.symbolEffect(.replace))` | Use | Play/pause morph, now-playing, Activity completion (UC-MOTION-02) |
| UC-KIT-19 | `ShareLink` | Use | Share a track file (the source is never shared) |
| UC-KIT-20 | `Settings` scene + `TabView`, `openSettings` + tab binding | Use | Settings |
| UC-KIT-21 | `Window(id: "activity")`, `openWindow` | Use | Activity window |
| UC-KIT-22 | `.fileImporter`, `.fileExporter`, `.fileDialogMessage` | Use | Every file/folder choice |
| UC-KIT-23 | `.confirmationDialog` / `.alert` with `ButtonRole` | Use | All confirmations |
| UC-KIT-24 | `.navigationTitle` / `.navigationSubtitle` | Use | UC-WIN-06 |
| UC-KIT-25 | Now Playing / `MPRemoteCommandCenter` | Keep | Media keys = Play/Pause, Next, Previous |
| UC-KIT-26 | Dock menu (`applicationDockMenu(_:)`) | Use, small | UC-DOCK-01 |
| UC-KIT-27 | TipKit (`.popoverTip`) | Use, three tips only | `Press Space to preview`, `Drag tracks onto a playlist`, `Edit several tracks at once`; one at a time; never again after dismissal or use; none while a sheet is open or a preview plays; reset via Help ▸ Show Tips Again / Settings ▸ Advanced (V-MAIN-LAYOUT.N01–N03) |
| UC-KIT-28 | Liquid Glass: `glassEffect(_:in:)`, `GlassEffectContainer`, `Glass.interactive`, `glassEffectID`, `backgroundExtensionEffect()`, `scrollEdgeEffectStyle(_:for:)`, `ToolbarSpacer` | Use, unconditionally, only per §5 | No `#available`, no helper (§10 Q10) |
| UC-KIT-29 | System notifications (`UNUserNotificationCenter`) | Use, opt-in | Jobs that finish while MLM is in the background; off by default |
| UC-KIT-30 | App Intents / Shortcuts, Spotlight (`CSSearchableItem`) | Later | Not in B3 |
| UC-KIT-31 | Quick Look (`QLPreviewPanel`, `.quickLookPreview`) | Not used | Floating panel; the behaviour is copied, the panel is not |
| UC-KIT-32 | `MenuBarExtra` mini player | Not used | Second player surface |
| UC-KIT-33 | `TabView` in the main window | Not used | Sidebar is the navigation; tabs only in Settings and as segmented scopes |
| UC-KIT-34 | `.windowStyle(.hiddenTitleBar)`, custom chrome, floating overlays, toasts | **Banned** | L2, ROADMAP §6.2, DEC-016 |
| UC-KIT-35 | `#available` glass checks, `MLMGlass`, `.regularMaterial` / `.bar` as glass fallback, `glassBackgroundEffect` (visionOS), custom `presentationBackground` | **Banned** | §10 Q10, §5 |
| UC-KIT-36 | `NSOpenPanel` / `NSSavePanel` by hand, AppKit settings window, `NSEvent` key monitors for app shortcuts, `HSplitView` for the inspector | **Banned** | §6, PATTERN-SHEETS.N08, K-SEARCH-CMDF, DEC-007 |
| UC-KIT-37 | AppKit is allowed only where SwiftUI has no equivalent: the read-only selectable log `NSTextView` (via `NSViewRepresentable`), `applicationDockMenu`, `applicationShouldTerminate`, `NSWorkspace` mount/unmount notifications, `ASWebAuthenticationSession`. | Use, narrowly | `activity.html` P-ACTIVITY-LOGS.E10, M-DOCK, M-APP.E07 |

(§6, corrected for macOS 27 by §10 Q10)

---

## 20. Accessibility

| ID | Rule |
|---|---|
| UC-A11Y-01 | Everything is operable from the keyboard alone: every command has a menu item (UC-MENU-02) or a documented key; Tab moves focus between sidebar, content and trailing column (with Full Keyboard Access also to buttons); grids and the sidebar support arrow keys and type-to-select. (P2, PATTERN-MENUS.N07) |
| UC-A11Y-02 | Every icon-only control has an `.accessibilityLabel` naming its action (`Previous`, `Play`, `Pause`, `Next`, `Volume`, `Show Queue`, `Activity`, `Show Info`, `Add`, `More`), and a `.help` tooltip with its shortcut where it has one (`Show Info ⌘I`, `Show Queue ⌥⌘U`, `Hide Sidebar ⌃⌘S`). (§6, app.js toolbar titles) |
| UC-A11Y-03 | The Activity item's accessibility value is its text (`Downloading 12 of 44, 9 failed`); progress views expose their value. (DEC-044) |
| UC-A11Y-04 | Never colour-only meaning: every state is a word (UC-COLOR-06); a tinted symbol is decoration of a word; Energy/Dance expose the number; the drop ring is accompanied by the cursor and the status-bar result. (DEC-043, P4) |
| UC-A11Y-05 | Status-bar messages and the drive banner are announced to VoiceOver (`AccessibilityNotification.Announcement`) when they appear. *(unspecified in B1 — convention set here)* |
| UC-A11Y-06 | Honour Reduce Transparency (UC-GLASS-13/14), Reduce Motion (UC-MOTION-03), Increase Contrast and Dynamic Type sizes the system provides on macOS — never fixed font sizes (UC-TYPE-01). |
| UC-A11Y-07 | Rows expose title, artist and their Status word to VoiceOver; the now-playing row adds `Now playing`. Dimmed rows add the reason (`Not reachable — “Lexxar” is not connected`). *(unspecified in B1 — convention set here)* |

---

## 21. Standing engineering constraints

| ID | Rule |
|---|---|
| UC-ENG-01 | **Foreign keys stay disabled.** `config.foreignKeysEnabled = false` is deliberate and test-locked (`foreignKeysRemainDisabledForSharedSchemaCompatibility()`, `inMemoryDatabaseDoesNotEnableForeignKeys()`). Implement cascades manually. (ROADMAP §6.1) |
| UC-ENG-02 | **Never inspect a live DB with `sqlite3 -readonly`** (WAL mode; it silently returns a stale snapshot). Use a plain connection with SELECT-only statements — and in agent work, never touch the live DB at all (UC-ENG-06). (ROADMAP §6.3) |
| UC-ENG-03 | **`swift test` prints two runner summaries** (Swift Testing and XCTest). Verify new suites by name in the output, not by the total count. (ROADMAP §6.4) |
| UC-ENG-04 | **Verify by `swift build` + `swift test` only.** No app launch, no screenshots, no AppleScript / UI scripting in agent work. Oliver does the visual check after each wave. (ROADMAP §6.5, B3-PLAN §1) |
| UC-ENG-05 | **Never read** `~/Library/Application Support/MLM/.env` or anything under `~/Library/Application Support/com.musiclibrary.app/`. |
| UC-ENG-06 | **Never touch the live library or `/Volumes/Lexxar`** (no reads, writes, scans or moves). Tests use temporary databases and temporary library folders/files only. |
| UC-ENG-07 | **Every schema change is a new numbered GRDB migration**; never edit an existing migration. Migration numbers are assigned by the coordinator in `B3-PLAN.md` §3; register only your own number. (B3-PLAN §1, §3) |
| UC-ENG-08 | **Pre-migration backups must keep working**: a new migration must not bypass or break the automatic backup taken before migrations run. (ROADMAP A2) |
| UC-ENG-09 | **Commits:** `feat(scope): …` / `fix(scope): …` (also `docs(scope):`, `test(scope):`, `refactor(scope):`), **no `Co-Authored-By` lines**. Work on branches off `redesign/b3` (`b3/<package-id>`); never commit to `main`; never move or recreate tag `v0.9`. |
| UC-ENG-10 | **Fix — don't port — known logic bugs** on surfaces you touch (inventory `PP-*` items, `LOGIC-*`), and say so in the commit message; never reproduce an old bug in the new UI for "parity". |
| UC-ENG-11 | Shared files (`MLM/App/MLMApp.swift`, the navigation model, `DependencyContainer.swift`, `DatabaseManager.swift`, `Notifications.swift`) are edited only by their owning package or the coordinator. (B3-PLAN §1) |
| UC-ENG-12 | Native toolbar stays; no custom window chrome, no floating player overlays. (ROADMAP §6.2) |
| UC-ENG-13 | A half-migrated surface stays behind its old entry point; the branch builds and the app stays usable after every merge. (B3-PLAN §1) |

---

## 22. Never — the review checklist

A change that does any of these fails review. Cite the rule.

| # | Never | Rule |
|---|---|---|
| N1 | Hex colours, `Color(red:…)`, custom palettes, asset colours (except the 4 brand dots) | UC-COLOR-02/07 |
| N2 | `mlm*` colour tokens in new or rebuilt code | UC-COLOR-03 |
| N3 | Status shown by colour alone; blue "Running" / green "Completed" text; coloured status capsules or chips; sidebar dots | UC-COLOR-05/06, UC-SIDE-04 |
| N4 | Fixed point sizes or custom fonts | UC-TYPE-01 |
| N5 | `#available` / `#unavailable` around glass, an `MLMGlass` helper, `.regularMaterial` / `.bar` as glass fallback, `glassBackgroundEffect` | UC-GLASS-10/11 |
| N6 | Glass on content (tables, lists, cards, headers, banners, status bar, forms) or glass inside glass | UC-GLASS-07/08 |
| N7 | A custom glass surface other than the selection bar; a custom `presentationBackground` | UC-GLASS-05/06 |
| N8 | `.hiddenTitleBar`, custom chrome, a floating player, a `MenuBarExtra` player, a second main window, an import window | UC-WIN-01/08, UC-KIT-32/34 |
| N9 | An AppKit settings window; a workspace or job list inside Settings | UC-WIN-03, UC-SURF-11 |
| N10 | Section-specific toolbar items, or a toolbar that changes shape | UC-TB-01/02 |
| N11 | Toasts, floating panels, overlays or banners to confirm an action | UC-STATUS-01 |
| N12 | Full-pane spinners; tables that blink to a spinner on refresh | UC-TABLE-09, UC-EMPTY-04 |
| N13 | Per-row (per-cell, per-scroll) disk probes such as `fileExists` | UC-TABLE-20 |
| N14 | Space = Play/Pause, a Space shortcut on Playback ▸ Play/Pause, a "Space bar" setting, ⌥Space | UC-KEY-01/37, UC-WIN-04 |
| N15 | Double-click / Return opening Info or anything else besides the primary action; Info or Queue opening by itself | UC-PRIM, UC-TRAIL-02 |
| N16 | Adding, playing or finishing something that navigates or steals focus | UC-PRIN-03, UC-CM-09, UC-JOB-12 |
| N17 | `File missing` because the drive is not connected; per-row red chips for a window-level state | UC-TABLE-12, UC-STATE-01 |
| N18 | Dimming `Download failed` or `Not downloaded` rows | UC-TABLE-10 |
| N19 | Showing `unknown album` / source names as album values | UC-TABLE-11 |
| N20 | Icon-only critical state or icon-only control without an accessibility label | UC-A11Y-02/04 |
| N21 | German strings, emoji, banned or retired words, synonyms for glossary terms | UC-COPY-01, UC-GLOSS-02 |
| N22 | Sentence-case menu items/buttons, `...` instead of `…`, straight quotes in UI copy, ellipsis on a command that acts at once | UC-COPY-02/05/06 |
| N23 | Dead menu items (enabled but doing nothing); hidden menu-bar items; disabled placeholders in context menus | UC-MENU-02, UC-CM-01 |
| N24 | A context menu in another group order, a count in every label, `Remove from Library` in the Queue or a sync profile, a destructive item that isn't last | UC-CM-01/04/07 |
| N25 | A confirmation for something undoable (except UC-UNDO-05); an undoable action that doesn't register undo; an irreversible action without a consequence-stating alert | UC-UNDO-04/05 |
| N26 | `OK` for a choice; a destructive default button; "Are you sure?"; a second alert on top of a sheet | UC-SHEET-14/15/12/05 |
| N27 | A background job > ~2 s without an Activity operation; an operation without a persisted result; a `Cancel` that doesn't cancel | UC-JOB-01/02/03 |
| N28 | Hand-rolled `NSOpenPanel`; a file panel without a message line | UC-SHEET-24 |
| N29 | New shortcuts, surfaces, state words or glass without an `IMP` entry | UC-PREC-04 |
| N30 | Editing an existing migration; enabling foreign keys; reading `.env`; touching `/Volumes/Lexxar` or the live library; launching the app or taking screenshots; `Co-Authored-By` lines; commits to `main`; moving `v0.9` | §21 |

---

## 23. Resolved contradictions in the packet

Where the sources disagree, the resolution here applies (UC-PREC-01). IDs are referenced from the rules above.

| # | Contradiction | Resolution |
|---|---|---|
| C1 | Space falls back to Play/Pause and has a setting / ⌥Space: THOUGHTS §4.2, §7.8, §7.16, DEC-009; `player.html` K-LIB-SPACE + P-PREVIEW.N06; `patterns-menus-shortcuts.html` M-PLAYBACK.E01 (`Pause Space`), keyboard map Space row, K-LIB-SPACE/rules ("Nothing selected … Play/Pause", "Always Play/Pause"), K-LIB-SPACE verdict; `settings.html` ST-GENERAL.N01 and its text "With nothing selected, Space is Play/Pause either way", ST-PLAYBACK "Space bar" pointer | §10 Q1: preview only, no setting, no Space on Play/Pause (UC-KEY-01/37, UC-WIN-04) |
| C2 | macOS 15 fallbacks: THOUGHTS §5 table column and "One isolation point" (`MLMGlass`); `AUTHORING.md` (`say the macOS 26 API and the macOS 15 fallback`); app.js annotations (P-SELBAR "macOS 15: .regularMaterial", P-TOOLBAR ".bar on 15", P-PLAYER "on macOS 26"); `mlm.css` comments; `playlists.html` cover note "On macOS 26 …"; LIQUID-GLASS-PLAN §1.1 (keep macOS 15) | §10 Q10: macOS 27, unconditional APIs (UC-GLASS-10/11) |
| C3 | Activity variant B (`activity.html` P-ACTIVITY/B) | Dropped (§10 Q2) |
| C4 | THOUGHTS §5 lists `.glassEffect(.regular.interactive(), in: .capsule)` on the selection bar **and** `.buttonStyle(.glass)`; nesting them is glass on glass, which §5 "Hierarchy" forbids | Capsule carries the glass; its buttons are `.borderless` (UC-GLASS-05/08). *(convention set here)* |
| C5 | Default name of a new playlist: `Untitled Playlist` (`playlists.html` V-PL New Playlist, `patterns-sheets-alerts.html` S-SEL-NEWPLAYLIST / S-PL-NEWPLAYLIST) vs `New Playlist` (`patterns-dnd.html` PATTERN-DND.N04, D-LIB-SPRING, D-LIB-TO-SIDEBAR-NEWPL; `shell.html` P-SIDEBAR.N11) | `Untitled Playlist` (numbered `Untitled Playlist 2` when taken); drops of an album / folder / genre use its name (UC-DND matrix). *(convention set here)* |
| C6 | Esc in the name field of a brand-new playlist: keeps the default name, ⌘Z removes it (`playlists.html` V-PL New Playlist, `patterns-sheets-alerts.html` S-PL-NEWPLAYLIST, S-SEL-NEWPLAYLIST) vs discards the playlist (`shell.html` inline rename text, `patterns-menus-shortcuts.html` K-PL-NEWPOPOVER-ESC, PATTERN-MENUS.N06) | Esc keeps `Untitled Playlist` (Finder's new-folder behaviour; the text-field rule "revert to the value before the edit"); ⌘Z removes it. *(convention set here)* |
| C7 | THOUGHTS §3.2 lists "new playlist name" as a popover example; the patterns make new playlists inline (S-PL-NEWPLAYLIST) | Inline (UC-SHEET-10) |
| C8 | Popovers have "no Cancel button" (PATTERN-SHEETS.N01) vs Save Queue as Playlist popover with `Cancel` (P-QUEUE.N15); its button is `Save` (sheets page) vs `Create` (`queue.html`) | Keep `Cancel` + `Create` on this one naming popover (UC-SHEET-10). *(convention set here)* |
| C9 | "missing" reserved for `File missing` (`patterns-context-menus.html` removed-items table, DEC-011) vs `Download Missing` / `Download 2 Missing` / `Download n missing` (CM-SIDEBAR-PINNED.N05, CM-PL-CARD.E06, V-PLD.E07, CM-ALB-CARD.N08, CM-ALBD-MORE.N05, THOUGHTS §7.6) | `Download ‹n› Tracks` (container menus), `Download All` (status sentence), `Download Not-Downloaded Tracks` (profile rows). *(convention set here)* |
| C10 | Delete on the Liked playlist: absent (`playlists.html` CM-PL-CARD note) vs offered with the consequence in the alert (`patterns-context-menus.html` CM-SIDEBAR-PINNED.E06) | Offered, confirmed by A-PL-DELETE (later, more specific catalogue; P8). *(convention set here)* |
| C11 | Window subtitle = library name + count (THOUGHTS §6, `patterns-states.html` G-LIB-CURRENT) vs name only (`shell.html` W-MAIN.E01) | Name + count (UC-WIN-06) |
| C12 | Status bar selection text `14 selected · 52 min` (THOUGHTS §7.2) vs `n of N selected · …` (app.js) | THOUGHTS (UC-STATUS-03) |
| C13 | `Synced 2 h ago` (THOUGHTS §7.1, `shell.html` P-SIDEBAR.N08) vs `Synced 2 hours ago` (`patterns-states.html` placement table) | System relative format → `Synced 2 hours ago` (UC-COPY-10). *(convention set here)* |
| C14 | Activity item with several jobs: oldest job + `+n` (`shell.html` Activity item, `patterns-states.html` G-BG-ACTIVE) vs priority by kind download/import → sync → scan → analysis (`activity.html` P-ACTIVITY.E05) | Oldest running operation + `+n` (two sources against one) (UC-JOB-04). *(convention set here)* |
| C15 | Recommendation primary action: "Return = recommended action" (THOUGHTS §4.3 row "Review group / recommendation / reel") vs "↩ / double-click: play it as a preview-in-place; K keeps" (PATTERN-MENUS.N04) | Return / double-click plays (P2); K keeps; ⌫ dismisses (UC-PRIM-10). *(convention set here)* |
| C16 | Reel: "Space plays the video" (PATTERN-MENUS.N04) vs §10 Q1 | Space previews the selected video (start/stop), never Play/Pause of the main player (UC-KEY-01) |
| C17 | Drive banner: `… queue downloads; playback and file actions are paused.` (THOUGHTS §4.9) vs `… queue downloads. Playback and file actions are paused.` (all mockups) | THOUGHTS wording; `Try Again` button from the mockups (§15.2) |
| C18 | `New Sync Profile…` in the Library menu and `Library ▸ Sync “iPod Classic” Now` (`sync.html` empty-state and Sync Now notes) vs File ▸ New Sync Profile… and no Sync Now item (`patterns-menus-shortcuts.html` M-FILE.N03, M-LIBRARY) | The menu catalogue (UC-MENU-05); Sync Now lives in the profile header and context menu |
| C19 | Folder row: primary action expand/collapse (THOUGHTS §4.3) vs "the primary action is always the first context-menu item" with `Open ⌘↓` first (PATTERN-MENUS.N04, CM-FOLD-TREE) | Expand/collapse; documented exception (UC-PRIM-06) |
| C20 | `Find Duplicates…` / `Find Albums…` carry `…` but start an operation at once (M-LIBRARY.N03/N04) vs the ellipsis rule (PATTERN-CM.N04) | No ellipsis (UC-COPY-05, UC-MENU-05) |
| C21 | `Retry all` (THOUGHTS §4.8, §7.6) vs `Retry All` (patterns); `Keep all — not duplicates` (§7.13) vs `Keep All — Not Duplicates` (CM-REV-GROUP) | Title Case on buttons and menu items (UC-COPY-02) |
| C22 | Dock menu header `Not Playing` (M-DOCK.N01) vs player idle `Not playing` (`player.html` E06) | `Not playing` (UC-DOCK-01) |
| C23 | Undoable bulk decisions confirmed by an alert (A-REV-APPLYALL, A-REV-ALBBULK) vs "if it can be undone it is not asked" (PATTERN-SHEETS.N06) | Explicit exceptions (UC-UNDO-05) |
| C24 | `Songs you downloaded from it stay in the library.` (A-REELS-DELETE) vs "MLM says track everywhere" (DEC-002) | `Tracks you downloaded from it stay in the library.`; button `Delete Reel` (verb + object, UC-SHEET-14) |
| C25 | `patterns-context-menus.html` PATTERN-CM.N04 says "THOUGHTS §4.4 says sentence case" — §4.4 now says Title Case | No conflict left: Title Case |
| C26 | UI-GROUNDTRUTH vs B1: sentence-case buttons (§1.7.2), `mlm*` tokens and blue/green status colours (§1.2), 36 pt rows and 320–480 pt inspector (§1.4), `Preview` = sync plan (§1.5), 60 % dimming of failed rows (§1.6), `Library` sidebar item (§1.5) | B1 / this file (UC-PREC-06) |
| C27 | Status-bar message lifetime 7 s in app.js vs 8 s (THOUGHTS §4.6, PATTERN-SHEETS.N06) | 8 s (UC-STATUS-04) |

---

## 24. Set by this document

Rules the B1 packet does not specify, decided here for consistency with the principles. The coordinator reviews these; changing one is an `IMP` entry.

| # | Item | Rule |
|---|---|---|
| S1 | Mapping of roles to system text styles | UC-TYPE-01 table |
| S2 | Spacing scale 4 · 6 · 8 · 12 · 16 · 20 pt and the named `Spacing` enum | UC-SPACE-01 |
| S3 | Corner radii 4 / 7 / 9 pt | UC-SPACE-04 |
| S4 | Brand dot colours = existing `Colors.swift` values in one `SourceBrand` type; non-brand sources `.tertiary` | UC-COLOR-07 |
| S5 | Selection-bar buttons `.borderless` inside the glass capsule; `.buttonStyle(.glass)` unused in B1 | UC-GLASS-05/08, C4 |
| S6 | Reduce Transparency fallback of the selection bar (opaque `windowBackgroundColor` capsule + separator stroke) | UC-GLASS-14 |
| S7 | Now-playing glyph `speaker.wave.2.fill` + title in `.tint` | UC-TABLE-16 |
| S8 | Placeholder thumbnail `music.note` on `.quaternary` | UC-TABLE-17 |
| S9 | Scope persistence via `@SceneStorage` | UC-SCOPE-05 |
| S10 | Status-bar default text for grids (`‹n› albums`, `‹shown› of ‹total›`) | UC-STATUS-02 |
| S11 | Status-bar message replaced at once by a newer one; at most two buttons | UC-STATUS-04 |
| S12 | Selection bar not shown outside track lists | UC-SELBAR-05 |
| S13 | Space / Return not bound as menu key equivalents; showing them next to Track ▸ Play / Preview optional | UC-KEY-37 |
| S14 | Undo action names beyond `Add to “Warm-up”` | UC-UNDO-07 |
| S15 | Default new-playlist name `Untitled Playlist`; Esc keeps it | C5, C6 |
| S16 | Save Queue as Playlist popover keeps `Cancel` + `Create` | C8 |
| S17 | `Download ‹n› Tracks` instead of `Download Missing` | C9 |
| S18 | Delete Playlist offered for the Liked playlist | C10 |
| S19 | Relative-time format `Synced 2 hours ago` | C13, UC-COPY-10 |
| S20 | Activity item shows the oldest running operation | C14 |
| S21 | Return on a recommendation plays it | C15 |
| S22 | Typographic quotes / apostrophes / dash and separator characters | UC-COPY-06/08 |
| S23 | Status-bar fragments without final period | UC-COPY-04 |
| S24 | Duration, size, date formatters (`m:ss`, `52 min` / `2 h 51 min` / `38 days`, `ByteCountFormatStyle`, `Date.FormatStyle`, `Date.RelativeFormatStyle`) | UC-COPY-10 |
| S25 | Tone: no "please / sorry / oops / simply / just" | UC-COPY-14 |
| S26 | VoiceOver announcements for status-bar messages and the drive banner; row accessibility content | UC-A11Y-05/07 |
| S27 | Commit prefixes `docs/test/refactor` allowed besides `feat/fix` | UC-ENG-09 |
| S28 | `Find Duplicates` / `Find Albums` without ellipsis | C20 |
| S29 | A-REELS-DELETE wording `Tracks you downloaded …`, button `Delete Reel` | C24 |
