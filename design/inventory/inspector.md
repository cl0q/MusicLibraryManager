# Track Inspector, Similar Tracks sheet, Genre Workshop

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): TD (inspector shell), META (metadata tabs), WAVE (waveform), DEBUG (Debug tab), GROOVE (Similar sheet), STUDIO (Genre Workshop) · Files covered: `MLM/Views/TrackDetail/TrackDetailView.swift`, `MetadataPanel.swift`, `WaveformView.swift`, `WaveformHelpers.swift`, `DebugTabView.swift`, `GrooveView.swift`, `GrooveStudioView.swift` (+ callers/services that shape what the user sees: `ContentView.swift`, `MLMApp.swift`, `SettingsView.swift`, `AppDelegate.swift`, `PlaybackViewModel.swift`, `TrackRepository.swift`, `PlaylistRepository.swift`, `DiscoveryReviewService.swift`, `SwarmRecommendationService.swift`, `Track.swift`, `TrackMetadataPresentation.swift`, `TrackContextMenu.swift`)

Reading notes for the designer:
- "Inspector" = the right-hand pane that shows one track. Today it is an `HSplitView` pane, **not** a SwiftUI `.inspector`, and it shows **exactly one track** — there is no multi-track editing anywhere in these files.
- "Similar Tracks sheet" = what code calls `GrooveView`. "Genre Workshop" = what code calls `GrooveStudioView`; it lives inside the **Settings window → Advanced tab** (ST-ADV is owned by settings.md; the screens inside it are documented here as `ST-STUDIO-*`).
- All metadata edits are written to the MLM database only; the audio file's own tags are never rewritten by any code in this area (`MLM/Views/TrackDetail/MetadataPanel.swift:264-266`, `MLM/Database/TrackRepository.swift:476-482`).

## Surfaces

### P-INSPECTOR — Track inspector ("detail panel")
- Reached via: double-click (table primary action) on a track row in V-LIB, V-PLD, V-FOLD and global search results — this **also starts playback** for local tracks (`MLM/Views/ContentView/ContentView.swift:394-404`, `MLM/Views/Library/TrackTable.swift:239-243`); V-SYNC-DETAIL failed-tracks row double-click (plays) and its row context menu item `Show Details` (does not play) via `.openTrackDetailForTrack` (`MLM/Views/Sync/SyncFailedDisclosure.swift:131-133,161-165,192-198`, `MLM/Views/ContentView/ContentView.swift:172-192`). **Not** reachable via ⌘I: M-LIBRARY `More Info` (⌘I) posts `.showTrackDetail`, which nothing observes (`MLM/App/MLMApp.swift:183-188`, `MLM/Utilities/Notifications.swift:114-115`; repo-wide grep finds no receiver). Not in CM-TRACK either (no `More Info` item in `MLM/Views/Library/TrackContextMenu.swift:59-195`, despite the doc comment at `MLM/Views/TrackDetail/TrackDetailView.swift:6-8`). Single-click selection never changes the inspector. No toolbar button.  ·  Leads to: P-INSPECTOR-WAVEFORM, P-INSPECTOR-GENERAL, P-INSPECTOR-AUDIO, P-INSPECTOR-FILE, P-INSPECTOR-SIMILAR, P-INSPECTOR-DEBUG, S-GROOVE-SIMILAR, V-REV (via `Show in Review`), A-META-SAVEERROR.
- Code: `MLM/Views/ContentView/ContentView.swift:230-253` (presentation), `MLM/Views/ContentView/ContentView.swift:148-158,240-245` (refresh / follow-now-playing), `MLM/Views/TrackDetail/TrackDetailView.swift:9-295` (shell + header), `MLM/Views/TrackDetail/MetadataPanel.swift:9-195` (tab bar, loading, sheet/alert hosts), `MLM/Views/TrackDetail/MetadataPanel.swift:742-823` (footer).
- Presentation (as built): third pane of an `HSplitView` to the right of the `NavigationSplitView` (sidebar + detail) in W-MAIN. Width min 320 / ideal 360 / max 480 pt, user-resizable via split divider (`MLM/Views/ContentView/ContentView.swift:247-252`, `MLM/Views/TrackDetail/TrackDetailView.swift:50`). Vertical stack: waveform (top) → header → tab bar → scrollable tab content → persistent footer. Close only via the `×` button (help `Close detail panel`) (`MLM/Views/TrackDetail/TrackDetailView.swift:156-169`); no keyboard shortcut, no toggle. While open it **follows the now-playing track** whenever playback changes track (but is never force-opened and never cleared on stop) (`MLM/Views/ContentView/ContentView.swift:240-245`). After any `.libraryDidImport` it re-fetches the shown track from the DB (`MLM/Views/ContentView/ContentView.swift:148-158`). Stays open across sidebar section changes.
- Purpose: everything about one track — listen/seek, edit its tags, see analysis, find its file, see its playlists, find similar music.
- User goals:
  1. See what is playing right now and seek in it (daily) — inferred from follow-now-playing behaviour.
  2. Fix a wrong title/artist/album/genre/year (weekly) — `MLM/Views/TrackDetail/MetadataPanel.swift:197-276`.
  3. Add the track to a playlist quickly while listening (daily) — persistent Quick Add footer, `MLM/Views/TrackDetail/MetadataPanel.swift:742-802`.
  4. Find where the file is / reveal in Finder (weekly).
  5. Find tracks that sound similar (weekly) — P-INSPECTOR-SIMILAR, S-GROOVE-SIMILAR.
  6. Check why a file is broken (rare) — P-INSPECTOR-DEBUG.
- What the user wants to see, in priority order: (1) which track this is (title, artist, album, artwork) and whether it is playable (availability); (2) playback position / seekable waveform; (3) editable tags; (4) playlist membership + add-to-playlist; (5) technical quality (format, bitrate, loudness, BPM); (6) file location; (7) similar tracks; (8) diagnostics.
- Elements today:
  - P-INSPECTOR.E01 Waveform strip (→ P-INSPECTOR-WAVEFORM), at the very top.
  - P-INSPECTOR.E02 Cover art 56×56 fused with a play button: on hover over a **local** track a dark overlay + `play.fill`/`pause.fill` appears, cursor becomes a pointing hand, tooltip `Play` / `Pause`; click plays this track (or toggles if it is already current). When the track is current and not hovered, a small `waveform` badge shows bottom-right. Remote tracks: no overlay, empty tooltip, click does nothing (`MLM/Views/TrackDetail/TrackDetailView.swift:61-113`).
  - P-INSPECTOR.E03 Title (max 2 lines) (`MLM/Views/TrackDetail/TrackDetailView.swift:116-120`).
  - P-INSPECTOR.E04 `Artist — Album` line; album omitted only if empty string — the literal `unknown album` (48 % of tracks, ROADMAP §0.3) is shown as is (`MLM/Views/TrackDetail/TrackDetailView.swift:122-136`).
  - P-INSPECTOR.E05 Format badge: `track.format` uppercased, tinted by format (FLAC/ALAC green, MP3 blue, AAC/M4A amber, OGG accent, other muted) (`MLM/Views/TrackDetail/TrackDetailView.swift:175-193`). *(inferred)* For not-downloaded tracks `format` can hold a source name (e.g. `soundcloud`, see `MLM/Views/Shared/TrackMetadataPresentation.swift:27-31`), so the badge would read `SOUNDCLOUD`.
  - P-INSPECTOR.E06 `N kbps` (if known), P-INSPECTOR.E07 duration (`MLM/Views/TrackDetail/TrackDetailView.swift:138-151`).
  - P-INSPECTOR.E08 `×` close button, tooltip `Close detail panel`.
  - P-INSPECTOR.E09 Tab bar — custom segmented row of 5 equal-width buttons, icon + label: `General` (pencil.and.outline), `Audio` (waveform), `File` (doc), `Similar` (sparkles), `Debug` (ladybug); selected tab filled with accent colour (`MLM/Views/TrackDetail/MetadataPanel.swift:22-40,74-103`). Starts on `General`; selection survives track changes but resets when the inspector is closed/reopened (view state only).
  - P-INSPECTOR.E10 Footer `Quick Add` button (prominent, `plus`), disabled when no playlist is chosen or there are no playlists (`MLM/Views/TrackDetail/MetadataPanel.swift:747-757`).
  - P-INSPECTOR.E11 Footer playlist picker (menu style, max 140 pt): `Select playlist` (none) + all playlists by name, or only `No playlists`. Choice persisted in UserDefaults `detail.quickAddPlaylistId`; defaults to the first playlist when the saved one is gone (`MLM/Views/TrackDetail/MetadataPanel.swift:142-156,759-774,804-808`).
  - P-INSPECTOR.E12 Footer menu button `Add to Playlist…` (`text.badge.plus`, tooltip `Add this track to a playlist`): items = playlist names, or disabled text `No playlists found` (`MLM/Views/TrackDetail/MetadataPanel.swift:776-792`).
