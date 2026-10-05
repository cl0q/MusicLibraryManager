# Playlists, Playlist Detail & Folders

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): PL (grid), PLD (detail), FOLD · Files covered: `MLM/Views/Playlists/{PlaylistsView,PlaylistCard,PlaylistDetailView,PlaylistDetailViewLoader,PlaylistTable}.swift`, `MLM/Views/Folders/{FoldersView,FolderTreeView}.swift`, `MLM/ViewModels/{PlaylistViewModel,PlaylistDetailViewModel,PlaylistIngestViewModel,FolderViewModel}.swift`, `MLM/Services/Playlists/{PlaylistCoverService,MosaicCompositor,GradientPalette,ArtworkExtractor}.swift`, `MLM/Services/Common/PlaylistTableCache.swift`

**Two definitions to read first.**

**1. What a "playlist" is in MLM today.** One database table (`playlists`) holds every kind (`MLM/Models/Playlist.swift:8-62`). The UI tells the kinds apart only by a few flags:

| Kind (user's words) | How it comes to exist | Flags | How the UI differs |
|---|---|---|---|
| **Local (native) playlist** | `New Playlist` popover (S-PL-NEWPLAYLIST), File → `New Playlist` ⌘N (creates "Untitled Playlist", `MLM/App/MLMApp.swift:94-98, 235-242`), `New Playlist…` from the track context menu (CM-TRACK, library.md), M3U import that resolves to a new playlist name (S-PLD-M3U-PREVIEW) | `source_id` NULL, `category = "regular"` (`MLM/Models/Playlist.swift:56-59, 210-215`) | No source label on the card. Detail header says `Local playlist` on hover and has no provenance. No `Sync` button. Has `Link Source…`. Grid filter `Local` shows these. |
| **Linked playlist** ("source-linked", "remote") | Imported in the Remote playlists window (W-REMOTE, sources-review.md) from SoundCloud / YouTube / Spotify, or a local playlist linked afterwards with `Link Source…` (S-PLD-LINK) | `source_id` set, `external_id` = remote id or URL, `category = "synced"` (`MLM/Database/PlaylistRepository.swift:418, 534, 622`) | Brand-coloured source name under the card title (`SoundCloud`, `YouTube` …). Header line `N tracks · Linked to YouTube · imported Jan 12, 2026`. Accent fallback gradient. `Change Link…` replaces `Link Source…`. `Sync` (refresh from source) appears **only** when `external_id` is a URL, which in practice means YouTube (`MLM/ViewModels/PlaylistDetailViewModel.swift:230-239`; SoundCloud/Spotify store numeric ids, `MLM/Services/Sources/RemotePlaylistProvider.swift:197, 288, 401`). "Download missing" downloads use that source first (`MLM/ViewModels/PlaylistDetailViewModel.swift:68-70`). |
| **Liked playlist** | Created by source "likes" sync (SoundCloud Likes, Spotify liked songs, Apple Music library) and by importing a file named `Liked.m3u8` (`MLM/Services/Sync/PlaylistIngestService.swift:148-159`) | `is_liked = 1` | Red heart gradient + `heart.fill` symbol, a `Liked` label next to the track count. **Cannot be deleted**: the Delete item is hidden (`MLM/Views/Playlists/PlaylistCard.swift:348-354`) and the repository refuses (`MLM/Database/PlaylistRepository.swift:88-92`). Cannot be linked. Has `Sync` when it has a source. |
| **Smart playlist** | Nothing in the code creates one | `is_smart = 1` | Icon (`wand.and.stars`) and gradient exist (`MLM/Views/Playlists/PlaylistCard.swift:495-497, 510-512`); dormant. |
| `category = "album"` | Nothing creates it | — | Icon mapping `opticaldisc` only (`MLM/Views/Playlists/PlaylistCard.swift:501`); dormant (see "Flow notes" albums-future). |

**2. What a "folder" is in MLM today.** In the Folders view (V-FOLD) a folder is **a real filesystem directory under the library folder** (the library root, e.g. `/Volumes/Lexxar/Music`), read straight from disk (`MLM/ViewModels/FolderViewModel.swift:6-9`, `MLM/Services/Folders/DiskFolderScanner.swift:46-57`). Folders are **not** playlist folders. MLM has **no way to group playlists into folders**: the `Playlist` model has no parent or folder field (`MLM/Models/Playlist.swift:8-25`), and neither the grid nor the sidebar can nest playlists. Playlist folders are listed as an open wish (`.planning/research/v1.4-daily-driver/FEATURES.md` B-D7). "Logical folders/collections" are deferred (`.planning/REQUIREMENTS.md:236-241`). In V-FOLD a folder never holds playlists, and a playlist never maps to a folder.

## Surfaces

### V-PL — Playlists (grid)
- Reached via: sidebar `Playlists` (P-SIDEBAR) · ⌘2 (M-NAVIGATE, `MLM/Views/ContentView/ContentView.swift:617-622`) · spring-loaded drag hover over the sidebar `Playlists` row (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:67-72`) · File → `New Playlist` jumps here after creating "Untitled Playlist" (`MLM/App/MLMApp.swift:235-242`) · the detail's back button ("‹ Playlists") · `Back to Playlists` on the not-found state · Leads to: V-PLD (click card, spring-load, `Show failed tracks`), S-PL-NEWPLAYLIST, A-PL-DELETE, CM-PL-CARD, S-PL-BANNER-PINLIMIT, S-PL-BANNER-COVERDROP, V-SYNC (via `Sync to ▸`), P-PINNED (pin)
- Code: `MLM/Views/Playlists/PlaylistsView.swift:21-503` (view), `MLM/Views/Playlists/PlaylistsView.swift:549-660` (card wiring), `MLM/Views/Playlists/PlaylistCard.swift:25-530` (card), `MLM/ViewModels/PlaylistViewModel.swift:10-401` (view model), `MLM/Services/Playlists/PlaylistCoverService.swift:51-369` (covers), `MLM/Database/PlaylistRepository.swift:27-33, 189-234` (order + health query)
- Purpose: see all playlists at once, recognise each by its cover, see where it came from and whether it is fully playable, and act on it (open, create, rename, pin, delete, download, sync to device).
- User goals:
  1. Open a playlist to listen to it (daily).
  2. Create a new empty playlist to fill later (weekly) — the "native playlists" half of the daily-driver loop (`.planning/PROJECT.md:38-48`).
  3. Spot which linked playlists are incomplete or still downloading, then fix them (`Incomplete` filter, `Show failed tracks`, `Download missing (n)`) (weekly).
  4. Find one playlist among many by name or source (weekly).
  5. Pin favourites so they show in the sidebar (rare).
  6. Give a playlist a custom cover by dragging an image onto it, or go back to the automatic cover (rare).
  7. Add a playlist to a device sync profile (rare).
  8. Rename or delete a playlist (rare).
- What the user wants to see, in priority order:
  1. Cover + name (recognition).
  2. Whether the playlist is fully playable: `Importing · 12 of 44` / `Incomplete · 9 failed`; whether it holds tracks that were **never** downloaded (today invisible on the card, see pain points).
  3. Where it came from (source label).
  4. Size (`44 tracks`); total duration is not shown *(wish: `.planning/research/v1.4-daily-driver/FEATURES.md` B-T7)*.
  5. Pinned or not.
- Elements today:
  - V-PL.E01 Title `Playlists` + count capsule showing **all** playlists, not the filtered count (`MLM/Views/Playlists/PlaylistsView.swift:157-168`).
  - V-PL.E02 Source filter menu (borderless menu button with a filter glyph and the current value). Items: `All`, `Local`, then one entry per source that has a linked playlist (e.g. `SoundCloud`, `YouTube`), the active one with a checkmark (`MLM/Views/Playlists/PlaylistsView.swift:256-303`, `MLM/ViewModels/PlaylistViewModel.swift:322-350`). `Local` = playlists with no resolvable source row (`MLM/ViewModels/PlaylistViewModel.swift:367-368`).
  - V-PL.E03 `Incomplete` toggle (circle / filled checkmark circle). Shows only playlists with ≥1 failed track (`MLM/Views/Playlists/PlaylistsView.swift:176-193`, `MLM/ViewModels/PlaylistViewModel.swift:373-377`).
  - V-PL.E04 Search field `Search playlists…` with a clear (x) button. Case-insensitive substring match on the name only (`MLM/Views/Playlists/PlaylistsView.swift:196-227`, `MLM/ViewModels/PlaylistViewModel.swift:357-361`). This field is separate from the toolbar search (V-SEARCH). Typing in the toolbar search here opens the global search pane instead (`MLM/Views/ContentView/ContentView.swift:263-268`).
  - V-PL.E05 Button `New Playlist` (+, accent-filled), ⌘N (K-PL-NEW) → S-PL-NEWPLAYLIST (`MLM/Views/Playlists/PlaylistsView.swift:230-248`).
  - V-PL.E06 Pin-limit banner → S-PL-BANNER-PINLIMIT (`MLM/Views/Playlists/PlaylistsView.swift:126-129`).
  - V-PL.E07 Cover-drop error banner → S-PL-BANNER-COVERDROP (`MLM/Views/Playlists/PlaylistsView.swift:133-136`).
  - V-PL.E08 Card grid: adaptive columns 200–260 pt. **Fixed order: pinned first, then A→Z by name.** The user cannot sort or rearrange (`MLM/Views/Playlists/PlaylistsView.swift:33-35, 356-372`, `MLM/Database/PlaylistRepository.swift:27-33`).
  - V-PL.E09 Card cover (square). One of: (a) the cached cover PNG; (b) if none, a category gradient + SF Symbol (`music.note.list`, `heart.fill` for liked, `wand.and.stars` for smart, `opticaldisc` for "album"); plus a `pin.fill` glyph top-right when pinned (`MLM/Views/Playlists/PlaylistCard.swift:155-191, 489-514`). How covers are generated (PlaylistCoverService, `MLM/Services/Playlists/PlaylistCoverService.swift:140-239`):
    - No artwork in the first 4 tracks → a 512×512 gradient with the playlist's initials (`MLM/Services/Playlists/MosaicCompositor.swift:67-95`, `MLM/Services/Playlists/GradientPalette.swift:12-46`).
    - Fewer than 4 tracks, or only 1 artwork → that single cover.
    - Otherwise → a 2×2 mosaic of the first 4 tracks' embedded artwork, with gradient tiles for gaps.
    - Regenerated whenever the playlist changes or a member track's artwork changes (`MLM/Services/Playlists/PlaylistCoverService.swift:98-134`), and re-checked for every card each time the grid appears (`MLM/Views/Playlists/PlaylistsView.swift:79-95`).
    - A dropped image locks the cover as "custom" and stops auto-regeneration until `Reset to Auto Cover` (`MLM/Services/Playlists/PlaylistCoverService.swift:241-305`).
  - V-PL.E10 Thin determinate progress line under the cover while any member track is downloading. It shows local/total (`MLM/Views/Playlists/PlaylistCard.swift:79-88`).
  - V-PL.E11 Name (2 lines, tail truncation), or the inline rename field `Playlist name` while renaming. Return saves, Esc cancels (`MLM/Views/Playlists/PlaylistCard.swift:198-215`, `MLM/ViewModels/PlaylistViewModel.swift:199-236`).
  - V-PL.E12 Source label: `SoundCloud` / `YouTube` / `Spotify` / `Apple Music` / other, in brand colour. Tooltip `Linked to ‹Source›` (`MLM/Views/Playlists/PlaylistCard.swift:217-225, 516-529`).
  - V-PL.E13 Status chip. Either `Importing · ‹local› of ‹total›` (blue, `arrow.down.circle`) when ≥1 track is downloading, or `Incomplete · ‹n› failed` (amber, `exclamationmark.triangle`) when ≥1 track failed. Nothing when healthy **and nothing when tracks were simply never downloaded** (`MLM/Views/Playlists/PlaylistCard.swift:227-241`, `MLM/Models/Playlist.swift:155-165`).
  - V-PL.E14 `‹n› track(s)` + `Liked` (heart label) for liked playlists (`MLM/Views/Playlists/PlaylistCard.swift:244-256`).
  - V-PL.E15 Empty states (`MLM/Views/Playlists/PlaylistsView.swift:376-417`):
    - No playlists: `No Playlists Yet` / `Create your first playlist with ⌘N or the + button above.`
    - Filters active: `No Playlists Match Your Filters` / `Try clearing or adjusting your filters.`
    - Fallback: `No matching playlists` / `Try a different search term.` (effectively unreachable because filters cover search).
  - V-PL.E16 Loading placeholder `Loading playlists…`, shown only before the view model exists (`MLM/Views/Playlists/PlaylistsView.swift:51-55`).
- Interactions:
  - Single click on a card → V-PLD. Ignored while renaming (`MLM/Views/Playlists/PlaylistCard.swift:105-109`).
  - No double-click action, no keyboard focus or selection in the grid, no multi-select of playlists.
  - Right-click → CM-PL-CARD.
  - Hover → card background raised and the border darkens (`MLM/Views/Playlists/PlaylistCard.swift:93-104`).
  - Drag & drop onto a card: D-PL-TRACKS-TO-CARD, D-PL-COVER-TO-CARD, D-PL-SPRINGLOAD-CARD.
  - Keyboard: K-PL-NEW.
  - Tooltips: source label only.
- States:
  - Default: covered above.
  - Empty / filtered-empty: E15.
  - Loading: E16. Later reloads happen without a spinner.
  - Error: `PlaylistViewModel.errorMessage` is set on load, create, delete, rename and pin failures (`MLM/ViewModels/PlaylistViewModel.swift:117, 158, 171, 191, 225, 287`) but **never shown anywhere in the view**. All of these fail silently.
  - Drive not connected: not handled. Card health comes from the database (any stored path counts as "local", `MLM/Database/PlaylistRepository.swift:194-199`), so cards look healthy when the drive is gone.
  - In-progress downloads: while a download batch runs, health is polled every 250 ms and cards update live (`MLM/Views/Playlists/PlaylistsView.swift:505-547`).
  - Huge data: not a concern at today's scale (~36 playlists = 36 covers, ROADMAP §1).
- Data scale / performance notes:
  - Every refresh re-reads all playlists and runs **one track-count query per playlist** (`MLM/ViewModels/PlaylistViewModel.swift:101-108`).
  - Any `.playlistDidChange` triggers a full refresh (`MLM/Views/Playlists/PlaylistsView.swift:62-64`), and so does every `.downloadStateDidChange`.
  - When the grid appears it posts one `.playlistDidChange` per playlist (`MLM/Views/Playlists/PlaylistsView.swift:86-94`). Each post triggers a full grid refresh and a cover regeneration (ffmpeg artwork extraction for up to 4 tracks). The cover service then posts again (origin `coverService`), which triggers another refresh. With 36 playlists that is roughly 72 reloads and 36 cover jobs per visit *(inferred from code; not measured)*.
- Pain points today:
  - A linked playlist whose 44 tracks were never downloaded shows **no chip**, only `44 tracks`. The only hint is the context-menu item `Download missing (44)` (`MLM/Views/Playlists/PlaylistCard.swift:227-241, 298-308`). UI-GROUNDTRUTH §3.3 edge case ("nothing downloaded yet") is not implemented.
  - Two words for the same thing: the card says `Importing ·`, the detail header says `Downloading ·` (`MLM/Views/Playlists/PlaylistCard.swift:230` vs `MLM/Views/Playlists/PlaylistDetailView.swift:576`).
  - All grid errors are silent (see States).
  - Two ⌘N actions with different behaviour: K-PL-NEW (popover asks for a name) vs M-FILE `New Playlist` (instantly creates "Untitled Playlist", no rename; `MLM/App/MLMApp.swift:94-98, 235-242`). Repeated use creates several identically named playlists.
  - Pin wording differs: card `Pin to Top` / `Unpin` vs sidebar `Unpin from Sidebar`. UI-GROUNDTRUTH §3.2 says `Pin to Sidebar`.
  - `Sync to ▸ › Create New Profile…` does nothing: it posts `.navigateToCreateSyncProfile` and nothing observes it (`MLM/Views/Playlists/PlaylistCard.swift:336-340`; only posters exist, `MLM/Views/Library/TrackContextMenu.swift:149`).
  - Inline rename: the field is not auto-focused *(inferred: no focus binding, `MLM/Views/Playlists/PlaylistCard.swift:198-208`)*. Clicking elsewhere neither saves nor cancels. An empty name silently cancels.
  - Covers for the grid are regenerated on every visit (perf, above).
  - The count capsule shows the total, not the filtered number.
  - The grid has its own name search while the toolbar search opens the global pane: two search fields on one screen with different scopes.
- Related flows: build-playlist, import-remote-playlist (status on cards), fix-failed-downloads (`Incomplete` filter → `Show failed tracks`), sync-device (`Sync to ▸`), daily-listening, drive-unplugged.
- Constraints / locked decisions: native macOS look only; critical states as text (the chips are text, ok); English only; pin limit 8 (planning decision 10, `MLM/ViewModels/PlaylistViewModel.swift:242-265`); native playlists local-only (`.planning/REQUIREMENTS.md:176`); playlist covers live inside the `.mlibm` library file (`A0-LIBRARY-DEFINITION.md:19`).
- Open questions for the designer:
  - Should "never downloaded" be a visible card state, distinct from "failed" and "downloading"?
  - Should the grid be user-sortable (recent, size, source), or should the fixed pinned-then-A→Z order stay?
  - Should pinning mean "pin to sidebar", "pin to top of the grid", or both, and which single word should name it?
  - Grid vs list: with a few dozen playlists, is a cover grid the right primary view, or should playlists live mainly in the sidebar (as in Apple Music; `.planning/research/v1.4-daily-driver/FEATURES.md` B-T2)?
  - How should the user find out that a linked source has disconnected or expired, given no surface shows it today?
  - One search field or two on this screen?

### V-PLD — Playlist detail
- Reached via: click a card in V-PL (rendered **inside** PlaylistsView; the sidebar stays on `Playlists`, `MLM/Views/Playlists/PlaylistsView.swift:39-48`) · click a pinned row in P-PINNED (route `.playlistDetail(id)` through PlaylistDetailViewLoader, `MLM/Views/ContentView/ContentView.swift:361-368`) · `Show failed tracks` in CM-PL-CARD (opens with the failed-tracks disclosure expanded) · spring-loaded drag hover over a card or pinned row · `Open playlist` in W-REMOTE (embedded inside that window, `MLM/Views/Sources/RemotePlaylistsView.swift:64-69`) · Leads to: V-PL (back), S-PLD-LINK, S-PLD-M3U-OPEN → S-PLD-M3U-PREVIEW, A-PLD-REMOVE, CM-TRACK (playlist variant), P-PLAYER / V-QUEUE (play), P-ACTIVITY (downloads), W-SETTINGS (`Open Settings`)
- Code: `MLM/Views/Playlists/PlaylistDetailView.swift:21-866`, `MLM/Views/Playlists/PlaylistTable.swift:10-418`, `MLM/Views/Playlists/PlaylistDetailViewLoader.swift:18-73` (view); `MLM/ViewModels/PlaylistDetailViewModel.swift:10-893` (view model); `MLM/Services/Common/PlaylistTableCache.swift:12-149` (re-entry cache)
- Purpose: everything about one playlist: play it, see what is in it in its own order, see what is playable or broken and fix it, keep it in step with its source, and arrange its order.
- User goals:
  1. Play the playlist from the top or shuffled (daily).
  2. Play one track by double-click (daily).
  3. Reorder tracks by dragging; drop new tracks in at a chosen position (weekly; `.planning/REQUIREMENTS.md` PLAYLIST-05).
  4. Remove tracks from the playlist without deleting files (weekly).
  5. After a remote import: see how many tracks downloaded, which failed and why, then retry or remove them (weekly; flow fix-failed-downloads).
  6. Download tracks that were never downloaded (`Download missing (n)`) (weekly).
  7. Pull new tracks from the source (YouTube, or liked playlists) (weekly).
  8. Link a local playlist to a YouTube/SoundCloud playlist URL (rare).
  9. Import an M3U/M3U8 file (rare).
  10. Filter within the playlist by text (weekly).
- What the user wants to see, in priority order:
  1. The track list in playlist order with a playable/broken status per row.
  2. Health summary: how many of N are playable; which failed and why; how many were never downloaded.
  3. Name, cover, provenance (`Linked to YouTube · imported …`).
  4. Total size and duration (duration not shown today).
  5. When the playlist was last refreshed from its source (not shown today).
- Elements today:
  - V-PLD.E01 Back button `‹ Playlists`. It returns to the grid, or from a pinned route to the grid as well (`MLM/Views/Playlists/PlaylistDetailView.swift:375-387`, `MLM/Views/ContentView/ContentView.swift:364`). Inside W-REMOTE it returns to the remote preview while still reading "Playlists".
  - V-PLD.E02 Cover, 64 pt: cached cover PNG or a category gradient + symbol (accent gradient when linked). Not a drop target (`MLM/Views/Playlists/PlaylistDetailView.swift:393-415, 836-864`).
  - V-PLD.E03 Playlist name (hero title, 1 line). **Not editable here** (`MLM/Views/Playlists/PlaylistDetailView.swift:419-422`).
  - V-PLD.E04 Provenance line. Local: `‹n› track(s)` (tooltip `Local playlist`). Linked: `‹n› tracks · Linked to ‹Source› · imported MMM d, yyyy` (the date is the playlist's creation date) (`MLM/Views/Playlists/PlaylistDetailView.swift:425-432, 783-822`).
  - V-PLD.E05 `Play` (prominent). Plays the first **local** track, with the whole displayed list as the queue. **Hidden when no track is local** (`MLM/Views/Playlists/PlaylistDetailView.swift:465-471`).
  - V-PLD.E06 `Shuffle` (prominent, tooltip `Shuffle play playlist`). Shown under the same condition as Play. Shuffles all displayed tracks, including non-downloaded ones (`MLM/Views/Playlists/PlaylistDetailView.swift:473-486`).
  - V-PLD.E07 `Download missing (‹n›)` (bordered). Only when ≥1 track is "Not downloaded". Starts a download batch, preferring the playlist's source (`MLM/Views/Playlists/PlaylistDetailView.swift:488-498, 732-739`).
  - V-PLD.E08 `Sync` / `Syncing…` with a spinning arrow: refresh from source. Shown only when `canSync` holds: liked + has source, or `external_id` is a URL (YouTube) (`MLM/Views/Playlists/PlaylistDetailView.swift:501-515`, `MLM/ViewModels/PlaylistDetailViewModel.swift:230-391`). What it does:
    - Liked SoundCloud → SoundCloud Likes sync.
    - Liked Spotify → liked songs.
    - Apple Music → library.
    - YouTube URL → re-lists the playlist and **appends only entries whose video is not yet anywhere in the library**, as new not-downloaded tracks with album `YouTube` (`MLM/ViewModels/PlaylistDetailViewModel.swift:395-456`).
    - Nothing is removed or reordered to match upstream.
    - The only success feedback is the reloaded table. Failure → E12 `Sync failed: …`.
  - V-PLD.E09 `Link Source…` / `Change Link…` (link icon) → S-PLD-LINK. Shown for every non-liked, non-smart playlist (`MLM/Views/Playlists/PlaylistDetailView.swift:518-529`, `MLM/ViewModels/PlaylistDetailViewModel.swift:730-742`).
  - V-PLD.E10 `Import M3U…` → S-PLD-M3U-OPEN (`MLM/Views/Playlists/PlaylistDetailView.swift:532-538`).
  - V-PLD.E11 `Remove ‹n›` (destructive tint). Only while rows are selected. Removes one track at once without a prompt; for more than one it asks A-PLD-REMOVE (`MLM/Views/Playlists/PlaylistDetailView.swift:541-550, 718-730`).
  - V-PLD.E12 Red error line (warning icon + text), persists until the next successful load. Sources: load, sync, add, remove, reorder failures; M3U preview failure; `Ingest service unavailable — please restart the app` (`MLM/Views/Playlists/PlaylistDetailView.swift:441-449, 699-715`).
  - V-PLD.E13 Download status line (`MLM/Views/Playlists/PlaylistDetailView.swift:571-600`):
    - While downloading: chip `Downloading · ‹local› of ‹total›` + a determinate bar (max 180 pt).
    - If any failed: amber chip `‹failed› of ‹total› tracks failed to download` + `Show` (expands E14) + `Retry all`.
    - Nothing for never-downloaded tracks.
  - V-PLD.E14 Disclosure `Failed tracks (‹n›)`. Starts expanded when opened via `Show failed tracks` (`MLM/Views/Playlists/PlaylistDetailView.swift:602-654`).
    - Per row: `Artist — Title`; the failure reason, or `Download failed`; the retry budget `‹n› attempts left` (`MLM/Views/Shared/DownloadRetryBudget.swift:5-16`).
    - Row buttons: `Open Settings`, only when the reason text contains "open Settings" → W-SETTINGS; `Retry`; `Remove` (destructive).
    - Footer: `Retry all` · `Remove failed tracks from playlist` (destructive; >1 → A-PLD-REMOVE).
  - V-PLD.E15 Track table (native multi-select table) (`MLM/Views/Playlists/PlaylistTable.swift:42-167`):
    - Failed rows at 60 % opacity.
    - Click a header to sort; clicking `#` returns to playlist order. There is no indicator that drag-reorder is now off.
    - Columns cannot be hidden. Width and order follow SwiftUI defaults *(no column customization in code)*.
    - Columns E16–E27:
  - V-PLD.E16 `#`: 1-based position **within the currently displayed (filtered) list**. It renumbers when filtered (`MLM/Views/Playlists/PlaylistTable.swift:46-50, 278-293`).
  - V-PLD.E17 `Title`: 18 pt artwork thumbnail, an animated speaker glyph + accent colour when this track is playing (`MLM/Views/Playlists/PlaylistTable.swift:52-56, 308-328`).
  - V-PLD.E18 `Artist` (`MLM/Views/Playlists/PlaylistTable.swift:58-62`).
  - V-PLD.E19 `Album`, secondary colour. Shows source-as-album values such as `YouTube` (`MLM/Views/Playlists/PlaylistTable.swift:64-68`).
  - V-PLD.E20 `Time` (`MLM/Views/Playlists/PlaylistTable.swift:70-74`).
  - V-PLD.E21 `Format`: coloured capsule badge (FLAC/ALAC green, MP3 blue, AAC/M4A amber, OGG accent, else muted, `—` if empty). Placeholder formats like `youtube` render as `YOUTUBE` *(inferred from format strings written at `MLM/ViewModels/PlaylistDetailViewModel.swift:428-434`)* (`MLM/Views/Playlists/PlaylistTable.swift:76-80, 353-366, 232-240`).
  - V-PLD.E22 `Status`: chip `Downloading…` / `Not downloaded` / `Download failed` / `File missing`; empty when local (`MLM/Views/Playlists/PlaylistTable.swift:82-86, 368-381`, `MLM/Views/Shared/StatusChip.swift:17-34`).
  - V-PLD.E23 `Genre` (`—` when empty) (`MLM/Views/Playlists/PlaylistTable.swift:90-94`).
  - V-PLD.E24 `Year` (`MLM/Views/Playlists/PlaylistTable.swift:96-100`).
  - V-PLD.E25 `Energy`: bars (`MLM/Views/Playlists/PlaylistTable.swift:102-106`).
  - V-PLD.E26 `Dance`: steps (`MLM/Views/Playlists/PlaylistTable.swift:108-112`).
  - V-PLD.E27 `Added`: `MMM d` of the track's **library** date-added, not the date it was added to this playlist (`MLM/Views/Playlists/PlaylistTable.swift:114-118, 251-276`).
  - V-PLD.E28 Empty state (`MLM/Views/Playlists/PlaylistDetailView.swift:658-693`):
    - Empty playlist: `No Tracks` / `Add tracks from the Library via right-click → Add to Playlist,\nor import an M3U playlist file.` + button `Import M3U…`.
    - Filtered-empty: `No matching tracks`.
  - V-PLD.E29 Loading and not-found:
    - `Loading…` until the view model exists (`MLM/Views/Playlists/PlaylistDetailView.swift:68-72`).
    - Loader spinner (`MLM/Views/Playlists/PlaylistDetailViewLoader.swift:47-50`).
    - Not found: warning symbol + `Playlist not found` + `Back to Playlists` (`MLM/Views/Playlists/PlaylistDetailViewLoader.swift:35-46`).
- Interactions:
  - Double-click a row (table primary action) → plays only if the row is local; **otherwise nothing happens** (`MLM/Views/Playlists/PlaylistTable.swift:147-153`).
  - Right-click → CM-TRACK (playlist variant).
  - Multi-select (⌘/⇧-click) → `Remove ‹n›`, or context-menu actions on the selection.
  - Drag & drop: D-PLD-REORDER, D-PLD-INSERT, D-PLD-ROWS-OUT.
  - Text filter: the toolbar search field filters this playlist live, but **only when the detail was opened from a pinned sidebar row**. Opened from the grid, the section is still `Playlists`, so typing opens the global search pane over the detail (`MLM/Views/ContentView/ContentView.swift:199-211, 263-268, 326-338`; filter wiring `MLM/Views/Playlists/PlaylistDetailView.swift:76, 85-88`).
  - No in-view search field (the header doc comment's "🔍 Search  [+ Add]" is outdated, `MLM/Views/Playlists/PlaylistDetailView.swift:10`).
  - Keyboard: no Delete-key removal, no rename shortcut. Space-to-play belongs to library.md/MAIN (not wired here; see "Unresolved from code").
  - Tooltips: provenance, Shuffle.
- States:
  - Default.
  - Empty / filtered-empty (E28).
  - Loading (E29). On cache hit, rows appear instantly with no spinner (`MLM/ViewModels/PlaylistDetailViewModel.swift:147-158`).
  - Not found (E29).
  - Error (E12).
  - Importing (E13 + per-row `Downloading…` chips).
  - Incomplete (E13 + E14).
  - Never downloaded: only the `Download missing (n)` button and per-row `Not downloaded` chips. No header sentence. Play/Shuffle disappear when nothing is local.
  - Drive not connected: **not handled as such**. Every downloaded row shows the red `File missing` chip, the header shows no status line (file-missing counts as local in the summary, `MLM/Models/Playlist.swift:127-129`), and Play/Shuffle disappear. Derived from `MLM/Models/Track.swift:138-166`, `MLM/ViewModels/PlaylistDetailViewModel.swift:64-66`.
  - Source disconnected / expired: not shown until `Sync` fails with a raw error.
  - Huge playlists: availability is checked with one disk lookup per track on the main actor on every load (`MLM/ViewModels/PlaylistDetailViewModel.swift:179-191`) *(perf inferred)*.
- Data scale / performance notes:
  - The re-entry cache keeps the last 5 opened playlists (configurable 0–20 in Settings → Maintenance, ST-MAINT) (`MLM/Services/Common/PlaylistTableCache.swift:9-11, 40-43`).
  - A cache hit skips re-reading availability. The cache is invalidated only by `.playlistDidChange` for this playlist while the detail is open (`MLM/Views/Playlists/PlaylistDetailView.swift:89-112`). Downloads that finish while the user is elsewhere may therefore show stale chips on return until the next notification *(inferred)*.
- Pain points today:
  - **Import M3U… does not import into this playlist.** The target is resolved by the file's embedded UUID or its **file name**: an existing playlist with that name, else a new one (`MLM/Services/Sync/PlaylistIngestService.swift:140-174`). After `Apply` the current playlist refreshes unchanged and the alert says `Imported n tracks` while the tracks went elsewhere. A file named `Liked.m3u8` merges into a "Liked" playlist with a sentinel source.
  - `Sync` sits next to `Sync to ▸` (device sync) on the same playlist; one word, two meanings (glossary rule).
  - `Sync` is missing for SoundCloud/Spotify-linked imported playlists even though the link alert promises "Linking only changes where Sync pulls new tracks from" (`MLM/Views/Playlists/PlaylistDetailView.swift:217`; numeric external ids fail `canSync`).
  - YouTube `Sync` never adds a video that already exists in the library through another playlist (`MLM/ViewModels/PlaylistDetailViewModel.swift:417-422`). Upstream removals are never reflected. New rows get album `YouTube` (source-as-album, which `todo_dump.md` wants gone).
  - Double-click on a non-local row does nothing; UI-GROUNDTRUTH §1.6 requires a contextual action.
  - The retry budget can read `0 attempts left` while `Retry` is still offered (`MLM/Views/Shared/DownloadRetryBudget.swift:3-16`).
  - The detail behaves differently by entry route:
    - Search: the global pane opens from the grid route; the playlist filters from the pinned route.
    - Live download progress: `.downloadStateDidChange` is posted only by the grid's observer (`MLM/ViewModels/PlaylistViewModel.swift:142`), so pinned-route detail updates only when a batch finishes *(inferred)*.
  - Inside W-REMOTE, `Play` and double-click are wired to a no-op (`MLM/Views/Sources/RemotePlaylistsView.swift:64-69`).
  - No rename, delete, cover change or pin in the detail.
  - Drag-reorder is silently refused while sorted or filtered (`MLM/Views/Playlists/PlaylistTable.swift:190-194`).
  - `#` renumbers under filter. `Added` is the library date, not the playlist date.
  - The error line never clears by itself and has no action.
  - There is no "Add tracks…" entry point. A dead state variable exists (`MLM/Views/Playlists/PlaylistDetailView.swift:30`), and `PlaylistDetailViewModel.addTracks` has no caller (`MLM/ViewModels/PlaylistDetailViewModel.swift:466-489`).
  - Drive unplugged shows a wall of red `File missing` instead of one "drive not connected" message.
- Related flows: daily-listening, build-playlist, import-remote-playlist, fix-failed-downloads, sync-device, drive-unplugged, albums-future, link-playlist-source (area flow: link a local playlist to a URL), m3u-import (area flow).
- Constraints / locked decisions: one meaning per word (glossary); critical states always text (Status chips comply); failed rows dimmed with a visible retry budget (UI-GROUNDTRUTH §1.6); native playlists local-only (`.planning/REQUIREMENTS.md:176`); the user's manual order must survive temporary sorting (`.planning/research/v1.4-daily-driver/FEATURES.md` B-D6, honoured: sorting is view-only).
- Open questions for the designer:
  - Should the detail look and behave identically regardless of entry route (grid, sidebar, Remote window)?
  - Where should playlist-level actions (rename, cover, pin, delete, sync to device) live in the detail, given the context menu exists only on cards?
  - How should a playlist with 0 local / 44 never-downloaded tracks present itself: still a "Play" playlist, or a "download first" playlist?
  - "Refresh from source" vs device "Sync": what is each called, and when should refresh be offered at all (YouTube only today)?
  - Should the failed-tracks list be inside the header, inline in the table, or both? How should "0 attempts left" read?
  - What should `#` mean under sorting and filtering, and how should the UI signal that drag-reorder is off?
  - Should "Added" mean "added to this playlist" (the data exists in `playlist_tracks.added_at`)?
  - How should M3U import target be communicated — into this playlist, or "import as playlist" at grid level?

### V-FOLD — Folders (disk folder browser)
- Reached via: sidebar `Folders` (P-SIDEBAR) · ⌘3 (`MLM/Views/ContentView/ContentView.swift:617-622`) · Leads to: Finder (`Show in Finder`), CM-TRACK, P-PLAYER (double-click), V-LIB (after `Import`), V-PL / V-PLD (via drag spring-loading)
- Code: `MLM/Views/Folders/FoldersView.swift:6-527` (view), `MLM/Views/Folders/FoldersView.swift:531-809` (tables), `MLM/Views/Folders/FolderTreeView.swift:8-125` (tree), `MLM/ViewModels/FolderViewModel.swift:10-610` (view model), `MLM/Services/Folders/DiskFolderScanner.swift:32-174`, `MLM/Services/Common/ManagedLibraryLayout.swift:5-21`
- Purpose: browse the music as it is laid out on disk under the library folder. See which folders MLM manages, what tracks sit in a folder, and catch files on disk that are not in the library. Folders here are filesystem directories, not playlist folders (see top of file).
- User goals:
  1. Navigate the on-disk structure (artist / set / download folders) to find and play music the way it is organised on disk (daily; the daily-driver loop "folder explorer", `.planning/PROJECT.md:38`).
  2. Find a folder by name (weekly).
  3. Import files that were dropped into a folder outside MLM (weekly).
  4. Reveal a folder in Finder (weekly).
  5. Drag tracks from a folder into a playlist (weekly; build-playlist).
  6. Tell MLM-managed download folders apart from personal folders (rare).
- What the user wants to see, in priority order:
  1. The folder hierarchy with the current location.
  2. Tracks in the selected folder with playable status.
  3. Subfolders.
  4. Unindexed files warning.
  5. Managed vs personal.
  6. Counts per folder (not shown today; wish `.planning/REQUIREMENTS.md` BROWSE-05).
- Elements today:
  - V-FOLD.E01 Title `Folders` + count capsule = number of **top-level** folders only (`MLM/Views/Folders/FoldersView.swift:86-96`, `MLM/ViewModels/FolderViewModel.swift:123-124`).
  - V-FOLD.E02 Filter field `Filter folders…` + clear. A disk search of **folder names** under the library folder, 200 ms debounce, **silently capped at 200 results** (`MLM/Views/Folders/FoldersView.swift:100-132`, `MLM/ViewModels/FolderViewModel.swift:424-470`, `MLM/Services/Folders/DiskFolderScanner.swift:118-121`). It also reshapes the tree to show only the matching branches (`MLM/ViewModels/FolderViewModel.swift:472-525`).
  - V-FOLD.E03 Window toolbar item `‹n› folders`, a duplicate of E01 (`MLM/Views/Folders/FoldersView.swift:73-79`).
  - V-FOLD.E04 Folder tree, left pane, resizable 180–360 pt (`MLM/Views/Folders/FoldersView.swift:140-148`, `MLM/Views/Folders/FolderTreeView.swift:24-53`). Two sections:
    - `MANAGED BY MLM` — only top-level `Downloads (SoundCloud)`, `Downloads (YouTube)`, `Transcode originals` (`MLM/Services/Common/ManagedLibraryLayout.swift:6-14`).
    - An unlabeled section with all other folders.
    - Children load lazily when expanded. Selecting a deep folder expands its parents.
  - V-FOLD.E05 Tree row (`MLM/Views/Folders/FolderTreeView.swift:55-93`):
    - Icon: `arrow.down.circle` in accent for managed folders, `folder` otherwise. Name, 1 line. Tooltip `Created and maintained by MLM` for managed folders.
    - A small spinner row while children load.
    - Click selects; double-click toggles expand. Right-click → CM-FOLD-TREE.
  - V-FOLD.E06 Search results (right pane while filtering) (`MLM/Views/Folders/FoldersView.swift:154-207, 745-809`):
    - Header `Search results for "‹q›"` + spinner + `‹n› folders found`.
    - Table `Name` · `Subfolders` · `Path` (relative).
    - States: `Searching…`, or the system "No Results for ‹q›" view.
    - Double-click opens the folder and clears the search. Right-click → CM-FOLD-SEARCHRESULT.
  - V-FOLD.E07 Breadcrumb bar (`MLM/Views/Folders/FoldersView.swift:408-460`): folder icon + clickable path segments relative to the library folder, `‹n› Tracks`, and an icon-only `Show in Finder` button (`arrow.right.circle`, tooltip only).
  - V-FOLD.E08 Unindexed-files banner (amber tint) (`MLM/Views/Folders/FoldersView.swift:222-240, 520-525`):
    - Text `‹n› files in this folder are not in the library` + button `Import`.
    - The count covers only audio files **directly** in this folder (`MLM/ViewModels/FolderViewModel.swift:275-291`), but `Import` imports the folder **recursively** (`MLM/Services/Import/ImportService.swift:12-21, 135-141`).
    - No progress, no result, errors swallowed, and the button stays enabled during the import.
  - V-FOLD.E09 `Subfolders` section (`MLM/Views/Folders/FoldersView.swift:256-287, 320-352, 675-741`):
    - Header + count capsule + spinner while loading.
    - Table `Name` · `Subfolders` · `Path`. The `Subfolders` count reads `1` for folders whose children have not loaded yet, because the loading placeholder is counted (`MLM/Views/Folders/FoldersView.swift:709-713`, placeholder `MLM/Services/Folders/DiskFolderScanner.swift:77`).
    - Double-click opens the folder; right-click → CM-FOLD-SUBFOLDER.
  - V-FOLD.E10 `Tracks` section (`MLM/Views/Folders/FoldersView.swift:289-317, 354-383, 531-671`):
    - Header + count capsule. Tracks sit directly in the folder (non-recursive).
    - Columns `Title` (speaker glyph when playing) · `Artist` · `Album` · `Time` · `Format` (plain text) · `Source` · `Status` (chip) · `kbps` · `Energy` · `Dance`. Default sort Title A→Z; headers sortable.
    - Multi-select; rows draggable (D-FOLD-TRACKS-OUT); right-click → CM-TRACK (library variant).
    - Double-click plays with the folder rows as the queue, **without checking availability** (`MLM/Views/Folders/FoldersView.swift:647-652`).
    - When a folder has both subfolders and tracks, the two sections stack in a resizable vertical split (`MLM/Views/Folders/FoldersView.swift:253-318`).
  - V-FOLD.E11 Pane placeholders:
    - Nothing selected: folder symbol + `Select a folder` / `Select a folder from the tree on the left to view its tracks.` (`MLM/Views/Folders/FoldersView.swift:387-403`).
    - Empty folder: `Folder is empty` / `This folder contains no music tracks or subfolders.` (`MLM/Views/Folders/FoldersView.swift:242-252`).
  - V-FOLD.E12 Full-pane states:
    - `Loading folders…` (`MLM/Views/Folders/FoldersView.swift:20`).
    - `Loading folder structure…` (`MLM/Views/Folders/FoldersView.swift:472-481`).
    - `Drive not connected` / `The external drive containing the music library is not connected.` (`MLM/Views/Folders/FoldersView.swift:464-470`).
    - `No folders` / `Import music to view the folder structure.`, or the system search-empty view (`MLM/Views/Folders/FoldersView.swift:483-495`).
- Interactions:
  - Tree: click / double-click.
  - Tables: sort by header; double-click = primary action.
  - Breadcrumb segments navigate.
  - Right-click → CM-FOLD-TREE, CM-FOLD-SUBFOLDER, CM-FOLD-SEARCHRESULT, CM-TRACK.
  - Drag: D-FOLD-TRACKS-OUT.
  - Keyboard: no area shortcut. A "focus folder filter" notification is observed but nothing posts it (`MLM/Views/Folders/FoldersView.swift:45-47`; `MLM/Utilities/Notifications.swift:109`).
  - The selected folder is remembered across visits and launches, per library folder (`MLM/ViewModels/FolderViewModel.swift:15-67`).
- States:
  - Default.
  - Loading (E12).
  - Empty: also shown when **no library folder is configured** (misleading copy: "Import music…") (`MLM/ViewModels/FolderViewModel.swift:203-209`).
  - Drive not connected (E12). There is no retry; it refreshes only on the next visit or a library import.
  - Search empty / searching (E06).
  - Error: `errorMessage` is set but never displayed (`MLM/ViewModels/FolderViewModel.swift:228, 310`). Scan and track-load failures look like an empty folder.
  - Huge folders: flat managed folders (e.g. `Downloads (SoundCloud)`) can hold thousands of tracks. One query per selection matches files by path (`MLM/ViewModels/FolderViewModel.swift:259-266`).
- Data scale / performance notes:
  - ~12,935 tracks overall (ROADMAP §1).
  - The tree loads one level at a time with placeholders.
  - Search walks the whole disk tree and caps at 200.
  - Audio files directly in the library folder root are **not reachable**: the root itself is not a selectable node (`MLM/ViewModels/FolderViewModel.swift:224-226`; the tree shows only subdirectories).
- Pain points today:
  - Errors are invisible; empty and failed look the same.
  - The `Import` banner count and import scope differ (direct vs recursive), with no progress or result.
  - Both the count capsule and the toolbar item show only top-level folders, twice.
  - The `Subfolders` count shows `1` for unloaded folders.
  - No per-folder track counts in the tree.
  - Folder search finds folder names only, not tracks, and silently stops at 200.
  - Double-click on a not-downloaded or missing track in a folder tries to play it anyway (contrast with V-PLD, which refuses silently).
  - Root-level files are unreachable.
  - UI-GROUNDTRUTH §3.4 "`512 tracks · Managed by MLM`" summary line is not implemented.
  - No relation to playlists other than dragging tracks out. There is no "make a playlist from this folder".
  - The `Format` column differs from V-PLD (plain text vs coloured badge); the column sets of the three track tables (Library / Playlist / Folder) differ.
- Related flows: organize-folders, daily-listening, build-playlist, drive-unplugged, find-fast.
- Constraints / locked decisions: native look; `Managed by MLM` is a glossary term; managed folders are created lazily by downloads, never at launch (`MLM/Services/Common/ManagedLibraryLayout.swift:3-4`); `Library folder` is the glossary term for the root; logical folders/collections deferred (`.planning/REQUIREMENTS.md:236-241`).
- Open questions for the designer:
  - Should Folders stay a separate section, or be a mode of Library?
  - Should the tree show track counts and download status per folder?
  - Should "managed by MLM" be a section or a badge?
  - How should playlist folders (wish) and disk folders be named apart, if both exist?
  - What should the Import banner promise (this folder only, or including subfolders), and where should its progress and result appear?
  - How should root-level files be reachable?
  - Should folder search also find tracks?

## Context menus

### CM-PL-CARD — Playlist card context menu
- Where: every card in V-PL · `MLM/Views/Playlists/PlaylistCard.swift:110-112, 263-355`
- Items, verbatim, in order:
  1. `Open` → V-PLD.
  2. — separator —
  3. `Rename…` → inline rename on the card (V-PL.E11). Saves on Return; posts `.playlistDidChange` (`MLM/ViewModels/PlaylistViewModel.swift:206-229`).
  4. `Pin to Top` (when unpinned) / `Unpin` (when pinned) → toggles pin. The 9th pin is hard-blocked → S-PL-BANNER-PINLIMIT. Success re-sorts the grid and refreshes the sidebar P-PINNED (`MLM/ViewModels/PlaylistViewModel.swift:250-289`).
  5. `Reset to Auto Cover`, **only when the cover is custom** → clears the lock, deletes the PNG, regenerates (`MLM/Services/Playlists/PlaylistCoverService.swift:283-305`).
  6. `Download missing (‹n›)`, only when ≥1 track was never downloaded → starts a download batch for those tracks, preferring the playlist's source (`MLM/Views/Playlists/PlaylistsView.swift:642-652`).
  7. `Show failed tracks`, only when ≥1 failed → opens V-PLD with E14 expanded.
  8. — separator —
  9. Section with submenu `Sync to ▸` (the label text includes a literal "▸"). Inside:
     - With no profiles: disabled text `No sync profiles. Create one first.`
     - Otherwise: one item per sync profile name, then a separator.
     - Then `Create New Profile…`.
     - Choosing a profile selects it in the Sync view model and adds the playlist to it, with **no confirmation or feedback** (`MLM/Views/Playlists/PlaylistsView.swift:611-616`).
     - `Create New Profile…` posts `.navigateToCreateSyncProfile`, which **nothing observes**, so the item does nothing.
  10. — separator —
  11. `Delete Playlist` (destructive), **hidden for liked playlists** → A-PL-DELETE.
- Not present: duplicate, export, show in Finder, set cover from file (only drag), sort, `Add to …`.

### Uses of CM-TRACK in V-PLD (playlist variant; menu owned by library.md)
- Where: V-PLD.E15 · `MLM/Views/Playlists/PlaylistTable.swift:130-146` → `MLM/Views/Library/TrackContextMenu.swift:59-68`
- Difference from the Library variant: a first section `Remove from Playlist` (destructive; suffix ` (‹n› tracks)` for multi-selection, `MLM/Views/Library/TrackContextMenu.swift:54, 64`), then a separator, then the standard items. Removing 1 track is immediate; removing more asks A-PLD-REMOVE (`MLM/Views/Playlists/PlaylistDetailView.swift:563-565, 718-730`).
- `Sync to ▸` on rows adds the **tracks** to a profile (`MLM/Views/Playlists/PlaylistTable.swift:136-141`).
- The menu also lists `Add to Playlist ▸`, including the current playlist; re-adding is silently ignored (`MLM/Database/PlaylistRepository.swift:273-305`).

### Uses of CM-TRACK in V-FOLD (folder variant; menu owned by library.md)
- Where: V-FOLD.E10 · `MLM/Views/Folders/FoldersView.swift:634-646`. The standard library menu, without a playlist section.

### CM-FOLD-TREE — Folder tree row
- Where: V-FOLD.E05 · `MLM/Views/Folders/FolderTreeView.swift:87-91`
- Items: `Show in Finder` → reveals the folder in Finder. Only one item; there is no "Import this folder", "Make playlist", "Expand all" etc.

### CM-FOLD-SUBFOLDER — Subfolders table row
- Where: V-FOLD.E09 · `MLM/Views/Folders/FoldersView.swift:726-737`
- Items: `Show in Finder` (first selected row only; the table is single-select). Primary action (double-click) opens the folder.

### CM-FOLD-SEARCHRESULT — Folder search results row
- Where: V-FOLD.E06 · `MLM/Views/Folders/FoldersView.swift:796-807`
- Items: `Show in Finder`. Primary action opens the folder and clears the search.

## Sheets, popovers, panels, alerts

### S-PL-NEWPLAYLIST — New Playlist popover
- Trigger: V-PL.E05 button or ⌘N while V-PL is visible (K-PL-NEW). The popover hangs below the button · `MLM/Views/Playlists/PlaylistsView.swift:246-248, 307-352`
- Content: title `New Playlist`; text field placeholder `Playlist name`.
- Buttons:
  - `Cancel` (Esc, K-PL-NEWPOPOVER-ESC) closes.
  - `Create` (Return, default, K-PL-NEWPOPOVER-RETURN; disabled while the name is blank) → creates a local playlist, inserts it in A→Z position, posts `.playlistDidChange`, closes. The user **stays in the grid**; the new playlist is not opened (`MLM/ViewModels/PlaylistViewModel.swift:155-176`).
  - Pressing Return in the field also creates. A blank name sets a hidden error and closes.
- Errors: not shown (no error line, though UI-GROUNDTRUTH §3.17 asks for one).
- Duplicate names allowed.

### A-PL-DELETE — Delete playlist confirmation
- Trigger: CM-PL-CARD `Delete Playlist` · `MLM/Views/Playlists/PlaylistsView.swift:96-114`
- Content: title `Delete playlist?`; message `Delete “‹name›”? Its music files will remain in your library.`
- Buttons: `Delete Playlist` (destructive) → deletes the playlist and its memberships, sync-profile links and snapshots (`MLM/Database/PlaylistRepository.swift:88-101`); `Cancel`.
- Errors: silent (V-PL error not displayed).
- No undo.
- Copy differs from UI-GROUNDTRUTH §3.17 (`This does not delete any files.`).

### S-PL-BANNER-PINLIMIT — Pin-limit banner (inline panel)
- Trigger: pinning a 9th playlist · `MLM/Views/Playlists/PlaylistsView.swift:124-129, 421-451`, `MLM/ViewModels/PlaylistViewModel.swift:254-265`
- Content: warning bar + triangle + `Pin limit reached (8). Unpin one first.` Slides in under the header and pushes the grid down. Auto-dismisses after 3 s. No buttons. Not shown when pinning from elsewhere (only the grid pins).

### S-PL-BANNER-COVERDROP — Cover drop rejected banner (inline panel)
- Trigger: dropping something with no image or file data on a card · `MLM/Views/Playlists/PlaylistsView.swift:131-136, 456-480`, `MLM/ViewModels/PlaylistViewModel.swift:298-304`
- Content: `Couldn't read that image. Try a PNG or JPEG file.` Auto-dismisses after 4 s.
- A Finder file that is **not** an image (e.g. a .txt) passes the first check and then fails silently in the cover service; no banner (`MLM/Views/Playlists/PlaylistCard.swift:449-462`, `MLM/Services/Playlists/PlaylistCoverService.swift:248-256`).

### S-PLD-LINK — Link Playlist Source sheet
- Trigger: V-PLD.E09 `Link Source…` / `Change Link…` · `MLM/Views/Playlists/PlaylistDetailView.swift:198-200, 266-367`; logic `MLM/ViewModels/PlaylistDetailViewModel.swift:712-891`
- Content:
  - Title (link icon) `Link Playlist Source`.
  - Subtitle `Paste a YouTube or SoundCloud playlist URL to link this playlist to a remote source.`
  - URL field with placeholder `https://youtube.com/playlist?list=… or https://soundcloud.com/…/sets/…`. Prefilled only when the current link is a URL. Disabled while checking.
  - Phase line:
    - `Checking link…` + spinner.
    - Failure in red, one of:
      - `Enter a playlist URL.`
      - `That doesn't look like a YouTube or SoundCloud playlist link.`
      - `SoundCloud is not connected — sign in in Settings first.` (no button to open Settings)
      - provider error text.
      - `Nothing to commit.`
    - Validated: `Remote playlist “‹title›” · ‹n› tracks` plus either `Differs: ‹a› track(s) only remote, ‹b› only local.` (amber) or `Matches the tracks in this playlist.`
- Buttons: `Cancel` (disabled while checking) · spinner · `Check` (prominent; disabled while empty or checking).
- Editing the URL resets the phase.
- If valid and the tracks match → commits immediately, closes, → A-PLD-LINKDONE. If they differ → A-PLD-LINKMISMATCH.
- Linking writes only the source reference; **no tracks are added or removed**.
- Size 440–520 × 240–340 pt.

### A-PLD-LINKMISMATCH — "Different tracks"
- Trigger: a validated link with differences · `MLM/Views/Playlists/PlaylistDetailView.swift:201-219`
- Message: `The remote playlist has ‹a› track(s) this playlist doesn't, and this playlist has ‹b› track(s) the remote doesn't. Linking only changes where Sync pulls new tracks from — nothing is added or removed now.`
- Buttons: `Cancel` (cancel; resets the check, sheet stays) · `Link Anyway` → commits, closes the sheet, → A-PLD-LINKDONE. On failure the sheet shows the error.

### A-PLD-LINKDONE — "Link Updated"
- Trigger: successful commit · `MLM/Views/Playlists/PlaylistDetailView.swift:220-226`
- Message `Linked to ‹remote title›`. Button `OK`.

### S-PLD-M3U-OPEN — M3U file chooser (system open panel)
- Trigger: V-PLD.E10 or the E28 `Import M3U…` · `MLM/Views/Playlists/PlaylistDetailView.swift:134-146`
- Allowed types `.m3u`, `.m3u8`; single file.
- On success → builds a preview, then S-PLD-M3U-PREVIEW. If the preview fails, the error goes to V-PLD.E12 (`Failed to load preview: …`, `MLM/ViewModels/PlaylistIngestViewModel.swift:51-63`).
- Cancel: nothing happens.

### S-PLD-M3U-PREVIEW — Import Playlist preview sheet (component shared with sync.md device ingest)
- Trigger: a valid M3U preview · `MLM/Views/Playlists/PlaylistDetailView.swift:147-177`; component `MLM/Views/Sync/IngestPreviewView.swift:11-255`; state `MLM/ViewModels/PlaylistIngestViewModel.swift:12-102`
- Content:
  - Title `Import Playlist`, `From ‹file name›`.
  - Target block: the target playlist name + `Will create new playlist` or `Existing playlist`.
  - Summary chips `Added` / `Removed` / `Reordered` / `Unresolved`, then lists `Added (n)`, `Removed (n)`, `Reordered (n)`, `Unresolved (n)`.
  - Red error box on apply failure (`Failed to apply: …`).
- Buttons: `Cancel` (disabled while applying) · spinner · `Create & Import` (new target) or `Apply` (existing target), prominent; disabled while applying or when nothing would change.
- Success → closes, → A-PLD-IMPORTDONE, posts `.playlistDidChange` for the **target** playlist.
- **The target is chosen by file UUID or file name, not by the playlist the user is in** (see V-PLD pain points). A standalone import always appends (sentinel profile −1).

### A-PLD-IMPORTDONE — "Import Complete"
- Trigger: M3U apply success · `MLM/Views/Playlists/PlaylistDetailView.swift:188-197`
- Message `Imported ‹n› track(s)` (= the `Added` count). Button `OK`. It does not say **which playlist** received them.

### A-PLD-REMOVE — "Remove tracks"
- Trigger: removing more than 1 track via `Remove ‹n›`, CM-TRACK `Remove from Playlist (n tracks)`, or `Remove failed tracks from playlist` · `MLM/Views/Playlists/PlaylistDetailView.swift:178-187, 718-730`
- Message `Remove ‹n› tracks from this playlist? This does not delete any files.`
- Buttons: `Cancel` (cancel) · `Remove` (destructive) → removes, reloads, posts `.playlistDidChange` (`MLM/ViewModels/PlaylistDetailViewModel.swift:495-517`).
- Single-track removal has **no** confirmation and no undo.

### Inline panel (not a separate ID): Failed tracks disclosure
- See V-PLD.E14 (`MLM/Views/Playlists/PlaylistDetailView.swift:602-654`).

### Expected, missing
- Rename playlist from the detail.
- Choose a cover image via a file dialog (only drag & drop exists).
- Export playlist (M3U) from the grid or detail. Only device sync writes M3U; not in this area.
- "Add tracks…" picker from the detail (there is a dead `showAddFromLibrary` state, `MLM/Views/Playlists/PlaylistDetailView.swift:30`).
- Delete-confirmation path for liked playlists that explains why delete is unavailable (UI-GROUNDTRUTH §3.2).

## Menu items & keyboard shortcuts (area-local)

- **K-PL-NEW** — ⌘N · button `New Playlist` · scope: only while V-PL's grid is on screen · opens S-PL-NEWPLAYLIST · `MLM/Views/Playlists/PlaylistsView.swift:243`. **Conflict:** M-FILE `New Playlist` is also ⌘N and instead creates "Untitled Playlist" directly and navigates to the grid (`MLM/App/MLMApp.swift:94-98, 235-242`). Which one wins while the grid is focused is not determinable from code ("Unresolved from code").
- **K-PL-NEWPOPOVER-ESC** — Esc · `Cancel` in S-PL-NEWPLAYLIST · `MLM/Views/Playlists/PlaylistsView.swift:332`.
- **K-PL-NEWPOPOVER-RETURN** — Return · `Create` in S-PL-NEWPLAYLIST (default action) · `MLM/Views/Playlists/PlaylistsView.swift:344` (also `onSubmit` 319-324).
- **K-PL-RENAME** — Return saves / Esc cancels the inline card rename · `MLM/Views/Playlists/PlaylistCard.swift:207-208`.
- Table primary action (V-PLD.E15, V-FOLD tables) — double-click (and Return for focused rows, per standard SwiftUI table behaviour *(inferred)*) · `MLM/Views/Playlists/PlaylistTable.swift:147-153`, `MLM/Views/Folders/FoldersView.swift:647-652, 732-737, 802-807`.
- Navigation shortcuts ⌘2 (Playlists) and ⌘3 (Folders) belong to M-NAVIGATE (shell.md) (`MLM/Views/ContentView/ContentView.swift:617-622`).
- Expected, missing: Delete/⌫ to remove selected tracks from a playlist; ⌘R / Return to rename a playlist; keyboard navigation between cards; a shortcut to focus the folder filter (the receiving notification exists but nothing posts it, `MLM/Views/Folders/FoldersView.swift:45-47`); ⌘F in Playlists/Folders.

## Drag & drop

- **D-PL-TRACKS-TO-CARD** — source: track rows from V-LIB (library.md), V-PLD, V-FOLD, or the Library table in another window · target: a playlist card in V-PL · payload `com.musiclibrary.trackdrag` (TrackDragData JSON: trackId + sourcePlaylistId, `MLM/Models/Track.swift:364-377`) · result: tracks are appended after the playlist's last track, already-present tracks are ignored, `.playlistDidChange` posted, grid reloaded (`MLM/Views/Playlists/PlaylistCard.swift:410-441`, `MLM/Views/Playlists/PlaylistsView.swift:617-641`). Feedback: accent border 2 pt while hovering; nothing after the drop (no toast or highlight; wish PLAYLIST-04, `.planning/REQUIREMENTS.md:212`); errors only logged. Practical reach: the user drags from Library/Folders, hovers the sidebar `Playlists` row 0.6 s (spring-load to the grid), then drops on a card.
- **D-PL-COVER-TO-CARD** — source: an image file from Finder, or an image dragged from another app · target: a playlist card · payload `public.file-url` or `public.image` · result: the image is centre-cropped to 512×512, saved as the playlist cover and **locked as custom** (no more auto-regeneration) (`MLM/Views/Playlists/PlaylistCard.swift:443-487`, `MLM/Services/Playlists/PlaylistCoverService.swift:242-280`). Feedback: accent border; on reject → S-PL-BANNER-COVERDROP. An unreadable file URL fails silently. Undo = CM-PL-CARD `Reset to Auto Cover`.
- **D-PL-SPRINGLOAD-CARD** — hovering a track drag over a card for 0.6 s opens that playlist's detail mid-drag, so the user can drop at a precise position (D-PLD-INSERT) (`MLM/Views/Playlists/PlaylistCard.swift:116-130`, wiring `MLM/Views/Playlists/PlaylistsView.swift:590-593`). Also fires for cover-image drags (the timer does not check the payload type) *(inferred)*. Sidebar spring-loading (Playlists row and pinned rows) is P-SIDEBAR / P-PINNED (main.md), `MLM/Views/Shared/SpringLoadableHover.swift:10-57`.
- **D-PLD-REORDER** — source: rows of V-PLD.E15 (multi-row) · target: a gap in the same table (native insertion line) · payload TrackDragData · result: rows are moved to the insertion point in drag order and the new order is saved; optimistic, no flicker (`MLM/Views/Playlists/PlaylistTable.swift:120-128, 171-218`, `MLM/ViewModels/PlaylistDetailViewModel.swift:558-666`). Only allowed in `#` ascending order with no text filter; otherwise the drop is **silently ignored**.
- **D-PLD-INSERT** — source: track rows from elsewhere (Library, Folders, another playlist) arriving via spring-load · target: a gap in V-PLD.E15 · result: tracks are inserted at that position (moved if already members). Allowed even while sorted or filtered (the position is mapped back to playlist order) (`MLM/Views/Playlists/PlaylistTable.swift:184-197`).
- **D-PLD-ROWS-OUT** — rows in V-PLD are draggable carrying their source playlist id (`MLM/Views/Playlists/PlaylistTable.swift:123`). Dropped on another playlist card they are **added** (copied), not moved; the source playlist id is not used by any target *(no consumer of `sourcePlaylistId` found in the drop handlers)*.
- **D-FOLD-TRACKS-OUT** — rows of V-FOLD.E10 are draggable (`MLM/Views/Folders/FoldersView.swift:629-632`). They reach playlists via sidebar spring-load → D-PL-TRACKS-TO-CARD / D-PLD-INSERT. Folders and subfolder rows themselves are **not** draggable.
- Expected, missing (evidence: Apple Music behaviour cited in `.planning/research/v1.4-daily-driver/FEATURES.md` B-T8/B-D2/B-D7, `.planning/REQUIREMENTS.md` PLAYLIST-03/04):
  - **D-PL-TRACKS-TO-PINNED (missing)** — dropping tracks directly on a pinned sidebar playlist adds them. Today pinned rows only spring-load (`MLM/Views/Shared/SpringLoadableHover.swift:36-40` returns `false`).
  - **D-PL-SELECTION-TO-NEW (missing)** — drop a selection on the sidebar or grid background to create a new playlist from it.
  - **D-PL-PLAYLIST-TO-FOLDER (missing)** — group playlists into playlist folders; no playlist folders exist.
  - **D-PL-CARD-REORDER (missing)** — arrange cards or pinned playlists manually.
  - **D-PLD-COVER-TO-HEADER (missing)** — drop an image on the 64 pt detail cover.
  - **D-PLD-M3U-FROM-FINDER (missing)** — drop an .m3u/.m3u8 file on the grid or detail.
  - **D-FOLD-FOLDER-TO-PLAYLIST (missing)** — drag a disk folder onto a playlist to add all its tracks.
  - **D-FOLD-FILES-FROM-FINDER (missing)** — drop audio files on a folder to import them.
  - **D-PLD-ROWS-TO-FINDER (missing)** — drag tracks out to Finder or another app as files.

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Drive not connected (library folder unreachable):**
  - V-FOLD shows a full-pane `Drive not connected` (`MLM/Views/Folders/FoldersView.swift:62-63, 464-470`; detection `MLM/ViewModels/FolderViewModel.swift:213-220`). No retry button; it re-checks only on re-entry or `.libraryDidImport`.
  - V-PL shows nothing; cards look healthy because SQL health ignores file existence (`MLM/Database/PlaylistRepository.swift:194-199`).
  - V-PLD marks every downloaded row `File missing` (red), shows no header status, and hides Play/Shuffle (`MLM/Models/Track.swift:142-166`, `MLM/Models/Playlist.swift:127-129`, `MLM/ViewModels/PlaylistDetailViewModel.swift:64-66`). It re-checks on `.libraryRootDidChange` (`MLM/Views/Playlists/PlaylistDetailView.swift:119-121`) but not on drive re-mount.
- **No library folder configured:** V-FOLD shows `No folders` / `Import music to view the folder structure.` (`MLM/ViewModels/FolderViewModel.swift:203-209`). In V-PLD, relative paths are treated as local (`MLM/Views/Shared/TrackPresentationAvailability.swift:14-22`).
- **Library loading / failed:** V-PL and V-PLD render only once the container's repositories exist; otherwise they stay on `Loading playlists…` / `Loading…` forever *(inferred: `initializeViewModel` bails silently, `MLM/Views/Playlists/PlaylistsView.swift:484-492`, `MLM/Views/Playlists/PlaylistDetailView.swift:768-781`)*. The loader shows `Playlist not found` when the repository is missing (`MLM/Views/Playlists/PlaylistDetailViewLoader.swift:56-59`).
- **Source disconnected / expired:**
  - Not represented on the card or in the header.
  - Surfaces only as `Sync failed: ‹raw error›` (V-PLD.E12), as per-track failure reasons in E14 (with `Open Settings` when the reason text says so), or in S-PLD-LINK as `SoundCloud is not connected — sign in in Settings first.`
  - UI-GROUNDTRUTH §1.6 "Linked, source disconnected" status is not implemented.
- **Background processing:** download batches update card chips live via polling (`MLM/Views/Playlists/PlaylistsView.swift:505-547`); see "Background work touchpoints".
- **Track availability states:** all five appear as text chips in V-PLD.E22 and V-FOLD.E10 Status (`MLM/Views/Shared/StatusChip.swift:17-34`). Failed rows are dimmed in V-PLD only. Playlist-level aggregates: `Importing · n of m` / `Incomplete · n failed` (card), `Downloading · n of m` / `n of m tracks failed to download` (header).
- **Library switch:** the covers directory follows the open library file (`MLM/Views/Playlists/PlaylistCard.swift:390-395`). The folder selection is stored relative to the library folder and resets when it changes (`MLM/ViewModels/FolderViewModel.swift:139-149`).

### Background work touchpoints

- **Downloads** (DownloadViewModel batches):
  - Started from: CM-PL-CARD `Download missing (n)`, V-PLD.E07, E13/E14 `Retry all` / `Retry`.
  - Progress: card chip + 2 pt bar (V-PL.E10/E13), header chip + bar (V-PLD.E13), per-row `Downloading…` chips, and P-ACTIVITY (activity.md).
  - Result: failures in E14 with reason and retry budget. **No completion message** in this area.
  - Control: no cancel from this area (cancel lives in P-ACTIVITY). The buttons are not disabled while a batch runs *(the track context menu does disable, `MLM/Views/Library/TrackContextMenu.swift:57`)*.
- **Refresh from source** (V-PLD.E08): spinner + `Syncing…` label on the button. No progress count, no cancel, no result count (`newTracks` is only posted as `.libraryDidImport`, `MLM/ViewModels/PlaylistDetailViewModel.swift:370-377`).
- **Link check** (S-PLD-LINK): `Checking link…` spinner; no cancel during the check (Cancel is disabled).
- **M3U ingest:** preview runs before the sheet without a visible spinner *(inferred: no state shown between file choice and sheet)*; apply shows a sheet spinner.
- **Cover generation** (PlaylistCoverService): invisible. Covers swap in when ready; failures are logged only (`MLM/Services/Playlists/PlaylistCoverService.swift:231-238`). It runs ffmpeg artwork extraction for up to 4 tracks per playlist on every grid visit.
- **Folder scanning / search:** tree child spinners (V-FOLD.E05), section spinners (E09), `Searching…` (E06).
- **Folder import** (V-FOLD.E08 `Import`): **no progress, no result, no Activity entry, errors swallowed** (`MLM/Views/Folders/FoldersView.swift:520-525`). It is recursive.
- **Device sync:** `Sync to ▸` on a card or rows adds the item to a sync profile silently; actual syncing is V-SYNC (sync.md).
- **Remote playlist import** (W-REMOTE, sources-review.md): creates a linked playlist, whose download status then shows on V-PL/V-PLD.

### Flow notes

- **build-playlist**
  1. V-PL → `New Playlist` (or ⌘N) → S-PL-NEWPLAYLIST: name it, `Create`. The user stays in the grid; the new card appears in A→Z position (it is not opened or highlighted).
  2. Go to V-LIB or V-FOLD, select tracks, then either:
     - (a) right-click → CM-TRACK `Add to Playlist ▸ ‹name›` (library.md); no confirmation feedback in this area; or
     - (b) drag the selection to the sidebar `Playlists` row, hold 0.6 s → V-PL, then either drop on the card (D-PL-TRACKS-TO-CARD; appended, no feedback) or hold 0.6 s more → V-PLD opens → drop at a position (D-PLD-INSERT).
  3. In V-PLD, reorder by dragging (D-PLD-REORDER; only in `#` order with no filter).
  4. Remove mistakes (CM-TRACK `Remove from Playlist`, `Remove ‹n›`).

  Breaks:
  - No "Add tracks…" from inside the detail; the user must leave it.
  - There is no direct drop on pinned sidebar playlists.
  - Spring-load needs two timed hovers.
  - File → New Playlist ⌘N creates "Untitled Playlist" with no rename prompt.
  - No total duration while building.
  - Wish: bulk "Add to playlist…" in the batch bar, recent-first (`.planning/REQUIREMENTS.md` BULK-01/02).
- **organize-folders**
  1. V-FOLD → expand the tree (E04) or filter by name (E02).
  2. Select a folder → breadcrumb, subfolders, tracks.
  3. Play or drag tracks out.
  4. If the banner says files are missing from the library → `Import`.
  5. `Show in Finder` to reorganise on disk.

  Breaks:
  - Reorganising (move/rename folders) is impossible in MLM; it is Finder-only.
  - After a Finder change, V-FOLD does not notice until re-entry *(no file watching found)*.
  - There are no playlist folders at all: "organize playlists into folders" has no surface.
  - Root-level files are unreachable.
  - Errors are invisible.
- **import-remote-playlist**
  1. The import happens in W-REMOTE (sources-review.md; UI-GROUNDTRUTH §3.6 "sheet" is actually this AppKit window, `MLM/App/AppDelegate.swift:120-135`, `MLM/Views/Sources/RemotePlaylistsView.swift`).
  2. The resulting linked playlist appears in V-PL with its source label and `Importing · n of m` while downloading (V-PL.E12/E13).
  3. `Open playlist` in W-REMOTE shows V-PLD **inside that window**, where Play does nothing (`MLM/Views/Sources/RemotePlaylistsView.swift:64-69`).
  4. In the main window, V-PLD shows `Downloading · n of m`, then `n of m tracks failed to download` + E14, or, if the user chose "Save without downloading", only `Download missing (m)` + per-row `Not downloaded`.
  5. Later: `Sync` (YouTube only) to pull new entries.

  Breaks:
  - Card and header use different words (Importing / Downloading).
  - A never-downloaded import looks healthy on the card.
  - SoundCloud/Spotify imports cannot be refreshed.
  - The YouTube refresh skips videos already in the library and writes album `YouTube`.
  - The planning seed describes SoundCloud import as a **one-time, unlinked, downloaded-only** import (`.planning/seeds/soundcloud-playlist-import.md`), while the code keeps a live link (§11 register).
- **fix-failed-downloads**
  1. V-PL → `Incomplete` toggle (E03) narrows to playlists with failures.
  2. CM-PL-CARD `Show failed tracks` → V-PLD with E14 expanded.
  3. Read each reason + `n attempts left`; `Retry` / `Retry all`, `Open Settings` (when the reason mentions Settings), or `Remove` / `Remove failed tracks from playlist` (→ A-PLD-REMOVE when more than 1).

  Breaks:
  - `0 attempts left` while Retry is still offered.
  - No feedback after retry other than the chips changing.
  - The pinned-route detail does not update live during the batch *(inferred)*.
  - `Open Settings` opens the Settings window, not the specific tab.
  - Reasons are raw provider text.
  - Failed rows in the table offer no row-level retry (double-click does nothing; the context menu's download item is library.md's).
  - Never-downloaded tracks are not "failed" and are not covered by the `Incomplete` filter.
- **daily-listening**
  1. Sidebar pinned playlist (P-PINNED) or V-PL card → V-PLD.
  2. `Play` / `Shuffle` / double-click a row → P-PLAYER.

  Breaks: Play/Shuffle hidden if nothing is local; Shuffle queues non-local tracks; double-click on a non-local row is silent; the toolbar search behaves differently by entry route.
- **sync-device:** CM-PL-CARD `Sync to ▸ ‹profile›` adds the playlist to a profile silently; `Create New Profile…` is dead. The rest is V-SYNC.
- **drive-unplugged:** V-FOLD is clear (`Drive not connected`); V-PLD shows a wall of `File missing`; V-PL shows nothing.
- **albums-future** (no design proposals; what exists in playlists that albums would resemble):
  - Playlists already have an **independent ordered membership**: `playlist_tracks.position` (fractional index, stable under reorder; `MLM/Models/Playlist.swift:168-193`, `MLM/ViewModels/PlaylistDetailViewModel.swift:558-666`). ROADMAP §4 C1 names this the model an `album_tracks` join could mirror.
  - Playlists have **cover handling**: auto mosaic/single/initials and a custom lock (`MLM/Services/Playlists/PlaylistCoverService.swift:140-305`). An album's image "should be the album cover" (`todo_dump.md`), so it would come from one source, not a mosaic.
  - Playlists have a card grid (V-PL), a detail with a 64 pt cover header, a `#` column, Play/Shuffle, and a download-health aggregate (`MLM/Models/Playlist.swift:88-166`). These are all things an album list or detail would display.
  - The playlist table lets the user re-sort temporarily while `#` keeps the stored order. For albums the order must be "respected"; whether temporary sorting or reorder-by-drag would apply is open.
  - A dormant `category = "album"` icon mapping (`opticaldisc`) already exists in card and detail (`MLM/Views/Playlists/PlaylistCard.swift:501`, `MLM/Views/Playlists/PlaylistDetailView.swift:848`). Nothing creates such playlists.
  - The `albums` table (8,020 rows, no ordering, no UI) is separate from playlists (ROADMAP §0.2).
  - The `Album` column in V-PLD/V-FOLD shows source-as-album values (`YouTube`, `SoundCloud Likes`), and YouTube refresh still writes `YouTube` (`MLM/ViewModels/PlaylistDetailViewModel.swift:428-434`).
- **link-playlist-source** (area flow)
  1. V-PLD `Link Source…`.
  2. S-PLD-LINK: paste URL → `Check`.
  3. Match → A-PLD-LINKDONE; differences → A-PLD-LINKMISMATCH → `Link Anyway`.

  Breaks: the alert promises "Sync pulls new tracks", but SoundCloud links never get a `Sync` button; nothing is imported, so the playlist does not change visibly except the provenance line.
- **m3u-import** (area flow)
  1. V-PLD `Import M3U…` → S-PLD-M3U-OPEN.
  2. S-PLD-M3U-PREVIEW → `Create & Import` / `Apply`.
  3. A-PLD-IMPORTDONE.

  Breaks: the target is chosen by file name/UUID, not the open playlist; the result alert does not name the target.

### Unresolved from code

- **⌘N conflict:** whether the grid button's ⌘N (K-PL-NEW) or the File menu's ⌘N (`New Playlist`, instant "Untitled Playlist") fires while V-PL is focused depends on runtime key-equivalent dispatch; not determinable without running the app.
- **Multi-row drag:** whether SwiftUI `Table` sends a multi-row drag as several item providers (which the drop handlers support), or only the clicked row, is not determinable from code.
- **Spring-load route survival:** whether a drag started in V-FOLD survives the view being torn down when spring-load switches sections (V-FOLD is not kept alive; V-LIB is) needs runtime verification.
- **Table primary action:** whether the primary action also fires on Return for a focused row is SwiftUI platform behaviour, not visible in code.
- **Pinned-route live progress:** whether the pinned-route detail updates during a download batch depends on whether any other component posts `.downloadStateDidChange` or `.playlistDidChange` per finished track; only the grid poller and batch-end posts were found.
- **Cover reach:** the exact number of playlists today: only the cover count (36, ROADMAP §1) is known. Playlist sizes (tracks per playlist) are unknown without live data.
- **Sidebar pinned rename/delete/"Reveal in Grid":** owned by main.md (P-PINNED); only the pin/unpin action and the 8-pin limit (enforced in V-PL only, sidebar shows `prefix(8)`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:63`) are described here.

