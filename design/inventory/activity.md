# Activity panel, Operations, Logs & background work

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): ACT, OPS, LOGS, BG · Files covered: `MLM/Views/Activity/ActivityPanel.swift`, `ActivityFeed.swift`, `ActivityFeedAdapters.swift`, `OperationsTab.swift`, `LogsTab.swift`, `LogFeed.swift`, `LogTextRenderer.swift`, `MLM/ViewModels/ActivityViewModel.swift`, `MLM/Services/Download/*` (user-visible decisions only: job states, retry, errors, notifications)

How to read this area: the Activity panel is the app's only global place for background work. It is a strip at the bottom of the main window that expands upward into two tabs. **Operations** combines four separate inputs that don't share a model:
(a) jobs registered with `ActivityViewModel`: folder import / rescan, device sync, transcode-cache relocation, CreateML export,
(b) the live download batch from `DownloadViewModel`,
(c) the live sync state from `SyncViewModel`,
(d) the analysis "priority queue" from `PerformanceQueueService`.

It adds a fifth input, download failures saved to the database. **Logs** is a live view of the in-memory app log. Most other background work in the app never reaches this panel (see index §10).

## Surfaces

### P-ACTIVITY — Activity
- Reached via: always present at the bottom edge of W-MAIN once a library is open (`MLM/Views/ContentView/ContentView.swift:273-279`). It spans the full window width, under the sidebar, the content and P-INSPECTOR. You open it only by clicking its header bar; no menu item or shortcut opens it. K-ACT-ESC only collapses it. · Leads to: P-ACTIVITY-OPS, P-ACTIVITY-LOGS, A-OPS-CLEARQUEUE
- Code: `MLM/Views/Activity/ActivityPanel.swift:1-239` (view), `MLM/Views/Activity/ActivityFeed.swift:128-304` (headline/summary aggregation), `MLM/ViewModels/ActivityViewModel.swift:1-356` (operation store)
- Purpose: Let the user see what MLM is doing in the background right now, and reach the details (jobs, failures, logs) without leaving the current screen.
- User goals:
  1. Glance: "is anything running / did my download or sync finish?" without opening anything. Daily, while importing or downloading. Evidence: UI-GROUNDTRUTH §4.2 rule 5 "the user can always answer 'what is the app doing right now and why' from the Activity header alone".
  2. Open the details to watch progress, cancel or retry. Weekly.
  3. Open Logs to diagnose a failure. Weekly to rare.
  4. Get the panel out of the way while browsing or listening (collapse, resize). Daily.
- What the user wants to see, in priority order:
  1. Whether anything is running, and what kind of work it is (download, sync, import, analysis), with a count ("12 of 44").
  2. Whether something **needs attention**: failures waiting for Retry *(today never shown in the header, see pain points)*.
  3. The current item (track or file).
  4. A way in to details and logs.
- Elements today:
  - P-ACTIVITY.E01 Header bar. The whole 36 pt row is a plain button; clicking anywhere toggles expanded/collapsed with a 0.2 s ease animation, or instantly with Reduce Motion (`MLM/Views/Activity/ActivityPanel.swift:57-83,182-193`). It has no hover state.
  - P-ACTIVITY.E02 Disclosure chevron, 9 pt bold, muted. `chevron.right` when collapsed, `chevron.down` when expanded. It sits at the leading edge (`MLM/Views/Activity/ActivityPanel.swift:62-66`).
  - P-ACTIVITY.E03 Title `Activity` (section-label font) (`MLM/Views/Activity/ActivityPanel.swift:68-70`).
  - P-ACTIVITY.E04 Busy spinner: a mini indeterminate `ProgressView`, shown only while at least one row is "active" (`MLM/Views/Activity/ActivityPanel.swift:92-96`).
  - P-ACTIVITY.E05 Summary text, trailing, one line, truncated in the middle. Its tooltip repeats the full text (`MLM/Views/Activity/ActivityPanel.swift:98-104`). Content comes from the headline algorithm (`MLM/Views/Activity/ActivityFeed.swift:261-304`):
    - Nothing active: `No active operations` (muted).
    - Otherwise these segments, joined with ` · `, in this order: download, sync, other registered jobs, analysis queue.
      - Download segment = the title of the download batch row, which is **the current track's "Artist - Title"**, or `Downloading…` before the first track (`MLM/Views/Activity/ActivityFeed.swift:465-467`).
      - Sync segment = the registered op title `Sync: ‹profile name›` (`MLM/Services/Sync/SyncService.swift:745-750`).
      - Other segments = op titles verbatim, e.g. `Rescan library`, `Import: ‹folder›` (`MLM/ViewModels/ImportViewModel.swift:108-122`), `Cache migration: ‹folder›` (`MLM/App/DependencyContainer.swift:437-442`), `CreateML Export: ‹folder›` (`MLM/Views/TrackDetail/GrooveStudioView.swift:2011-2015`).
      - Analysis segment = `Analyzing: Artist - Title`, `Downloading: Artist - Title`, `Preparing sync preview` (`MLM/Services/Common/PerformanceQueueService.swift:296-306`), or `‹n› analyses pending` (`MLM/Views/Activity/ActivityFeed.swift:562`).
    - The header snapshot is built with `sync: nil` and `persistedFailures: []` (`MLM/Views/Activity/ActivityPanel.swift:132-142`). So the header **never shows failures** and never shows the SyncViewModel row.
  - P-ACTIVITY.E06 Resize handle: a 4 pt strip between the header and the content, shown only when expanded. Dragging changes the height, clamped to 150–700 pt. Hovering shows the up/down resize cursor (`MLM/Views/Activity/ActivityPanel.swift:209-239`).
  - P-ACTIVITY.E07 Tab picker: segmented `Operations` | `Logs`, with the Picker label `Tab` (`MLM/Views/Activity/ActivityPanel.swift:152-160`). The selected tab is remembered (`@AppStorage("activity.selectedTab")`, default `Operations`, `MLM/Views/Activity/ActivityPanel.swift:13`).
  - P-ACTIVITY.E08 Content area at the persisted height (`@AppStorage("activity.panel.height")`, default 284) (`MLM/Views/Activity/ActivityPanel.swift:12,147-178`). It hosts P-ACTIVITY-OPS or P-ACTIVITY-LOGS.
  - P-ACTIVITY.E09 Invisible zero-size button bound to Escape that collapses the panel (K-ACT-ESC, `MLM/Views/Activity/ActivityPanel.swift:44-52`).
- Interactions:
  - Click: header toggles the panel.
  - Drag: E06 resizes.
  - Keyboard: K-ACT-ESC collapses.
  - Hover: tooltip on the summary text.
  - None of: double-click, right-click (no context menu), drag & drop, multi-select.
  - Expanded/collapsed state persists across launches (`@AppStorage("activity.panel.expanded")`, default collapsed, `MLM/Views/Activity/ActivityPanel.swift:11`).