- Interactions: click cover = play/pause; click tab = switch tab (animated); footer add = immediate DB insert, no confirmation/feedback toast — the only visible confirmation is the new row in the General tab's `PLAYLISTS` list (`MLM/Views/TrackDetail/MetadataPanel.swift:920-938`). No right-click menu anywhere in the inspector. No drag sources/targets. Keyboard: none specific to the inspector (see K section). Multi-select: **not supported** — the inspector holds a single `Track?`; with several rows selected, the table primary action opens `selectedIDs.first` of an unordered Set, i.e. an arbitrary one of them (`MLM/Views/Library/TrackTable.swift:239-243`). No bulk tag editing exists anywhere in MLM's track inspector code.
- States:
  - default: as above.
  - empty: no inspector shown (pane absent) when nothing chosen.
  - loading: playlists/availability load silently in the background (`MLM/Views/TrackDetail/MetadataPanel.swift:135-141`); no spinner.
  - error: footer add/remove playlist errors swallowed (`try?`, `MLM/Views/TrackDetail/MetadataPanel.swift:911,927`); tag save error → A-META-SAVEERROR.
  - offline / drive not connected: no banner; header still shows play affordance for tracks with a stored path (E02 uses `isLocal` = "has a path", not "file exists", `MLM/Models/Track.swift:116-118`); clicking play then fails with the player's message `Playback unavailable: <title> — file could not be found on disk.` shown by the player (P-PLAYER), not in the inspector (`MLM/ViewModels/PlaybackViewModel.swift:180`). File tab shows `File missing` (see P-INSPECTOR-FILE).
  - remote (not downloaded): play affordance hidden; analysis buttons disabled; no Download action anywhere in the inspector.
  - track removed from library while shown: *(inferred)* the refresh only replaces the track when the re-fetch succeeds (`MLM/Views/ContentView/ContentView.swift:149-156`), so the stale track stays displayed; an edit then fails with A-META-SAVEERROR.
  - huge data: n/a (one track).
  - background work: none surfaced (download/analysis progress for this track is not shown here, except its own Audio/Similar buttons).
- Data scale / performance notes: footer loads **all** playlists and all sync profiles on every appear and on every `.playlistDidChange` / `.syncProfileDidChange` (`MLM/Views/TrackDetail/MetadataPanel.swift:157-165,816-823`); sync profiles are loaded but never used (dead `addToSyncProfile`, `MLM/Views/TrackDetail/MetadataPanel.swift:940-953`).
- Pain points today:
  - ⌘I `More Info` does nothing (no observer) — `MLM/App/MLMApp.swift:183-188`; UI-GROUNDTRUTH §2.1 line 221 / §2.6 line 349 promise ⌘I opens and closes it.
  - Opening the inspector always starts playback for local tracks (double-click is the only general entry point) — `MLM/Views/ContentView/ContentView.swift:394-404`. There is no "inspect without playing".
  - Track-scoped view state is not reset on track change (no `.id(track.id)` on `TrackDetailView`, `MLM/Views/ContentView/ContentView.swift:247-251`): an open inline edit, the Debug tab result, the Similar tab analysing flag all carry over to the next track (details in the tab entries). Because the inspector auto-follows the now-playing track, this happens without user action when the queue advances.
  - Footer always visible on every tab, including Debug.
  - No sync-profile action although UI-GROUNDTRUTH §3.10 wireframe shows `[Add to Playlist…] [Add to Sync Profile…]`; code loads profiles then never offers them.
  - Quick Add always inserts at the fixed position string `999000` (`MLM/Views/TrackDetail/MetadataPanel.swift:925`) instead of the repository's tail-append (`MLM/Database/PlaylistRepository.swift:270-281`) — *(inferred)* tracks added via the inspector may not land at the end of the playlist and several such adds share one position.
  - Uses custom colour tokens (`mlmSurface`, `mlmAccent`, custom tab bar) — conflicts with the locked "native macOS look" decision.
- Related flows: daily-listening (inspector follows now-playing), edit-metadata, build-playlist (Quick Add), discover (Similar), review-duplicates (Show in Review), sync-device (Show Details from failed sync rows), drive-unplugged.
- Constraints / locked decisions: native macOS look only; English only; critical states always text; one meaning per word (glossary: "Similar", never "Groove").
- Open questions for the designer:
  - Should the inspector open/close independently of playback (⌘I, toolbar toggle), and follow selection, the now-playing track, or both?
  - What should the inspector show when several tracks are selected?
  - Which pieces of the header duplicate the player bar (cover, play, waveform) and which belong only here?
  - Should "add to playlist" from the inspector give feedback beyond the General tab list?

### P-INSPECTOR-WAVEFORM — Waveform strip (top of the inspector)
- Reached via: always visible at the top of P-INSPECTOR  ·  Leads to: playback in P-PLAYER (seek / play), P-INSPECTOR-AUDIO (its options card).
- Code: `MLM/Views/TrackDetail/TrackDetailView.swift:197-261,286-294` (host), `MLM/Views/TrackDetail/WaveformView.swift:8-283` (rendering, gestures), `MLM/Views/TrackDetail/WaveformHelpers.swift:7-63` (bin count, colour ramp, seek math), `MLM/ViewModels/PlaybackViewModel.swift:541-560` (data source).
- Purpose: see the shape of the track and jump to any point.
- User goals: 1. Jump to the drop/break of the playing track (daily, inferred — DJ use, drop detection elsewhere). 2. Scrub through long mixes (weekly, inferred from `isScrollable` ≥ 7 min). 3. Start a not-yet-playing track at a chosen point (weekly).
- What the user wants to see: (1) the waveform of **this** track; (2) where the playhead is + current time; (3) total time.
- Elements today:
  - P-INSPECTOR-WAVEFORM.E01 Bar waveform (mirrored, bottom half 70 % height), colour ramps from steel blue (quiet) to orange-red (loud); played part brighter (`MLM/Views/TrackDetail/WaveformView.swift:159-216`, `MLM/Views/TrackDetail/WaveformHelpers.swift:33-42`).
  - .E02 Playhead line + needle time label (e.g. `1:23`) drawn inside the waveform, only while 0 < progress < 1 and only for the current track (`MLM/Views/TrackDetail/WaveformView.swift:218-246`, `MLM/Views/TrackDetail/TrackDetailView.swift:286-294`).
  - .E03 Time row `0:00` … `<duration>` below — only when this is the current track (`MLM/Views/TrackDetail/TrackDetailView.swift:225-235`).
  - .E04 Resize handle: 4 pt bar, up/down resize cursor, drag sets height 60–250 pt (`MLM/Views/TrackDetail/TrackDetailView.swift:237-256`).
  - Loading placeholder: 40 grey animated bars; empty placeholder: a single thin horizontal line (`MLM/Views/TrackDetail/WaveformView.swift:250-276`).
- Interactions: click or drag anywhere = seek (fires continuously during drag). If this is the current track → seek; if another **local** track → starts playing it then seeks; remote → nothing (`MLM/Views/TrackDetail/TrackDetailView.swift:209-219`). Tracks ≥ 420 s (7 min) render as a horizontally scrolling strip (2 pt bars + 1 pt gap at zoom 1) with trackpad **pinch zoom** 0.5×–8× (K-WAVE-PINCH); shorter tracks fit to width and ignore pinch (`MLM/Views/TrackDetail/WaveformView.swift:77-151`). Sensitivity / Gain / Height sliders and Reset live in P-INSPECTOR-AUDIO. No hover tooltip.
- States:
  - default: playing track's waveform.
  - **wrong-track state:** the data shown is always the **main player's** current waveform (`playbackVM.waveformData`), not the inspected track's (`MLM/Views/TrackDetail/TrackDetailView.swift:200`, `MLM/ViewModels/PlaybackViewModel.swift:66,541-560`). If the inspector shows a track other than the playing one (e.g. opened via `Show Details` without play), the waveform of the playing track is drawn with progress 0; if nothing plays, only the flat line.
  - loading: grey bar placeholder while the player extracts peaks.
  - empty / remote / file missing / drive offline: flat line, no text explaining why.
  - error: none shown.
- Data scale: 2 bins per second, 200–14,400 bins (`MLM/Views/TrackDetail/WaveformHelpers.swift:16-22`); a 2 h mix at zoom 8 is ~173,000 pt wide.
- Pain points: wrong-track waveform (above); no text for empty states (violates "critical states always text"); *(inferred)* on long tracks the drag-to-seek gesture is simultaneous with the horizontal scroll, so scrolling the strip also seeks (`MLM/Views/TrackDetail/WaveformView.swift:85-110`); *(inferred)* no auto-scroll keeps the playhead in view when zoomed; zoom/sensitivity/gain/height are not persisted — they reset whenever the inspector is closed (`MLM/Views/TrackDetail/TrackDetailView.swift:18-21`). UI-GROUNDTRUTH §3.10 wireframe places the waveform **below** the header and shows `[BPM segments] 0:47 / 3:44` — code has it on top, no BPM segments, and shows `0:00` instead of the position.
- Related flows: daily-listening.
- Constraints: native look; critical states as text.
- Open questions: Should the inspector waveform always be the inspected track's own (needs its own extraction), or a mirror of the player? Is the waveform a player-bar feature, an inspector feature, or both? Do sensitivity/gain/height belong to the user's permanent preferences?

