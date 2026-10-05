# Library view, shared track table, track context menu & track presentation primitives

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): LIB, SEL, TRACK · Files covered: `MLM/Views/Library/LibraryView.swift`, `MLM/Views/Library/LibraryTable.swift`, `MLM/Views/Library/TrackTable.swift`, `MLM/Views/Library/TrackContextMenu.swift`, `MLM/Views/Library/EnergyBars.swift`, `MLM/Views/Library/DanceabilitySteps.swift`, `MLM/Views/Shared/StatusChip.swift`, `MLM/Views/Shared/TrackCoverView.swift`, `MLM/Views/Shared/TrackMetadataPresentation.swift`, `MLM/Views/Shared/TrackPresentationAvailability.swift`, `MLM/Views/Shared/DownloadRetryBudget.swift`, `MLM/Views/Shared/SelectionCreationSheets.swift`, `MLM/Views/Shared/SpringLoadableHover.swift`, `MLM/ViewModels/LibraryViewModel.swift`, `MLM/Services/Artwork/ArtworkBackfillService.swift`, `MLM/Services/Artwork/ArtworkResolver.swift`

Reading note for the designer: "Local" = the track row has a stored file path (`organized_path`), "Remote" = it has none (a linked track from SoundCloud/YouTube/Spotify etc. that was never downloaded). The library has ~12,935 tracks (ROADMAP §0.2). The track table is one shared component used in five places; the right-click menu is one shared menu used in eight places.

## Surfaces

### V-LIB — Library
- Reached via: sidebar item `Library` (P-SIDEBAR) · ⌘1 (M-NAVIGATE) · the app's default section at launch · spring-loaded hover while dragging a track over the sidebar `Library` row (D-LIB-SPRING) · Leads to: P-INSPECTOR (double-click), P-PLAYER (double-click / `Play` / `Shuffle`), V-QUEUE (`Play Next`), S-SEL-NEWPLAYLIST, S-SEL-NEWSYNCPROFILE, A-TRACK-REMOVE, A-TRACK-REMOVE-FAILED, Finder (`Show in Finder`), P-ACTIVITY (downloads, re-scan), V-SEARCH (Return in the toolbar search field replaces this view with the global search results)
- Code: `MLM/Views/Library/LibraryView.swift:7-216` (container, header, banner, toolbar), `MLM/Views/Library/LibraryTable.swift:9-82` (library wrapper), `MLM/Views/Library/TrackTable.swift:14-332` (the table itself), `MLM/ViewModels/LibraryViewModel.swift:43-293` (view model), `MLM/Database/TrackRepository.swift:152-169,208-264` (counts, SQL filter/sort), `MLM/Views/ContentView/ContentView.swift:340-352,394-404,510-535` (kept-alive host, double-click handler)
- Purpose: browse, search and act on every track in the open library — the files on disk ("Local") and the linked-but-not-downloaded tracks ("Remote").
- User goals (jobs to be done):
  1. Find a track and play it, continuing through the visible list — daily (double-click plays with the visible order as queue, `MLM/Views/ContentView/ContentView.swift:394-404`).
  2. Hear something without choosing: shuffle the current list — daily *(inferred from the `Shuffle` toolbar button, `MLM/Views/Library/LibraryView.swift:103-116`)*.
  3. Put a multi-selection into a playlist or a sync profile — daily/weekly (`MLM/Views/Library/TrackContextMenu.swift:86-157`; daily-driver wish "bulk actions on multi-selection", `.planning/PROJECT.md:41`).
  4. See which linked tracks are not downloaded / failed, and download them — weekly (Remote tab + `Download n missing tracks`, `MLM/Views/Library/TrackContextMenu.swift:174-184`).
  5. Check newly added music (default sort = `Added`, newest first) — daily/weekly (`MLM/ViewModels/LibraryViewModel.swift:72`).
  6. Sort/scan by energy, danceability, BPM, genre, year to pick tracks for a set — weekly *(inferred from the DJ-oriented columns, `MLM/Views/Library/TrackTable.swift:194-209`)*.
  7. Clean up: remove tracks (moves local files to Trash) — rare (`MLM/Views/Library/TrackContextMenu.swift:186-193`).
  8. Locate the file on disk / copy its path — weekly (`MLM/Views/Library/TrackContextMenu.swift:161-172`).
  9. Pick up changes made on disk (`Re-scan Library`, ⌘R) — rare/weekly (`MLM/Views/Library/LibraryView.swift:117-132`).
  10. Preview a track with the spacebar while browsing — daily **wish, does not exist** (`.planning/PROJECT.md:40`, `.planning/REQUIREMENTS.md:188-190`).
- What the user wants to see, in priority order (information, not layout):
  1. Title / artist (with now-playing marker) and whether the track can be played right now (availability).
  2. Why a track can't be played (not downloaded / download failed + reason + attempts left / file missing / drive disconnected) and the one action that fixes it.
  3. DJ-relevant attributes: BPM, energy, danceability, genre, time.
  4. Album (but: 48 % of tracks have album `unknown album` — ROADMAP §0.3 — so the column is mostly noise today).
  5. Quality: format, kbps.
  6. When it was added.
  7. How many tracks are in the current view / selected (not shown today — only per-tab totals).
