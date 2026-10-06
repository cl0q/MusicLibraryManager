# B3 conformance

**Branch / commit.** `b3/w5-5-closing` off `redesign/b3` @ `64f5d1e` (this file is written in the closing package W5-5, 2026-10-06). Audit baseline: `redesign/b3` @ `d5340eb` (W5-AUDIT, read-only); every gap it found was then fixed, decided (`IMP-111` … `IMP-124`) or kept as a deviation, and the verdicts below say which.

**Tests on this branch.** `swift build` clean. `swift test`, two full runs:

- Swift Testing: `Test run with 3202 tests in 329 suites passed` (both runs)
- XCTest: `Executed 14 tests, with 3 tests skipped and 0 failures` (plain run) · `Executed 14 tests, with 0 failures` (run with `MLM_SNAPSHOTS=1 MLM_SNAPSHOT_SET=macos27-arm64`, the snapshot suite rendering and comparing 27 fixtures × Light/Dark against the committed baselines)
- Snapshot baselines: `MLMTests/Snapshots/__Snapshots__/macos27-arm64`, 54 PNGs. Inventory 149 files · 27 fixtures · 21 rendered · 40 non-view · 88 deferred (deferrals carry their reason in `SnapshotFixtures.swift`).

**Read-only walk against** `design/b1/COVERAGE.md` (308 inventory + 66 new IDs = 374 rows), `UI-CONVENTIONS.md`, THOUGHTS §10, the five `patterns-*.html` pages and `B3-PLAN.md` §4/§6. No build of the app was launched, no screenshot taken, no database opened.

**Method.** Each ID was located by its citation in code comments (`V-…`, `CM-…`, `UC-…`, `IMP-…`), then the cited lines were read; copy was checked by grepping every verbatim string of UC §15–§18 / §10.2 and every button / menu-item title of the area mockups against `MLM/`. "as designed" = implementation found and no deviation seen in the lines read (not a line-by-line proof of every sub-element). Evidence paths are relative to the repo root; `file:line` numbers are as of the audit commit, the text anchors still hold. `deviates (IMP-nnn)` cites the recorded decision (`B3-PLAN.md` §4) instead of re-flagging. Rows changed after the audit name their new evidence (a test suite or file) and the fixing package.

**Verdict words.** `as designed` · `removed by design` · `deviates (IMP-nnn)` · `not done` · `not verifiable without launch`. No `deviates (undecided)` is left: each of the 25 was fixed (→ `as designed`) or decided (→ `deviates (IMP-nnn)`).

**Counts:** as designed 265 · removed by design 54 · deviates (IMP) 45 · not done 1 · not verifiable without launch 9 = 374. (At the audit: 251 · 54 · 30 · 25 undecided · 5 not done · 9.)

## What is left

### `not done` (1)

- `G-LIB-CURRENT` — the window subtitle carries `‹Library› · ‹count›` for All Tracks, Albums, Genres, All Playlists, a playlist page and Folders; Review, Discover, a sync profile and pushed album / genre pages show the library name only (no cheap count source).

### Differences with no row of their own (residuals inside rows marked `as designed` or `deviates`)