### P-INSPECTOR-GENERAL — General tab (tag editing + playlist membership)
- Reached via: P-INSPECTOR.E09 `General` (default tab)  ·  Leads to: A-META-SAVEERROR; library tables refresh via `.libraryDidImport`; playlists refresh via `.playlistDidChange`.
- Code: `MLM/Views/TrackDetail/MetadataPanel.swift:197-276` (rows + save), `MLM/Views/TrackDetail/MetadataPanel.swift:1187-1294` (`EditableRowView`), `MLM/Views/TrackDetail/MetadataPanel.swift:825-918` (playlists section), `MLM/Database/TrackRepository.swift:476-482` (write).
- Purpose: correct the track's tags and see/remove which playlists contain it.
- User goals: 1. Fix a typo in title/artist (weekly). 2. Set album / album artist for album-centric listening (weekly → wish for albums, todo_dump "properly introduce albums"). 3. Set genre so the track shows up in genre-based work (weekly). 4. Remove the track from a playlist without opening that playlist (weekly).
- What the user wants to see: (1) current values clearly distinguishable from placeholders; (2) which field is being edited and how to commit/cancel; (3) whether the save worked; (4) playlists this track is in.
- Elements today (each row = a card with an uppercase caption and the value in bold; empty value shows placeholder or `—` in muted colour):
  - P-INSPECTOR-GENERAL.E01 `TITLE` — editable, required.
  - .E02 `ARTIST` — editable, required.
  - .E03 `ALBUM ARTIST` — editable; if saved empty it is silently set to the Artist value (`MLM/Views/TrackDetail/MetadataPanel.swift:244-246`).
  - .E04 `ALBUM` — editable; may be saved empty.
  - .E05 `GENRE` — editable, placeholder `No genre`; empty → cleared (nil).
  - .E06 `YEAR` — editable, placeholder `No year`; must parse as an integer, empty clears.
  - .E07 `PLAYLISTS` caption + one row per playlist containing the track: playlist name (bold) + `xmark.circle.fill` button, tooltip `Remove from <playlist name>`; empty: `Not in any playlist` (`MLM/Views/TrackDetail/MetadataPanel.swift:827-890`).
  - Edit mode (per row): plain text field with accent outline, a green `checkmark.circle.fill` button (save) and a red `xmark.circle.fill` button (cancel) — both icon-only without tooltips (`MLM/Views/TrackDetail/MetadataPanel.swift:1210-1252`). Hovering a row in display mode shows a small `pencil` icon and a raised background.
