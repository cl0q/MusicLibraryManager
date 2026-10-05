# MLM B1 — feedback template

Fallback for the in-page comment mode: write your note after the colon of any line; delete nothing, leave lines empty if you have no remark. IDs are stable — `X.E..` = element that exists today, `X.N..` = new element, `/A` = variant, `DEC-` = decision (THOUGHTS.md §8), `Q` = question (THOUGHTS.md §9).
Every ID is listed once, under the page where it is best seen (shell elements under `shell.html`). Press **A** on a page to see the IDs on the elements.

## Questions (THOUGHTS.md §9)

- Q1 — Space bar: preview the selected track (Finder feel) or always play/pause (Music feel)?: 
- Q2 — Activity: are you comfortable losing the always-visible bottom strip for a toolbar item + popover + window?: 
- Q3 — Sources leaves the sidebar — accounts in Settings, importing from the ＋ menu. Do you open Sources often enough to want a row?: 
- Q4 — Review may move unkept duplicates to the Trash (your choice per session, default off). OK to let Review touch files?: 
- Q5 — Recommendations stay out of All Tracks until kept. Or should downloads from Discover count as library tracks immediately?: 
- Q6 — YouTube mixes / live sets / video-only uploads: album stays empty (No album is a deliberate, accepted value) with the channel as artist?: 
- Q7 — Write tag edits to the files by default (so shared/synced copies are correct), never writing the source anywhere?: 
- Q8 — Library-file icon: crate (A), sleeves (B) or document (C)?: 
- Q9 — Genres as a sidebar row — worth a permanent place?: 
- Q10 — Raise the deployment target to macOS 26? Everything here works on 15 with fallbacks, but the selection bar and header extension only *shine* on 26+.: 
- Q11 — Album and playlist cards: single click selects and double-click opens (Finder, as mocked), or single click opens (Music)?: 
- Q12 — Similar ▸ Online: Download puts a suggestion into Discover for a verdict; should there also be Keep (download straight into the library)?: 
- Q13 — Sync profile menu: add Eject "‹device›"? MLM has no eject today.: 

## Decisions (THOUGHTS.md §8)

- DEC-001 — Sidebar structure?: 
- DEC-002 — Name of the tracks row?: 
- DEC-003 — Where do playlists live?: 
- DEC-004 — Sources as a destination?: 
- DEC-005 — Where is Activity?: 
- DEC-006 — Where is the Queue?: 
- DEC-007 — Inspector behaviour?: 
- DEC-008 — Double-click / Return?: 
- DEC-009 — Space bar?: 
- DEC-010 — Where does the preview show?: 
- DEC-011 — Local/Remote split?: 
- DEC-012 — Columns?: 
- DEC-013 — unknown album and source-as-album?: 
- DEC-014 — Drive not connected?: 
- DEC-015 — Multi-selection affordance?: 
- DEC-016 — Confirmations of silent actions?: 
- DEC-017 — Search behaviour?: 
- DEC-018 — Paste a link?: 
- DEC-019 — Album order model?: 
- DEC-020 — Edition chooser?: 
- DEC-021 — Tracks without album?: 
- DEC-022 — Playlist actions?: 
- DEC-023 — Words for playlist states?: 
- DEC-024 — Folders layout?: 
- DEC-025 — Genre Workshop home?: 
- DEC-026 — Import UI?: 
- DEC-027 — Sync profiles?: 
- DEC-028 — Review consequences?: 
- DEC-029 — Recommendations in the library?: 
- DEC-030 — Similar tracks surface?: 
- DEC-031 — Library picker?: 
- DEC-032 — Switching with running work?: 
- DEC-033 — Library-file icon?: 
- DEC-034 — First run?: 
- DEC-035 — Settings structure?: 
- DEC-036 — Backup controls?: 
- DEC-037 — External tools?: 
- DEC-038 — Menu bar?: 
- DEC-039 — Context-menu order?: 
- DEC-040 — Drag payload?: 
- DEC-041 — Undo scope?: 
- DEC-042 — Glass policy?: 
- DEC-043 — Colour?: 
- DEC-044 — Background work rule?: 
- DEC-045 — Unplayable track in the queue?: 
- DEC-046 — Energy / Dance?: 
- DEC-047 — Arrow-key seeking?: 
- DEC-048 — Section actions in the toolbar?: 
- DEC-049 — Deleting a playlist?: 
- DEC-050 — Dismissing a recommendation / removing from a playlist, queue or sync profile?: 
- DEC-051 — Dim Download failed rows (UI-GROUNDTRUTH §1.6)?: 
- DEC-052 — Default button of destructive alerts?: 
- DEC-053 — ⌘↓ / ⌘↑?: 

## shell.html — Shell: window, sidebar, toolbar

Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-009, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-026, DEC-027, DEC-028, DEC-029, DEC-031, DEC-034, DEC-038, DEC-039, DEC-040, DEC-044, DEC-045, DEC-048

### A-TRACK-REMOVE — Remove from Library confirmation

- A-TRACK-REMOVE (Remove from Library confirmation): 

### CM-TRACK — Track context menu

- CM-TRACK (Track context menu): 
- CM-TRACK.E02: 
- CM-TRACK.E03: 
- CM-TRACK.E04: 
- CM-TRACK.E05: 
- CM-TRACK.E06: 
- CM-TRACK.E07: 
- CM-TRACK.E08: 
- CM-TRACK.E09: 
- CM-TRACK.N01: 
- CM-TRACK.N02: 
- CM-TRACK.N03: 
- CM-TRACK.N04: 
- CM-TRACK.N05: 
- CM-TRACK.N06: 
- CM-TRACK.N07: 

### G-DRIVE-OFFLINE — Drive not connected banner

- G-DRIVE-OFFLINE (Drive not connected banner): 

### K-SIDEBAR-NAV — ⌘1…⌘6

- K-SIDEBAR-NAV (⌘1…⌘6): 

### K-SIDEBAR-QUEUE8 — ⌘8 Queue (removed)

- K-SIDEBAR-QUEUE8 (⌘8 Queue (removed)): 

### P-ACTIVITY — Activity item

- P-ACTIVITY (Activity item): 
- P-ACTIVITY.N01 (Activity item: Idle): 
- P-ACTIVITY.N02 (Activity item: Running): 
- P-ACTIVITY.N03 (Activity item: Running, several jobs): 
- P-ACTIVITY.N04 (Activity item: Needs attention): 
- P-ACTIVITY.N05 (Activity item: Running and needs attention): 
- P-ACTIVITY.N06 (Activity item: Waiting for the drive): 

### P-ACTIVITY-OPS — Activity popover

- P-ACTIVITY-OPS (Activity popover): 

### P-ADDMENU — Add menu

- P-ADDMENU (Add menu): 
- P-ADDMENU.N01 (Add menu items): 

### P-INSPECTOR — Info (track inspector)

- P-INSPECTOR (Info (track inspector)): 

### P-LIBFOOTER — Library footer (switcher)

- P-LIBFOOTER (Library footer (switcher)): 
- P-LIBFOOTER.N01 (Library menu): 
- P-LIBFOOTER.N02 (Library footer: drive not connected): 
- P-LIBFOOTER.N03 (Library footer: long name): 

### P-PINNED

- P-PINNED.E01 (All Playlists row): 
- P-PINNED.E02 (Warm-up row): 
- P-PINNED.E04 (Inline rename field): 

### P-PLAYER — Player (toolbar, .principal)

- P-PLAYER (Player (toolbar, .principal)): 
- P-PLAYER.E01 (Previous): 
- P-PLAYER.E02 (Play/Pause): 
- P-PLAYER.E03 (Next): 
- P-PLAYER.E04 (Cover (click: large cover popover)): 
- P-PLAYER.E05 (Title / artist / state line): 
- P-PLAYER.E08 (Elapsed / duration): 
- P-PLAYER.E09 (Scrubber (waveform while previewing)): 
- P-PLAYER.E10 (Volume (persisted)): 
- P-PLAYER.N01 (Queue button): 

### P-QUEUE — Queue

- P-QUEUE (Queue): 

### P-SELBAR — Selection bar

- P-SELBAR (Selection bar): 
- P-SELBAR.N01 (Play Next): 
- P-SELBAR.N02 (Add to Playlist ▾): 
- P-SELBAR.N03 (Edit Info): 
- P-SELBAR.N04 (Download (only if some are not downloaded)): 
- P-SELBAR.N05 (More): 

### P-SIDEBAR — Sidebar

- P-SIDEBAR (Sidebar): 
- P-SIDEBAR.E01 (Library section header): 
- P-SIDEBAR.E02 (All Tracks row): 
- P-SIDEBAR.E03 (Playlists section header): 
- P-SIDEBAR.E04 (Folders row): 
- P-SIDEBAR.E05 (Sync section header): 
- P-SIDEBAR.E06 (Sources row (removed)): 
- P-SIDEBAR.E07 (Inbox section header): 
- P-SIDEBAR.E08 (Review row): 
- P-SIDEBAR.E09 (Discover row): 
- P-SIDEBAR.E10 (Queue footer row (removed)): 
- P-SIDEBAR.E11 (Settings footer row (removed)): 
- P-SIDEBAR.N01 (Albums row): 
- P-SIDEBAR.N02 (Genres row): 
- P-SIDEBAR.N03 (Sets row): 
- P-SIDEBAR.N04 (Liked on SoundCloud row): 
- P-SIDEBAR.N05 (iPod Classic row): 
- P-SIDEBAR.N06 (Sync profile: n to add): 
- P-SIDEBAR.N07 (Sync profile: Syncing n of m): 
- P-SIDEBAR.N08 (Sync profile: Synced): 
- P-SIDEBAR.N09 (Collapsed section header): 
- P-SIDEBAR.N10 (Playlist row as drop target): 
- P-SIDEBAR.N11 (Drop on the Playlists header): 
- P-SIDEBAR.N12 (Playlist row: Incomplete): 
- P-SIDEBAR.N13 (Playlist row: Not downloaded): 
- P-SIDEBAR.N14 (Sync profile: last sync had failures): 
- P-SIDEBAR.N15 (Sync profile row as drop target): 
- P-SIDEBAR.N16 (Rename error, inline): 

### P-STATUSBAR — Status bar

- P-STATUSBAR (Status bar): 

### P-TOOLBAR — Toolbar

- P-TOOLBAR (Toolbar): 
- P-TOOLBAR.E01 (Sidebar toggle): 
- P-TOOLBAR.N01 (Back / Forward): 
- P-TOOLBAR.N02 (Inspector toggle): 
- P-TOOLBAR.N03 (Toolbar at 1320 pt): 
- P-TOOLBAR.N04 (Toolbar at 1000 pt): 
- P-TOOLBAR.N05 (Toolbar at 900 pt): 

### V-LIB

- V-LIB.E01 (View title = window title): 

### V-MAIN-LAYOUT

- V-MAIN-LAYOUT.E01 (Sidebar column): 
- V-MAIN-LAYOUT.E02 (Content column): 
- V-MAIN-LAYOUT.E03 (Trailing column (system inspector)): 
- V-MAIN-LAYOUT.E04 (Toolbar): 
- V-MAIN-LAYOUT.E05 (Bottom Activity strip (removed)): 
- V-MAIN-LAYOUT.E06 (First-run scrim (removed)): 
- V-MAIN-LAYOUT.E07 (Loading state): 
- V-MAIN-LAYOUT.E08 (Start-up failure): 
- V-MAIN-LAYOUT.E09 (Pre-library states): 
- V-MAIN-LAYOUT.N01 (Tip: Space preview): 
- V-MAIN-LAYOUT.N02 (Tip: drop on sidebar playlists): 
- V-MAIN-LAYOUT.N03 (Tip: ⌘I): 
- V-MAIN-LAYOUT.N04 (Window title in the Window menu): 
- V-MAIN-LAYOUT.N05 (Info | Queue switch): 

### V-SEARCH

- V-SEARCH.E01 (Search field): 

### V-TRACK-TABLE

- V-TRACK-TABLE.N01 (Column header menu): 

### W-MAIN — Main window

- W-MAIN (Main window): 
- W-MAIN.E01 (Library name (window subtitle)): 


## library.html — All Tracks

States: default, empty, loading, error, huge
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-011, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-044, DEC-045, DEC-048

### V-LIB

- V-LIB.E02 (Availability scope bar): 
- V-LIB.E06 (Track table): 
- V-LIB.E07 (Title column): 
- V-LIB.E08 (Artist column): 
- V-LIB.E09 (Album column): 
- V-LIB.E10 (Time column): 
- V-LIB.E12 (Status column): 
- V-LIB.E14 (Genre column): 
- V-LIB.E16 (Energy column): 
- V-LIB.E18 (BPM column): 
- V-LIB.E19 (Added column): 
- V-LIB.E20 (First load): 
- V-LIB.E21 (Load error): 
- V-LIB.E22 (Empty library): 
- V-LIB.N01 (Scope: Download failed): 
- V-LIB.N02 (Filter token (example)): 


## albums.html — Albums

States: default, empty, loading, error
Variants: A, B
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-011, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-020, DEC-021, DEC-022, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-040, DEC-041, DEC-043, DEC-044, DEC-045, DEC-048

### A-ALB-REMOVE — Remove album from Library confirmation

- A-ALB-REMOVE (Remove album from Library confirmation): 

### CM-ALB-CARD — Album card context menu

- CM-ALB-CARD (Album card context menu): 
- CM-ALB-CARD.N01 (Play): 
- CM-ALB-CARD.N02 (Play Next): 
- CM-ALB-CARD.N03 (Add to Queue): 
- CM-ALB-CARD.N04 (Add to Playlist ▸): 
- CM-ALB-CARD.N05 (Add to Sync Profile ▸): 
- CM-ALB-CARD.N06 (Get Info): 
- CM-ALB-CARD.N07 (Go to Artist): 
- CM-ALB-CARD.N08 (Download n Missing): 
- CM-ALB-CARD.N09 (Show in Finder): 
- CM-ALB-CARD.N10 (Remove from Library…): 

### CM-ALBD-ABSENT — Context menu of a “Not in library” row

- CM-ALBD-ABSENT (Context menu of a “Not in library” row): 

### CM-ALBD-MORE — Album More menu

- CM-ALBD-MORE (Album More menu): 
- CM-ALBD-MORE.N01 (Edit Album Info…): 
- CM-ALBD-MORE.N02 (Choose Cover…): 
- CM-ALBD-MORE.N03 (Edit Order): 
- CM-ALBD-MORE.N04 (Merge with Another Album…): 
- CM-ALBD-MORE.N05 (Download n Missing): 

### S-ALB-EDIT — Edit Album Info sheet

- S-ALB-EDIT (Edit Album Info sheet): 
- S-ALB-EDIT.N01 (Title): 
- S-ALB-EDIT.N02 (Album artist): 
- S-ALB-EDIT.N03 (Year): 
- S-ALB-EDIT.N04 (Genre): 
- S-ALB-EDIT.N05 (Compilation): 
- S-ALB-EDIT.N06 (Cover well): 

### S-ALB-MERGE — Merge with Another Album sheet

- S-ALB-MERGE (Merge with Another Album sheet): 
- S-ALB-MERGE.N01 (Album search): 
- S-ALB-MERGE.N02 (Candidates): 
- S-ALB-MERGE.N03 (Merge as): 
- S-ALB-MERGE.N04 (Consequence text): 

### V-ALB — Albums (grid)

- V-ALB (Albums (grid)): 
- V-ALB.N01 (View title): 
- V-ALB.N02 (Sort control): 
- V-ALB.N03 (Scope bar): 
- V-ALB.N04 (Album grid): 
- V-ALB.N05 (Album card): 
- V-ALB.N06 (Incomplete, in words): 
- V-ALB.N07 (Missing artwork placeholder): 
- V-ALB.N08 (Tracks without an album (footer line)): 
- V-ALB.N09 (Show): 
- V-ALB.N10 (Find Albums…): 
- V-ALB.N11 (Empty: no albums): 
- V-ALB.N12 (First load): 
- V-ALB.N13 (Load error): 
- V-ALB.N14 (No results): 
- V-ALB.N15 (Sort menu): 

### V-ALBD — Album detail