- Search ▸ Online rows have no `Preview` (IMP-109 covers Similar ▸ Online and Reels results; UC-PRIM-16 also names Search). Row `V-SEARCH`.
- Stream preview fetches to a temporary file (≤ 48 MB) before playing and is never started with Space on Similar / Reels rows (no selection model there; button and context menu only). IMP-119.
- `Show Versions in All Tracks` (Review) filters by words, not ids. Row `V-REV`.
- Info ▸ Similar rows (G26) are not interactive; `Show All` opens Similar.
- `Set Artwork` writes the artwork cache only, never the audio file (IMP-121).
- A-TRACK-REMOVE-FAILED has no `Details` disclosure; the per-track text goes to Activity ▸ Logs (IMP-122).
- `Share…` is not in the Queue / Recommendation menus (IMP-124).
- `TrackCoverView`'s fallback glyph keeps `.font(.system(size:))` (it scales with the cover size).
- Copy that differs from the shapes now written in `UI-CONVENTIONS.md` (the conventions were extended to the recommended forms, the code was not changed in W5-5): `Import started — “‹folder›”` reads in code without the `‹n› files · Show in Activity` form of UC-JOB-08; the Locate File… refusal for an unreadable file reads `Couldn’t use “‹file›” — the file can’t be read` (UC-SHEET-25 / §15.4 use the same wording).
- Tag writing stays off by default (IMP-044, `B3-PLAN.md` §5 Q6, Oliver's decision pending): rows `P-INSPECTOR-GENERAL`, `F-13`, problem 17.
- No online album lookup (IMP-076, IMP-082, `B3-PLAN.md` §5 Q2).

### Oliver's checklist: `not verifiable without launch`

Nothing below can be proven from code, tests or the snapshot harness (no composited Liquid Glass, no real window, no device, no network). Walk these in the running app:

| ID / area | What to check |
|---|---|
| `K-LIB-SPACE`, `F-03` | Space on a focused track table starts a preview (a SwiftUI `Table` may not deliver Space to `.onKeyPress`; fallback is Track ▸ Preview) |
| `K-SEARCH-RETURN`, `K-SEARCH-ESC` | Return in the search field hands focus to the rows; Esc leaves search and restores the scope `This view` |
| `K-WAVE-PINCH` | Pinch on the Info waveform zooms it (only the zoom binding exists, no `MagnifyGesture` found) |
| `D-SIDEBAR-SPRINGLOAD`, `D-LIB-SPRING`, `D-PL-SPRINGLOAD-CARD` | System spring-loading on sidebar rows, playlist cards and the library row while dragging |
| `D-LOGS-TEXTDRAG` | Dragging selected text out of Activity ▸ Logs (system `NSTextView` drag) |
| W5-1a | Window subtitle per place; ⌥↑ / ⌥↓ in a Manual-order playlist; drop an image on the Info cover then Undo; Info ▸ Similar list and `Show All`; Library search with an album word; trash-failure alert (read-only volume); drag a held recommendation onto a playlist |
| W5-1b | Share… sheet from Track and from the context menu; Dock menu without the open library; the three tips one at a time, none while a sheet is open or a preview plays; `Show Tips Again` (the reset also takes effect at the next launch, IMP-123) |
| W5-F2 | Sync: plan after a download is quick; reorder tracks in a profile's playlist → `1 playlist to update`, Sync Now copies nothing and the device playlist has the new order; drag a profile row (and Undo); folder row dropped on the Queue column; Review ▸ Resolved `Decision` column and a library switch mid-scan; **Preview on a SoundCloud suggestion in Similar ▸ Online and on a Reels result** (the real fetch, the yt-dlp format and AVFoundation reading the temporary file were never exercised); reel link pasted into search or dropped on the window opens Discover ▸ Reels; `⌫` on `Delete Reel…`; Refresh from Sources appends new likes to an existing Liked playlist |
| Open since earlier waves | Cover-well drop and genre completion links in the album sheets; the `radioGroup` Merge-as picker; album grid arrow keys and type-select; Info cover and playlist grid keyboard use; the visual pass of every light / dark pair in `MLMTests/Snapshots/__Snapshots__/macos27-arm64` (first-time baselines, recorded without a visual review by an agent) |

## Table

| ID | Page | Verdict | Evidence | Note |
|---|---|---|---|---|
| `W-MAIN` | launch.html | as designed | MLM/App/MLMApp.swift:16, MLM/Views/Launch/LaunchRootView.swift:50 | One `Window`, `.windowToolbarStyle(.unified)`; subtitle gap see G-LIB-CURRENT |
| `W-SETTINGS` | settings.html | as designed | MLM/Views/Settings/SettingsView.swift:3, MLM/Views/Settings/SettingsView.swift:48 |  |
| `W-REMOTE` | import.html | removed by design | MLM/Views/Import/ImportPlaylistSheet.swift | S-IMPORT sheet; AppKit window removed (W3-ADD) |
| `V-LAUNCH-NOLIB` | launch.html | removed by design | MLM/Views/Launch/LibraryPickerView.swift:7 | → V-PICKER |
| `V-LAUNCH-CANTOPEN` | launch.html | removed by design | MLM/Views/Launch/LibraryPickerView.swift:7 | → picker row state |
| `V-LAUNCH-INVALID` | launch.html | as designed | MLM/Views/Launch/LibraryLaunchFailureView.swift:61, MLM/Services/Library/LibraryLaunchCoordinator.swift:5 |  |
| `V-LAUNCH-LOADING` | launch.html | deviates (IMP-041) | MLM/Views/Launch/LibraryLoadingView.swift:3, MLM/Services/Library/LibraryOpenPhase.swift:61 | Backup phase indeterminate with size (design: determinate %) |
| `V-LAUNCH-FAILED` | launch.html | as designed | MLM/Views/Launch/LibraryLaunchFailureView.swift:4, MLM/Services/Library/LibraryLaunchCoordinator.swift:39 |  |
| `V-MAIN-LAYOUT` | shell.html | as designed | MLM/Views/ContentView/ContentView.swift:38 |  |
| `V-QUEUE` | queue.html | as designed | MLM/Views/Queue/QueuePanelModel.swift:4, MLM/Views/Queue/QueuePanel.swift:24 |  |
| `V-SEARCH` | search.html | deviates (IMP-109) | MLM/Views/Search/SearchResultsView.swift:108-160, MLM/Views/Search/OnlineSearchResultsView.swift:6, MLMTests: LibrarySearchAlbumsTests | Library scope has the Albums section since W5-1a (five rows + `Show All`, rows open the album; G28). Online rows of Search have no `Preview`: IMP-109 gave it to Similar ▸ Online and Reels results only |
| `V-LIB` | library.html | as designed | MLM/Views/Library/LibraryView.swift:108-113, MLMTests: W5GapPagesTests | Empty sentence completed with `You can also drop files here.` (G12, W5-1a) |
| `V-TRACK-TABLE` | library.html | as designed | MLM/Views/TrackList/TrackListTable.swift:5 |  |
| `V-TRACK-PRIMITIVES` | library.html | as designed | MLM/Views/TrackList/TrackCell.swift, MLM/Views/TrackList/TrackRowPresentation.swift:59 |  |
| `V-PL` | playlists.html | as designed | MLM/Views/Playlists/PlaylistsView.swift:4, MLM/Views/Playlists/PlaylistsView.swift:26 |  |
| `V-PLD` | playlists.html#detail | as designed | MLM/ViewModels/PlaylistDetailViewModel.swift:4, MLM/ViewModels/PlaylistDetailViewModel.swift:42 |  |
| `V-FOLD` | folders.html | deviates (IMP-047) | MLM/Views/Folders/FoldersView.swift, MLM/Views/Folders/FolderOutlineTable.swift | IMP-047 details; subtitle without count (FoldersView.swift:37, UC-WIN-06) |
| `V-SYNC` | sync.html | removed by design | MLM/Views/Sidebar/SidebarView.swift:87-113 | Profiles are sidebar rows; empty `No sync profiles yet.` |
| `V-SYNC-DETAIL` | sync.html | deviates (IMP-045) | MLM/Views/Sync/SyncProfilePage.swift:3, MLM/Views/Sync/SyncProfileSections.swift | No `Resume When Connected` (banner resumes by itself), no Path-style option. Sync Now also for playlist-only changes (IMP-105) |
| `V-SRC` | import.html | removed by design | MLM/Views/Settings/SourcesSetupView.swift:3, MLM/Views/Shell/ShellToolbar.swift:88 | Settings ▸ Sources + Add menu |
| `V-REV` | review.html | as designed | MLM/Views/Review/ReviewView.swift:240, MLMTests: W5GapPagesTests, ReviewNitsTests | Empty sentence names album suggestions (G18); Resolved has the `Decision` column (IMP-108, W5-F2). Residual, not changed: `Show Versions in All Tracks` filters by words, not ids |
| `V-DISC` | discover.html | as designed | MLM/ViewModels/DiscoverModel.swift:4, MLM/Views/Discover/DiscoverView.swift:3 |  |
| `V-INBOX` | discover.html#recs | deviates (IMP-115) | MLM/Views/Discover/RecommendationsView.swift:36-43, MLM/Views/Discover/DiscoverView.swift:105, MLMTests: SimilarModelTests | Empty state has `Similar to the Playing Track` (G19, W5-1b). No sheet (IMP-115). No per-row Keep/Dismiss buttons (W3-DISC-A note: keys and menu only) |
| `V-REELS` | discover.html#reels | deviates (IMP-114) | MLM/Views/Reels/ReelsView.swift, MLM/Views/Reels/ReelWorkbenchSections.swift, MLM/Views/Shared/StreamPreviewControls.swift | `Preview` / `Stop` on result rows (IMP-109, IMP-119) and reel links routed to Reels (IMP-110) are built; result rows are menu only, not draggable (IMP-114) |
| `P-SIDEBAR` | shell.html | as designed | MLM/Views/Sidebar/SidebarView.swift:4, MLM/Views/Sidebar/SidebarView.swift:65 |  |
| `P-PINNED` | playlists.html | removed by design | MLM/Views/Sidebar/SidebarView.swift:52-84 | Sidebar Playlists section |
| `P-TOOLBAR` | shell.html | as designed | MLM/Views/Shell/ShellToolbar.swift:17-50 | Order/customization per UC-TB-01/04 |
| `P-PLAYER` | player.html | as designed | MLM/Views/Player/PlayerBar.swift:4 |  |
| `P-INSPECTOR` | inspector.html | as designed | MLM/Views/Inspector/InspectorDetailsTab.swift:3, MLM/Views/Inspector/InspectorDetailsTab.swift:89 |  |
| `P-INSPECTOR-WAVEFORM` | inspector.html | as designed | MLM/Views/Inspector/InspectorAudioTab.swift:4, MLM/Views/Inspector/InspectorAudioTab.swift:217 |  |
| `P-INSPECTOR-GENERAL` | inspector.html | deviates (IMP-044) | MLM/Views/Inspector/InspectorDetailsTab.swift:3 | `Write tags to files` OFF by default (§10 Q7 says on; §5 Q6 pending) |
| `P-INSPECTOR-AUDIO` | inspector.html | as designed | MLM/Views/Inspector/InspectorAnalysis.swift:4, MLM/Views/Inspector/InspectorAnalysis.swift:8 |  |
| `P-INSPECTOR-FILE` | inspector.html | as designed | MLM/Views/Inspector/InspectorFileStatus.swift:3, MLM/Views/Inspector/InspectorFileTab.swift:4 |  |
| `P-INSPECTOR-SIMILAR` | inspector.html | as designed | MLM/Views/Inspector/InspectorAudioTab.swift:77-83, MLMTests: InspectorSimilarTests | The five nearest in-library matches (title, artist, `‹n›%`) + `Show All` (G26, W5-1a); the rows are not interactive |
| `P-INSPECTOR-DEBUG` | inspector.html | removed by design | MLM/Views/Inspector/InspectorFileTab.swift:152 | Diagnostics disclosure on File tab |
| `P-ACTIVITY` | activity.html | deviates (IMP-039) | MLM/Views/Activity/ActivityToolbarItem.swift:3 |  |
| `P-ACTIVITY-OPS` | activity.html | as designed | MLM/Views/Activity/ActivityToolbarItem.swift:84, MLM/Views/Activity/ActivityToolbarItem.swift:208 |  |
| `P-ACTIVITY-LOGS` | activity.html#logs | as designed | MLM/Views/Activity/LogFeed.swift:64, MLM/Views/Activity/ActivityLogsView.swift:5 |  |
| `ST-STUDIO-GRID` | genres.html#list | as designed | MLM/Views/Genres/GenresView.swift:9 | Moved to V-GENRES |
| `ST-STUDIO-GENRE` | genres.html#detail | as designed | MLM/Views/Genres/GenreSuggestionsSection.swift:3, MLM/Views/TrackList/TrackCell.swift:157 |  |
| `ST-STUDIO-MERGE` | genres.html#list | as designed | MLM/Views/Genres/GenreMergeSheet.swift:3, MLM/Views/Genres/GenreMergeSheet.swift:148 |  |
| `ST-STUDIO-EXPORT` | genres.html#list | as designed | MLM/Views/Genres/CreateMLExportSheet.swift:4, MLM/Services/Genres/CreateMLExport.swift:4 |  |
| `ST-LIB` | settings.html#library | as designed | MLM/Views/Settings/LibrarySetupView.swift:6, MLM/Views/Settings/LibrarySetupView.swift:232 |  |
| `ST-SRC` | settings.html#sources | deviates (IMP-044) | MLM/Views/Settings/SourcesSetupView.swift:3 | No refresh schedule (ST-SRC.N03); YouTube row without button |
| `ST-MAINT` | settings.html#maintenance | deviates (IMP-113) | MLM/Views/Settings/MaintenanceView.swift:3, MLM/Views/Settings/MaintenanceView.swift:6 | Wording `Maintenance that reads audio files can’t run until it is.` / `Applies to the next run.` instead of the mockup's "job" (UC-GLOSS-03, G14) |
| `ST-BACKUP` | settings.html#backup | as designed | MLM/ViewModels/BackupSettingsViewModel.swift:69, MLM/Views/Settings/BackupSettingsView.swift:5 |  |
| `ST-STORAGE` | settings.html#storage | as designed | MLM/ViewModels/DataLocationsViewModel.swift:13, MLM/ViewModels/DataLocationsViewModel.swift:25 |  |
| `ST-PLAYBACK` | settings.html#playback | as designed | MLM/Views/Settings/PlaybackSettingsView.swift:3 |  |
| `ST-ADV` | genres.html | removed by design | MLM/Views/Genres/GenresView.swift:9 | Genre tools → Genres |
| `S-LIBFILE-OPEN` | patterns-sheets-alerts.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:27, MLM/Views/Launch/LibraryFileIcon.swift:76 | `Choose a library file.` |
| `S-WIZ-FOLDER` | patterns-sheets-alerts.html | as designed | MLM/Views/Launch/LibrarySetupFlowView.swift:111 |  |
| `S-ADOPT` | launch.html | as designed | MLM/Views/Launch/LibraryAdoptionSheet.swift:4, MLM/Views/Launch/LibraryAdoptionSheet.swift:59 |  |
| `S-NEWLIB` | launch.html | as designed | MLM/Views/Launch/NewLibrarySheet.swift:3, MLM/Views/Launch/NewLibrarySheet.swift:90 |  |
| `S-WIZARD` | launch.html | removed by design | MLM/Views/Launch/LibrarySetupFlowView.swift:4 | → V-SETUP |
| `S-SEARCH-UNIVERSAL` | search.html | removed by design | MLM/Views/Search/SearchSuggestionList.swift, MLM/Views/Import/QuickAddSheet.swift | → suggestions + S-QUICKADD |
| `S-PLAYER-COVER` | player.html | as designed | MLM/Views/Player/PlayerBar.swift:155, MLM/Views/Player/PlayerBar.swift:164 |  |
| `S-SEL-NEWPLAYLIST` | patterns-sheets-alerts.html | as designed | MLM/App/Commands/TrackCommandActions.swift:81, MLM/Views/Shell/ShellActions.swift:86 |  |
| `S-SEL-NEWSYNCPROFILE` | patterns-sheets-alerts.html | as designed | MLM/Views/Sync/NewSyncProfileSheet.swift:87 | `Create and Add ‹n› Tracks` |
| `S-GROOVE-SIMILAR` | discover.html#similar | removed by design | MLM/Views/Similar/SimilarView.swift:80 | → V-SIMILAR |
| `S-STUDIO-EXPORTFOLDER` | patterns-sheets-alerts.html | as designed | MLM/Views/Genres/CreateMLExportSheet.swift:112 |  |
| `S-PL-NEWPLAYLIST` | playlists.html | removed by design | MLM/Views/Sidebar/SidebarView.swift:480, MLM/Views/Shell/ShellEdits.swift:156 | Inline rename |
| `S-PL-BANNER-PINLIMIT` | playlists.html | removed by design | — | Pinning removed (DEC-003) |
| `S-PL-BANNER-COVERDROP` | playlists.html | as designed | MLM/Services/DragDrop/DropRules.swift:608, MLM/Views/Playlists/PlaylistsView.swift:279 |  |
| `S-PLD-LINK` | playlists.html#detail | deviates (IMP-042) | MLM/Views/Playlists/PlaylistLinkSheet.swift:4 | Spotify playlist links refused (pattern page says accepted) |
| `S-PLD-M3U-OPEN` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistM3UImportSheet.swift:65,93-97 |  |
| `S-PLD-M3U-PREVIEW` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistM3UImportSheet.swift:9, MLM/Views/Playlists/PlaylistM3UImportSheet.swift:116 |  |
| `S-SYNC-DEVICEINGEST` | sync.html | as designed | MLM/ViewModels/DevicePlaylistChangesModel.swift:4, MLM/Views/Sync/SyncProfileSheets.swift:271 |  |
| `S-SYNC-NEWPROFILE` | sync.html | as designed | MLM/ViewModels/SyncViewModel.swift:727, MLM/Views/Sync/NewSyncProfileSheet.swift:4 |  |
| `S-SYNC-OPENPANEL` | sync.html | as designed | MLM/Views/Sync/NewSyncProfileSheet.swift:106, MLM/Views/Sync/SyncProfileSheets.swift:59 |  |
| `S-SYNC-RENAME` | sync.html | removed by design | MLM/Views/Sync/SyncProfileMenu.swift:27 | Inline rename |
| `S-SYNC-PLAYLISTPICKER` | sync.html | as designed | MLM/Views/Sync/SyncProfileMenu.swift:25, MLM/Views/Sync/SyncProfileSheets.swift:68 |  |
| `S-SYNC-INGESTPREVIEW` | sync.html | removed by design | MLM/Views/Sync/SyncProfileSheets.swift:271 | Right half of device sheet |
| `S-SYNC-TOAST` | sync.html | removed by design | MLM/Views/Sync/NewSyncProfileSheet.swift:8, MLM/Views/Sync/SyncProfileSections.swift:433 | Preset summary + Reset to Device Defaults |
| `S-REV-UNDOTOAST` | review.html | removed by design | MLM/Views/Shell/StatusBarCenter.swift | Status-bar message with Undo |
| `S-SRC-OAUTH` | import.html | as designed | MLM/ViewModels/SourceSignInModel.swift:4, MLM/ViewModels/SourcesViewModel.swift:254 |  |
| `S-REELS-OPENFOLDER` | discover.html#reels | as designed | MLM/Views/Reels/ReelsView.swift:63 |  |
| `S-REELS-KEYFRAME` | discover.html#reels | as designed | MLM/Views/Reels/ReelWorkbench.swift:108, MLM/Views/Reels/ReelWorkbench.swift:182 |  |
| `S-SET-LIBROOT` | patterns-sheets-alerts.html | as designed | MLM/Views/Settings/LibrarySetupView.swift:391 |  |
| `S-SET-IMPORTFOLDER` | patterns-sheets-alerts.html | as designed | MLM/Views/Settings/LibrarySetupView.swift:292 |  |
| `S-SET-CACHEFOLDER` | patterns-sheets-alerts.html | as designed | MLM/Views/Settings/MaintenanceView.swift:119 |  |
| `S-SET-BACKUPFOLDER` | patterns-sheets-alerts.html | as designed | MLM/Views/Settings/BackupSettingsView.swift:81 |  |
| `S-SET-EXPORTFOLDER` | patterns-sheets-alerts.html | removed by design | MLM/Views/Genres/CreateMLExportSheet.swift:112 | Same panel as S-STUDIO-EXPORTFOLDER |
| `A-LIB-SWITCH` | launch.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:57, MLM/Services/Library/RunningWorkSummary.swift:3 |  |
| `A-LIB-COPY` | launch.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:6, MLM/Services/Library/LibraryLaunchCoordinator.swift:178 |  |
| `A-LIBFILE-CANTOPEN` | launch.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:6 |  |
| `A-LIBFILE-INVALID` | launch.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:7, MLM/Services/Library/LibraryLaunchCoordinator.swift:5 |  |
| `A-SIDEBAR-DELETEPL` | playlists.html | removed by design | MLM/Views/Shell/ShellEdits.swift:502 | → A-PL-DELETE |
| `A-SIDEBAR-RENAMEFAIL` | playlists.html | removed by design | MLM/Views/Sidebar/SidebarView.swift:395-404 | Inline error |
| `A-TRACK-REMOVE` | library.html | as designed | MLM/App/Commands/TrackCommandActions.swift:142 |  |
| `A-TRACK-REMOVE-FAILED` | patterns-sheets-alerts.html | deviates (IMP-122) | MLM/App/Commands/TrackCommandActions.swift:304-333, MLMTests: TrackRemovalFailureTests | SwiftUI `.alert` with counted title, `Show the ‹n› Tracks` / `OK` (G35, W5-1a); a `.alert` holds no `Details` disclosure, the per-track text goes to Activity ▸ Logs |
| `A-GROOVE-DELETEFILE` | discover.html#similar | removed by design | MLM/Views/Similar/SimilarView.swift:270-300 | No delete in Similar (PP-INSPECTOR-21) |
| `A-META-SAVEERROR` | inspector.html | removed by design | MLM/Views/Inspector/InspectorDetailsTab.swift:72 | Inline error |
| `A-PL-DELETE` | playlists.html | as designed | MLM/Database/PlaylistRepository.swift:988, MLM/Views/Playlists/PlaylistM3UImportSheet.swift:25 |  |
| `A-PLD-LINKMISMATCH` | playlists.html#detail | removed by design | MLM/Views/Playlists/PlaylistLinkSheet.swift:8 | Inline result |
| `A-PLD-LINKDONE` | playlists.html#detail | removed by design | MLM/Views/Playlists/PlaylistLinkSheet.swift:129 | Status bar |
| `A-PLD-IMPORTDONE` | playlists.html#detail | removed by design | MLM/Services/Playlists/PlaylistEdits.swift:46 | Status bar |
| `A-PLD-REMOVE` | playlists.html#detail | removed by design | MLM/Views/Shell/ShellEdits.swift | Undoable removal |
| `A-SYNC-DELETEPROFILE` | sync.html | as designed | MLM/ViewModels/SyncViewModel.swift:449, MLM/Views/Sidebar/SidebarView.swift:185 |  |
| `A-SYNC-REMOVECONTENT` | sync.html | removed by design | MLM/Views/Shell/ShellEdits.swift:810 | Undoable removal |
| `A-SRC-KEYCHAIN` | import.html | as designed | MLM/Views/Import/SourceSignInView.swift:3, MLM/Services/Sources/SourceAccountStates.swift:8 |  |
| `A-INBOX-DELETE` | discover.html#recs | removed by design | MLM/ViewModels/DiscoverModel.swift | Dismiss undoable (IMP-055) |
| `A-INBOX-ERROR` | discover.html | removed by design | MLM/ViewModels/DiscoverModel.swift | Status bar |
| `A-REELS-DELETE` | discover.html#reels | deviates (IMP-065) | MLM/ViewModels/ReelsModel.swift:168,624 | Two destructive buttons instead of the Trash toggle |
| `A-REELS-DELETEERROR` | discover.html | removed by design | MLM/ViewModels/ReelsModel.swift:633 | Status bar (IMP-062) |
| `A-SET-DISCONNECT` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:45 |  |
| `A-SET-RESTORE` | settings.html#backup | as designed | MLM/ViewModels/BackupSettingsViewModel.swift:249, MLM/ViewModels/BackupSettingsViewModel.swift:254 |  |
| `A-SET-RESTOREFAILED` | settings.html#backup | as designed | MLM/Views/Settings/BackupSettingsView.swift:108 |  |
| `A-SET-PATHAPPLY` | settings.html#maintenance | as designed | MLM/Views/Settings/MaintenanceView.swift:297, MLM/Services/Maintenance/MaintenanceJobs.swift:114 |  |
| `A-SET-PATHROLLBACK` | settings.html#maintenance | as designed | MLM/Views/Settings/MaintenanceView.swift:304, MLM/Services/Maintenance/OrganizedPathMigrationService.swift:454 |  |
| `A-OPS-CLEARQUEUE` | activity.html | as designed | MLM/Views/Activity/ActivityToolbarItem.swift:228, MLM/Services/Activity/ActivityModel.swift:586 |  |
| `CM-SIDEBAR-PINNED` | playlists.html | as designed | MLM/Views/Playlists/PlaylistActions.swift:9, MLM/Views/Sidebar/SidebarView.swift:287 | Shared PlaylistMenu builder |
| `CM-SIDEBAR-PINNEDRENAME` | playlists.html | removed by design | MLM/Views/Sidebar/SidebarView.swift:395 | System text menu |
| `CM-TRACK` | library.html | deviates (IMP-118) | MLM/Views/TrackList/TrackMenuModel.swift:140-260, MLM/Views/TrackList/TrackMenu.swift, MLM/Views/TrackList/TrackShare.swift | `Share…` built (IMP-124). A Not-downloaded / Download-failed single track still has no Queue group (IMP-038, kept by IMP-118 until Oliver answers) |
| `CM-STUDIO-SUGGESTION` | genres.html#detail | deviates (IMP-046) | MLM/Views/Genres/GenreSuggestionsSection.swift:169 | `Not This Genre` → `Not Now` (session-only, IMP-046) |
| `CM-STUDIO-GENRETRACK` | genres.html#detail | as designed | MLM/Views/Genres/GenreDetailView.swift | Track menu + extras |
| `CM-STUDIO-MERGETABLE` | genres.html#list | as designed | MLM/Views/Genres/GenreMergeSheet.swift:78 | Standard TrackListTable menu |
| `CM-PL-CARD` | playlists.html | as designed | MLM/Views/Playlists/PlaylistActions.swift:9 |  |
| `CM-FOLD-TREE` | folders.html | as designed | MLM/Views/TrackList/TrackMenu.swift:189, MLM/Views/Folders/FolderMenus.swift:4 |  |
| `CM-FOLD-SUBFOLDER` | folders.html | removed by design | MLM/Views/Folders/FolderMenus.swift:4 | → CM-FOLD-TREE |
| `CM-FOLD-SEARCHRESULT` | folders.html | removed by design | MLM/Views/Folders/FolderMenus.swift:4 | → CM-FOLD-TREE |
| `CM-SYNC-PROFILE` | sync.html | as designed | MLM/Database/SyncRepository.swift:92, MLM/Views/Sidebar/SidebarView.swift:372 |  |
| `CM-SYNC-PLROW` | sync.html | as designed | MLM/Views/Sync/SyncProfileSections.swift:145 |  |
| `CM-SYNC-TRACKROW` | sync.html | deviates (IMP-045) | MLM/Views/Sync/SyncProfileSections.swift:145 | Reduced menu, not the shared builder |
| `CM-SYNC-PREVIEWFILE` | sync.html | as designed | MLM/Views/Sync/SyncProfileSections.swift:379 |  |
| `CM-SYNC-FAILED` | sync.html | as designed | MLM/Views/Sync/SyncProfileSections.swift:516 |  |
| `CM-REELS-ADDPL` | discover.html#reels | as designed | MLM/Views/Reels/ReelWorkbenchSections.swift:253 |  |
| `CM-REELS-TEXTPILL` | discover.html#reels | as designed | MLM/ViewModels/ReelsModel.swift:26, MLM/ViewModels/ReelsModel.swift:377 |  |
| `CM-LOGS-TEXT` | activity.html#logs | as designed | MLM/Views/Activity/ActivityLogsView.swift:400 |  |
| `M-APP` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:185-192 |  |
| `M-FILE` | patterns-menus-shortcuts.html | deviates (IMP-041) | MLM/App/Commands/FileCommands.swift, MLM/App/LibraryCommands.swift:47 | `Clear Menu` stays pending (W3-LAUNCH) |
| `M-EDIT` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/EditCommands.swift | Delete without ⌫ glyph (IMP-014) |
| `M-VIEW` | patterns-menus-shortcuts.html | deviates (IMP-112) | MLM/App/Commands/ViewCommands.swift | Columns ▸ lists the hideable columns; `Auto Size All Columns` dropped (SwiftUI `Table` has no width-reset API) |
| `M-NAVIGATE` | patterns-menus-shortcuts.html | removed by design | MLM/App/Commands/GoCommands.swift:3 | → Go menu |
| `M-PLAYBACK` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/PlaybackCommands.swift | Play/Pause without key (§10 Q1) |
| `M-LIBRARY` | patterns-menus-shortcuts.html | deviates (IMP-074) | MLM/App/Commands/LibraryMenuCommands.swift:43-87 | Adds `Read Track Numbers` and `Clear Source Names from Album…` (IMP-074, IMP-098) |
| `M-WINDOW` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:332, MLM/App/Commands/WindowCommands.swift:3 |  |
| `M-HELP` | patterns-menus-shortcuts.html | deviates (IMP-116) | MLM/App/Commands/HelpCommands.swift:9-15, MLM/App/Commands/MenuCatalog.swift:339-345, MLMTests: W5GapCommandsTests, MenuBarStructureTests | `MLM Help` removed (no Help Book, IMP-116); `Show Tips Again` wired to TipKit (IMP-123) |
| `M-DOCK` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/DockMenu.swift:36-57, MLMTests: W5GapCommandsTests | Dock lists the other known libraries, not the open one (G30, W5-1b) |
| `K-APP-SETTINGS` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:187 |  |
| `K-FILE-NEWPLAYLIST` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:195 |  |
| `K-FILE-OPENLIB` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:217 |  |
| `K-NAV-LIBRARY` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:321 | ⌘1 All Tracks |
| `K-NAV-PLAYLISTS` | patterns-menus-shortcuts.html | removed by design | MLM/App/Commands/MenuCatalog.swift:322 | ⌘2 = Albums |
| `K-NAV-FOLDERS` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:324 | ⌘4 |
| `K-NAV-SYNC` | patterns-menus-shortcuts.html | removed by design | — |  |
| `K-NAV-SOURCES` | patterns-menus-shortcuts.html | removed by design | MLM/Views/Shell/NavigationModel.swift:101 |  |
| `K-NAV-REVIEW` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:326 |  |
| `K-NAV-DISCOVER` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:325 | ⌘5 |
| `K-NAV-QUEUE` | patterns-menus-shortcuts.html | removed by design | MLM/App/Commands/MenuCatalog.swift:242 | ⌥⌘U |
| `K-PLAYBACK-STOP` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:285 |  |
| `K-PLAYBACK-SKIPBACK` | patterns-menus-shortcuts.html | removed by design | MLM/App/Commands/MenuCatalog.swift:287,289 | ⌘← Previous, ⌥⌘← seek |
| `K-PLAYBACK-SKIPFWD` | patterns-menus-shortcuts.html | removed by design | MLM/App/Commands/MenuCatalog.swift:286,288 |  |
| `K-LIBRARY-IMPORT` | patterns-menus-shortcuts.html | removed by design | MLM/App/Commands/MenuCatalog.swift:205-206 | ⇧⌘I = Import Playlist from Source… |
| `K-LIBRARY-MOREINFO` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:241 | ⌘I Show Info |
| `K-WIN-SEEKBACK` | patterns-menus-shortcuts.html | removed by design | MLM/Views/TrackList/TrackListPreviewKeys.swift:69 | ← only while previewing |
| `K-WIN-SEEKFWD` | patterns-menus-shortcuts.html | removed by design | MLM/Views/TrackList/TrackListPreviewKeys.swift:69 |  |
| `K-SEARCH-CMDF` | search.html | as designed | MLM/App/Commands/EditCommands.swift:31 |  |
| `K-SEARCH-RETURN` | search.html | not verifiable without launch | MLM/Views/Shell/ShellSearch.swift:144, MLM/Views/Search/SearchFocusHandoff.swift:4 | Focus hand-off to rows |
| `K-SEARCH-ESC` | search.html | not verifiable without launch | MLM/Views/Shell/ShellSearch.swift:415 | System `.searchable` Esc; scope reset to This view |
| `K-SIDEBAR-QUEUE8` | shell.html | removed by design | — | ⌘8 unbound |
| `K-SIDEBAR-NAV` | shell.html | as designed | MLM/App/Commands/MenuCatalog.swift:321-326 |  |
| `K-SIDEBAR-RENAME` | playlists.html | as designed | MLM/Views/Sidebar/SidebarView.swift:403-404 |  |
| `K-SEARCH-UNIVERSAL-KEYS` | search.html | removed by design | — |  |
| `K-LIB-RESCAN` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/TrackCommands.swift:165-215 | One ⌘R, titled per view |
| `K-LIB-SPACE` | player.html | not verifiable without launch | MLM/Views/TrackList/TrackListPreviewKeys.swift:69 | W2-C: whether `Table` delivers Space to `.onKeyPress` is unverified |
| `K-LIB-DELETE` | patterns-menus-shortcuts.html | as designed | MLM/Views/TrackList/TrackListTable.swift:230, MLM/App/Commands/MenuCatalog.swift:281 |  |
| `K-LIB-INFO` | inspector.html | as designed | MLM/App/Commands/MenuCatalog.swift:241 |  |
| `K-LIB-RETURN` | player.html | as designed | MLM/Views/TrackList/TrackListTable.swift:226, MLM/Views/TrackList/TrackPrimaryAction.swift |  |
| `K-META-EDIT-RETURN` | inspector.html | as designed | MLM/Views/Inspector/InspectorDetailsTab.swift:72 |  |
| `K-META-EDIT-ESC` | inspector.html | as designed | MLM/Views/Inspector/InspectorDetailsTab.swift:73 |  |
| `K-WAVE-PINCH` | inspector.html | not verifiable without launch | MLM/Views/Inspector/InspectorAudioTab.swift:284-289, MLM/Views/TrackDetail/WaveformView.swift:22 | No `MagnifyGesture` found; zoom binding only |
| `K-STUDIO-MERGE-PRIMARY` | genres.html#list | as designed | MLM/Views/Genres/GenreMergeSheet.swift:78 | Standard TrackListTable |
| `K-PL-NEW` | playlists.html | removed by design | MLM/App/Commands/MenuCatalog.swift:195 |  |
| `K-PL-NEWPOPOVER-ESC` | playlists.html | removed by design | — |  |
| `K-PL-NEWPOPOVER-RETURN` | playlists.html | removed by design | — |  |
| `K-PL-RENAME` | playlists.html | as designed | MLM/Views/Sidebar/SidebarView.swift:403-404 |  |
| `K-SYNC-REFRESH` | sync.html | as designed | MLM/App/Commands/TrackCommands.swift:193 | Recompute Plan ⌘R |
| `K-SYNC-NEWPROFILE-KEYS` | sync.html | as designed | MLM/Views/Sync/NewSyncProfileSheet.swift:86,90 |  |
| `K-SYNC-RENAME-KEYS` | sync.html | removed by design | MLM/Views/Sidebar/SidebarView.swift:403 |  |
| `K-SYNC-PICKER-RETURN` | sync.html | as designed | MLM/Views/Sync/SyncProfileSheets.swift:43,49 |  |
| `K-REMOTE-DONE` | import.html | removed by design | MLM/Views/Import/ImportPlaylistSheet.swift | Sheet Cancel |
| `K-DISC-NAV` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/MenuCatalog.swift:325 |  |
| `K-REELS-RETURN` | discover.html#reels | as designed | MLM/ViewModels/ReelsModel.swift:260, MLM/ViewModels/ReelsModel.swift:478 |  |
| `K-REELS-LISTNAV` | discover.html#reels | as designed | MLM/Views/Reels/ReelsView.swift | Selecting starts no work (IMP-061) |
| `K-REELS-DELETE` | discover.html#reels | as designed | MLM/Views/Reels/ReelsView.swift:154 | `⌫` shown on `Delete Reel…` (IMP-110) |
| `K-REELS-KEYFRAME-ESC` | discover.html#reels | as designed | MLM/Views/Reels/ReelWorkbench.swift:176 |  |
| `K-SET-COOKIE-RETURN` | patterns-menus-shortcuts.html | as designed | MLM/Views/Settings/SourcesSetupView.swift:295 |  |
| `K-SET-GW-TABLE-RETURN` | genres.html#list | removed by design | MLM/Views/Genres/GenreMergeSheet.swift:78 |  |
| `K-ACT-ESC` | activity.html | removed by design | MLM/Views/Activity/ActivityToolbarItem.swift | System popover Esc |
| `K-LOGS-COPY` | activity.html#logs | as designed | MLM/Views/Activity/ActivityLogsView.swift:202 |  |
| `D-LIBFILE-OPEN` | patterns-dnd.html | as designed | MLM/Services/Library/LibraryLaunchCoordinator.swift:358, MLM/Services/DragDrop/DropRules.swift:173 |  |
| `D-SIDEBAR-SPRINGLOAD` | shell.html | not verifiable without launch | MLM/Views/DragDrop/DropTargetModifier.swift:140 | System spring-loading; rows accept drops |
| `D-QUEUE-ROWS` | queue.html | as designed | MLM/Views/Queue/QueuePanel.swift:69,100,162 | `itemProvider` rows |
| `D-SEARCH-ROWS` | patterns-dnd.html | as designed | MLM/Views/TrackList/TrackListTable.swift:213 |  |
| `D-LIB-TRACK-OUT` | patterns-dnd.html | as designed | MLM/Views/TrackList/TrackListTable.swift:213, MLM/Services/DragDrop/DragPayloads.swift:101 |  |
| `D-LIB-SPRING` | shell.html | not verifiable without launch | MLM/Views/DragDrop/DropTargetModifier.swift:140 | System spring-loading |
| `D-PL-TRACKS-TO-CARD` | playlists.html | as designed | MLM/Services/DragDrop/DropRules.swift:36 |  |
| `D-PL-COVER-TO-CARD` | playlists.html | as designed | MLM/Views/Shell/ShellEdits.swift:759, MLM/Services/DragDrop/DropRules.swift:36 |  |
| `D-PL-SPRINGLOAD-CARD` | patterns-dnd.html | not verifiable without launch | MLM/Views/DragDrop/DropTargetModifier.swift:140 |  |
| `D-PLD-REORDER` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistTable.swift:82, MLM/Views/Shell/ShellEdits.swift:551 |  |
| `D-PLD-INSERT` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistTable.swift:82, MLM/Views/Shell/ShellEdits.swift:551 |  |
| `D-PLD-ROWS-OUT` | patterns-dnd.html | as designed | MLM/Views/TrackList/TrackListTable.swift:213 |  |
| `D-FOLD-TRACKS-OUT` | patterns-dnd.html | as designed | MLM/Views/Folders/FolderOutlineTable.swift:316 |  |
| `D-REELS-IMPORT` | discover.html#reels | as designed | MLM/Views/Reels/ReelsView.swift (dropTarget .reels) |  |
| `D-LOGS-TEXTDRAG` | activity.html#logs | not verifiable without launch | MLM/Views/Activity/ActivityLogsView.swift:278 | System NSTextView drag |
| `D-LIBFILE-WINDOWDROP` | launch.html | as designed | MLM/Views/DragDrop/DropTargetModifier.swift:178 |  |
| `D-WIZ-FOLDERDROP` | launch.html | as designed | MLM/Views/Launch/LibrarySetupFlowView.swift:119 |  |
| `D-LIB-FINDER-IN` | patterns-dnd.html | as designed | MLM/Views/Shell/ShellActions.swift:242, MLM/Views/DragDrop/DropTargetModifier.swift:178 |  |
| `D-LIB-TO-FINDER` | patterns-dnd.html | as designed | MLM/Services/DragDrop/DragPayloads.swift:101-107 | File URL only for reachable local tracks (IMP-040) |
| `D-LIB-TO-SIDEBAR-NEWPL` | shell.html | deviates (IMP-040) | MLM/Views/Sidebar/SidebarView.swift:84,518 | Only the Playlists header / All Playlists row / empty area |
| `D-LIB-TO-QUEUE` | queue.html | as designed | MLM/Views/Queue/QueuePanel.swift:72,86, MLM/Views/Player/PlayerBar.swift |  |
| `D-LIB-TO-SYNC` | shell.html | as designed | MLM/Views/Shell/ShellEdits.swift:678 |  |
| `D-TD-TRACK-OUT` | inspector.html | as designed | MLM/Views/Inspector/InspectorView.swift:155-183, MLMTests: TrackArtworkEditTests | The Info cover drags the single selected track (G25, W5-1a) |
| `D-GROOVE-ROW-TO-PLAYLIST` | discover.html#similar | deviates (IMP-114) | MLM/Views/Similar/SimilarView.swift:270-300 | In-library rows drag; online rows are menu only (`Download`, `Keep and Add to Playlist ▸`). The COVERAGE row promised a drag |
| `D-TD-ARTWORK-IN` | inspector.html | as designed | MLM/Views/Inspector/InspectorView.swift:155-183, MLMTests: TrackArtworkEditTests | Info cover is a drop target: undoable `Set Artwork`, refusal sentence; the artwork cache is written, audio files are not (IMP-121) |
| `D-STUDIO-TRACK-TO-GENRE` | patterns-dnd.html | as designed | MLM/Views/Genres/GenreDetailView.swift:278, MLM/Services/DragDrop/DropRules.swift:54 |  |
| `D-PL-TRACKS-TO-PINNED` | playlists.html | as designed | MLM/Views/Sidebar/SidebarView.swift:287-303 (.dropTarget) |  |
| `D-PL-SELECTION-TO-NEW` | patterns-dnd.html | as designed | MLM/Views/Sidebar/SidebarView.swift:118, MLM/Views/Playlists/PlaylistsView.swift:203 |  |
| `D-PL-PLAYLIST-TO-FOLDER` | playlists.html | as designed | MLM/Database/PlaylistFolderRepository.swift:216, MLM/Services/Playlists/PlaylistEdits.swift:190 |  |
| `D-PL-CARD-REORDER` | patterns-dnd.html | as designed | MLM/Database/PlaylistFolderRepository.swift:216, MLM/Views/Sidebar/SidebarView.swift:55 |  |
| `D-PLD-COVER-TO-HEADER` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistDetailView.swift:192, MLM/Views/Shell/ShellEdits.swift:759 |  |
| `D-PLD-M3U-FROM-FINDER` | patterns-dnd.html | deviates (IMP-040) | MLM/Services/DragDrop/DropRules.swift:85,103,164 | M3U import by drop has no Undo yet |
| `D-FOLD-FOLDER-TO-PLAYLIST` | patterns-dnd.html | as designed | MLM/Views/Folders/FolderOutlineTable.swift:307-311, MLM/Services/DragDrop/DragPayloads.swift:54, MLMTests: QueueFolderDropTests | Folder → Queue queues its in-library tracks in folder order (IMP-107, W5-F2) |
| `D-FOLD-FILES-FROM-FINDER` | patterns-dnd.html | as designed | MLM/Views/Folders/FolderPathBar.swift:8, MLM/Views/Folders/FolderMenus.swift:37 |  |
| `D-PLD-ROWS-TO-FINDER` | patterns-dnd.html | as designed | MLM/Services/DragDrop/DragPayloads.swift:101 |  |
| `D-SYNC-PLAYLIST-TO-PROFILE` | sync.html | as designed | MLM/Views/Sidebar/SidebarView.swift:345-372 (.dropTarget) |  |
| `D-SYNC-TRACKS-TO-PROFILE` | sync.html | as designed | MLM/Views/Shell/ShellEdits.swift:41 |  |
| `D-SYNC-FOLDER-TO-OUTPUT` | sync.html | as designed | MLM/Views/Sync/NewSyncProfileSheet.swift:107 |  |
| `D-SYNC-REORDER-PROFILES` | sync.html | as designed | MLM/Views/Sidebar/SidebarView.swift:87-113, MLM/Services/Sync/SyncProfileOrder.swift | Profile rows drag to reorder, undoable `Reorder Sync Profiles` (IMP-106, v56); payload IMP-120 |
| `D-REMOTE-URL-DROP` | patterns-dnd.html | as designed | MLM/Views/DragDrop/DropTargetModifier.swift:178 |  |
| `D-REMOTE-PLAYLIST-TO-SIDEBAR` |  | removed by design | — |  |
| `D-REV-TRACK-OUT` | patterns-dnd.html | as designed | MLM/Views/Review/ReviewComparison.swift (TrackListTable) |  |
| `D-INBOX-TO-PLAYLIST` | discover.html#recs | as designed | MLM/Services/DragDrop/DropRules.swift, MLM/Services/DragDrop/DropPerformer.swift, MLMTests: HeldRecommendationDropTests | A held recommendation dropped on a playlist or profile is kept and added in one undo group (G37, W5-1a); the status still says `Kept and added ‹n›` when every track was already there |
| `D-REELS-RESULT-TO-PLAYLIST` | discover.html#reels | deviates (IMP-114) | MLM/Views/Reels/ReelWorkbenchSections.swift:253 | Reel results are menu only (`Add to Playlist ▸`), not draggable. The COVERAGE row promised a drag |
| `D-REELS-URL` | discover.html#reels | as designed | MLM/Services/Reels/ReelLinkFetcher.swift:3 |  |
| `D-REELS-OUT` | discover.html#reels | as designed | MLM/Views/Reels/ReelsView.swift:147 |  |
| `D-SET-FOLDER-TO-LIBROOT` | patterns-dnd.html | as designed | MLM/Views/Settings/SettingsRows.swift:175 |  |
| `D-SET-GW-TRACK-TO-GENRE` | patterns-dnd.html | as designed | MLM/Views/Genres/GenresView.swift:7, MLM/Services/DragDrop/DropRules.swift:51 |  |
| `D-SET-GW-TRACK-OUT` | patterns-dnd.html | as designed | MLM/Views/TrackList/TrackListTable.swift:213 |  |
| `D-SET-FOLDER-TO-DESTINATION` | patterns-dnd.html | as designed | MLM/Views/Settings/SettingsRows.swift:176 |  |
| `F-01` | launch.html#setup-1 | as designed | MLM/Views/Launch/LibrarySetupFlowView.swift |  |
| `F-02` | launch.html#adopt | as designed | MLM/Views/Launch/LibraryAdoptionSheet.swift |  |
| `F-03` | library.html | not verifiable without launch | MLM/Views/TrackList/TrackListPreviewKeys.swift:69 | Space on Table unverified |
| `F-04` | search.html | as designed | MLM/Views/Shell/ShellSearch.swift |  |
| `F-05` | import.html | as designed | MLM/Views/Import/ImportPlaylistSheet.swift |  |
| `F-06` | import.html#quickadd | as designed | MLM/Views/Import/QuickAddSheet.swift, MLM/Services/Import/QuickAddRouter.swift | Reel links go to Discover ▸ Reels (IMP-110, W5-F2) |
| `F-07` | library.html | as designed | MLM/Views/Library/LibraryView.swift |  |
| `F-08` | playlists.html | as designed | MLM/Views/Sidebar/SidebarView.swift |  |
| `F-09` | folders.html | as designed | MLM/Views/Folders/FoldersView.swift |  |
| `F-10` | sync.html | deviates (IMP-045) | MLM/Views/Sync/SyncProfilePage.swift | No Resume When Connected button |
| `F-11` | sync.html | as designed | MLM/Views/Sync/SyncProfileSheets.swift:271 |  |
| `F-12` | review.html | as designed | MLM/Views/Review/ReviewView.swift |  |
| `F-13` | inspector.html | deviates (IMP-044) | MLM/Views/Inspector/InspectorDetailsTab.swift | Tags to files OFF by default |
| `F-14` | discover.html | deviates (IMP-115) | MLM/Views/Similar/SimilarView.swift | Preview on Similar ▸ Online rows is built (IMP-109); no `S-DISC-FIND` sheet (IMP-115) |
| `F-15` | discover.html#reels | deviates (IMP-114) | MLM/Views/Reels/ReelWorkbenchSections.swift | Result Preview built (IMP-109); result drag to a playlist is menu only (IMP-114) |
| `F-16` | settings.html#backup | as designed | MLM/Views/Settings/BackupSettingsView.swift:5 |  |
| `F-17` | launch.html | as designed | MLM/Views/Launch/LibraryPickerView.swift |  |
| `F-18` | patterns-states.html | as designed | MLM/Views/Shell/ContentScaffold.swift:149 |  |
| `F-19` | settings.html | as designed | MLM/Views/Settings/LibrarySetupView.swift:6 |  |
| `F-20` | settings.html#sources | as designed | MLM/Views/Import/SourceSignInView.swift:3 |  |
| `F-21` | genres.html | as designed | MLM/Views/Genres/GenresView.swift |  |
| `F-22` | settings.html#maintenance | as designed | MLM/Views/Settings/MaintenanceView.swift:3 |  |
| `F-23` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistLinkSheet.swift |  |
| `F-24` | albums.html | deviates (IMP-082) | MLM/Services/Albums/AlbumSuggesting.swift | No online lookup (§5 Q2) |
| `G-LIB-RESOLVING` | launch.html | as designed | MLM/Services/Library/LibraryLaunchCoordinator.swift:158 |  |
| `G-LIB-LOADING` | launch.html | as designed | MLM/Views/Launch/LibraryLoadingView.swift:7 |  |
| `G-LIB-FAILED` | launch.html | as designed | MLM/Views/Launch/LibraryLaunchFailureView.swift:9 |  |
| `G-LIB-NONE` | launch.html | as designed | MLM/Views/Launch/LibraryPickerView.swift:8 |  |
| `G-LIB-NOTFOUND` | launch.html | as designed | MLM/Views/Sidebar/LibraryFooter.swift:120, MLM/Services/Library/LibraryPickerRows.swift |  |
| `G-LIB-MISMATCH` | launch.html | as designed | MLM/Services/Library/LibraryPickerRows.swift:24 |  |
| `G-LIB-INVALID` | launch.html | as designed | MLM/Services/Library/LibraryLaunchCoordinator.swift:24 |  |
| `G-LIB-COPY` | launch.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:125 |  |
| `G-LIB-ADOPT-PENDING` | launch.html | as designed | MLM/Services/Library/LibraryPickerRows.swift:44 |  |
| `G-LIB-ADOPT-INTERRUPTED` | launch.html | as designed | MLM/Services/Library/LibraryOpenPhase.swift:55 |  |
| `G-LIB-LEGACY` | launch.html | as designed | MLM/Services/Library/LibraryPickerRows.swift:11 |  |
| `G-LIB-SWITCH-PENDING` | launch.html | deviates (IMP-041) | MLM/Views/Launch/LibraryFilePresentation.swift:76-80 | Alert always shown; default flips with running work |
| `G-LIB-CURRENT` | shell.html | not done | MLM/Views/Shell/DestinationView.swift:184-196, MLM/Views/Folders/FoldersView.swift:37 | Subtitle `‹Library› · ‹count›` is built for All Tracks, Albums, Genres, All Playlists, a playlist page and Folders (G1/G2, W5-1a; `W5GapShellTests`). Review, Discover, a sync profile and pushed album / genre pages show the library name only: no cheap count source |
| `G-ROOT-NONE` | launch.html | as designed | MLM/Views/Settings/LibrarySetupView.swift:331, MLM/Views/Folders/FoldersView.swift |  |
| `G-DRIVE-OFFLINE` | patterns-states.html | as designed | MLM/Views/Shell/ContentScaffold.swift:149-152 |  |
| `G-DRIVE-BOOT` | patterns-states.html | as designed | MLM/Views/Shell/ContentScaffold.swift:145 |  |
| `G-DEVICE-OFFLINE` | sync.html | as designed | MLM/Services/Sync/SyncProfileState.swift:178 |  |
| `G-SRC-CONNECTED` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift |  |
| `G-SRC-DISCONNECTED` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:63 |  |
| `G-SRC-EXPIRED` | settings.html#sources | as designed | MLM/Services/Sources/SourceAccountStates.swift:50, MLM/Views/TrackList/DownloadFailureReasonText.swift:67 |  |
| `G-SRC-KEYCHAIN` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:107 |  |
| `G-SRC-CREDS-MISSING` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:81 |  |
| `G-SRC-APPLEMUSIC` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:72 |  |
| `G-SRC-QOBUZ-COOKIE` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:344 |  |
| `G-TRK-LOCAL` | library.html | as designed | MLM/Views/TrackList/TrackRowPresentation.swift |  |
| `G-TRK-DOWNLOADING` | library.html | as designed | MLM/Views/TrackList/TrackRowPresentation.swift |  |
| `G-TRK-NOTDOWNLOADED` | library.html | as designed | MLM/Views/TrackList/TrackRowPresentation.swift:59 |  |
| `G-TRK-FAILED` | library.html | as designed | MLM/Views/TrackList/DownloadFailureReasonText.swift:3 |  |
| `G-TRK-MISSING` | library.html | as designed | MLM/Views/Player/LocateFile.swift:6 |  |
| `G-TRK-PLACEHOLDER` | library.html | as designed | MLM/Views/Shared/TrackMetadataPresentation.swift:27 |  |
| `G-TRK-DUPLICATE` | inspector.html | as designed | MLM/Views/Inspector/InspectorFileTab.swift:232 |  |
| `G-PL-LOCAL` | playlists.html | as designed | MLM/Services/Playlists/PlaylistPresentation.swift |  |
| `G-PL-LINKED` | playlists.html | as designed | MLM/Views/Playlists/PlaylistCard.swift:46 |  |
| `G-PL-IMPORTING` | playlists.html#detail | as designed | MLM/Services/Playlists/PlaylistPresentation.swift:25 |  |
| `G-PL-INCOMPLETE` | playlists.html#detail | as designed | MLM/Services/Playlists/PlaylistPresentation.swift:26 |  |
| `G-PL-NOTDOWNLOADED` | playlists.html#detail | as designed | MLM/Services/Playlists/PlaylistPresentation.swift |  |
| `G-PL-SRC-DISCONNECTED` | playlists.html#detail | as designed | MLM/Services/Playlists/PlaylistPresentation.swift | Retired wording replaced by `‹Source› sign-in expired` |
| `G-PL-DRIVE-OFFLINE` | playlists.html | as designed | MLM/Views/Playlists/PlaylistDetailView.swift |  |
| `G-BG-ACTIVE` | activity.html | deviates (IMP-039) | MLM/Views/Activity/ActivityToolbarItem.swift:12-68 | Idle symbol `list.bullet.rectangle` |
| `G-JOB-STATUS` | activity.html | as designed | MLM/Services/Activity/ActivityPresentation.swift |  |
| `G-JOB-SILENT` | activity.html | as designed | MLM/Services/Import/ImportService.swift:202,229,272,293, MLMTests: ImportPhaseWordsTests | Import phases read `Scanning…`, `Reading tags…`, `Adding to the library…`, `Finished` (G36, W5-1a) |
| `G-TOOL-MISSING` | settings.html#sources | as designed | MLM/Views/Settings/SettingsRows.swift:126 |  |
| `G-PLAYBACK-ERROR` | player.html | as designed | MLM/Services/Playback/PlaybackWords.swift:41 |  |
| `G-LIB-NOTCONNECTED` | launch.html | as designed | MLM/Views/Sidebar/LibraryFooter.swift:121 |  |
| `A-ALB-REMOVE` | albums.html#grid | as designed | MLM/App/Commands/TrackCommandActions.swift:202, MLM/Services/Albums/AlbumActions.swift:126 |  |
| `A-LIBFILE-INVALID.N01` | launch.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:7, MLM/Services/Library/LibraryLaunchCoordinator.swift:185 |  |
| `A-LOGS-CLEAR` | activity.html#logs | as designed | MLM/Views/Activity/ActivityLogsView.swift:8, MLM/Views/Activity/ActivityLogsView.swift:92 |  |
| `A-REV-ALBBULK` | review.html#albums | as designed | MLM/ViewModels/ReviewAlbumsModel.swift:128, MLM/Views/Review/ReviewAlbumsView.swift:7 |  |
| `A-REV-APPLYALL` | review.html | as designed | MLM/Views/Review/ReviewView.swift:362, MLM/Services/Review/ReviewPresentation.swift:156 |  |
| `A-SET-CACHECLEAR` | settings.html#maintenance | as designed | MLM/Views/Settings/MaintenanceView.swift:287, MLM/Services/Maintenance/MaintenanceJobs.swift:509 |  |
| `A-SET-COOKIECLEAR` | settings.html#sources | as designed | MLM/Views/Settings/SourcesSetupView.swift:273 |  |
| `CM-ALB-CARD` | albums.html#grid | as designed | MLM/Views/Albums/AlbumMenus.swift:11 | Per-card `.contextMenu` (W4-2) |
| `CM-ALBD-ABSENT` | albums.html#detail | deviates (IMP-076) | MLM/Views/Albums/AlbumDetailView.swift:315 | Only `Use a Track from the Library…` |
| `CM-ALBD-MORE` | albums.html#detail | as designed | MLM/Views/Albums/AlbumMenus.swift:11, MLM/Services/Albums/AlbumActions.swift:4 |  |
| `CM-GENRE-ROW` | genres.html#list | as designed | MLM/Views/Genres/GenresView.swift:6, MLM/Views/Genres/GenreMenu.swift:3 |  |
| `CM-GENRED-MORE` | genres.html#detail | as designed | MLM/Views/Genres/GenreMenu.swift:3, MLM/Views/Genres/GenreMenu.swift:9 |  |
| `CM-OPS-ROW` | activity.html | as designed | MLM/Views/Activity/ActivityWindow.swift:292, MLM/Services/Activity/ActivityCenter.swift:588 |  |
| `CM-QUEUE` | queue.html | deviates (IMP-124) | MLM/Views/TrackList/TrackMenuModel.swift:300-325, MLMTests: W5GapMenuTests | Next rows have `Find Similar` (G8); `Share…` is not in the Queue menus, whose groups are pinned (IMP-124) |
| `CM-QUEUE.N01` | queue.html | as designed | MLM/Views/TrackList/TrackMenuModel.swift:326-330, MLMTests: W5GapMenuTests | History rows have `Find Similar` (G9) |
| `CM-REV-ALBUM` | review.html#albums | as designed | MLM/Views/Review/ReviewAlbumsView.swift:292 |  |
| `CM-REV-GROUP` | review.html | as designed | MLM/Views/Review/ReviewGroupList.swift:170 |  |
| `CM-REV-VERSION` | review.html | as designed | MLM/Views/Review/ReviewComparison.swift:95-100, MLMTests: W5GapMenuTests | Review version rows get `Get Info · Show in All Tracks` only (G10) |
| `CM-SUB-COPY` | patterns-context-menus.html | as designed | MLM/Views/TrackList/TrackMenu.swift:146-152, MLM/App/Commands/TrackCommands.swift:143-148, MLMTests: W5GapCommandsTests | Menu-bar Copy ▸ has `Link` (G29, W5-1b) |
| `CM-SUB-MOVE` | patterns-context-menus.html | as designed | MLM/Database/PlaylistFolderRepository.swift:216, MLM/Views/Playlists/PlaylistActions.swift:436 |  |
| `CM-SUB-PLAYLIST` | patterns-context-menus.html | as designed | MLM/App/Commands/TrackCommands.swift:70, MLM/Views/TrackList/SelectionBar.swift:297 |  |
| `CM-SUB-SYNC` | patterns-context-menus.html | as designed | MLM/App/Commands/TrackCommandActions.swift:86 |  |
| `ICON-MLIBM` | library-icon.html | as designed | MLM/Views/Launch/LibraryFileIcon.swift:5 |  |
| `M-APP.E07/alert` | patterns-menus-shortcuts.html | as designed | MLM/Views/Launch/LibraryFilePresentation.swift:30-53, MLM/App/QuitGuard.swift | `Quit MLM?` / `Quit` / `Cancel` |
| `M-TRACK` | patterns-menus-shortcuts.html | as designed | MLM/App/Commands/TrackCommands.swift:143-149, MLMTests: W5GapCommandsTests | Copy ▸ Link (G29) and `Share…` (G31, IMP-124) built |
| `P-ACTIVITY/B` | activity.html | removed by design | — | Variant B dropped (§10 Q2) |
| `P-ADDMENU` | shell.html | deviates (IMP-111) | MLM/Views/Shell/ShellToolbar.swift:97-134 | Window menus carry no key equivalents; the glyphs of UC-TB-05 name the File-menu keys, which own them |
| `P-LIBFOOTER` | shell.html | as designed | MLM/App/LibraryCommands.swift:6, MLM/Views/Sidebar/LibraryFooter.swift:4 |  |
| `P-LIBFOOTER.N01` | shell.html | as designed | MLM/Views/Sidebar/LibraryFooter.swift:20 |  |
| `P-PREVIEW` | player.html | deviates (IMP-119) | MLM/Services/Playback/PreviewMachine.swift:3, MLM/Services/Playback/StreamPreview.swift | Online preview built (`PreviewCandidate.stream`, SoundCloud / YouTube resolver); the stream is fetched to one temporary file and played, so it starts after the fetch, not at the first bytes |
| `P-QUEUE` | queue.html | as designed | MLM/ViewModels/PlaybackViewModel.swift:951, MLM/Views/Shell/TrailingColumnView.swift:10 |  |
| `P-QUEUE.N15` | queue.html | as designed | MLM/Views/Queue/QueueEditCommands.swift:124, MLM/Views/Queue/QueuePanelModel.swift:180 |  |
| `P-SIDEBAR.E03/add` | playlists.html | as designed | MLM/Views/Sidebar/SidebarView.swift:65 |  |
| `P-SIDEBAR.N03/menu` | playlists.html | deviates (IMP-042) | MLM/Views/Playlists/PlaylistActions.swift:465-482 | `Delete Folder` without `…` (acts at once, undoable) |
| `S-ALB-EDIT` | albums.html#detail | as designed | MLM/Views/Albums/AlbumInfoSheet.swift:5, MLM/Services/Albums/AlbumInfoEdit.swift:4 |  |
| `S-ALB-MERGE` | albums.html#detail | as designed | MLM/Views/Albums/AlbumMergeSheet.swift:3, MLM/Services/Albums/AlbumMerge.swift:4 |  |
| `S-DISC-FIND` | discover.html | deviates (IMP-115) | MLM/Views/Discover/DiscoverView.swift:105,131-138 | No sheet: `Find Recommendations` runs at once with the selected recommendation's seed else the playing track, both sources (SoundCloud, Last.fm) |
| `S-IMPORT` | import.html | as designed | MLM/ViewModels/QuickAddModel.swift:27, MLM/ViewModels/ImportSheetsPresenter.swift:5 |  |
| `S-LAUNCH-RESTORE` | launch.html | as designed | MLM/ViewModels/LaunchRestoreModel.swift:5, MLM/Views/Launch/LibraryLaunchFailureView.swift:132 |  |
| `S-PLFOLDER-NEW` | playlists.html | as designed | MLM/Views/Sidebar/SidebarView.swift:480 |  |
| `S-QUICKADD` | import.html#quickadd | as designed | MLM/ViewModels/QuickAddModel.swift:4, MLM/ViewModels/ImportSheetsPresenter.swift:5 |  |
| `S-REELS-LINK` | discover.html#reels | as designed | MLM/Views/Reels/ReelLinkSheet.swift:4, MLM/Services/Reels/ReelLinkFetcher.swift:3 |  |
| `S-SET-LIBFOLDER` | settings.html#library | as designed | MLM/ViewModels/ImportViewModel.swift:103, MLM/ViewModels/ImportViewModel.swift:106 |  |
| `S-SET-RENAMELIB` | settings.html#library | deviates (IMP-044) | MLM/Views/Settings/LibrarySetupView.swift:419-461 | `Rename and Relaunch` |
| `S-SYNC-DESTINATION` | sync.html | as designed | MLM/ViewModels/SyncViewModel.swift:501, MLM/Views/Sync/SyncProfileMenu.swift:21 |  |
| `ST-ADVANCED` | settings.html#advanced | deviates (IMP-044) | MLM/Views/Settings/AdvancedSettingsView.swift:4-8 | `Show Tips Again` row built (G15, IMP-123); no log-level row |
| `ST-BACKUP.N04` | settings.html#backup | as designed | MLM/Views/Settings/BackupSettingsView.swift:292 |  |
| `ST-GENERAL` | settings.html#general | as designed | MLM/Views/Settings/GeneralSettingsView.swift:21-54 | No Space-bar setting (§10 Q1) |
| `V-ALB` | albums.html#grid | as designed | MLM/Views/Albums/AlbumsView.swift, MLM/Views/Albums/AlbumCard.swift | Grid keyboard not verifiable (W4-2) |
| `V-ALBD` | albums.html#detail | deviates (IMP-076) | MLM/Views/Albums/AlbumDetailView.swift:45 | Gaps `Track ‹n›` without Find (§5 Q2) |
| `V-FOLD.N02/menu` | folders.html | as designed | MLM/Views/Folders/FolderMenus.swift:4, MLM/Views/Folders/FolderMenus.swift:209 |  |
| `V-GENRED` | genres.html#detail | deviates (IMP-046) | MLM/Views/Genres/GenreDetailView.swift:3 |  |
| `V-GENRES` | genres.html#list | as designed | MLM/Views/Genres/GenresView.swift:3, MLM/Views/Genres/GenresView.swift:234 |  |
| `V-GENRES.N02` | genres.html#list | as designed | MLM/Views/Genres/GenreMenu.swift:3 |  |
| `V-INBOX.N07` | discover.html#recs | as designed | MLM/Views/TrackList/TrackMenuModel.swift:262-280 |  |
| `V-PICKER` | launch.html | as designed | MLM/Views/Launch/LibraryPickerView.swift:4 |  |
| `V-PICKER.N14` | launch.html | deviates (IMP-041) | MLM/Views/Launch/LibraryPickerView.swift:107 | `Rename…` not in the row menu (Settings ▸ Library) |
| `V-PLD.E02/menu` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistActions.swift:9 |  |
| `V-PLD.N01/menu` | playlists.html#detail | as designed | MLM/Views/Playlists/PlaylistActions.swift:9 |  |
| `V-REELS.N09` | discover.html#reels | as designed | MLM/Views/Reels/ReelsView.swift:137, MLM/Views/Reels/ReelsView.swift:194 |  |
| `V-SETUP` | launch.html | deviates (IMP-041) | MLM/Views/Launch/LibrarySetupFlowView.swift:3 |  |
| `V-SIMILAR` | discover.html#similar | as designed | MLM/ViewModels/SimilarModel.swift:4, MLM/ViewModels/SimilarModel.swift:6 |  |
| `V-SIMILAR.N08` | discover.html#similar | as designed | MLM/Views/Similar/SimilarView.swift:287-300, MLMTests: SimilarModelTests | Online row menu: `Preview` (IMP-109) · `Download` · `Keep` · `Keep and Add to Playlist ▸` (G21, W5-1b) |
| `V-SYNC-DETAIL.N10` | sync.html | as designed | MLM/Views/Sync/SyncProfileMenu.swift:31 |  |
| `V-TRACK-TABLE.N01` | library.html | deviates (IMP-112) | MLM/Views/TrackList/TrackListTable.swift:21-55 | System header menu lists the columns; no `Auto Size All Columns` |
| `W-ACTIVITY` | activity.html | deviates (IMP-039) | MLM/Views/Activity/ActivityWindow.swift:3 | History 200 / 30 days |

## Flows F-01 … F-24 (walkable in code?)

| Flow | Walkable | Missing step |
|---|---|---|
| F-01 first launch | yes — picker → V-SETUP steps 1–3 (`LibrarySetupFlowView`) | — |
| F-02 adopt old install | yes — `LibraryAdoptionSheet`, interrupted-journal phase | — |
| F-03 browse → Space → play → queue | yes in code | Space on a focused `Table` unverified (W2-C note); fallback Track ▸ Preview |
| F-04 search | yes — filter in place, scopes, tokens, Albums section in Library scope | Online rows have no Preview |
| F-05 import playlist + download | yes — S-IMPORT 3 steps, header echo, Activity | — |
| F-06 track from URL | yes — ⌘U / suggestion row → S-QUICKADD; reel links go to Discover ▸ Reels (IMP-110) | — |
| F-07 fix failed downloads | yes — `Download failed` scope, reasons, Retry All, Activity group | — |
| F-08 create + fill playlist | yes — ⌘N inline, drops, selection bar, ⇧⌘N | — |
| F-09 folders | yes — outline, path bar, import, scan, folder → Queue (IMP-107) | — |
| F-10 sync + failures | yes — plan, Sync Now (also for playlist-only changes, IMP-105), Last sync, Retry Failed, Eject, profile reorder | no `Resume When Connected` button (IMP-045: resumes by itself) |
| F-11 device ingest | yes — `Read Playlist Changes from Device…` sheet, undoable | — |
| F-12 review | yes — duplicates, conflicts, albums, resolved with Decision column, bulk alert | — |
| F-13 edit in Info | yes — multi-edit, Mixed, undo | files written only if `Write tags to files` is enabled (IMP-044, §5 Q6) |
| F-14 discover | yes — Find Recommendations, Keep/Dismiss, Similar, Preview on online rows | no `S-DISC-FIND` sheet (IMP-115) |
| F-15 reels | yes — import, identify, search, Preview, download | result drag to a playlist is menu only (IMP-114) |
| F-16 backup/restore | yes — schedule, keep, restore alert, failed-restore alert | — |
| F-17 switch/create/open library | yes — picker, switch alert, New Library, `.mlibm` drop | `Clear Menu` pending (IMP-041) |
| F-18 drive unplugged | yes — banner, dimming, waits, `“‹V›” connected.` + Resume | — |
| F-19 settings changes | yes — folder-change sheet, Sources in place, cache move | — |
| F-20 sign-in expired | yes — one account model, Reconnect in place | — |
| F-21 genres + Create ML | yes — V-GENRES/V-GENRED, merge sheet, export sheet | — |
| F-22 analysis batch | yes — Maintenance rows as operations, Clear Waiting… | — |
| F-23 link source / M3U | yes — S-PLD-LINK, S-PLD-M3U-PREVIEW into the open playlist | Spotify links refused (IMP-042) |
| F-24 albums | yes — grid, detail, edit order, sheets, Review ▸ Albums | no online tracklist / lookup (IMP-076/082, §5 Q2) |

## §11.1 problems 1–20

| # | State | Where / why |
|---|---|---|
| 1 Space preview, playback keys | fixed | `TrackListPreviewKeys.swift:69`, `MenuCatalog.swift:285-291` (W2-C); Space on a `Table` needs the launch check |
| 2 queue stalls | fixed | `Services/Playback/QueueAdvance.swift` (IMP-033) |
| 3 drive state | fixed | `ContentScaffold.swift:149` banner, `TrackRowPresentation`, `LibraryAvailabilityMonitor` (W2-A) |
| 4 double-click only / ⌘I dead | fixed | `TrackPrimaryAction.swift`, ⌘I `MenuCatalog.swift:241` |
| 5 dead commands | fixed | catalog `.pending` only for `Clear Menu` (IMP-041); `Share…` and `Show Tips Again` wired, `MLM Help` removed (IMP-116) |
| 6 lossy download feedback | fixed | `DownloadFailureReasonText.swift`, Activity results (IMP-029/039) |
| 7 failed downloads blind | fixed | All Tracks scope bar + second line (UC-TABLE-13) |
| 8 sync hides skips | fixed | per-profile results v47, plan Skip (W3-SYNC) |
| 9 sign-in state | fixed | `Services/Auth/SourceAccounts.swift` (W3-SET) |
| 10 review decisions | fixed | v48/v54, `ReviewDecisionRepository` (IMP-051/057) |
| 11 data-risk paths | fixed | Info commit keyed to selection; no delete in Similar; ingest merges (IMP-048) |
| 12 source-as-album writes | fixed | PP-MAIN-04 (W2-I), C3 cleanup (IMP-085/099/102) |
| 13 invisible background work | fixed | every job is an operation (W3-ACT); import phase words plain (G36, `ImportPhaseWordsTests`) |
| 14 open library invisible | fixed, partly | footer + title; subtitle count in six places (see `G-LIB-CURRENT`) |
| 15 shortcut conflicts | fixed | `MenuCatalog` one key per item; no key monitors; ⌥↑ / ⌥↓ added with IMP-117 |
| 16 backups | fixed | `BackupSchedule` / `BackupRetention`, guarded restore (W3-SET) |
| 17 edits never reach files | deferred | tag writing exists but OFF by default (IMP-044, §5 Q6) |
| 18 language drift | fixed | UI German gone; log sources `Recommendations` / `Similarity` / `Analysis` and messages without banned words (G38, W5-1b); source-grep test `Source conventions (UC-§22)` (W5-4) |
| 19 dead-end failures | fixed | `LibraryLaunchFailureView.swift` (Try Again, Restore, Show Logs, Details); deep links `SettingsTab` |
| 20 M3U target | fixed | `PlaylistM3UImportSheet.swift:93-97`, PP-PLAYLISTS-01 |

## Menu bar, Dock, TipKit

- **`.pending` in `MenuCatalog`:** only `clearRecentLibraries` (File ▸ Open Recent ▸ Clear Menu, owner W3-LAUNCH — kept by IMP-041). Everything else is `.app` or `.system`. `MenuBarStructureTests` no longer allows the owner `W5-2`.
- **Order vs UC-MENU-05:** matches, plus IMP-074/098 additions in Library ▸ Maintenance. Track ▸ Copy ▸ has `Link` (G29); Track ▸ `Share…` is built with `ShareLink` (IMP-124); Help has Keyboard Shortcuts and `Show Tips Again`, no `MLM Help` (IMP-116, UC-MENU-05 / UC-KEY-27 updated); View ▸ Columns has no `Auto Size All Columns` (IMP-112, UC-TABLE-03 updated).
- **Dock menu:** header `‹Title› — ‹Artist›` / `Not playing`, Play/Pause, Next, Previous, Open Recent without the open library (G30, UC-DOCK-01).
- **TipKit:** `Tips.configure()` at launch; three tips in an ordered `TipGroup` (`Press Space to preview`, `Drag tracks onto a playlist`, `Edit several tracks at once`) as `.popoverTip`, hidden while a sheet or alert is open or a preview plays (`MLM/Services/Tips/MLMTips.swift`); Help ▸ Show Tips Again and Settings ▸ Advanced reset them (IMP-123: the reset also takes effect at the next launch). Needs the launch check above.

## Accessibility

- **Reduce Motion:** the now-playing glyph in `TrackCell` is gated on `accessibilityReduceMotion` (G4/G5); Queue, player, Activity item, selection bar and the `TrackCoverView` fade honour it (W5-1a / W5-1b, tests `W5GapShellTests`, `NowPlayingSyncTests`).
- **Reduce Transparency:** honoured in the only glass surface (`SelectionBar.swift`). OK.
- **VoiceOver labels:** toolbar, player, sidebar ＋, Activity item labelled; sync picker rows expose their selected state and a label (G16/G17, `W5GapPagesTests`); a sweep of icon-only buttons found none unlabelled and `IconButtonLabelTests` guards it. The Suggested-tracks disclosure in `GenreSuggestionsSection.swift` is a plain button with no expanded state (not changed).
- **Keyboard-only:** playlist rows reorder with ⌥↑ / ⌥↓ in Manual order (IMP-117, UC-KEY-32); sync profiles reorder by drag only; grid arrow keys / type-select in Albums and All Playlists need the launch check.
- **Announcements:** status bar, drive banner, selection bar and refused drops post `AccessibilityNotification.Announcement` (UC-A11Y-05). OK.
- **Fixed sizes:** `.font(.system(size:))` and `mlm*` tokens removed from `LibrarySetupFlowView` (G39, W5-1b) and the theme files (W5-4); the one exception is the fallback glyph of `TrackCoverView` (listed above).