- States:
  - Default (collapsed, idle): `Activity` … `No active operations`.
  - In-progress background work: spinner plus summary segments.
  - Failures pending: **not represented** in the header.
  - Library loading, launch screens, init error: the panel is **not shown at all**. It lives only in `initializedView` (`MLM/Views/ContentView/ContentView.swift:63-120,224-280`).
  - Drive not connected: nothing specific; downloads simply fail (see P-ACTIVITY-OPS).
  - Huge data: n/a. The summary is one string.
- Data scale / performance: the snapshot is rebuilt on every body evaluation (`MLM/Views/Activity/ActivityPanel.swift:107-143`). Cheap for a handful of ops.
- Pain points today:
  - The header hides failures (`MLM/Views/Activity/ActivityPanel.swift:132-142`). This contradicts UI-GROUNDTRUTH §4.2 rule 5.
  - The header shows a bare track name, with no "Downloading" and no "n of m" (`MLM/Views/Activity/ActivityFeed.swift:279,465-467`). UI-GROUNDTRUTH §2.5 mock expects `Downloading 12/44`.
  - The header has no hover affordance. UI-GROUNDTRUTH §2.5 rule 1 says "today it doesn't look interactive"; still true (`MLM/Views/Activity/ActivityPanel.swift:81`).
  - Unclear whether the `Tab` label of the segmented picker renders ("Unresolved from code").
  - The drag base height is initialised to 284, not the persisted height. If the app launches already expanded at a different height, the first drag can jump (`MLM/Views/Activity/ActivityPanel.swift:18,190-192,223`). Inferred.
  - There's no menu or keyboard route to open the panel or jump to Logs.
- Related flows: import-remote-playlist, fix-failed-downloads, sync-device, drive-unplugged, settings-changes, diagnose-problem (area flow, "Flow notes").
- Constraints / locked decisions: native macOS look only (system colours/materials); the native toolbar stays; no floating panels; critical states always as text; English only; glossary word **Activity** = "The background work panel" (UI-GROUNDTRUTH §1.5); size 36 pt collapsed, 150–700 pt expanded, default 284 (UI-GROUNDTRUTH line 105).
- Open questions for the designer:
  - Should the collapsed bar carry a persistent "needs attention" signal (e.g. "9 downloads failed") even when nothing is running?
  - Which of the 4–5 concurrent kinds of work earns a place in a one-line summary, and what drops first when the window is narrow?
  - Should the panel be reachable from the menu bar (View) and by shortcut, including "open straight to Logs"?
  - Should the panel exist on launch / error screens, so logs are reachable when a library can't open?
  - Should it span under the inspector, or only under the content column?

### P-ACTIVITY-OPS — Operations
- Reached via: P-ACTIVITY.E07 `Operations` segment (the default tab). · Leads to: A-OPS-CLEARQUEUE. It has no navigation out: rows don't link to tracks, playlists or sync profiles.
- Code:
  - View: `MLM/Views/Activity/OperationsTab.swift:1-535`.
  - Aggregation (pure): `MLM/Views/Activity/ActivityFeed.swift:1-632`.
  - Adapters: `MLM/Views/Activity/ActivityFeedAdapters.swift:1-70`.
  - Operation store: `MLM/ViewModels/ActivityViewModel.swift:1-356`.
  - Download driver: `MLM/ViewModels/DownloadViewModel.swift:66-708`.
- Purpose: Show every running background job with progress and Cancel, keep failed downloads visible with Retry, and keep a short list of recently finished jobs.
- User goals:
  1. Watch a playlist import/download batch progress, and see which tracks are done or failed. Daily during collecting. Evidence: UI-GROUNDTRUTH Part 6 item 1, "44-track YouTube import shows live progress … failed track listed with reason and Retry … still visible after restart".
  2. Retry downloads that failed, possibly days later. Weekly. Evidence: `MLM/Views/Activity/OperationsTab.swift:433-483`, UI-GROUNDTRUTH §2.5 rule 3.
  3. Cancel a long job (sync, import, download batch). Weekly.
  4. Pause/resume a device sync. Weekly. Evidence: `MLM/Views/Activity/ActivityFeed.swift:514-518`.
  5. Clear the pending analysis backlog. Rare. Evidence: `MLM/Views/Activity/OperationsTab.swift:28-37`.
  6. Check that a sync / import / rescan finished and with what summary. Weekly.
- What the user wants to see, in priority order:
  1. Running jobs: kind, what's happening now, determinate "n of m", time left *(inferred)*.
  2. Failures: which track, a plain reason, when, attempts, Retry (UI-GROUNDTRUTH §5.3 `n attempts left`).
  3. Finished jobs with an outcome summary (`n synced · m failed`, `n imported, m skipped`).
  4. Why something is waiting (analysis paused while downloads run, UI-GROUNDTRUTH §2.5 rule 4).