- V-ALBD (Album detail): 
- V-ALBD.N01 (Album header): 
- V-ALBD.N02 (Cover (drop target)): 
- V-ALBD.N03 (Kind line): 
- V-ALBD.N04 (Album title): 
- V-ALBD.N05 (Album artist): 
- V-ALBD.N06 (Facts line): 
- V-ALBD.N07 (Edition picker (variant A, recommended)): 
- V-ALBD.N08 (Edition menu): 
- V-ALBD.N09 (Edition strip (variant B)): 
- V-ALBD.N10 (Play): 
- V-ALBD.N11 (Shuffle): 
- V-ALBD.N12 (More): 
- V-ALBD.N13 (Status line (only when not complete)): 
- V-ALBD.N14 (Track list (fixed album order)): 
- V-ALBD.N15 (Disc group row): 
- V-ALBD.N16 (# column): 
- V-ALBD.N17 (Title column): 
- V-ALBD.N19 (Time column): 
- V-ALBD.N20 (Status column): 
- V-ALBD.N21 (“Not in library” row + Find): 
- V-ALBD.N22 (Other versions shelf): 
- V-ALBD.N23 (Edit Order bar): 
- V-ALBD.N25 (Offline line): 
- V-ALBD.N26 (“Download failed” row): 


## folders.html — Folders

States: default, importing, imported, empty, loading, error
Variants: A, B
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-008, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-044, DEC-045, DEC-048

### CM-FOLD-TREE — Folder context menu

- CM-FOLD-TREE (Folder context menu): 
- CM-FOLD-TREE.E01: 
- CM-FOLD-TREE.N01 (Open): 
- CM-FOLD-TREE.N02: 
- CM-FOLD-TREE.N03: 
- CM-FOLD-TREE.N04 (Add to Playlist ▸): 
- CM-FOLD-TREE.N05: 
- CM-FOLD-TREE.N06 (Scan This Folder): 
- CM-FOLD-TREE.N07: 
- CM-FOLD-TREE.N08: 

### V-FOLD — Folders

- V-FOLD (Folders): 
- V-FOLD.E01 (Title): 
- V-FOLD.E02 (Filter result line): 
- V-FOLD.E04 (Outline table (folders and tracks)): 
- V-FOLD.E05 (Name column): 
- V-FOLD.E07 (Path bar): 
- V-FOLD.E08 (Files not in the library): 
- V-FOLD.E09 (Folder row): 
- V-FOLD.E10 (Track row): 
- V-FOLD.E12 (No library folder): 
- V-FOLD.E12/loading (Scanning (first load)): 
- V-FOLD.N01 (Managed by MLM): 
- V-FOLD.N02 (File not in the library): 
- V-FOLD.N02/menu (Menu of a file that is not in the library): 
- V-FOLD.N03 (Status column): 
- V-FOLD.N04 (Import running): 
- V-FOLD.N05 (Import result): 
- V-FOLD.N06 (Drive not connected — folders from the database): 
- V-FOLD.N07 (File directly in the library folder): 
- V-FOLD.N08 (Can’t read the library folder): 
- V-FOLD.N09 (Folder that can’t be read): 
- V-FOLD.N10 (Lazy rows): 
- V-FOLD/B (Variant B: tree + table): 


## playlists.html — Playlists

States: default, empty, loading, error, filtered-empty, not-found
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-022, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-040, DEC-041, DEC-044, DEC-045, DEC-048

### A-PL-DELETE — Delete playlist confirmation

- A-PL-DELETE (Delete playlist confirmation): 

### A-PLD-LINKMISMATCH — Result: different tracks (inline)

- A-PLD-LINKMISMATCH (Result: different tracks (inline)): 

### CM-PL-CARD — Playlist card context menu

- CM-PL-CARD (Playlist card context menu): 
- CM-PL-CARD.E01: 
- CM-PL-CARD.E03: 
- CM-PL-CARD.E05: 
- CM-PL-CARD.E06: 
- CM-PL-CARD.E07: 
- CM-PL-CARD.E09 (Add to Sync Profile ▸): 
- CM-PL-CARD.E11: 
- CM-PL-CARD.N01: 
- CM-PL-CARD.N02: 
- CM-PL-CARD.N03: 
- CM-PL-CARD.N04 (Move to Folder ▸): 
- CM-PL-CARD.N05: 
- CM-PL-CARD.N06: 

### CM-SIDEBAR-PINNED — Sidebar playlist row context menu

- CM-SIDEBAR-PINNED (Sidebar playlist row context menu): 
- CM-SIDEBAR-PINNED.E02: 
- CM-SIDEBAR-PINNED.E04: 
- CM-SIDEBAR-PINNED.E06: 
- CM-SIDEBAR-PINNED.N01: 
- CM-SIDEBAR-PINNED.N02: 
- CM-SIDEBAR-PINNED.N03: 
- CM-SIDEBAR-PINNED.N04: 
- CM-SIDEBAR-PINNED.N05: 
- CM-SIDEBAR-PINNED.N06: 

### CM-TRACK — Track context menu (in a playlist)

- CM-TRACK.E01 (Remove from Playlist): 

### P-SIDEBAR — Sidebar

- P-SIDEBAR.E03/add (Playlists section ＋): 
- P-SIDEBAR.N03/menu (Playlist folder context menu): 

### S-PLD-LINK — Link Source sheet

- S-PLD-LINK (Link Source sheet): 
- S-PLD-LINK.E01 (Link field): 
- S-PLD-LINK.E02 (Check): 
- S-PLD-LINK.E03 (Result: same tracks): 
- S-PLD-LINK.E04 (Result: sign-in expired): 
- S-PLD-LINK.E05 (Link Playlist): 

### S-PLD-M3U-PREVIEW — Import M3U into this playlist — preview

- S-PLD-M3U-PREVIEW (Import M3U into this playlist — preview): 
- S-PLD-M3U-PREVIEW.E01 (Where the tracks go): 
- S-PLD-M3U-PREVIEW.E02 (Not found entries): 
- S-PLD-M3U-PREVIEW.E03 (Add 38 Tracks): 

### V-PL — All Playlists (cover grid)

- V-PL (All Playlists (cover grid)): 
- V-PL.E01 (Title + count): 
- V-PL.E02 (Filter scopes): 
- V-PL.E03 (Scope: Needs attention): 
- V-PL.E05 (New Playlist): 
- V-PL.E08 (Card grid): 
- V-PL.E09 (Card cover): 
- V-PL.E10 (Import progress): 
- V-PL.E11 (Name / inline rename): 
- V-PL.E12 (Source): 
- V-PL.E13 (Status in words): 
- V-PL.E14 (Track count): 
- V-PL.E15 (No playlists): 
- V-PL.E15/filtered (No playlists match): 
- V-PL.E16 (First load): 
- V-PL.N01 (Sort control): 
- V-PL.N01/menu (Sort menu): 
- V-PL.N02 (Load error): 
- V-PL.N03 (Not downloaded · n tracks): 
- V-PL.N04 (Playlist folder (group heading)): 

### V-PLD — Playlist detail

- V-PLD (Playlist detail): 
- V-PLD.E02 (Cover, 160 pt (drop target)): 
- V-PLD.E02/menu (Cover context menu): 
- V-PLD.E03 (Title (editable)): 
- V-PLD.E04 (Facts line): 
- V-PLD.E05 (Play): 
- V-PLD.E06 (Shuffle): 
- V-PLD.E07 (Download n Missing): 
- V-PLD.E08 (Refresh from ‹Source›): 
- V-PLD.E09 (Link Source… / Change Link…): 
- V-PLD.E10 (Import M3U into This Playlist…): 
- V-PLD.E12 (Action error line): 
- V-PLD.E13 (Playlist status sentence): 
- V-PLD.E14 (Scope: All · Download failed): 
- V-PLD.E15 (Track table): 
- V-PLD.E16 (# column): 
- V-PLD.E17 (Title column): 
- V-PLD.E18 (Artist column): 
- V-PLD.E19 (Album column): 
- V-PLD.E20 (Time column): 
- V-PLD.E22 (Status column): 
- V-PLD.E23 (Genre column): 
- V-PLD.E25 (Energy column): 
- V-PLD.E27 (Added column): 
- V-PLD.E29 (First load): 
- V-PLD.N01 (More menu): 
- V-PLD.N01/menu (More menu items): 
- V-PLD.N02 (Reorder hint): 
- V-PLD.N03 (Playlist not found): 
- V-PLD.N04 (Add to Sync Profile ▸): 
- V-PLD.N05 (Rename): 
- V-PLD.N06 (Choose Cover…): 
- V-PLD.N07 (Delete Playlist…): 
- V-PLD.N08 (BPM column): 


## queue.html — Queue

States: default, next-empty, empty, error
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-040, DEC-041, DEC-044, DEC-045, DEC-048

### CM-QUEUE — Queue row context menu

- CM-QUEUE (Queue row context menu): 
- CM-QUEUE.N01 (History / Now playing row menu): 

### P-QUEUE — Queue

- P-QUEUE.N01 (Queue row): 
- P-QUEUE.N02 (Context divider): 
- P-QUEUE.N03 (Clear): 
- P-QUEUE.N04 (State word on an unplayable row): 
- P-QUEUE.N05 (Save as Playlist…): 
- P-QUEUE.N06 (Persisted-queue note): 
- P-QUEUE.N07 (Reorder handle and drop line): 
- P-QUEUE.N08 (Context link): 
- P-QUEUE.N09 (Count and time left): 
- P-QUEUE.N11 (Player as drop target): 
- P-QUEUE.N12 (Drop zones of the Queue column): 
- P-QUEUE.N13 (Skipped message): 
- P-QUEUE.N15 (Save as Playlist popover): 

### V-QUEUE

- V-QUEUE.E01 (History section): 
- V-QUEUE.E02 (Now playing section): 
- V-QUEUE.E03 (Next section): 
- V-QUEUE.E04 (Empty texts): 
- V-QUEUE.E05 (Playback not available): 


## player.html — Player and preview

States: default, paused, not-playing, not-downloaded, file-missing, unsupported, end-of-queue
Variants: A, B
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-008, DEC-009, DEC-010, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-044, DEC-045, DEC-047, DEC-048

### K-LIB-SPACE — Space-bar rules

- K-LIB-SPACE (Space-bar rules): 

### P-PLAYER — Player (toolbar, .principal)

- P-PLAYER.E06 (Not playing): 
- P-PLAYER.E07 (Can’t play — not downloaded): 
- P-PLAYER.N02 (Playing): 
- P-PLAYER.N03 (Paused): 
- P-PLAYER.N04 (Can’t play — file missing): 
- P-PLAYER.N05 (Can’t play — drive not connected): 
- P-PLAYER.N06 (Unsupported format): 
- P-PLAYER.N07 (Skipped message): 
- P-PLAYER.N08 (End of the queue): 
- P-PLAYER.N09 (Volume popover): 
- P-PLAYER.N10 (Drive came back): 
- P-PLAYER.N11 (Download-then-play message): 

### P-PREVIEW — Preview state of the player

- P-PREVIEW (Preview state of the player): 
- P-PREVIEW.N01 (Preview label): 
- P-PREVIEW.N02 (Waveform scrubber): 
- P-PREVIEW.N03 (Hot-spot marker): 
- P-PREVIEW.N04 (Hint line): 
- P-PREVIEW.N05 (Preview bar (variant B)): 
- P-PREVIEW.N06 (Setting: Space bar): 

### S-PLAYER-COVER — Large cover popover

- S-PLAYER-COVER (Large cover popover): 


## search.html — Search

States: idle, this-view, library, online, link, no-results, error
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-011, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016, DEC-017, DEC-018, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-044, DEC-045, DEC-048

### K-SEARCH-CMDF — ⌘F

- K-SEARCH-CMDF (⌘F): 

### K-SEARCH-ESC — Esc

- K-SEARCH-ESC (Esc): 

### K-SEARCH-RETURN — Return in the field

- K-SEARCH-RETURN (Return in the field): 

### S-SEARCH-UNIVERSAL — Universal search panel (merged)

- S-SEARCH-UNIVERSAL (Universal search panel (merged)): 

### V-SEARCH

- V-SEARCH.E02 (Clear button): 
- V-SEARCH.E03 (Results title): 
- V-SEARCH.E04 (Search scope bar): 
- V-SEARCH.E05 (Per-source progress): 
- V-SEARCH.E06 (Suggestions (was the empty-query prompt)): 
- V-SEARCH.E07 (Search error): 
- V-SEARCH.E09 (Library results, grouped): 
- V-SEARCH.E10 (No results): 
- V-SEARCH.N01 (Tokens): 
- V-SEARCH.N02 (Top result): 
- V-SEARCH.N03 (Tracks group): 
- V-SEARCH.N04 (Albums group): 
- V-SEARCH.N05 (Playlists group): 
- V-SEARCH.N06 (Folders group): 
- V-SEARCH.N07 (Show all): 
- V-SEARCH.N08 (Nothing is saved): 
- V-SEARCH.N09 (Source section): 
- V-SEARCH.N14 (Link suggestion: track): 
- V-SEARCH.N15 (Link suggestion: playlist): 
- V-SEARCH.N16 (Token value suggestions): 
- V-SEARCH.N17 (Recent searches): 
- V-SEARCH.N18 (Escalation buttons): 
- V-SEARCH.N19 (The view’s own scope bar keeps working): 
- V-SEARCH.N20 (Filtered in place): 


## inspector.html — Track inspector (Info)

States: default, analyzing, tool-missing, save-error
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-010, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-030, DEC-031, DEC-037, DEC-039, DEC-040, DEC-041, DEC-043, DEC-044, DEC-045, DEC-046, DEC-048

### A-META-SAVEERROR — Save error, inline

- A-META-SAVEERROR (Save error, inline): 

### D-TD-ARTWORK-IN — Cover as drop target

- D-TD-ARTWORK-IN (Cover as drop target): 

### D-TD-TRACK-OUT — Cover as drag source

- D-TD-TRACK-OUT (Cover as drag source): 

### K-LIB-INFO — ⌘I

- K-LIB-INFO (⌘I): 

### K-META-EDIT-ESC — Esc in a field

- K-META-EDIT-ESC (Esc in a field): 

### K-META-EDIT-RETURN — Return in a field

- K-META-EDIT-RETURN (Return in a field): 

### K-WAVE-PINCH — Pinch on the waveform

- K-WAVE-PINCH (Pinch on the waveform): 

### P-INSPECTOR — Info (track inspector)

- P-INSPECTOR.E02 (Cover): 
- P-INSPECTOR.E03 (Title): 
- P-INSPECTOR.E04 (Artist): 
- P-INSPECTOR.E05 (Format line): 
- P-INSPECTOR.E09 (Tabs): 
- P-INSPECTOR.E11 (Add to Playlist menu (was the footer picker)): 
- P-INSPECTOR.E12 (Add to Playlist): 
- P-INSPECTOR.N01 (Multiple selection header): 
- P-INSPECTOR.N02 (Go to Album): 
- P-INSPECTOR.N03 (Track / Disc): 
- P-INSPECTOR.N04 (BPM field): 
- P-INSPECTOR.N05 (Comment): 
- P-INSPECTOR.N06 (Tag write queued): 
- P-INSPECTOR.N07 (No selection): 
- P-INSPECTOR.N09 (Multiple selection: Audio): 
- P-INSPECTOR.N10 (Multiple selection: File): 

### P-INSPECTOR-AUDIO — Audio tab

- P-INSPECTOR-AUDIO (Audio tab): 
- P-INSPECTOR-AUDIO.E01 (Analysis values): 
- P-INSPECTOR-AUDIO.E02 (Analyze): 
- P-INSPECTOR-AUDIO.N01 (Analysis running): 
- P-INSPECTOR-AUDIO.N02 (Analysis tool missing): 

### P-INSPECTOR-DEBUG — Diagnostics (was the Debug tab)

- P-INSPECTOR-DEBUG (Diagnostics (was the Debug tab)): 

### P-INSPECTOR-FILE — File tab

- P-INSPECTOR-FILE (File tab): 
- P-INSPECTOR-FILE.E01 (Location): 
- P-INSPECTOR-FILE.E03 (File facts): 
- P-INSPECTOR-FILE.E04 (Duplicate hint): 
- P-INSPECTOR-FILE.N01 (Availability: local): 
- P-INSPECTOR-FILE.N02 (Availability: Not downloaded): 
- P-INSPECTOR-FILE.N04 (Availability: Download failed): 
- P-INSPECTOR-FILE.N05 (Availability: File missing): 
- P-INSPECTOR-FILE.N06 (Availability: drive not connected): 
- P-INSPECTOR-FILE.N07 (Source): 

### P-INSPECTOR-GENERAL — Details tab (was General)

- P-INSPECTOR-GENERAL (Details tab (was General)): 
- P-INSPECTOR-GENERAL.E01 (Title field): 
- P-INSPECTOR-GENERAL.E02 (Artist field): 
- P-INSPECTOR-GENERAL.E03 (Album artist field): 
- P-INSPECTOR-GENERAL.E04 (Album field): 
- P-INSPECTOR-GENERAL.E05 (Genre field): 
- P-INSPECTOR-GENERAL.E06 (Year field): 
- P-INSPECTOR-GENERAL.E07 (In playlists): 

### P-INSPECTOR-SIMILAR — Similar (top five)

- P-INSPECTOR-SIMILAR (Similar (top five)): 

### P-INSPECTOR-WAVEFORM — Waveform

- P-INSPECTOR-WAVEFORM (Waveform): 
- P-INSPECTOR-WAVEFORM.E01 (Waveform bars): 
- P-INSPECTOR-WAVEFORM.E02 (Playhead): 
- P-INSPECTOR-WAVEFORM.E03 (Time row): 
- P-INSPECTOR-WAVEFORM.N01 (Waveform unavailable, in words): 


## launch.html — Library picker, launch & first run

States: picker, picker-empty, loading, cant-open, invalid, failed, adopt, new, switch, copy, open-alerts, setup-1, setup-2, setup-3, setup-done
Decisions on this page: DEC-005, DEC-012, DEC-031, DEC-032, DEC-034, DEC-039, DEC-040, DEC-044

### A-LIB-COPY — Library file is a copy

- A-LIB-COPY (Library file is a copy): 
- A-LIB-COPY.E01 (Open as Separate Library): 
- A-LIB-COPY.E02 (Cancel): 

### A-LIB-SWITCH — Switch library

- A-LIB-SWITCH (Switch library): 
- A-LIB-SWITCH.E01 (Switch and Relaunch): 
- A-LIB-SWITCH.E02 (Cancel): 
- A-LIB-SWITCH.N01 (Running work list): 

### A-LIBFILE-CANTOPEN — Library can’t be opened (library open)

- A-LIBFILE-CANTOPEN (Library can’t be opened (library open)): 
- A-LIBFILE-CANTOPEN.E01 (Locate…): 
- A-LIBFILE-CANTOPEN.E02 (Show in Finder): 
- A-LIBFILE-CANTOPEN.N01 (Try Again): 

### A-LIBFILE-INVALID — Not a valid library file (library open)

- A-LIBFILE-INVALID (Not a valid library file (library open)): 
- A-LIBFILE-INVALID.N01 (New library couldn’t be created): 

### D-LIBFILE-OPEN — Open a library file from Finder

- D-LIBFILE-OPEN (Open a library file from Finder): 

### D-LIBFILE-WINDOWDROP — Drop a library file

- D-LIBFILE-WINDOWDROP (Drop a library file): 

### D-WIZ-FOLDERDROP — Library folder drop target

- D-WIZ-FOLDERDROP (Library folder drop target): 

### M-FILE

- M-FILE.E02 (New Library…): 
- M-FILE.E03 (Open Library…): 
- M-FILE.E04 (Open Recent (with states)): 

### S-ADOPT — Set up your library file

- S-ADOPT (Set up your library file): 
- S-ADOPT.E01 (Title): 
- S-ADOPT.E02 (Explanation): 
- S-ADOPT.E03 (Name field + saved-as line): 
- S-ADOPT.E04 (Not Now): 
- S-ADOPT.E05 (Create Library File): 
- S-ADOPT.E06 (Phases): 
- S-ADOPT.E07 (Success text): 
- S-ADOPT.E08 (Show in Finder): 
- S-ADOPT.E09 (Done): 
- S-ADOPT.E10 (Failure text): 
- S-ADOPT.E11 (Details): 
- S-ADOPT.E12 (Not Now): 
- S-ADOPT.E13 (Try Again): 

### S-LAUNCH-RESTORE — Restore from Backup (launch)

- S-LAUNCH-RESTORE (Restore from Backup (launch)): 

### S-LIBFILE-OPEN — Open panel (system)

- S-LIBFILE-OPEN (Open panel (system)): 

### S-NEWLIB — New Library

- S-NEWLIB (New Library): 
- S-NEWLIB.E01 (Title): 
- S-NEWLIB.E02 (Name field): 
- S-NEWLIB.E03 (What a library is): 
- S-NEWLIB.E04 (Cancel): 
- S-NEWLIB.E05 (Create): 
- S-NEWLIB.N01 (Location): 
- S-NEWLIB.N02 (Saved-as line and rationale): 
- S-NEWLIB.N03 (Inline error): 

### S-WIZ-FOLDER — Folder panel (system)

- S-WIZ-FOLDER (Folder panel (system)): 

### S-WIZARD

- S-WIZARD.E02 (Welcome heading): 
- S-WIZARD.E05 (Library folder heading): 
- S-WIZARD.E06 (Chosen folder + reachability): 
- S-WIZARD.E07 (Choose Folder…): 
- S-WIZARD.E08 (Scan and Import): 
- S-WIZARD.E09 (Phase, counts, current file): 
- S-WIZARD.E10 (Progress): 
- S-WIZARD.E11 (Stop): 
- S-WIZARD.E12 (Result): 
- S-WIZARD.E13 (Stopped / error line): 
- S-WIZARD.E14 (Managed folders line): 
- S-WIZARD.E15 (Done): 

### ST-LIB

- ST-LIB.E04 (Open the last library at launch): 

### V-LAUNCH-CANTOPEN

- V-LAUNCH-CANTOPEN.E01 (Can’t-open title): 
- V-LAUNCH-CANTOPEN.E02 (Not connected explanation): 
- V-LAUNCH-CANTOPEN.E03 (Try Again): 
- V-LAUNCH-CANTOPEN.E07 (Mismatch explanation): 
- V-LAUNCH-CANTOPEN.E08 (Show in Finder): 

### V-LAUNCH-FAILED — Library failed to open

- V-LAUNCH-FAILED (Library failed to open): 
- V-LAUNCH-FAILED.E02 (Title): 
- V-LAUNCH-FAILED.E03 (Details (raw error)): 
- V-LAUNCH-FAILED.N01 (Try Again): 
- V-LAUNCH-FAILED.N02 (Choose Another Library): 
- V-LAUNCH-FAILED.N03 (Restore from Backup…): 
- V-LAUNCH-FAILED.N04 (Show Logs): 

### V-LAUNCH-INVALID — Not a valid library file

- V-LAUNCH-INVALID (Not a valid library file): 
- V-LAUNCH-INVALID.E01 (Title): 
- V-LAUNCH-INVALID.E02 (Choose Another Library): 
- V-LAUNCH-INVALID.N01 (Cause: no database): 
- V-LAUNCH-INVALID.N02 (Cause: newer MLM): 
- V-LAUNCH-INVALID.N03 (Show in Finder): 

### V-LAUNCH-LOADING — Opening a library

- V-LAUNCH-LOADING (Opening a library): 
- V-LAUNCH-LOADING.E01 (Phase line + progress): 
- V-LAUNCH-LOADING.E02 (Opening title): 
- V-LAUNCH-LOADING.N01 (Choose Another Library): 
- V-LAUNCH-LOADING.N02 (Phase: backing up before update): 
- V-LAUNCH-LOADING.N03 (Phase: finishing library file setup): 
- V-LAUNCH-LOADING.N04 (Takes longer than usual): 

### V-LAUNCH-NOLIB

- V-LAUNCH-NOLIB.E01 (Picker title): 
- V-LAUNCH-NOLIB.E02 (Picker description): 
- V-LAUNCH-NOLIB.E03 (New Library…): 
- V-LAUNCH-NOLIB.E04 (Open Other…): 

### V-PICKER — Library picker

- V-PICKER (Library picker): 
- V-PICKER.N01 (Known libraries list): 
- V-PICKER.N02 (Library row — available): 
- V-PICKER.N03 (Library row — Not connected): 
- V-PICKER.N04 (Library row — Not found): 
- V-PICKER.N05 (Row state: doesn’t match): 
- V-PICKER.N06 (Restore from Backup…): 
- V-PICKER.N07 (Locate…): 
- V-PICKER.N08 (Remove from List): 
- V-PICKER.N09 (Not found explanation): 
- V-PICKER.N10 (Library row — needs setup (legacy install)): 
- V-PICKER.N11 (Set Up…): 
- V-PICKER.N12 (Picker — no libraries): 
- V-PICKER.N13 (Open): 
- V-PICKER.N14 (Library row context menu): 

### V-SETUP — First-run setup (in the window)

- V-SETUP (First-run setup (in the window)): 
- V-SETUP.N01 (Name): 
- V-SETUP.N02 (Location of the library file): 
- V-SETUP.N03 (Why the default location): 
- V-SETUP.N04 (Open Other…): 
- V-SETUP.N05 (Chosen folder — not connected): 
- V-SETUP.N06 (Set Up Later): 
- V-SETUP.N07 (Scan When Connected): 
- V-SETUP.N08 (Continue in Background): 
- V-SETUP.N09 (Show (skipped files)): 
- V-SETUP.N10 (Create Library): 

### W-MAIN — Main window (launch states)

- W-MAIN.E02 (Title bar / toolbar): 


## import.html — Add menu · Add from Link · Import Playlist from Source

States: default, empty, loading, error, sign-in-expired, private, tool-missing, queued
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016, DEC-017, DEC-018, DEC-019, DEC-023, DEC-024, DEC-025, DEC-026, DEC-027, DEC-028, DEC-029, DEC-031, DEC-037, DEC-039, DEC-044, DEC-045, DEC-048

### A-SRC-KEYCHAIN — macOS keychain prompt (system)

- A-SRC-KEYCHAIN (macOS keychain prompt (system)): 

### K-REMOTE-DONE — Cancel (Esc)

- K-REMOTE-DONE (Cancel (Esc)): 

### P-ADDMENU — Add menu

- P-ADDMENU.N02 (New Playlist): 
- P-ADDMENU.N03 (New Playlist Folder): 
- P-ADDMENU.N04 (Add from Link…): 
- P-ADDMENU.N05 (Import Playlist from Source…): 
- P-ADDMENU.N06 (Import Files or Folder…): 
- P-ADDMENU.N07 (Import M3U…): 
- P-ADDMENU.N08 (Refresh from Sources): 

### S-IMPORT — Import Playlist from Source (sheet, 3 steps)

- S-IMPORT (Import Playlist from Source (sheet, 3 steps)): 
- S-IMPORT.N01 (Sources list): 
- S-IMPORT.N02 (Manage Accounts…): 
- S-IMPORT.N03 (Filter playlists): 
- S-IMPORT.N04 (Sign-in expired (in place)): 
- S-IMPORT.N05 (Next): 
- S-IMPORT.N06 (Summary line): 
- S-IMPORT.N07 (Target playlist): 
- S-IMPORT.N08 (Keep linked to ‹Source›): 
- S-IMPORT.N09 (Loading playlist): 
- S-IMPORT.N10 (Sign-in expired, discovered mid-way): 
- S-IMPORT.N11 (Private / unavailable playlist): 
- S-IMPORT.N12 (Next): 
- S-IMPORT.N13 (Queued behind another import): 
- S-IMPORT.N14 (Confirmation): 
- S-IMPORT.N15 (Also download tracks already in the library): 
- S-IMPORT.N16 (Where progress lives): 
- S-IMPORT.N17 (Target menu): 
- S-IMPORT.N18 (In library column): 

### S-QUICKADD — Add from Link (sheet)

- S-QUICKADD (Add from Link (sheet)): 
- S-QUICKADD.N01 (Link field): 
- S-QUICKADD.N02 (Paste): 
- S-QUICKADD.N03 (No link yet): 
- S-QUICKADD.N04 (Detecting): 
- S-QUICKADD.N05 (Detected: single track): 
- S-QUICKADD.N06 (Add to playlist (optional)): 
- S-QUICKADD.N07 (Queued note): 
- S-QUICKADD.N08 (Detected: already in the library): 
- S-QUICKADD.N09 (Detected: playlist link): 
- S-QUICKADD.N10 (Unsupported link): 
- S-QUICKADD.N11 (Tool missing): 
- S-QUICKADD.N12 (Sign-in expired): 
- S-QUICKADD.N13 (Private / unavailable): 
- S-QUICKADD.N14 (Cancel (Esc)): 
- S-QUICKADD.N15 (Download (default)): 
- S-QUICKADD.N16 (Show in Library): 
- S-QUICKADD.N17 (Import…): 

### S-SRC-OAUTH — Browser sign-in hand-off (in place)

- S-SRC-OAUTH (Browser sign-in hand-off (in place)): 

### V-SRC

- V-SRC.E04c (Source state (Spotify)): 
- V-SRC.E04g (Sign-in expired · Reconnect (Spotify)): 
- V-SRC.E04i (Apple Music — Not available yet): 
- V-SRC.E04l (Context line before the system dialog): 
- V-SRC.E05 (YouTube: paste a playlist link): 

### W-REMOTE

- W-REMOTE.E02 (Playlist link field): 
- W-REMOTE.E03 (Load): 
- W-REMOTE.E04 (Source didn’t answer): 
- W-REMOTE.E05 (yt-dlp not found · Open Settings ▸ Sources): 
- W-REMOTE.E06 (Account playlists): 
- W-REMOTE.E07 (Loading the playlist list): 
- W-REMOTE.E08 (The source didn’t answer): 
- W-REMOTE.E09 (No playlists): 
- W-REMOTE.E11 (Back): 
- W-REMOTE.E12 (Playlist heading): 
- W-REMOTE.E14 (Spotify note): 
- W-REMOTE.E15 (Selection: All · First n · Random n): 
- W-REMOTE.E16 (n): 
- W-REMOTE.E17 (Preview table): 
- W-REMOTE.E19 (Import n Tracks (default)): 
- W-REMOTE.E20 (Download now): 


## activity.html — Activity

States: default, empty, loading, error, no-library
Variants: A, B
Decisions on this page: DEC-005, DEC-012, DEC-032, DEC-039, DEC-044

### A-LOGS-CLEAR — Clear logs confirmation

- A-LOGS-CLEAR (Clear logs confirmation): 

### A-OPS-CLEARQUEUE — Clear waiting analyses

- A-OPS-CLEARQUEUE (Clear waiting analyses): 

### CM-LOGS-TEXT — Log text context menu

- CM-LOGS-TEXT (Log text context menu): 
- CM-LOGS-TEXT.N01 (Show Only ‹Source› Lines): 
- CM-LOGS-TEXT.N02 (Show Only This Operation): 

### CM-OPS-ROW — Operation context menu

- CM-OPS-ROW (Operation context menu): 

### P-ACTIVITY — Activity item — running + needs attention (live)

- P-ACTIVITY.E01 (Activity item — idle): 
- P-ACTIVITY.E05 (Activity item — running): 
- P-ACTIVITY.E07 (Tabs: Operations · Logs): 
- P-ACTIVITY/B (Variant B: bottom Activity strip): 
- P-ACTIVITY/B.N01 (Strip (click to expand)): 

### P-ACTIVITY-LOGS — Logs

- P-ACTIVITY-LOGS (Logs): 
- P-ACTIVITY-LOGS.E01 (Logs toolbar): 
- P-ACTIVITY-LOGS.E02 (Level filter): 
- P-ACTIVITY-LOGS.E03 (Source filter): 
- P-ACTIVITY-LOGS.E04 (Search): 
- P-ACTIVITY-LOGS.E05 (Pause / Resume): 
- P-ACTIVITY-LOGS.E07 (Wrap lines): 
- P-ACTIVITY-LOGS.E08 (Clear…): 
- P-ACTIVITY-LOGS.E09 (Show Log File in Finder): 
- P-ACTIVITY-LOGS.E10 (Log text): 
- P-ACTIVITY-LOGS.E11 (No lines): 
- P-ACTIVITY-LOGS.N01 (Deep-link filter): 
- P-ACTIVITY-LOGS.N02 (Buffer note): 
- P-ACTIVITY-LOGS.N03 (Copy): 
- P-ACTIVITY-LOGS.N04 (Export…): 

### P-ACTIVITY-OPS — Activity popover

- P-ACTIVITY-OPS.E01 (No activity): 
- P-ACTIVITY-OPS.E02 (Filters: All · Running · Needs attention · Finished): 
- P-ACTIVITY-OPS.E03 (Needs attention): 
- P-ACTIVITY-OPS.E04 (Finished): 
- P-ACTIVITY-OPS.E05 (Operations table): 
- P-ACTIVITY-OPS.E06 (Import scan row): 
- P-ACTIVITY-OPS.E07 (Download batch row): 
- P-ACTIVITY-OPS.E08 (Sync row): 
- P-ACTIVITY-OPS.E09 (Analysis queue row): 
- P-ACTIVITY-OPS.E11 (Failure group: sign-in expired): 
- P-ACTIVITY-OPS.E12 (Recent): 
- P-ACTIVITY-OPS.E13 (Per-track disclosure): 
- P-ACTIVITY-OPS.E14 (Per-track outcome): 
- P-ACTIVITY-OPS.E15 (Progress column): 
- P-ACTIVITY-OPS.E16 (State column): 
- P-ACTIVITY-OPS.E17 (Started column): 
- P-ACTIVITY-OPS.E18 (Cancel after this track): 
- P-ACTIVITY-OPS.E20 (Pause / Resume): 
- P-ACTIVITY-OPS.E21 (Clear Waiting…): 
- P-ACTIVITY-OPS.N01 (Retry All): 
- P-ACTIVITY-OPS.N02 (Operation detail): 
- P-ACTIVITY-OPS.N03 (Loading history): 
- P-ACTIVITY-OPS.N04 (History can’t be loaded): 
- P-ACTIVITY-OPS.N05 (Why it waits): 
- P-ACTIVITY-OPS.N06 (Dismiss): 
- P-ACTIVITY-OPS.N07 (Failure group: tool missing): 
- P-ACTIVITY-OPS.N08 (Waiting for the drive): 
- P-ACTIVITY-OPS.N09 (Tag changes waiting): 
- P-ACTIVITY-OPS.N10 (Last backup line): 
- P-ACTIVITY-OPS.N11 (Operation column): 
- P-ACTIVITY-OPS.N12 (Result column): 
- P-ACTIVITY-OPS.N13 ( column): 
- P-ACTIVITY-OPS.N14 (Show in Logs): 

### W-ACTIVITY — Activity window

- W-ACTIVITY (Activity window): 
- W-ACTIVITY.N01 (Job-kind map): 


## review.html — Review

States: default, empty, scanning, error
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-010, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-021, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-041, DEC-044, DEC-045, DEC-048

### A-REV-ALBBULK — Accept All Above 90 % (new)

- A-REV-ALBBULK (Accept All Above 90 % (new)): 

### A-REV-APPLYALL — Apply Recommended to All (new)

- A-REV-APPLYALL (Apply Recommended to All (new)): 

### CM-REV-ALBUM — Album suggestion context menu (new)

- CM-REV-ALBUM (Album suggestion context menu (new)): 

### CM-REV-GROUP — Group context menu (new)

- CM-REV-GROUP (Group context menu (new)): 

### CM-REV-VERSION — Version row context menu (new)

- CM-REV-VERSION (Version row context menu (new)): 

### V-REV

- V-REV.E01 (View title): 
- V-REV.E02 (Run Scan): 
- V-REV.E03 (Last scan): 
- V-REV.E04 (Scan error): 
- V-REV.E05 (Tabs: Duplicates · Conflicts · Albums · Resolved): 
- V-REV.E06 (Duplicate groups): 
- V-REV.E06c (Recommendation column): 
- V-REV.E07 (Comparison table): 
- V-REV.E07a (Version column): 
- V-REV.E07b (Keep Recommended (default)): 
- V-REV.E07c (Keep Selected): 
- V-REV.E07d (Keep All — Not Duplicates): 
- V-REV.E08a (Conflicts intro): 
- V-REV.E08b (Field-by-field table): 
- V-REV.E08c (Use All from A / B / C): 
- V-REV.E08d (After merge): 
- V-REV.E08e (Where it is written): 
- V-REV.E08f (Apply Merge (default)): 
- V-REV.E09 (Resolved history): 
- V-REV.N01 (Albums tab (new)): 
- V-REV.N02 (Review while the drive is away): 
- V-REV.N03 (Unkept versions: session choice): 
- V-REV.N04 (Apply Recommended to All…): 
- V-REV.N05 (Albums header): 
- V-REV.N06 (Lookup progress): 
- V-REV.N07 (Filter: Suggestions · No Match · No Album): 
- V-REV.N08 (Accept All Above 90 %…): 
- V-REV.N09 (Album suggestions): 
- V-REV.N10 (Nothing to review): 
- V-REV.N11 (Alternatives pop-up): 
- V-REV.N12 (Playlists using it): 
- V-REV.N13 (Preview): 
- V-REV.N14 (Suggested album + year): 
- V-REV.N15 (Source): 
- V-REV.N16 (Match): 
- V-REV.N17 (Accept / Reject / No Album): 


## discover.html — Discover

States: default, empty, loading, error, identifying, not-identified, no-results, no-internet, not-analysed, no-sources
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-010, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016, DEC-017, DEC-018, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-030, DEC-031, DEC-037, DEC-039, DEC-040, DEC-041, DEC-043, DEC-044, DEC-045, DEC-046, DEC-048

### A-INBOX-ERROR — Keep / Dismiss failed

- A-INBOX-ERROR (Keep / Dismiss failed): 

### A-REELS-DELETE — Delete Reel confirmation

- A-REELS-DELETE (Delete Reel confirmation): 

### A-REELS-DELETEERROR — Delete reel failed

- A-REELS-DELETEERROR (Delete reel failed): 

### CM-REELS-ADDPL — Add to Playlist menu

- CM-REELS-ADDPL (Add to Playlist menu): 

### CM-REELS-TEXTPILL — Text fragment menu

- CM-REELS-TEXTPILL (Text fragment menu): 

### S-DISC-FIND — Find Recommendations (sheet)

- S-DISC-FIND (Find Recommendations (sheet)): 

### S-GROOVE-SIMILAR

- S-GROOVE-SIMILAR.E01 (Seed header): 
- S-GROOVE-SIMILAR.E02 (In your library (track table)): 
- S-GROOVE-SIMILAR.E03 (Source picker): 
- S-GROOVE-SIMILAR.E04 (Online suggestions): 
- S-GROOVE-SIMILAR.E04b (Download): 
- S-GROOVE-SIMILAR.E06 (Load More): 

### S-REELS-KEYFRAME — Keyframe (popover)

- S-REELS-KEYFRAME (Keyframe (popover)): 

### S-REELS-LINK — Add Reel from Link (sheet)

- S-REELS-LINK (Add Reel from Link (sheet)): 

### V-DISC

- V-DISC.E01 (View title): 
- V-DISC.E02 (Scope bar: Recommendations · Reels): 

### V-INBOX — Recommendations

- V-INBOX (Recommendations): 
- V-INBOX.E02 (Count and keyboard hint): 
- V-INBOX.E04 (First load): 
- V-INBOX.E05 (Empty: no recommendations waiting): 
- V-INBOX.E06 (Recommendation list, grouped by seed): 
- V-INBOX.E06b (Title column): 
- V-INBOX.E06c (Artist column): 
- V-INBOX.E06d (Seed group row): 
- V-INBOX.E06e (Source column): 
- V-INBOX.E06g (Keep): 
- V-INBOX.E06h (Dismiss): 
- V-INBOX.N01 (Find Recommendations…): 
- V-INBOX.N02 (Drive-off hint (Recommendations)): 
- V-INBOX.N03 (Time column): 
- V-INBOX.N04 (Energy column): 
- V-INBOX.N05 (Load error): 
- V-INBOX.N06 (Selection bar (Recommendations)): 
- V-INBOX.N07 (Recommendation context menu): 

### V-REELS — Reels

- V-REELS (Reels): 
- V-REELS.E02 (Import…): 
- V-REELS.E03 (Empty: no reels yet): 
- V-REELS.E04 (Reel list): 
- V-REELS.E06 (Video): 
- V-REELS.E09 (Artist / Title fields): 
- V-REELS.E11 (Search): 
- V-REELS.E13 (Identify by Audio (Shazam)): 
- V-REELS.E14 (Use (guess)): 
- V-REELS.E15 (No match): 
- V-REELS.E16 (Keyframe strip): 
- V-REELS.E17 (Use (text guess)): 
- V-REELS.E18 (Text fragments): 
- V-REELS.E19 (Nothing to search for yet): 
- V-REELS.E20 (Results per source): 
- V-REELS.E21 (Result row actions): 
- V-REELS.N01 (Add from Link…): 
- V-REELS.N02 (Drop hint): 
- V-REELS.N03 (Workbench): 
- V-REELS.N04 (Mark as Done): 
- V-REELS.N05 (Delete Reel…): 
- V-REELS.N06 (Guesses with provenance): 
- V-REELS.N07 (Zero results): 
- V-REELS.N08 (Offline): 
- V-REELS.N09 (Reel context menu): 
- V-REELS.N10 (Reel state word): 

### V-SIMILAR — Similar to ‹track› (pushed view)

- V-SIMILAR (Similar to ‹track› (pushed view)): 
- V-SIMILAR.N01 (Show Recommendations): 
- V-SIMILAR.N02 (Seed not analysed): 
- V-SIMILAR.N03 (Refresh): 
- V-SIMILAR.N04 (Online loading): 
- V-SIMILAR.N05 (Online error): 
- V-SIMILAR.N06 (Source not configured): 
- V-SIMILAR.N07 (No delete in Similar): 
- V-SIMILAR.N08 (Online suggestion context menu): 
- V-SIMILAR.N09 (Match column): 
- V-SIMILAR.N10 (Preview (30 s stream)): 
- V-SIMILAR.N11 (Keep): 


## sync.html — iPod Classic — sync profile

States: ready, not-connected, syncing, paused, device-removed, done-with-failures, library-drive-off, empty-profile, no-profiles
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-012, DEC-014, DEC-016, DEC-017, DEC-019, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-040, DEC-041, DEC-044, DEC-045, DEC-048

### A-SYNC-DELETEPROFILE — Delete Sync Profile confirmation

- A-SYNC-DELETEPROFILE (Delete Sync Profile confirmation): 

### A-SYNC-REMOVECONTENT — Remove content → undoable

- A-SYNC-REMOVECONTENT (Remove content → undoable): 

### CM-SYNC-FAILED — Failed track row

- CM-SYNC-FAILED (Failed track row): 

### CM-SYNC-PLROW — Playlist / album row in a profile

- CM-SYNC-PLROW (Playlist / album row in a profile): 

### CM-SYNC-PREVIEWFILE — File in a plan list

- CM-SYNC-PREVIEWFILE (File in a plan list): 

### CM-SYNC-PROFILE — Sync profile context menu (sidebar row)

- CM-SYNC-PROFILE (Sync profile context menu (sidebar row)): 
- CM-SYNC-PROFILE.N01 (Eject (proposal)): 

### CM-SYNC-TRACKROW — Track row in a profile

- CM-SYNC-TRACKROW (Track row in a profile): 

### D-SYNC-REORDER-PROFILES — Reorder (insertion line)

- D-SYNC-REORDER-PROFILES (Reorder (insertion line)): 

### D-SYNC-TRACKS-TO-PROFILE — Drop targets

- D-SYNC-TRACKS-TO-PROFILE (Drop targets): 

### K-SYNC-PICKER-RETURN — Add (Return)

- K-SYNC-PICKER-RETURN (Add (Return)): 

### S-SYNC-DESTINATION — Change Destination (sheet)

- S-SYNC-DESTINATION (Change Destination (sheet)): 

### S-SYNC-DEVICEINGEST — Read Playlist Changes from Device (sheet)

- S-SYNC-DEVICEINGEST (Read Playlist Changes from Device (sheet)): 
- S-SYNC-DEVICEINGEST.E04 (Changed playlists): 
- S-SYNC-DEVICEINGEST.N01 (MLM-only tracks kept): 
- S-SYNC-DEVICEINGEST.N02 (Apply (merge)): 

### S-SYNC-INGESTPREVIEW — Entry-level diff

- S-SYNC-INGESTPREVIEW (Entry-level diff): 

### S-SYNC-NEWPROFILE — New Sync Profile (sheet)

- S-SYNC-NEWPROFILE (New Sync Profile (sheet)): 
- S-SYNC-NEWPROFILE.E01 (Name): 
- S-SYNC-NEWPROFILE.E02 (Destination path): 
- S-SYNC-NEWPROFILE.E03 (Detected devices): 
- S-SYNC-NEWPROFILE.N01 (Device preset): 

### S-SYNC-OPENPANEL — Choose… (system folder panel)

- S-SYNC-OPENPANEL (Choose… (system folder panel)): 

### S-SYNC-PLAYLISTPICKER — Add to profile (picker sheet)

- S-SYNC-PLAYLISTPICKER (Add to profile (picker sheet)): 

### S-SYNC-RENAME — Rename → inline in the sidebar

- S-SYNC-RENAME (Rename → inline in the sidebar): 

### S-SYNC-TOAST — Device defaults note

- S-SYNC-TOAST (Device defaults note): 

### V-SYNC — Profile list → sidebar rows

- V-SYNC (Profile list → sidebar rows): 
- V-SYNC.E01 (Sync section header with ＋): 
- V-SYNC.E02 (New Sync Profile (＋)): 
- V-SYNC.E04 (Row: name + state): 
- V-SYNC.E06 (Connection and sync state (words)): 
- V-SYNC.E07 (No sync profiles): 

### V-SYNC-DETAIL — Sync profile detail

- V-SYNC-DETAIL (Sync profile detail): 
- V-SYNC-DETAIL.E01 (Profile name): 
- V-SYNC-DETAIL.E02 (Destination path): 
- V-SYNC-DETAIL.E03 (Updating plan (progress + Cancel)): 
- V-SYNC-DETAIL.E04 (Recompute (⌘R)): 
- V-SYNC-DETAIL.E05 (Sync Now): 
- V-SYNC-DETAIL.E06 (Why Sync Now is unavailable): 
- V-SYNC-DETAIL.E07 (Options section): 
- V-SYNC-DETAIL.E08 (Playlist files): 
- V-SYNC-DETAIL.E09 (Playlist file format): 
- V-SYNC-DETAIL.E10 (Format): 
- V-SYNC-DETAIL.E11 (Normalize volume): 
- V-SYNC-DETAIL.E12 (Artwork): 
- V-SYNC-DETAIL.E13 (Path style): 
- V-SYNC-DETAIL.E14 (Clean up): 
- V-SYNC-DETAIL.E15 (Background processing (moved)): 
- V-SYNC-DETAIL.E16 (Playlists (count, Add…)): 
- V-SYNC-DETAIL.E17 (Playlist rows): 
- V-SYNC-DETAIL.E18 (Tracks (count, Add…)): 
- V-SYNC-DETAIL.E19 (Track rows): 
- V-SYNC-DETAIL.E20 (Plan status line): 
- V-SYNC-DETAIL.E21 (Plan summary): 
- V-SYNC-DETAIL.E22 (Add / Remove lists): 
- V-SYNC-DETAIL.E23 (Not enough space): 
- V-SYNC-DETAIL.E24 (Sync progress): 
- V-SYNC-DETAIL.E25 (Errors where they happen): 
- V-SYNC-DETAIL.E26 (Result line): 
- V-SYNC-DETAIL.E27 (Failed tracks): 
- V-SYNC-DETAIL.N01 (Capacity gauge): 
- V-SYNC-DETAIL.N02 (More menu): 
- V-SYNC-DETAIL.N03 (Device removed during sync): 
- V-SYNC-DETAIL.N04 (Library drive not connected): 
- V-SYNC-DETAIL.N05 (Not downloaded count on a playlist): 
- V-SYNC-DETAIL.N06 (Albums (count, Add…)): 
- V-SYNC-DETAIL.N07 (Skip list): 
- V-SYNC-DETAIL.N08 (Download All): 
- V-SYNC-DETAIL.N09 (Retry Failed): 
- V-SYNC-DETAIL.N10 (More menu (items)): 
- V-SYNC-DETAIL.N11 (Failure reason): 


## genres.html — Genres

States: default, empty, loading, error, no-reference, not-analysed
Decisions on this page: DEC-001, DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-008, DEC-009, DEC-012, DEC-014, DEC-015, DEC-016, DEC-017, DEC-019, DEC-021, DEC-023, DEC-024, DEC-025, DEC-027, DEC-028, DEC-029, DEC-031, DEC-039, DEC-040, DEC-041, DEC-044, DEC-045, DEC-048

### CM-GENRE-ROW — Genre row context menu

- CM-GENRE-ROW (Genre row context menu): 

### CM-GENRED-MORE — Genre More menu

- CM-GENRED-MORE (Genre More menu): 

### CM-STUDIO-GENRETRACK — Context menu: track of the genre

- CM-STUDIO-GENRETRACK (Context menu: track of the genre): 
- CM-STUDIO-GENRETRACK.N01 (Use as Reference for Suggestions): 
- CM-STUDIO-GENRETRACK.N02 (Remove from ‹Genre›): 

### CM-STUDIO-SUGGESTION — Context menu: suggestion row

- CM-STUDIO-SUGGESTION (Context menu: suggestion row): 
- CM-STUDIO-SUGGESTION.N01 (Add to ‹Genre›): 
- CM-STUDIO-SUGGESTION.N02 (Not This Genre): 

### S-STUDIO-EXPORTFOLDER — Choose… (system folder dialog)

- S-STUDIO-EXPORTFOLDER (Choose… (system folder dialog)): 

### ST-STUDIO-EXPORT — Export Create ML Training Set sheet

- ST-STUDIO-EXPORT (Export Create ML Training Set sheet): 
- ST-STUDIO-EXPORT.E01 (Title): 
- ST-STUDIO-EXPORT.E02 (Intro): 
- ST-STUDIO-EXPORT.E03 (Included / left out): 
- ST-STUDIO-EXPORT.E04 (Format): 
- ST-STUDIO-EXPORT.E05 (Left-out genres): 
- ST-STUDIO-EXPORT.E06 (Destination): 
- ST-STUDIO-EXPORT.E07 (Progress → Activity): 

### ST-STUDIO-GENRE

- ST-STUDIO-GENRE.E01 (Header (genre name; Save moved to the staging bar)): 
- ST-STUDIO-GENRE.E03 (Suggestion controls): 
- ST-STUDIO-GENRE.E04 (Suggestion rows): 
- ST-STUDIO-GENRE.E05 (Tracks in this genre): 

### ST-STUDIO-GRID

- ST-STUDIO-GRID.E01 (View title (was “Genre Workshop”)): 
- ST-STUDIO-GRID.E02 (Merge Genres… (was “Consolidate genres”)): 
- ST-STUDIO-GRID.E03 (Export Create ML Training Set… (was a header button)): 
- ST-STUDIO-GRID.E04 (Genre list (was the card grid)): 

### ST-STUDIO-MERGE — Merge Genres sheet (was the “Consolidate genres” screen)

- ST-STUDIO-MERGE (Merge Genres sheet (was the “Consolidate genres” screen)): 
- ST-STUDIO-MERGE.E01 (Title): 
- ST-STUDIO-MERGE.E02 (Consequence text): 
- ST-STUDIO-MERGE.E03 (Result and errors): 
- ST-STUDIO-MERGE.E04 (Selected genres): 
- ST-STUDIO-MERGE.E05 (Canonical name field (“Merge into”)): 
- ST-STUDIO-MERGE.E06 (Preview table): 

### V-GENRED — Genre detail

- V-GENRED (Genre detail): 
- V-GENRED.N01 (Play): 
- V-GENRED.N02 (Shuffle): 
- V-GENRED.N03 (More): 
- V-GENRED.N04 (Suggested tracks section): 
- V-GENRED.N05 (Reference track): 
- V-GENRED.N06 (State: no reference track): 
- V-GENRED.N07 (State: reference track not analysed): 
- V-GENRED.N08 (Staging bar: Save n Changes / Discard): 
- V-GENRED.N09 (Hidden suggestions): 
- V-GENRED.N10 (Match column): 
- V-GENRED.N11 (Genre column): 

### V-GENRES — Genres (list)

- V-GENRES (Genres (list)): 
- V-GENRES.N01 (More): 
- V-GENRES.N02 (More menu (list)): 
- V-GENRES.N03 (“Looks like …” hint): 
- V-GENRES.N04 (Tracks without a genre (footer line)): 
- V-GENRES.N05 (Show): 
- V-GENRES.N06 (Empty: no genres): 
- V-GENRES.N07 (First load): 
- V-GENRES.N08 (Load error): 
- V-GENRES.N09 (Minimum tracks per genre): 
- V-GENRES.N10 (Speed (background processing)): 
- V-GENRES.N11 (What will be skipped): 
- V-GENRES.N12 (Result with skipped and failed counts): 
- V-GENRES.N13 (Genre column (sortable)): 
- V-GENRES.N14 (Tracks column (sortable)): 
- V-GENRES.N15 (“n changes not saved” hint): 


## settings.html — Settings

States: default, no-library, drive-off
Decisions on this page: DEC-004, DEC-009, DEC-012, DEC-014, DEC-023, DEC-025, DEC-031, DEC-035, DEC-036, DEC-037, DEC-039, DEC-043, DEC-044

### A-SET-CACHECLEAR — Clear transcode cache

- A-SET-CACHECLEAR (Clear transcode cache): 

### A-SET-COOKIECLEAR — Clear Qobuz cookie

- A-SET-COOKIECLEAR (Clear Qobuz cookie): 

### A-SET-DISCONNECT — Disconnect source

- A-SET-DISCONNECT (Disconnect source): 

### A-SET-PATHAPPLY — Update organized paths?

- A-SET-PATHAPPLY (Update organized paths?): 

### A-SET-PATHROLLBACK — Roll back last path migration?

- A-SET-PATHROLLBACK (Roll back last path migration?): 

### A-SET-RESTORE — Restore backup

- A-SET-RESTORE (Restore backup): 

### A-SET-RESTOREFAILED — Restore didn’t finish

- A-SET-RESTOREFAILED (Restore didn’t finish): 

### S-SET-LIBFOLDER — Change library folder (consequences)

- S-SET-LIBFOLDER (Change library folder (consequences)): 
- S-SET-LIBFOLDER.N01 (Check of the chosen folder): 

### S-SET-LIBROOT — Choose… (system panel)

- S-SET-LIBROOT (Choose… (system panel)): 

### S-SET-RENAMELIB — Rename library

- S-SET-RENAMELIB (Rename library): 

### ST-ADVANCED — Advanced tab (new content)

- ST-ADVANCED (Advanced tab (new content)): 
- ST-ADVANCED.N01 (Credentials file): 
- ST-ADVANCED.N02 (Diagnostics): 
- ST-ADVANCED.N03 (Reset tips): 

### ST-BACKUP — Backup tab

- ST-BACKUP (Backup tab): 
- ST-BACKUP.E01 (Placeholder without a library): 
- ST-BACKUP.E02 (Restoring… / Relaunching…): 
- ST-BACKUP.E03 (Error section): 
- ST-BACKUP.E04 (Backup folder): 
- ST-BACKUP.E05 (Change…): 
- ST-BACKUP.E06 (Use Default): 
- ST-BACKUP.E07 (Show in Finder): 
- ST-BACKUP.E08 (Last backup): 
- ST-BACKUP.E09 (Count): 
- ST-BACKUP.E10 (Total size): 
- ST-BACKUP.E11 (Section: Status): 
- ST-BACKUP.E12 (Backup list): 
- ST-BACKUP.E13 (Restore…): 
- ST-BACKUP.E14 (Show in Finder (backup)): 
- ST-BACKUP.E15 (No backups yet): 
- ST-BACKUP.E16 (Back Up Now): 
- ST-BACKUP.E17 (Footer): 
- ST-BACKUP.N01 (Back up automatically): 
- ST-BACKUP.N02 (Keep): 
- ST-BACKUP.N03 (Backup folder — not connected): 
- ST-BACKUP.N04 (Backup row context menu): 

### ST-GENERAL — General tab (new)

- ST-GENERAL (General tab (new)): 
- ST-GENERAL.N01 (Space bar behaviour): 
- ST-GENERAL.N02 (Notifications (opt-in)): 

### ST-LIB — Library tab

- ST-LIB (Library tab): 
- ST-LIB.E01 (Section: Library file): 
- ST-LIB.E02 (Library name and location): 
- ST-LIB.E03 (Show in Finder): 
- ST-LIB.E05 (Footer): 
- ST-LIB.E06 (Section: Library folder): 
- ST-LIB.E07 (Footer): 
- ST-LIB.E08 (Statistics): 
- ST-LIB.E09 (Show in Finder (library folder)): 
- ST-LIB.E10 (Section: Managed folders): 
- ST-LIB.E11 (Scan Library Folder): 
- ST-LIB.E12 (Import Files or Folder…): 
- ST-LIB.E13 (Import in progress): 
- ST-LIB.E14 (Last result): 
- ST-LIB.E15 (Result with failures): 
- ST-LIB.E16 (Supported formats): 
- ST-LIB.N01 (Rename…): 
- ST-LIB.N02 (Choose Library…): 
- ST-LIB.N03 (Library folder — not connected): 
- ST-LIB.N04 (Change…): 
- ST-LIB.N05 (Write tag changes to files): 

### ST-MAINT — Maintenance tab

- ST-MAINT (Maintenance tab): 
- ST-MAINT.E01 (Background processing): 
- ST-MAINT.E02 (Transcode cache location): 
- ST-MAINT.E03 (Helper): 
- ST-MAINT.E04 (Memory in use): 
- ST-MAINT.E05 (Cached playlists): 
- ST-MAINT.E06 (Recently opened playlists kept ready): 
- ST-MAINT.E07 (Fingerprint all tracks): 
- ST-MAINT.E08 (ReplayGain analysis): 
- ST-MAINT.E09 (Danceability analysis): 
- ST-MAINT.E10 (Similarity analysis): 
- ST-MAINT.E11 (Refresh embedded artwork): 
- ST-MAINT.E12 (Fetch artwork from MusicBrainz): 
- ST-MAINT.E13 (Job row pattern): 
- ST-MAINT.E14 (Find duplicates and conflicts): 
- ST-MAINT.E15 (Reread tags from files): 
- ST-MAINT.E16 (Organized-path migration): 
- ST-MAINT.E17 (Recreate linked playlist): 
- ST-MAINT.N01 (Drive not connected line): 
- ST-MAINT.N02 (Clear Cache…): 

### ST-PLAYBACK — Playback tab

- ST-PLAYBACK (Playback tab): 
- ST-PLAYBACK.E01 (History length): 
- ST-PLAYBACK.E02 (Queue length from a list): 
- ST-PLAYBACK.E03 (Normalize loudness): 

### ST-SRC — Sources tab

- ST-SRC (Sources tab): 
- ST-SRC.E01 (Accounts): 
- ST-SRC.E02 (Disconnect): 
- ST-SRC.E03 (Reconnect): 
- ST-SRC.E04 (Connect… (YouTube)): 
- ST-SRC.E05 (Section: Qobuz cookie): 
- ST-SRC.E06 (Cookie field): 
- ST-SRC.E07 (How to get the cookie): 
- ST-SRC.E08 (Cookie status): 
- ST-SRC.E09 (Save): 
- ST-SRC.E10 (Clear…): 
- ST-SRC.E11 (Saved time): 
- ST-SRC.N01 (Apple Music — not available yet): 
- ST-SRC.N02 (Credentials file missing): 
- ST-SRC.N03 (Refresh schedule): 
- ST-SRC.N04 (Download tools): 
- ST-SRC.N05 (Tool not found): 
- ST-SRC.N06 (How to Install): 

### ST-STORAGE — Storage Location tab

- ST-STORAGE (Storage Location tab): 
- ST-STORAGE.E01 (Placeholder without a library): 
- ST-STORAGE.E02 (Library file): 
- ST-STORAGE.E03 (Database): 
- ST-STORAGE.E04 (Playlist covers): 
- ST-STORAGE.E05 (Backups): 
- ST-STORAGE.E06 (Last backup): 
- ST-STORAGE.E07 (Credentials file): 
- ST-STORAGE.E08 (Library folder): 
- ST-STORAGE.E09 (Transcode cache): 
- ST-STORAGE.E10 (Sign-in tokens): 
- ST-STORAGE.E11 (Footer): 
- ST-STORAGE.E12 (State line): 
- ST-STORAGE.E13 (Show in Finder (per row)): 
- ST-STORAGE.N01 (Sizes chart): 
- ST-STORAGE.N02 (List of libraries): 
- ST-STORAGE.N03 (Caches, logs, migration backups, previous install): 

### W-SETTINGS — Settings window

- W-SETTINGS (Settings window): 
- W-SETTINGS.E01 (Window title): 
- W-SETTINGS.E02 (Title bar): 
- W-SETTINGS.E03 (Tab strip): 
- W-SETTINGS.N01 (No library open line): 
- W-SETTINGS.N02 (System folder panel): 


## library-icon.html — Library-file icon

Variants: A, B, C
Decisions on this page: DEC-012, DEC-031, DEC-033, DEC-039, DEC-044

### ICON-MLIBM

- ICON-MLIBM.N01 (Finder sample: list row and icon view): 
- ICON-MLIBM.N02 (Finder icon view (64 px)): 
- ICON-MLIBM.N03 (File ▸ Open Recent sample (16 px)): 
- ICON-MLIBM.N04 (Library picker rows (32 px)): 
- ICON-MLIBM.N05 (Rules for the asset): 
- ICON-MLIBM/A (Variant A — Record crate (recommended)): 
- ICON-MLIBM/B (Variant B — Stacked sleeves): 
- ICON-MLIBM/C (Variant C — Document with folded corner + mark): 


## patterns-sheets-alerts.html — Sheets & alerts

Decisions on this page: DEC-003, DEC-004, DEC-006, DEC-007, DEC-010, DEC-012, DEC-016, DEC-018, DEC-021, DEC-023, DEC-025, DEC-026, DEC-027, DEC-028, DEC-029, DEC-030, DEC-031, DEC-032, DEC-034, DEC-035, DEC-036, DEC-037, DEC-039, DEC-040, DEC-041, DEC-044

### A-GROOVE-DELETEFILE — No delete in Similar

- A-GROOVE-DELETEFILE (No delete in Similar): 

### A-INBOX-DELETE — Dismiss — undoable, no alert

- A-INBOX-DELETE (Dismiss — undoable, no alert): 

### A-PLD-IMPORTDONE — M3U imported — status bar

- A-PLD-IMPORTDONE (M3U imported — status bar): 

### A-PLD-LINKDONE — Linked — status bar

- A-PLD-LINKDONE (Linked — status bar): 

### A-PLD-REMOVE — Removed from playlist — status bar

- A-PLD-REMOVE (Removed from playlist — status bar): 

### A-SIDEBAR-DELETEPL — Delete playlist (sidebar) — same alert as A-PL-DELETE

- A-SIDEBAR-DELETEPL (Delete playlist (sidebar) — same alert as A-PL-DELETE): 

### A-SIDEBAR-RENAMEFAIL — Rename failed — inline

- A-SIDEBAR-RENAMEFAIL (Rename failed — inline): 

### A-TRACK-REMOVE-FAILED — Some tracks couldn’t be removed

- A-TRACK-REMOVE-FAILED (Some tracks couldn’t be removed): 

### PATTERN-SHEETS

- PATTERN-SHEETS.N01 (Surface rule table): 
- PATTERN-SHEETS.N02 (Sheet anatomy (model)): 
- PATTERN-SHEETS.N03 (Short work stays in the sheet): 
- PATTERN-SHEETS.N04 (Long work is handed to Activity): 
- PATTERN-SHEETS.N05 (Alert anatomy (model)): 
- PATTERN-SHEETS.N06 (Undoable confirmation (model)): 
- PATTERN-SHEETS.N07 (Failure placement table): 
- PATTERN-SHEETS.N08 (File panel (model)): 

### S-GROOVE-SIMILAR — Similar to ‹track› (pushed view, was a sheet)

- S-GROOVE-SIMILAR (Similar to ‹track› (pushed view, was a sheet)): 

### S-PL-BANNER-COVERDROP — Cover drop refused — on the card

- S-PL-BANNER-COVERDROP (Cover drop refused — on the card): 

### S-PL-BANNER-PINLIMIT — No pins, no limit

- S-PL-BANNER-PINLIMIT (No pins, no limit): 

### S-PL-NEWPLAYLIST — New playlist — inline rename

- S-PL-NEWPLAYLIST (New playlist — inline rename): 

### S-PLD-M3U-OPEN — M3U file chooser

- S-PLD-M3U-OPEN (M3U file chooser): 

### S-PLFOLDER-NEW — New playlist folder — inline rename

- S-PLFOLDER-NEW (New playlist folder — inline rename): 

### S-REELS-OPENFOLDER — Reels import panel

- S-REELS-OPENFOLDER (Reels import panel): 

### S-REV-UNDOTOAST — Review decision — status bar

- S-REV-UNDOTOAST (Review decision — status bar): 

### S-SEL-NEWPLAYLIST — New playlist from selection — inline

- S-SEL-NEWPLAYLIST (New playlist from selection — inline): 

### S-SEL-NEWSYNCPROFILE — New Sync Profile (opened from a selection)

- S-SEL-NEWSYNCPROFILE (New Sync Profile (opened from a selection)): 

### S-SET-BACKUPFOLDER — Backup folder panel

- S-SET-BACKUPFOLDER (Backup folder panel): 

### S-SET-CACHEFOLDER — Transcode cache panel

- S-SET-CACHEFOLDER (Transcode cache panel): 

### S-SET-EXPORTFOLDER — Create ML destination — same panel as S-STUDIO-EXPORTFOLDER

- S-SET-EXPORTFOLDER (Create ML destination — same panel as S-STUDIO-EXPORTFOLDER): 

### S-SET-IMPORTFOLDER — Import Files or Folder panel

- S-SET-IMPORTFOLDER (Import Files or Folder panel): 

### S-WIZARD — First-run setup (in the window)

- S-WIZARD (First-run setup (in the window)): 


## patterns-context-menus.html — Context menus

Decisions on this page: DEC-003, DEC-006, DEC-012, DEC-014, DEC-017, DEC-019, DEC-020, DEC-021, DEC-022, DEC-024, DEC-025, DEC-026, DEC-027, DEC-028, DEC-029, DEC-030, DEC-031, DEC-036, DEC-039, DEC-040, DEC-041, DEC-044

### CM-ALBD-ABSENT — Context menu of a “Not in library” row

- CM-ALBD-ABSENT.N01 (Find Online): 
- CM-ALBD-ABSENT.N02 (Use a Track from the Library…): 
- CM-ALBD-ABSENT.N03 (Copy Title — Artist): 

### CM-ALBD-MORE — Album More menu

- CM-ALBD-MORE.N06 (Play Next): 
- CM-ALBD-MORE.N07 (Add to Queue): 
- CM-ALBD-MORE.N08 (Add to Playlist): 
- CM-ALBD-MORE.N09 (Add to Sync Profile): 
- CM-ALBD-MORE.N10 (Show in Finder): 
- CM-ALBD-MORE.N11 (Remove from Library…): 

### CM-FOLD-SEARCHRESULT — Folder context menu (filtered row)

- CM-FOLD-SEARCHRESULT (Folder context menu (filtered row)): 

### CM-FOLD-SUBFOLDER — Folder context menu (subfolder row)

- CM-FOLD-SUBFOLDER (Folder context menu (subfolder row)): 

### CM-FOLD-TREE — Folder context menu

- CM-FOLD-TREE.N09 (Add to Queue): 

### CM-GENRE-ROW — Genre row context menu

- CM-GENRE-ROW.N01 (Open): 
- CM-GENRE-ROW.N02 (Play): 
- CM-GENRE-ROW.N03 (Play Next): 
- CM-GENRE-ROW.N04 (Add to Queue): 
- CM-GENRE-ROW.N05 (Add to Playlist): 
- CM-GENRE-ROW.N06 (Add to Sync Profile): 
- CM-GENRE-ROW.N07 (Rename Genre…): 
- CM-GENRE-ROW.N08 (Merge Genres…): 

### CM-GENRED-MORE — Genre More menu

- CM-GENRED-MORE.N01 (Play Next): 
- CM-GENRED-MORE.N02 (Add to Queue): 
- CM-GENRED-MORE.N03 (Add to Playlist): 
- CM-GENRED-MORE.N04 (Add to Sync Profile): 
- CM-GENRED-MORE.N05 (Rename Genre…): 
- CM-GENRED-MORE.N06 (Merge with Another Genre…): 

### CM-OPS-ROW — Operation context menu

- CM-OPS-ROW.N01 (Show Playlist): 
- CM-OPS-ROW.N02 (Retry Failed): 
- CM-OPS-ROW.N03 (Pause): 
- CM-OPS-ROW.N04 (Cancel after This Track): 
- CM-OPS-ROW.N05 (Show in Logs): 
- CM-OPS-ROW.N06 (Copy Summary): 
- CM-OPS-ROW.N07 (Remove from History): 

### CM-PL-CARD — Playlist card context menu

- CM-PL-CARD.N07 (Add to Queue): 

### CM-QUEUE — Queue row context menu

- CM-QUEUE.N01.N01 (Play): 
- CM-QUEUE.N01.N02 (Play Next): 
- CM-QUEUE.N01.N03 (Add to Queue): 
- CM-QUEUE.N01.N04 (Add to Playlist): 
- CM-QUEUE.N01.N05 (Add to Sync Profile): 
- CM-QUEUE.N01.N06 (Get Info): 
- CM-QUEUE.N01.N07 (Go to Album): 
- CM-QUEUE.N01.N08 (Find Similar): 
- CM-QUEUE.N01.N09 (Show in Finder): 
- CM-QUEUE.N01.N10 (Copy): 
- CM-QUEUE.N01.N11 (Clear History): 

### CM-REELS-ADDPL — Add to Playlist menu

- CM-REELS-ADDPL.N01 (New Playlist…): 

### CM-REELS-TEXTPILL — Text fragment menu

- CM-REELS-TEXTPILL.E01 (Use as Artist): 
- CM-REELS-TEXTPILL.E02 (Use as Title): 
- CM-REELS-TEXTPILL.E03 (Use as “Artist – Title”): 
- CM-REELS-TEXTPILL.E04 (Copy): 

### CM-REV-ALBUM — Album suggestion context menu (new)

- CM-REV-ALBUM.N01 (Play): 
- CM-REV-ALBUM.N02 (Preview): 
- CM-REV-ALBUM.N03 (Get Info): 
- CM-REV-ALBUM.N04 (Show Suggested Album): 
- CM-REV-ALBUM.N05 (Accept): 
- CM-REV-ALBUM.N06 (Choose Another Album…): 
- CM-REV-ALBUM.N07 (No Album): 
- CM-REV-ALBUM.N08 (Reject): 
- CM-REV-ALBUM.N09 (Show in Finder): 
- CM-REV-ALBUM.N10 (Copy): 

### CM-REV-GROUP — Group context menu (new)

- CM-REV-GROUP.N01 (Keep Recommended): 
- CM-REV-GROUP.N02 (Show Comparison): 
- CM-REV-GROUP.N03 (Show Versions in All Tracks): 
- CM-REV-GROUP.N04 (Keep All — Not Duplicates): 
- CM-REV-GROUP.N05 (Copy): 
- CM-REV-GROUP/conflict (Conflict group context menu (new)): 
- CM-REV-GROUP/conflict.N01 (Apply Merge): 
- CM-REV-GROUP/conflict.N02 (Show Comparison): 
- CM-REV-GROUP/conflict.N03 (Show Versions in All Tracks): 
- CM-REV-GROUP/conflict.N04 (Different Versions — Keep Both): 
- CM-REV-GROUP/conflict.N05 (Copy): 

### CM-REV-VERSION — Version row context menu (new)

- CM-REV-VERSION.N01 (Play): 
- CM-REV-VERSION.N02 (Preview): 
- CM-REV-VERSION.N03 (Play Next): 
- CM-REV-VERSION.N04 (Add to Queue): 
- CM-REV-VERSION.N05 (Add to Playlist): 
- CM-REV-VERSION.N06 (Get Info): 
- CM-REV-VERSION.N07 (Show in All Tracks): 
- CM-REV-VERSION.N08 (Keep This Version): 
- CM-REV-VERSION.N09 (Show in Finder): 
- CM-REV-VERSION.N10 (Copy): 
- CM-REV-VERSION.N11 (Remove from Library…): 

### CM-SIDEBAR-PINNEDRENAME — Rename field — system text menu

- CM-SIDEBAR-PINNEDRENAME (Rename field — system text menu): 

### CM-STUDIO-MERGETABLE — Merge preview table — track menu

- CM-STUDIO-MERGETABLE (Merge preview table — track menu): 

### CM-SUB-COPY — Submenu: Copy

- CM-SUB-COPY (Submenu: Copy): 
- CM-SUB-COPY.N01 (Title — Artist): 
- CM-SUB-COPY.N02 (File Path): 
- CM-SUB-COPY.N03 (Link): 

### CM-SUB-MOVE — Submenu: Move to Folder

- CM-SUB-MOVE (Submenu: Move to Folder): 
- CM-SUB-MOVE.N01 (No Folder): 
- CM-SUB-MOVE.N02 (Sets): 
- CM-SUB-MOVE.N03 (Archive): 
- CM-SUB-MOVE.N04 (New Playlist Folder…): 

### CM-SUB-PLAYLIST — Submenu: Add to Playlist

- CM-SUB-PLAYLIST (Submenu: Add to Playlist): 
- CM-SUB-PLAYLIST.N01 (New Playlist…): 
- CM-SUB-PLAYLIST.N02 (Warm-up): 
- CM-SUB-PLAYLIST.N03 (Road trip 2026): 
- CM-SUB-PLAYLIST.N04 (Peak time): 
- CM-SUB-PLAYLIST.N05 (Sets): 
- CM-SUB-PLAYLIST.N06 (Liked on SoundCloud): 
- CM-SUB-PLAYLIST.N07 (Boiler Room picks): 
- CM-SUB-PLAYLIST.N08 (Road trip 2026): 
- CM-SUB-PLAYLIST.N09 (Ambient for work): 

### CM-SUB-SYNC — Submenu: Add to Sync Profile

- CM-SUB-SYNC (Submenu: Add to Sync Profile): 
- CM-SUB-SYNC.N01 (iPod Classic): 
- CM-SUB-SYNC.N02 (Car USB stick): 
- CM-SUB-SYNC.N03 (New Sync Profile…): 

### CM-SYNC-FAILED — Failed track row

- CM-SYNC-FAILED.E01 (Play): 
- CM-SYNC-FAILED.E02 (Play Next): 
- CM-SYNC-FAILED.E04 (Get Info): 
- CM-SYNC-FAILED.E05 (Retry): 
- CM-SYNC-FAILED.E07 (Show in Finder): 
- CM-SYNC-FAILED.E08 (Copy): 
- CM-SYNC-FAILED.N01 (Add to Queue): 

### CM-SYNC-PLROW — Playlist / album row in a profile

- CM-SYNC-PLROW.E01 (Remove from “iPod Classic”): 
- CM-SYNC-PLROW.N01 (Open): 
- CM-SYNC-PLROW.N02 (Add to Sync Profile): 
- CM-SYNC-PLROW.N03 (Download Not-Downloaded Tracks): 

### CM-SYNC-PREVIEWFILE — File in a plan list

- CM-SYNC-PREVIEWFILE.E01 (Show on Device in Finder): 
- CM-SYNC-PREVIEWFILE.N01 (Play): 
- CM-SYNC-PREVIEWFILE.N02 (Get Info): 
- CM-SYNC-PREVIEWFILE.N03 (Show Library File in Finder): 
- CM-SYNC-PREVIEWFILE.N04 (Copy): 
- CM-SYNC-PREVIEWFILE.N05 (Remove from “iPod Classic”): 

### CM-SYNC-PROFILE — Sync profile context menu (sidebar row)

- CM-SYNC-PROFILE.E01 (Rename): 
- CM-SYNC-PROFILE.E02 (Duplicate): 
- CM-SYNC-PROFILE.E03 (Read Playlist Changes from Device…): 
- CM-SYNC-PROFILE.E04 (Delete Sync Profile…): 
- CM-SYNC-PROFILE.N02 (Open): 
- CM-SYNC-PROFILE.N03 (Sync Now): 
- CM-SYNC-PROFILE.N04 (Change Destination…): 
- CM-SYNC-PROFILE.N05 (Recompute Plan): 
- CM-SYNC-PROFILE.N06 (Show in Finder): 

### CM-SYNC-TRACKROW — Track row in a profile

- CM-SYNC-TRACKROW.E01 (Remove from “iPod Classic”): 
- CM-SYNC-TRACKROW.N01 (Play): 
- CM-SYNC-TRACKROW.N02 (Preview): 
- CM-SYNC-TRACKROW.N03 (Play Next): 
- CM-SYNC-TRACKROW.N04 (Add to Queue): 
- CM-SYNC-TRACKROW.N05 (Add to Playlist): 
- CM-SYNC-TRACKROW.N06 (Add to Sync Profile): 
- CM-SYNC-TRACKROW.N07 (Get Info): 
- CM-SYNC-TRACKROW.N08 (Go to Album): 
- CM-SYNC-TRACKROW.N09 (Find Similar): 
- CM-SYNC-TRACKROW.N10 (Show in Finder): 
- CM-SYNC-TRACKROW.N11 (Copy): 

### CM-TRACK — Track context menu

- CM-TRACK.N08 (Locate File…): 
- CM-TRACK.N09 (Download Again): 
- CM-TRACK.N11 (Import File): 
- CM-TRACK.N12 (Move to End of Queue): 
- CM-TRACK.N13 (Show in “Warm-up”): 
- CM-TRACK.N14 (Remove from Queue): 
- CM-TRACK/download-failed (Track menu — Download failed): 
- CM-TRACK/drive-off (Track menu — drive not connected): 
- CM-TRACK/file-missing (Track menu — File missing): 
- CM-TRACK/in-playlist (Track menu — in a playlist): 
- CM-TRACK/multi (Track menu — multi-selection, mixed): 
- CM-TRACK/not-downloaded (Track menu — Not downloaded): 
- CM-TRACK/order (Order example (one local track in a playlist)): 
- CM-TRACK/rule-local (Local track (short form)): 
- CM-TRACK/rule-notdl (Not downloaded track (short form)): 

### P-LIBFOOTER

- P-LIBFOOTER.N01.N01 (Main Library): 
- P-LIBFOOTER.N01.N02 (Laptop Subset): 
- P-LIBFOOTER.N01.N03 (Archive 2019 — Not connected): 
- P-LIBFOOTER.N01.N04 (Show Library File in Finder): 
- P-LIBFOOTER.N01.N05 (Library Settings…): 

### P-SIDEBAR

- P-SIDEBAR.E03/add.N01 (New Playlist): 
- P-SIDEBAR.E03/add.N02 (New Playlist Folder): 
- P-SIDEBAR.N03/menu.N01 (New Playlist in Folder): 
- P-SIDEBAR.N03/menu.N02 (Rename): 
- P-SIDEBAR.N03/menu.N03 (Delete Folder…): 

### PATTERN-CM

- PATTERN-CM.N01 (Group order): 
- PATTERN-CM.N02 (Rule: groups disappear): 
- PATTERN-CM.N03 (Rule: count header): 
- PATTERN-CM.N04 (Rule: wording): 
- PATTERN-CM.N05 (Rule: Remove group): 
- PATTERN-CM.N06 (Rule: More = context menu): 
- PATTERN-CM.N07 (Rule: right-click target): 

### ST-BACKUP

- ST-BACKUP.N04.N01 (Restore…): 
- ST-BACKUP.N04.N02 (Show in Finder): 

### V-INBOX

- V-INBOX.N07.N01 (Preview): 
- V-INBOX.N07.N02 (Keep): 
- V-INBOX.N07.N03 (Keep and Add to Playlist): 
- V-INBOX.N07.N04 (Go to Seed Track): 
- V-INBOX.N07.N05 (Find Similar): 
- V-INBOX.N07.N06 (Show in Finder): 
- V-INBOX.N07.N07 (Copy): 
- V-INBOX.N07.N08 (Dismiss): 

### V-PICKER

- V-PICKER.N14.N01 (Open): 
- V-PICKER.N14.N02 (Rename…): 
- V-PICKER.N14.N03 (Show in Finder): 
- V-PICKER.N14.N04 (Copy Path): 
- V-PICKER.N14.N05 (Remove from List): 

### V-PLD

- V-PLD.E02/menu.N01 (Choose Cover…): 
- V-PLD.E02/menu.N02 (Use Automatic Cover): 
- V-PLD.N01/menu.N01 (Play Next): 
- V-PLD.N01/menu.N02 (Add to Queue): 
- V-PLD.N01/menu.N03 (Use Automatic Cover): 
- V-PLD.N01/menu.N04 (Move to Folder): 

### V-REELS

- V-REELS.N09.N01 (Play Video): 
- V-REELS.N09.N02 (Identify Again): 
- V-REELS.N09.N03 (Mark as Done): 
- V-REELS.N09.N04 (Show in Finder): 
- V-REELS.N09.N05 (Copy): 
- V-REELS.N09.N06 (Delete Reel…): 

### V-SIMILAR

- V-SIMILAR.N08.N01 (Preview): 
- V-SIMILAR.N08.N02 (Download): 
- V-SIMILAR.N08.N03 (Keep): 
- V-SIMILAR.N08.N04 (Keep and Add to Playlist): 
- V-SIMILAR.N08.N05 (Open on SoundCloud): 
- V-SIMILAR.N08.N06 (Copy Link): 

### V-SYNC-DETAIL

- V-SYNC-DETAIL.N10.N01 (Read Playlist Changes from Device…): 
- V-SYNC-DETAIL.N10.N02 (Rename): 
- V-SYNC-DETAIL.N10.N03 (Duplicate): 
- V-SYNC-DETAIL.N10.N04 (Change Destination…): 
- V-SYNC-DETAIL.N10.N05 (Show in Finder): 
- V-SYNC-DETAIL.N10.N06 (Delete Sync Profile…): 

### V-TRACK-TABLE

- V-TRACK-TABLE.N01.N01 (Artist): 
- V-TRACK-TABLE.N01.N02 (Album): 
- V-TRACK-TABLE.N01.N03 (Time): 
- V-TRACK-TABLE.N01.N04 (BPM): 
- V-TRACK-TABLE.N01.N05 (Energy): 
- V-TRACK-TABLE.N01.N06 (Dance): 
- V-TRACK-TABLE.N01.N07 (Genre): 
- V-TRACK-TABLE.N01.N08 (Year): 
- V-TRACK-TABLE.N01.N09 (Format): 
- V-TRACK-TABLE.N01.N10 (kbps): 
- V-TRACK-TABLE.N01.N11 (Added): 
- V-TRACK-TABLE.N01.N12 (Status): 
- V-TRACK-TABLE.N01.N13 (Auto Size All Columns): 


## patterns-menus-shortcuts.html — Menu bar &amp; keyboard

Decisions on this page: DEC-002, DEC-003, DEC-004, DEC-005, DEC-006, DEC-007, DEC-008, DEC-009, DEC-012, DEC-017, DEC-018, DEC-022, DEC-026, DEC-027, DEC-029, DEC-032, DEC-035, DEC-038, DEC-039, DEC-041, DEC-044, DEC-047

### K-ACT-ESC — K-ACT-ESC — Merged

- K-ACT-ESC (K-ACT-ESC — Merged): 

### K-APP-SETTINGS — K-APP-SETTINGS — Kept

- K-APP-SETTINGS (K-APP-SETTINGS — Kept): 

### K-DISC-NAV — K-DISC-NAV — Changed to ⌘5

- K-DISC-NAV (K-DISC-NAV — Changed to ⌘5): 

### K-FILE-NEWPLAYLIST — K-FILE-NEWPLAYLIST — Kept, one meaning

- K-FILE-NEWPLAYLIST (K-FILE-NEWPLAYLIST — Kept, one meaning): 

### K-FILE-OPENLIB — K-FILE-OPENLIB — Kept

- K-FILE-OPENLIB (K-FILE-OPENLIB — Kept): 

### K-LIB-DELETE — K-LIB-DELETE — Added

- K-LIB-DELETE (K-LIB-DELETE — Added): 

### K-LIB-RESCAN — K-LIB-RESCAN — Kept, one concept

- K-LIB-RESCAN (K-LIB-RESCAN — Kept, one concept): 

### K-LIB-RETURN — K-LIB-RETURN — Defined

- K-LIB-RETURN (K-LIB-RETURN — Defined): 

### K-LIB-SPACE — K-LIB-SPACE — Added

- K-LIB-SPACE/rules (Space-bar rule table): 

### K-LIBRARY-IMPORT — K-LIBRARY-IMPORT — Revived, key reassigned

- K-LIBRARY-IMPORT (K-LIBRARY-IMPORT — Revived, key reassigned): 

### K-LIBRARY-MOREINFO — K-LIBRARY-MOREINFO — Revived

- K-LIBRARY-MOREINFO (K-LIBRARY-MOREINFO — Revived): 

### K-LOGS-COPY — K-LOGS-COPY — Kept

- K-LOGS-COPY (K-LOGS-COPY — Kept): 

### K-NAV-DISCOVER — K-NAV-DISCOVER — Changed to ⌘5

- K-NAV-DISCOVER (K-NAV-DISCOVER — Changed to ⌘5): 

### K-NAV-FOLDERS — K-NAV-FOLDERS — Changed to ⌘4

- K-NAV-FOLDERS (K-NAV-FOLDERS — Changed to ⌘4): 

### K-NAV-LIBRARY — K-NAV-LIBRARY — Kept, renamed

- K-NAV-LIBRARY (K-NAV-LIBRARY — Kept, renamed): 

### K-NAV-PLAYLISTS — K-NAV-PLAYLISTS — Removed, key reassigned

- K-NAV-PLAYLISTS (K-NAV-PLAYLISTS — Removed, key reassigned): 

### K-NAV-QUEUE — K-NAV-QUEUE — Changed to ⌥⌘U

- K-NAV-QUEUE (K-NAV-QUEUE — Changed to ⌥⌘U): 

### K-NAV-REVIEW — K-NAV-REVIEW — Kept

- K-NAV-REVIEW (K-NAV-REVIEW — Kept): 

### K-NAV-SOURCES — K-NAV-SOURCES — Removed, key reassigned

- K-NAV-SOURCES (K-NAV-SOURCES — Removed, key reassigned): 

### K-NAV-SYNC — K-NAV-SYNC — Removed, key reassigned

- K-NAV-SYNC (K-NAV-SYNC — Removed, key reassigned): 

### K-PL-NEW — K-PL-NEW — Merged

- K-PL-NEW (K-PL-NEW — Merged): 

### K-PL-NEWPOPOVER-ESC — K-PL-NEWPOPOVER-ESC — Merged into inline rename

- K-PL-NEWPOPOVER-ESC (K-PL-NEWPOPOVER-ESC — Merged into inline rename): 

### K-PL-NEWPOPOVER-RETURN — K-PL-NEWPOPOVER-RETURN — Merged into inline rename

- K-PL-NEWPOPOVER-RETURN (K-PL-NEWPOPOVER-RETURN — Merged into inline rename): 

### K-PL-RENAME — K-PL-RENAME — Kept

- K-PL-RENAME (K-PL-RENAME — Kept): 

### K-PLAYBACK-SKIPBACK — K-PLAYBACK-SKIPBACK — Changed to ⌥⌘←

- K-PLAYBACK-SKIPBACK (K-PLAYBACK-SKIPBACK — Changed to ⌥⌘←): 

### K-PLAYBACK-SKIPFWD — K-PLAYBACK-SKIPFWD — Changed to ⌥⌘→

- K-PLAYBACK-SKIPFWD (K-PLAYBACK-SKIPFWD — Changed to ⌥⌘→): 

### K-PLAYBACK-STOP — K-PLAYBACK-STOP — Kept

- K-PLAYBACK-STOP (K-PLAYBACK-STOP — Kept): 

### K-REELS-DELETE — K-REELS-DELETE — Kept, made reliable

- K-REELS-DELETE (K-REELS-DELETE — Kept, made reliable): 

### K-REELS-KEYFRAME-ESC — K-REELS-KEYFRAME-ESC — Kept

- K-REELS-KEYFRAME-ESC (K-REELS-KEYFRAME-ESC — Kept): 

### K-REELS-LISTNAV — K-REELS-LISTNAV — Kept, without the side effect

- K-REELS-LISTNAV (K-REELS-LISTNAV — Kept, without the side effect): 

### K-REELS-RETURN — K-REELS-RETURN — Changed

- K-REELS-RETURN (K-REELS-RETURN — Changed): 

### K-SEARCH-UNIVERSAL-KEYS — K-SEARCH-UNIVERSAL-KEYS — Removed (replaced by ⌘U)

- K-SEARCH-UNIVERSAL-KEYS (K-SEARCH-UNIVERSAL-KEYS — Removed (replaced by ⌘U)): 

### K-SET-COOKIE-RETURN — K-SET-COOKIE-RETURN — Kept, fixed

- K-SET-COOKIE-RETURN (K-SET-COOKIE-RETURN — Kept, fixed): 

### K-SET-GW-TABLE-RETURN — K-SET-GW-TABLE-RETURN — Merged (duplicate)

- K-SET-GW-TABLE-RETURN (K-SET-GW-TABLE-RETURN — Merged (duplicate)): 

### K-SIDEBAR-RENAME — K-SIDEBAR-RENAME — Kept, widened

- K-SIDEBAR-RENAME (K-SIDEBAR-RENAME — Kept, widened): 

### K-STUDIO-MERGE-PRIMARY — K-STUDIO-MERGE-PRIMARY — Kept, standardised

- K-STUDIO-MERGE-PRIMARY (K-STUDIO-MERGE-PRIMARY — Kept, standardised): 

### K-SYNC-NEWPROFILE-KEYS — K-SYNC-NEWPROFILE-KEYS — Kept

- K-SYNC-NEWPROFILE-KEYS (K-SYNC-NEWPROFILE-KEYS — Kept): 

### K-SYNC-REFRESH — K-SYNC-REFRESH — Kept, one concept

- K-SYNC-REFRESH (K-SYNC-REFRESH — Kept, one concept): 

### K-SYNC-RENAME-KEYS — K-SYNC-RENAME-KEYS — Merged into inline rename

- K-SYNC-RENAME-KEYS (K-SYNC-RENAME-KEYS — Merged into inline rename): 

### K-WIN-SEEKBACK — K-WIN-SEEKBACK — Changed (scoped)

- K-WIN-SEEKBACK (K-WIN-SEEKBACK — Changed (scoped)): 

### K-WIN-SEEKFWD — K-WIN-SEEKFWD — Changed (scoped)

- K-WIN-SEEKFWD (K-WIN-SEEKFWD — Changed (scoped)): 

### M-APP — MLM (application menu)

- M-APP (MLM (application menu)): 
- M-APP.E01 (About MLM): 
- M-APP.E02 (Settings…): 
- M-APP.E03 (Services): 
- M-APP.E04 (Hide MLM): 
- M-APP.E05 (Hide Others): 
- M-APP.E06 (Show All): 
- M-APP.E07 (Quit MLM): 
- M-APP.E07/alert (Quit with running work): 

### M-DOCK — Dock menu

- M-DOCK (Dock menu): 
- M-DOCK.N01 (Pause): 
- M-DOCK.N02 (Next): 
- M-DOCK.N03 (Previous): 
- M-DOCK.N04 (Laptop Subset): 
- M-DOCK.N05 (Archive 2019 — Not connected): 

### M-EDIT — Edit

- M-EDIT (Edit): 
- M-EDIT.N01 (Undo Add to “Warm-up”): 
- M-EDIT.N02 (Redo): 
- M-EDIT.N03 (Cut): 
- M-EDIT.N04 (Copy): 
- M-EDIT.N05 (Paste): 
- M-EDIT.N06 (Delete): 
- M-EDIT.N07 (Select All): 
- M-EDIT.N08 (Deselect All): 
- M-EDIT.N09 (Find): 
- M-EDIT.N09.N10 (Search): 

### M-FILE — File

- M-FILE (File): 
- M-FILE.E01 (New Playlist): 
- M-FILE.E04.N01 (Main Library): 
- M-FILE.E04.N02 (Laptop Subset): 
- M-FILE.E04.N03 (Archive 2019 — Not connected): 
- M-FILE.E04.N04 (Old Test Library — Not found): 
- M-FILE.E04.N05 (Clear Menu): 
- M-FILE.E05 (Close Window): 
- M-FILE.N01 (New Playlist from Selection): 
- M-FILE.N02 (New Playlist Folder): 
- M-FILE.N03 (New Sync Profile…): 
- M-FILE.N04 (Add from Link…): 
- M-FILE.N05 (Import Playlist from Source…): 
- M-FILE.N06 (Import M3U…): 
- M-FILE.N07 (Export): 
- M-FILE.N07.N01 (Playlist as M3U…): 
- M-FILE.N08 (Show Library File in Finder): 

### M-HELP — Help

- M-HELP (Help): 
- M-HELP.N01 (MLM Help): 
- M-HELP.N02 (Keyboard Shortcuts): 
- M-HELP.N03 (Show Tips Again): 

### M-LIBRARY — Library

- M-LIBRARY (Library): 
- M-LIBRARY.E01 (Search Library): 
- M-LIBRARY.E02 (Import Files or Folder…): 
- M-LIBRARY.E03 (Get Info): 
- M-LIBRARY.N01 (Refresh from Sources): 
- M-LIBRARY.N02 (Scan Library Folder): 
- M-LIBRARY.N03 (Find Duplicates…): 
- M-LIBRARY.N04 (Find Albums…): 
- M-LIBRARY.N05 (Maintenance): 
- M-LIBRARY.N05.N01 (Fingerprint All Tracks): 
- M-LIBRARY.N05.N02 (ReplayGain Analysis): 
- M-LIBRARY.N05.N03 (Danceability Analysis): 
- M-LIBRARY.N05.N04 (Similarity Analysis): 
- M-LIBRARY.N05.N05 (Refresh Embedded Artwork): 
- M-LIBRARY.N05.N06 (Fetch Artwork from MusicBrainz): 
- M-LIBRARY.N05.N07 (Reread Tags from Files): 
- M-LIBRARY.N05.N08 (Maintenance Settings…): 
- M-LIBRARY.N06 (Back Up Now): 
- M-LIBRARY.N07 (Library Settings…): 

### M-NAVIGATE — Go (was Navigate)

- M-NAVIGATE (Go (was Navigate)): 
- M-NAVIGATE.E01 (All Tracks): 
- M-NAVIGATE.E03 (Folders): 
- M-NAVIGATE.E06 (Review): 
- M-NAVIGATE.E07 (Discover): 
- M-NAVIGATE.N01 (Albums): 
- M-NAVIGATE.N02 (Genres): 
- M-NAVIGATE.N03 (Back): 
- M-NAVIGATE.N04 (Forward): 
- M-NAVIGATE.N05 (Playlists): 
- M-NAVIGATE.N06 (Sync Profiles): 

### M-PLAYBACK — Playback

- M-PLAYBACK (Playback): 
- M-PLAYBACK.E01 (Pause): 
- M-PLAYBACK.E02 (Stop): 
- M-PLAYBACK.E03 (Previous): 
- M-PLAYBACK.E04 (Next): 
- M-PLAYBACK.E05 (Skip Back 10 Seconds): 
- M-PLAYBACK.E06 (Skip Forward 10 Seconds): 
- M-PLAYBACK.N01 (Volume Up): 
- M-PLAYBACK.N02 (Volume Down): 
- M-PLAYBACK.N03 (Shuffle All Tracks): 
- M-PLAYBACK.N04 (Repeat): 
- M-PLAYBACK.N05 (Play All Tracks): 

### M-TRACK — Track

- M-TRACK (Track): 
- M-TRACK.N01 (Play): 
- M-TRACK.N02 (Preview): 
- M-TRACK.N03 (Play Next): 
- M-TRACK.N04 (Add to Queue): 
- M-TRACK.N05 (Add to Playlist): 
- M-TRACK.N06 (Add to Sync Profile): 
- M-TRACK.N07 (Go to Album): 
- M-TRACK.N08 (Go to Artist): 
- M-TRACK.N09 (Find Similar): 
- M-TRACK.N10 (Download): 
- M-TRACK.N11 (Locate File…): 
- M-TRACK.N12 (Refresh from Source): 
- M-TRACK.N13 (Show in Finder): 
- M-TRACK.N14 (Copy): 
- M-TRACK.N15 (Share…): 
- M-TRACK.N16 (Remove from Playlist): 
- M-TRACK.N17 (Remove from Library…): 

### M-VIEW — View

- M-VIEW (View): 
- M-VIEW.N01 (Hide Sidebar): 
- M-VIEW.N02 (Show Info): 
- M-VIEW.N03 (Show Queue): 
- M-VIEW.N04 (Columns): 
- M-VIEW.N05 (Sort By): 
- M-VIEW.N06 (Filter): 
- M-VIEW.N07 (Go to Current Track): 
- M-VIEW.N08 (Enter Full Screen): 
- M-VIEW.N09 (Customize Toolbar…): 

### M-WINDOW — Window

- M-WINDOW (Window): 
- M-WINDOW.N01 (Minimize): 
- M-WINDOW.N02 (Zoom): 
- M-WINDOW.N03 (Activity): 
- M-WINDOW.N04 (Bring All to Front): 
- M-WINDOW.N05 (All Tracks — Main Library): 
- M-WINDOW.N06 (Activity): 
- M-WINDOW.N07 (Settings): 

### PATTERN-MENUS

- PATTERN-MENUS.N01 (Menu bar): 
- PATTERN-MENUS.N02 (Keyboard map): 
- PATTERN-MENUS.N03 (Resolved conflicts): 
- PATTERN-MENUS.N04 (Primary action table): 
- PATTERN-MENUS.N05 (Sheet and alert keys): 
- PATTERN-MENUS.N06 (Text field keys): 
- PATTERN-MENUS.N07 (List keys): 
- PATTERN-MENUS.N08 (Outline keys): 


## patterns-states.html — States

Decisions on this page: DEC-004, DEC-005, DEC-008, DEC-011, DEC-012, DEC-013, DEC-014, DEC-016, DEC-017, DEC-023, DEC-027, DEC-028, DEC-031, DEC-032, DEC-034, DEC-035, DEC-037, DEC-039, DEC-043, DEC-044, DEC-045

### F-18

- F-18.N01 (F-18 step 1 — The drive is unplugged while a track plays): 
- F-18.N02 (F-18 step 2 — The window says it once): 
- F-18.N03 (F-18 step 3 — Keep working): 
- F-18.N04 (F-18 step 4 — Try to play or open a file): 
- F-18.N05 (F-18 step 5 — The drive comes back): 

### G-BG-ACTIVE — Something is running

- G-BG-ACTIVE (Something is running): 

### G-DEVICE-OFFLINE — Sync device not connected

- G-DEVICE-OFFLINE (Sync device not connected): 

### G-DRIVE-BOOT — Library folder on the Mac’s own disk

- G-DRIVE-BOOT (Library folder on the Mac’s own disk): 

### G-JOB-SILENT — Work with lasting effects but no UI

- G-JOB-SILENT (Work with lasting effects but no UI): 

### G-JOB-STATUS — Job lifecycle

- G-JOB-STATUS (Job lifecycle): 

### G-LIB-ADOPT-INTERRUPTED — Library file setup was interrupted

- G-LIB-ADOPT-INTERRUPTED (Library file setup was interrupted): 

### G-LIB-ADOPT-PENDING — Old install not yet a library file

- G-LIB-ADOPT-PENDING (Old install not yet a library file): 

### G-LIB-COPY — Library file is a copy of another

- G-LIB-COPY (Library file is a copy of another): 

### G-LIB-CURRENT — Which library is open

- G-LIB-CURRENT (Which library is open): 

### G-LIB-FAILED — Library failed to open

- G-LIB-FAILED (Library failed to open): 

### G-LIB-INVALID — Not a valid library file

- G-LIB-INVALID (Not a valid library file): 

### G-LIB-LEGACY — Running on the old layout after “Not Now”

- G-LIB-LEGACY (Running on the old layout after “Not Now”): 

### G-LIB-LOADING — Library database and services starting

- G-LIB-LOADING (Library database and services starting): 

### G-LIB-MISMATCH — Library file and database don’t belong together

- G-LIB-MISMATCH (Library file and database don’t belong together): 

### G-LIB-NONE — No library open

- G-LIB-NONE (No library open): 

### G-LIB-NOTCONNECTED — Library file: Not connected

- G-LIB-NOTCONNECTED (Library file: Not connected): 

### G-LIB-NOTFOUND — Library file: Not found

- G-LIB-NOTFOUND (Library file: Not found): 

### G-LIB-RESOLVING — Deciding which library to open

- G-LIB-RESOLVING (Deciding which library to open): 

### G-LIB-SWITCH-PENDING — Another library was picked; MLM must relaunch

- G-LIB-SWITCH-PENDING (Another library was picked; MLM must relaunch): 

### G-PL-DRIVE-OFFLINE — Playlist while the drive is not connected

- G-PL-DRIVE-OFFLINE (Playlist while the drive is not connected): 

### G-PL-IMPORTING — Playlist: Importing · n of m

- G-PL-IMPORTING (Playlist: Importing · n of m): 

### G-PL-INCOMPLETE — Playlist: Incomplete · n failed

- G-PL-INCOMPLETE (Playlist: Incomplete · n failed): 

### G-PL-LINKED — Playlist: linked to a source

- G-PL-LINKED (Playlist: linked to a source): 

### G-PL-LOCAL — Playlist: local

- G-PL-LOCAL (Playlist: local): 

### G-PL-NOTDOWNLOADED — Playlist: Not downloaded · n tracks

- G-PL-NOTDOWNLOADED (Playlist: Not downloaded · n tracks): 

### G-PL-SRC-DISCONNECTED — Linked playlist whose source sign-in expired

- G-PL-SRC-DISCONNECTED (Linked playlist whose source sign-in expired): 

### G-PLAYBACK-ERROR — Track can’t be played

- G-PLAYBACK-ERROR (Track can’t be played): 

### G-ROOT-NONE — No library folder configured

- G-ROOT-NONE (No library folder configured): 

### G-SRC-APPLEMUSIC — Apple Music not available

- G-SRC-APPLEMUSIC (Apple Music not available): 

### G-SRC-CONNECTED — Source: Connected

- G-SRC-CONNECTED (Source: Connected): 

### G-SRC-CREDS-MISSING — Credentials file missing

- G-SRC-CREDS-MISSING (Credentials file missing): 

### G-SRC-DISCONNECTED — Source: Disconnected

- G-SRC-DISCONNECTED (Source: Disconnected): 

### G-SRC-EXPIRED — Source: Sign-in expired

- G-SRC-EXPIRED (Source: Sign-in expired): 

### G-SRC-KEYCHAIN — Saved sign-in can’t be read from the keychain

- G-SRC-KEYCHAIN (Saved sign-in can’t be read from the keychain): 

### G-SRC-QOBUZ-COOKIE — Qobuz access cookie

- G-SRC-QOBUZ-COOKIE (Qobuz access cookie): 

### G-TOOL-MISSING — External tool missing

- G-TOOL-MISSING (External tool missing): 

### G-TRK-DOWNLOADING — Track: Downloading…

- G-TRK-DOWNLOADING (Track: Downloading…): 

### G-TRK-DUPLICATE — Possible duplicate

- G-TRK-DUPLICATE (Possible duplicate): 

### G-TRK-FAILED — Track: Download failed

- G-TRK-FAILED (Track: Download failed): 

### G-TRK-LOCAL — Track: local

- G-TRK-LOCAL (Track: local): 

### G-TRK-MISSING — Track: File missing

- G-TRK-MISSING (Track: File missing): 

### G-TRK-NOTDOWNLOADED — Track: Not downloaded

- G-TRK-NOTDOWNLOADED (Track: Not downloaded): 

### G-TRK-PLACEHOLDER — Placeholder metadata

- G-TRK-PLACEHOLDER (Placeholder metadata): 

### PATTERN-STATES

- PATTERN-STATES.N01 (Level rule): 
- PATTERN-STATES.N02 (Status text (model)): 
- PATTERN-STATES.N03 (Placement table): 
- PATTERN-STATES.N04 (State vocabulary table): 
- PATTERN-STATES.N10 (Empty — first use): 
- PATTERN-STATES.N11 (Empty — filtered): 
- PATTERN-STATES.N12 (Loading — first load): 
- PATTERN-STATES.N13 (Loading — refresh): 
- PATTERN-STATES.N14 (Loading — determinate): 
- PATTERN-STATES.N15 (Error — whole view): 
- PATTERN-STATES.N16 (Error — of the thing shown): 
- PATTERN-STATES.N17 (Error — of an action): 
- PATTERN-STATES.N18 (Drive not connected — the window): 
- PATTERN-STATES.N19 (Disabled actions carry the reason): 
- PATTERN-STATES.N20 (Drive connected again): 
- PATTERN-STATES.N21 (Huge data — counts carry the state): 


## patterns-dnd.html — Drag &amp; drop

Decisions on this page: DEC-003, DEC-006, DEC-007, DEC-012, DEC-016, DEC-017, DEC-018, DEC-024, DEC-025, DEC-026, DEC-027, DEC-028, DEC-029, DEC-030, DEC-031, DEC-032, DEC-034, DEC-035, DEC-036, DEC-039, DEC-040, DEC-041, DEC-044

### D-FOLD-FILES-FROM-FINDER — Audio files onto a folder — Added by the redesign

- D-FOLD-FILES-FROM-FINDER (Audio files onto a folder — Added by the redesign): 

### D-FOLD-FOLDER-TO-PLAYLIST — A disk folder onto a playlist — Added by the redesign

- D-FOLD-FOLDER-TO-PLAYLIST (A disk folder onto a playlist — Added by the redesign): 

### D-FOLD-TRACKS-OUT — Track rows of Folders dragged out — Exists today · kept

- D-FOLD-TRACKS-OUT (Track rows of Folders dragged out — Exists today · kept): 

### D-GROOVE-ROW-TO-PLAYLIST — Similar-track rows onto a playlist — Added by the redesign

- D-GROOVE-ROW-TO-PLAYLIST (Similar-track rows onto a playlist — Added by the redesign): 

### D-INBOX-TO-PLAYLIST — Recommendation onto a playlist — Added by the redesign

- D-INBOX-TO-PLAYLIST (Recommendation onto a playlist — Added by the redesign): 

### D-LIB-FINDER-IN — Audio files or folders from Finder onto a track list — Added by the redesign

- D-LIB-FINDER-IN (Audio files or folders from Finder onto a track list — Added by the redesign): 

### D-LIB-SPRING — Spring-loaded sidebar (same behaviour, second entry) — Exists today · merged

- D-LIB-SPRING (Spring-loaded sidebar (same behaviour, second entry) — Exists today · merged): 

### D-LIB-TO-FINDER — Tracks dragged out to Finder or another app — Added by the redesign

- D-LIB-TO-FINDER (Tracks dragged out to Finder or another app — Added by the redesign): 

### D-LIB-TO-QUEUE — Tracks onto the player or the Queue — Added by the redesign

- D-LIB-TO-QUEUE (Tracks onto the player or the Queue — Added by the redesign): 

### D-LIB-TO-SIDEBAR-NEWPL — Selection onto the sidebar — Added by the redesign

- D-LIB-TO-SIDEBAR-NEWPL (Selection onto the sidebar — Added by the redesign): 

### D-LIB-TO-SYNC — Tracks onto a sync profile — Added by the redesign

- D-LIB-TO-SYNC (Tracks onto a sync profile — Added by the redesign): 

### D-LIB-TRACK-OUT — Track rows as a drag source — Exists today · changed

- D-LIB-TRACK-OUT (Track rows as a drag source — Exists today · changed): 

### D-LOGS-TEXTDRAG — Selected log text dragged out — Exists today · kept

- D-LOGS-TEXTDRAG (Selected log text dragged out — Exists today · kept): 

### D-PL-CARD-REORDER — Arrange playlists by hand — Added by the redesign

- D-PL-CARD-REORDER (Arrange playlists by hand — Added by the redesign): 

### D-PL-COVER-TO-CARD — Image onto a playlist card — Exists today · kept

- D-PL-COVER-TO-CARD (Image onto a playlist card — Exists today · kept): 

### D-PL-PLAYLIST-TO-FOLDER — Playlist onto a playlist folder — Added by the redesign

- D-PL-PLAYLIST-TO-FOLDER (Playlist onto a playlist folder — Added by the redesign): 

### D-PL-SELECTION-TO-NEW — Selection onto empty space = new playlist — Added by the redesign

- D-PL-SELECTION-TO-NEW (Selection onto empty space = new playlist — Added by the redesign): 

### D-PL-SPRINGLOAD-CARD — Hover a card to open the playlist mid-drag — Exists today · kept

- D-PL-SPRINGLOAD-CARD (Hover a card to open the playlist mid-drag — Exists today · kept): 

### D-PL-TRACKS-TO-CARD — Tracks onto a playlist card — Exists today · kept

- D-PL-TRACKS-TO-CARD (Tracks onto a playlist card — Exists today · kept): 

### D-PL-TRACKS-TO-PINNED — Tracks directly onto a sidebar playlist — Added by the redesign

- D-PL-TRACKS-TO-PINNED (Tracks directly onto a sidebar playlist — Added by the redesign): 

### D-PLD-COVER-TO-HEADER — Image onto the playlist header cover — Added by the redesign

- D-PLD-COVER-TO-HEADER (Image onto the playlist header cover — Added by the redesign): 

### D-PLD-INSERT — Tracks from elsewhere between rows of a playlist — Exists today · kept

- D-PLD-INSERT (Tracks from elsewhere between rows of a playlist — Exists today · kept): 

### D-PLD-M3U-FROM-FINDER — .m3u file from Finder — Added by the redesign

- D-PLD-M3U-FROM-FINDER (.m3u file from Finder — Added by the redesign): 

### D-PLD-REORDER — Reorder rows in a playlist — Exists today · kept

- D-PLD-REORDER (Reorder rows in a playlist — Exists today · kept): 

### D-PLD-ROWS-OUT — Playlist rows dragged to another playlist — Exists today · kept

- D-PLD-ROWS-OUT (Playlist rows dragged to another playlist — Exists today · kept): 

### D-PLD-ROWS-TO-FINDER — Playlist rows out to Finder — Added by the redesign

- D-PLD-ROWS-TO-FINDER (Playlist rows out to Finder — Added by the redesign): 

### D-QUEUE-ROWS — Queue rows dragged out — Exists today · kept

- D-QUEUE-ROWS (Queue rows dragged out — Exists today · kept): 

### D-REELS-IMPORT — Video files from Finder onto Reels — Exists today · kept

- D-REELS-IMPORT (Video files from Finder onto Reels — Exists today · kept): 

### D-REELS-OUT — Reel row dragged out — Added by the redesign

- D-REELS-OUT (Reel row dragged out — Added by the redesign): 

### D-REELS-RESULT-TO-PLAYLIST — Reel search result onto a playlist — Added by the redesign

- D-REELS-RESULT-TO-PLAYLIST (Reel search result onto a playlist — Added by the redesign): 

### D-REELS-URL — Instagram / TikTok link onto Reels — Added by the redesign

- D-REELS-URL (Instagram / TikTok link onto Reels — Added by the redesign): 

### D-REMOTE-PLAYLIST-TO-SIDEBAR — Account playlist row dragged to the sidebar — Stays out of scope

- D-REMOTE-PLAYLIST-TO-SIDEBAR (Account playlist row dragged to the sidebar — Stays out of scope): 

### D-REMOTE-URL-DROP — Link dropped on the window — Added by the redesign

- D-REMOTE-URL-DROP (Link dropped on the window — Added by the redesign): 

### D-REV-TRACK-OUT — Review version row dragged out — Added by the redesign

- D-REV-TRACK-OUT (Review version row dragged out — Added by the redesign): 

### D-SEARCH-ROWS — Search results dragged out — Exists today · kept

- D-SEARCH-ROWS (Search results dragged out — Exists today · kept): 

### D-SET-FOLDER-TO-DESTINATION — Folder onto a destination row — Added by the redesign

- D-SET-FOLDER-TO-DESTINATION (Folder onto a destination row — Added by the redesign): 

### D-SET-FOLDER-TO-LIBROOT — Folder onto the Library folder row — Added by the redesign

- D-SET-FOLDER-TO-LIBROOT (Folder onto the Library folder row — Added by the redesign): 

### D-SET-GW-TRACK-OUT — Genre Workshop rows onto a playlist — Added by the redesign

- D-SET-GW-TRACK-OUT (Genre Workshop rows onto a playlist — Added by the redesign): 

### D-SET-GW-TRACK-TO-GENRE — Track onto a genre (Settings-side entry) — Added by the redesign

- D-SET-GW-TRACK-TO-GENRE (Track onto a genre (Settings-side entry) — Added by the redesign): 

### D-SIDEBAR-SPRINGLOAD — Track drag over a sidebar row — Exists today · changed

- D-SIDEBAR-SPRINGLOAD (Track drag over a sidebar row — Exists today · changed): 

### D-STUDIO-TRACK-TO-GENRE — Tracks onto a genre — Added by the redesign

- D-STUDIO-TRACK-TO-GENRE (Tracks onto a genre — Added by the redesign): 

### D-SYNC-FOLDER-TO-OUTPUT — Folder or disk onto the sync destination — Added by the redesign

- D-SYNC-FOLDER-TO-OUTPUT (Folder or disk onto the sync destination — Added by the redesign): 

### D-SYNC-PLAYLIST-TO-PROFILE — Playlist onto a sync profile — Added by the redesign

- D-SYNC-PLAYLIST-TO-PROFILE (Playlist onto a sync profile — Added by the redesign): 

### PATTERN-DND

- PATTERN-DND.N01 (Drag payloads): 
- PATTERN-DND.N02 (Drop feedback): 
- PATTERN-DND.N03 (Sidebar as drop target): 
- PATTERN-DND.N04 (Drop confirmation): 
- PATTERN-DND.N05 (Not draggable): 
- PATTERN-DND.N06 (Drag & drop matrix): 
- PATTERN-DND.N07 (Strip: selection → sidebar playlist): 
- PATTERN-DND.N08 (Strip: tracks → player / Queue): 
- PATTERN-DND.N09 (Strip: Finder files → playlist): 


## index.html — MLM B1 — design packet

Decisions on this page: DEC-012, DEC-039, DEC-044

### B1

- B1.N01 (Export all feedback): 

