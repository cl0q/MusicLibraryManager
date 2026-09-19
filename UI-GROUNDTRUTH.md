# MLM for macOS — UI Ground Truth

**Status:** Binding design reference for the native macOS app (`macos-app/MLM`).
**Scope:** Native macOS app only. Web, mobile, server, and legacy Tauri UI are out of scope.
**Language of this document:** English. **Language of all UI strings:** English only.

> **How to use this document**
>
> 1. This file is the **ground truth** for what the app should look like and how it should behave. When code and this document disagree, the code is wrong (or the document must be changed deliberately, in a commit that says why).
> 2. Every screen follows the same schema: **Purpose → Wireframe → Anatomy → States → Interactions → Edge Cases → Changes vs. current**.
> 3. The **"Changes vs. current"** boxes reference real code locations (file + line, accurate as of August 2026) so each box doubles as an implementation backlog item. Line numbers drift — treat them as pointers, not gospel.
> 4. Nothing in this document invents new features. It re-organizes, renames, and clarifies what already exists.

---

# Part 1 — Foundations

## 1.1 Product Principles

These five principles settle every design argument not explicitly covered below.

1. **Critical states are always text, never icon-only.** Download failures, missing files, placeholder metadata, source disconnects, duplicate markings: each gets words (and usually an action). An icon may accompany text; it may never replace it. (Today: cloud badge with no label, `PlaylistCard.swift:428–439`.)
2. **Automation is visible, controllable, reversible.** Anything the app does on its own — creating folders, marking duplicates, transcoding, re-linking sources — is shown somewhere, can be paused or configured, and can be undone. No silent mutations.
3. **Dense is welcome, confusing is not.** Tables may be dense. Every column header, badge, and row state must still be self-explanatory to a first-time user. Jargon from the implementation never reaches the UI.
4. **One meaning per word, one word per meaning.** The glossary in §1.5 is exhaustive for user-facing concepts. If a feature needs a new word, it is added there first.
5. **Native macOS, not a port.** Standard sidebar, tables, toolbars, inspectors, context menus, keyboard shortcuts, and selection behavior. Semantic system colors so Light/Dark and accessibility settings work. No custom chrome that fights AppKit.

## 1.2 Color System

### Base tokens (unchanged concept, kept from `Theme/Colors.swift`)

The app already maps tokens to semantic `NSColor`s — keep this. It is the reason Light/Dark mode works for free.

| Token | Maps to | Used for |
|---|---|---|
| `mlmBase` | `windowBackgroundColor` | Window background |
| `mlmSurface` | `controlBackgroundColor` | Cards, panels, table headers |
| `mlmRaised` | `underPageBackgroundColor` | Hover, elevated rows |
| `mlmEdge` | `separatorColor` | Borders, separators |
| `mlmInk` | `.primary` | Primary text |
| `mlmInkSecondary` | `.secondary` | Secondary text, subtitles |
| `mlmInkMuted` | `tertiaryLabelColor` | Placeholders, disabled, hints |
| `mlmAccent` | `accentColor` | Selection, primary actions, active nav |

### Status palette (fixed meanings — never reuse these hues for anything else)

| Token | Color | Exactly one meaning |
|---|---|---|
| `mlmActive` | system blue | **Work in progress** (downloading, analyzing, syncing, importing) |
| `mlmSuccess` | system green | **Completed successfully** (synced, downloaded, resolved) |
| `mlmAttention` | system orange | **Needs user review or action** (failed download, pending duplicate review, expired sign-in, incomplete playlist) |
| `mlmError` | system red | **Error or destructive** (playback error, missing file, delete actions) |

> Rule: status colors are only ever used for these four meanings. If a design wants color for a non-status purpose (data scales, brands), it must use a different hue.

### Source brand colors (new — replaces the colliding generics)

Today `mlmSoundCloud = .orange` collides with the warning color and `mlmSpotify = .green` collides with success (`Colors.swift:68–74`). Brand colors become real brand values, used **only** for source identity (source badges, source rows, "linked to" labels), never for status:

| Token | Hex | Source |
|---|---|---|
| `mlmBrandSoundCloud` | `#FF5500` | SoundCloud |
| `mlmBrandSpotify` | `#1DB954` | Spotify |
| `mlmBrandYouTube` | `#FF0000` | YouTube |
| `mlmBrandAppleMusic` | `#FA243C` | Apple Music |

Each defined as adaptive `NSColor` (slightly darkened in Dark Mode for contrast against `mlmSurface`). YouTube red vs. error red: acceptable because brand color always appears **with the source name as text**, never alone (Principle 1).

### Data visualization scales (decoupled from status hues)

| Scale | Spec | Notes |
|---|---|---|
| Energy (1–5, LUFS-derived) | Single-hue ramp on the accent color: level 1 = accent at 25 % opacity → level 5 = accent at 100 % | Replaces the cyan→green→yellow→orange→red ramp (`Colors.swift:60–65`), which reused three status hues. Red bars must not read as "error". |
| Danceability (0–1) | Violet→indigo ramp (existing `DanceabilitySteps` look) | Kept; violet collides with nothing. |
| BPM | Plain monospaced text, no color | |
| Waveforms | Accent fill at 40 % opacity, played portion at 100 % | |

## 1.3 Typography

Keep the existing semantic scale (`Theme/Typography.swift`) with these reductions — several aliases exist today that differ in name only; the ground truth set is:

| Token | Spec | Used for |
|---|---|---|
| `heroTitle` | `.title.bold` | Playlist/detail hero names |
| `pageTitle` | `.title2.semibold` | Screen titles |
| `sectionHeader` | `.headline` | In-screen section headers |
| `body` | `.body` | Table cells, default text |
| `bodyBold` | `.body.semibold` | Track titles, emphasized rows |
| `data` | `.body` monospaced | Durations, bitrates, sizes, paths |
| `dataSmall` | `.caption` monospaced | Shortcuts, counts, technical IDs (rare) |
| `sectionLabel` | `.caption.semibold.smallCaps()` | Group labels ("MANAGED BY MLM") |
| `muted` | `.caption` | Subtitles, secondary lines |
| `badge` | `.caption2.medium` | Status chips, count pills |

No other font sizes. No emoji in UI copy (removes `"Groove Studio 🚀"`, `MetadataPanel.swift:874`).

## 1.4 Spacing, Metrics, Iconography

| Element | Value |
|---|---|
| Sidebar width | 200–240 pt |
| Table row height | 36 pt |
| Playlist card | 200–260 pt adaptive grid (unchanged) |
| Inspector width | 320–480 pt, ideal 360 |
| Activity panel | 36 pt collapsed, 150–700 pt expanded, default 284 |
| Card/panel corner radius | 8 pt |
| Status chip | `badge` font, 4 pt vertical / 8 pt horizontal padding, capsule, tinted background at 15 % opacity |

**Iconography rules:**
1. Status chips and critical states: SF Symbol **plus** text, always.
2. Source identity: source name as text; the symbol is decoration only.
3. Destructive actions: `trash` or `exclamationmark.triangle`, red, and always labeled — never a bare thumbs-down that deletes a file (today: `DiscoveryInboxView.swift:279`).
4. One symbol per concept, fixed in the glossary below.

## 1.5 Glossary — the only user-facing words

| Term | Meaning | Never called |
|---|---|---|
| **Library** | The local track collection | — |
| **Playlist** | Any playlist; may be local or linked | "synced playlist" |
| **Linked to ‹Source›** | Playlist/track originates from an external source | "Synced", cloud icon |
| **Not downloaded** | Remote track, never fetched | "Stream" |
| **Download failed** | A fetch attempt failed; reason is known | "download failed" |
| **File missing** | DB says local, disk disagrees | — (was invisible) |
| **Review** | The Duplicates + Conflicts area | "Duplicate Review" |
| **Duplicate group** | N versions of one recording | "Track A / Track B" pairs |
| **Metadata conflict** | Same recording, disagreeing fields | "Metadata Conflict" badge only |
| **Discover** | Recommendations + Reels area | "Swarm Intelligence" |
| **Recommendation** | A suggested track to review | "Neighbor", "Swarm recommendation" |
| **Reels** | Identify music in imported videos | — |
| **Similar** | Track-level similarity feature | "Groove", "Groove Studio" (sheet) |
| **Genre Workshop** | Genre labeling + ML export (Settings → Advanced) | "Groove Studio" (sidebar) |
| **Sync profile** | A target folder/device + rules | — |
| **Preview** | Pre-computed sync plan | — |
| **Background processing** | Concurrency preference: Conservative / Standard / Fast | "Turbo", "CPU-Leistung" |
| **Managed by MLM** | App-owned folders/files | "00_Artists", "01_SoundCloud" |
| **Activity** | The background work panel | — |

Banned from all user-facing strings: `Turbo`, `Swarm`, `Vector Gravity`, `Warp Embeddings`, `Drop-Fokus`, `kept_higher_quality`, `flagged`, `fingerprint_dedup`, raw track IDs (`Track #123`), any German UI string.

## 1.6 Global State Vocabulary