- Elements today:
  - P-ACTIVITY-OPS.E01 Empty state, shown when no section has rows (`MLM/Views/Activity/OperationsTab.swift:44-46,361-374`):
    - icon `checkmark.circle`
    - `No active operations`
    - `Downloads, imports, and sync jobs appear here`
  - P-ACTIVITY-OPS.E02 Section header `Active` (muted, section-label font). Holds running rows, in this order (`MLM/Views/Activity/ActivityFeed.swift:144-171,200-208`):
    1. registered ops, oldest first
    2. the download batch row
    3. the sync batch row
    4. the analysis queue row
  - P-ACTIVITY-OPS.E03 Section header `Needs Attention`, in the attention colour (`MLM/Views/Activity/OperationsTab.swift:117-119`, `MLM/Views/Activity/ActivityFeed.swift:210-218`). Holds:
    - terminal ops still in the active list. Effectively never happens, because every terminal transition moves the op to Recent (`MLM/ViewModels/ActivityViewModel.swift:239,256,280`).
    - persisted download failures, newest first, de-duplicated (`MLM/Views/Activity/ActivityFeed.swift:175-188`).
  - P-ACTIVITY-OPS.E04 Section header `Recent`, with a trailing `Clear` button (plain, muted). Clear empties Recent immediately, with no confirmation (`MLM/Views/Activity/OperationsTab.swift:140-153`, `MLM/ViewModels/ActivityViewModel.swift:325-330`). When more than 20 have finished, the header also shows `Capped at 20` (`MLM/Views/Activity/OperationsTab.swift:129-135`, `MLM/ViewModels/ActivityViewModel.swift:103,350-355`). Recent is newest first.
  - P-ACTIVITY-OPS.E05 Row anatomy, the same for all rows (`MLM/Views/Activity/OperationsTab.swift:157-232`):
    - an icon zone, or a disclosure button (E13) when the row has children
    - title (body font, 1 line)
    - optional detail line (muted, 1 line)
    - a right zone that shows **one of**: progress bar + text (E15), status badge (E16), or duration (E17). Precedence is progress > badge > duration.
    - action buttons (E18–E21)
    - hover tints the background
    - a divider between rows.
  - Type icons (`MLM/Views/Activity/OperationsTab.swift:378-388`):

    | Type | Icon |
    |---|---|
    | Download | `arrow.down.circle` |
    | Sync | `arrow.triangle.2.circlepath` |
    | Import | `square.and.arrow.down` |
    | Analysis | `waveform` |
    | Fingerprint | `hand.point.up.braille` |
    | Artwork | `photo` |
    | CreateML Export | `brain` |

  - Icon tint by status (`MLM/Views/Activity/OperationsTab.swift:390-398`): running = accent, completed = green, failed = red, cancelled = orange, stalled = attention.
  - P-ACTIVITY-OPS.E06 **Registered-operation row (running)** (`MLM/Views/Activity/ActivityFeed.swift:320-353`):
    - title: the op title; detail: the op detail.
    - progress bar + `NN%`.
    - `Cancel` only if the op registered a cancellation token.
    - Producers today:

      | Job | Title | Detail | Cancel token | Code |
      |---|---|---|---|---|
      | Folder import / rescan | `Rescan library` or `Import: ‹folder›` | `Scanning ‹folder›…`, then the current file or phase | yes | `MLM/ViewModels/ImportViewModel.swift:95-123,139-227` |
      | Device sync | `Sync: ‹profile›` | `0 / ‹total›`, then `‹n› / ‹total› — ‹file›` | **no** | `MLM/Services/Sync/SyncService.swift:476-501,743-750` |
      | Transcode-cache relocation | `Cache migration: ‹folder›` | `Scanning existing cache...`, then `[n/total] moved...` | **no**; type is `.sync` | `MLM/App/DependencyContainer.swift:423-505` |
      | CreateML export | `CreateML Export: ‹folder›` | `Starting export of N tracks...`, then `[n/total] tracks exported...` | **no** | `MLM/Views/TrackDetail/GrooveStudioView.swift:2011-2015,2130` |

    - The `Fingerprint` and `Artwork` types exist, but nothing registers them (`MLM/ViewModels/ActivityViewModel.swift:58-66`; grep finds only the four producers above).
  - P-ACTIVITY-OPS.E07 **Download batch row**, present while `DownloadViewModel.isDownloading` (`MLM/Views/Activity/ActivityFeed.swift:159-161,450-502`, `MLM/Views/Activity/ActivityFeedAdapters.swift:9-31`):
    - title = the current track `Artist - Title`, or `Downloading…`.
    - detail = counter `‹n› / ‹total›`, where n = completed + 1 (`MLM/Views/Activity/ActivityFeed.swift:308-316`).
    - progress bar once progress > 0, plus the same `n / total` text in place of a percentage.
    - The row has no Cancel action of its own, so the tab appends a direct `Cancel` that calls `DownloadViewModel.cancel()`. That stops the batch **after the current track** (`MLM/Views/Activity/OperationsTab.swift:277-298`, `MLM/ViewModels/DownloadViewModel.swift:592-599`, `MLM/Services/Download/DownloadOrchestrator.swift:370-378`).
    - Has a child list (E13/E14).
  - P-ACTIVITY-OPS.E08 **Sync batch row** from `SyncViewModel`, present while `isSyncing` (`MLM/Views/Activity/OperationsTab.swift:64-66`, `MLM/Views/Activity/ActivityFeed.swift:163-166,504-549`, `MLM/Views/Activity/ActivityFeedAdapters.swift:46-60`):
    - title = the current file, or `Syncing…`; detail = `n / total`.
    - progress + `n / total`.
    - badge `Paused` when paused, but it's hidden whenever progress > 0 (E05 precedence).
    - button `Pause` / `Resume` (`MLM/Views/Activity/OperationsTab.swift:336-340`), plus a direct `Cancel` that calls `cancelSync()` (`MLM/Views/Activity/OperationsTab.swift:281-283,300-306`).
    - **This row appears in addition to the E06 `Sync: ‹profile›` row**, so one sync renders as two rows (pain points).
  - P-ACTIVITY-OPS.E09 **Analysis queue row**, present when there are pending analyses or downloads, or an active job (`MLM/Views/Activity/ActivityFeed.swift:168-171,551-583,612-614`):
    - title = the queue's active-job text (`Analyzing: Artist - Title` / `Downloading: Artist - Title` / `Preparing sync preview`) or `‹n› analyses pending`.
    - detail = `‹n› items pending` (analyses + queued downloads).
    - no progress, badge or duration.
    - button `Clear` opens A-OPS-CLEARQUEUE (`MLM/Views/Activity/OperationsTab.swift:342-347`).
    - It has no Cancel for the running item, and no text saying it is suspended while downloads or sync previews run (`MLM/Services/Common/PerformanceQueueService.swift:468-476`).
  - P-ACTIVITY-OPS.E10 Failed or cancelled op in Needs Attention: badge `Failed` / `Cancelled`, `Retry` if retryable (`MLM/Views/Activity/ActivityFeed.swift:355-399`). Practically unreachable today (see E03).
  - P-ACTIVITY-OPS.E11 **Persisted download failure row** (`MLM/Views/Activity/ActivityFeed.swift:585-608`, `MLM/Views/Activity/OperationsTab.swift:433-504`):
    - title `‹Artist› – ‹Title›`; detail = the stored reason.
    - badge `Failed`.
    - button `Retry`, which calls `retryAllFailed(trackIds: [id])` (`MLM/Views/Activity/OperationsTab.swift:327-334`).
    - Source 1: tracks with `organized_path IS NULL` and a `download_failure` record, or a legacy `download_status` of `failed`/`error` (`MLM/Database/TrackRepository.swift:93-104`). For the legacy ones the reason is `Download failed`.
    - Source 2: items in the legacy retry file `.retry_queue.json` (`MLM/Views/Activity/OperationsTab.swift:457-472`, `MLM/Services/Download/DownloadQueue.swift:45-48`).
    - Reloaded when the tab appears and on every `.downloadDidComplete` (`MLM/Views/Activity/OperationsTab.swift:20-27`).
    - The attempt count and the date are loaded, but not displayed (pain points).
  - P-ACTIVITY-OPS.E12 **Recent row**: completed / failed / cancelled registered ops, at most 20 (`MLM/Views/Activity/ActivityFeed.swift:401-448`).
    - Completed: green icon plus duration `m:ss` (or `h:mm:ss`), measured from start to *now*, so it keeps growing (`MLM/Views/Activity/ActivityFeed.swift:440,616-623`).
    - Failed: badge `Failed`, detail = the error text, `Retry` if a retry handler exists. Today that's sync (`MLM/Services/Sync/SyncService.swift:749`) and cache migration (`MLM/App/DependencyContainer.swift:441`).
    - Cancelled: badge `Cancelled`.
    - Clicking `Retry` first removes the row, then runs the handler (`MLM/ViewModels/ActivityViewModel.swift:285-322`).
  - P-ACTIVITY-OPS.E13 Download disclosure button. `chevron.right.circle.fill` / `chevron.down.circle.fill` replaces the type icon when the row has children. Clicking expands an inline list of **only the first 5** batch items, with no "more" indicator (`MLM/Views/Activity/OperationsTab.swift:163-172,223-228`). Only one row can be expanded at a time.
  - P-ACTIVITY-OPS.E14 Child item (`MLM/Views/Activity/OperationsTab.swift:234-269`, `MLM/Views/Activity/ActivityFeedAdapters.swift:20-28,33-43`):
    - a small dot.
    - `‹Artist› – ‹Title›`, truncated in the middle.
    - an optional red error line (e.g. `download cancelled`, `downloaded but not saved to library`, or the failure reason; `MLM/ViewModels/DownloadViewModel.swift:535-559`).
    - a status capsule showing the **raw lowercase enum**: `queued`, `downloading`, `transcoding`, `completed`, `failed`, `skipped` or `cancelled` (`MLM/Models/AppModels.swift:14-22`). `transcoding` is never assigned anywhere.
  - P-ACTIVITY-OPS.E15 Progress bar, 80 pt (`ProgressView(value:)`), plus mono text 48 pt wide (`NN%` or `n / total`) (`MLM/Views/Activity/OperationsTab.swift:197-206`).
  - P-ACTIVITY-OPS.E16 Status badge capsule (`MLM/Views/Activity/OperationsTab.swift:207-208,400-419`). Verbatim words: `Failed` (red), `Cancelled` (orange), `Stalled` (attention), `Paused` (muted). `Stalled` means a running op with no progress for more than 120 s (`MLM/ViewModels/ActivityViewModel.swift:105-106,341-346`), but it can't show, because these rows always have a progress value.
  - P-ACTIVITY-OPS.E17 Duration text (mono) for rows without progress or badge (`MLM/Views/Activity/OperationsTab.swift:209-213`). Relative times like `just now` / `5m ago` / `2h ago` / `3d ago` are computed (`MLM/Views/Activity/ActivityFeed.swift:625-631`) but **never rendered**.
  - P-ACTIVITY-OPS.E18 `Cancel` buttons, bordered (`MLM/Views/Activity/OperationsTab.swift:292-316`). Three variants:
    - op token: `ActivityViewModel.cancelOperation`, which runs the token and moves the row to Recent as `Cancelled`.
    - direct download cancel.
    - direct sync cancel. Added to **any** `.sync` row without a token, including the cache-migration row, where it calls `SyncViewModel.cancelSync()` and has no effect on the migration.
  - P-ACTIVITY-OPS.E19 `Retry` button, bordered (`MLM/Views/Activity/OperationsTab.swift:318-334`). Either the op retry handler or `DownloadViewModel.retryAllFailed(trackIds:)`. The download retry silently does nothing while a batch runs (`MLM/ViewModels/DownloadViewModel.swift:630-632`). It always uses the `.auto` source chain (`MLM/ViewModels/DownloadViewModel.swift:647`).
  - P-ACTIVITY-OPS.E20 `Pause` / `Resume` button, bordered, sync rows only (`MLM/Views/Activity/OperationsTab.swift:336-340`, `MLM/ViewModels/SyncViewModel.swift:541-548`).
  - P-ACTIVITY-OPS.E21 `Clear` button, bordered, on the analysis queue row. Opens A-OPS-CLEARQUEUE (`MLM/Views/Activity/OperationsTab.swift:342-347`).
