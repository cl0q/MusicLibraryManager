# MLM B1 — coverage

Every ID of `design/B1-UI-INVENTORY.md` (§3–§9 registers) and what became of it in the B1 packet. Generated from `coverage-parts/*.tsv`; the ID list is `coverage-parts/_all-ids.tsv`.

**Status:** *mocked* = designed on the linked page · *covered by pattern* = shown on a Tier 3 catalogue page in the unified pattern · *unchanged* = stays as it is (reason given) · *removed* / *merged* = no longer exists as such (reason and replacement given).

## Totals

**308 inventory IDs, 0 unmapped.**

| Kind | IDs | mocked | covered by pattern | unchanged | merged | removed |
|---|---|---|---|---|---|---|
| Windows (`W-`) | 3 | 2 | 0 | 0 | 1 | 0 |
| Views (`V-`) | 21 | 17 | 0 | 0 | 4 | 0 |
| Persistent panels (`P-`) | 14 | 11 | 0 | 0 | 3 | 0 |
| Settings tabs (`ST-`) | 11 | 10 | 0 | 0 | 1 | 0 |
| Sheets, popovers, panels (`S-`) | 33 | 11 | 9 | 3 | 7 | 3 |
| Alerts (`A-`) | 28 | 15 | 1 | 0 | 8 | 4 |
| Context menus (`CM-`) | 18 | 15 | 0 | 0 | 2 | 1 |
| Menus (`M-`) | 10 | 0 | 9 | 0 | 1 | 0 |
| Keyboard shortcuts (`K-`) | 52 | 19 | 13 | 2 | 13 | 5 |
| Drag & drop (`D-`) | 50 | 27 | 21 | 1 | 0 | 1 |
| Flows (`F-`) | 24 | 24 | 0 | 0 | 0 | 0 |
| Global states (`G-`) | 44 | 44 | 0 | 0 | 0 | 0 |
| **Total** | **308** | **195** | **53** | **6** | **40** | **14** |

The inventory counts 240 surface/overlay/menu/shortcut/drag IDs plus 43 global states and 24 flows; `G-LIB-NOTFOUND / G-LIB-NOTCONNECTED` share one row there and are listed separately here (hence 308).
Every sheet, alert, context menu, menu, shortcut and drag & drop ID additionally appears on its Tier 3 catalogue page (`patterns-*.html`), whatever its status here.

