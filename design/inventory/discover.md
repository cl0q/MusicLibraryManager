# Discover — Recommendations & Reels

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): DISC, REELS, INBOX · Files covered: `MLM/Views/Discover/DiscoverView.swift`, `MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift`, `MLM/Views/ReelsInbox/ReelsInboxView.swift`, `MLM/Services/Analysis/SwarmRecommendationService.swift`, `MLM/Services/Analysis/DiscoveryReviewService.swift` (+ the code they call that shapes what the user sees: `DownloadViewModel.downloadDiscoveryTrack`, `TrackRepository` discovery-log queries, `UnifiedSearchService`, `ReelRepository`, `ReelDeletionController`, sidebar badge)

**Orientation for the designer (what this area is, in plain words).**
Discover is one sidebar destination (`Discover`, ⌘7, group `WORK`) with two segments:

- **Recommendations** — an *inbox of tracks that were already downloaded because the user asked for them* from a track's Similar sheet. It is **not** a feed: MLM never produces recommendations on its own or in the background. The user opens a track → Inspector `Similar` tab → `Show all` → Similar sheet; its right half lists "Recommendations" fetched live from **SoundCloud ("related tracks")** or **Last.fm ("similar tracks")** for that one seed track. Clicking `Download` there fetches the audio file into the library folder (`Discovered Neighbors/<Seed artist> - <Seed title>/`) and adds it to the library **immediately**; at that moment it also lands in Discover → Recommendations with status "new". The inbox's job is the verdict: keep (`Add to library`) or throw away (`Delete…`, file to Trash). Keeping silently also feeds a "taste" signal that nudges future similarity ranking for that seed.
- **Reels** — a tool to *identify the song playing in a short video* (the copy says "Instagram Reel") that the user saved as `.mp4`/`.mov`. The user imports videos (folder picker or drag & drop), picks one, MLM tries to name the song from the file name, from the audio (Shazam), and from on-screen text (OCR on 10 still frames). With an artist/title in hand it searches four download sources at once (DABmusic, Qobuz, SoundCloud, YouTube, 3 hits each), and the user can preview a hit, queue a download, or add it (undownloaded) to a playlist. Nothing in Reels touches the video file itself.

---

## Surfaces

### V-DISC — Discover
- Reached via: sidebar row `Discover` (sparkles icon) in the `WORK` group (P-SIDEBAR) · menu `Navigate ▸ Discover` ⌘7 (M-NAVIGATE, K-DISC-NAV) · empty-state hint in nothing else (no deep links into Discover exist)  ·  Leads to: V-INBOX, V-REELS
- Code: `MLM/Views/Discover/DiscoverView.swift:5-50` (view), `MLM/Views/ContentView/ContentView.swift:379-380,556,597,611,626` (routing/label/icon/shortcut), `MLM/Views/Sidebar/SidebarView.swift:46-48,62-75,178-186,264-272` (sidebar row + pending badge)
- Purpose: one place for "new music coming in" — downloaded recommendations awaiting a verdict, and identifying songs from saved videos.
- User goals:
  1. See at a glance whether recommendations are waiting (sidebar badge) — weekly *(inferred: recommendations only arrive after manual downloads in the Similar sheet)*.
  2. Switch between reviewing recommendations and identifying reel music — weekly.