- Interactions: click anywhere on a row → enters edit mode with the current value, focus in the field (`MLM/Views/TrackDetail/MetadataPanel.swift:1270-1275`). Return or the check button → save (K-META-EDIT-RETURN). Esc or the × button → cancel, value discarded (K-META-EDIT-ESC). Only one field can be in edit mode; clicking another row switches to it and **silently discards** the unsaved text of the first. Clicking elsewhere neither saves nor cancels — the field stays open. Playlist row × → removes immediately (optimistic), no confirmation, no undo (`MLM/Views/TrackDetail/MetadataPanel.swift:901-918`). No drag, no context menu, no multi-select.
- Validation / save / cancel / undo (verbatim behaviour):
  - All values are trimmed. Empty Title or Artist → save is **silently ignored**, the field stays open, no message (`MLM/Views/TrackDetail/MetadataPanel.swift:236-243`).
  - Year that is not an integer → silently ignored, field stays open (`MLM/Views/TrackDetail/MetadataPanel.swift:253-261`); no range check (any integer accepted).
  - No uniqueness/normalisation/autocomplete for Genre or Album (free text) — the Genre Workshop's merge tool exists precisely because genres fragment.
  - Save writes **only the database row** (`TrackRepository.update`), never the file's tags; then posts `.libraryDidImport` so tables and the inspector re-fetch (`MLM/Views/TrackDetail/MetadataPanel.swift:264-272`, `MLM/Views/ContentView/ContentView.swift:148-158`).
  - Save failure → A-META-SAVEERROR (`Could not save metadata` / `Your changes were not saved.`); field stays in edit mode.
  - Success: field closes; no confirmation.
  - Undo: none after save (no ⌘Z integration; only the text field's own in-field undo while typing).
  - Remote tracks: editable like local ones (no restriction).
- States: default; empty values (placeholders/`—`); playlists loading (silent; list just appears); save error (alert); **stale-edit hazard** *(inferred from code)*: `editingField`/`editValue` are not reset when the inspected track changes (`MLM/Views/TrackDetail/MetadataPanel.swift:169-177` resets other state only), and the inspector auto-switches to the next now-playing track — an open edit of track A therefore stays open showing A's text over track B, and Return saves A's text into B (`saveField` copies the **current** `track`, `MLM/Views/TrackDetail/MetadataPanel.swift:231-233`).
- Data scale: album strings — 1,616 distinct values for 8,020 album rows, 6,209 tracks = `unknown album` (ROADMAP §0.3); editing one track at a time is the only path.
- Pain points: one-track-at-a-time editing for a 13k library with 48 % `unknown album`; DB-only edits (file tags and therefore copies outside MLM keep old values — see "Unresolved from code"); silent validation; silent discard on row switch; stale-edit hazard; no undo; hidden Album Artist fallback rule; icon-only save/cancel buttons without tooltips. UI-GROUNDTRUTH §3.10 says "Save failures toast instead of print()" — code uses a modal alert.
- Related flows: edit-metadata, albums-future, build-playlist (remove from playlist).
- Constraints: English only; sentence-case labels (captions are rendered uppercase by code).
- Open questions: Should edits be written to the file tags, the DB, or both — and should the user see which? Should multiple selected tracks be editable together (album/genre/year)? What validation feedback should empty title/invalid year produce? Should edit fields commit on focus loss like Finder/Music? What does "album" mean here once albums become entities (track number, disc number, album artwork)?

### P-INSPECTOR-AUDIO — Audio tab (analysis values, manual analysis, waveform options)
- Reached via: P-INSPECTOR.E09 `Audio`  ·  Leads to: refreshed values via `.libraryDidImport`; P-INSPECTOR-WAVEFORM (options).
- Code: `MLM/Views/TrackDetail/MetadataPanel.swift:278-484` (UI), `MLM/Views/TrackDetail/MetadataPanel.swift:655-740` (file resolution + analysis runs), `MLM/Views/Library/EnergyBars.swift:11-57`, `MLM/Views/Library/DanceabilitySteps.swift:15-73`.
- Purpose: see how loud/energetic/danceable the track is and compute missing values.
- User goals: 1. Check loudness/BPM before using a track in a set (weekly, inferred). 2. Fill a missing value for one track without running a library-wide batch (rare). 3. Tune waveform readability (rare).
- What the user wants to see: (1) BPM, energy, danceability, loudness; (2) which values are missing and why; (3) whether an analysis is running/failed.
- Elements today:
  - .E01 Values card: `LUFS (Integrated)` (`-9.3 LUFS`), `Loudness Range` (`x.x LU`), `True Peak` (`x.x dBTP`), `Tempo (BPM)` (`128 BPM`) — missing → `—`; `Energy` 5-bar meter + `n/5`; `Danceability` step meter + `NN%`; missing meters show `—` (`MLM/Views/TrackDetail/MetadataPanel.swift:283-321`).
  - .E02 `Run analysis` card (bolt icon) with two bordered buttons: `Loudness (LUFS)` (tooltip `Run loudness analysis for this track`) and `Danceability` (tooltip `Analyze this track's danceability`). While one runs, it shows a small spinner and **both** are disabled; disabled for remote tracks (`MLM/Views/TrackDetail/MetadataPanel.swift:333-380`). Shown even when values already exist (acts as re-run).
  - .E03 `Waveform options` card: `Sensitivity` slider 0.5–3.0 step 0.1 (`1.5x`), `Gain` 0.5–2.5 (`1.0x`), `Height` 60–250 pt step 5 (`80 pt`), `Reset` (also resets zoom to 1×) (`MLM/Views/TrackDetail/MetadataPanel.swift:392-470`).
- Interactions: buttons start a one-off analysis; sliders apply live to P-INSPECTOR-WAVEFORM.
- States:
  - not analysed: `—` values.
  - running: spinner in the pressed button.
  - success: values update after the DB write + `.libraryDidImport` re-fetch (`MLM/Views/TrackDetail/MetadataPanel.swift:687-708,729-734`); no message.
  - failure / analyzer unavailable (e.g. ffmpeg missing) / file not found / drive offline: spinner stops, **nothing else** — errors go to `print()` only, not even to the Logs tab (`MLM/Views/TrackDetail/MetadataPanel.swift:677-679,710-712,720-722,736-738`).
  - remote: buttons disabled, no explanation text.
- Background work: these runs are not registered in Activity (P-ACTIVITY-OPS); UI-GROUNDTRUTH §4.3 says "Analysis pending" status appears per track in this tab — no pending/queued state exists in code.
- Pain points: silent failure; no "why disabled" text for remote; technical labels (`LUFS (Integrated)`, `dBTP`) without explanation; waveform options live in a different tab than the waveform; Danceability analysis also overwrites BPM silently (`MLM/Views/TrackDetail/MetadataPanel.swift:729-733`).
- Related flows: daily-listening (inferred), drive-unplugged.
- Open questions: Which of these values matter in daily use vs. are diagnostic? Should manual analysis be visible as a job in Activity? Where should waveform display preferences live?

### P-INSPECTOR-FILE — File tab (paths, availability, source, duplicate hint)
- Reached via: P-INSPECTOR.E09 `File`  ·  Leads to: Finder, pasteboard, V-REV (`Show in Review`).
- Code: `MLM/Views/TrackDetail/MetadataPanel.swift:486-669` (UI + Finder/copy), `MLM/Views/TrackDetail/MetadataPanel.swift:1093-1115` (availability), `MLM/Models/Track.swift:138-190` (availability rules), `MLM/Views/Shared/TrackMetadataPresentation.swift:19-40` (source), `MLM/Views/ContentView/ContentView.swift:162-171` (Review navigation).
- Purpose: where the file is, whether it exists, where it came from.
- User goals: 1. Reveal the file in Finder (weekly). 2. Copy the path (rare). 3. Understand why a track will not play (weekly — drive often unplugged). 4. Jump to Review for a flagged duplicate (rare).
- What the user wants to see: (1) availability state in words; (2) the absolute path, reveal/copy; (3) source; (4) dates; (5) duplicate status with a way to resolve.
- Elements today:
  - .E01 Path card `ORIGINAL PATH`: buttons `Copy` (tooltip `Copy path`) and, for tracks with a stored library path, `Show in Finder` (tooltip `Show file in Finder`); path text selectable, single line, horizontally scrollable (`MLM/Views/TrackDetail/MetadataPanel.swift:570-626`).
  - .E02 Path card `LIBRARY PATH` (only if an organized path exists) — shows the **relative** path as stored; `Copy` copies that relative string (`MLM/Views/TrackDetail/MetadataPanel.swift:494-496,630-633`).
  - .E03 Info card rows: `Format`, `Bitrate` (`N kbps`/`—`), `Duration`, `Added` (local medium date + short time), `Status`, `Source`, and `Downloaded` (only when `download_status` is non-nil) (`MLM/Views/TrackDetail/MetadataPanel.swift:498-511`).
    - `Status` values: `Local` · `Downloading` · `Not downloaded` · `Download failed` · `File missing` (`MLM/Views/TrackDetail/MetadataPanel.swift:1093-1101`). The failure reason/date/attempts carried by the `.failed` state are **not** shown.
    - `Source` values: `Reels` · `SoundCloud` · `YouTube` · `Qobuz` · `DABmusic` · `Local import` (guessed from path/format/album).
    - `Downloaded`: ISO timestamps are formatted; any other stored value is shown raw (`MLM/Views/TrackDetail/MetadataPanel.swift:957-969`) — *(inferred)* legacy values such as `remote` or `failed` (`MLM/Models/Track.swift:181-188`) appear as `Downloaded  remote`.
  - .E04 Duplicate card (only if flagged duplicate or variant): `Possible duplicate of "Artist — Title"` (or `Possible duplicate`), subline `Review decides whether to keep one version or keep both.`, button `Show in Review` → switches main window to Review focusing this track (`MLM/Views/TrackDetail/MetadataPanel.swift:522-544`).
- Interactions: Copy = writes path to pasteboard, no feedback; Show in Finder = reveals resolved file, falls back to the raw original path when it is absolute — if nothing resolves, nothing happens (`MLM/Views/TrackDetail/MetadataPanel.swift:635-653`).
- States: local; not downloaded (`Not downloaded`, original path is the source URL, no Finder button); downloading; download failed (label only, no reason, no Retry); file missing; **drive not connected → shows `File missing`** (no distinction; `MLM/Models/Track.swift:150-165`); library root not configured → relative path assumed `Local` (`MLM/Views/TrackDetail/MetadataPanel.swift:1107-1111`). LOGIC-030 (availability surviving a track change) appears fixed in current code: the track-change handler resets to `.notDownloaded` and reloads (`MLM/Views/TrackDetail/MetadataPanel.swift:169-177`) — but the brief reset value means a local track flashes `Not downloaded` until the async check returns *(inferred)*.
- Pain points: drive-offline indistinguishable from deleted file; no download/retry action for remote/failed tracks; relative library path copy; raw `Downloaded` strings; Show in Finder silently does nothing when unresolvable; `Source` is a heuristic and the glossary/todo_dump want provenance hidden from shared files but visible here (todo_dump line 7, ROADMAP §4 C3).
- Related flows: drive-unplugged, fix-failed-downloads, review-duplicates.
- Open questions: How should "disk not connected" vs "file deleted" be told apart here? Should failed tracks expose reason + retry here? Is "Source" provenance the user wants to see daily or only on demand?

### P-INSPECTOR-SIMILAR — Similar tab
- Reached via: P-INSPECTOR.E09 `Similar`  ·  Leads to: S-GROOVE-SIMILAR (`Show all`).
- Code: `MLM/Views/TrackDetail/MetadataPanel.swift:980-1091` (UI), `MLM/Views/TrackDetail/MetadataPanel.swift:1117-1184` (load / embedding check / analysis), `MLM/Views/TrackDetail/MetadataPanel.swift:166-182` (triggers), `MLM/Database/TrackRepository.swift:1141-1148` (similarity requires an embedding).
- Purpose: show the five most similar tracks in the library, or let the user analyse this track first.
- User goals: 1. "What else do I have that sounds like this?" while listening (weekly). 2. Launch the full Similar view with online recommendations (weekly).
- What the user wants to see: (1) whether this track is analysed; (2) the top matches with a percentage; (3) a way to play/queue them.
- Elements today:
  - Not analysed: `sparkles` icon, `No analysis yet`, `Analyze this track to find similar music in your library.`, accent button `Analyze this track` (`wand.and.stars`) (`MLM/Views/TrackDetail/MetadataPanel.swift:1002-1039`).
  - Analysing: large spinner, `Analyzing this track…`, `This creates the local audio analysis used to find similar tracks.` (`MLM/Views/TrackDetail/MetadataPanel.swift:984-1001`).
  - Analysed: heading `Local matches`; loading `Finding similar tracks…`; empty `No local matches yet. Analyze more tracks to improve results.`; list of up to 5 rows `NN%` + title + artist (rows are **not interactive**: no click, play, context menu or drag); bordered button `Show all` → S-GROOVE-SIMILAR (`MLM/Views/TrackDetail/MetadataPanel.swift:1040-1088`).
- Interactions: matches load when the tab is selected (`MLM/Views/TrackDetail/MetadataPanel.swift:178-182`); `Analyze this track` runs the embedding analysis for this file.
- States: not analysed / analysing / loading / empty / list as above. Failure of `Analyze this track` → silently returns to `No analysis yet` (error only in Logs as `Groove analysis failed: …`, source `Suggestions`) (`MLM/Views/TrackDetail/MetadataPanel.swift:1177-1182`). Remote or drive offline: button is **enabled** and simply fails (no path check before running, `MLM/Views/TrackDetail/MetadataPanel.swift:1137-1154`). Track without duration: button does nothing (`MLM/Views/TrackDetail/MetadataPanel.swift:1141`). Track change while the tab is open *(inferred)*: matches are cleared and the embedding re-checked, but matches are only re-fetched on tab selection, so an analysed track shows `No local matches yet…`; an in-progress `isAnalyzing` flag is not reset.
- Background work: analysis is not shown in Activity; no cancel.
- Pain points: silent analysis failure; analyse button available for remote/offline tracks; dead-end match rows (cannot play or open them); stale state on track change; UI-GROUNDTRUTH §3.10 claimed a bounce-back sheet behaviour that is now gone (doc says "today selecting it force-opens a sheet") — code matches the doc's target instead.
- Related flows: discover, daily-listening.
- Open questions: Should matches be playable/queueable/draggable in place? Should analysis be offered only when the file is reachable? Is "% match" meaningful to the user or should it be ranked only?

### P-INSPECTOR-DEBUG — Debug tab (ffmpeg diagnostics)
- Reached via: P-INSPECTOR.E09 `Debug`  ·  Leads to: pasteboard (`Copy`).
- Code: `MLM/Views/TrackDetail/DebugTabView.swift:9-264`, `MLM/Views/TrackDetail/MetadataPanel.swift:120-121`.
- Purpose: decode the whole file with ffmpeg and report errors, stream info and the decoder log.
- User goals: 1. Find out whether a file is corrupt (rare). 2. Copy the decoder log for debugging (rare).
- What the user wants to see: (1) is the file OK — yes/no; (2) stream facts; (3) the raw log on demand.
- Elements today:
  - Loading card: spinner + `Decoding full file with ffmpeg…`.
  - `No local file` card (`arrow.down.circle`): `Download the track to run ffmpeg diagnostics.`
  - `ffmpeg not found` card: `Install ffmpeg in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, or /usr/bin to enable diagnostics.`
  - Decode-check card: `Decode errors`, `Warnings`, `Broken frames`, `ffmpeg exit code` — green when 0, red otherwise (warnings are also red).
  - Stream card: `Container`, `Codec`, `Sample rate` (`N Hz`), `Channels` (`2 (stereo)`), `Bitrate`, `Duration`.
  - `Decoder log` card with `Copy` and `Re-run` buttons; log text monospaced, selectable, max 220 pt scroll; or `No decode errors reported — the file decodes cleanly.`
  - Footer line `ffmpeg: <path> · ran HH:mm:ss`.
- Interactions: runs automatically when the tab is shown; `Re-run` repeats; `Copy` copies error+warning lines.
- States: loading; missing local file — also shown when the **drive is not connected** (text wrongly tells the user to download); ffmpeg missing; results. No cancel while decoding.
- Performance: full decode of the file every time the Debug tab is (re)opened — switching tabs destroys and recreates this view *(inferred from the `switch` in `MLM/Views/TrackDetail/MetadataPanel.swift:111-122`)*; a 2 h mix decodes in full each visit.
- Pain points: misleading `No local file` for offline drive; *(inferred)* if the inspected track changes while the tab is open, the previous track's diagnostics stay on screen (state not keyed by track, `MLM/Views/TrackDetail/DebugTabView.swift:14-24,41-43`); developer-facing surface sits in the everyday inspector tab bar.
- Related flows: fix-failed-downloads (corrupt download), drive-unplugged.
- Open questions: Should diagnostics be in the everyday inspector at all, or behind a secondary entry? What is the non-developer summary of a diagnostic result?

> The Genre Workshop is the only content of Settings → `Advanced`. The tab itself is documented as [ST-ADV in settings.md](settings.md#st-adv--advanced-genre-workshop); the four entries below describe its sub-screens.

### ST-STUDIO-GRID — Genre Workshop: genre grid (Settings → Advanced)
- Reached via: W-SETTINGS → tab `Advanced` (ST-ADV, `slider.horizontal.3`) (`MLM/Views/Settings/SettingsView.swift:49-53`); the Settings window is an AppKit window opened by the app menu, default 720×560, min 600×500, resizable, remembers last tab (`MLM/App/AppDelegate.swift:67-84`, `MLM/Views/Settings/SettingsView.swift:9`). The ST-ADV tab **contains nothing but** the Genre Workshop.  ·  Leads to: ST-STUDIO-GENRE, ST-STUDIO-MERGE, ST-STUDIO-EXPORT.
- Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:6-155` (navigation), `MLM/Views/TrackDetail/GrooveStudioView.swift:159-328` (grid), `MLM/Views/TrackDetail/GrooveStudioView.swift:1666-1691` (loading), `MLM/Database/TrackRepository.swift:1501-1524` (genre queries).
- Purpose: pick a genre to clean up, or go to merge/export tools.
- User goals: 1. See which genres exist and how big they are (rare). 2. Start tagging untagged tracks into a genre (rare). 3. Consolidate spelling variants (rare). 4. Export a CreateML training set (rare).
- What the user wants to see: (1) all genres with counts, biggest first; (2) obviously-duplicate genres; (3) entry to merge/export.
- Elements today:
  - .E01 Title `Genre Workshop`, subtitle `Pick a genre to review suggestions and clean up your tags.`
  - .E02 Button `Consolidate genres` (tooltip `Consolidate inconsistent genres in your library`) → ST-STUDIO-MERGE.
  - .E03 Button `Export training set (CreateML)` (tooltip `Export a flat training set for CreateML`) → ST-STUDIO-EXPORT.
  - .E04 Adaptive card grid (220–300 pt cards): music-note icon in a gradient circle, count badge, genre name, `1 Song` / `N Songs`. Sorted by count descending; grouping is case-sensitive (`MLM/Database/TrackRepository.swift:1503-1509`).
- Interactions: click card → ST-STUDIO-GENRE; screens slide horizontally; there is no window-level back/forward or breadcrumb other than in-screen `Back`/`Genres` buttons.
- States: loading `Loading genres...` (large spinner); empty `No genres in your library yet` / `Tag some tracks to use the workshop.`; load error → silently treated as empty (`print`, `MLM/Views/TrackDetail/GrooveStudioView.swift:1675-1680`).
- Data scale: one card per distinct genre string (count unknown, see "Unresolved from code").
- Pain points: a full-size workspace inside a 720×560 Settings tab; "Advanced" tab name says nothing about genres; custom gradient cards vs native look; copy `Songs` vs glossary "tracks".
- Related flows: genre-tagging (area flow), createml-export (area flow), edit-metadata (bulk genre).
- Constraints: Glossary: "Genre Workshop (Settings → Advanced)", never "Groove Studio".
- Open questions: Does genre cleanup belong in Settings, in the main window, or in bulk editing of the library? Is the CreateML export a user feature or a developer tool?

### ST-STUDIO-GENRE — Genre Workshop: genre detail (reference track, suggestions, staged tagging)
- Reached via: click a card in ST-STUDIO-GRID  ·  Leads to: back to ST-STUDIO-GRID (`Genres`), CM-STUDIO-SUGGESTION, CM-STUDIO-GENRETRACK, main player (via CM-TRACK `Play`).
- Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:332-1006` (UI), `MLM/Views/TrackDetail/GrooveStudioView.swift:1712-1908` (load, reference, suggestions, thumbs, save), `MLM/Views/TrackDetail/GrooveView.swift:7-165` (`PreviewPlayerManager` used by both mini players).
- Purpose: pick a reference track of a genre, get acoustically similar tracks, mark which ones belong to the genre, save the genre tag in one batch.
- User goals: 1. Grow a genre by finding untagged tracks that sound like it (rare). 2. Preview candidates against the reference side by side (rare). 3. Exclude bad suggestions (rare).
- What the user wants to see: (1) the reference track and what's playing in each preview; (2) candidate list with match %; (3) which candidates are staged; (4) the count of staged changes and a save action.
- Elements today:
  - .E01 Header: `chevron.left Genres` (back), genre name as page title, purple button `Save (N)` (only when staged edits exist), green transient message (`N track(s) tagged and saved.` for 4 s, or `Could not save changes.`).
  - .E02 Dual preview players: left label `Suggestion player` (when loaded) / `Preview player`; right label `Reference player` (when the reference is loaded) / `Preview player`; each: play/pause button (disabled until loaded), 24 pt seekable waveform, `m:ss / m:ss` or `0:00`, and `Title · Artist` or `Ready for preview…` (`MLM/Views/TrackDetail/GrooveStudioView.swift:426-560`). Starting either preview pauses the main player.
  - .E03 Left column `Suggestions`: controls (only after a reference is chosen) `Temperature:` slider 0.0–1.0 step 0.1 with value; `Suggestions:` segmented `10 tracks` / `20 tracks`; checkbox `Suggest untagged tracks only` — each change reloads (`MLM/Views/TrackDetail/GrooveStudioView.swift:564-626`).
  - .E04 Suggestion rows: 24 pt cover = play in left player; title/artist; either `NN% Match` (green >80, amber >60) or, when staged, the genre name as a purple outlined tag; `hand.thumbsup` (tooltip `Mark this genre for saving`) toggles staging; `hand.thumbsdown` (tooltip `Exclude this track from suggestions`) → saves negative feedback immediately, removes the row, refills the list. Double-click row = play in left player. Right-click → CM-STUDIO-SUGGESTION (`MLM/Views/TrackDetail/GrooveStudioView.swift:672-795`).
  - .E05 Right column `Tracks in <genre>`: reference slot — either `Reference track` card (purple) with cover/title/artist and `xmark.circle.fill` (tooltip `Remove reference track`), or dashed placeholder `No reference selected` / `Double-click a track below to generate suggestions`; then the genre's tracks (cover = play in right player, title, artist, album). Double-click: if no reference → becomes reference (auto-plays in right player + loads suggestions); otherwise plays in right player. Right-click → CM-STUDIO-GENRETRACK (`MLM/Views/TrackDetail/GrooveStudioView.swift:803-1006`).
- Interactions: double-click and cover clicks (above); thumbs up/down; Save; Back. No drag & drop, no multi-select, no keyboard.
- Save behaviour: `Save (N)` writes for each staged track: genre := this genre (DB only), clears its mix category, saves positive similarity feedback; posts `.libraryDidImport`; reloads both columns (`MLM/Views/TrackDetail/GrooveStudioView.swift:1857-1908`). Partial failure → `Could not save changes.` with no indication which tracks were saved. No undo.
- States: no reference → left column `Choose a reference track` / `Double-click a track on the right to load suggestions.`; loading `Finding suggestions…`; empty `No suggestions found` / `Adjust the temperature or remove filters.` (also shown when the reference track simply has no similarity analysis — `MLM/Database/TrackRepository.swift:1143-1148` returns empty; the copy then misleads); genre tracks loading `Loading genre tracks...`; empty `No known tracks available`; preview file missing / drive offline → preview silently doesn't start (logged as `Preview: File not found …`, `MLM/Views/TrackDetail/GrooveView.swift:57-61`).
- Pain points: **leaving via `Genres` discards all staged edits without warning** (`MLM/Views/TrackDetail/GrooveStudioView.swift:336-350`), as does closing Settings; thumbs-down feedback is permanent and has no list/undo; the `Temperature` concept is unexplained (UI-GROUNDTRUTH §3.15 asks for a one-line explanation — none in code); two mini players + main player = three playback paths; mixed copy (`Songs`, `Tracks`); main player stays paused after previewing *(inferred: preview pauses main playback, nothing resumes it, `MLM/Views/TrackDetail/GrooveView.swift:41-42`)*.
- Related flows: genre-tagging, edit-metadata.
- Open questions: Should staged changes survive navigation? Should genre assignment be a general multi-select bulk edit rather than a separate workshop? Which previews should play through the main player?

### ST-STUDIO-MERGE — Genre Workshop: Consolidate genres
- Reached via: ST-STUDIO-GRID `Consolidate genres`  ·  Leads to: ST-STUDIO-GRID (`Back`), CM-STUDIO-MERGETABLE, main player (double-click).
- Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:1010-1338` (UI), `MLM/Views/TrackDetail/GrooveStudioView.swift:1692-1710,1912-1948` (preview load, merge), `MLM/Database/TrackRepository.swift:1537-1543` (SQL update).
- Purpose: merge spelling variants/duplicates of genres into one canonical genre.
- User goals: 1. Turn `Hip Hop`, `HipHop`, `Hip-Hop` into one (rare). 2. Check what tracks a genre contains before merging (rare).
- What the user wants to see: (1) all genres with counts and which are selected; (2) the target name; (3) affected track count before committing; (4) result.
- Elements today:
  - .E01 Header `chevron.left Back`, title `Consolidate genres`.
  - .E02 Intro: `Select alternate spellings or duplicate genres and merge them into one canonical genre. Tracks update immediately in the database.`
  - .E03 Success banner (green) `Genres merged into '<name>'.` / error banner (red) `Could not merge genres: <system error>` or `The target genre name cannot be empty.`
  - .E04 `SELECT (N selected)` list, fixed 200 pt high: per genre a checkbox (`square` / `checkmark.square.fill`) and a row button (name + `N Songs`) that loads the preview below; first checked genre pre-fills the target name.
  - .E05 `MERGE` box: **German** label `Neuer kanonischer Genre-Name:` and placeholder `z.B. Hip Hop & Rap` (`MLM/Views/TrackDetail/GrooveStudioView.swift:1161-1165`); button `Merge selected genres` — disabled and grey until ≥ 2 genres are checked and the name is non-empty.
  - .E06 Preview: `Tracks in "<genre>" (showing N of 50)` + `Double-click to preview`; sortable native `Table` with columns `Title` (with cover and a now-playing speaker icon), `Artist`, `Album`, `Time`, `Format`; capped at 50 rows; multi-selection supported. Empty: `No tracks found in this genre.`; nothing chosen: `Choose a genre from the list` / `Select a genre above to review up to 50 tracks before merging.`; loading `Loading tracks…`.
- Interactions: checkbox toggles; row click previews; table double-click (K-STUDIO-MERGE-PRIMARY) plays the first selected track **in the main player** (despite the `Double-click to preview` caption) (`MLM/Views/TrackDetail/GrooveStudioView.swift:1303-1312`); right-click → CM-STUDIO-MERGETABLE.
- Merge behaviour: immediate SQL `UPDATE tracks SET genre = target WHERE genre IN (sources)`; **no confirmation, no count of affected tracks, no undo**, DB only (`MLM/Database/TrackRepository.swift:1537-1543`). Posts `.libraryDidImport`.
- Pain points: irreversible bulk change without confirmation (violates UI-GROUNDTRUTH §3.17 "every destructive action confirms"); German strings (§1.7, Part 5 banned list); preview is per single genre, not of the merge result; `of 50` wording even for small genres; case-sensitive genre identity means `house` and `House` appear separately; UI-GROUNDTRUTH §3.15 specifies `Merge into:` — code differs.
- Related flows: genre-tagging.
- Open questions: What should the user confirm before a merge (count, names)? Should merges be undoable? Should genre consolidation also suggest likely duplicates automatically?

### ST-STUDIO-EXPORT — Genre Workshop: Export CreateML training set
- Reached via: ST-STUDIO-GRID `Export training set (CreateML)`  ·  Leads to: S-STUDIO-EXPORTFOLDER, P-ACTIVITY-OPS (operation `CreateML Export: <folder>`), ST-STUDIO-GRID (`Back`).
- Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:1342-1662` (UI), `MLM/Views/TrackDetail/GrooveStudioView.swift:1952-2171` (folder picker, export, cancel), `MLM/ViewModels/ActivityViewModel.swift:65`.
- Purpose: copy/transcode every track of every genre with ≥ 50 tracks into `<destination>/<Genre>/<Artist> - <Title>.m4a` for Apple Create ML.
- User goals: 1. Produce a training set for a genre classifier (rare, developer-ish).
- What the user wants to see: (1) how many tracks/genres qualify and which are excluded; (2) destination; (3) progress, cancel, result.
- Elements today:
  - .E01 Header `Back` (disabled while exporting; also cancels), title `Export CreateML training set`.
  - .E02 Intro (bold inline): `Export tracks with genres into a flat folder structure. FFmpeg converts each track to **AAC 248 kbps (.m4a)**, ready to load into **Apple Create ML** for training a SoundClassifier model.`
  - .E03 Cards `READY FOR EXPORT (≥ 50 tracks)` (`Tracks:` N, `Genres:` N) and `EXCLUDED (< 50 tracks)` (same).
  - .E04 `Target format:` `AAC 248kbps (.m4a)` badge.
  - .E05 Disclosure `Show excluded genres (N)` → text `These genres have fewer than 50 tracks and are excluded from training. Use Consolidate genres to merge them.` + horizontally scrolling chips `Genre  N`.
  - .E06 `TRAINING SET DESTINATION:` button `Choose destination…` (→ S-STUDIO-EXPORTFOLDER) + path (middle-truncated) or `No folder selected`.
  - .E07 `Start export` (grey/disabled until a folder is chosen) → while running: progress text `[i/N] Exporting tracks (P%)...`, linear progress bar, red `Cancel export`; end text `Exported N tracks into genre folders.` / `Export cancelled.` / `Export failed: <error>` / `No tracks with genres found. At least 50 tracks per genre are required.`
- Interactions: choose folder; start; cancel. Concurrency silently uses the Sync "background processing" level (`MLM/Views/TrackDetail/GrooveStudioView.swift:1970,2019-2020`), which the screen does not mention.
- States: idle; running (also an Activity operation with progress, completion, or failure `Cancelled by user`); per-track failures (missing source file, drive offline, transcode failure) are only logged — the final text still says `Exported N tracks` with N = all eligible tracks (`MLM/Views/TrackDetail/GrooveStudioView.swift:2046-2049,2135-2151`); leaving Settings during export: *(inferred)* task keeps running, no UI to return to.
- Pain points: success count counts attempts, not successes; hidden concurrency setting (UI-GROUNDTRUTH §4.2 rule 2 requires it be labelled); `≥ 50` threshold fixed; comments say `≥ 10` (`MLM/Views/TrackDetail/GrooveStudioView.swift:1394,1434`) — code is 50; destination not remembered between visits.
- Related flows: createml-export.
- Open questions: Is this a user feature worth a place in the redesign or a developer tool to hide? Should export report per-track failures?

## Context menus

### CM-STUDIO-SUGGESTION — Suggestion row (ST-STUDIO-GENRE left column)
- Where: right-click a suggestion row in ST-STUDIO-GENRE. Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:774-787` → shared CM-TRACK `MLM/Views/Library/TrackContextMenu.swift:59-195`.
- Items (CM-TRACK, single track, no playlist context, library actions on), in order: `Play` · `Play Next` · ─ · `Add to Playlist ▸` { `New Playlist…` · ─ · playlists (pin icon for pinned) or `No playlists` } · `Sync to ▸` { `Create new profile…` · ─ · profiles or `No sync profiles — create one first` · (─) · `Create new profile… (Settings)` } · ─ · [if local] `Show in Finder` · `Copy File Path` · ─ · [if not downloaded] `Download 1 missing track` · ─ · `Remove from Library` (destructive).
- Rules: `Play` disabled for remote; `Download…` disabled while a download batch runs. Sync profile adds go through `syncViewModel.addTracks` (`MLM/Views/TrackDetail/GrooveStudioView.swift:780-785`). `New Playlist…`/`Create new profile…` post notifications handled by W-MAIN's ContentView (`MLM/Views/ContentView/ContentView.swift:138-147`) — *(inferred)* their sheets open in the main window, not in the Settings window where the user right-clicked. `Remove from Library` is available inside Settings.

### CM-STUDIO-GENRETRACK — Genre track row (ST-STUDIO-GENRE right column)
- Where: right-click a track in `Tracks in <genre>`. Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:980-993` → CM-TRACK. Items and rules identical to CM-STUDIO-SUGGESTION (single track).

### CM-STUDIO-MERGETABLE — Merge preview table (ST-STUDIO-MERGE)
- Where: right-click rows in the 50-row preview table. Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:1290-1302` → CM-TRACK. Multi-select aware: labels get ` (N tracks)` suffix; `Download N missing tracks`; sync add uses all selected IDs. Primary action → K-STUDIO-MERGE-PRIMARY.

No context menus exist in P-INSPECTOR (any tab) or S-GROOVE-SIMILAR. *Expected, missing:* right-click on inspector match rows (P-INSPECTOR-SIMILAR) and Similar-sheet rows to get CM-TRACK.

## Sheets, popovers, panels, alerts

### S-GROOVE-SIMILAR — Similar tracks sheet (code: `GrooveView`)
- Reached via: P-INSPECTOR-SIMILAR `Show all` (only shown once the track is analysed) (`MLM/Views/TrackDetail/MetadataPanel.swift:183-186,1084-1086`). Sheet on W-MAIN, min 1040×680 (`MLM/Views/TrackDetail/GrooveView.swift:238`).  ·  Leads to: A-GROOVE-DELETEFILE, downloads (DownloadViewModel), playlists/sync profiles.
- Code: `MLM/Views/TrackDetail/GrooveView.swift:168-1117` (sheet), `MLM/Views/TrackDetail/GrooveView.swift:7-165` (independent preview player), `MLM/Services/Analysis/DiscoveryReviewService.swift:9-84` (accept/delete), `MLM/Services/Analysis/SwarmRecommendationService.swift:16-36,188-196,327-335` (sources, error copy).
- Purpose: from one seed track, see similar tracks in the library and online recommendations; preview, download, keep or delete them.
- User goals: 1. Discover new music like this track from SoundCloud/Last.fm (weekly). 2. Preview candidates quickly (weekly). 3. Download good ones (weekly). 4. Teach MLM what is a good/poor match (rare, implicit).
- What the user wants to see: (1) seed track; (2) local matches ranked; (3) online recommendations, which are already in the library, which are downloading/failed; (4) preview of each; (5) quick add to playlist.
- Elements today:
  - .E01 Header: `sparkles` + `Similar tracks`; `Similar to` `'<title>'` `by` `<artist>`; close `xmark.circle.fill` (tooltip `Close similar tracks`) — stops preview and dismisses.
  - .E02 Left `Local matches` (icon-only refresh `arrow.clockwise`, no tooltip; spinner while loading). Up to 12 rows (`MLM/Views/TrackDetail/GrooveView.swift:842`): 36 pt cover (click = preview / toggle), title, artist, capsule `NN% Match` (green >85, amber >70, grey), `plus.circle` menu (tooltip `Add to playlist`; playlists or `No playlists found`), `arrow.triangle.2.circlepath.circle` menu (tooltip `Add to sync profile`; profiles or `No sync profiles found`), thumbs up (tooltip `Mark as a good match`; filled green once given), thumbs down (tooltip `Mark as a poor match and hide`; row disappears on reload). Double-click row = preview. Empty: `No local matches yet` / `Analyze more tracks in your library to find similar music.`
  - .E03 Right `Recommendations` with segmented `SoundCloud` | `Last.fm` and refresh (icon-only). States: error `Could not load recommendations` + service message (e.g. `Last.fm not configured — add an API key in Settings.`, `SoundCloud is not configured. Add a client ID in Settings.`, `SoundCloud could not load recommendations (HTTP N).`); loading/empty `Searching recommendations…` / `No recommendations found`.
  - .E04 Recommendation rows not in the library: source icon, title, artist, source capsule (`SoundCloud` orange; Last.fm recs show `Lastfm` in red — `src.capitalized` of `lastfm`, `MLM/Views/TrackDetail/GrooveView.swift:622-631`, `MLM/Services/Analysis/SwarmRecommendationService.swift:192`), then `Download` button, or status `Queued…` / spinner `Downloading…` / `Downloaded` / red `Retry`.
  - .E05 Recommendation rows already in the library ("morph" into a local row): as .E02 but with the source capsule instead of %; thumbs up tooltip `Add to library` (marks it approved + positive feedback), thumbs down tooltip `Delete` → A-GROOVE-DELETEFILE.
  - .E06 `Load more` button at the end of the list (+10).
  - .E07 Inline preview deck under the playing row: play/pause, 24 pt seekable waveform, position/duration, stop.
- Interactions: preview plays in a **separate** player that pauses the main player and seeks to the analysed "drop" position if one exists (`MLM/Views/TrackDetail/GrooveView.swift:41-42,86-96`); downloads refresh rows on `.downloadDidComplete`. No context menus, no drag, no keyboard shortcuts, no multi-select.
- States: matching to library uses fuzzy title match against tracks discovered for this seed, then SoundCloud id/permalink, then exact artist+title across the whole library (`MLM/Views/TrackDetail/GrooveView.swift:917-969`). Preview of a missing/offline file: silently nothing (Logs only). Add-to-playlist/sync errors swallowed. Accept/delete/feedback errors → Logs only.
- Pain points: thumbs-down `Delete` on a recommendation that matched an **existing** library track (step 3, exact artist/title) trashes that pre-existing file and removes the track from the library (*inferred from* `MLM/Views/TrackDetail/GrooveView.swift:954-961` + `MLM/Services/Analysis/DiscoveryReviewService.swift:59-69`); thumbs icons carry two different meanings (feedback vs add/delete) in the same row design; `Lastfm` brand typo; icon-only refresh buttons; sheet min width 1040 can exceed a small main window; main player remains paused after preview *(inferred)*; implicit learning signal invisible. LOGIC-019 (late provider results) appears addressed by request IDs (`MLM/Views/TrackDetail/GrooveView.swift:867-915`); UI-001 partly addressed — deletion now goes to the Trash (`MLM/Services/Analysis/DiscoveryReviewService.swift:28-33`) but there is no Undo.
- Related flows: discover, build-playlist.
- Open questions: Should Similar be a sheet, a tab, or part of Discover? How should "already in library" vs "recommended" be distinguished? What does thumbs up/down mean to the user, and should that be visible/reversible?

### A-GROOVE-DELETEFILE — "Delete file?" confirmation
- Trigger: thumbs-down (`Delete`) on a recommendation row that is already in the library (S-GROOVE-SIMILAR.E05). Code: `MLM/Views/TrackDetail/GrooveView.swift:254-265,415-420,1055-1071`, `MLM/Services/Analysis/DiscoveryReviewService.swift:59-69`.
- Content: title `Delete file?`; message `The file will be moved to the Trash.`
- Buttons: `Cancel` (cancel) → nothing; `Delete` (destructive) → stops preview if it is this track, moves the file to the Trash (if it exists), **deletes the track row from the library** (incl. playlist, sync, source rows, `MLM/Database/TrackRepository.swift:490-500`), posts `.libraryDidImport`, reloads both columns.
- Escape: Esc/Cancel. Errors: logged only (`GrooveStudio: Failed to reject track…`). The message does not mention removal from library/playlists; no Undo although recovery data is kept internally (`MLM/Services/Analysis/DiscoveryReviewService.swift:15,65`). Copy differs from UI-GROUNDTRUTH §3.17 (`Delete this file from disk?`).

### A-META-SAVEERROR — "Could not save metadata"
- Trigger: DB write failure when saving a General-tab field. Code: `MLM/Views/TrackDetail/MetadataPanel.swift:187-194,273-275`.
- Content: title `Could not save metadata`; message `Your changes were not saved.` (fallback `Please try again.`).
- Buttons: `OK` (cancel role) → dismiss; the field stays in edit mode with the typed text. No details/cause, no retry button.

### S-STUDIO-EXPORTFOLDER — Choose CreateML destination (NSOpenPanel)
- Trigger: ST-STUDIO-EXPORT `Choose destination…`. Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:1952-1962`.
- Content: folder-only, single selection; title `Choose a destination folder for the CreateML training set`; prompt button `Choose folder`.
- Buttons: `Choose folder` (default) → sets destination; system Cancel → unchanged. Modal (`runModal`); no "New Folder" customisation beyond system default.

## Menu items & keyboard shortcuts (area-local)

- **M-LIBRARY › `More Info` (⌘I)** (owned by shell.md; documented here because it targets P-INSPECTOR): global menu; posts `.showTrackDetail`; **no observer exists → does nothing** (`MLM/App/MLMApp.swift:183-188`, `MLM/Utilities/Notifications.swift:114-115`). UI-GROUNDTRUTH §2.1/§2.6/§3.1 promise ⌘I opens/closes the inspector.
- **K-META-EDIT-RETURN** — Return · save the field being edited · scope: inline field focused in P-INSPECTOR-GENERAL · `MLM/Views/TrackDetail/MetadataPanel.swift:1223-1227`. Silently no-ops on empty Title/Artist or non-integer Year.
- **K-META-EDIT-ESC** — Esc · cancel the inline edit (value discarded) · scope: inline field focused · `MLM/Views/TrackDetail/MetadataPanel.swift:1228-1230`.
- **K-WAVE-PINCH** — trackpad pinch · zoom the waveform 0.5×–8× · scope: P-INSPECTOR-WAVEFORM, tracks ≥ 7 min only (also attached to the Similar/Workshop mini waveforms but those are never scrollable) · `MLM/Views/TrackDetail/WaveformView.swift:111-122`. Reset via P-INSPECTOR-AUDIO `Reset`.
- **K-STUDIO-MERGE-PRIMARY** — double-click (table primary action) · plays the first selected track in the **main** player · scope: ST-STUDIO-MERGE preview table · `MLM/Views/TrackDetail/GrooveStudioView.swift:1303-1312`. Conflicts with the caption `Double-click to preview`.
- Missing (expected): shortcut to close the inspector; ⌘Z after a tag save; Tab/Shift-Tab to move between tag fields (each row is independent, *inferred*); space to preview in S-GROOVE-SIMILAR (daily-driver wish: "spacebar preview", MEMORY/planning).

## Drag & drop

No drag sources or drop targets exist in any file of this area (grep for `onDrag`/`onDrop`/`draggable`/`dropDestination` in `MLM/Views/TrackDetail/` finds none). The resize handle (P-INSPECTOR-WAVEFORM.E04) and waveform scrubbing are drag gestures, not drag & drop.

Expected, missing:
- **D-TD-TRACK-OUT** *(missing)* — drag the inspected track (cover/title) onto a sidebar playlist or into Finder. Evidence: Apple Music behaviour; `.planning/research/v1.4-daily-driver/FEATURES.md:85` (drag selection to sidebar).
- **D-GROOVE-ROW-TO-PLAYLIST** *(missing)* — drag a local match / recommendation row from S-GROOVE-SIMILAR or P-INSPECTOR-SIMILAR onto a playlist. Today only per-row menus.
- **D-TD-ARTWORK-IN** *(missing)* — drop an image onto the inspector cover to set artwork (standard in Music/Get Info); no artwork editing exists in the inspector at all.
- **D-STUDIO-TRACK-TO-GENRE** *(missing)* — drag suggestions onto the genre column instead of thumbs-up staging.

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Drive not connected:** no banner/state in P-INSPECTOR. Availability resolves to `File missing` (`MLM/Models/Track.swift:150-165`, `MLM/Views/TrackDetail/MetadataPanel.swift:1103-1115`); Debug tab says `No local file` / `Download the track…` (`MLM/Views/TrackDetail/DebugTabView.swift:83-95`); analysis buttons and `Show in Finder` silently do nothing (`MLM/Views/TrackDetail/MetadataPanel.swift:635-653,677,720`); play affordance remains (uses stored path, `MLM/Views/TrackDetail/TrackDetailView.swift:71-113`) and the player reports `Playback unavailable: … file could not be found on disk.` (`MLM/ViewModels/PlaybackViewModel.swift:180`). Similar `Analyze this track` fails silently. Workshop/Similar previews silently do not start (`MLM/Views/TrackDetail/GrooveView.swift:57-61`). CreateML export logs per-track `Source file missing` and still reports full success count (`MLM/Views/TrackDetail/GrooveStudioView.swift:2046-2049,2145`). The app pauses playback on unmount (`MLM/Views/ContentView/ContentView.swift:126-133`, main.md's area).
- **Library loading/failed:** inspector exists only inside the initialized main view (`MLM/Views/ContentView/ContentView.swift:64-70,230-253`); Workshop in Settings shows empty/`No genres…` if repositories are unavailable (guards return silently, `MLM/Views/TrackDetail/GrooveStudioView.swift:1666-1681`).
- **Source disconnected / expired:** only in S-GROOVE-SIMILAR.E03 error copy (`SoundCloud is not configured. Add a client ID in Settings.`, `Last.fm not configured — add an API key in Settings.`, HTTP errors) — no reconnect action (`MLM/Services/Analysis/SwarmRecommendationService.swift:16-36`).
- **Background processing:** inspector shows nothing for running downloads/analysis of the shown track except `Status: Downloading` in P-INSPECTOR-FILE. CreateML export borrows the sync concurrency level silently (`MLM/Views/TrackDetail/GrooveStudioView.swift:1970`).
- **Track availability states:** P-INSPECTOR-FILE `Status` row uses the §1.6 vocabulary words (`Local`, `Downloading` without ellipsis, `Not downloaded`, `Download failed`, `File missing`) — the only place in this area; header/other tabs use `isLocal` (= has stored path) instead, so a `File missing` track still shows a play overlay.

### Background work touchpoints

- **Single-track loudness / danceability analysis** (P-INSPECTOR-AUDIO): spinner on the button only; result appears via re-fetch; errors `print()` only; not in Activity; no cancel.
- **Single-track similarity analysis** (P-INSPECTOR-SIMILAR): full-tab spinner + text; error to Logs (`Groove analysis failed`, source `Suggestions`); not in Activity; no cancel.
- **ffmpeg diagnostics** (P-INSPECTOR-DEBUG): loading card; re-runs on every tab visit; no cancel.
- **Waveform extraction** (P-INSPECTOR-WAVEFORM): grey placeholder while the main player extracts/caches peaks (`MLM/ViewModels/PlaybackViewModel.swift:541-650`).
- **Discovery downloads** (S-GROOVE-SIMILAR): per-row `Queued…` / `Downloading…` / `Downloaded` / `Retry`; driven by `DownloadViewModel.discoveryStatuses`; refresh on `.downloadDidComplete` (`MLM/Views/TrackDetail/GrooveView.swift:249-253,633-688,979-988`). Whether these appear in Activity: not verified ("Unresolved from code").
- **Recommendation fetch** (S-GROOVE-SIMILAR): header spinner; error state in the column.
- **Genre save / merge** (ST-STUDIO-GENRE/MERGE): synchronous-feeling DB writes; transient success text / banners.
- **CreateML export** (ST-STUDIO-EXPORT): in-screen progress + Cancel, plus Activity operation `CreateML Export: <folder>` with progress, completion `N tracks exported`, or failure (`Cancelled by user`) (`MLM/Views/TrackDetail/GrooveStudioView.swift:2011-2015,2128-2163`).

### Flow notes

**edit-metadata**
1. Double-click a track in V-LIB → P-INSPECTOR opens (and the track starts playing — user only wanted to edit). ⌘I would be the natural path but does nothing.
2. General tab is pre-selected → click `TITLE` row → field opens.
3. Type, press Return → DB updated, tables refresh. If the title was emptied → nothing happens, no message.
4. Move to `ALBUM`: clicking it while `TITLE` still has unsaved text silently drops that text.
5. Repeat per field, per track — no multi-track editing; to fix 6,209 `unknown album` tracks the user would have to open each one.
6. Breaks: the track ends and the queue advances → inspector switches to the next track while a field is open; Return now writes into the wrong track *(inferred)*. Edits never reach the file tags; a copy shared outside MLM still carries old tags ("Unresolved from code" for sync copies).

**discover** (similar-tracks path; Discover inbox itself is discover.md's)
1. While a track plays, P-INSPECTOR → `Similar` tab.
2. If `No analysis yet` → `Analyze this track` → spinner → matches (or silent failure back to `No analysis yet`).
3. Top 5 matches visible but not clickable → `Show all` → S-GROOVE-SIMILAR.
4. Left: preview local matches (main playback pauses), give thumbs up/down, add to playlist via icon menu.
5. Right: switch `SoundCloud`/`Last.fm`, preview is impossible for non-downloaded recs (no stream preview), `Download` → status badges → row morphs into a local row.
6. Thumbs up = `Add to library` (already downloaded; marks approved); thumbs down = `Delete` → A-GROOVE-DELETEFILE → file to Trash + track removed.
7. Close → preview stops; main playback stays paused *(inferred)*.
- Breaks: risk of deleting a pre-existing library track that merely matched by artist/title; `Lastfm` label; no way to preview remote recommendations before download.

**albums-future** (album fields today)
1. Album information appears in P-INSPECTOR header (`Artist — Album`) and as editable `ALBUM` and `ALBUM ARTIST` free-text rows in P-INSPECTOR-GENERAL.
2. No track number, disc number, album artwork editing, album link, or album-level view exists in this area; the header shows literal `unknown album` (48 % of tracks).
3. Album Artist silently defaults to Artist when cleared.
4. Genre Workshop's merge (ST-STUDIO-MERGE) is the only bulk tag tool and only for genre — there is no analogue for album strings (1,616 distinct album strings across 8,020 album rows, ROADMAP §0.3).
- Breaks: album clean-up at scale is impossible through the UI today; the source-as-album values (`SoundCloud`, `YouTube`…) are edited the same way as real albums.

**daily-listening**
1. Double-click a track → plays + inspector opens.
2. Inspector follows playback as the queue advances; waveform shows the playing track; click the waveform to seek.
3. Quick Add footer adds the playing track to the remembered playlist in one click.
- Breaks: inspector waveform shows the wrong track if the inspector was opened without playing; no spacebar/preview from inspector match lists.

**build-playlist**
1. In P-INSPECTOR footer choose playlist in picker once (remembered) → `Quick Add` per track while listening; or `Add to Playlist…` menu.
2. Confirmation only by the `PLAYLISTS` list in the General tab.
- Breaks: no feedback on other tabs; duplicate add silently ignored *(inferred, `onConflict: .ignore`, `MLM/Database/PlaylistRepository.swift:265`)*; position `999000` ordering issue *(inferred)*.

**review-duplicates**: P-INSPECTOR-FILE duplicate card → `Show in Review` → V-REV focused on this track (`MLM/Views/ContentView/ContentView.swift:162-171`).

**sync-device**: V-SYNC-DETAIL failed row → `Show Details` → P-INSPECTOR for that track without playing (`MLM/Views/Sync/SyncFailedDisclosure.swift:161-165`) — the waveform then shows whatever else is playing.

**fix-failed-downloads**: P-INSPECTOR-FILE shows `Download failed` but no reason and no Retry; Debug tab says `No local file`. The user must go back to the table/context menu to download.

**drive-unplugged**: see "Global-state touchpoints" — every inspector tab reports "missing" or does nothing; no "disk not connected" wording.

**genre-tagging** (area flow)
1. Settings (app menu) → `Advanced` tab → `Genre Workshop` grid.
2. Click a genre → double-click a track on the right → it becomes the reference, plays in the right mini player, suggestions load on the left.
3. Preview suggestions (left player), thumbs up to stage, thumbs down to exclude forever.
4. `Save (N)` → genres written (DB only).
- Breaks: `Genres` back button or closing Settings discards staged edits; `No suggestions found` when the reference simply isn't analysed; all inside a 720×560 settings window.

**createml-export** (area flow): grid → `Export training set (CreateML)` → `Choose destination…` → `Start export` → progress + Activity → `Exported N tracks…` even if some failed.

### Unresolved from code

- Whether sync/transcode copies write DB tags (title/artist/album/genre) into the copied files — only the `mlm_uuid` embedding was found (`MLM/Services/Sync/SyncService.swift:1575-1605`); if not, inspector edits never leave MLM. Needs sync.md agent confirmation.
- Whether Esc dismisses S-GROOVE-SIMILAR (no explicit cancel shortcut in code; depends on SwiftUI sheet default on macOS 15/27).
- Whether `primaryAction` in the library table also fires on Return (SwiftUI behaviour, not verifiable without running).
- Whether discovery downloads started from S-GROOVE-SIMILAR appear in P-ACTIVITY (DownloadViewModel `processDiscoveryQueue`, `MLM/ViewModels/DownloadViewModel.swift:651-760`, not fully traced) and how Last.fm recs (no URL) are resolved for download.
- Number of distinct genre strings in the live library (no live data access); affects ST-STUDIO-GRID size and ST-STUDIO-MERGE list height.
- Whether `playlist_tracks` has a unique (playlist, track) constraint (determines if a second Quick Add of the same track is ignored or duplicates).
- Exact behaviour of `NSWorkspace.activateFileViewerSelecting` with a non-existent absolute path (Show in Finder fallback).
- Whether the ST-ADV TabView keeps Genre Workshop state when switching Settings tabs (SwiftUI TabView retention) — affects loss of staged edits.
- Performance of `fetchSimilarTracks` over ~13k embeddings (`MLM/Database/TrackRepository.swift:1141+`) — no timing evidence.