- Status vocabulary actually shown (verbatim):
  - section titles `Active`, `Needs Attention`, `Recent`
  - badges `Failed`, `Cancelled`, `Stalled` *(never visible)*, `Paused` *(usually hidden)*
  - child capsules (lowercase) `queued`, `downloading`, `completed`, `failed`, `skipped`, `cancelled`
  - `Running`, `Completed` and `Queued` never appear as text. They exist only as icon tint or the section. UI-GROUNDTRUTH §1.6 requires `Queued` · `Running` · `Paused` · `Completed` · `Failed` · `Cancelled`.
- Download failure reasons that can appear in E11 detail / E14 error (verbatim, from `MLM/Services/Download/`):
  - Bounded set (`MLM/Services/Download/DownloadOrchestrator.swift:69-82`): `Video unavailable` (also used for "all sources exhausted" and for any unrecognised thrown error, `MLM/Services/Download/DownloadOrchestrator.swift:125-129`), `Video unavailable in your region`, `Private video`, `yt-dlp not installed — open Settings`, `Network error`.
  - Chain messages (`MLM/Services/Download/DownloadOrchestrator.swift:771,778,803,837,908,944,1003,1013,1112,1158,1164`): `No SoundCloud URL — cannot download (pinned to SoundCloud)`, `scdl not installed — install via \`pip install scdl\``, `Download cancelled`, `DAB requires a captcha cookie — try another source`, `Squid requires a captcha cookie — set MLM_SQUID_CAPTCHA from browser dev-tools`, `Track not found on any source`, `Download failed — reason unknown`, `DAB authentication failed`, `DAB returned an invalid download link — trying another source`.
  - Classifier (`MLM/Services/Download/DownloadFailureClassifier.swift:221,233,354,425-450,519-551`): `‹Source› rejected the request (HTTP 403) — the downloader tool is probably outdated`, `‹Source› returned HTTP 403 — the client ID or credentials may be expired`, `‹Source› did not find the track — trying next source`, `Authentication expired — re-authorize and retry`, `Content has been removed from ‹Source›`, `Rate limited by ‹Source› — retry after a short wait`, `‹Source› server error — retry later`, `DRM-protected on ‹Source› — this source cannot provide the track`, `Not available in your region on ‹Source›`, `Downloads are disabled for this track on ‹Source›`, `Downloader tool is not installed`, `Timed out contacting ‹Source›`, `Network unreachable — check your connection`, `Downloaded media is corrupt — quarantined for inspection`, `Downloader finished without producing a file`.
  - Timeouts: `SoundCloud download timed out — retry later` (`MLM/Services/Download/SoundCloudDownloader.swift:173,234`), `YouTube download timed out — the connection may be slow or YouTube is not responding` (`MLM/Services/Download/YouTubeDownloader.swift:232`).
  - Batch rejection: `Another download batch is already running.` (`MLM/Services/Download/DownloadOrchestrator.swift:384-401`).
  - Save failures: `downloaded but not saved to library` / `Downloaded file could not be saved to library` (`MLM/ViewModels/DownloadViewModel.swift:541-543`, `MLM/Services/Download/DownloadOrchestrator.swift:590-597`).