- Elements today:
  - V-LIB.E01 — Header title `Library` (`MLM/Views/Library/LibraryView.swift:142-144`).
  - V-LIB.E02 — Segmented control (hidden label `Source`) with two segments `Local (n)` and `Remote (n)`; n = total count of tracks with / without a stored path, **not** affected by search (`MLM/Views/Library/LibraryView.swift:146-169`, `MLM/ViewModels/LibraryViewModel.swift:24-36`, `MLM/Database/TrackRepository.swift:152-169`). Switching tabs clears the selection and refetches (`MLM/ViewModels/LibraryViewModel.swift:52-59`).
  - V-LIB.E03 — Drive-disconnected banner, shown only when the library drive is unmounted: icon `externaldrive.badge.exclamationmark` + `Library drive is disconnected. Local tracks remain visible but cannot be played.` (`MLM/Views/Library/LibraryView.swift:77-89`).
  - V-LIB.E04 — Toolbar button `Shuffle` (icon `shuffle`, tooltip `Shuffle play library`), disabled when the list is empty; shuffles **the currently displayed rows** (tab + search filter) and plays (`MLM/Views/Library/LibraryView.swift:103-116`, `MLM/ViewModels/PlaybackViewModel.swift:145-150`).
  - V-LIB.E05 — Toolbar button `Re-scan Library` (icon `arrow.clockwise`, tooltip `Re-scan the library folder for changes`, ⌘R → K-LIB-RESCAN); while running the label is replaced by a small spinner and the button is disabled (`MLM/Views/Library/LibraryView.swift:117-132,173-182`).
  - V-LIB.E06 — The track table (shared component `TrackTable`, see "Shared component" below), filled by `LibraryTable` (`MLM/Views/Library/LibraryTable.swift:30-73`).
  - Columns, in order (header label verbatim · what it shows · sortable · width behaviour) — `MLM/Views/Library/TrackTable.swift:116-217`:
    - V-LIB.E07 — `Title` · 18 pt cover thumbnail (V-TRACK-PRIMITIVES.E02) + animated speaker icon `speaker.wave.2.fill` and accent-coloured title **only while the row's track is playing** (paused = no marker) + title, one line · sortable · resizable (min 160, ideal 280) (`MLM/Views/Library/TrackTable.swift:119-137,291-299`).
    - V-LIB.E08 — `Artist` · artist, one line; import placeholders rendered muted italic with tooltip (V-TRACK-PRIMITIVES.E03) · sortable · resizable (min 100, ideal 180) (`MLM/Views/Library/TrackTable.swift:139-142`).
    - V-LIB.E09 — `Album` · album in secondary colour, same placeholder treatment · sortable · resizable (min 100, ideal 180) (`MLM/Views/Library/TrackTable.swift:144-147`). The literal value `unknown album` (6,209 tracks) is **not** in the placeholder list and renders as normal text (`MLM/Views/Shared/TrackMetadataPresentation.swift:7-17`).
    - V-LIB.E10 — `Time` · `m:ss` (minutes not wrapped into hours), `—` if unknown, monospaced digits · sortable · fixed 54 pt (`MLM/Views/Library/TrackTable.swift:149-154`, `MLM/Models/Track.swift:193-198`).
    - V-LIB.E11 — `Format` · stored format uppercased (e.g. `FLAC`, `M4A`), `—` if empty · sortable · fixed 60 pt. For remote rows the stored format can be a source name (code elsewhere treats `format == "soundcloud"`/`"youtube"` as a source, `MLM/Views/Shared/TrackMetadataPresentation.swift:27-31`), so `SOUNDCLOUD`/`YOUTUBE` can appear here *(inferred from data model)* (`MLM/Views/Library/TrackTable.swift:156-160,301-304`).
    - V-LIB.E12 — `Status` · availability chip (V-TRACK-PRIMITIVES.E01); empty for a verified local file · **not sortable** · fixed 90 pt (`MLM/Views/Library/TrackTable.swift:162-169`).
    - V-LIB.E13 — `kbps` · bitrate number or `—` · sortable · fixed 48 pt (`MLM/Views/Library/TrackTable.swift:173-178`).
    - V-LIB.E14 — `Genre` · genre or `—` · sortable · resizable (min 70, ideal 110) (`MLM/Views/Library/TrackTable.swift:180-185`).
    - V-LIB.E15 — `Year` · year or `—` · sortable · fixed 48 pt (`MLM/Views/Library/TrackTable.swift:187-192`).
    - V-LIB.E16 — `Energy` · 5-bar meter (V-TRACK-PRIMITIVES.E04) or `—` · sortable · fixed 56 pt (`MLM/Views/Library/TrackTable.swift:194-197`).
    - V-LIB.E17 — `Dance` · 5-dot danceability meter (V-TRACK-PRIMITIVES.E05) or `—` · sortable · fixed 56 pt (`MLM/Views/Library/TrackTable.swift:199-202`).
    - V-LIB.E18 — `BPM` · integer or `—` · sortable · fixed 48 pt (`MLM/Views/Library/TrackTable.swift:204-209`).
    - V-LIB.E19 — `Added` · date as `MMM d` (e.g. `May 7`) **without year**; `—` if none; Local tab shows the date the file landed in the library (falls back to source date), Remote tab shows the source/liked date · sortable (default, newest first) · fixed 78 pt (`MLM/Views/Library/TrackTable.swift:211-216,306-331`, `MLM/Database/TrackRepository.swift:238-251`).
    - No column can be hidden or shown (no column-customisation binding); no `#` column; widths and order are not persisted (`MLM/Views/Library/TrackTable.swift:117`). Column reordering by dragging headers: see "Unresolved from code".
  - V-LIB.E20 — Loading state: large spinner + `Loading tracks…` (replaces the whole table) (`MLM/Views/Library/TrackTable.swift:101-102,271-278`).
  - V-LIB.E21 — Error state: `Failed to load tracks` (icon `exclamationmark.triangle.fill`) + raw error text (`MLM/Views/Library/TrackTable.swift:103-104,280-286`).
  - V-LIB.E22 — Empty state (no search): `No local tracks` + `Import music or download from Remote to get started.` (Local tab) / `No remote tracks` (Remote tab, no description); no buttons (`MLM/Views/Library/LibraryTable.swift:49-60`).
  - V-LIB.E23 — Filtered-empty state: system search-unavailable view for the query (macOS standard "No Results for “…”" text) (`MLM/Views/Library/LibraryTable.swift:61-63`).
  - V-LIB.E24 — Pre-init placeholder `Initializing…` with spinner, shown until the view model is attached (`MLM/Views/Library/LibraryView.swift:33-36`).
  - Not an element of this view but drives it: the toolbar search field (V-SEARCH, owned by main.md) live-filters this table after 200 ms idle; multi-word queries are AND-ed; matched against artist, album artist, album, title, genre and format, accent/case-insensitive (`MLM/Views/Library/LibraryView.swift:41,98-101`, `MLM/ViewModels/LibraryViewModel.swift:62-69`, `MLM/Database/TrackRepository.swift:223-231`, `MLM/Database/DatabaseManager.swift:767-784`). Pressing Return opens the global search pane instead (`MLM/ViewModels/SearchCoordinator.swift:39-60`). Changing sidebar section clears the query (`MLM/Views/ContentView/ContentView.swift:199-211`).
- Interactions:
  - Click / ⇧-click / ⌘-click / ⌘A: native table multi-selection (selection = set of track IDs, `MLM/ViewModels/LibraryViewModel.swift:80`). Selection survives search/sort refreshes; cleared on tab switch. Single selection does **not** update the inspector.
  - Double-click (table primary action): opens the inspector (P-INSPECTOR) for the clicked track **and**, if the row has a stored path, plays it with all visible rows after it as the queue (`MLM/Views/Library/TrackTable.swift:239-244`, `MLM/Views/ContentView/ContentView.swift:394-404`, `MLM/ViewModels/PlaybackViewModel.swift:132-141`). Remote row: inspector only, no message. File-missing row: playback is attempted and fails with `Playback unavailable: ‹title› — file could not be found on disk.` (`MLM/ViewModels/PlaybackViewModel.swift:180`; where it is shown belongs to P-PLAYER).
  - Right-click (row or selection) → CM-TRACK.
  - Header click → SQL re-sort, ascending/descending toggle; Status column not sortable (`MLM/Views/Library/TrackTable.swift:245-264`, `MLM/Views/Library/LibraryTable.swift:34-36`).
  - Keyboard → K-LIB-RESCAN (⌘R); ←/→ seek ±5 s window-wide (M-PLAYBACK / shell.md, `MLM/App/MLMApp.swift:67-72`); spacebar → nothing (K-LIB-SPACE, missing); Delete key → nothing (K-LIB-DELETE, missing); ⌘I `More Info` → nothing (posts a notification no view observes, `MLM/App/MLMApp.swift:183-188`, `MLM/Utilities/Notifications.swift:115`).
  - Drag rows out → D-LIB-TRACK-OUT; sidebar spring-loading → D-LIB-SPRING; expected-missing → D-LIB-FINDER-IN, D-LIB-TO-FINDER, D-LIB-TO-SIDEBAR-NEWPL, D-LIB-TO-QUEUE.
  - Hover/tooltips: only on placeholder artist/album values. No tooltip on status chips (failure reason/date/attempts are never shown here), none on truncated titles.