One vocabulary, used identically in every table, card, header, inspector, and menu. **This section is the fix for the app's deepest problem: states that had no model and therefore no UI.**

### Track availability (persisted enum — new)

| State | Chip text | Color | Icon | Meaning / data rule |
|---|---|---|---|---|
| Local | *(no chip — default)* | — | — | `organizedPath != nil` AND file verified on disk |
| Downloading… | `Downloading…` | `mlmActive` | `arrow.down.circle` | Active download job |
| Not downloaded | `Not downloaded` | `mlmInkMuted` | `icloud` *(text carries meaning)* | Remote, never attempted |
| Download failed | `Download failed` | `mlmAttention` | `exclamationmark.arrow.circlepath` | Persisted failure with reason + timestamp + attempt count |
| File missing | `File missing` | `mlmError` | `doc.questionmark` | Was local, file gone (detected on scan/playback attempt) |

Rules:
- Availability gets its **own narrow table column** ("Status") in Library, Playlist, and Folder tables. The Format column shows format only — the "Stream" badge hack (`PlaylistTable.swift:309`, `LibraryTable.swift:99`) is removed.
- Failed rows are dimmed (60 % opacity text) and never silently disappear after 3 retries; the retry budget is shown ("2 attempts left").
- Double-clicking a non-playable row never produces a bare playback error; it offers the contextual action (Retry download / Reveal issue).

### Playlist status

| State | Where | Text |
|---|---|---|
| Local | Card subtitle / header | nothing extra |
| Linked | Card subtitle | `SoundCloud` / `YouTube` / `Spotify` (brand-colored text label, not icon) |
| Importing | Card chip + header status line | `Importing · 12 of 44` (blue) |
| Incomplete | Card chip + header status line | `Incomplete · 9 failed` (amber, always with action) |
| Linked, source disconnected | Header status line | `SoundCloud disconnected — reconnect in Settings` |

### Source status

`Connected` (green) · `Disconnected` (muted) · `Sign-in expired` (amber, with "Reconnect" action). Shown in Sources, and anywhere a linked playlist's source matters.

### Job status (Activity panel & import jobs)

`Queued` (muted) · `Running` (blue, determinate where countable) · `Paused` (muted) · `Completed` (green) · `Failed` (red, with reason + Retry) · `Cancelled` (muted).

## 1.7 Language & Copy Rules

1. **English only.** Every German string in the current UI is a defect (list in Part 5).
2. Sentence case for buttons and menu items ("Add to playlist", not "Add To Playlist").
3. Numbers over symbols in running text ("9 failed", not "⚠9").
4. Errors = plain-language cause + one action. Technical detail behind a "Details" disclosure or the Logs tab.
5. Confirmation dialogs state the consequence, not just the action ("This removes 6 files from your disk. You can restore them from the Trash.").

---

# Part 2 — App Shell

## 2.1 Main Window

```
┌──────────────────────────────────────────────────────────────────────┐
│  Toolbar:  [◀ sidebar]   [ Player Bar (centered) ]        [ Search ] │
├────────────┬─────────────────────────────────────────┬───────────────┤
│            │                                         │               │
│  SIDEBAR   │            DETAIL (per section)         │   INSPECTOR   │
│  200–240pt │                                         │  (on demand,  │
│            │                                         │   320–480pt)  │
│            │                                         │               │
│ ────────── │                                         │               │
│  Settings  │                                         │               │
├────────────┴─────────────────────────────────────────┴───────────────┤
│  Activity bar (36 pt, always visible — expands upward)               │
└──────────────────────────────────────────────────────────────────────┘
```

**Anatomy**

| Element | Spec |
|---|---|
| Window | Min 900×600, default 1200×800 (unchanged, `MLMApp.swift:21–28`), unified title bar |
| Toolbar | Leading: sidebar toggle. Center (`.principal`): Player Bar. Trailing: **Search field** (⌘F). Nothing else. |
| Detail | Routed by sidebar selection; playlist details push within the Playlists section |
| Inspector | Trailing `.inspector`, opens via ⌘I / double-click on a track; closed via × or ⌘I |
| Activity bar | Bottom edge, always visible, see §2.5 |

**Changes vs. current**
- Remove `SyncTurboToggle` from the toolbar (`ContentView.swift:189–191`). The concurrency preference moves to Settings → Maintenance (§3.15) and the Sync detail (§3.8). This eliminates the "50 CPU" pseudo-meter, the toolbar layout shift from its late async appearance (`SyncTurboToggle.swift:9`), and the second conflicting "Turbo Mode" toggle (`MaintenanceView.swift:22–42`) — one setting, one place, one name: **Background processing**.
- Add the global Search field to the toolbar; the Search sidebar section (`ContentView.swift:242–243`) is removed (⌘F remains).
- Root loading copy `"Loading Library..."` / `"Failed to Initialize"` is fine; keep, unchanged.

## 2.2 Sidebar

```
┌─────────────────────┐
│ LIBRARY             │
│ 􀫋 Library      ⌘1  │
│ 􀊆 Playlists    ⌘2  │
│   ▸ Pinned (≤8)     │
│ 􀈖 Folders      ⌘3  │
│ 􀁷 Sync         ⌘4  │
│ 􀤆 Sources      ⌘5  │
│ WORK                │
│ 􀋃 Review  (5·2) ⌘6 │
│ 􀎞 Discover     ⌘7  │
│                     │
│ ─────────────────── │
│ 􀍟 Settings          │
└─────────────────────┘
```

**Anatomy**

| Row | Icon | Badge | Notes |
|---|---|---|---|
| Library | `music.note.list` | Red dot + text-on-hover `Library drive disconnected` | Dot stays (today: `SidebarView.swift:50–56`); add the same warning as a banner inside Library when offline |
| Playlists | `list.bullet` | — | Disclosure with up to 8 pinned playlists (existing `PinnedPlaylistsDisclosure`); empty state `No pinned playlists` (keep) |
| Folders | `folder` | — | |
| Sync | `arrow.triangle.2.circlepath` | Blue spinner dot while any sync runs | New — currently no ambient sync signal outside the collapsed Activity panel |
| Sources | `globe` | Amber dot if any source expired | New — mirrors source status vocabulary |
| Review | `doc.on.doc` | Amber capsule `5 dup · 2 conf` | Today a single undifferentiated count (`SidebarView.swift:59–70`); split the number, tooltip explains |
| Discover | `sparkles` | Muted count of pending recommendations | New — today the inbox gives no ambient signal |
| Settings | `gearshape` | — | Pinned footer (unchanged) |

Section headers: `LIBRARY` / `WORK`, `sectionLabel` font, `mlmInkMuted`.

**Interactions** — single-click navigates; ⌘1–⌘7; pinned-playlist context menu unchanged except English copy (`Unpin from Sidebar`, `Rename…`, `Reveal in Grid`, `Delete` — keep) and rename failures surface a toast instead of silent-fail (`PinnedPlaylistsDisclosure.swift:156–158`).