- Interactions:
  - Click: buttons only, plus the disclosure on the download row.
  - Hover: background tint on rows.
  - None of: double-click, right-click (no context menu), selection, keyboard navigation of rows, drag & drop.
- States:
  - Default (idle, nothing recent): E01 empty state.
  - Loading: no indicator. Persisted failures load asynchronously, and errors only go to Logs (`MLM/Views/Activity/OperationsTab.swift:477-482`).
  - In-progress: E02 with rows.
  - Error / failures: E03 and E11 rows.
  - Filtered-empty: n/a (no filters).
  - Drive not connected: download batches fail. The staging directory can't be created, and every track gets `failureReason(for:)`, typically `Video unavailable` (`MLM/Services/Download/DownloadOrchestrator.swift:411-437`). No "drive" wording.
  - Huge data: Needs Attention is an uncapped, non-lazy `VStack` of every failed track (`MLM/Views/Activity/OperationsTab.swift:48-53`, `MLM/Database/TrackRepository.swift:93-104`).
  - After relaunch: Recent is empty (in memory only, `MLM/ViewModels/ActivityViewModel.swift:99-103`). Persisted download failures reappear (DB + `.retry_queue.json`). The analysis queue is gone (in memory, `MLM/Services/Common/PerformanceQueueService.swift:29-60`).
- Data scale / performance: 12,935 tracks, and `organized_path IS NULL` remote tracks are common (ROADMAP §0–§1). The number of failed downloads isn't known from code, and the Needs Attention list has no cap, grouping or search. The snapshot is rebuilt per render, including the persisted-failure mapping.
- Pain points today: see §11 register (rows tagged OPS). The main ones:
  - sync rows never end after Cancel;
  - one sync shows as two rows;
  - Cancel on cache migration is a no-op;
  - download batch outcomes vanish when the batch ends;
  - misleading `Video unavailable`;
  - silent rejection of a second download;
  - timestamps and attempt counts never shown.
- Related flows: import-remote-playlist, fix-failed-downloads, sync-device, drive-unplugged, settings-changes, first-launch.
- Constraints / locked decisions: job status vocabulary (UI-GROUNDTRUTH §1.6); errors = plain cause + one action, technical detail in Logs (§1.7 rule 4); "Download failed" is the glossary term (§1.5); critical states as text, never icon-only.
- Open questions for the designer:
  - Group by status (today: Active / Needs Attention / Recent) or by kind (UI-GROUNDTRUTH §2.5: Downloads / Sync / Analysis / Recent)?
  - How should a 44-item batch show per-track state? Today it's the first 5 only.
  - How should hundreds of persisted failures be presented: grouped by playlist, by reason, with "Retry all" and "Dismiss"?
  - What should a failure row link to: the track in Library, the playlist, the sync profile?
  - Should finished downloads leave a Recent entry with an outcome summary ("35 downloaded · 9 failed")?
  - How do you communicate "waiting / suspended because downloads run" for the analysis queue?
  - Which jobs should offer Pause, given that only sync supports it today?
  - What should Cancel look like for work that can only stop "after the current track"?

### P-ACTIVITY-LOGS — Logs
- Reached via: P-ACTIVITY.E07 `Logs` segment. · Leads to: Finder (reveals `mlm.log`).
- Code: `MLM/Views/Activity/LogsTab.swift:1-454` (view + `SelectableLogView`), `MLM/Views/Activity/LogFeed.swift:1-185` (filtering), `MLM/Views/Activity/LogTextRenderer.swift:1-181` (rendering), `MLM/Utilities/AppLogger.swift:1-245` (source data).
- Purpose: A live, filterable stream of what the app logged, for finding out *why* something failed.
- User goals:
  1. After a failed download or sync, find the raw cause (provider error, ffmpeg exit code). Weekly. Evidence: "Keep raw provider/process messages in the Logs tab" (`MLM/Services/Download/DownloadOrchestrator.swift:57-59`); UI-GROUNDTRUTH §1.7 rule 4.
  2. Filter to errors or warnings, or to one subsystem (Download, Sync, Import, Backup…). Weekly.
  3. Copy log text to share with an agent or into a bug report. Weekly *(inferred: selectable text view, "user explicitly wants cross-row text selection for copy-paste", `.planning/activity-redesign.md` §9.4)*.
  4. Open the full log file on disk. Rare.
- What the user wants to see, in priority order:
  1. Errors and warnings related to the thing that just failed.
  2. Time, level and source per line.
  3. Search.
  4. The full history beyond the buffer (the file).
- Elements today:
  - P-ACTIVITY-LOGS.E01 Toolbar row, 32 pt (`MLM/Views/Activity/LogsTab.swift:74-96`).
  - P-ACTIVITY-LOGS.E02 Level filter menu (borderless). The label is `‹Level› (‹count›)` plus a chevron. Items, with a checkmark on the current one: `All (n)`, `Info+ (n)`, `Warn+ (n)`, `Errors (n)`, `Debug (n)` (`MLM/Views/Activity/LogsTab.swift:100-128`, `MLM/Views/Activity/LogFeed.swift:5-34`). `Info+` counts info+warn+error; `Debug` is debug only (`MLM/Views/Activity/LogFeed.swift:160-172`).
  - P-ACTIVITY-LOGS.E03 Source filter menu. The label is a `tag` icon plus the current source plus a chevron. Items: `All sources`, a divider, every source in the buffer (sorted case-insensitively, casing variants merged), a divider, `(no source)` (`MLM/Views/Activity/LogsTab.swift:132-192`, `MLM/Views/Activity/LogFeed.swift:114-151`). Typical sources come from code: `Download`, `Sync`, `Import`, `Activity`, `Backup`, `CreateML`, `CreateML Export`, `PerformanceQueue`, `Analysis`.
  - P-ACTIVITY-LOGS.E04 Search field with a magnifier and placeholder `Search logs...` (`MLM/Views/Activity/LogsTab.swift:196-221`):
    - `xmark.circle.fill` clear button when non-empty.
    - 250 ms debounce (`MLM/Views/Activity/LogsTab.swift:45-52`).
    - case-insensitive substring match on message or source (`MLM/Views/Activity/LogFeed.swift:86-109`).
  - P-ACTIVITY-LOGS.E05 Pause toggle, icon only: `pause.fill` / `play.fill`, tooltip `Pause` / `Resume`. While paused, the view freezes and new entries are held back until resume (`MLM/Views/Activity/LogsTab.swift:225-235,352-370`).
  - P-ACTIVITY-LOGS.E06 Autoscroll toggle, icon `arrow.down.to.line`, accent tint when on. Tooltip `Autoscroll on` / `Autoscroll off`. Scrolls to the end only when already within 20 pt of the bottom (`MLM/Views/Activity/LogsTab.swift:237-248,432-444`).
  - P-ACTIVITY-LOGS.E07 Wrap toggle, icon `text.alignleft` (off) / `text.wordwrap` (on). Tooltip `Wrap off` / `Wrap on` (`MLM/Views/Activity/LogsTab.swift:250-261`).
  - P-ACTIVITY-LOGS.E08 `Clear` (plain, muted). Empties the in-memory buffer immediately, with no confirmation. The file on disk is kept (`MLM/Views/Activity/LogsTab.swift:265-272`, `MLM/Utilities/AppLogger.swift:232-240`).
  - P-ACTIVITY-LOGS.E09 Reveal button, icon `doc.text.magnifyingglass`. The tooltip is the **full file path** of the log. Selects the file in Finder (`MLM/Views/Activity/LogsTab.swift:274-284`). The file is `~/Library/Logs/MLM/mlm.log`, rotated at 5 MB with 3 backups (`MLM/Utilities/AppLogger.swift:5-11,58-67`).
  - P-ACTIVITY-LOGS.E10 Log text view: read-only, selectable `NSTextView` with a vertical scroller (`MLM/Views/Activity/LogsTab.swift:309-344`). Each line is 4 tab-stopped columns (`MLM/Views/Activity/LogTextRenderer.swift:6-14,138-180`):
    - time `HH:mm:ss.SSS` (secondary colour)
    - level `INFO` / `WARN` / `ERROR` / `DEBUG`, 9 pt bold, coloured blue / orange / red / grey
    - source in accent colour, truncated to 12 characters + `…` and padded
    - message.
    - Wrap off clips long lines, with no horizontal scroller (`MLM/Views/Activity/LogsTab.swift:338-343`).
  - P-ACTIVITY-LOGS.E11 Empty state (`MLM/Views/Activity/LogsTab.swift:288-304`):
    - icon `text.alignleft`
    - `No log entries` (no filter) or `No entries match the filter`
    - `Application events stream here in real time`.