- States:
  - Default: table of the current tab, sorted `Added` newest first.
  - Empty: V-LIB.E22 (no import button — import lives in the menu `Import from Folder…` ⇧⌘I, M-LIBRARY).
  - Loading: V-LIB.E20 replaces the table on **every** refresh (tab switch, search keystroke after debounce, sort change, download completion), so the whole table blinks to a spinner and back (`MLM/ViewModels/LibraryViewModel.swift:135-137`, `MLM/Views/Library/TrackTable.swift:101-102`).
  - Error: V-LIB.E21 with raw error text, no retry action.
  - Drive not connected: banner V-LIB.E03 appears; rows stay. Status chips are **not** recomputed on unmount/mount (the view does not observe those events), so after unplugging, local rows keep showing no chip until something triggers a refresh, after which every local row shows `File missing`; after re-plugging they keep showing `File missing` until the next refresh (`MLM/Views/Library/LibraryView.swift:50-69` observes import/root/delete/download/playlist/profile only; `MLM/Views/ContentView/ContentView.swift:127-137`; `MLM/Models/Track.swift:138-172`). Playback is paused on unmount (`MLM/Views/ContentView/ContentView.swift:127-133`).
  - Filtered-empty: V-LIB.E23. Tab counts still show unfiltered totals.
  - Huge data: all rows of a tab are fetched without a limit and handed to a native table (see Data scale).
  - Background work: downloads → rows change only when the whole batch ends (`.downloadDidComplete`), then downloaded rows disappear from Remote and appear in Local; mid-batch `Downloading…` chips appear only if some other refresh happens (`MLM/Views/Library/LibraryView.swift:61-63`, `MLM/ViewModels/DownloadViewModel.swift:560-577`). Re-scan → spinner in E05 only. Artwork backfill → covers pop in row by row, no progress shown (V-TRACK-PRIMITIVES.E02).
  - Library not configured / no library root: availability is shown as Local without verification (no `File missing` flash) (`MLM/Views/Shared/TrackPresentationAvailability.swift:14-23`).