## Windows (`W-`) — 3

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `W-MAIN` | Main window ("MLM") | mocked | [launch.html](launch.html) | Launch states, title/subtitle naming the library and the picker are mocked here; the working layout (sidebar, toolbar, columns) is shell.html (DEC-031) |
| `W-SETTINGS` | Settings window (shell only; tabs ST-* belong to settings.md) | mocked | [settings.html](settings.html) | SwiftUI Settings scene with 8 deep-linkable tabs (DEC-035) |
| `W-REMOTE` | Remote playlists window (SoundCloud Playlists / Spotify Playlists / Import YouTube Playlis | merged | [import.html](import.html) | DEC-026: the separate import window is replaced by the S-IMPORT sheet (Source > Preview > Confirm); progress/result move to the playlist header (playlists.html#detail) and to Activity (DEC-044) |

## Views (`V-`) — 21

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `V-LAUNCH-NOLIB` | "No library open" | merged | [launch.html](launch.html) | Replaced by the library picker V-PICKER (states picker, picker-empty); element IDs E01-E04 reused (DEC-031) |
| `V-LAUNCH-CANTOPEN` | "‹name›" can't be opened (window-content form) | merged | [launch.html](launch.html) | No separate screen: state cant-open = V-PICKER with the affected row selected, explaining Not connected / Not found / identity mismatch with its actions (DEC-031) |
| `V-LAUNCH-INVALID` | "‹name›" isn't a valid library file. | mocked | [launch.html](launch.html) | State invalid: cause sentence, Choose Another Library, Show in Finder (DEC-031) |
| `V-LAUNCH-LOADING` | "Loading Library..." | mocked | [launch.html](launch.html) | State loading: names the library, phase line, determinate backup phase, finishing library file setup (DEC-031, DEC-044) |
| `V-LAUNCH-FAILED` | "Failed to Initialize" | mocked | [launch.html](launch.html) | State failed: sentence, Details, Try Again, Choose Another Library, Restore from Backup…, Show Logs (DEC-031) |
| `V-MAIN-LAYOUT` | Main window content (what fills W-MAIN) | mocked | [shell.html](shell.html) | Live shell plus exhibits; E05 Activity strip removed (DEC-005), E06–E09 launch states live on launch.html (DEC-031, DEC-034) |
| `V-QUEUE` | Queue | mocked | [queue.html](queue.html) | Becomes P-QUEUE, the Queue mode of the trailing column (DEC-006); V-QUEUE.E01–E05 reused |
| `V-SEARCH` | Toolbar search field and search results pane | mocked | [search.html](search.html) | Filter in place, scopes This view · Library · Online, tokens, links (DEC-017, DEC-018) |
| `V-LIB` | Library | mocked | [library.html](library.html) | Mocked by the lead |
| `V-TRACK-TABLE` | Shared track table (component, not a sidebar view) | mocked | [library.html](library.html) | Mocked by the lead |
| `V-TRACK-PRIMITIVES` | Track presentation primitives (component catalogue) | mocked | [library.html](library.html) | Mocked by the lead |
| `V-PL` | Playlists (grid) | mocked | [playlists.html](playlists.html) | DEC-003: becomes "All Playlists" (cover grid of what the sidebar lists); sort control, scope bar incl. Needs attention, folder groups, states default/empty/loading/error/filtered-empty |
| `V-PLD` | Playlist detail | mocked | [playlists.html#detail](playlists.html#detail) | DEC-022/DEC-023: 160 pt cover header, editable title, Play/Shuffle/More, one status sentence, scope All · Download failed, undoable removal; states healthy/importing/incomplete/not downloaded/sign-in expired/empty/loading/error/not found |
| `V-FOLD` | Folders (disk folder browser) | mocked | [folders.html](folders.html) | DEC-024: variant A one hierarchical table + path bar (recommended), variant B tree + table; states default/importing/imported/empty/loading/error + drive-off hint |
| `V-SYNC` | Sync (profile list) | merged | [sync.html](sync.html) | DEC-027: the profile list becomes sidebar rows (exhibit below the window); its empty state is the page state no-profiles |
| `V-SYNC-DETAIL` | Sync profile detail | mocked | [sync.html](sync.html) | Header · Content · Plan · Options · Last sync, nine page states (DEC-027) |
| `V-SRC` | Sources | merged | [import.html](import.html) | DEC-004: no Sources sidebar section. Accounts move to Settings > Sources (settings.html#sources); entry points are the Add menu (P-ADDMENU); source state and Reconnect appear in place in S-IMPORT step 1; the per-card Sync becomes Refresh from Sources (exhibit on import.html) |
| `V-REV` | Review (duplicates & metadata conflicts) | mocked | [review.html](review.html) |  |
| `V-DISC` | Discover | mocked | [discover.html](discover.html) | Discover with scope bar Recommendations · Reels (DEC-029); one title, counts on the scopes |
| `V-INBOX` | Recommendations (Discovery inbox) | mocked | [discover.html#recs](discover.html#recs) | Grouped by seed, keyboard triage, held outside All Tracks until kept (DEC-029) |
| `V-REELS` | Reels (Reels inbox) | mocked | [discover.html#reels](discover.html#reels) | Master–detail with state words, guesses with provenance, results per source (DEC-029) |

## Persistent panels (`P-`) — 14

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `P-SIDEBAR` | Sidebar | mocked | [shell.html](shell.html) | Library · Inbox · Playlists · Sync + library footer (DEC-001…004); E06 Sources, E10 Queue, E11 Settings rows removed |
| `P-PINNED` | Pinned playlists (nested under "Playlists" in the sidebar) | merged | [playlists.html](playlists.html) | DEC-003: replaced by the sidebar Playlists section (all playlists, playlist folders, state words, drop targets); rows rebuilt on playlists.html, shell in shell.html |
| `P-TOOLBAR` | Window toolbar | mocked | [shell.html](shell.html) | Constant toolbar at three widths; E04/E05 section items removed (DEC-048) |
| `P-PLAYER` | Player bar (in the toolbar) | mocked | [player.html](player.html) | All states, Space preview, variants A/B (DEC-009, DEC-010, DEC-045) |
| `P-INSPECTOR` | Track inspector ("detail panel") | mocked | [inspector.html](inspector.html) | System inspector, ⌘I, follows selection, multi-edit, tabs Details · Audio · File (DEC-007) |
| `P-INSPECTOR-WAVEFORM` | Waveform strip (top of the inspector) | mocked | [inspector.html](inspector.html) | Moved from the top strip into the Audio tab; shows the inspected track |
| `P-INSPECTOR-GENERAL` | General tab (tag editing + playlist membership) | mocked | [inspector.html](inspector.html) | Renamed Details tab |
| `P-INSPECTOR-AUDIO` | Audio tab (analysis values, manual analysis, waveform options) | mocked | [inspector.html](inspector.html) | E03 waveform option sliders removed |
| `P-INSPECTOR-FILE` | File tab (paths, availability, source, duplicate hint) | mocked | [inspector.html](inspector.html) | Availability sentence with fix action per state |
| `P-INSPECTOR-SIMILAR` | Similar tab | merged | [inspector.html](inspector.html) | DEC-007/DEC-030: top-5 Similar section on the Audio tab, Show All opens V-SIMILAR (discover.html#similar) |
| `P-INSPECTOR-DEBUG` | Debug tab (ffmpeg diagnostics) | merged | [inspector.html](inspector.html) | DEC-007: Diagnostics disclosure at the bottom of the File tab, runs on demand |
| `P-ACTIVITY` | Activity | mocked | [activity.html](activity.html) | DEC-005: bottom panel becomes toolbar Activity item + popover + Activity window; bottom strip kept as variant P-ACTIVITY/B |
| `P-ACTIVITY-OPS` | Operations | mocked | [activity.html](activity.html) | Popover (Running / Needs attention / Recent) and Operations tab of W-ACTIVITY |
| `P-ACTIVITY-LOGS` | Logs | mocked | [activity.html#logs](activity.html#logs) |  |

## Settings tabs (`ST-`) — 11

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `ST-STUDIO-GRID` | Genre Workshop: genre grid (Settings → Advanced) | mocked | [genres.html#list](genres.html#list) | DEC-025: the Genre Workshop grid leaves Settings and becomes the V-GENRES list (table with multi-selection); elements E01–E04 reused |
| `ST-STUDIO-GENRE` | Genre Workshop: genre detail (reference track, suggestions, staged tagging) | mocked | [genres.html#detail](genres.html#detail) | DEC-025: becomes V-GENRED (genre tracks + Suggested tracks section + staging bar); E02 dual preview players removed, replaced by Space preview in the toolbar player (DEC-009/010) |
| `ST-STUDIO-MERGE` | Genre Workshop: Consolidate genres | mocked | [genres.html#list](genres.html#list) | DEC-025/DEC-041: screen becomes the sheet "Merge Genres…" (id s-merge) on the list selection; previewed, counted, undoable |
| `ST-STUDIO-EXPORT` | Genre Workshop: Export CreateML training set | mocked | [genres.html#list](genres.html#list) | DEC-025/DEC-044: screen becomes the sheet "Export Create ML Training Set…" (id s-export; More menu and File ▸ Export); progress is an Activity operation; result counts skipped/failed |
| `ST-LIB` | Library | mocked | [settings.html#library](settings.html#library) | E04/E05 moved to General; E08/E09 merged into the Library folder row; consequences sheet for Change… (DEC-035) |
| `ST-SRC` | Sources | mocked | [settings.html#sources](settings.html#sources) | Accounts with Connect/Reconnect/Disconnect in place, refresh schedule, Download tools, Qobuz cookie (DEC-004, DEC-037) |
| `ST-MAINT` | Maintenance | mocked | [settings.html#maintenance](settings.html#maintenance) | Jobs as rows with coverage and own result, run as Activity operations; E18 shared result removed; E04-E06 table cache moved to Advanced (DEC-044) |
| `ST-BACKUP` | Backup | mocked | [settings.html#backup](settings.html#backup) | Adds schedule, keep-last and destination reachability (DEC-036) |
| `ST-STORAGE` | Storage Location | mocked | [settings.html#storage](settings.html#storage) | Grouped In this library file / Library folder / On this Mac, sizes chart, missing locations added (DEC-035) |
| `ST-PLAYBACK` | Playback | mocked | [settings.html#playback](settings.html#playback) | Normalisation with its dependency explained; history and queue length under Advanced with plain labels (DEC-035) |
| `ST-ADV` | Advanced (Genre Workshop) | merged | [genres.html](genres.html) | DEC-025: the Genre Workshop (the tab's only content) moves to the sidebar destination Genres (V-GENRES/V-GENRED); Settings ▸ Advanced gets other content per DEC-035 (settings.html) |

## Sheets, popovers, panels (`S-`) — 33

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `S-LIBFILE-OPEN` | Open Library… file panel | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | System open panel; triggers (Open Other…, Locate…) are mocked in launch.html |
| `S-WIZ-FOLDER` | library folder panel | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | System folder panel; trigger and drop target mocked in launch.html state setup-2 |
| `S-ADOPT` | "Set up your library file" | mocked | [launch.html](launch.html) | State adopt: sheet over the picker with clickable phases, success and failure (DEC-031) |
| `S-NEWLIB` | "New Library" | mocked | [launch.html](launch.html) | State new: name + location with default-location rationale; same fields are step 1 of V-SETUP (DEC-034) |
| `S-WIZARD` | First-run wizard (window overlay) | merged | [launch.html](launch.html) | Replaced by the in-window setup V-SETUP (states setup-1, setup-2, setup-3, setup-done); the Welcome step is folded into step 1; element IDs reused (DEC-034) |
| `S-SEARCH-UNIVERSAL` | Universal search panel ("Paste a URL or search for music…") | merged | [search.html](search.html) | DEC-018: link detection is a suggestion row in the search field plus Add from Link… ⌘U (S-QUICKADD) and the import sheet (S-IMPORT); the panel is not rebuilt |
| `S-PLAYER-COVER` | Large cover popover | mocked | [player.html](player.html) | Large cover popover, live and as exhibit |
| `S-SEL-NEWPLAYLIST` | New playlist from selection | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) |  |
| `S-SEL-NEWSYNCPROFILE` | New sync profile from selection | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) |  |
| `S-GROOVE-SIMILAR` | Similar tracks sheet (code: `GrooveView`) | merged | [discover.html#similar](discover.html#similar) | DEC-030: the sheet becomes the pushed view V-SIMILAR |
| `S-STUDIO-EXPORTFOLDER` | Choose CreateML destination (NSOpenPanel) | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | system folder dialog (.fileImporter); its trigger "Choose…" is mocked in the export sheet on genres.html |
| `S-PL-NEWPLAYLIST` | New Playlist popover | merged | [playlists.html](playlists.html) | DEC-003 / THOUGHTS §4.2: no naming popover; New Playlist creates "Untitled Playlist" and puts the name into inline edit (card V-PL.E11 or sidebar row P-PINNED.E04) |
| `S-PL-BANNER-PINLIMIT` | Pin-limit banner (inline panel) | removed | [playlists.html](playlists.html) | DEC-003: pinning and its limit of 8 no longer exist; every playlist is a sidebar row |
| `S-PL-BANNER-COVERDROP` | Cover drop rejected banner (inline panel) | mocked | [playlists.html](playlists.html) | Reworked as an inline error sentence on the card that refused the drop (also shown for non-image files), no grid-pushing banner |
| `S-PLD-LINK` | Link Playlist Source sheet | mocked | [playlists.html#detail](playlists.html#detail) | DEC-023: Link Source sheet with inline check results (same tracks, different tracks, not a playlist link, sign-in expired) |
| `S-PLD-M3U-OPEN` | M3U file chooser (system open panel) | unchanged | [playlists.html#detail](playlists.html#detail) | System open panel (.fileImporter for .m3u/.m3u8); only its message now names the target playlist; not mocked, the More item opens the preview directly |
| `S-PLD-M3U-PREVIEW` | Import Playlist preview sheet (component shared with sync.md device ingest) | mocked | [playlists.html#detail](playlists.html#detail) | Imports into the open playlist: states where tracks go, lists will be added / already in playlist / not found |
| `S-SYNC-DEVICEINGEST` | Read Playlist Changes (device ingest results sheet) | mocked | [sync.html](sync.html) | Unified sheet “Read Playlist Changes from Device”; Apply merges, undoable (DEC-027) |
| `S-SYNC-NEWPROFILE` | New Sync Profile sheet | mocked | [sync.html](sync.html) | Name, destination with detected devices / Choose… / drop, device preset |
| `S-SYNC-OPENPANEL` | Output folder chooser (file dialog) | unchanged | [sync.html](sync.html) | System folder panel behind Choose… in the new-profile and change-destination sheets |
| `S-SYNC-RENAME` | Rename sync profile sheet | removed | [sync.html](sync.html) | DEC-027: inline rename in the sidebar row (More ▸ Rename; exhibit below the window) |
| `S-SYNC-PLAYLISTPICKER` | Add playlists to profile sheet | mocked | [sync.html](sync.html) | One picker for Playlists · Albums · Tracks |
| `S-SYNC-INGESTPREVIEW` | Import Playlist (m3u diff preview sheet) | merged | [sync.html](sync.html) | DEC-027: its entry-level diff is the right half of the unified device sheet; the M3U import keeps S-PLD-M3U-PREVIEW (playlists area) |
| `S-SYNC-TOAST` | "device defaults" toast | removed | [sync.html](sync.html) | DEC-016: preset summary in the new-profile sheet plus a device-defaults note under Options |
| `S-REV-UNDOTOAST` | Review undo toast | merged | [review.html](review.html) | DEC-016: floating undo toast replaced by the status-bar confirmation with Undo (working in the mockup) |
| `S-SRC-OAUTH` | Sign-in in the web browser (external) | mocked | [import.html](import.html) | In place in S-IMPORT step 1 (Spotify > Reconnect), as sheet s-oauth from other Reconnect buttons, and as exhibit |
| `S-REELS-OPENFOLDER` | folder picker (NSOpenPanel) | unchanged | [discover.html#reels](discover.html#reels) | System open panel, now via Import… for files or folders (recursive); nothing to design |
| `S-REELS-KEYFRAME` | keyframe detail sheet | mocked | [discover.html#reels](discover.html#reels) | Becomes a popover on the keyframe strip (po-keyframe), DEC-029 / THOUGHTS §3.2 (a glance is a popover) |
| `S-SET-LIBROOT` | Select Music Library Folder (NSOpenPanel) | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | System folder panel; preceded by the new consequences sheet S-SET-LIBFOLDER mocked in settings.html#library |
| `S-SET-IMPORTFOLDER` | Import Audio Files (NSOpenPanel) | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | System panel behind Import Files or Folder… (settings.html#library and the Add menu) |
| `S-SET-CACHEFOLDER` | Choose transcode cache location (NSOpenPanel) | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | System folder panel behind Transcode cache Change… (settings.html#maintenance) |
| `S-SET-BACKUPFOLDER` | Choose backup folder (NSOpenPanel) | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | System folder panel behind Backup folder Change… (settings.html#backup) |
| `S-SET-EXPORTFOLDER` | CreateML destination (NSOpenPanel) | merged | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) | same panel as S-STUDIO-EXPORTFOLDER (duplicate inventory entry of the Create ML destination dialog); trigger mocked in the export sheet on genres.html (DEC-025) |

## Alerts (`A-`) — 28

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `A-LIB-SWITCH` | "Switch to "‹name›"?" | mocked | [launch.html](launch.html) | State switch: lists running work, Switch and Relaunch / Cancel (DEC-032) |
| `A-LIB-COPY` | "‹name›" is a copy of "‹original›" (library-file copy prompt) | mocked | [launch.html](launch.html) | State copy: one alert form, also used over the picker (DEC-031) |
| `A-LIBFILE-CANTOPEN` | can't be opened (alert form, while a library is open) | mocked | [launch.html](launch.html) | State open-alerts: three causes, Try Again added for Not connected (DEC-031) |
| `A-LIBFILE-INVALID` | isn't a valid library file (alert form) | mocked | [launch.html](launch.html) | State open-alerts: with cause and Show in Finder; a failed New Library gets its own message (DEC-031) |
| `A-SIDEBAR-DELETEPL` | "Delete playlist?" | merged | [playlists.html](playlists.html) | Merged into A-PL-DELETE (one delete confirmation everywhere) |
| `A-SIDEBAR-RENAMEFAIL` | "Could not rename playlist" | merged | [playlists.html](playlists.html) | DEC-016: the alert becomes an inline error under the still-open rename field; the typed name is kept (simulated "Rename fails") |
| `A-TRACK-REMOVE` | Remove from Library confirmation | mocked | [library.html](library.html) | Shell alert, mocked by the lead |
| `A-TRACK-REMOVE-FAILED` | Could not remove all tracks | covered by pattern | [patterns-sheets-alerts.html](patterns-sheets-alerts.html) |  |
| `A-GROOVE-DELETEFILE` | "Delete file?" confirmation | removed | [discover.html#similar](discover.html#similar) | DEC-030: no delete in Similar (fixes PP-INSPECTOR-21); discarding happens in Recommendations via Dismiss, only for held tracks |
| `A-META-SAVEERROR` | "Could not save metadata" | merged | [inspector.html](inspector.html) | DEC-007: inline error under the field with Try Again; no alert |
| `A-PL-DELETE` | Delete playlist confirmation | mocked | [playlists.html](playlists.html) | DEC-041: one alert for grid, sidebar and detail; states the consequence and that Undo works until quit |
| `A-PLD-LINKMISMATCH` | "Different tracks" | merged | [playlists.html#detail](playlists.html#detail) | Merged into S-PLD-LINK: the difference and its consequence are an inline result, the primary button stays "Link Playlist" |
| `A-PLD-LINKDONE` | "Link Updated" | merged | [playlists.html#detail](playlists.html#detail) | DEC-016: replaced by the status-bar message "Linked … to SoundCloud" with Undo |
| `A-PLD-IMPORTDONE` | "Import Complete" | merged | [playlists.html#detail](playlists.html#detail) | DEC-016: replaced by the status-bar message "Added 38 tracks to ‹playlist› · 4 already there · 6 not found" with Undo |
| `A-PLD-REMOVE` | "Remove tracks" | removed | [playlists.html#detail](playlists.html#detail) | DEC-041/DEC-016: removal from a playlist is immediate and undoable for any count (⌫, context menu); status-bar message with Undo replaces the alert |
| `A-SYNC-DELETEPROFILE` | Delete sync profile? | mocked | [sync.html](sync.html) | More ▸ Delete Sync Profile… |
| `A-SYNC-REMOVECONTENT` | Remove from profile? | removed | [sync.html](sync.html) | DEC-041: undoable removal (⌫ / context menu) with the consequence in the status-bar message |
| `A-SRC-KEYCHAIN` | macOS keychain permission prompt (system) | mocked | [import.html](import.html) | System dialog shown as exhibit with MLM's context line; Deny maps to Sign-in expired - Reconnect |
| `A-INBOX-DELETE` | "Delete file?" | removed | [discover.html#recs](discover.html#recs) | DEC-029/DEC-041: Dismiss moves the file to the Trash without an alert; undoable via status bar and Edit ▸ Undo |
| `A-INBOX-ERROR` | "Recommendations" error alert | merged | [discover.html](discover.html) | DEC-016: replaced by a status-bar message with cause and Try Again (exhibit below the window); load failure has its own error state |
| `A-REELS-DELETE` | "Delete 1 reel?" / "Delete N reels?" | mocked | [discover.html#reels](discover.html#reels) | Attached to the view; option “Also move the video file to the Trash” |
| `A-REELS-DELETEERROR` | "Deletion Error" | merged | [discover.html](discover.html) | DEC-016: replaced by a status-bar message naming the reel and the cause (exhibit below the window) |
| `A-SET-DISCONNECT` | Disconnect source | mocked | [settings.html#sources](settings.html#sources) | Says it applies to all libraries and that refreshing stops (DEC-023) |
| `A-SET-RESTORE` | Restore backup | mocked | [settings.html#backup](settings.html#backup) | States that MLM quits and reopens in the restored library; lists running work (DEC-036) |
| `A-SET-RESTOREFAILED` | Restore didn't finish | mocked | [settings.html#backup](settings.html#backup) | Approved copy kept; opened from the mockup strip |
| `A-SET-PATHAPPLY` | Update organized paths? (confirmation dialog) | mocked | [settings.html#maintenance](settings.html#maintenance) | Title kept, plain consequence text |
| `A-SET-PATHROLLBACK` | Roll back last path migration? (confirmation dialog) | mocked | [settings.html#maintenance](settings.html#maintenance) | Title kept, names the migration that is undone |
| `A-OPS-CLEARQUEUE` | Clear Pending Jobs | mocked | [activity.html](activity.html) | Reworded 'Clear 212 waiting analyses?'; opens from Clear Waiting... on the analysis row; static exhibit too |

## Context menus (`CM-`) — 18

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `CM-SIDEBAR-PINNED` | Pinned playlist row | mocked | [playlists.html](playlists.html) | DEC-039: sidebar playlist row menu (Play, Play Next, Add to Sync Profile, Rename, Move to Folder, Download n Missing, Refresh from ‹Source›, Show in All Playlists, Delete Playlist…); Unpin removed |
| `CM-SIDEBAR-PINNEDRENAME` | Row in rename mode | removed | [playlists.html](playlists.html) | The one-item "Cancel" menu is dropped; the inline rename field shows the standard text-field menu, Esc cancels |
| `CM-TRACK` | Track context menu (shared) | mocked | [library.html](library.html) | Shell context menu, mocked by the lead; queue variant CM-QUEUE on queue.html |
| `CM-STUDIO-SUGGESTION` | Suggestion row (ST-STUDIO-GENRE left column) | mocked | [genres.html#detail](genres.html#detail) | menu cm-genre-sugg: shared track menu in DEC-039 order plus Add to ‹Genre› / Not This Genre |
| `CM-STUDIO-GENRETRACK` | Genre track row (ST-STUDIO-GENRE right column) | mocked | [genres.html#detail](genres.html#detail) | menu cm-genre-track: shared track menu in DEC-039 order plus Use as Reference for Suggestions / Remove from ‹Genre› |
| `CM-STUDIO-MERGETABLE` | Merge preview table (ST-STUDIO-MERGE) | mocked | [genres.html#list](genres.html#list) | merge sheet preview table uses the shared CM-TRACK menu (multi-selection aware) |
| `CM-PL-CARD` | Playlist card context menu | mocked | [playlists.html](playlists.html) | DEC-039 order; Pin/Unpin removed (DEC-003); "Sync to" becomes "Add to Sync Profile"; "Show failed tracks" opens the Download failed scope |
| `CM-FOLD-TREE` | Folder tree row | mocked | [folders.html](folders.html) | DEC-039: the one folder context menu (Open, Play, Play Next, Add to Queue, Add to Playlist, Add to Sync Profile, Scan This Folder, Import n Files, Show in Finder, Copy Path) |
| `CM-FOLD-SUBFOLDER` | Subfolders table row | merged | [folders.html](folders.html) | DEC-024: the Subfolders table no longer exists; its rows are folder rows of the one outline table and use CM-FOLD-TREE |
| `CM-FOLD-SEARCHRESULT` | Folder search results row | merged | [folders.html](folders.html) | DEC-024/DEC-017: search filters the outline in place, there is no results table; rows use CM-FOLD-TREE |
| `CM-SYNC-PROFILE` | profile row | mocked | [sync.html](sync.html) | On the sidebar rows, DEC-039 order; same items as the More menu |
| `CM-SYNC-PLROW` | playlist row in profile | mocked | [sync.html](sync.html) | Playlist and album rows in Content |
| `CM-SYNC-TRACKROW` | track row in profile | mocked | [sync.html](sync.html) | Track rows in Content and in Plan ▸ Skip |
| `CM-SYNC-PREVIEWFILE` | file in preview list | mocked | [sync.html](sync.html) | Rows of Plan ▸ Add / Remove |
| `CM-SYNC-FAILED` | failed track row | mocked | [sync.html](sync.html) | Failed rows in Last sync (state done-with-failures) |
| `CM-REELS-ADDPL` | "Add to playlist" pull-down on a search result | mocked | [discover.html#reels](discover.html#reels) | Standard Add to Playlist menu with New Playlist…, confirmation + Undo (DEC-039) |
| `CM-REELS-TEXTPILL` | recognized-text pill menu | mocked | [discover.html#reels](discover.html#reels) | Menu on text fragments: Use as Artist / Use as Title / Use as “Artist – Title” / Copy |
| `CM-LOGS-TEXT` | standard text menu in the log view | mocked | [activity.html#logs](activity.html#logs) | System text menu plus two filter items; right-click the log text |

## Menus (`M-`) — 10

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `M-APP` | "MLM" (application menu) | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Application menu; Settings… opens the Settings scene (DEC-038) |
| `M-FILE` | "File" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | File menu (DEC-038); Open Recent with states is additionally shown as an exhibit in launch.html |
| `M-EDIT` | "Edit" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Edit menu gains named Undo/Redo (DEC-038, DEC-041) |
| `M-VIEW` | "View" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | View menu with sidebar, Info, Queue, columns (DEC-038) |
| `M-NAVIGATE` | "Navigate" | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Renamed and rebuilt as the Go menu: All Tracks, Albums, Genres, Folders, Discover, Review, Back/Forward (DEC-038, THOUGHTS §4.2) |
| `M-PLAYBACK` | "Playback" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Playback menu with shortcuts for Play/Pause, Next, Previous, seek, volume (DEC-038, THOUGHTS §4.2) |
| `M-LIBRARY` | "Library" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Library menu kept with working items; selection commands move to the new Track menu (DEC-038) |
| `M-WINDOW` | "Window" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | System Window menu plus Activity ⌥⌘0 (DEC-038, DEC-005) |
| `M-HELP` | "Help" | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | System Help menu (DEC-038) |
| `M-DOCK` | Dock menu | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | New small Dock menu: Play/Pause, Next, Previous, current title, Open Recent library (THOUGHTS §6) |

## Keyboard shortcuts (`K-`) — 52

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `K-APP-SETTINGS` | ⌘, · `Settings…` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘, unchanged |
| `K-FILE-NEWPLAYLIST` | ⌘N · `New Playlist` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘N keeps one meaning: new playlist with inline rename in the sidebar (THOUGHTS §4.2) |
| `K-FILE-OPENLIB` | ⌘O · `Open Library…` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘O Open Library… unchanged; leads to the picker / A-LIB-SWITCH |
| `K-NAV-LIBRARY` | ⌘1 · `Library` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘1 now All Tracks (DEC-002) |
| `K-NAV-PLAYLISTS` | ⌘2 · `Playlists` | removed | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Playlists are sidebar rows, not one destination; ⌘2 is reassigned to Albums (DEC-003, THOUGHTS §4.2) |
| `K-NAV-FOLDERS` | ⌘3 · `Folders` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Folders moves from ⌘3 to ⌘4 (THOUGHTS §4.2) |
| `K-NAV-SYNC` | ⌘4 · `Sync` | removed | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Sync profiles are sidebar rows, there is no single Sync destination; ⌘4 is reassigned to Folders (DEC-027, THOUGHTS §4.2) |
| `K-NAV-SOURCES` | ⌘5 · `Sources` | removed | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Sources is no longer a destination; accounts live in Settings ▸ Sources, importing in the Add menu; ⌘5 is reassigned to Discover (DEC-004, THOUGHTS §4.2) |
| `K-NAV-REVIEW` | ⌘6 · `Review` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘6 Review unchanged |
| `K-NAV-DISCOVER` | ⌘7 · `Discover` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Discover moves from ⌘7 to ⌘5 (THOUGHTS §4.2) |
| `K-NAV-QUEUE` | ⌘8 · `Queue` | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘8 is gone; the Queue is a mode of the trailing column toggled with ⌥⌘U (DEC-006, THOUGHTS §4.2) |
| `K-PLAYBACK-STOP` | ⌘. · `Stop` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘. Stop unchanged |
| `K-PLAYBACK-SKIPBACK` | ⌘← · `Skip Back 10s` | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘← becomes Previous Track; seeking back 10 s moves to ⌥⌘← (DEC-047, THOUGHTS §4.2) |
| `K-PLAYBACK-SKIPFWD` | ⌘→ · `Skip Forward 10s` | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘→ becomes Next Track; seeking forward 10 s moves to ⌥⌘→ (DEC-047, THOUGHTS §4.2) |
| `K-LIBRARY-IMPORT` | ⌘⇧I · `Import from Folder…` | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | The dead Import from Folder… item is replaced by Import Files or Folder… (Add menu / File menu, no shortcut); ⇧⌘I now means Import Playlist from Source… (DEC-026, THOUGHTS §4.2) |
| `K-LIBRARY-MOREINFO` | ⌘I · `More Info` | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘I now works: show/hide Info for the selection (DEC-007) |
| `K-WIN-SEEKBACK` | ← (hold repeats) · — (no menu item) | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Bare ← seeks only while previewing (±5 s); otherwise the key belongs to the focused control and seeking is ⌥⌘← (DEC-047, THOUGHTS §4.2) |
| `K-WIN-SEEKFWD` | → (hold repeats) · — | merged | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Bare → seeks only while previewing (±5 s); otherwise seeking is ⌥⌘→ (DEC-047, THOUGHTS §4.2) |
| `K-SEARCH-CMDF` | ⌘F (no ⌥/⌃/⇧) · `Focus search field` | mocked | [search.html](search.html) | ⌘F focuses the system search field of the main window only (DEC-017); ⌥⌘F = Library scope |
| `K-SEARCH-RETURN` | Return in the search field | mocked | [search.html](search.html) | Return takes the first suggestion or moves focus to the results; no pane (DEC-017) |
| `K-SEARCH-ESC` | Escape in the search pane | mocked | [search.html](search.html) | Esc clears text and tokens, view as it was (DEC-017) |
| `K-SIDEBAR-QUEUE8` | ⌘8 · `Queue` | removed | [shell.html](shell.html) | DEC-006: Queue is no sidebar destination; ⌥⌘U shows the Queue column; ⌘8 unbound |
| `K-SIDEBAR-NAV` | (relation only; M-NAVIGATE is owned by shell.md): ⌘1 `Library`, ⌘2 `Playlists`, ⌘3 `Folder | mocked | [shell.html](shell.html) | ⌘1…⌘6 = All Tracks, Albums, Genres, Folders, Discover, Review (DEC-038); full map on patterns-menus-shortcuts.html |
| `K-SIDEBAR-RENAME` | Return commits, Escape cancels, in P-PINNED.E04 | mocked | [playlists.html](playlists.html) | Return commits, Esc cancels in the sidebar inline rename (same rule as K-PL-RENAME) |
| `K-SEARCH-UNIVERSAL-KEYS` | Return re-submits, Escape closes (S-SEARCH-UNIVERSAL). The advertised ⌘K and "tab to navig | removed | [search.html](search.html) | DEC-018: goes with the merged S-SEARCH-UNIVERSAL panel; Return/Esc of the search field replace it |
| `K-LIB-RESCAN` | ⌘R · `Re-scan Library` (toolbar button in V-LIB) | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌘R = refresh the current view's source of truth; the toolbar button P-TOOLBAR.E04 is removed (DEC-048) |
| `K-LIB-SPACE` | Space · *expected, missing*: preview/play the selected track (`.planning/REQUIREMENTS.md:1 | mocked | [player.html](player.html) | Space-bar rules table and live preview (DEC-009) |
| `K-LIB-DELETE` | ⌫ / ⌘⌫ · *expected, missing*: remove selection (Finder/Music convention). No delete comman | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | ⌫ removes from the current container, ⌘⌫ Remove from Library…; ⌫ in the queue is live on queue.html |
| `K-LIB-INFO` | ⌘I `More Info` (M-LIBRARY, owned by shell.md) | mocked | [inspector.html](inspector.html) | ⌘I shows/hides Info for the selection (DEC-007) |
| `K-LIB-RETURN` | Return on a selected row: whether the table's primary action (play + inspector) fires is n | mocked | [player.html](player.html) | Return / double-click plays, never opens the inspector (DEC-008); status-bar messages for non-local rows |
| `K-META-EDIT-RETURN` | Return · save the field being edited | mocked | [inspector.html](inspector.html) | Return, Tab or leaving the field commits |
| `K-META-EDIT-ESC` | Esc · cancel the inline edit (value discarded) | mocked | [inspector.html](inspector.html) | Esc reverts the field |
| `K-WAVE-PINCH` | trackpad pinch · zoom the waveform 0.5×–8× | unchanged | [inspector.html](inspector.html) | Pinch still zooms the waveform of long tracks (now on the Audio tab); zoom remembered |
| `K-STUDIO-MERGE-PRIMARY` | double-click (table primary action) | mocked | [genres.html#list](genres.html#list) | merge preview table is a standard track table: Return/double-click plays, Space previews (DEC-008/009); misleading caption removed |
| `K-PL-NEW` | ⌘N · button `New Playlist` | merged | [playlists.html](playlists.html) | THOUGHTS §4.2: ⌘N has one meaning app-wide (new playlist with inline rename); full map in patterns-menus-shortcuts.html |
| `K-PL-NEWPOPOVER-ESC` | Esc · `Cancel` in S-PL-NEWPLAYLIST | merged | [playlists.html](playlists.html) | Popover removed (see S-PL-NEWPLAYLIST); Esc in the inline rename keeps the default name (K-PL-RENAME) |
| `K-PL-NEWPOPOVER-RETURN` | Return · `Create` in S-PL-NEWPLAYLIST (default action) | merged | [playlists.html](playlists.html) | Popover removed (see S-PL-NEWPLAYLIST); Return in the inline rename commits (K-PL-RENAME) |
| `K-PL-RENAME` | Return saves / Esc cancels the inline card rename | mocked | [playlists.html](playlists.html) | Inline rename on card, sidebar row and detail title: Return commits, Esc cancels, click-away commits |
| `K-SYNC-REFRESH` | ⌘R · `Refresh` | mocked | [sync.html](sync.html) | ⌘R = Recompute plan, with progress and Cancel |
| `K-SYNC-NEWPROFILE-KEYS` | Escape = `Cancel`, Return = `Create` in S-SYNC-NEWPROFILE | mocked | [sync.html](sync.html) | Esc = Cancel, Return = Create in the sheet (Return is annotated, not wired in the mockup) |
| `K-SYNC-RENAME-KEYS` | Escape = `Cancel`, Return = `Rename` in S-SYNC-RENAME | merged | [sync.html](sync.html) | DEC-027: Return commits / Esc cancels the inline rename field in the sidebar |
| `K-SYNC-PICKER-RETURN` | Return = `Add (n)` in S-SYNC-PLAYLISTPICKER (no Escape binding for Cancel) | mocked | [sync.html](sync.html) | Return = Add, Esc = Cancel in the picker |
| `K-REMOTE-DONE` | toolbar `Done` in W-REMOTE with `.cancellationAction` placement | merged | [import.html](import.html) | DEC-026: the window's Done toolbar button becomes the sheet's Cancel (Esc); element carries the ID in S-IMPORT step 1 |
| `K-DISC-NAV` | ⌘7 · `Discover` in menu `Navigate` (M-NAVIGATE, owned by shell.md) | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Go ▸ Discover becomes ⌘5 (THOUGHTS §4.2, DEC-038); menu owned by the shortcuts catalogue |
| `K-REELS-RETURN` | Return in V-REELS.E08 search field | mocked | [discover.html#reels](discover.html#reels) | Return in Artist or Title searches; the third free-text field is merged into them |
| `K-REELS-LISTNAV` | ↑/↓ in the reel list (system list selection) | mocked | [discover.html#reels](discover.html#reels) | ↑/↓ in the reel list only selects; identification no longer starts per selection |
| `K-REELS-DELETE` | list deletion via SwiftUI `.onDelete` (on macOS presumably ⌫ / Edit ▸ Delete on the select | mocked | [discover.html#reels](discover.html#reels) | ⌫ on selected reels opens A-REELS-DELETE; also a visible Delete Reel… button and context menu |
| `K-REELS-KEYFRAME-ESC` | Esc · S-REELS-KEYFRAME open | mocked | [discover.html#reels](discover.html#reels) | Esc closes the keyframe popover |
| `K-SET-COOKIE-RETURN` | Return · label: none (text field submit) | covered by pattern | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | Return in the Qobuz cookie field saves, but no longer saves an empty value; field mocked in settings.html#sources |
| `K-SET-GW-TABLE-RETURN` | *(inferred)* — Return / double-click | merged | [genres.html#list](genres.html#list) | same shortcut as K-STUDIO-MERGE-PRIMARY (duplicate inventory entry); Return/double-click = play in the merge preview table (DEC-008) |
| `K-ACT-ESC` | Escape collapses the Activity panel | merged | [activity.html](activity.html) | DEC-005: the hidden Esc button of the bottom panel is gone; Esc closes the popover (system), Option-Command-0 opens the Activity window (keyboard table on activity.html) |
| `K-LOGS-COPY` | Select all / Copy in the log view | unchanged | [activity.html#logs](activity.html#logs) | Standard text-view Select All / Copy stays; a Copy button is added next to it |

## Drag & drop (`D-`) — 50

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `D-LIBFILE-OPEN` | Finder → MLM: double-click / Open With / drop a `.mlibm` on the MLM Dock icon. Payload: fi | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | Finder open / Dock drop of a library file; exhibit and queue-during-S-ADOPT note in launch.html (DEC-040) |
| `D-SIDEBAR-SPRINGLOAD` | a track drag (`UTType.trackDrag`) hovering over a sidebar row (P-SIDEBAR rows, the P-PINNE | mocked | [shell.html](shell.html) | Sidebar rows now accept the drop (DEC-040); spring-loading stays as system behaviour |
| `D-QUEUE-ROWS` | V-QUEUE rows can be dragged out as `TrackDragData` (track id, no source playlist) to any t | mocked | [queue.html](queue.html) | Queue rows drag out (live: onto sidebar playlists) and reorder |
| `D-SEARCH-ROWS` | V-SEARCH results can be dragged out the same way | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | Result rows drag like any track rows (noted on search.html) |
| `D-LIB-TRACK-OUT` | source: rows in V-LIB, V-SEARCH, V-QUEUE (all `TrackTable`) and V-FOLD → targets: Playlist | covered by pattern | [patterns-dnd.html](patterns-dnd.html) |  |
| `D-LIB-SPRING` | Spring-loaded sidebar: while a track drag hovers ≥ 0.6 s over any sidebar section row, the | mocked | [shell.html](shell.html) | Same exhibit as D-SIDEBAR-SPRINGLOAD: rows accept drops directly (DEC-040) |
| `D-PL-TRACKS-TO-CARD` | source: track rows from V-LIB (library.md), V-PLD, V-FOLD, or the Library table in another | mocked | [playlists.html](playlists.html) | DEC-040: simulated ("Tracks → card"): accent ring, appended, status-bar confirmation with Undo |
| `D-PL-COVER-TO-CARD` | source: an image file from Finder, or an image dragged from another app | mocked | [playlists.html](playlists.html) | DEC-040: simulated ("Image → card cover"), incl. the rejected drop as inline error |
| `D-PL-SPRINGLOAD-CARD` | hovering a track drag over a card for 0.6 s opens that playlist's detail mid-drag, so the  | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: spring-loading stays as system behaviour but is never required (cards and sidebar rows accept drops directly) |
| `D-PLD-REORDER` | source: rows of V-PLD.E15 (multi-row) | mocked | [playlists.html#detail](playlists.html#detail) | Insertion line illustrated (tr.drop-before); reorder hint line when sorted by another column |
| `D-PLD-INSERT` | source: track rows from elsewhere (Library, Folders, another playlist) arriving via spring | mocked | [playlists.html#detail](playlists.html#detail) | Simulated ("Tracks → between rows"): insertion line + status-bar text |
| `D-PLD-ROWS-OUT` | rows in V-PLD are draggable carrying their source playlist id … | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: rows are Transferable (IDs + file URLs); dropping on another playlist adds |
| `D-FOLD-TRACKS-OUT` | rows of V-FOLD.E10 are draggable (`MLM/Views/Folders/FoldersView.swift:629-632`). They rea | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: unchanged behaviour, track rows of the outline are draggable; noted on folders.html |
| `D-REELS-IMPORT` | Finder video files/folders → Reels | mocked | [discover.html#reels](discover.html#reels) | Drop hint in the list and in the empty state; whole view is the drop target (DEC-040) |
| `D-LOGS-TEXTDRAG` | drag selected log text out | unchanged | [activity.html#logs](activity.html#logs) | System drag of selected log text stays (text view unchanged); listed in the keyboard/drag table |
| `D-LIBFILE-WINDOWDROP` | *expected, missing*: dropping a `.mlibm` onto the main window (esp. V-LAUNCH-NOLIB) does n | mocked | [launch.html](launch.html) | Now exists: drop a .mlibm on the picker / window; drop hint with highlight in state picker (DEC-040) |
| `D-WIZ-FOLDERDROP` | *expected, missing*: dropping a music folder onto S-WIZARD step 2 is not supported … | mocked | [launch.html](launch.html) | Now exists: folder drop target in state setup-2 (DEC-040) |
| `D-LIB-FINDER-IN` | *expected, missing*: drag audio files/folders from Finder onto the Library table to import | covered by pattern | [patterns-dnd.html](patterns-dnd.html) |  |
| `D-LIB-TO-FINDER` | *expected, missing*: drag tracks out to Finder, DJ software or a mail/chat app as files. T | covered by pattern | [patterns-dnd.html](patterns-dnd.html) |  |
| `D-LIB-TO-SIDEBAR-NEWPL` | *expected, missing*: drop a selection on the sidebar (or a sidebar playlist) to create/add | mocked | [shell.html](shell.html) | Drop on a playlist row / on the Playlists header exhibit (DEC-040) |
| `D-LIB-TO-QUEUE` | *expected, missing*: drag tracks onto the player bar or Queue to queue them (`Play Next` e | mocked | [queue.html](queue.html) | Drop on the player = Play Next; Queue column top half Play Next, bottom half Add to Queue |
| `D-LIB-TO-SYNC` | *expected, missing*: drop tracks on a sync profile (Sync spring-loads but has no drop targ | mocked | [shell.html](shell.html) | Sync profile row as drop target exhibit (DEC-027) |
| `D-TD-TRACK-OUT` | *(missing)* — drag the inspected track (cover/title) onto a sidebar playlist or into Finde | mocked | [inspector.html](inspector.html) | Inspector cover is a drag source for the track (DEC-040) |
| `D-GROOVE-ROW-TO-PLAYLIST` | *(missing)* — drag a local match / recommendation row from S-GROOVE-SIMILAR or P-INSPECTOR | mocked | [discover.html#similar](discover.html#similar) | In-library rows are a standard track table, online rows are draggable; drop on sidebar playlists / sync profiles (DEC-040) |
| `D-TD-ARTWORK-IN` | *(missing)* — drop an image onto the inspector cover to set artwork (standard in Music/Get | mocked | [inspector.html](inspector.html) | Cover drop-target exhibit (DEC-040) |
| `D-STUDIO-TRACK-TO-GENRE` | *(missing)* — drag suggestions onto the genre column instead of thumbs-up staging. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | expected-missing drag; designed as "drag a suggestion onto the genre's track table = stage" and "drop tracks on a genre row = set genre" (described in element notes on genres.html, DEC-040), not interactive in the mockup |
| `D-PL-TRACKS-TO-PINNED` | (missing) — dropping tracks directly on a pinned sidebar playlist adds them. Today pinned  | mocked | [playlists.html](playlists.html) | DEC-003/DEC-040: now exists — every sidebar playlist row accepts dropped tracks (simulated "Tracks → sidebar playlist") |
| `D-PL-SELECTION-TO-NEW` | (missing) — drop a selection on the sidebar or grid background to create a new playlist fr | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: drop on the Playlists header or empty sidebar area creates a playlist from the selection (inline name) |
| `D-PL-PLAYLIST-TO-FOLDER` | (missing) — group playlists into playlist folders; no playlist folders exist. | mocked | [playlists.html](playlists.html) | DEC-003/DEC-040: now exists — playlist folders accept dropped playlists (simulated "Playlist → playlist folder"); also Move to Folder in the menus |
| `D-PL-CARD-REORDER` | (missing) — arrange cards or pinned playlists manually. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-003: Manual order = sidebar order; rows and cards reorder by drag (described on V-PL.E08, not animated) |
| `D-PLD-COVER-TO-HEADER` | (missing) — drop an image on the 64 pt detail cover. | mocked | [playlists.html#detail](playlists.html#detail) | DEC-040: now exists — the 160 pt header cover is a drop target (simulated "Image → detail cover") |
| `D-PLD-M3U-FROM-FINDER` | (missing) — drop an .m3u/.m3u8 file on the grid or detail. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: .m3u dropped on the Playlists section imports as playlist; on an open playlist it opens S-PLD-M3U-PREVIEW |
| `D-FOLD-FOLDER-TO-PLAYLIST` | (missing) — drag a disk folder onto a playlist to add all its tracks. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: folder rows are draggable onto playlists and sync profiles; menu equivalent Add to Playlist is mocked on folders.html |
| `D-FOLD-FILES-FROM-FINDER` | (missing) — drop audio files on a folder to import them. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: audio files dropped on a folder row import there (Activity operation); noted on V-FOLD.E04 |
| `D-PLD-ROWS-TO-FINDER` | (missing) — drag tracks out to Finder or another app as files. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: public.file-url representation for local tracks |
| `D-SYNC-PLAYLIST-TO-PROFILE` | (expected, missing) — drag playlists from V-PL / sidebar pins onto a profile row or the Pl | mocked | [sync.html](sync.html) | Sidebar profile rows are drop targets (exhibit; Content rows can be dragged onto the real rows), DEC-040 |
| `D-SYNC-TRACKS-TO-PROFILE` | (expected, missing) — drag tracks from V-LIB / V-PLD / V-FOLD onto a profile. Today only C | mocked | [sync.html](sync.html) | Same drop target for tracks and albums, status-bar confirmation with Undo, DEC-040 |
| `D-SYNC-FOLDER-TO-OUTPUT` | (expected, missing) — drop a Finder folder or mounted volume onto `Output folder`. | mocked | [sync.html](sync.html) | Destination in the new-profile sheet accepts a dropped folder or disk, DEC-040 |
| `D-SYNC-REORDER-PROFILES` | (expected, missing) — reorder profiles in V-SYNC (list order is DB order). | mocked | [sync.html](sync.html) | Insertion line in the sidebar exhibit, DEC-040 |
| `D-REMOTE-URL-DROP` | (expected, missing) — a playlist URL dragged from the browser onto V-SRC's YouTube card, o | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-018/DEC-040: a link dropped on the window or search field opens S-QUICKADD (track) or S-IMPORT step 2 (playlist); target sheets mocked on import.html |
| `D-REMOTE-PLAYLIST-TO-SIDEBAR` | (expected, missing) — drag a remote playlist row to the sidebar/Playlists to import it. | removed |  | DEC-026: the account playlist list now lives in a modal sheet (S-IMPORT step 1), so there is no sidebar to drag to; replaced by clicking the row (preview) and by dropping a playlist link on the window (D-REMOTE-URL-DROP) |
| `D-REV-TRACK-OUT` | (expected, missing) — drag a Review version row into a playlist or Finder. | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | DEC-040: Review version rows are tracks and use the standard track drag payload (IDs + file URL); not mocked interactively on review.html |
| `D-INBOX-TO-PLAYLIST` | (missing) — drag a recommendation row onto a sidebar playlist / P-PINNED. Evidence: daily- | mocked | [discover.html#recs](discover.html#recs) | Drag a recommendation onto a sidebar playlist = keep and add (DEC-040) |
| `D-REELS-RESULT-TO-PLAYLIST` | (missing) — drag a search result onto a playlist instead of the ⊕ menu. | mocked | [discover.html#reels](discover.html#reels) | Result rows drag onto sidebar playlists (DEC-040) |
| `D-REELS-URL` | (missing) — drop an Instagram/TikTok link (text/URL) to fetch the reel; today only local f | mocked | [discover.html#reels](discover.html#reels) | Add from Link… sheet (S-REELS-LINK) and link drop (DEC-018/DEC-040) |
| `D-REELS-OUT` | (missing) — drag a reel row out to Finder / reveal; rows are not draggable. | mocked | [discover.html#reels](discover.html#reels) | Reel rows are draggable as file URLs (annotated on the reel list); Show in Finder in the reel context menu |
| `D-SET-FOLDER-TO-LIBROOT` | (expected, missing) — Finder folder → ST-LIB.E06 to set the music folder, or → ST-LIB `Imp | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | Now exists: path rows accept a folder from Finder; annotated on the Library folder group in settings.html#library (DEC-040) |
| `D-SET-GW-TRACK-TO-GENRE` | (expected, missing) — track row (ST-ADV.E11/E14 or a V-LIB selection) → genre card / `Trac | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | expected-missing drag; same design as D-STUDIO-TRACK-TO-GENRE (tracks → genre row or genre track table sets/stages the genre, DEC-040) |
| `D-SET-GW-TRACK-OUT` | (expected, missing) — Genre Workshop rows → sidebar playlist (build-playlist flow; CM-TRAC | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | expected-missing drag; genre and suggestion rows are standard track rows and drag to sidebar playlists / sync profiles / Finder like every track table (DEC-040) |
| `D-SET-FOLDER-TO-DESTINATION` | (expected, missing) — Finder folder → backup folder row / transcode cache row / CreateML d | covered by pattern | [patterns-dnd.html](patterns-dnd.html) | Now exists for the backup folder and transcode cache rows; annotated in settings.html#backup (DEC-040) |

## Flows (`F-`) — 24

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `F-01` | First launch with no library | mocked | [launch.html#setup-1](launch.html#setup-1) |  |
| `F-02` | First launch of an A3 build: turn the old install into a library file | mocked | [launch.html#adopt](launch.html#adopt) |  |
| `F-03` | Daily listening session: browse → preview with Space → play → queue | mocked | [library.html](library.html) · [player.html](player.html) · [queue.html](queue.html) |  |
| `F-04` | Find a track fast (search) | mocked | [search.html](search.html) |  |
| `F-05` | Import a YouTube / SoundCloud / Spotify playlist and download it | mocked | [import.html](import.html) → [playlists.html#detail](playlists.html#detail) → [activity.html](activity.html) |  |
| `F-06` | Download one track from a pasted URL | mocked | [import.html#quickadd](import.html#quickadd) · [search.html](search.html) (state link) |  |
| `F-07` | Fix failed downloads | mocked | [library.html](library.html) (scope Download failed) · [playlists.html#detail](playlists.html#detail) · [activity.html](activity.html) |  |
| `F-08` | Create and fill a playlist (drag & drop, multi-select) | mocked | [playlists.html](playlists.html) · [library.html](library.html) (selection bar) · [patterns-dnd.html](patterns-dnd.html) |  |
| `F-09` | Organize via folders | mocked | [folders.html](folders.html) |  |
| `F-10` | Sync a profile to a device and handle failures | mocked | [sync.html](sync.html) |  |
| `F-11` | Pull playlist changes back from a device (device ingest) | mocked | [sync.html](sync.html) (Read Playlist Changes from Device sheet) |  |
| `F-12` | Review duplicates and metadata conflicts | mocked | [review.html](review.html) |  |
| `F-13` | Edit metadata in the inspector | mocked | [inspector.html](inspector.html) |  |
| `F-14` | Discover: get recommendations, listen, keep or delete | mocked | [discover.html](discover.html) · [discover.html#similar](discover.html#similar) |  |
| `F-15` | Reels: identify the song in a saved video and get it | mocked | [discover.html#reels](discover.html#reels) |  |
| `F-16` | Back up and restore | mocked | [settings.html#backup](settings.html#backup) |  |
| `F-17` | Switch / create / open a library file (incl. Finder double-click) | mocked | [launch.html](launch.html) (picker, switch, new, copy) |  |
| `F-18` | External drive unplugged mid-session | mocked | every main-window page via the Drive switch · [patterns-states.html](patterns-states.html) |  |
| `F-19` | Settings changes: library folder, sources sign-in, transcode cache | mocked | [settings.html](settings.html) |  |
| `F-20` | A source sign-in has expired | mocked | [settings.html#sources](settings.html#sources) · [import.html](import.html) · [activity.html](activity.html) |  |
| `F-21` | Genre tagging and ML export (Genre Workshop) | mocked | [genres.html](genres.html) |  |
| `F-22` | Run an analysis batch (Maintenance) | mocked | [settings.html#maintenance](settings.html#maintenance) · [activity.html](activity.html) |  |
| `F-23` | Link a playlist to a source / import an M3U file | mocked | [playlists.html#detail](playlists.html#detail) (Link Source, Import M3U sheets) |  |
| `F-24` | Albums (future flow) | mocked | [albums.html](albums.html) · [review.html#albums](review.html#albums) |  |

## Global states (`G-`) — 44

| ID | Today | Status | Where | Reason / what replaces it |
|---|---|---|---|---|
| `G-LIB-RESOLVING` | Deciding which library to open (order: interrupted adoption → file opened from Finder → le | mocked | [launch.html](launch.html) (state loading) |  |
| `G-LIB-LOADING` | Library DB and services starting | mocked | [launch.html](launch.html) (state loading) |  |
| `G-LIB-FAILED` | Library failed to open | mocked | [launch.html](launch.html) (state failed) |  |
| `G-LIB-NONE` | No library open | mocked | [launch.html](launch.html) (state picker) |  |
| `G-LIB-NOTFOUND` | Library file not at its last location / on a disk that isn't connected | mocked | [launch.html](launch.html) (picker row state; state cant-open) |  |
| `G-LIB-MISMATCH` | Library-file identity doesn't match registry/DB | mocked | [launch.html](launch.html) (state cant-open) |  |
| `G-LIB-INVALID` | Not a valid library file | mocked | [launch.html](launch.html) (state invalid) |  |
| `G-LIB-COPY` | Library file is a Finder copy of another (same `library_id`) | mocked | [launch.html](launch.html) (state copy) |  |
| `G-LIB-ADOPT-PENDING` | Old single-DB layout not yet turned into a library file | mocked | [launch.html](launch.html) (state adopt; picker row “needs setup”) |  |
| `G-LIB-ADOPT-INTERRUPTED` | Adoption journal found at launch | mocked | [launch.html](launch.html) (state loading, phase “Finishing library file setup…”) |  |
| `G-LIB-LEGACY` | Running on the old layout after `Not now` | mocked | [launch.html](launch.html) (picker row “needs setup”) |  |
| `G-LIB-SWITCH-PENDING` | User picked another library; app must relaunch | mocked | [launch.html](launch.html) (state switch) |  |
| `G-LIB-CURRENT` | Which library is open | mocked | [shell.html](shell.html) (window subtitle, library footer) |  |
| `G-ROOT-NONE` | No library folder configured | mocked | [launch.html](launch.html) (setup-2) · [folders.html](folders.html) (state empty) · [settings.html#library](settings.html#library) |  |
| `G-DRIVE-OFFLINE` | Library folder's volume not mounted | mocked | every main-window page (Drive switch) · [patterns-states.html](patterns-states.html) |  |
| `G-DRIVE-BOOT` | Library folder on the boot volume | mocked | [patterns-states.html](patterns-states.html) |  |
| `G-DEVICE-OFFLINE` | A sync target (device/folder) is not connected | mocked | [sync.html](sync.html) (state not-connected) |  |
| `G-SRC-CONNECTED` | Signed in | mocked | [settings.html#sources](settings.html#sources) |  |
| `G-SRC-DISCONNECTED` | Not signed in | mocked | [settings.html#sources](settings.html#sources) |  |
| `G-SRC-EXPIRED` | Sign-in expired | mocked | [settings.html#sources](settings.html#sources) · [import.html](import.html) · [activity.html](activity.html) |  |
| `G-SRC-KEYCHAIN` | Token stored but keychain unreadable | mocked | [settings.html#sources](settings.html#sources) |  |
| `G-SRC-CREDS-MISSING` | Client ID missing from the credentials file | mocked | [settings.html#sources](settings.html#sources) |  |
| `G-SRC-APPLEMUSIC` | Apple Music not implemented | mocked | [settings.html#sources](settings.html#sources) (“Not available yet”) |  |
| `G-SRC-QOBUZ-COOKIE` | Squid/Qobuz captcha cookie state | mocked | [settings.html#sources](settings.html#sources) |  |
| `G-TRK-LOCAL` | `local` | mocked | [library.html](library.html) |  |
| `G-TRK-DOWNLOADING` | `downloading` | mocked | [library.html](library.html) |  |
| `G-TRK-NOTDOWNLOADED` | `notDownloaded` | mocked | [library.html](library.html) |  |
| `G-TRK-FAILED` | `failed(reason, date, attempts)` | mocked | [library.html](library.html) (scope Download failed) · [inspector.html](inspector.html) |  |
| `G-TRK-MISSING` | `fileMissing` | mocked | [library.html](library.html) · [inspector.html](inspector.html) |  |
| `G-TRK-PLACEHOLDER` | metadata placeholder | mocked | [library.html](library.html) (Album column “—”, DEC-013) |  |
| `G-TRK-DUPLICATE` | Track marked as possible duplicate after a Review decision | mocked | [inspector.html](inspector.html) (File tab) · [review.html](review.html) |  |
| `G-PL-LOCAL` | nothing extra | mocked | [playlists.html](playlists.html) |  |
| `G-PL-LINKED` | source name as text | mocked | [playlists.html](playlists.html) |  |
| `G-PL-IMPORTING` | `Importing · 12 of 44` | mocked | [playlists.html#detail](playlists.html#detail) |  |
| `G-PL-INCOMPLETE` | `Incomplete · 9 failed` | mocked | [playlists.html#detail](playlists.html#detail) |  |
| `G-PL-NOTDOWNLOADED` | — (not in §1.6) | mocked | [playlists.html#detail](playlists.html#detail) (new state word, DEC-023) |  |
| `G-PL-SRC-DISCONNECTED` | `SoundCloud disconnected — reconnect in Settings` | mocked | [playlists.html#detail](playlists.html#detail) |  |
| `G-PL-DRIVE-OFFLINE` | — | mocked | [playlists.html](playlists.html) (Drive switch) |  |
| `G-BG-ACTIVE` | Something is running | mocked | [activity.html](activity.html) · [shell.html](shell.html) (Activity item) |  |
| `G-JOB-STATUS` | Job lifecycle | mocked | [activity.html](activity.html) |  |
| `G-JOB-SILENT` | Work with lasting effects but no UI | mocked | [activity.html](activity.html) (every job is an operation, DEC-044) |  |
| `G-TOOL-MISSING` | External tool missing (yt-dlp, ffmpeg, fpcalc, scdl) | mocked | [settings.html#sources](settings.html#sources) (Download tools) · [activity.html](activity.html) |  |
| `G-PLAYBACK-ERROR` | Track can't be played | mocked | [player.html](player.html) |  |
| `G-LIB-NOTCONNECTED` | Library file not at its last location / on a disk that isn't connected | mocked | [launch.html](launch.html) (picker row state; state cant-open) |  |

## New in this design — 66 IDs

Screens, sheets, alerts and menus that do not exist in the app today.

| ID | Where | Note |
|---|---|---|
| `A-ALB-REMOVE` | [albums.html#grid](albums.html#grid) | new |
| `A-LIBFILE-INVALID.N01` | [launch.html](launch.html) | new |
| `A-LOGS-CLEAR` | [activity.html#logs](activity.html#logs) | new: confirmation for Clear... in Logs |
| `A-REV-ALBBULK` | [review.html#albums](review.html#albums) | new: confirmation for Accept All Above 90 % (DEC-021) |
| `A-REV-APPLYALL` | [review.html](review.html) | new: confirmation for Apply Recommended to All (DEC-028) |
| `A-SET-CACHECLEAR` | [settings.html#maintenance](settings.html#maintenance) | New: confirmation for Clear Cache… |
| `A-SET-COOKIECLEAR` | [settings.html#sources](settings.html#sources) | New: confirmation for clearing the Qobuz cookie |
| `CM-ALB-CARD` | [albums.html#grid](albums.html#grid) | new |
| `CM-ALBD-ABSENT` | [albums.html#detail](albums.html#detail) | new |
| `CM-ALBD-MORE` | [albums.html#detail](albums.html#detail) | new |
| `CM-GENRE-ROW` | [genres.html#list](genres.html#list) | new |
| `CM-GENRED-MORE` | [genres.html#detail](genres.html#detail) | new |
| `CM-OPS-ROW` | [activity.html](activity.html) | new: context menu on operation rows (DEC-039) |
| `CM-QUEUE` | [queue.html](queue.html) | New: queue row context menu in DEC-039 order, ends with Remove from Queue |
| `CM-QUEUE.N01` | [queue.html](queue.html) | new |
| `CM-REV-ALBUM` | [review.html#albums](review.html#albums) | new: context menu on album-suggestion rows (DEC-039) |
| `CM-REV-GROUP` | [review.html](review.html) | new: context menu on duplicate/conflict group rows (DEC-039) |
| `CM-REV-VERSION` | [review.html](review.html) | new: context menu on version rows (DEC-039) |
| `CM-SUB-COPY` | [patterns-context-menus.html](patterns-context-menus.html) | new |
| `CM-SUB-MOVE` | [patterns-context-menus.html](patterns-context-menus.html) | new |
| `CM-SUB-PLAYLIST` | [patterns-context-menus.html](patterns-context-menus.html) | new |
| `CM-SUB-SYNC` | [patterns-context-menus.html](patterns-context-menus.html) | new |
| `ICON-MLIBM` | [library-icon.html](library-icon.html) | new |
| `M-APP.E07/alert` | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | new |
| `M-TRACK` | [patterns-menus-shortcuts.html](patterns-menus-shortcuts.html) | new |
| `P-ACTIVITY/B` | [activity.html](activity.html) | new: variant B exhibit (bottom strip), DEC-005 alternative |
| `P-ADDMENU` | [shell.html](shell.html) | New (DEC-004, DEC-026); menu exhibit here, sheets on import.html |
| `P-LIBFOOTER` | [shell.html](shell.html) | New (DEC-031); switching flow on launch.html |
| `P-LIBFOOTER.N01` | [shell.html](shell.html) | new |
| `P-PREVIEW` | [player.html](player.html) | New (DEC-009, DEC-010) |
| `P-QUEUE` | [queue.html](queue.html) | New (DEC-006) |
| `P-QUEUE.N15` | [queue.html](queue.html) | new |
| `P-SIDEBAR.E03/add` | [playlists.html](playlists.html) | new |
| `P-SIDEBAR.N03/menu` | [playlists.html](playlists.html) | new |
| `S-ALB-EDIT` | [albums.html#detail](albums.html#detail) | new |
| `S-ALB-MERGE` | [albums.html#detail](albums.html#detail) | new |
| `S-DISC-FIND` | [discover.html](discover.html) | New sheet: Find Recommendations (seed + source), DEC-029 |
| `S-IMPORT` | [import.html](import.html) | new screen ID (THOUGHTS 3.3) |
| `S-LAUNCH-RESTORE` | [launch.html](launch.html) | New: Restore from Backup sheet reachable from the failed state and from a mismatched row (DEC-031) |
| `S-PLFOLDER-NEW` | [playlists.html](playlists.html) | New (DEC-003): new playlist folder as inline rename in the sidebar (⌥⌘N, section ＋, Add menu) |
| `S-QUICKADD` | [import.html#quickadd](import.html#quickadd) | new screen ID (THOUGHTS 3.3) |
| `S-REELS-LINK` | [discover.html#reels](discover.html#reels) | New sheet: Add Reel from Link, DEC-018 |
| `S-SET-LIBFOLDER` | [settings.html#library](settings.html#library) | New: change-library-folder consequences sheet (DEC-035) |
| `S-SET-RENAMELIB` | [settings.html#library](settings.html#library) | New: rename library sheet |
| `S-SYNC-DESTINATION` | [sync.html](sync.html) | New sheet: Change Destination…, DEC-027 |
| `ST-ADVANCED` | [settings.html#advanced](settings.html#advanced) | New content of the Advanced tab: credentials file, diagnostics, list cache, tips; replaces ST-ADV, whose Genre Workshop moved to genres.html (DEC-025) |
| `ST-BACKUP.N04` | [settings.html#backup](settings.html#backup) | new |
| `ST-GENERAL` | [settings.html#general](settings.html#general) | New tab: launch behaviour, space bar, notifications (DEC-035, DEC-009) |
| `V-ALB` | [albums.html#grid](albums.html#grid) | new |
| `V-ALBD` | [albums.html#detail](albums.html#detail) | new |
| `V-FOLD.N02/menu` | [folders.html](folders.html) | new |
| `V-GENRED` | [genres.html#detail](genres.html#detail) | new |
| `V-GENRES` | [genres.html#list](genres.html#list) | new |
| `V-GENRES.N02` | [genres.html#list](genres.html#list) | new |
| `V-INBOX.N07` | [discover.html#recs](discover.html#recs) | new |
| `V-PICKER` | [launch.html](launch.html) | New: library picker (DEC-031) |
| `V-PICKER.N14` | [launch.html](launch.html) | new |
| `V-PLD.E02/menu` | [playlists.html#detail](playlists.html#detail) | new |
| `V-PLD.N01/menu` | [playlists.html#detail](playlists.html#detail) | new |
| `V-REELS.N09` | [discover.html#reels](discover.html#reels) | new |
| `V-SETUP` | [launch.html](launch.html) | New: in-window first-run setup, states setup-1 … setup-done (DEC-034) |
| `V-SIMILAR` | [discover.html#similar](discover.html#similar) | New screen (DEC-030) |
| `V-SIMILAR.N08` | [discover.html#similar](discover.html#similar) | new |
| `V-SYNC-DETAIL.N10` | [sync.html](sync.html) | new |
| `V-TRACK-TABLE.N01` | [library.html](library.html) | new |
| `W-ACTIVITY` | [activity.html](activity.html) | new screen ID (THOUGHTS 3.3) |