- Interactions:
  - Click: toolbar controls.
  - Text: select, ⌘A / ⌘C and the standard text context menu (CM-LOGS-TEXT); K-LOGS-COPY.
  - Hover: tooltips on the icon toggles and on Reveal.
  - Drag: of selected text, system default (D-LOGS-TEXTDRAG).
  - There are no per-line actions, no filtering from a clicked line, and no copy-all or export button.
- States:
  - Default: live stream.
  - Empty: E11.
  - Filtered-empty: E11 variant.
  - Paused: frozen. Only the icon swap indicates it, with no "paused" text.
  - Library not open / init error: tab unreachable (panel not shown).
  - Huge data: buffer capped at 5,000 entries (`MLM/Utilities/AppLogger.swift:58-60,192-195`). A filter change rebuilds the whole text, and new entries are appended incrementally (`MLM/Views/Activity/LogTextRenderer.swift:114-134`). **Once the buffer is full, the entry count stops changing, and the view's only refresh trigger is that count** (`MLM/Views/Activity/LogsTab.swift:44,57-70`). So new lines likely stop appearing until a filter changes *(inferred, "Unresolved from code")*.
- Data scale / performance: 5,000-entry ring buffer; counts recomputed per query or count change.
- Pain points today:
  - It probably freezes at 5,000 entries.
  - Filter, search, pause, wrap and autoscroll states are `@State`. They reset whenever the user switches to Operations or collapses the panel (`MLM/Views/Activity/LogsTab.swift:7-18`).
  - Three different `Clear` buttons in one panel (Recent, queue, logs) mean three different things.
  - Icon-only toggles whose state is shown only by tint.
  - No export or "copy visible lines".
  - Logs are unreachable exactly when the library fails to open (`MLM/Views/ContentView/ContentView.swift:95-120,478-490`).
  - The UI-GROUNDTRUTH §2.5 rule 5 claim of German strings (`"Quellen:"`, `"Logs durchsuchen…"`) is out of date; the code is English.
- Related flows: diagnose-problem, fix-failed-downloads, sync-device, drive-unplugged.
- Constraints / locked decisions: English only; native controls; the text view must keep cross-row selection (`.planning/activity-redesign.md` §9.4 rejected a table for this reason).
- Open questions for the designer:
  - Should a failure row in Operations deep-link into Logs pre-filtered (source + time)?
  - Is a "copy diagnostic bundle / export" action needed for sharing with agents?
  - How should paused, autoscroll and wrap state read as text, not tint only?
  - Should log filters persist like the panel's tab and height do?
  - Should Logs be reachable from launch and error screens and the menu bar?

## Context menus

### CM-LOGS-TEXT — standard text menu in the log view
- Appears in: P-ACTIVITY-LOGS.E10 · Code: `MLM/Views/Activity/LogsTab.swift:318-330` (plain `NSTextView`, not editable, selectable; no custom `menu`).
- Items: the AppKit default for a read-only selectable `NSTextView`, not customised in code. Exact items are system-defined (typically Copy, Look Up, Share, Services, Speech…). MLM adds nothing.
- Consequence: copy or look up the selected text only.

No other context menus exist in this area. Operations rows, section headers and the Activity header have **no** right-click menu (`MLM/Views/Activity/OperationsTab.swift:157-232`, `MLM/Views/Activity/ActivityPanel.swift:57-83`). Expected, missing *(inferred)*: on a failure row, items such as "Retry", "Show in Library", "Show in Playlist", "Copy error", "Show log lines"; on a running job, "Cancel", "Pause".

## Sheets, popovers, panels, alerts

### A-OPS-CLEARQUEUE — Clear Pending Jobs
- Trigger: `Clear` on the analysis queue row (P-ACTIVITY-OPS.E21) · Code: `MLM/Views/Activity/OperationsTab.swift:28-37,342-347`
- Title: `Clear Pending Jobs`
- Message: `Clear ‹n› pending jobs? This cannot be undone.` (n = pending analyses + pending queued downloads, read live)
- Buttons: `Keep` (cancel) · `Clear` (destructive)
- Consequences:
  - `Clear` calls `PerformanceQueueService.shared.clearQueue()`. It drops all **pending** analysis and queued-download jobs. The running job continues (`MLM/Services/Common/PerformanceQueueService.swift:137-141,220`).
  - Dropped download jobs (e.g. from Reels) leave their tracks remote, with no failure record *(inferred)*.
  - Escape / `Keep`: nothing happens.
  - Errors: none surfaced.
- Note: UI-008 ("modeled but cannot be invoked") is **fixed in the current code**. The row button is wired (§11 register).

### Pull-down menus (part of P-ACTIVITY-LOGS, listed for completeness)
- Level menu P-ACTIVITY-LOGS.E02 and Source menu P-ACTIVITY-LOGS.E03. Items are verbatim above (`MLM/Views/Activity/LogsTab.swift:100-192`).