**Changes vs. current**
- Remove `Duplicates`, `Discovery Inbox`, `Reels Inbox`, `Groove Studio`, `Search` rows; add `Review` and `Discover`. 10 rows → 7 + Settings (the app's own old design doc demanded ≤5+2; this lands at 7+1 with every row earning its place).
- `Review` = today's Duplicates section, renamed because it contains conflicts too (title mismatch: `ContentView.swift:364` vs. `ReviewQueueView.swift:34`).
- `Discover` = Recommendations (ex-Discovery Inbox) + Reels as tabs (§3.11, §3.12).
- Genre Workshop (ex-Groove Studio sidebar section) moves to Settings → Advanced (§3.15). Decision: feature is kept, re-homed.
- Shortcuts: Review ⌘6, Discover ⌘7 (reused from removed sections).

## 2.3 Toolbar

| Position | Content |
|---|---|
| Leading | Sidebar toggle (system) |
| Principal | Player Bar (§2.4) |
| Trailing | Search field: placeholder `Search library…`, ⌘F, icon `magnifyingglass`. Focus jumps: if results include remote sources, segmented scope `Library · All sources` appears inline (§3.13) |

No other items. No percentage, no gauge, no permanent settings affordances.

## 2.4 Player Bar

```
┌────────────────────────────────────────────────────────────────┐
│  [▶]  [cover 40]  Title (semibold)      ─────●───── 0:47 3:12  │
│                   Artist · Album (muted)            ( 🔊 ─── )  │
└────────────────────────────────────────────────────────────────┘
```

**States**

| State | Presentation |
|---|---|
| Idle | Cover placeholder `music.note`, text `Not Playing` (keep), scrubber disabled, times hidden (not `"—:——"`, `PlayerBar.swift:119,135`) |
| Playing/Paused | As wireframe; cover hover reveals pause/play overlay (consistent with inspector header) |
| Track unavailable | Red `exclamationmark.triangle` + `File missing` / `Download failed` + button `Show in Review`/`Retry` — replaces raw error text (`PlayerBar.swift:85–94`) |

**Changes vs. current**
- Remove permanently disabled prev/next buttons (`PlayerBar.swift:45,63`) until wired. Dead affordances ship nothing.
- Remove disabled `Volume Up/Down` menu items (`MLMApp.swift:112–122`).

## 2.5 Activity Panel

Collapsed (default, 36 pt):

```
┌──────────────────────────────────────────────────────────────┐
│ 􀐫 Activity · Downloading 12/44 · Analysis: 3 pending   [▲]  │
└──────────────────────────────────────────────────────────────┘
```

Expanded (150–700 pt, drag-resizable — keep):

```
┌──────────────────────────────────────────────────────────────┐
│  [Operations | Logs]                                     [▼] │
│  DOWNLOADS                                                   │
│   Downloading 12/44  ▓▓▓▓▓░░░░░  Artist – Title   [Pause][✕] │
│   9 failed — [Retry all] [Show]                              │
│  SYNC                                                        │
│   Walkman · 134/812 · Copying: Artist – Title     [Pause][✕] │
│  ANALYSIS QUEUE                                              │
│   3 pending · paused while downloads run          [Resume]   │
│  RECENT                                                      │
│   ✓ Import "YouTube Playlist" — 35/44 · 9 failed  [Show]     │
└──────────────────────────────────────────────────────────────┘
```

**Anatomy / rules**

1. Header reads as a button: chevron + `Activity` + summary, hover background `mlmRaised` (today it doesn't look interactive).
2. Every running job: determinate fraction where countable, current item, **Pause and Cancel inline** (today cancel exists only here and only for sync/downloads — keep that, add Pause; sync detail also gets its own controls, §3.8).
3. Failed downloads remain visible after relaunch (persisted retry queue surfaces here: `00_FLAC/.retry_queue.json` gets UI at last — today zero views render it).
4. Analysis queue explains suspension in words: `Paused while downloads run` (today it silently stalls, `PerformanceQueueService.swift:434–442`).
5. Logs tab: keep level filters and search; all strings English (`LogsTab.swift` is currently German: `"Quellen:"`, `"Logs durchsuchen…"`).
6. Empty: `No active operations` + `Downloads, imports, and sync jobs appear here` (keep, already good: `OperationsTab.swift:116–119`).

## 2.6 Menu Bar (complete, English)

| Menu | Items |
|---|---|
| MLM | About MLM · Settings… ⌘, · Quit MLM ⌘Q |
| File | New Playlist ⌘N · Import from Folder… ⌘⇧I |
| Edit | (standard) |
| Playback | Play/Pause ␣ · Stop ⌘. · Skip Back 10 s ⌘← · Skip Forward 10 s ⌘→ |
| Navigate | Library ⌘1 · Playlists ⌘2 · Folders ⌘3 · Sync ⌘4 · Sources ⌘5 · Review ⌘6 · Discover ⌘7 |
| Library | Search Library ⌘F · More Info ⌘I |
| Window | (standard) |
| Help | MLM Help |

**Changes vs. current:** remove `"Einstellungen…"` German label (`MLMApp.swift:39`); remove `"Sichere Pfad-Migration…"` menu item + its redirect alert (`MLMApp.swift:153`, `ContentView.swift:271–276`) — path migration lives exclusively in Settings → Maintenance; fix Dock menu `Show Library` with `action: nil` (`AppDelegate.swift:51–55`) or remove it.

---

# Part 3 — Screens

Schema for every screen: **Purpose · Wireframe · Anatomy · States · Interactions · Edge Cases · Changes vs. current.**

## 3.1 Library

**Purpose.** The home screen: browse, filter, and act on the full track collection, local and remote.

**Wireframe**

```
┌──────────────────────────────────────────────────────────────┐
│ Library                                   [Local 12.431|Remote 812]│
│ [Search tracks…]              Sort: [Recently added ▾]       │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ ⚠ Library drive disconnected — reconnect to play files.  │ │ ← only when offline
│ ├────┬───────────┬────────┬────────┬───────┬────────┬──────┤ │
│ │ #  │ Title     │ Artist │ Album  │ Time  │ Format │Status│ │
│ │  1 │ Song      │ Artist │ Album  │ 3:12  │ FLAC   │      │ │
│ │  2 │ Track     │ Artist │ YouTube│ 4:01  │ —      │Not d.│ │
│ │  3 │ Track     │ Artist │ YouTube│ 3:44  │ —      │Failed│ │
│ └────┴───────────┴────────┴────────┴───────┴────────┴──────┘ │
└──────────────────────────────────────────────────────────────┘
```

**Anatomy**

| Element | Spec |
|---|---|
| Scope tabs | Segmented `Local` / `Remote` with counts (exists, `LibraryView.swift:105–126`); tab badges use `badge` font |
| Table | Sortable columns: `#`, `Title` (with 18 pt cover thumb + now-playing `speaker.wave.2.fill`), `Artist`, `Album`, `Time`, `Genre`, `Year`, `BPM`, `Energy`, `Dance`, `Format`, **Status** (new, 90 pt, vocabulary §1.6), `Added` |
| Status column | Chips per §1.6; empty for healthy local tracks |
| Placeholder metadata | Rendered `mlmInkMuted` italic + tooltip `Placeholder from import — will update after download` |

**States** — Default / Empty library (`No music yet` + `Import Folder…` button + `Connect a source in Settings`) / Loading (skeleton rows, not spinner-only) / Drive disconnected (amber banner above table + rows of local files remain browsable but non-playable) / Filtered-empty (`No matching tracks`).

**Interactions**
- Double-click row: play (if playable) — else show the state-appropriate action menu
- ⌘I / double-click: inspector (§3.10)
- Context menu (full list): `Play` · `Add to Playlist ▸` (existing playlists + `New Playlist…`) · `Add to Sync Profile ▸` · — · `Download` / `Download n tracks` / **`Download missing tracks`** (always offered when any selection is remote; replaces the all-remote-only rule, `TrackContextMenu.swift:29–31,163`) · `Retry download` (failed only) · — · `Reveal in Finder` (local only) · `Copy File Path` · — · `Remove from Library…` (confirm dialog, English)
- Column sort: click header; reorder-only-in-default-sort rule for playlist tables documented there (§3.3)

**Edge Cases** — 10k+ tracks (virtualized table, keep); remote-only scope with disconnected source (rows show `Not downloaded`, source banner points to Settings); mixed selection for Download (menu shows `Download 12 missing of 30 selected`).

**Changes vs. current**
- New Status column replaces the `Stream` text in Format (`LibraryTable.swift:99`).
- Placeholder metadata visually marked (today indistinguishable from real data).
- Drive-offline banner added (today only a 7 px red dot in the sidebar).
- Download context action fixed for partial selections.

## 3.2 Playlists (Grid)

**Purpose.** Overview of all playlists with instantly readable origin and health.

**Wireframe**

```
┌──────────────────────────────────────────────────────────────┐
│ Playlists (24)                    [Filter: All|Local|SoundCloud|YouTube|Incomplete] [+ New]│
│ [Search playlists…]                                          │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐                         │
│ │ cover   │ │ cover   │ │ cover   │                         │
│ │      􀇿 │ │         │ │         │                         │
│ │ Title   │ │ Mix     │ │ Gym     │                         │
│ │ YouTube │ │ 48 tracks│ │ 12 tracks│                        │
│ │ 44 tracks│ │        │ │         │                         │
│ │⬤Incomplete·9 failed│ │        │ │                         │
│ └─────────┘ └─────────┘ └─────────┘                         │
└──────────────────────────────────────────────────────────────┘
```

**Anatomy**

| Element | Spec |
|---|---|
| Card cover | Square; custom cover → image; else category gradient + symbol (existing) |
| Pin | `pin.fill`, top-right, white on scrim (unchanged) |
| Source label | **Text under the title**: `YouTube` / `SoundCloud` / `Spotify`, brand color, `muted` font. Replaces the unlabeled cloud badge |
| Status chip | Bottom-left of the info area: `Importing · 12 of 44` (blue) or `Incomplete · 9 failed` (amber); absent when healthy |
| Subtitle | `44 tracks` (keep); liked playlist: `♥ Liked` word instead of duplicate heart glyphs |
| Filter bar | Segment chips: `All · Local · SoundCloud · YouTube · Incomplete` (sources appear dynamically based on what's linked) |

**States** — Empty (`No playlists yet` + `Create your first playlist with ⌘N or the + button.`) / Search-empty (`No matching playlists`) / Importing cards show a thin determinate progress line under the cover.

**Interactions** — Click opens detail; context menu: `Open` · `Rename…` · `Pin to Sidebar` / `Unpin` · `Reset to Auto Cover` (if custom) · `Download missing tracks` (linked/incomplete only) · `Show failed tracks` (incomplete only) · `Sync to ▸` · — · `Delete Playlist…` (confirm; liked playlists explain protection instead of hiding delete silently).

**Edge Cases** — Pin limit: keep the 3 s banner, copy: `Pin limit reached (8). Unpin one first.` / Source expired: card gets amber `Reconnect` chip linking to Settings → Sources / Drag-and-drop cover image errors: keep banner, English copy.

**Changes vs. current**
- Cloud badge (`PlaylistCard.swift:148–158,428–439`) replaced by source text label — the icon was unlabeled, tooltip-less, and collided with the SoundCloud-specific use of the same glyph in Sources.
- New: source/status filter chips (today: name search only, `PlaylistViewModel.swift:264–273`).
- New: incomplete/importing chips (today a 44-track unplayable playlist looks healthy).
- Liked state shown once, as text (today up to three redundant cues).

## 3.3 Playlist Detail

**Purpose.** Everything about one playlist: what it is, where it came from, what's playable, what needs action.

**Wireframe**

```
┌──────────────────────────────────────────────────────────────┐
│ ‹ Playlists                                                  │
│ ┌────┐  My Playlist                            [▶ Play]      │
│ │ 64 │  44 tracks · Linked to YouTube · imported Jan 12      │
│ └────┘  ⚠ 9 of 44 tracks failed to download — [Show] [Retry all]│
│         [Sync ↻] [Import M3U…] [Download missing (35)]  [Search tracks…]│
│ ┌────┬───────────┬────────┬────────┬──────┬────────┬───────┐ │
│ │ #  │ Title     │ Artist │ Album  │ Time │ Format │Status │ │
│ │  7 │ Video ttl │ Unknown│ YouTube│ 3:44 │ —      │Failed │ │ ← dimmed
│ └────┴───────────┴────────┴────────┴──────┴────────┴───────┘ │
│ ▾ Failed tracks (9)                                          │
│   Video title — "Video unavailable in your region" [Retry]   │
│   Video title — "yt-dlp not installed" [Open Settings]       │
└──────────────────────────────────────────────────────────────┘
```

**Anatomy**

| Element | Spec |
|---|---|
| Header line 2 | `44 tracks · Linked to YouTube · imported Jan 12, 2026` — provenance as a sentence, replaces the bare `Synced` label (`PlaylistDetailView.swift:169–173`) |
| Header status line (conditional) | Amber: `9 of 44 tracks failed to download` + `Show` (expands failure list) + `Retry all`. Blue while importing: `Downloading · 12 of 44` + determinate bar |
| Primary action | **`▶ Play`** — new (today: only row double-click) |
| Secondary actions | `Sync` only when actually supported (liked source playlists; the capability gate `canSync` already exists, `PlaylistDetailViewModel.swift:86`) · `Import M3U…` (renamed from mixed-language `Import M3U8`) · **`Download missing (n)`** — new, the fix for the all-remote trap |
| Failed tracks section | Disclosure below the header: per-track reason in plain language + contextual action (`Retry`, `Open Settings` for missing tools, `Remove`) + footer actions `Retry all` · `Remove failed tracks from playlist` |
| Table | Columns as Library incl. Status; `Added` shows `—` for imports until a real date exists |

**States** — Empty (`No tracks yet` + `Add tracks from the Library via right-click → Add to Playlist, or import an M3U file.`) / Loading / `Playlist not found` (keep, `PlaylistDetailViewLoader.swift:36–44`) / Importing (live counts, updates on `.downloadDidComplete` — today the view ignores that notification, `PlaylistDetailView.swift:63`) / Incomplete (status line above) / Source disconnected.

**Interactions** — Row double-click: play or contextual recovery · drag to reorder (default sort only, existing) · context menu per §3.1 plus `Remove from Playlist` (with confirm for multi-select — today selection-based removal has no confirmation and the single-track alert is unreachable dead code, `PlaylistDetailView.swift:88–99`).

**Edge Cases** — Playlist of 44 not-downloaded tracks: header says `Linked to YouTube · nothing downloaded yet` + prominent `Download all (44)`; partial download after cancel: counts reflect reality; track whose file was deleted: `File missing` chip + `Re-download` / `Remove from Library`.

**Changes vs. current**
- New: Play button, provenance line, status line, failed-tracks disclosure with reasons, `Download missing` action.
- `Synced` label removed; sync button only where meaningful.
- Live refresh on download completion.
- Deletion confirmations consistent.

## 3.4 Folders

**Purpose.** Answer three questions at a glance: where are my files, which of them does the app manage, and what came from where.

**Wireframe**

```
┌──────────────────┬───────────────────────────────────────────┐
│ ▾ Music          │ Music › 01_SoundCloud          [Show in Finder]│
│   􀈕 Downloads   │ 512 tracks · Managed by MLM                │
│    (SoundCloud)  │ ┌──────────┬────────┬──────┬────────┬─────┐│
│   􀈕 Downloads   │ │ Title    │ Artist │ Time │ Format │Source││
│    (YouTube)     │ │ Song     │ Artist │ 3:12 │ M4A    │ SC  ││
│   ▸ Artists      │ └──────────┴────────┴──────┴────────┴─────┘│
│   ▸ Sets         │ ⚠ 3 files in this folder are not in the    │
│                  │   library — [Import]                       │
└──────────────────┴───────────────────────────────────────────┘
```

**Anatomy**

| Element | Spec |
|---|---|
| Managed folders | Distinct icon `arrow.down.circle` (or source glyph) + section label `MANAGED BY MLM` pinned atop the outline; tooltip `Created and maintained by MLM` |
| Managed folder names (target) | `Downloads (SoundCloud)`, `Downloads (YouTube)` — replaces `01_SoundCloud`, `00_Artists` (created lazily on first download, not at app launch: `DownloadOrchestrator.swift:124–138`) |
| Track table | Columns: `Title`, **`Artist`** (new — a flat 500-file folder is unusable without it), `Album`, `Time`, `Format`, `kbps`, **`Source`** (new), `Energy`, `Dance` |
| Unindexed files notice | Amber row under the table: `3 files in this folder are not in the library` + `Import` (today such files are invisible, `FolderViewModel.swift:122–145`) |
| Breadcrumb | Keep, clickable, plus track count + Reveal |

**States** — Drive offline: `Drive not connected` full-pane state (keep, `FoldersView.swift:431–437`) / Empty folder / Folder with only unindexed files (notice above) / Orphaned managed folder (managed folder deleted in Finder → Review surfaces the repair flow, see §3.9).

**Interactions** — Tree: single-click select, double-click expand (keep), context `Show in Finder` (keep, English) · Track context menu as §3.1 · `Import` on the unindexed notice scans just that folder.

**Edge Cases** — User dropped own files into a managed folder (unindexed notice catches it) · nested Discovery seed folders (build with `PathSanitizer`, not raw artist strings — `DownloadViewModel.swift:475`) · very large flat managed folders (Artist column + search make them workable).

**Changes vs. current**
- Managed vs. personal folders visually and structurally distinguished (today identical generic folder icons, `FolderTreeView.swift:26–33`).
- Artist + Source columns; unindexed-file detection; lazy folder creation; sanitized seed folder names.
- Settings → Library gains an "Storage layout" explainer listing the managed folders (§3.15).

## 3.5 Sources

**Purpose.** Connect external accounts and start imports. This is the single entry point for SoundCloud/Spotify/Apple Music/YouTube.

**Wireframe**

```
┌──────────────────────────────────────────────────────────────┐
│ Sources                                                      │
│ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐       │
│ │ 􀆔 SoundCloud  │ │ 􀑪 Spotify     │ │ 􀑭 Apple Music │       │
│ │ ● Connected   │ │ ● Sign-in     │ │ ○ Disconnected│       │
│ │ 1.2k tracks   │ │   expired     │ │               │       │
│ │ Last sync 2h  │ │ [Reconnect]   │ │ [Connect]     │       │
│ │ [Sync] [Playlists]│            │ │               │       │
│ └───────────────┘ └───────────────┘ └───────────────┘       │
│ ┌───────────────┐                                            │
│ │ 􀅼 YouTube     │  Paste a playlist URL to download tracks. │
│ │ [Import playlist…]                                         │
│ └───────────────┘                                            │
└──────────────────────────────────────────────────────────────┘
```

**Anatomy** — One card per source: brand-colored name, status line (vocabulary §1.6), track count + last sync when connected, primary actions. YouTube card: no auth, single `Import playlist…` action opening the import sheet (§3.6). All copy English (the current YouTube card text is German, `SourcesView.swift:305–360`).

**States** — Per source: Disconnected / Connecting (spinner + `Open browser to authorize`) / Connected / Expired (amber + `Reconnect`) / Syncing (determinate where the API allows).

**Edge Cases** — Token refresh fails silently today → surface as Expired · scdl config missing → the SoundCloud card explains the prerequisite with a link to Settings.

## 3.6 Remote Import Sheet (YouTube / SoundCloud playlist import)

**Purpose.** Turn a remote playlist into a local one — honestly: show what will happen, then report exactly what happened.

**Wireframe — step 1 (fetch)**

```
┌──────────────── Import YouTube Playlist ────────────────┐
│ [https://www.youtube.com/playlist?list=…          ]     │
│ [Load]                                                  │
│ Loading playlist… (indeterminate is OK here: one call)  │
└─────────────────────────────────────────────────────────┘
```

**Wireframe — step 2 (review & import)**

```
┌──────────────── Import YouTube Playlist ────────────────┐
│ "My Mix" · 44 tracks · from YouTube                     │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ 1  Track title                    Uploader    3:44  │ │
│ │ …  (titles only — metadata completes after download)│ │
│ └─────────────────────────────────────────────────────┘ │
│ Select: (•) All  ( ) First N [10]  ( ) N random [10]    │
│                                                         │
│ [Download 44 tracks]        [Save without downloading]  │
└─────────────────────────────────────────────────────────┘
```

**Wireframe — step 3 (progress → result)**

```
│ Downloading…  23 of 44  ▓▓▓▓▓▓░░░░  [Cancel]            │
│ ── after completion ──                                   │
│ ✓ 35 downloaded · ⚠ 9 failed                    [Show failed]│
│ [Open playlist]   [Done]                                 │
```

**Anatomy / rules**

1. **Two explicit choices**: `Download n tracks` (default) vs. `Save without downloading` — today saving happens implicitly on Load, creating the "fake finished playlist" (`RemotePlaylistsView.swift:57–78`). Both are legitimate; the user chooses.
2. Track list labels placeholder metadata honestly: subtitle `Metadata completes after download`.
3. Progress is determinate with per-track failures inline.
4. Result state persists: closing the sheet never loses the outcome — the playlist itself carries the status (§3.2/§3.3), and the Activity panel keeps the job in Recent.
5. yt-dlp missing → the error says exactly that + `Open Settings` (today: generic `Playlist konnte nicht importiert werden.`, `RemotePlaylistsViewModel.swift:112`).

**States** — Idle / Loading / Review / Downloading / Done (complete) / Done (partial) / Failed (with reason).

**Edge Cases** — Video deleted between fetch and download → per-track `Video unavailable` · duplicate tracks already in library → matched by external ID, not re-downloaded (existing `findOrCreate` behavior — now surfaced: `12 already in library`) · user cancels at 23/44 → playlist shows `Incomplete · 23 of 44 downloaded` with `Download missing (21)`.

**Changes vs. current**
- New: explicit download-vs-save choice, determinate progress, result summary, plain-language failures, settings deep-links.
- All copy English (sheet is currently German: `RemotePlaylistsView.swift`).

## 3.7 Sync — Profile List

**Purpose.** Manage sync targets (devices, folders) and see their state at a glance.

**Wireframe**

```
┌───────────────┬──────────────────────────────────────────┐
│ Sync Profiles │  (selected profile detail — §3.8)        │
│ [+]           │                                          │
│ 􀁷 Walkman     │                                          │
│   /Volumes/…  │                                          │
│   ✓ Synced 2h ago                                       │
│ 􀁷 USB Drive   │                                          │
│   ● 34 pending│                                          │
└───────────────┴──────────────────────────────────────────┘
```

**Anatomy / changes** — Rows gain a status line (today: name + folder only, `SyncView.swift:268–283`): `✓ Synced 2h ago` · `● n tracks pending` (preview says changes exist) · `◌ Device not connected` · `↻ Syncing 134/812`. Context menu: `Rename…` (new), `Duplicate` (new), `Delete…` — **with confirmation** (today none, `SyncView.swift:100–102`). Empty state stays: `No sync profiles` / `Create a profile to sync music to an external device`.

**Create sheet** — English: `New Sync Profile` · fields `Name`, `Output folder [Browse…]`, `Detect device…` (Rockbox detection stays, `SyncView.swift:136–263`); smart defaults toast stays: `Rockbox device detected — device defaults applied`. Empty detection: `No devices found — is it connected?`

## 3.8 Sync — Profile Detail

**Purpose.** Configure what goes where, see the plan before anything happens, run it with confidence.

**Wireframe**

```
┌──────────────────────────────────────────────────────────┐
│ Walkman                          [↻ Refresh] [▶ Sync now]│
│ /Volumes/WALKMAN · Rockbox defaults                      │
│ Preview: up to date · computed 2 min ago                 │ ← status line
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐     │
│ │ Add  23 ▾│ │ Remove 4 ▾│ │ ≈ 1.2 GB │ │ 8.4 GB   │     │
│ │          │ │          │ │ new size │ │ available│     │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘     │
│ ▸ Playlists (3)      ▸ Tracks (12)      ▸ Settings       │
│ ── during sync ──                                        │
│ Syncing… 134 of 812 ▓▓▓▓░░░░ Transcoding: Artist – Title │
│ [Pause] [Cancel]                                         │
│ ── after ──                                              │
│ ✓ 810 synced · ⚠ 2 failed — ▸ Failed tracks (2)          │
│   Artist – Title — "Destination full"        [Retry]     │
└──────────────────────────────────────────────────────────┘
```

**Anatomy**

| Element | Spec |
|---|---|
| Preview status line | One of: `Preview: up to date · computed 2 min ago` / `Preview: updating… 45/120` (determinate, cancelable) / `Preview: outdated — updating in background` / `Device not connected — preview unchecked` |
| Stat cards | `Add`, `Remove`, `≈ new size`, `Available` — **Add/Remove expand into the actual file lists** (data exists today, never shown: `SyncService.swift:30–38`) |
| Size estimate | Mode-aware (not hardcoded 248 kbps, `SyncService.swift:826–830`) and prefixed `≈` |
| Space check | Amber banner when tight: `Not enough space on device — need ≈4.2 GB, 1.0 GB available` |
| During sync | Inline determinate progress **in the detail view** + `Pause` + `Cancel` (today: only a redirect line to the collapsed Activity panel, `SyncProfileDetailView.swift:65,80–85`) |
| Current item | `Copying:` vs `Transcoding:` prefix — the distinction exists in code, surface it |
| Failures | `Failed tracks (n)` disclosure: aligned rows with **Title Artist** + reason + album, per-row context menu (Play, Play Next, Show Details, Retry Sync, Reveal in Finder, Copy File Path), double-click plays + opens detail inspector, Retry button (`SyncFailedDisclosure.swift`) |

**Settings section (English, collapsed by default — keep pattern):** `Playlists (create .m3u8 files for Rockbox or Doppi)` · `Format & app (Rockbox / Doppi)` · `Transcode mode (Originals / AAC 248k / AAC 320k)` · `Normalize volume (−14 LUFS, AAC modes only)` · `Compatible paths (FAT32-safe)` · `Clean up (remove deleted tracks from destination)` · **`Background processing: Conservative / Standard / Fast`** — the renamed, relocated ex-Turbo setting (§2.1).

**States** — No device / Preview fresh / Preview stale (auto-refreshing in background) / Syncing / Paused / Completed / Completed with failures / Error (English strings only — today raw English tech strings mix with German UI, e.g. `TranscodeCache.swift:410`).

**Interactions** — Toggle settings freely: changes save instantly (keep) but mark the preview stale and trigger **debounced background recompute** (never a blocking spinner) · ⌘R manual refresh · stat cards expand · per-file context: `Reveal in destination`, `Exclude from sync`.

**Edge Cases** — Device unplugged mid-sync: state `Device disconnected`, partial results kept, resume offered · transcode cache pre-warmed: sync shows `Copying (pre-converted)` and finishes fast · settings changed during sync: applies to next run, note shown.

**Changes vs. current**
- Preview: cached + background-recomputed (today: synchronous, double-triggered on selection — `SyncView.swift:106` + `SyncProfileDetailView.swift:121` — recomputed on every toggle, with sequential per-track ffprobe, `SyncService.swift:141–146`).
- Inline progress + Pause/Cancel; file lists visible; failures human-readable; single-track retry without full recompute.
- Content rules engine exists in the DB (`SyncRepository.swift:77–83`) with no UI — the Rules section ships as `Coming in a later release` is **not** acceptable; either add a minimal rule editor (Genre/Energy/Playlist filters) or hide the plumbing. Decision: **hide until designed** — no half-doors.

## 3.9 Review (Duplicates & Metadata Conflicts)

**Purpose.** One trustworthy place to decide about duplicate recordings and disagreeing metadata — with reasons, recommendations, previews, and undo.

**Wireframe — list**

```
┌──────────────────────────────────────────────────────────┐
│ Review                        [Duplicates 5 | Conflicts 2]│
│ [Run scan]  Last scan: 2 days ago · 12.431 tracks        │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ 3 versions of "Song Title" — Artist                  │ │
│ │ Identical recording (audio fingerprint 96% match)    │ │
│ │ Recommended: keep Version 1 — lossless, complete tags│ │
│ │ [Review group]                        [Keep all]      │ │
│ └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**Wireframe — group detail (expands or pushes)**

```
┌──────────────────────────────────────────────────────────┐
│ "Song Title" — Artist · 3 versions                       │
│ Why flagged: identical audio fingerprint (96%),          │
│ different file quality.                                  │
│ ┌───┬──────────┬────────┬───────┬────────────┬─────────┐│
│ │ ✓ │ FLAC     │ 1411k  │ 3:44  │ Library/…  │ Complete││ ← recommended
│ │   │ M4A      │ 256k   │ 3:44  │ Downloads… │ Missing genre│
│ │   │ MP3      │ 128k   │ 3:42  │ old/…      │ Complete││
│ └───┴──────────┴────────┴───────┴────────────┴─────────┘│
│ [▶] preview each · Source column: Local / SoundCloud     │
│ [Keep recommended] [Choose manually] [Keep all — not duplicates]│
│ ☐ Move unkept files to Trash (optional, off by default)  │
└──────────────────────────────────────────────────────────┘
```

**Wireframe — metadata conflict**

```
┌──────────────────────────────────────────────────────────┐
│ Metadata conflict · same recording (fingerprint 94%)     │
│ ┌───────────┬──────────────────┬──────────────────┐      │
│ │ Field     │ Version A        │ Version B        │      │
│ │ ▸ Title   │ Song (Radio Edit)│ Song             │ ← amber│
│ │ ▸ Artist  │ Artist           │ Artist feat. X   │ ← amber│
│ │   Album   │ Album (same)     │ Album (same)     │ collapsed│
│ └───────────┴──────────────────┴──────────────────┘      │
│ Per field: (•) A  ( ) B        [Use all from A] [… from B]│
│ After merge: Title "Song", Artist "Artist feat. X", …    │
│ Affects: database only · file A will be renamed          │
│ [Apply] [These are different versions — keep both]       │
└──────────────────────────────────────────────────────────┘
```

**Anatomy / rules**

1. **Groups, not pairs** — N copies = one group with header (today: flat pairwise list, `ReviewQueueView.swift:87–98`).
2. **Reason in plain language** + the stored similarity score finally displayed (written to `details` JSON, never read, `DuplicateDetectionService.swift:405–410`).
3. **Recommendation with justification** (lossless > lossy > bitrate; completeness of metadata; location) — the ranking exists (`isBetterQuality`, `DuplicateDetectionService.swift:386–395`), the UI just never shows it.
4. **Roles labeled**: `Recommended` / `Alternative`, not `Track A` / `Track B`.
5. **Nothing is pre-marked in the DB during scan.** The scan proposes; the user disposes. (Today `is_duplicate = 1` is written at scan time, `DuplicateDetectionService.swift:359–363` — removed.)
6. **Undo**: every resolution posts a toast with `Undo`; `Restore` lives in Review → Resolved. (No unmark path exists today.)
7. **Variants** (remix/live/remaster/edit): activate the existing dead classifier (`DuplicateMatcher.isVariant`, `DuplicateDetectionService.swift:78–121`) and default such groups to `Keep both` with the explanation `Same recording, different version`.
8. **Conflicts: field-level diff.** Persist per-field scores at scan time (today discarded, `DuplicateDetectionService.swift:340–347`); highlight disagreeing fields amber; per-field pick A/B; merge preview; consequence line (`database only` vs `file will be renamed/moved`); escape hatch `These are different versions`.
9. **Scan entry points unified**: scan runs from Review only; Settings → Maintenance loses its duplicate `Deep Scan` (`MaintenanceView.swift:140–149`) and links here instead.

**States** — Never scanned (`Find duplicates and conflicts` + one-sentence scan explanation + `Run scan`) / Scanning (determinate `Comparing 1.204 of 12.431…`, cancelable) / Empty result (`No duplicates found — your library is clean`) / Items pending / All resolved (history visible).

**Edge Cases** — >2 versions; same recording different lengths (radio edit → variant path, not duplicate); one version remote (can be kept as the "streaming copy", explained); destination volume offline during Trash action (block with message); `Never suggest again` per group (dismissed = remembered, today dismissal is meaningless bookkeeping).

**Changes vs. current**
- Replaces the entire `ReviewQueueView` row model; `Resolve`/`Dismiss` (status-only bookkeeping, `AnalysisRepository.swift:145–162`) replaced by real actions.
- Raw tokens `(kept_higher_quality)` / `(flagged)` removed from UI (`ReviewQueueView.swift:130–134`).
- Inspector rows `Duplikat: Ja` / `Variante von: Track #123` (`MetadataPanel.swift:467–474`) become `Possible duplicate of "Artist – Title" — Show in Review` (linked).

## 3.10 Track Inspector

**Purpose.** Everything about one track: edit metadata, see analysis, locate the file, find similar music.

**Wireframe**

```
┌─ Inspector (320–480 pt) ─────────────────┐
│ [cover 56] Title                      [×] │
│            Artist — Album                 │
│            FLAC · 1411 kbps · 3:44        │
│ ──────────────────────────────────────────│
│ ~~~~~~~~~waveform (seekable)~~~~~~~~~~~  │
│ [BPM segments] 0:47 / 3:44                │
│ ──────────────────────────────────────────│
│ [General][Audio][File][Similar]           │
│  (tab content — below)                    │
│ ──────────────────────────────────────────│
│ [Add to Playlist…] [Add to Sync Profile…] │
└───────────────────────────────────────────┘
```

**Tabs (all English copy):**

| Tab | Content | Key fixes |
|---|---|---|
| General | Inline-editable rows: `Title`, `Artist`, `Album Artist`, `Album`, `Genre`, `Year` (Enter saves, Esc cancels — existing pattern, labels currently German, `MetadataPanel.swift:159–164`). Save failures toast instead of `print()` (line 231). |
| Audio | LUFS, Loudness Range, True Peak, BPM, Energy (n/5), Danceability (%); `Run analysis` buttons for missing values (labels + help English); waveform options (Sensitivity/Gain/Height/Reset) |
| File | Path cards `Original path` / `Library path` with `Copy` / `Show in Finder`; rows: `Format`, `Bitrate`, `Duration`, `Added`, **Status** (vocabulary §1.6 — replaces `Lokal`/`Remote`), `Downloaded`, **Source** (`SoundCloud` / `YouTube` / `Local import` — new), duplicate link row (§3.9) |
| Similar | **Real tab content, not a sheet launcher** (today selecting it force-opens a sheet and bounces back to General on dismiss, `MetadataPanel.swift:143–151`): analyzed → top-5 local similar tracks inline + `Show all` opens the Similar sheet; not analyzed → `No analysis yet` + `Analyze this track` + one-line explainer |
| Debug | Lazy ffmpeg/ffprobe diagnostics (`DebugTabView.swift`): decode-check card (errors, warnings, broken frames, exit code), stream-info card (container, codec, sample rate, channels, bitrate, duration), decoder-log card with Copy + Re-run. Runs once when the tab is first selected; shows "No local file" or "ffmpeg not found" cards when prerequisites are missing |

**Changes vs. current** — `Groove` tab → `Similar`; German labels → English; source row added; availability vocabulary unified; emoji removed.

## 3.11 Similar Tracks Sheet (ex-GrooveView)

**Purpose.** From one track: find what sounds like it — locally and from connected sources — and act on recommendations.

**Wireframe**

```
┌──────────── Similar to "Song Title" — Artist ────────────┐
│ ┌─ Local matches ────────────┐ ┌─ Recommendations ──────┐│
│ │ 96%  Artist – Title  [▶]   │ │ [SoundCloud|Last.fm]   ││
│ │ 91%  Artist – Title  [▶]   │ │ Artist – Title         ││
│ │ …                          │ │ 94% match · [Preview][↓]││
│ └────────────────────────────┘ └────────────────────────┘│
│ Preview deck: ~~~~waveform~~~~ 0:47/3:12  [Stop]         │
└──────────────────────────────────────────────────────────┘
```

**Rules**
1. Copy is plain: `Local matches`, `Recommendations`, `% match`, `Preview`, `Download`. Banned: Swarm/Vector Gravity/Warp Embeddings (tooltips today: `GrooveView.swift:396,412`).
2. Accept/Reject of downloaded recommendations: `Add to library` / `Delete` — **Delete asks for confirmation** (today a bare thumbs-down purges the file, `GrooveView.swift:1056–1063`). The implicit learning signal stays invisible to the user.
3. Accept/reject logic lives in **one** place shared with Discover (today duplicated nearly verbatim between `GrooveView.swift:1017–1078` and `DiscoveryInboxView.swift:111–181`).
4. Last.fm unconfigured → the tab says `Last.fm not configured — add an API key in Settings` instead of a German error (`SwarmRecommendationService.swift:19–36`).

**Edge Cases** — Track unanalyzed: sheet opens with the analyze CTA inline · download fails: `Download failed — Retry` inline per row (pattern exists, keep) · preview seeks to the detected drop (keep — but call it `Preview from the drop`, tooltip, not "Drop-Fokus").

## 3.12 Discover (Recommendations + Reels)

**Purpose.** One home for "new music coming in": recommendations awaiting review, and identifying tracks from videos.

**Wireframe**

```
┌──────────────────────────────────────────────────────────┐
│ Discover                    [Recommendations (4) | Reels] │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ [cover] Artist – Title      SOUNDCLOUD               │ │
│ │         Recommended because you liked "Seed Title"   │ │
│ │         [▶ Preview]        [Add to library] [Delete…]│ │
│ └──────────────────────────────────────────────────────┘ │
│ Empty: No recommendations yet — open a track's Similar   │
│ tab to find and download recommendations.                │
└──────────────────────────────────────────────────────────┘
```

**Recommendations tab** — ex-Discovery Inbox. Fixes: `Neighbor of X` → `Recommended because you liked "X"` (`DiscoveryInboxView.swift:236`); icon-only actions → labeled buttons; `Delete…` confirms (today instant purge, lines 155–163); empty state links the actual entry point (today it references a feature you must find yourself, lines 46–53); sidebar badge shows pending count.

**Reels tab** — ex-Reels Inbox, kept and focused:

| Element | Spec |
|---|---|
| Left column | Imported videos list — **persisted** (today `@State` only, everything vanishes on view switch, `ReelsInboxView.swift:54`) |
| Main flow | Watch → `Identify (Shazam)` / `Read on-screen text (OCR)` → results → `Search & download` — the flow itself is genuinely good, keep it |
| Embedded search | Scoped to resolving the identified track; not a third general search entry point |
| Qobuz banner | **Removed entirely** — the "copy 'metallica - one', open squid.wtf" personal workaround (`ReelsInboxView.swift:153–192,1917–1927`) never ships. Cookie management lives in Settings → Sources only, with honest status |
| Language | English throughout (currently German) |

**Edge Cases** — Reel with no metadata and Shazam miss → OCR path offered explicitly · identification wrong → edit search terms and re-search (existing, keep) · downloaded reel tracks land in the library with source `Reels` and normal availability vocabulary (not bespoke `downloadStatus: "remote"` strings, `ReelsInboxView.swift:952`).

## 3.13 Global Search

**Purpose.** ⌘F from anywhere: search the library, optionally fan out to connected sources, resolve pasted links, download what you find.

**Wireframe**

```
┌──────────────────────────────────────────────────────────┐
│ Toolbar: [🔍 Search library…                        ⌘F]  │
│ (on focus, detail becomes:)                              │
│ Scope: (•) Library  ( ) All sources    Mode: [Search|Link]│
│ ┌──────────────────────────────────────────────────────┐ │
│ │ Artist – Title          SoundCloud · 3:44   [↓]      │ │
│ │ Artist – Title          YouTube   · 4:01    [↓]      │ │
│ │ 2 sources unreachable — results incomplete [Details] │ │
│ └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**Rules**
1. One search entry point (the sidebar Search section is removed; the Reels-embedded search is scoped to identification, §3.12).
2. Source failures are **surfaced**, not silently skipped (today failing sources vanish, `GlobalSearchViewModel.swift:63–107`): an inline notice `2 sources unreachable — results incomplete`.
3. Results grouped by source with headers (today interleaved arbitrarily), each row: source label (brand text), duration, download action with per-row spinner.
4. Download errors show inline per row — today an error with non-empty results is invisible (`GlobalSearchView.swift:52` shows errors only when results are empty).
5. Link mode: paste any supported URL → resolve → download options; invalid input gets a specific message (existing validation, English copy).
6. All copy English (view is currently German).

**Edge Cases** — No sources connected: scope toggle hidden, link mode still works for YouTube · query matches local tracks only: results instantly, no fan-out spinner · downloading a search hit: row morphs through the standard availability states (§1.6).

## 3.14 Settings — Window, Library, Sources

**Window** — `Settings` (window title, English; today `"MLM Einstellungen"`, `AppDelegate.swift:62–79`). Tabs: **Library · Sources · Maintenance · Advanced**. Selection persistence (existing `@AppStorage`) stays.

### Library tab

| Section | Content |
|---|---|
| Library root | Path (mono, middle-truncated) + `Change…`; footer: `The root folder containing your music files. MLM scans it recursively for audio files.` |
| Storage layout (new) | Explains the managed folders: `MLM creates these folders inside your library:` — `Downloads (SoundCloud)`, `Downloads (YouTube)`, `Transcode originals` — each with a one-line purpose. This is the in-app answer to "what are these 00_ folders?" |
| Statistics | Tracks in library · Library path + `Show in Finder` |
| Import | `Re-scan Library` · `Import Folder…` + determinate progress (existing) + last result line |
| Supported formats | Badge grid incl. ALAC (keep) |

### Sources tab

Per-source connection rows (mirrors §3.5 cards: status, reconnect, disconnect) **plus** the Squid/Qobuz cookie field — moved here from its orphaned position, English copy, honest helper text: `Open qobuz.squid.wtf, complete one download (this passes the captcha), then copy the value of the 'captcha_verified_at' cookie from your browser's developer tools and paste it here.` Status: `Not configured` / `Expired — renew` / `Active` (persisted timestamp, so the status survives relaunch — today `savedAt` is session-only, `SourcesSetupView.swift:57`).

## 3.15 Settings — Maintenance & Advanced (Genre Workshop)

### Maintenance tab (all English)

| Section | Rows |
|---|---|
| Background processing | `Conservative — keeps the Mac responsive` / `Standard` / `Fast — uses all cores, fans may spin up`. **One segmented control, persisted, used by analysis, transcode, and sync.** (Replaces both `SyncTurboLevel` and the unpersisted Maintenance "Turbo Mode", `MaintenanceView.swift:22–42` + `BatchControl.swift:53–55`.) |
| Analysis | `Fingerprint all tracks` · `ReplayGain analysis` · `Danceability analysis` · `Similarity analysis (embeddings)` · `Refresh embedded artwork` · `Fetch metadata from MusicBrainz` — each with progress, **Cancel** (missing today), and its own result line (today one shared slot erases previous results, `MaintenanceView.swift:194–200`) |
| Duplicates | `Find duplicates & conflicts` — button **opens Review** and starts the scan there (no second orphan scan UI, `MaintenanceView.swift:140–149`) |
| Transcode cache | Location + `Change…` + size + `Clear cache…` (confirm) — English |
| Library repair | Organized-path migration flow (existing audit → preview → confirm → rollback — genuinely good), fully English: `Preview changes`, `n reviewed · n matched · n ambiguous`, `Apply n unambiguous changes`, `Roll back last migration…` |
| Source playlists | `Recreate linked playlist` picker + button — English |

Dependency errors stay helpful but English: `fpcalc not found — install with: brew install chromaprint`.

### Advanced tab — Genre Workshop (kept feature, new home)

The former sidebar "Groove Studio" (`GrooveStudioView.swift`) moves here unchanged in capability, renamed and re-cop​ied:

| Screen | Content |
|---|---|
| Genre grid | `Genre Workshop` — `Pick a genre to review suggestions and clean up your tags.` Cards per genre with track counts. Empty: `No genres in your library yet — tag some tracks to use the workshop.` |
| Genre detail | Dual waveform players: `Suggestions` (left, from the on-device model) / `Reference` (right); `Temperature` slider kept with a one-line plain explanation; `Suggest only untagged tracks` toggle; `% match` badges; staged saves with `Save (n)` |
| Merge | `Consolidate genres` — multi-select → `Merge into:` name field → preview of affected tracks |
| Export | `Export training set (CreateML)` — stat cards `Ready (≥50 tracks)` / `Excluded (<50 tracks)`, target `AAC 248k (.m4a)`, progress + cancel |

**Mandatory fixes:** remove the hardcoded personal `Vixa Club` tag staging (`GrooveStudioView.swift:729–737,1829`); remove the hidden reuse of the sync turbo level (line 1979 — it now reads the unified Background processing setting, and says so); English copy throughout.

## 3.16 First-Run Wizard

Keep the 4-step structure (welcome → folder → scanning → done, `FirstRunWizard.swift`) — it's solid — with these fixes:

1. Scanning step gains **`Cancel`** (today none) — cancels to the folder step, partial imports are fine (resumable).
2. Format list consistent: `MP3, FLAC, AAC, M4A, OGG, WAV, AIFF, ALAC` (wizard omits ALAC today, settings list it).
3. Done step adds a quiet orientation line: `MLM will create folders like "Downloads (SoundCloud)" inside your library when you import from sources — see Settings → Library for details.` This one sentence prevents the "00_Artists" confusion for every future user.
4. Copy already English — keep.

## 3.17 Sheets & Alerts — Catalog

| Sheet/Alert | Trigger | Spec |
|---|---|---|
| New Playlist | ⌘N / context menu | Existing popover; English; error line |
| New Playlist from Selection | Track context menu | Existing sheet (good), keep copy; fix error strings to user language |
| New Sync Profile from Selection | Track context menu | English throughout (today German labels + English buttons mixed, `SelectionCreationSheets.swift:128–271`) |
| Playlist picker (Sync) | Add in Sync detail | Title `Add playlists to profile`; **empty state required** (`No playlists — create one first`) — today blank list |
| Track picker (Sync) | Add in Sync detail | Keep filter chips (`All / Local only / With artwork`), English; loading + empty states |
| Delete playlist | Context menu | Confirm: `Delete "Name"? This does not delete any files.` |
| Remove from Library | Context menu | Confirm with file consequence: `Move n files to the Trash? You can restore them from there.` |
| Delete recommendation | Discover / Similar | Confirm: `Delete this file from disk?` |
| Delete sync profile | Sync list | Confirm (new — today none) |
| Import result | Remote import | §3.6 step 3 |
| Error banner (in-screen) | any | Plain cause + action + `Details` disclosure linking to Logs |

Pattern rules: **every destructive action confirms**; every confirmation states the consequence and the escape (Trash/Undo); no alert ever contains a raw error code, a database ID, or an internal token.

---

# Part 4 — Background Processing & Status Model

The experiential goal: **when the user opens a preview or starts a sync, the answer is already there.** The infrastructure largely exists (`PerformanceQueueService` — prioritized serial queue, downloads preempt analysis, cooperative suspension). This part defines what computes when, and what shows where.

## 4.1 What is pre-computed in the background

| Work item | Trigger | Invalidation | Priority |
|---|---|---|---|
| Sync preview per profile | Profile/content change (debounced 1 s), device mount, after sync completes | Any change to content, settings, or device availability | Below playback/download, above analysis |
| Transcode pre-warming (cache fill) | Preview shows pending AAC tracks; idle time | Track deleted or settings changed | Lowest; pauses during playback and downloads |
| Track analysis (fingerprint → ReplayGain → embeddings) | After import/download (existing behavior — keep) | File changed | Lowest, serial |
| Duplicate scan | Manual only (scans compare everything; too expensive for idle) | — | User-initiated |

## 4.2 Rules

1. **Playback and UI always win.** Background work yields; on battery, `Conservative` is suggested once.
2. **One concurrency setting** (`Background processing: Conservative / Standard / Fast`, Settings → Maintenance) governs analysis, transcode, and sync workers. No second hidden knob anywhere; nothing may silently borrow it (the GrooveStudio CreateML export reads it openly and labels the fact).
3. **Every job is visible, pausable, cancelable** in the Activity panel; sync additionally in its detail view.
4. **Failure is persisted and explained** — a job that fails while the app was closed appears in Activity → Recent with its reason on next launch.
5. **No work starts without an accounting**: the user can always answer "what is the app doing right now and why" from the Activity header alone.

## 4.3 Where status appears (summary matrix)

| Status | Sidebar | Toolbar | Screen | Activity |
|---|---|---|---|---|
| Download running/failed | — | — | Status column + playlist status line | Header + Downloads section |
| Sync running | Spinner dot on Sync | — | Inline in detail | Header + Sync section |
| Analysis pending | — | — | Inspector Audio tab (per track) | Analysis section |
| Preview stale | — | — | Sync detail status line | — (too minor) |
| Source expired | Amber dot on Sources | — | Sources + linked playlist headers | — |
| Drive offline | Red dot on Library | — | Banner in Library/Folders | — |
| Review pending | Badge `5 dup · 2 conf` | — | Review | — |
| Recommendations pending | Badge on Discover | — | Discover | — |

Nothing appears in two chrome locations at once; nothing important appears only in chrome.

---

# Part 5 — Copy Deck (binding English strings)

The canonical strings. Anything in the app not listed here follows the same voice: sentence case, plain, no jargon.

## 5.1 Navigation & chrome

| Element | String |
|---|---|
| Sidebar | `Library` · `Playlists` · `Folders` · `Sync` · `Sources` · `Review` · `Discover` · `Settings` |
| Toolbar search | `Search library…` |
| Player idle | `Not Playing` |
| Activity empty | `No active operations` / `Downloads, imports, and sync jobs appear here` |
| Settings window title | `Settings` |

## 5.2 Status vocabulary (from §1.6 — repeated here as the copy source of truth)

`Local` · `Downloading…` · `Not downloaded` · `Download failed` · `File missing` · `Importing · n of m` · `Incomplete · n failed` · `Linked to SoundCloud` / `…YouTube` / `…Spotify` · `Connected` · `Disconnected` · `Sign-in expired` · `Reconnect`

## 5.3 Imports & downloads

| Context | String |
|---|---|
| YouTube card | `Paste a playlist URL to download tracks.` |
| Import sheet | `Import YouTube Playlist` · `Load` · `Loading playlist…` · `Download n tracks` · `Save without downloading` · `Metadata completes after download` |
| Import result | `n downloaded · m failed` · `Show failed` · `Open playlist` |
| Failure reasons | `Video unavailable` · `Video unavailable in your region` · `Private video` · `yt-dlp not installed — open Settings` · `Network error — will retry automatically` |
| Retry | `Retry` · `Retry all` · `n attempts left` |
| Playlist status line | `n of m tracks downloaded` · `Nothing downloaded yet` · `Download all (m)` · `Download missing (n)` |

## 5.4 Review

| Context | String |
|---|---|
| Empty | `Find duplicates and conflicts` · `The scan compares audio fingerprints. It never deletes or changes anything on its own.` · `Run scan` |
| Group header | `n versions of "Title" — Artist` |
| Reasons | `Identical recording (audio fingerprint n% match)` · `Same recording, different version` · `Same recording, metadata differs` |
| Recommendation | `Recommended: keep Version 1 — lossless, complete tags` |
| Actions | `Keep recommended` · `Choose manually` · `Keep all — not duplicates` · `Move unkept files to Trash` · `Never suggest again` · `Undo` |
| Conflict | `Metadata conflict · same recording (n% match)` · `Use all from A` / `Use all from B` · `These are different versions — keep both` · `After merge:` · `Affects: database only` / `…file will be renamed` |

## 5.5 Sync

`New Sync Profile` · `Name` · `Output folder` · `Browse…` · `Detect device…` · `No devices found — is it connected?` · `Rockbox device detected — device defaults applied` · `Preview: up to date · computed 2 min ago` · `Preview: updating… n/m` · `Device not connected — preview unchecked` · `Add` / `Remove` / `≈ new size` / `Available` · `Not enough space on device — need ≈4.2 GB, 1.0 GB available` · `Syncing… n of m` · `Copying:` / `Transcoding:` · `Pause` · `Cancel` · `n synced · m failed` · `Failed tracks (n)`

## 5.6 Settings

`Background processing` · `Conservative — keeps the Mac responsive` · `Standard` · `Fast — uses all cores, fans may spin up` · `Storage layout` · `MLM creates these folders inside your library:` · `Find duplicates & conflicts` (opens Review) · `Managed by MLM` · `Show in Finder` (all Finder actions; replaces `In Finder anzeigen`)

## 5.7 Discover

`Recommendations` · `Reels` · `Recommended because you liked "Title"` · `Add to library` · `Delete…` · `Delete this file from disk?` · `No recommendations yet — open a track's Similar tab to find and download recommendations.` · `Identify (Shazam)` · `Read on-screen text (OCR)` · `Last.fm not configured — add an API key in Settings`

## 5.8 Explicit removals (strings that must not survive)

`Sync CPU-Leistung` · `Turbo: 80%` · `(8/10 Cores)` · `Synced` (cloud label) · `Stream` (format column) · `Fingerprint Match` · `(kept_higher_quality)` · `(flagged)` · `Track A` / `Track B` · `Track #123` · `Duplikat` / `Variante von` · `Lokal` / `Remote` (status) · `Swarm Intelligence` · `Vector Gravity` · `Warp Embeddings` · `Drop-Fokus` · `Groove Studio 🚀` · `Sichere Pfad-Migration…` · `In Papierkorb verschieben` · `Sync zu ▸` · `Import M3U8 Datei…` · `Qobuz Cookie fehlt/abgelaufen` banner copy · `metallica - one` clipboard hack · `download failed` · `Playlist konnte nicht importiert werden.`

---

# Part 6 — Acceptance Checklist (user-observable)

A release conforms to this document when all of the following are true:

**Trust & states**
- [ ] A 44-track YouTube import shows live progress, ends in a clear result, and any failed track is listed with a plain-language reason and a Retry action — still visible after an app restart.
- [ ] Placeholder metadata is visually distinct from real metadata everywhere it can appear.
- [ ] Every track's availability (§1.6) is readable from its row without opening anything.
- [ ] A deleted-from-disk file surfaces as `File missing` with a recovery action, not a playback crash.

**Provenance & organization**
- [ ] Every playlist states its origin and local availability in words (`Linked to YouTube · 38 of 44 downloaded`).
- [ ] App-managed folders are named, grouped, and explained in-app (Settings → Library); no bare `00_*` buckets are created at launch.
- [ ] Files present on disk but absent from the library are reported, never hidden.

**Review**
- [ ] Every duplicate group shows why it matched, a scored recommendation with justification, per-version preview, and Undo.
- [ ] Nothing is marked as duplicate before the user decides.
- [ ] Every metadata conflict shows the differing fields, both values, per-field choice, and the merge consequence.

**Performance feel**
- [ ] Opening a sync profile never shows a blocking spinner for the preview; a cached result appears instantly, updates in the background with a determinate counter.
- [ ] Everything the app does in the background is visible, pausable, and cancelable in one place.
- [ ] No control in the window chrome displays a percentage that could be mistaken for live CPU usage.

**Consistency**
- [ ] The sidebar has exactly 7 items + Settings; no concept appears twice; every user-facing string is English and jargon-free (§5.8 list verified empty).
- [ ] Every destructive action confirms and names its consequence; every confirmation offers an escape.
- [ ] No permanently disabled control, dead menu item, or unreachable alert ships.

---

*End of document. Changes to this file are design decisions — make them deliberately, in writing, here first.*