- Data scale / performance notes:
  - ~12,935 tracks split across the two tabs (split not in ROADMAP). Whole tab fetched by SQL each refresh, then row wrappers rebuilt (`MLM/Views/Library/LibraryTable.swift:67-81`), then **one file-existence check per local row** on every refresh — i.e. thousands of disk probes on the external drive per search keystroke (`MLM/ViewModels/LibraryViewModel.swift:162-168`).
  - The Library view is kept alive and hidden (opacity 0) when other sections are shown, to avoid a ~0.5 s rebuild of the ~12,000-row table (`MLM/Views/ContentView/ContentView.swift:340-352,510-535`). Return to Library is instant if tab/search/sort/root unchanged (`MLM/ViewModels/LibraryViewModel.swift:210-241`).
  - Right-click builds the menu by scanning all rows (`MLM/Views/Library/TrackTable.swift:227`, `MLM/Views/Library/TrackContextMenu.swift:19-24`).
  - Double-click queues every visible row after the clicked one (capped by the playback queue's context cap, `MLM/ViewModels/PlaybackViewModel.swift:132-141`).
- Pain points today:
  - No way to list only failed / missing / not-downloaded tracks: Status is neither filterable nor sortable, tabs only split Local/Remote (`MLM/Views/Library/TrackTable.swift:162-169`; UI-GROUNDTRUTH §1.6).
  - Failure reason, date and retry budget never visible in Library; failed rows not dimmed (UI-GROUNDTRUTH §1.6 rules vs `MLM/Views/Shared/StatusChip.swift:25-30`; `DownloadRetryBudget` is only used in Playlist detail, `MLM/Views/Playlists/PlaylistDetailView.swift:618`).
  - `Re-scan Library` (⌘R) does nothing per code reading: the import view model it creates never loads the library root, so `importLibrary()` exits with an unseen `No library root configured` (`MLM/Views/Library/LibraryView.swift:205-214`, `MLM/ViewModels/ImportViewModel.swift:49-57,63-69,96-100`).
  - Drive unplug/replug does not refresh availability (see States) — UI-007 is only partly addressed (banner exists, root change observed).
  - No spacebar preview (core daily-driver wish, `.planning/PROJECT.md:40`); Playback menu `Play`/`Pause` has no shortcut (`MLM/App/MLMApp.swift:120-123`).
  - Whole-table spinner on every refresh (search typing feels like reloading).
  - `Added` shows no year; `Album` dominated by `unknown album` (48 %); Format may show source names for remote rows.
  - No visible count of results/selection.
  - `Shuffle` on the Remote tab shuffles remote rows that cannot play (first pick likely fails) (`MLM/Views/Library/LibraryView.swift:107`, `MLM/ViewModels/PlaybackViewModel.swift:145-150`).
  - Double-click on non-playable rows: no contextual action (UI-GROUNDTRUTH §1.6 rule 3, §3.1 Interactions).
  - The Library view stays mounted while hidden, so its toolbar items (`Shuffle`, `Re-scan Library` ⌘R) may also appear/act in other sections and ⌘R collides with Sync detail `Refresh` ⌘R (`MLM/Views/Sync/SyncProfileDetailView.swift:144`) *(inferred; verify on Mac)*.
  - Sorting text columns uses SQLite default ordering without case folding (no `COLLATE` in schema) *(inferred; verify)* (`MLM/Database/TrackRepository.swift:253-258`).
- Related flows: daily-listening, find-fast, build-playlist, fix-failed-downloads, drive-unplugged, albums-future, edit-metadata (via inspector), sync-device (`Sync to ▸`), library-cleanup (remove).
- Constraints / locked decisions: native macOS look only (system colours/materials) — today the table uses custom `mlm*` colours and a custom violet gradient for Dance; critical states always text (Status chips have text — keep); one meaning per word (glossary: `Not downloaded`, `Download failed`, `File missing`, `Library folder`); English only; native toolbar stays; one active library per process.
- Open questions for the designer:
  1. Should availability be a filter (e.g. "show only Download failed"), a sort, a separate view, or all three?
  2. Is `Local`/`Remote` the right top-level split, given the glossary words `Not downloaded`/`Linked to ‹Source›`?
  3. Which columns earn default visibility at 13k rows for a DJ, and should the user be able to hide/reorder/persist them?
  4. What should double-click do on a remote / failed / missing row?
  5. How should the drive-disconnected state look on 12k local rows — banner only, dim rows, or a single "drive" state instead of 12k `File missing` chips?
  6. Where do result and selection counts belong?
  7. What should spacebar do (Quick Look-style preview vs. play/pause of main player)?
  8. How should `unknown album` / missing album be shown until albums exist (Track C)?
  9. Should `Shuffle` and `Re-scan Library` live in the Library view, the toolbar, or menus?

### V-TRACK-TABLE — Shared track table (component, not a sidebar view)
- Reached via: embedded in V-LIB, V-SEARCH (global search results), V-QUEUE (three tables: history, now playing, up next) · Leads to: CM-TRACK, P-INSPECTOR / P-PLAYER (double-click, per embedder)
- Code: `MLM/Views/Library/TrackTable.swift:14-332`
- Purpose: one consistent row look and behaviour for track lists ("search rows behave exactly like library rows", `MLM/Views/Library/TrackTable.swift:7-10`).
- Embedders (grep `TrackTable(` in `MLM/Views`):
  | Embedder | ID | Code | Differences |
  |---|---|---|---|
  | Library | V-LIB | `MLM/Views/Library/LibraryTable.swift:31-66` | Full: SQL sort, Status chips, playlists + sync profiles in CM-TRACK, custom empty state |
  | Global search results | V-SEARCH (main.md) | `MLM/Views/Search/GlobalSearchPresentationView.swift:122-140` | No sort handler → header clicks change the arrow but not the order; no availability map → **Status column always empty**; no sync-add handler → choosing a profile under `Sync to ▸` does nothing |
  | Queue · History | V-QUEUE (main.md) | `MLM/Views/Queue/PlaybackQueueView.swift:72-83` | No playlists/profiles passed → `No playlists` / `No sync profiles — create one first`; Status empty; sorting inert; empty `No history yet` |
  | Queue · Now playing | V-QUEUE | `MLM/Views/Queue/PlaybackQueueView.swift:95-106` | One row, 64 pt tall table; empty `Nothing playing` |
  | Queue · Up next | V-QUEUE | `MLM/Views/Queue/PlaybackQueueView.swift:118-129` | Same as History; empty `Queue is empty`; full CM-TRACK incl. `Remove from Library` |
  Not embedders (own tables that reuse the primitives and CM-TRACK): Playlist detail `PlaylistTable` (V-PLD, `MLM/Views/Playlists/PlaylistTable.swift:131-146`), Folders track list (V-FOLD, `MLM/Views/Folders/FoldersView.swift:574-645`), Genre Workshop in Settings → Advanced (ST-ADV, `MLM/Views/TrackDetail/GrooveStudioView.swift:775,981,1291`).
- Elements today: the 13 columns V-LIB.E07–E19; loading/error/empty states V-LIB.E20–E23; row drag source (D-LIB-TRACK-OUT); context menu (CM-TRACK); primary action (double-click). Configuration knobs: `playlist` + `onRemoveFromPlaylist` (adds `Remove from Playlist` to CM-TRACK — no current embedder passes them), `dragSourcePlaylistID` (always nil in embedders), `contextMenuAllowsLibraryActions` (never set to false anywhere → dead flag) (`MLM/Views/Library/TrackTable.swift:41-49,93`).
- States: loading replaces the table; error replaces the table; empty shows embedder's content (`MLM/Views/Library/TrackTable.swift:99-112`).
- Pain points: behaviour differs silently per embedder (sorting inert, Status blank, sync-add no-op); Queue tables offer destructive `Remove from Library`; header sort arrow initialised to `Added` descending in every embedder even where rows are not sorted that way (`MLM/Views/Library/TrackTable.swift:26-28`).
- Open questions for the designer: Should every track list share exactly one column set and one menu, or should each context (queue, search, playlist, folder) declare its own? Which actions are inappropriate in the Queue?

### V-TRACK-PRIMITIVES — Track presentation primitives (component catalogue)
- Reached via: rows/headers in V-LIB, V-SEARCH, V-QUEUE, V-PLD, V-FOLD, P-INSPECTOR, P-PLAYER, V-INBOX, ST-ADV.
- Code: `MLM/Views/Shared/StatusChip.swift:1-46`, `MLM/Views/Shared/TrackCoverView.swift:27-219`, `MLM/Views/Shared/TrackMetadataPresentation.swift:1-70`, `MLM/Views/Library/EnergyBars.swift:11-42`, `MLM/Views/Library/DanceabilitySteps.swift:15-58`, `MLM/Views/Shared/TrackPresentationAvailability.swift:4-32`, `MLM/Views/Shared/DownloadRetryBudget.swift:5-16`, `MLM/Models/Track.swift:138-190`, `MLM/Models/TrackAvailability.swift:82-142`
- Elements today:
  - V-TRACK-PRIMITIVES.E01 — **Status chip** (capsule: icon + text, tinted background at 15 %). Vocabulary verbatim, mapped against UI-GROUNDTRUTH §1.6 / §5.2:
    | Availability (code) | Chip text | Icon | Tint | Data rule in code | §1.6 match |
    |---|---|---|---|---|---|
    | `local` | *(no chip)* | — | — | stored path AND file exists (organized path under library root, else original path) | matches; but when the library root is not yet known the row is treated as Local unverified (`MLM/Views/Shared/TrackPresentationAvailability.swift:14-23`) |
    | `downloading` | `Downloading…` | `arrow.down.circle` | `mlmActive` | no path AND `download_status` in downloading/queued/in_progress | text/icon match; but Library only refreshes at batch end, so rarely seen there |
    | `notDownloaded` | `Not downloaded` | `icloud` | `mlmInkMuted` | no path, no failure record | matches; §1.6 says "never attempted", code also lands here for `remote`/`completed`/unknown statuses |
    | `failed(reason, date, attempts)` | `Download failed` | `exclamationmark.arrow.circlepath` | `mlmAttention` | no path AND failure record (or legacy status `failed`/`error` → reason `Download failed`, 1 attempt) | chip matches; §1.6 dimming + "n attempts left" **not implemented in Library** (only in V-PLD) |
    | `fileMissing` | `File missing` | `doc.questionmark` | `mlmError` | stored path but neither organized nor original file exists | matches; also produced for every local row when the drive is unplugged (no separate "drive offline" state) |
    Code: `MLM/Views/Shared/StatusChip.swift:17-34`, `MLM/Models/Track.swift:138-190`. No tooltip/accessibility detail beyond the text (`MLM/Views/Shared/StatusChip.swift:36-45`). Other `StatusChip` uses with free text: Playlist card and Playlist detail (owned by playlists.md; `MLM/Views/Playlists/PlaylistCard.swift:229-235`, `MLM/Views/Playlists/PlaylistDetailView.swift:575-586`).
  - V-TRACK-PRIMITIVES.E02 — **Cover** (`TrackCoverView`): states — (a) artwork image (fades in over 0.2 s); (b) placeholder = diagonal gradient (custom "Solar" colours `mlmBase`→`mlmRaised`) with a `music.note` symbol, used for: still loading, no artwork known, artwork file vanished (self-repair triggered once per session, max 2 concurrent), remote tracks (no artwork path is ever resolved for remote tracks in tables — `ArtworkResolver.resolveArtworkURL` has no callers), previews with loading disabled. There is no distinct loading vs. no-art appearance (`MLM/Views/Shared/TrackCoverView.swift:39-69,76-136,193-207`). Covers update live when background extraction finishes for that track (`MLM/Views/Shared/TrackCoverView.swift:51-58`, `MLM/Services/Artwork/ArtworkBackfillService.swift:403-411`). Sizes used: 18 pt in tables, 40/56 pt player bar & inspector (callers frame it).
  - V-TRACK-PRIMITIVES.E03 — **Metadata text with placeholder treatment** (`TrackMetadataText`): values `youtube`, `soundcloud likes`, `discovered neighbors`, `reels inbox imports`, `downloads`, `unknown` (case-insensitive) render muted + italic with tooltip `Placeholder from import — will update after download`; others normal (`MLM/Views/Shared/TrackMetadataPresentation.swift:4-17,44-70`). Also `sourceName` maps a track to `Reels` / `SoundCloud` / `YouTube` / `Qobuz` / `DABmusic` / `Local import` — used by Folders and the inspector, not by V-LIB (`MLM/Views/Shared/TrackMetadataPresentation.swift:19-40`).
  - V-TRACK-PRIMITIVES.E04 — **Energy bars**: 5 bars of rising/falling height (8-12-16-12-8 pt), first *level* bars filled with accent colour whose opacity grows with level, rest in system quaternary; `—` when no value (`MLM/Views/Library/EnergyBars.swift:11-42`). Level comes from loudness analysis (energy bucket 1–5).
  - V-TRACK-PRIMITIVES.E05 — **Danceability dots**: 5 dots, first *level* filled with a hard-coded violet gradient + glow; score 0–1 mapped to 1–5 (≤0.2→1 … >0.8→5); `—` when no value (`MLM/Views/Library/DanceabilitySteps.swift:15-58`).
  - V-TRACK-PRIMITIVES.E06 — **Retry budget text** `1 attempt left` / `n attempts left` (max 3) — helper used only by Playlist detail (`MLM/Views/Shared/DownloadRetryBudget.swift:5-16`, `MLM/Views/Playlists/PlaylistDetailView.swift:618`).
- Pain points: E04/E05 are unlabeled graphics — the number behind them is not shown anywhere in the table, no tooltip; E05 uses a custom colour (conflicts with native-only lock); E02 placeholder uses the abandoned Solar palette; E03 placeholder list misses `unknown album` and marks `Unknown` artist as "will update after download" even on local files that will never download.
- Open questions for the designer: Should energy/danceability show numbers, glyphs, or both? Should "no artwork" and "loading" look different? Where may the failure reason/attempts appear in a 13k-row table (tooltip, inspector, column)?

## Context menus

### CM-TRACK — Track context menu (shared)
- Appears in (grep `TrackContextMenu(` in `MLM/Views`): V-LIB (via `MLM/Views/Library/TrackTable.swift:224-238`), V-SEARCH (same table), V-QUEUE history/now playing/up next (same table), V-PLD (`MLM/Views/Playlists/PlaylistTable.swift:131-146`, the only one with `Remove from Playlist`), V-FOLD (`MLM/Views/Folders/FoldersView.swift:635-645`), ST-ADV Genre Workshop suggestion lists and preview table (`MLM/Views/TrackDetail/GrooveStudioView.swift:775,981,1291`; single-track variants).
- Code: `MLM/Views/Library/TrackContextMenu.swift:7-429`
- Selection rule: the menu acts on the IDs the table hands it — the right-clicked row if it is outside the selection, otherwise the whole selection (`contextMenu(forSelectionType:)`, `MLM/Views/Library/TrackTable.swift:224`). "(n tracks)" suffix appears when more than one track is targeted (`MLM/Views/Library/TrackContextMenu.swift:54`).
- Items verbatim, in order:
  1. *(only when shown inside a playlist)* `Remove from Playlist` / `Remove from Playlist (n tracks)` — icon `minus.circle`, destructive role; removes from that playlist via the playlist view; then a separator (`MLM/Views/Library/TrackContextMenu.swift:59-68`).
  2. `Play` — icon `play.fill`. Disabled when nothing targeted or when the **first targeted track in display order** is remote. Plays the first targeted local track with the targeted tracks as queue (`MLM/Views/Library/TrackContextMenu.swift:71-74,327-331`). Enabled for `File missing` rows (then playback fails).
  3. `Play Next` — icon `forward.end.fill`. Disabled only when nothing targeted; inserts all targeted tracks (including remote ones) after the current track in the queue (`MLM/Views/Library/TrackContextMenu.swift:76-79,335-340`).
  — separator — *(everything below is inside "library actions", always shown because no caller disables it, `MLM/Views/Library/TrackContextMenu.swift:83`)*
  4. Submenu `Add to Playlist` / `Add to Playlist (n tracks)` — icon `text.badge.plus`, disabled when nothing targeted (`MLM/Views/Library/TrackContextMenu.swift:86-120`):
     - `New Playlist…` (icon `plus.square.on.square`) → opens S-SEL-NEWPLAYLIST (posts `.triggerNewPlaylistFromSelection`, `MLM/Views/Library/TrackContextMenu.swift:88-96`, observed at `MLM/Views/ContentView/ContentView.swift:138-142`)
     - separator
     - every playlist by name, pinned ones prefixed with a `pin.fill` icon → appends targeted tracks in display order, posts `.playlistDidChange` (cover regenerates); failure only logged, no user feedback (`MLM/Views/Library/TrackContextMenu.swift:103-114,404-428`)
     - or the disabled text `No playlists` when the list is empty (also in V-QUEUE, which never passes playlists).
  5. Submenu `Sync to ▸` (literal `▸` in the label, plus the system submenu arrow) — icon `arrow.triangle.2.circlepath`, disabled when nothing targeted (`MLM/Views/Library/TrackContextMenu.swift:122-157`):
     - `Create new profile…` (icon `plus.circle`) → opens S-SEL-NEWSYNCPROFILE (posts `.triggerNewSyncProfileFromSelection`, observed at `MLM/Views/ContentView/ContentView.swift:143-147`)
     - separator
     - every sync profile by name → adds targeted tracks to that profile; **also switches the Sync view's selected profile** as a side effect; no confirmation/feedback in place (`MLM/Views/Library/LibraryTable.swift:41-46`, `MLM/ViewModels/SyncViewModel.swift:422-436`) — then a separator; or disabled text `No sync profiles — create one first`
     - `Create new profile… (Settings)` (icon `plus.circle`) → posts `.navigateToCreateSyncProfile`, which **no view observes** → does nothing (`MLM/Views/Library/TrackContextMenu.swift:148-152`; only definition `MLM/Utilities/Notifications.swift:132`).
  — separator —
  6. *(only if at least one targeted track has a stored path)* `Show in Finder` (icon `folder`) → reveals the **first** targeted local file; silently does nothing if the file can't be found (drive unplugged) (`MLM/Views/Library/TrackContextMenu.swift:161-165,359-366`).
  7. *(same condition)* `Copy File Path` (icon `doc.on.doc`) → copies the absolute path of the first targeted local file, wrapped in double quotes if it contains spaces; silent no-op if not found (`MLM/Views/Library/TrackContextMenu.swift:167-169,371-382`). Then separator.
  8. *(only if at least one targeted track is remote)* `Download 1 missing track` / `Download n missing tracks` (icon `arrow.down.circle`) — n counts only the remote ones in a mixed selection; disabled while any download batch is running; starts a background batch whose progress shows in P-ACTIVITY (`MLM/Views/Library/TrackContextMenu.swift:174-184,348-354`). This is also the only "retry" for `Download failed` rows — there is no `Retry download` label. Then separator.
  9. `Remove from Library` / `Remove from Library (n tracks)` — icon `trash`, destructive role, disabled when nothing targeted. If any targeted track is local → A-TRACK-REMOVE; if all remote → removed immediately, **no confirmation, no undo** (`MLM/Views/Library/TrackContextMenu.swift:186-193,202-220`). Removal also deletes the tracks from every playlist and sync profile (`MLM/Database/TrackRepository.swift:497-506`), not mentioned anywhere in the UI.
- Visibility summary: single vs multi → only labels change (suffix), except `Show in Finder`/`Copy File Path` which act on the first local track only; local-only selection → no Download item; remote-only selection → no Finder items, `Play` disabled; mixed → both groups; downloaded-vs-failed → identical menu (failure not distinguished); inside playlist (V-PLD) → `Remove from Playlist` on top; in Library vs elsewhere → same items everywhere (Queue and Genre Workshop included).
- Pain points: dead `(Settings)` item; duplicate "Create new profile…" items; `Sync to ▸` double arrow and naming differs from §3.1 `Add to Sync Profile ▸`; no `Retry download`/reason; no `Get Info`/`Show in Inspector`; Title-case labels vs §1.7 sentence-case rule; remote-only removal unconfirmed; Play gating depends on display order.

## Sheets, popovers, panels, alerts

### S-SEL-NEWPLAYLIST — New playlist from selection
- Trigger: CM-TRACK → `Add to Playlist` → `New Playlist…` (any surface, including Settings → Genre Workshop, in which case the sheet attaches to the main window) · presented by ContentView (`MLM/Views/ContentView/ContentView.swift:138-142,193-195`).
- Code: `MLM/Views/Shared/SelectionCreationSheets.swift:6-124`
- Content: title `New playlist`; text `Enter a name for the new playlist. The n selected track(s) will be added automatically.`; text field placeholder `Playlist name` (focused on open, Return submits when non-empty); inline red error line when creation fails (`MLM/Views/Shared/SelectionCreationSheets.swift:19-46,74-76`).
- Buttons: `Cancel` (Esc, cancel role) · `Add 1 track` / `Add n tracks` (Return, default; disabled while name is blank or while submitting; shows a small spinner while submitting) (`MLM/Views/Shared/SelectionCreationSheets.swift:48-68`).
- Consequence: creates a playlist with that name, adds the tracks (order taken from an unordered set — **not** display order — at a fixed start position `999000`), posts `.playlistDidChange`, closes. Does not navigate to the new playlist (`MLM/Views/Shared/SelectionCreationSheets.swift:79-123`).
- Error handling: messages are raw (`error.localizedDescription`, `Playlist repository is not available.`, `Failed to resolve new playlist ID.`); a playlist created before a failed track insert stays behind empty *(inferred from sequential calls without transaction)*.
- Pain: track order lost (LOGIC-015 fixed only for the context-menu "add to existing" path); sheet uses custom background `mlmSurface`.

### S-SEL-NEWSYNCPROFILE — New sync profile from selection
- Trigger: CM-TRACK → `Sync to ▸` → `Create new profile…` · presented by ContentView (`MLM/Views/ContentView/ContentView.swift:143-147,196-198`).
- Code: `MLM/Views/Shared/SelectionCreationSheets.swift:128-271`
- Content: title `New Sync Profile`; text `Create a new sync profile. The n selected track(s) will be added directly.`; label `Name` + field placeholder `For example, Walkman or USB drive` (focused); label `Output folder` + read-only field placeholder `No folder selected` + button `Browse...` (three dots, not `…`) opening a folder chooser (NSOpenPanel, directories only, single, prompt `Choose folder`); inline error line (`MLM/Views/Shared/SelectionCreationSheets.swift:141-187,220-232`).
- Buttons: `Cancel` (Esc) · `Add 1 track` / `Add n tracks` (Return, default; disabled until name and folder set; spinner while submitting) (`MLM/Views/Shared/SelectionCreationSheets.swift:189-209`).
- Consequence: creates the profile (default settings: no M3U8, keep originals, FAT32-safe paths, cleanup on, keep artwork), selects it in the Sync view, adds the tracks, closes. No navigation to Sync (`MLM/Views/Shared/SelectionCreationSheets.swift:234-270`, `MLM/ViewModels/SyncViewModel.swift:91-118`).
- Error handling (bug per code reading): if creation fails (e.g. `A sync profile with this name already exists.`), the error is stored in the Sync view model, not thrown; the sheet then finds the **previously selected** profile, adds the tracks to it, and closes without any message (`MLM/ViewModels/SyncViewModel.swift:119-126`, `MLM/Views/Shared/SelectionCreationSheets.swift:249-262`). No device detection (cf. §5.5 `Detect device…`).
- Note: UI-GROUNDTRUTH §3.17 says this sheet has German labels — today all labels are English (§11 register).

### A-TRACK-REMOVE — Remove from Library confirmation
- Trigger: CM-TRACK `Remove from Library…` when ≥1 targeted track is local; shown as a native modal alert after the menu closes (`MLM/Views/Library/TrackContextMenu.swift:202-235`).
- Content: title `Remove track from Library?` / `Remove n tracks from Library?` (n counts local + remote); message `This moves local files to the Trash. You can restore them from there. Remote links are removed from the Library.`; warning style.
- Buttons: `Move to Trash` (first/default, destructive) · `Cancel`.
- Consequence: each local file is moved to the Trash; only tracks whose file reached the Trash (plus remote ones) are deleted from the database (with all playlist/sync memberships); views refresh via `.libraryDidDeleteTracks` (`MLM/Views/Library/TrackContextMenu.swift:248-313`). Escape = Cancel.
- Copy vs §3.17: doc wants `Move n files to the Trash? You can restore them from there.`

### A-TRACK-REMOVE-FAILED — Could not remove all tracks
- Trigger: some files could not be located/trashed, or the database update failed after trashing (`MLM/Views/Library/TrackContextMenu.swift:292-311`).
- Content: title `Could Not Remove All Tracks`; message either `Some tracks were kept in the Library because they could not be moved to Trash.` or `The Library database could not be updated. The moved files remain in Trash and can be restored.`, followed by a raw per-track list (`‹artist› — ‹title›: file could not be located` / system error) or Trash locations (`MLM/Views/Library/TrackContextMenu.swift:316-323`).
- Buttons: `OK`. LOGIC-004 is fixed by this path.

## Menu items & keyboard shortcuts (area-local)

- **K-LIB-RESCAN** — ⌘R · `Re-scan Library` (toolbar button in V-LIB) · scope: attached to the Library toolbar button; Library stays mounted while hidden, so possibly active in other sections *(inferred)* · action: rescan library folder (currently a no-op, see V-LIB pain points) + refresh table · `MLM/Views/Library/LibraryView.swift:117-132` · conflict: Sync detail `Refresh` also ⌘R (`MLM/Views/Sync/SyncProfileDetailView.swift:144`).
- **K-LIB-SPACE** — Space · *expected, missing*: preview/play the selected track (`.planning/REQUIREMENTS.md:188-190`, `.planning/research/v1.4-daily-driver/FEATURES.md:114-116`). Today: no handler; Playback menu `Play`/`Pause` has no shortcut (`MLM/App/MLMApp.swift:120-123`).
- **K-LIB-DELETE** — ⌫ / ⌘⌫ · *expected, missing*: remove selection (Finder/Music convention). No delete command handler in the table.
- **K-LIB-INFO** — ⌘I `More Info` (M-LIBRARY, owned by shell.md) · intended to open P-INSPECTOR for the selection; posts `.showTrackDetail`, which no view observes → nothing happens (`MLM/App/MLMApp.swift:183-188`, `MLM/Utilities/Notifications.swift:115`). Inspector opens only via double-click.
- **K-LIB-RETURN** — Return on a selected row: whether the table's primary action (play + inspector) fires is not determinable from code ("Unresolved from code").
- Native table keys: ↑/↓ move selection, ⇧/⌘-click extend, ⌘A select all; ←/→ are taken window-wide for ±5 s seek (`MLM/App/MLMApp.swift:67-72`).
- Sheet keys: Esc = `Cancel`, Return = `Add n tracks` in S-SEL-NEWPLAYLIST and S-SEL-NEWSYNCPROFILE (`MLM/Views/Shared/SelectionCreationSheets.swift:54,67,195,208`).

## Drag & drop

- **D-LIB-TRACK-OUT** — source: rows in V-LIB, V-SEARCH, V-QUEUE (all `TrackTable`) and V-FOLD → targets: Playlist cards in V-PL (adds tracks; the card also spring-loads into the playlist after 0.6 s, `MLM/Views/Playlists/PlaylistCard.swift:113-125,410-440`), Playlist detail table in V-PLD (insert at position, `MLM/Views/Playlists/PlaylistTable.swift:125-127`). Payload: `TrackDragData { trackId, sourcePlaylistId = nil }` as JSON under the private type `com.musiclibrary.trackdrag` (not declared in the app's Info.plist; falls back to generic data if unknown) (`MLM/Views/Library/TrackTable.swift:218-223`, `MLM/Models/Track.swift:363-377`). Feedback: system drag image of the row; card highlight on target. Multi-row drag: see "Unresolved from code".
- **D-LIB-SPRING** — Spring-loaded sidebar: while a track drag hovers ≥ 0.6 s over any sidebar section row, the `Playlists` disclosure label, or a pinned playlist row, MLM navigates there; a pulsing accent outline marks the hovered row; the hover target never accepts the drop itself (drop "passes through" = is refused) (`MLM/Views/Shared/SpringLoadableHover.swift:10-57`; used at `MLM/Views/Sidebar/SidebarView.swift:188-190`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:70-72,119-123`; no-op instances in `MLM/Views/TrackDetail/GrooveStudioView.swift:321,851`). Consequence: hovering `Library`, `Folders`, `Sync`, `Sources`, `Review`, `Discover`, `Queue` navigates to sections that accept no track drop; dropping on a pinned playlist row in the sidebar does nothing.
- **D-LIB-FINDER-IN** — *expected, missing*: drag audio files/folders from Finder onto the Library table to import (Apple Music behaviour). V-LIB has no drop target; import only via `Import from Folder…` ⇧⌘I (M-LIBRARY, `MLM/App/MLMApp.swift:174-179`).
- **D-LIB-TO-FINDER** — *expected, missing*: drag tracks out to Finder, DJ software or a mail/chat app as files. The payload carries only an internal ID, no file URL.
- **D-LIB-TO-SIDEBAR-NEWPL** — *expected, missing*: drop a selection on the sidebar (or a sidebar playlist) to create/add a playlist (`.planning/research/v1.4-daily-driver/FEATURES.md:85`).
- **D-LIB-TO-QUEUE** — *expected, missing*: drag tracks onto the player bar or Queue to queue them (`Play Next` exists only in CM-TRACK).
- **D-LIB-TO-SYNC** — *expected, missing*: drop tracks on a sync profile (Sync spring-loads but has no drop target).

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Drive not connected**: V-LIB.E03 banner (`MLM/Views/Library/LibraryView.swift:77-89`) driven by `isLibraryDriveMounted` (`MLM/Views/ContentView/ContentView.swift:127-137`); playback paused on unmount; availability not recomputed on mount/unmount → stale chips, then mass `File missing` (V-LIB States). `Show in Finder` / `Copy File Path` silently do nothing; `Remove from Library` reports `file could not be located` in A-TRACK-REMOVE-FAILED; Re-scan does nothing. Sidebar red dot (P-SIDEBAR, `MLM/Views/Sidebar/SidebarView.swift:135-140`).
- **Library loading / failed**: `Initializing…` (V-LIB.E24) until the view model exists; `Loading tracks…` (E20) during each fetch; `Failed to load tracks` + raw error (E21). Library-root change → full refresh (`MLM/Views/Library/LibraryView.swift:53-55`). No library root → availability unverified = Local (`MLM/Views/Shared/TrackPresentationAvailability.swift:14-23`).
- **Source disconnected / expired**: nothing in V-LIB; remote rows still show `Not downloaded`; download attempts fail into `Download failed` with no source hint.
- **Background processing**: no indicator in V-LIB; `Download n missing tracks` greyed while a batch runs (`MLM/Views/Library/TrackContextMenu.swift:46-49`).
- **Track availability states**: full mapping in V-TRACK-PRIMITIVES.E01 table.

### Background work touchpoints

- **Downloads**: started from CM-TRACK item 8; progress only in P-ACTIVITY; V-LIB refreshes at batch end (`.downloadDidComplete`); rows migrate Remote → Local; failures become `Download failed` chips (no reason/attempts in Library). Only one batch at a time; second request blocked by the disabled item (and rejected with a log line in `MLM/ViewModels/DownloadViewModel.swift:195-198`). No cancel in V-LIB.
- **Import / re-scan**: `Re-scan Library` button spinner; intended Activity entry `Rescan library` (`MLM/ViewModels/ImportViewModel.swift:109-113`) — not reached today (bug). Any import elsewhere posts `.libraryDidImport` → V-LIB refreshes.
- **Artwork extraction**: auto-runs after imports and downloads (4 concurrent ffmpeg), plus per-cell self-repair; progress is tracked internally (`progress`) but displayed nowhere outside Maintenance; covers pop in per track (`MLM/Services/Artwork/ArtworkBackfillService.swift:98-122,225-310,403-411`). User control only via Settings → Maintenance (ST-MAINT).
- **Analysis** (energy, danceability, BPM): values appear in E16–E18 after analysis; the table only shows them after the next refresh. No "pending analysis" marker (`—` is used for both "not analysed" and "no value").
- **Sync**: `Sync to ▸` adds tracks and schedules a preview refresh in the Sync view (`MLM/ViewModels/SyncViewModel.swift:422-436`); no feedback in V-LIB.

### Flow notes

- **daily-listening** (browse → space preview → play → queue):
  1. V-LIB: open Library (⌘1), Local tab, sorted by Added — intent "what's new".
  2. V-LIB: arrow through rows, wants to hear one → **breaks**: spacebar does nothing (K-LIB-SPACE missing); ⌘I does nothing.
  3. V-LIB: double-click → plays + opens inspector (P-INSPECTOR) every time, even when the user only wanted to listen; inspector then follows now-playing.
  4. CM-TRACK `Play Next` to stack tracks; no drag-to-queue (D-LIB-TO-QUEUE missing); queue silently includes remote tracks.
  5. `Shuffle` on Remote tab or with File-missing rows → playback errors.
- **build-playlist** (create + fill by multi-select / drag):
  1. V-LIB: search (toolbar), ⌘-click several rows.
  2. CM-TRACK `Add to Playlist (n tracks)` → existing playlist (order kept) — no confirmation, no feedback, failure silent.
  3. Or `New Playlist…` → S-SEL-NEWPLAYLIST → `Add n tracks` — order lost; stays in Library (no jump to playlist).
  4. Or drag rows to V-PL card / V-PLD table via D-LIB-SPRING (hover sidebar `Playlists` 0.6 s) → works; dropping on sidebar playlist row does nothing; no "drop on sidebar → new playlist".
  5. No batch bar for multi-select (Tauri v1.2 had one, `.planning/PROJECT.md:31`).
- **fix-failed-downloads**:
  1. V-LIB Remote tab — intent "which ones failed and why".
  2. **Breaks**: no filter/sort by Status; must scroll all remote rows looking for `Download failed` chips; reason/attempts not shown (only V-PLD shows them).
  3. Select failed rows → CM-TRACK `Download n missing tracks` (no `Retry` wording).
  4. Watch progress in P-ACTIVITY; V-LIB updates only at batch end; still-failing rows keep the same chip, no "attempts left".
- **drive-unplugged**:
  1. Drive ejected → playback paused, banner E03 appears, sidebar red dot.
  2. Rows unchanged until something refreshes; then every local row shows red `File missing` (12k-row wall of red) — no distinct "drive offline" row state.
  3. Double-click / `Play` → playback error; `Show in Finder`/`Copy File Path` silent; `Re-scan` silent.
  4. Drive back → banner disappears, but `File missing` chips stay until a refresh (search/sort/tab change or download/import).
- **albums-future**:
  1. V-LIB `Album` column today shows the raw album string; 6,209 tracks (48 %) read `unknown album` in normal text (not treated as placeholder); source names (`YouTube`, `SoundCloud Likes`, `Downloads`) are styled as placeholders with a misleading "will update after download" tooltip.
  2. Sorting by Album groups the 48 % block together; no album grouping, no track number/disc order (ROADMAP §0.2, §4 C1).
  3. No album view or album navigation from a row (ROADMAP §4 C2).
- **find-fast**: toolbar search live-filters V-LIB (200 ms) with multi-word AND across artist/album artist/album/title/genre/format; tab counts don't change; whole table flashes `Loading tracks…` per refresh; Return jumps to V-SEARCH, whose table has no sort and no Status.
- **sync-device**: CM-TRACK `Sync to ▸` → profile (silent add, changes selected profile in V-SYNC) or `Create new profile…` → S-SEL-NEWSYNCPROFILE (silent wrong-profile add on name clash); `Create new profile… (Settings)` dead.
- **library-cleanup** (area-specific): CM-TRACK `Remove from Library` → A-TRACK-REMOVE (local) or immediate (remote-only); memberships in playlists/profiles silently removed; partial failures → A-TRACK-REMOVE-FAILED.
- **switch-library / settings-changes**: library-root change triggers full refresh (`.libraryRootDidChange`); nothing else in this area.

### Unresolved from code

- Whether SwiftUI's `Table` here lets the user reorder columns by dragging headers (no customization binding is passed; default macOS behaviour not determinable from code).
- Whether dragging one of several selected rows drags all selected tracks (per-row `.draggable` on `TableRow`; multi-item behaviour is framework-defined).
- Whether Return triggers the table's primary action (play + inspector) on macOS.
- Whether the hidden (opacity 0) Library view's toolbar items and ⌘R stay active in other sections.
- Whether the private drag type `com.musiclibrary.trackdrag` resolves without an Info.plist declaration or falls back to generic data (`MLM/Models/Track.swift:373-377`).
- Whether the `Not downloaded` chip fits the fixed 90 pt Status column without truncation (font metrics).
- Whether `search_text` is kept up to date on metadata edits/new imports (only migrations seen; write path not in my files).
- Exact Local/Remote split of the 12,935 tracks (live DB off-limits; ROADMAP gives no split).
- What happens when queue playback advances onto a remote track queued via `Play`/`Play Next`/double-click (PlaybackViewModel queue logic is outside my files).
- Whether text sorting is case-sensitive in practice (no `COLLATE` found; column definitions created in early migrations not fully read).