### External
- Reveal opens a Finder window with `mlm.log` selected (`MLM/Views/Activity/LogsTab.swift:274-284`). There is no sheet.
- Notifications posted from this area's code: `.downloadDidComplete` (`MLM/ViewModels/DownloadViewModel.swift:571-578,804-811`), `.libraryDidImport` (`MLM/ViewModels/ImportViewModel.swift:187-194`), `.qobuzCookieStatusDidChange` (`MLM/Services/Download/SquidWtfClient.swift:66-74`, consumed by ST-SRC cookie status label `MLM/Views/Settings/SourcesSetupView.swift:42-56,82-84`). None open UI by themselves; there are no system notifications and no toasts for background work (index §10).

## Menu items & keyboard shortcuts (area-local)

### K-ACT-ESC — Escape collapses the Activity panel
- Key: `Esc` (no modifiers) · Label: none (an invisible, zero-size button) · Scope: anywhere in W-MAIN's initialized view, whenever the panel is expanded · Action: collapse, with animation unless Reduce Motion · Code: `MLM/Views/Activity/ActivityPanel.swift:44-52,195-204`
- Conflicts: possibly competes with Escape in other main-window controls (search field dismiss, table selection, `.cancelAction` buttons inside views such as `MLM/Views/Playlists/PlaylistsView.swift:332`). Precedence was not determinable statically ("Unresolved from code"). There's no shortcut to *expand* the panel.

### K-LOGS-COPY — Select all / Copy in the log view
- Keys: `⌘A`, `⌘C` (standard `NSTextView` responder behaviour) · Scope: the log text view has focus · Code: `MLM/Views/Activity/LogsTab.swift:318-330` · Not customised.

### Missing (documented wishes, not implemented)
- `⌘L` focuses the log search (`.planning/activity-redesign.md` §8.4). Not found in code.
- No menu-bar item for Activity, Operations or Logs. Grep for `Activity` in `MLM/App/` finds only view-model wiring.
- Related shortcut owned elsewhere: `⌘R` Re-scan Library (`MLM/Views/Library/LibraryView.swift:117-129`, owner library.md) starts an Activity `Rescan library` op.

## Drag & drop

- P-ACTIVITY.E06 resize is a drag gesture, but it isn't drag & drop (no payload). See P-ACTIVITY interactions.

### D-LOGS-TEXTDRAG — drag selected log text out
- Source → target: selected text in P-ACTIVITY-LOGS.E10 → any text drop target · Payload: plain/attributed text (AppKit `NSTextView` default) · Code: `MLM/Views/Activity/LogsTab.swift:318-330` (no custom drag code; system behaviour, *inferred*) · Feedback: system drag image.

### Expected, missing
- Drag a failed-download row (or a child item) onto a playlist, into the Library, or to Finder. No payload exists; rows aren't draggable (`MLM/Views/Activity/OperationsTab.swift:157-232`). Evidence: "daily-driver loop" multi-select and bulk actions direction (MEMORY project_daily_driver_loop); analogous to Music.app downloads.
- Drop a SoundCloud/YouTube URL onto the Activity panel to start a download. No drop target exists. Downloads start only from views (index §10). Evidence: analogous to download managers; weak.

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Drive not connected:**
  - The download batch can't create its staging folder `.mlm-download-tmp` inside the library root. The whole batch fails, each track with a generic reason (usually `Video unavailable`) and an entry in the retry queue (`MLM/Services/Download/DownloadOrchestrator.swift:411-437,125-129`). The Activity panel says nothing about the drive.
  - Sync, import and cache relocation fail with `error.localizedDescription` as the Recent row detail (`MLM/Services/Sync/SyncService.swift:914-932`, `MLM/ViewModels/ImportViewModel.swift:196-213`, `MLM/App/DependencyContainer.swift:497-502`).
  - The retry-queue file itself lives on the library drive (`MLM/Services/Download/DownloadOrchestrator.swift:296,336`; LOGIC-028).
- **Library loading / failed / no library:** P-ACTIVITY is absent. The loading view `Loading Library...`, the error view `Failed to Initialize` and the launch screens have no panel and no Logs (`MLM/Views/ContentView/ContentView.swift:63-120,478-506`).
- **Source disconnected / expired:**
  - Shows up only as per-track failure text (`Authentication expired — re-authorize and retry`, `DAB requires a captcha cookie — try another source`, `Squid requires a captcha cookie — set MLM_SQUID_CAPTCHA from browser dev-tools`).
  - Squid cookie expiry flips `squid.captcha_cookie_expired` and posts `.qobuzCookieStatusDidChange`. Only ST-SRC reacts, with the label `Expired — renew` (`MLM/Services/Download/SquidWtfClient.swift:66-74,328-337`; `MLM/Views/Settings/SourcesSetupView.swift:42-56`). Activity has no source-health signal.
- **Background processing:** P-ACTIVITY header (E04/E05) and P-ACTIVITY-OPS.E02. Only four registered producers, the download batch, the sync driver and the analysis queue are visible (index §10).
- **Track availability:**
  - `Download failed` tracks appear as E11 rows, and also as legacy `download_status` `failed`/`error`.
  - `Downloading…` appears only as the batch row and its children.
  - `Not downloaded` and `File missing` aren't represented here.
  - Successful downloads leave no trace in Activity after the batch ends.

### Background work touchpoints

| Work | Appears in Activity as | Progress | Result / error | User control | Survives relaunch |
|---|---|---|---|---|---|
| Download batch (playlist/track/universal search) | E07 live row + E14 children | n/total + bar (`MLM/ViewModels/DownloadViewModel.swift:258-283`) | Row disappears at end. Failures persist as E11. Successes are not recorded | `Cancel` (after the current track) | Failures yes (DB + `.retry_queue.json`); nothing else |
| Recommendation (discovery) download | Reuses the E07 row (stale totals and children from the last batch, `MLM/ViewModels/DownloadViewModel.swift:710-720`) | Single-track % | Inline in Similar (GrooveView); errors to Logs only | `Cancel` button shown but the discovery loop doesn't check it (`MLM/ViewModels/DownloadViewModel.swift:693-817`) *(inferred)* | No |
| Queued downloads (Reels → PerformanceQueue) | E09 `Downloading: Artist - Title` | none | If a batch is active, `downloadTracks` returns silently (`MLM/ViewModels/DownloadViewModel.swift:194-197`, `MLM/Services/Common/PerformanceQueueService.swift:336-342`) | `Clear` pending | No (in memory) |
| Folder import / rescan | E06 `Rescan library` / `Import: ‹folder›` | % + current file | Recent `‹n› imported, ‹m› skipped`. Failures only as `errorMessage` in the originating view | `Cancel` (token; save-phase caveat LOGIC-023) | Recent no |
| Sync | E06 `Sync: ‹profile›` **and** E08 | % + n/total | Recent `‹n› synced · ‹m› failed`, or `Failed` with Retry | `Pause`/`Resume`, 2× `Cancel` | No |
| Transcode-cache relocation | E06 `Cache migration: ‹folder›` (type sync) | % `[n/total] moved...` | Recent `Moved ‹n› cache files.` / Failed with Retry | `Cancel` shown but ineffective | No (half-moved state possible) |
| CreateML export | E06 `CreateML Export: ‹folder›` | % | Recent completed `‹n› tracks exported`; user cancel appears as `Failed` / `Cancelled by user` | none in Activity (cancel in Groove Studio sheet) | No |
| Auto analysis (ReplayGain/fingerprint/embeddings after import/download) | E09 | none (counts only) | Errors to Logs only | `Clear` pending | No |