- What the user wants to see, in priority order:
  1. How many recommendations wait for a verdict (today: only in the sidebar badge and inside V-INBOX's header, not on the segment).
  2. Which of the two jobs they are in.
  3. For Reels: how many videos are still unidentified *(inferred — no such count exists)*.
- Elements today:
  - V-DISC.E01 — page title `Discover` (`MLM/Views/Discover/DiscoverView.swift:18-20`).
  - V-DISC.E02 — segmented control (accessibility label `Discover content`, label hidden) with segments `Recommendations` · `Reels`, fixed 260 pt wide, right-aligned in the title row (`MLM/Views/Discover/DiscoverView.swift:24-35`). No count on either segment.
  - V-DISC.E03 — content area: V-INBOX or V-REELS (`MLM/Views/Discover/DiscoverView.swift:42-47`).
  - V-DISC.E04 (in P-SIDEBAR, owned by main.md) — pending badge next to `Discover`: plain number `N`, muted colour, tooltip `N recommendations pending`; hidden when 0 (`MLM/Views/Sidebar/SidebarView.swift:178-186`). Recomputed on appear, on `libraryDidImport` and on `downloadDidComplete` by running the full inbox query and counting (`MLM/Views/Sidebar/SidebarView.swift:62-75,264-272`).
- Interactions: click segment; ⌘7 from anywhere. No keyboard shortcut to switch segments. No toolbar items contributed.
- States:
  - default: always opens on `Recommendations`. The selected segment is view-local `@State` (`MLM/Views/Discover/DiscoverView.swift:13`) and resets each time the user leaves Discover and comes back (ContentView rebuilds the view per section, `MLM/Views/ContentView/ContentView.swift:379-380`).
  - switching to `Reels` and back rebuilds V-REELS, discarding its in-memory Shazam/OCR results (see V-REELS States).
  - empty/loading/error: delegated to the children.
- Data scale: n/a at container level.
- Pain points today:
  - Double page titles: `Discover` (E01) plus `Recommendations` (V-INBOX.E01) or `Reels Inbox` (V-REELS.E01, same page-title font) stacked under it (`MLM/Views/Discover/DiscoverView.swift:18`, `MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:18`, `MLM/Views/ReelsInbox/ReelsInboxView.swift:148`).
  - Segment state not remembered; working in Reels and visiting another section loses the Reels context.
  - Count is on the sidebar but not on the segment (UI-GROUNDTRUTH §3.12 wireframe shows `Recommendations (4)`).
- Related flows: `discover`, `reels-triage`.
- Constraints: native look; English only; glossary word "Discover" = Recommendations + Reels; "Recommendation" never "Neighbor"/"Swarm" (UI-GROUNDTRUTH §1.5).
- Open questions for the designer:
  - Should the segment carry the pending count, the sidebar badge, or both (§4.3 says sidebar badge only)?
  - Should Discover remember the last segment (and the selected reel) across navigation?
  - Are Recommendations and Reels really one destination, given one is a verdict inbox and the other an identification workbench?

### V-INBOX — Recommendations (Discovery inbox)
- Reached via: V-DISC segment `Recommendations` (default)  ·  Leads to: A-INBOX-DELETE, A-INBOX-ERROR, P-PLAYER (Preview plays in the main player). Entry point for new items is outside this area: Inspector `Similar` tab (P-INSPECTOR-SIMILAR) → `Show all` → Similar sheet (owned by inspector.md, `MLM/Views/TrackDetail/MetadataPanel.swift:1084-1085,183-185`, `MLM/Views/TrackDetail/GrooveView.swift:513-720`).
- Code: `MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:4-169` (view + actions), `:173-252` (row), `MLM/Services/Analysis/DiscoveryReviewService.swift:39-83` (accept/delete), `MLM/Database/TrackRepository.swift:1364-1423` (inbox query, status), `MLM/ViewModels/DownloadViewModel.swift:651-818` (how items get in), `MLM/Services/Analysis/SwarmRecommendationService.swift:71-336` (where suggestions come from)
- Purpose: decide, one by one, whether each recommended track the user downloaded is a keeper or should be thrown away.
- Where recommendations come from (as the user would understand it):
  1. Only from the user's own action: in a track's Similar sheet the user picks a source (`SoundCloud` | `Last.fm`, `MLM/Views/TrackDetail/GrooveView.swift:520-528`) and sees 10 suggestions (`Load more` adds 10, `MLM/Views/TrackDetail/GrooveView.swift:818`).
     - SoundCloud: if the seed came from SoundCloud, its URL is resolved; otherwise MLM searches SoundCloud for "<artist> <title>" and **takes the first hit** as the seed (could be the wrong song), then asks for related tracks (`MLM/Services/Analysis/SwarmRecommendationService.swift:81-115,242-285`).
     - Last.fm: "similar tracks" by artist+title (`MLM/Services/Analysis/SwarmRecommendationService.swift:117-127,134-197`).
  2. User clicks `Download` on a suggestion → queued → `Downloading…` → `Downloaded` (or `Retry`) inside the Similar sheet (`MLM/Views/TrackDetail/GrooveView.swift:633-681`). The file goes to `<library folder>/Discovered Neighbors/<Seed artist> - <Seed title>/`, is inserted as a normal local track (album falls back to `Discovered Neighbors` if the file has no album tag), queued for audio analysis, and logged as discovery status `new` (`MLM/ViewModels/DownloadViewModel.swift:722-799`).
  3. It now appears here, newest first (`MLM/Database/TrackRepository.swift:1377-1384`).
- User goals:
  1. Listen to a recommendation quickly and decide keep/delete — weekly *(inferred cadence)*.
  2. Understand why it was recommended (which of my tracks it came from) — weekly.
  3. Get rid of bad recommendations without leaving files behind — weekly.
  4. Clear a large backlog fast (bulk keep/delete) — rare *(inferred; no bulk exists)*.
- What the user wants to see, in priority order:
  1. Title + artist of each recommendation, and the seed track it came from.
  2. A way to hear it right now (ideally from the most characteristic part).
  3. Keep / delete actions with a clear consequence.
  4. Source (SoundCloud / Last.fm), how many wait.
  5. *(missing today)* duration, format/quality, when it was downloaded, where the file is.
- Elements today:
  - V-INBOX.E01 — section title `Recommendations` (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:18-20`).
  - V-INBOX.E02 — count line `N recommendations waiting for review` (always plural, also for 1 and 0) (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:21-23`).
  - V-INBOX.E03 — `Refresh` button (arrow.clockwise icon + text), disabled while loading; reloads the list (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:27-32`).
  - V-INBOX.E04 — loading state `Loading recommendations…` spinner (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:38-42`).
  - V-INBOX.E05 — empty state: sparkles icon, `No recommendations yet`, `Open a track's Similar tab to find and download recommendations.` — text only, no button or link (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:43-57`).
  - V-INBOX.E06 — list (inset style), one row per recommendation (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:58-79`). Row (`:182-240`):
    - E06a cover thumbnail 40×40 (`:185-186`);
    - E06b title, 1 line (`:190-193`);
    - E06c artist, 1 line (`:196-199`);
    - E06d `•` + `Recommended because you liked "<seed title>"` in accent colour — only if the seed track still exists (`:201-210`);
    - E06e source badge: raw source string upper-cased, e.g. `SOUNDCLOUD`, `LASTFM`, capsule in orange (SoundCloud) / red (Last.fm) / muted (other) (`:217-226,242-251`);
    - E06f `Preview` (bordered) — plays the track in the main player, then jumps to the detected "drop" if audio analysis has stored one (`:230,153-168`);
    - E06g `Add to library` (bordered) — marks the recommendation approved and records positive feedback for the seed; the row disappears (`:232,126-139`, `MLM/Services/Analysis/DiscoveryReviewService.swift:39-57`);
    - E06h `Delete…` (bordered, destructive) — opens A-INBOX-DELETE (`:234,68-71`).
- Interactions: click buttons only. No row selection, no double-click, no right-click (CM-TRACK is **not** attached), no keyboard handling, no drag, no multi-select, no hover tooltips. List auto-reloads when any download completes (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:104-106`).
- States:
  - default: list, newest first.
  - empty: E05. **Same view when loading failed or the library isn't ready**: a load error is only logged (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:120-123`); with no repository the view stays empty (`:112`).
  - loading: E04 replaces the whole list on every reload — including after each `Add to library`/`Delete` and every `downloadDidComplete` (`:113,134,146,104-106`), so the list blinks to a spinner and back.
  - error: action failures → A-INBOX-ERROR. Preview failures surface only in the player (P-PLAYER), not here.
  - analysis not run: Preview starts at 0:00 instead of the drop; no indication either way (`:159-166`). Discovered tracks are auto-queued for analysis after download (`MLM/ViewModels/DownloadViewModel.swift:789`).
  - offline: the inbox itself is local-only and works offline. Getting *new* recommendations (Similar sheet) fails with e.g. `SoundCloud network error.` / `Last.fm network error.` (`MLM/Services/Analysis/SwarmRecommendationService.swift:27,34`) shown under `Could not load recommendations` in the Similar sheet (`MLM/Views/TrackDetail/GrooveView.swift:558-561`).
  - source not configured: Similar sheet shows `Last.fm not configured — add an API key in Settings.` / `SoundCloud is not configured. Add a client ID in Settings.` (`MLM/Services/Analysis/SwarmRecommendationService.swift:19,28`) — but no such Settings field exists; the values come from the credentials file / `~/.config/scdl/scdl.cfg` (`MLM/Utilities/CredentialsLoader.swift:44-49`, `MLM/Services/Download/SoundCloudDownloader.swift:372-374`).
  - drive not connected: list still renders (DB data); `Preview` fails in the player; `Delete…` cannot trash the file (it isn't reachable) but still deletes the database entry, leaving an orphan file in `Discovered Neighbors/…` (`MLM/Services/Analysis/DiscoveryReviewService.swift:62-67`).
  - huge backlog: whole inbox loaded at once, no paging, sorting, filtering, search or grouping by seed (`MLM/Database/TrackRepository.swift:1377-1413`); sidebar badge re-runs the full query just to count (`MLM/Views/Sidebar/SidebarView.swift:267`); every verdict reloads everything.
  - in-progress background work: none shown here; discovery downloads show in the Similar sheet and in Activity (P-ACTIVITY-OPS via DownloadViewModel `isDownloading`/`currentTrack`, `MLM/Views/Activity/ActivityFeed.swift:159,462-467`).
- Data scale: unknown (live DB off-limits; "Unresolved from code"). Inbox size is bounded by how many recommendations the user manually downloaded.
- Pain points today:
  - `Add to library` is misleading: the track is **already** in the library (Library, Folders, search) from the moment it was downloaded; the button only changes its discovery status and feeds the similarity signal (`MLM/ViewModels/DownloadViewModel.swift:761-799`, `MLM/Services/Analysis/DiscoveryReviewService.swift:42-55`). Conversely, pending recommendations are not marked as such anywhere else (no Library query filters on the discovery log — grep of `track_discovery_log` shows no Library/Folders usage).
  - Banned word leaks into the file system and album field: folder `Discovered Neighbors` and fallback album `Discovered Neighbors` (`MLM/ViewModels/DownloadViewModel.swift:722-727,765`) vs glossary "never Neighbor" (§1.5).
  - No Undo after delete although the service keeps recovery data (`MLM/Services/Analysis/DiscoveryReviewService.swift:15,65`; unused anywhere) — UI-001.
  - Load failure masquerades as "No recommendations yet" (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:120-123`).
  - Empty state names a feature path ("a track's Similar tab") without a button; the actual source picker is one more click away (`Show all` → sheet).
  - Raw source badge text `LASTFM` (no dot, all caps) (`:217`).
  - Accept gives no confirmation/feedback besides the row vanishing; approved recommendations are not listed anywhere.
  - Preview hijacks the main player and clears the queue context (`MLM/ViewModels/PlaybackViewModel.swift:119-125`); no stop/playing indicator in the row.
  - Count line grammar `1 recommendations` (`:21`).
- Related flows: `discover`, `daily-listening` (preview), `drive-unplugged`.
- Constraints: copy per §5.7 (`Recommendations`, `Recommended because you liked "Title"`, `Add to library`, `Delete…`); errors = cause + action (§1.7.4); destructive confirmations state the consequence (§1.7.5); learning signal stays invisible (§3.11 rule 2); accept/delete logic shared with the Similar sheet (§3.11 rule 3 — met by `DiscoveryReviewService`).
- Open questions for the designer:
  - What does "keep" mean to the user if the file is already in the library — should pending recommendations be visibly "on probation" in Library/Folders, or held outside the library until accepted?
  - Should the inbox be grouped by seed track ("Because you liked X: 4 tracks")?
  - Should verdicts be keyboard-driven (next/keep/delete) for fast triage, with spacebar preview?
  - How should "preview from the drop" be communicated, and what happens if analysis hasn't run yet?
  - Where should the user start a recommendation search from Discover itself (today impossible)?
  - Should there be an Undo for Delete, given files go to the Trash?

### V-REELS — Reels (Reels inbox)
- Reached via: V-DISC segment `Reels`  ·  Leads to: S-REELS-OPENFOLDER, S-REELS-KEYFRAME, A-REELS-DELETE, A-REELS-DELETEERROR, CM-REELS-ADDPL, CM-REELS-TEXTPILL, P-PLAYER (result previews play in the main player), Library (downloads land as tracks with album `Reels`), V-PLD (add to playlist).
- Code: `MLM/Views/ReelsInbox/ReelsInboxView.swift:51-2005` (view + logic), `:2008-2035` (Shazam delegate), `:2110-2150` (keyframe thumbnail), `:2153-2279` (keyframe sheet), `:2283-2323` (delete confirmation/error), `MLM/Database/ReelRepository.swift:5-31`, `MLM/Services/Common/ReelDeletionController.swift:13-30`, `MLM/Services/Search/UnifiedSearchService.swift:24-100`
- What a "reel" is (from code): a **local video file** (`.mp4` or `.mov`) the user saved, typically an Instagram Reel (`MLM/Views/ReelsInbox/ReelsInboxView.swift:365`, OCR noise filter for Instagram UI words `:1518-1542`). There is no Instagram/TikTok URL import and no account connection; only files on disk.
- Purpose: find out which song plays in a saved video and get that song into the library or a playlist.
- User goals:
  1. Bring saved videos in (folder or drag & drop) — weekly *(inferred)*.
  2. Identify the song automatically (file name / Shazam / on-screen text) — weekly.
  3. Correct the artist/title by hand or by picking recognized text — weekly.
  4. Hear candidate matches from the download sources and pick the right one — weekly.
  5. Download it (or add it to a playlist to download later) — weekly.
  6. Remove handled reels from the list — weekly.
- What the user wants to see, in priority order:
  1. Which videos are still unidentified vs done (today: only "Artist - Title" or `Not parsed` per row; no "downloaded" state).
  2. The video itself, to watch/listen.
  3. The best guess for artist + title and where it came from (file name / Shazam / OCR).
  4. Matching tracks per source with duration, to preview and pick.
  5. Confirmation that the download was queued / succeeded / failed (today: none).
- Elements today (left column, 260–350 pt, `MLM/Views/ReelsInbox/ReelsInboxView.swift:145-242`):
  - V-REELS.E01 — header `Reels Inbox` (page-title font) (`:148-150`).
  - V-REELS.E02 — `Import` button (folder.badge.plus), tooltip `Select folder containing reels` → S-REELS-OPENFOLDER (`:154-158`).
  - V-REELS.E03 — list empty state: icon, `No Reels Imported`, `Drag and drop .mp4 or .mov files here, or click Import to load a folder.`, prominent button `Select Folder` → S-REELS-OPENFOLDER; background tints while a drag hovers (`:164-187`).
  - V-REELS.E04 — reel list (sidebar style, single selection) (`:189-239`). Row: video icon; **file name** incl. extension (bold); second line `<artist> - <title>` or `Not parsed` (`:205-214`); small spinner while Shazam runs for that reel (`:219-222`). Sorted newest-imported first on reload (`MLM/Database/ReelRepository.swift:14-16`), appended at the bottom during a session (`:671`).
  (right pane, `:245-377`)
  - V-REELS.E05 — no-selection state: icon, `Select a Reel`, `Choose an imported Instagram Reel from the sidebar to identify and download its music.` (`:355-372`).
  - V-REELS.E06 — `Reel Preview` label + inline system video player (AVKit, 180×240, native transport controls; does not autoplay) (`:253-266`).
  - V-REELS.E07 — `Music Identification` section label (`:270-272`).
  - V-REELS.E08 — `Search and download` label, free-text field placeholder `Artist, title, or another search term` (Return searches), and an unlabeled magnifier icon button (no tooltip) (`:275-290`). The field is overwritten with "<artist> <title>" whenever artist/title change (`:743`).
  - V-REELS.E09 — `Artist` field, placeholder `e.g. Drake`; every keystroke saves the reel (`:296-305,732-744`).
  - V-REELS.E10 — `Song Title` field, placeholder `e.g. Hotline Bling`; same autosave (`:307-317`).
  - V-REELS.E11 — prominent button `Search & download` (spinner while searching); disabled when both Artist and Song Title are empty, even if E08 has text; it **only searches** (`:319-336`).
  - V-REELS.E12 — panel `Video analysis and text recognition (OCR)` / `Select a keyframe to seek, or use recognized text to search.` (`:1180-1186`).
  - V-REELS.E13 — Shazam button **`Per Audio erkennen (Shazam)`** (German; UI-011) (`:1204-1212`); while running replaced by spinner + `Identifying with Shazam…` (`:1191-1202`). Listens to the first 12 s of the video's audio, waits ≤4 s for an answer (`:1694,1709`).
  - V-REELS.E14 — Shazam result card: `Shazam match` / `<Artist> - <Title>` (green) / button `Use match` (fills fields + searches) (`:1217-1247,1608-1624`).
  - V-REELS.E15 — Shazam failure line: `Shazam could not identify this track. Try the on-screen text instead.` (`:1248-1259`).
  - V-REELS.E16 — `Video keyframes`: while running `Loading keyframes and reading on-screen text…` (`:1268-1282`); then a horizontal strip of 10 thumbnails (100×75, at 5 %…95 % of the duration) each with a play icon (tooltip `Seek to this point` → jumps the video there and plays) and a time label like `12.3s`; clicking the thumbnail itself opens S-REELS-KEYFRAME (tooltip `Click to enlarge this frame and select text`) (`:1283-1295,2110-2149`); if nothing was generated, button `Load keyframes and run OCR` (`:1296-1304`).
  - V-REELS.E17 — `Recognized text` panel (only when OCR found text) (`:1308-1417`): sub-heading `Recognized songs and titles` with one button per "Artist - Title"-shaped candidate (`<Artist> - <Title>` / `Select to use this song and search`) → fills fields + searches (`:1315-1358`).
  - V-REELS.E18 — `Recognized text fragments`: up to 8 pills (truncated in the middle), each with a ⊕ pull-down → CM-REELS-TEXTPILL (`:1360-1408`).
  - V-REELS.E19 — `Unified Search Results` header + spinner (`:382-394`); placeholder icon + `Searching sources...` or `No results yet` while no results object exists (`:396-410`).
  - V-REELS.E20 — up to four source sections in fixed order `DABmusic`, `Qobuz`, `SoundCloud`, `YouTube` (icon + name), each ≤3 results; a source with 0 hits is omitted (`:412-496`; limit `MLM/Services/Search/UnifiedSearchService.swift:24`).
  - V-REELS.E21 — result row: title, artist (uploader for YouTube/SoundCloud, `Unknown` if missing), duration `m:ss` if known; icon buttons: play/stop (tooltip `Preview / Listen to track`, spinner while resolving), download (tooltip `High priority download`), ⊕ menu (tooltip `Add to playlist`) → CM-REELS-ADDPL (`:541-620`).
- Automatic behaviour on selecting a reel (`:709-730`): stops the video, cancels a running search, loads the video, copies the reel's artist/title into the fields; **if the file name parsed into artist/title it searches immediately, otherwise it starts Shazam**; and it always starts keyframe OCR (skipped if done earlier in this session). When OCR finishes and both fields are still empty, the best on-screen candidate is filled in and searched (`:1845-1855`). When Shazam matches, it **overwrites** the fields (even if the user typed meanwhile) and searches (`:1719-1730`). File-name parsing splits on ` - `, `–`, `—`, `•`, `|`, `:` or `-` (`:1143-1156`).
- Interactions:
  - click row / arrow keys in list → select + auto-identify (K-REELS-LISTNAV).
  - Return in E08 → search (K-REELS-RETURN).
  - deleting rows: only via SwiftUI's list `.onDelete` (`:232`) → A-REELS-DELETE (K-REELS-DELETE; reachability on macOS unverified, "Unresolved from code"). No visible delete button, no context menu.
  - drag & drop: D-REELS-IMPORT.
  - result preview toggles: clicking play on the currently playing result stops main playback (`:897-900`).
  - no right-click menus, no multi-select UI (list is single selection), no "Show in Finder" for a reel.
- States:
  - empty (no reels): E03. Also shown when the reel repository isn't available (library not loaded) (`:1977-1979`).
  - no selection: E05.
  - loading: per-reel spinner (Shazam) in the row and E13; OCR E16; search E11/E19; per-result preview spinner.
  - filtered-empty / zero results: if the search returns nothing from all four sources the results area is **blank** under the header (no "no matches" text) because results exist but every section is empty (`:396,412-496`).
  - error: none surfaced. Search errors per source are logged and turned into "0 hits" (`MLM/Services/Search/UnifiedSearchService.swift:31-71`); preview resolve/download failures only clear the spinner (`:905-911,890-892`); download failures are invisible here; Shazam/AV errors become the generic E15; OCR errors silently end with the `Load keyframes and run OCR` button.
  - offline: Shazam fails as "could not identify" (E15); every source returns 0 → blank results; nothing says "offline".
  - drive not connected / file moved: reel row stays; video stays black, Shazam reports E15, OCR yields nothing — no "file missing" state (`:1642-1652,1767-1776`).
  - huge data: all reels loaded at once; each keystroke in E09/E10 re-reads all reel records to save one (`:1991-2004`). OCR keyframes held in memory per reel for the session.
  - persistence: only id, file path, artist, title survive (`:1991-2003`, `ReelRepository.swift`). Shazam result, OCR text, keyframes are lost when leaving the Reels segment or Discover (§3.12 asked for persisted list — partly met).
  - in-progress background work: downloads started here run through the shared download queue (`MLM/Services/Common/PerformanceQueueService.swift:72-76,335-342`); progress appears only in Activity (P-ACTIVITY-OPS), never back in the reel; if another download batch is active the job is dropped silently (`MLM/ViewModels/DownloadViewModel.swift:195-198`).
- Data scale: per reel 10 full-resolution keyframe images in memory; search limited to 3 hits × 4 sources.
- Pain points today:
  - German control `Per Audio erkennen (Shazam)` (`:1207`) — UI-011, §1.7.1. (The second UI-011 string `Kopieren` is fixed → `Copy`, `:1388`.)
  - Delete confirmation/error alert are attached to **each search-result row**, not to the list (`:622-631`): with no search results on screen the confirmation cannot appear, the deletion silently doesn't happen and stays pending — it may pop up later when results render; with several results N identical dialogs are bound to one state. (UI-015 follow-up.)
  - Confirmation copy contradicts itself: message says `The database entry will be removed. The media file on disk is not affected.` while the button's accessibility label is `Delete permanently` (`:2296-2304`).
  - `Search & download` only searches; the per-row download icon has no label, no feedback, no result status (`:319-336,590-600,1004-1056`).
  - Downloads create a library track with album `Reels` and a stream URL as origin (`:983-1001`) — conflicts with the wish to stop using album as a source marker (`todo_dump.md:9`); existing track with same artist/title is silently reused, so "download" can be a no-op (`:977-981`).
  - Previews download the whole audio file to a temp folder before playing, then play in the main player under album `Search Previews` (`:854-893`) — slow, silent on failure, interrupts what the user was listening to.
  - Add-to-playlist menu: playlists loaded once on appear (stale), empty menu if none, no confirmation, adds an *undownloaded* track at the end (`:603-616,1113-1140`).
  - Auto-actions fight the user: Shazam match overwrites typed fields; E08 is overwritten on any artist/title change.
  - Jargon/inaccurate copy: `Unified Search Results`, `Reels Inbox`, `Music Identification`, `Select a keyframe to seek` (clicking a keyframe enlarges; the small play icon seeks), `the sidebar` meaning the left reel list, `Searching sources...` (three dots), `Not parsed`.
  - No "done" state per reel: after downloading, the reel looks identical to an unhandled one.
  - Video audio and main-player preview can play at the same time (video is paused only when a result preview starts, `:896`).
  - Dead code: `ReelFramePreviewView` (`:2038-2107`) is never used.
- Related flows: `reels-triage`, `discover`, `build-playlist`, `fix-failed-downloads`, `drive-unplugged`.
- Constraints: English only (§1.7.1); §3.12: embedded search "scoped to resolving the identified track; not a third general search entry point"; downloaded reel tracks should use the normal availability vocabulary (§1.6); Qobuz cookie workaround must not ship in Reels (now absent from this file).
- Open questions for the designer:
  - Is the unit of work the *video* (inbox with done/undone) or the *song* (identify → acquire)? What marks a reel as finished?
  - Should identification sources (file name / Shazam / OCR) be presented as competing guesses with provenance, instead of silently overwriting fields?
  - How much of the 4-source search belongs here vs in global search (§3.12 says scoped)? Should the user even see source names like DABmusic/Qobuz?
  - What feedback should a download started here produce in the reel row itself?
  - Should removing a reel offer "also move the video to Trash", given the files are usually throw-away downloads?
  - Should a preview here play in an isolated preview player instead of taking over the main player?

---

## Context menus

> No right-click (`.contextMenu`) menus exist in any file of this area. The two entries below are **pull-down button menus** (click a ⊕ icon), listed here because they are the only menus.

### CM-REELS-ADDPL — "Add to playlist" pull-down on a search result
- Where: V-REELS.E21 ⊕ icon (tooltip `Add to playlist`) · `MLM/Views/ReelsInbox/ReelsInboxView.swift:603-616`
- Items: one item per existing playlist, labelled with the playlist name, in repository order (`:604-610`). No separators, no `New Playlist…`, no empty-state item (menu is empty when there are no playlists).
- Visibility: always; playlists loaded once when V-REELS appears (`:122-125,1132-1140`), not refreshed.
- Effect: creates (or reuses by exact artist+title match) a remote, undownloaded track (album `Reels`), appends it to the end of the playlist and posts `playlistDidChange` (refreshes V-PLD) (`:1059-1130`). No download is started, no feedback, errors ignored (`try?`, `:1119`).

### CM-REELS-TEXTPILL — recognized-text pill menu
- Where: V-REELS.E18 ⊕ on each text pill · `MLM/Views/ReelsInbox/ReelsInboxView.swift:1378-1398`
- Items (verbatim, in order): `Artist` · `Title` · `Use both as "Artist - Title"` · `Copy`
- Effects: `Artist` → sets artist field + saves reel (`:1428-1437`); `Title` → sets title + saves (`:1439-1448`); `Use both…` → splits the text on a delimiter and, only if both parts exist, sets both and searches — otherwise nothing happens, silently (`:1593-1600`); `Copy` → copies text to the clipboard (`:1450-1454`). `Artist`/`Title` don't trigger a search.

### Expected, missing
- Right-click on a V-INBOX row (expected: CM-TRACK — Show in Finder, Add to playlist, Play next; and Add to library / Delete…). Evidence: every other track list uses CM-TRACK; daily-driver wishes (`.planning/research/v1.4-daily-driver/FEATURES.md:233`).
- Right-click on a V-REELS list row (expected: Show in Finder, Remove from Reels, Identify again).

## Sheets, popovers, panels, alerts

### A-INBOX-DELETE — "Delete file?"
- Trigger: V-INBOX.E06h `Delete…` · `MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:68-71,89-100`
- Content: title `Delete file?` · message `The file will be moved to the Trash.`
- Buttons: `Cancel` (cancel) · `Delete` (destructive).
- Consequence: `Delete` → file moved to Trash (if reachable), track **and** its discovery entry removed from the database, `libraryDidImport` posted (Library/sidebar refresh), list reloads (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:141-151`, `MLM/Services/Analysis/DiscoveryReviewService.swift:59-69`). If the file is not reachable (drive unplugged, path missing) the DB entry is still removed and the file stays on disk. No Undo offered (UI-001).
- Escape: Cancel / Esc. Error → A-INBOX-ERROR `Could not delete this recommendation.`
- Same dialog exists in the Similar sheet (`MLM/Views/TrackDetail/GrooveView.swift:254-265`, INSPECTOR-owned).

### A-INBOX-ERROR — "Recommendations" error alert
- Trigger: failure of Add to library or Delete · `MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:82-88,136-137,148-149`
- Content: title `Recommendations`; message either `Could not add this recommendation to your library.` or `Could not delete this recommendation.`
- Buttons: `OK` (cancel).
- Notes: no cause, no action (§1.7.4); the underlying error is discarded (not even logged on these paths).

### S-REELS-OPENFOLDER — folder picker (NSOpenPanel)
- Trigger: V-REELS.E02 `Import` or E03 `Select Folder` · `MLM/Views/ReelsInbox/ReelsInboxView.swift:649-657`
- Content: standard open panel, folders only, single selection, no custom title/prompt/message.
- Consequence: adds every top-level `.mp4`/`.mov` in the folder (not recursive, hidden files skipped) that isn't already in the list; file name parsed into artist/title; each saved (`:659-678`). Nothing selected automatically. Non-video files ignored silently; a folder with no videos does nothing, silently. Read errors only logged (`:675-677`).
- Escape: Cancel → nothing.

### S-REELS-KEYFRAME — keyframe detail sheet
- Trigger: click a keyframe thumbnail in V-REELS.E16 · `MLM/Views/ReelsInbox/ReelsInboxView.swift:126-141,2153-2279`
- Content: header `Keyframe detail (offset: 12.3s)` (format `%.1fs`) · button `Close` (Esc) · left: enlarged frame · right: `Text recognized in this frame`, then per text: the text (selectable) and buttons `Artist` · `Title` · `Use both` (prominent, green); empty: `No text was recognized in this frame.` Size min 700×480, ideal 850×560.
- Buttons/consequences: `Artist` → sets artist field + saves, closes · `Title` → sets title + saves, closes · `Use both` → splits text into artist+title and searches if it parses, otherwise silently nothing; closes either way (`:130-140,2231-2260`) · `Close` → dismiss.
- Escape: `Close` has `.cancelAction` (Esc) (`:2169-2172`).

### A-REELS-DELETE — "Delete 1 reel?" / "Delete N reels?"
- Trigger: list `.onDelete` on V-REELS.E04 (`:232,746-748`) · dialog `MLM/Views/ReelsInbox/ReelsInboxView.swift:2283-2307`, **attached to each search-result row** (`:622-627`)
- Content: confirmation dialog, title `Delete 1 reel?` / `Delete N reels?` · message `The database entry will be removed. The media file on disk is not affected.`
- Buttons: `Delete` (destructive; accessibility label `Delete permanently`) · `Cancel` (cancel; accessibility label `Cancel deletion`).
- Consequence: rows removed immediately; if a deleted reel was selected the video stops and selection clears; DB removal awaited per reel; failures re-inserted at their old position and reported via A-REELS-DELETEERROR (`:750-797`). Video file untouched.
- Escape: Cancel / Esc clears the pending deletion.
- Bug: presentation depends on search results being on screen (see V-REELS pain points).

### A-REELS-DELETEERROR — "Deletion Error"
- Trigger: one or more reels could not be removed from the database · `MLM/Views/ReelsInbox/ReelsInboxView.swift:628-631,790-793,2309-2322`
- Content: title `Deletion Error` · message `Failed to delete: <title>, <title>` (reel titles; may be empty strings).
- Buttons: `OK`.
- Notes: title-case title; no cause or action; same attachment bug as A-REELS-DELETE.

## Menu items & keyboard shortcuts (area-local)

- **K-DISC-NAV** — ⌘7 · `Discover` in menu `Navigate` (M-NAVIGATE, owned by shell.md) · global · selects V-DISC · `MLM/App/MLMApp.swift:106-116`, `MLM/Views/ContentView/ContentView.swift:626`.
- **K-REELS-RETURN** — Return in V-REELS.E08 search field · focused field · runs the multi-source search · `MLM/Views/ReelsInbox/ReelsInboxView.swift:280`. (Artist/Song Title fields have no Return action.)
- **K-REELS-LISTNAV** — ↑/↓ in the reel list (system list selection) · list focused · each selection change runs `loadReel` → video load + auto search or Shazam + OCR · `MLM/Views/ReelsInbox/ReelsInboxView.swift:189,235-239,709-730`. Arrowing quickly through the list starts work for each reel passed.
- **K-REELS-DELETE** — list deletion via SwiftUI `.onDelete` (on macOS presumably ⌫ / Edit ▸ Delete on the selected row; not verifiable without running — "Unresolved from code") → A-REELS-DELETE · `MLM/Views/ReelsInbox/ReelsInboxView.swift:232`.
- **K-REELS-KEYFRAME-ESC** — Esc · S-REELS-KEYFRAME open · `Close` · `MLM/Views/ReelsInbox/ReelsInboxView.swift:2172`.
- Expected, missing: spacebar preview in V-INBOX (daily-driver "spacebar preview" wish, MEMORY/`project_daily_driver_loop`), keyboard keep/delete/next in V-INBOX, segment switching shortcut in V-DISC, spacebar play/pause for the reel video, ⌘O / ⌘I-style import in Reels.

## Drag & drop

### D-REELS-IMPORT — Finder video files/folders → Reels
- Source → target: Finder (any app providing file URLs) → the whole V-REELS split view (`:119-121`).
- Payload: `public.file-url`.
- What happens: each `.mp4`/`.mov` URL not already present is added (name parsed, saved); a dropped folder is scanned (top level only) like S-REELS-OPENFOLDER; anything else ignored silently (`:680-707`). Always reports the drop as accepted (`:706`). New reels appear at the bottom, not selected.
- Feedback during drag: accent tint only on the empty-state panel (E03, `:187`); once reels exist there is **no** drop highlight.

### Expected, missing
- **D-INBOX-TO-PLAYLIST** (missing) — drag a recommendation row onto a sidebar playlist / P-PINNED. Evidence: daily-driver "build playlist by drag & drop" wish (`.planning/research/v1.4-daily-driver/FEATURES.md:233,266`).
- **D-REELS-RESULT-TO-PLAYLIST** (missing) — drag a search result onto a playlist instead of the ⊕ menu.
- **D-REELS-URL** (missing) — drop an Instagram/TikTok link (text/URL) to fetch the reel; today only local files are accepted.
- **D-REELS-OUT** (missing) — drag a reel row out to Finder / reveal; rows are not draggable.

---

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Drive not connected** (library folder on external disk): V-INBOX lists normally (DB only); `Preview` fails in P-PLAYER; `Delete…` removes DB entry but cannot trash the file → orphan in `Discovered Neighbors/` (`MLM/Services/Analysis/DiscoveryReviewService.swift:62-67`). New recommendation downloads (Similar sheet) fail → `Retry` badge there; with no library folder configured: `Downloads are unavailable until a library is configured.` (`MLM/ViewModels/DownloadViewModel.swift:663-667`). V-REELS: videos on the unplugged disk stay listed; video black, Shazam → E15 text, OCR → nothing; no "not connected" wording anywhere. Reel downloads queue but fail invisibly here.
- **Library loading / failed**: repositories nil → V-INBOX shows "No recommendations yet" (`MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:112`), V-REELS shows "No Reels Imported" (`MLM/Views/ReelsInbox/ReelsInboxView.swift:1978`); sidebar badge hidden. Misleading in both cases.
- **Source disconnected / not configured**: Last.fm key or SoundCloud client ID missing → errors in the Similar sheet pointing to non-existent Settings fields (`MLM/Services/Analysis/SwarmRecommendationService.swift:19,28`). In V-REELS a failing/unconfigured source just disappears from results (`MLM/Services/Search/UnifiedSearchService.swift:31-71`); Qobuz without captcha cookie searches fine but downloads fail (`MLM/Services/Download/DownloadOrchestrator.swift:312`, logged only).
- **Background processing**: discovery downloads drive DownloadViewModel progress → P-ACTIVITY-OPS (`MLM/Views/Activity/ActivityFeed.swift:159,462-467`); after download the track is queued for analysis (`MLM/ViewModels/DownloadViewModel.swift:789`), which later enables "preview from the drop" in V-INBOX — invisible here.
- **Track availability**: V-INBOX shows no availability chip; pending recommendations are local files. Reel downloads/playlist adds create `Not downloaded` remote tracks with album `Reels` that appear in Library/playlists, not in V-REELS.

### Background work touchpoints

| Work | Started from | Progress visible | Result/error visible | User control |
|---|---|---|---|---|
| Recommendation fetch (SoundCloud/Last.fm) | Similar sheet | spinner in sheet | list / `Could not load recommendations` + message (`MLM/Views/TrackDetail/GrooveView.swift:551-577`) | source picker, refresh, `Load more` |
| Recommendation download | Similar sheet `Download` | `Queued…`/`Downloading…` in sheet; Activity | `Downloaded`/`Retry` in sheet; then appears in V-INBOX (via `downloadDidComplete`, `MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift:104-106`) | Retry only; no cancel |
| Post-download analysis | automatic (`MLM/ViewModels/DownloadViewModel.swift:789`) | Activity analysis (owned elsewhere) | none in V-INBOX | none here |
| Accept → feedback + embedding nudge | V-INBOX `Add to library` | none | row disappears | none (invisible by design, §3.11) |
| Shazam identification | auto on select / E13 | E13 + row spinner | E14 / E15 | re-run via E13; no cancel |
| Keyframe OCR | auto on select / E16 button | E16 text | E17/E18 or nothing | no cancel |
| 4-source search | auto / E08 / E11 / candidates | E11/E19 spinner | E20 sections (blank on 0 hits) | new search cancels old (`:800`) |
| Result preview (full file download to temp) | E21 play | per-row spinner | plays in P-PLAYER; failure silent | click again to stop |
| Reel track download | E21 download | Activity only | nowhere in Reels; dropped if a batch is running (`MLM/ViewModels/DownloadViewModel.swift:195-198`) | none |
| Reel persistence | every field edit, import, delete | none | delete failures → A-REELS-DELETEERROR; save failures ignored (`:2003`) | none |

### Flow notes

**flow: discover** (get recommendations → listen → keep/delete → library)
1. User is on a track they like (Library) and wants more like it → opens Inspector `Similar` tab (P-INSPECTOR-SIMILAR) → `Show all` → Similar sheet. *Breaks:* nothing in V-DISC starts this; V-INBOX.E05 only describes it in text.
2. Picks `SoundCloud` or `Last.fm`, scans 10 suggestions, clicks `Download` on interesting ones. *Breaks:* suggestions can't be previewed before download *(per sheet code: remote rows only offer Download)*; local tracks seeded via SoundCloud search may resolve to the wrong seed silently (first hit, `MLM/Services/Analysis/SwarmRecommendationService.swift:242-285`); unconfigured sources point to non-existent Settings fields.
3. Download runs (Activity shows it); the file is written to `Discovered Neighbors/<seed>/` and is **already in the library**. Sidebar badge on `Discover` increments.
4. User goes to Discover (⌘7) → V-INBOX. Sees title/artist/seed/source. *Breaks:* no duration/quality; no grouping by seed; spinner flash on every reload.
5. `Preview` → plays in main player, jumping to the drop if analysed. *Breaks:* replaces queue context; no in-row playing state; no keyboard.
6. Verdict: `Add to library` (status approved, silent learning, row disappears) or `Delete…` → A-INBOX-DELETE → Trash. *Breaks:* "Add to library" for something already in the library; no Undo; no bulk; drive unplugged → orphan file.
7. Kept track lives on in Library/Folders under `Discovered Neighbors` — banned word visible in folder and fallback album.

**flow: reels-triage** (saved Instagram videos → identified song → download/playlist)
1. User saved videos to a folder → V-DISC `Reels` → `Import`/`Select Folder` (S-REELS-OPENFOLDER) or drags files (D-REELS-IMPORT). *Breaks:* no drop highlight when list non-empty; no URL import; non-recursive folder scan.
2. Clicks a reel (V-REELS.E04). MLM auto-searches if the file name looks like "Artist - Title", else runs Shazam; OCR always runs. *Breaks:* arrow-key browsing triggers heavy work per reel; leaving Discover discards results.
3. Reviews guesses: Shazam card (`Use match`), OCR candidates, text pills (CM-REELS-TEXTPILL), or keyframe sheet (S-REELS-KEYFRAME); edits Artist/Song Title. *Breaks:* German Shazam label; Shazam overwrites typing; offline looks like "couldn't identify"; no provenance shown for prefilled fields.
4. Search results per source (E20/E21); clicks play to preview. *Breaks:* zero results = blank area; preview downloads the full file first and hijacks the main player.
5. Clicks download icon (`High priority download`) or ⊕ → playlist. *Breaks:* zero feedback; download may be dropped silently if another batch runs; creates album `Reels`; may silently reuse an existing track.
6. Removes the handled reel (list delete → A-REELS-DELETE). *Breaks:* dialog only appears if search results are on screen; no "done" state to distinguish handled reels instead.

**flow: build-playlist** — CM-REELS-ADDPL adds undownloaded tracks to a playlist from Reels; no D&D from V-INBOX or V-REELS (see Drag & drop "Expected, missing").

**flow: fix-failed-downloads** — reel downloads that fail are only visible in Activity / as `Not downloaded` tracks in Library; V-REELS never shows them. Recommendation downloads show `Retry` only inside the Similar sheet, not in V-INBOX.

**flow: drive-unplugged** — see "Global-state touchpoints"; Discover has no drive banner and no disabled states.

**flow: daily-listening** — V-INBOX `Preview` is the only playback entry; it uses the main player and clears the up-next context (`MLM/ViewModels/PlaybackViewModel.swift:119-125`).

### Unresolved from code

- Whether SwiftUI `.onDelete` on a macOS `List` (`MLM/Views/ReelsInbox/ReelsInboxView.swift:232`) is reachable by the Delete key, Edit ▸ Delete or a swipe — no explicit key handler exists; needs a run (forbidden here).
- How many recommendations / reels the real library holds — live DB is off-limits and ROADMAP §0–§1 gives no Discover numbers.
- Whether the Similar sheet lets the user preview a *not yet downloaded* recommendation — only its local rows have preview in the code read (`MLM/Views/TrackDetail/GrooveView.swift:589-597`); full sheet is inspector.md's.
- Whether DAB/Qobuz stream URLs stored as a reel track's origin (`MLM/Views/ReelsInbox/ReelsInboxView.swift:1005-1027`) expire before the queued download runs *(inferred risk; depends on DABClient/SquidWtfClient, not read in full)*.
- Exact P-PLAYER behaviour when a V-INBOX preview's file is on an unplugged drive (owned by main.md).
- Whether `List(selection:)` keeps the highlight after a reel's in-memory data changes (`ImportedReel` is compared by all fields, `MLM/Views/ReelsInbox/ReelsInboxView.swift:33-49`); visual effect needs a run.