### Flow notes

- **import-remote-playlist**
  1. The user starts a download from W-REMOTE / V-PLD (other agents). Intent: get 44 tracks.
  2. P-ACTIVITY header shows a spinner plus the current track name. Intent: "how far along?" **Breaks:** there's no n/m in the header, only the track name.
  3. Expand → P-ACTIVITY-OPS.E07 shows `n / 44` and the bar. The disclosure shows only the first 5 tracks, and earlier ones still read `downloading` until the batch ends (`MLM/ViewModels/DownloadViewModel.swift:261-270`).
  4. The batch ends: the row vanishes. Failures appear in `Needs Attention` with reason and `Retry`. Successes leave no trace. **Breaks:** no "35 downloaded · 9 failed" summary in Activity (the summary exists only in the remote-import sheet). If the batch was rejected because another was running, the sheet shows the *previous* batch's numbers (`MLM/ViewModels/RemotePlaylistsViewModel.swift:127-138`).
- **fix-failed-downloads**
  1. Expand the panel. Intent: "what failed and why?"
  2. `Needs Attention` lists every failed track, flat and uncapped, with no date, no attempt count and no playlist context.
  3. `Retry` per row. **Breaks:**
     - There's no Retry all.
     - Retry is a silent no-op while any batch runs (`MLM/ViewModels/DownloadViewModel.swift:630-632`).
     - Retry uses the auto chain even for YouTube/SoundCloud-pinned tracks (`MLM/ViewModels/DownloadViewModel.swift:647` vs `604-627,942-951`).
     - There's no way to dismiss a permanent failure (DRM, removed).
  4. Reasons can be misleading (`Video unavailable` for a SoundCloud/DAB track or a transcode/disk error) or not actionable (`yt-dlp not installed — open Settings`, while Settings has no yt-dlp control; `set MLM_SQUID_CAPTCHA from browser dev-tools`).
  5. The user goes to Logs to understand. Filters reset every time the tab is left.
- **sync-device**
  1. Start a sync in V-SYNC-DETAIL (other agent). The sidebar shows a spinner (`MLM/Views/Sidebar/SidebarView.swift:145-147`).
  2. P-ACTIVITY header: `Sync: ‹profile›`. Operations shows **two** rows for one sync, with two Cancel buttons and one Pause.
  3. Cancel → SyncService terminalises via `cancelOperation`, which ignores non-cancellable ops (`MLM/ViewModels/ActivityViewModel.swift:263-267`). **Breaks:** the `Sync: ‹profile›` row stays in `Active` at its last % for the rest of the session. The `Stalled` mitigation isn't visible either (E16).
  4. A failed sync → Recent `Failed` + `Retry`, which reruns `SyncService.executeSync` directly, bypassing SyncViewModel. So there's no sidebar spinner, no detail-view progress and no Pause row *(inferred)*.
- **drive-unplugged**
  - With the library drive missing, starting downloads fails every track with a generic reason. Activity never says "library drive not connected".
  - If the library can't open at all, the Activity panel and Logs aren't available.
- **settings-changes**
  - Changing the transcode cache folder (ST-MAINT `Change…`, `MLM/Views/Settings/MaintenanceView.swift:78-81,869`) starts `Cache migration: ‹folder›` in Activity. Its `Cancel` does nothing (LOGIC-013 variant).
  - Settings → Library `Import Folder` / Re-scan now registers an Activity op and has its own Cancel (`MLM/Views/Settings/LibrarySetupView.swift:199-225`). UI-006 is resolved in code.
- **first-launch**
  - The first-run wizard import (`MLM/Views/Shared/FirstRunWizard.swift:191-215,328-331`) also registers an Activity op. But the panel sits behind the wizard's dimmed overlay (`MLM/Views/ContentView/ContentView.swift:63-80`).
- **diagnose-problem** (area flow)
  1. Something fails.
  2. Expand → Logs.
  3. Set `Errors` and source `Download`.
  4. Search a track name.
  5. Select lines → ⌘C, or Reveal the file.
  - **Breaks:** the view likely stops updating at 5,000 buffered entries. Filters reset. There's no export. Logs are unreachable on startup failure.

### Unresolved from code

- **Escape precedence:** whether the invisible Escape button (`MLM/Views/Activity/ActivityPanel.swift:44-52`) fires before or instead of Escape handling in focused text fields, tables or inline `.cancelAction` buttons in W-MAIN. This depends on AppKit key-equivalent routing at runtime.
- **Segmented picker label:** whether the label `Tab` of the segmented `Picker` (`MLM/Views/Activity/ActivityPanel.swift:152`) is visibly rendered on macOS 15/27 outside a `Form`. There's no `.labelsHidden()`.
- **Logs freeze at 5,000:** the inference follows from `.onChange(of: logger.entries.count)` being the only entry-driven trigger (`MLM/Views/Activity/LogsTab.swift:44`). SwiftUI may still re-run `updateNSView` on other observation changes, so this needs a Mac check.
- **Stall refresh:** there's no timer, so whether `Stalled` ever re-evaluates without another state change depends on SwiftUI re-render frequency.
- **Counter width:** whether `n / total` in the 48 pt mono slot (`MLM/Views/Activity/OperationsTab.swift:201-206`) truncates for 3-digit totals.
- **Drive-unplugged message:** the exact text when the library drive is unplugged. It depends on the Foundation error string that `failureReason(for:)` sees (`MLM/Services/Download/DownloadOrchestrator.swift:411-437`); could be `Video unavailable` or `Network error`.
- **Reels queue downloads:** whether queued Reels downloads (`MLM/Services/Common/PerformanceQueueService.swift:336-342`) are retried later after a silent rejection. Nothing in code re-queues them.
- **Discovery Cancel:** whether `Cancel` affects discovery downloads. `orchestrator.downloadDiscoveryTrack` wasn't traced for `cancelRequested`.
- **Failure-row volume:** how many persisted failures exist in Oliver's library (live data is off-limits). This decides whether Needs Attention is 5 rows or 500.

