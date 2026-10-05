# Main window composition, sidebar, toolbar, player, queue, search, import/download entry points

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): MAIN, SIDEBAR, TOOLBAR, PLAYER, QUEUE, SEARCH, IMPORT · Files covered: `MLM/Views/ContentView/ContentView.swift`, `MLM/Views/Sidebar/SidebarView.swift`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift`, `MLM/Views/Player/PlayerBar.swift`, `MLM/Views/Queue/PlaybackQueueView.swift`, `MLM/Views/Search/GlobalSearchPresentationView.swift`, `MLM/Views/Search/UniversalSearchView.swift`, `MLM/ViewModels/PlaybackViewModel.swift`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift`, `MLM/ViewModels/UniversalSearchViewModel.swift`, `MLM/ViewModels/SearchCoordinator.swift`, `MLM/ViewModels/DownloadViewModel.swift`, `MLM/ViewModels/ImportViewModel.swift` (plus read for context: `MLM/App/MLMApp.swift`, `MLM/Services/Search/UniversalSearchRouter.swift`, `MLM/Services/Search/RemoteTrackMaterializer.swift`, `MLM/Services/Playback/PlaybackQueue.swift`, `MLM/Views/Library/TrackTable.swift`, `MLM/Views/Library/LibraryView.swift`, `MLM/Views/Shared/SpringLoadableHover.swift`)

Reading notes for the designer:
- "Detail" means the large area to the right of the sidebar. "Inspector" is the track detail column (P-INSPECTOR) on the right edge. "Activity" is the panel along the bottom edge (P-ACTIVITY).
- Facts are taken from the code as it is today (2026-10-05). Where a behaviour follows from the code but can only be confirmed visually, it is marked *(inferred)*.

## Surfaces

### V-MAIN-LAYOUT — Main window content (what fills W-MAIN)
- Reached via: launching MLM; the window itself is W-MAIN (owned by shell.md) · Leads to: P-SIDEBAR, P-TOOLBAR, P-PLAYER, V-SEARCH, every detail view (V-LIB, V-PL, V-PLD, V-FOLD, V-SYNC, V-SRC, V-REV, V-DISC, V-QUEUE), P-INSPECTOR, P-ACTIVITY, S-WIZARD, S-ADOPT, V-LAUNCH-NOLIB / V-LAUNCH-CANTOPEN, S-NEWLIB, A-LIB-SWITCH, A-LIB-COPY, S-SEL-* (two sheets), S-SEARCH-UNIVERSAL (unreachable, see below)
- Code: `MLM/Views/ContentView/ContentView.swift:44-212` (root states, sheets and notification handling), `MLM/Views/ContentView/ContentView.swift:230-284` (initialized layout), `MLM/Views/ContentView/ContentView.swift:324-386` (detail router), `MLM/Views/ContentView/ContentView.swift:394-404` (double-click handler), `MLM/Views/ContentView/ContentView.swift:477-507` (error and loading states), `MLM/Views/ContentView/ContentView.swift:521-537` (LibraryHost), `MLM/App/MLMApp.swift:63-76` (window size and style)
- Purpose: the one window where Oliver browses, plays and manages his library. The sidebar on the left picks what the large area on the right shows, the player sits in the window toolbar, track details open as a column on the right, and background work shows in a strip along the bottom.
- User goals:
  1. Move between library, playlists, folders, sync, sources, review, discover and queue without losing his place — daily.
  2. Play music while doing anything else in the window. Player and Activity stay visible in every section — daily.
  3. Double-click a track to play it and see its details at the same time — daily.
  4. Know when the window can't work: still loading, failed to start, no library open, library drive unplugged — rare, but critical when it happens.
- What the user wants to see, in priority order:
  1. The current section's content (track table, grid, etc.).
  2. What is playing and the transport controls (toolbar centre).
  3. Where he is (sidebar selection) and what needs attention (sidebar badges).
  4. Details of the track he's focused on (inspector), only when he asks for them.
  5. Background work, as a compact strip.
- Elements today:
  - V-MAIN-LAYOUT.E01 Sidebar column: a `NavigationSplitView` sidebar, min width 192 pt, initial visibility `.all` (→ P-SIDEBAR). `MLM/Views/ContentView/ContentView.swift:49-50`, `MLM/Views/ContentView/ContentView.swift:234-236`
  - V-MAIN-LAYOUT.E02 Detail column: shows whichever view the sidebar selection points to (`MLM/Views/ContentView/ContentView.swift:354-383`). When the toolbar search pane is open, it shows V-SEARCH instead of any section (`MLM/Views/ContentView/ContentView.swift:326-338`). V-LIB is never torn down: it stays mounted, hidden at opacity 0, while other sections show, which avoids a ~0.5 s rebuild of its ~12,000-row table (`MLM/Views/ContentView/ContentView.swift:340-352`, `MLM/Views/ContentView/ContentView.swift:510-537`).
  - V-MAIN-LAYOUT.E03 Inspector column: `TrackDetailView` (→ P-INSPECTOR). It is placed to the right of the whole split view inside an `HSplitView` with a draggable divider (min 320, ideal 360, max 480 pt). It is **not** a system `.inspector` (`MLM/Views/ContentView/ContentView.swift:233-253`). It opens on double-click of a track in any table that routes through the handler (`MLM/Views/ContentView/ContentView.swift:394-397`), or when another view asks for it via `.openTrackDetailForTrack` (`MLM/Views/ContentView/ContentView.swift:172-192`). It closes via its own close action (`MLM/Views/ContentView/ContentView.swift:248-250`). While open, it follows the now-playing track: when the playing track changes, the inspector switches to it, but it never opens or closes on its own (`MLM/Views/ContentView/ContentView.swift:240-245`). After any import (`.libraryDidImport`) it reloads the inspected track (`MLM/Views/ContentView/ContentView.swift:148-158`).
  - V-MAIN-LAYOUT.E04 Toolbar (→ P-TOOLBAR), attached to the split view (`MLM/Views/ContentView/ContentView.swift:254-271`). The window uses the unified toolbar style (`MLM/App/MLMApp.swift:74-75`).
  - V-MAIN-LAYOUT.E05 A 1 pt separator line, then the Activity panel across the full window width, under sidebar, detail and inspector (`MLM/Views/ContentView/ContentView.swift:273-279`) → P-ACTIVITY.
  - V-MAIN-LAYOUT.E06 First-run overlay: when no library folder is configured, a black 60 % scrim covers the whole window with `FirstRunWizard` on top (→ S-WIZARD, shell.md). Finishing it hides the overlay (`MLM/Views/ContentView/ContentView.swift:69-86`).
  - V-MAIN-LAYOUT.E07 Loading state: a large spinner and `Loading Library...`. Shown while the library launch is resolving, or after it has opened but before the container is initialized (`MLM/Views/ContentView/ContentView.swift:119-121`, `MLM/Views/ContentView/ContentView.swift:497-507`).
  - V-MAIN-LAYOUT.E08 Start-up failure state: a 48 pt red triangle, `Failed to Initialize` and the raw `error.localizedDescription`. There are **no buttons**: no retry, no quit, no "open other library" (`MLM/Views/ContentView/ContentView.swift:95-96`, `MLM/Views/ContentView/ContentView.swift:477-493`).
  - V-MAIN-LAYOUT.E09 Pre-library states, owned by shell.md and only routed here: the adoption sheet over an empty base background (`MLM/Views/ContentView/ContentView.swift:97-108` → S-ADOPT), and the launch placeholder for no library / can't open (`MLM/Views/ContentView/ContentView.swift:109-118` → V-LAUNCH-NOLIB / V-LAUNCH-CANTOPEN).
- Interactions:
  - Double-click a track (or press Return, the table's primary action) in V-LIB, V-PL, V-PLD, V-FOLD or V-SEARCH: the inspector opens with that track, and **if the track is local** it plays, with the rows below it in the visible order queued (capped at 100) (`MLM/Views/ContentView/ContentView.swift:394-404`, `MLM/ViewModels/PlaybackViewModel.swift:132-141`). **If the track is remote, nothing plays and no message appears.** Only the inspector opens.
  - Changing section dismisses the search pane, clears the toolbar search text and removes focus from the field. It also tells search which context it is in: Library, a specific playlist, or "other" (`MLM/Views/ContentView/ContentView.swift:199-211`).
  - Requests from other views, handled here: `.showReview` switches to Review, optionally focused on one track (`MLM/Views/ContentView/ContentView.swift:162-171`). `.openTrackDetailForTrack` opens the inspector, and plays the track if `play` is set and the track is local (`MLM/Views/ContentView/ContentView.swift:172-192`). `.triggerNewPlaylistFromSelection` and `.triggerNewSyncProfileFromSelection` open the selection sheets S-SEL-* (`MLM/Views/ContentView/ContentView.swift:138-147`, `MLM/Views/ContentView/ContentView.swift:193-198`).
  - Library drive unplugged: the sidebar Library row gets its red dot and playback pauses. Plugging it back in clears the dot. Playback does **not** resume (`MLM/Views/ContentView/ContentView.swift:126-137`).
  - Keyboard: ⌘F (→ K-SEARCH-CMDF). ⌘1–⌘8 (→ M-NAVIGATE, shell.md). ←/→ seek ±5 s, ⌘←/⌘→ ±10 s (M-PLAYBACK, shell.md; `MLM/App/MLMApp.swift:67-72`, `MLM/App/MLMApp.swift:145-161`).
- States:
  - default: as above.
  - loading: E07.
  - error: E08 (no recovery action).
  - no library: E09.
  - offline / drive not connected: only the sidebar dot (P-SIDEBAR.E02) and paused playback. Nothing in the detail area comes from this file. V-LIB owns any in-view banner.
  - search active: the detail area is replaced by V-SEARCH, and V-LIB is removed from the view tree while it shows (`MLM/Views/ContentView/ContentView.swift:326-339`). *(inferred)* That costs the ~0.5 s rebuild when the user leaves search.
  - huge data: handled by keeping V-LIB alive (E02).
  - in-progress background work: P-ACTIVITY only, plus the Sync spinner in the sidebar.
- Data scale / performance notes: 12,935 tracks. Keeping V-LIB alive is a deliberate performance trade-off (`MLM/Views/ContentView/ContentView.swift:340-345`). Every section switch resets the search state (`MLM/Views/ContentView/ContentView.swift:199-211`).
- Pain points today:
  - Double-clicking a remote ("Not downloaded") track silently does nothing except open the inspector (`MLM/Views/ContentView/ContentView.swift:399`). UI-GROUNDTRUTH §1.6 wants a contextual action instead.
  - The start-up failure screen has no action (`MLM/Views/ContentView/ContentView.swift:477-493`). LOGIC-003 (bootstrap failure never reached this screen) looks fixed: `initializationError` is now assigned at `MLM/App/DependencyContainer.swift:102`.
  - The inspector is an `HSplitView` pane, not the `.inspector` that UI-GROUNDTRUTH §2.1 specifies (doc-vs-code). Menu `More Info` ⌘I posts `.showTrackDetail`, but nothing listens for it, so ⌘I does nothing (`MLM/App/MLMApp.swift:183-188`; no observer of `.showTrackDetail` exists in `MLM/`).
  - Menu `Import from Folder…` ⌘⇧I posts `.showImportDialog`, and nothing listens for that either (`MLM/App/MLMApp.swift:174-179`). The import entry point in the menu is dead.
  - Drive unplugged is shown only as a 7 pt icon-only dot. This violates the locked rule that critical states are always text.
- Related flows: daily-listening, drive-unplugged, first-launch, switch-library, find-fast.
- Constraints / locked decisions: single `Window("MLM", id: "main")`. Native toolbar stays (no `.hiddenTitleBar`, no floating player). Native macOS look. One active library per process. Critical states always text.
- Open questions for the designer:
  - Should the track inspector be a true trailing inspector, toggleable with ⌘I, and should it follow the playing track or the selected track?
  - What should the window show when start-up fails: which recovery actions, and in which words?
  - When a remote track is double-clicked, what should the user see and be offered?
  - Should the full-window first-run scrim stay an overlay on top of a live but empty window, or be a separate state?

### P-SIDEBAR — Sidebar
- Reached via: always visible on the left (it can be collapsed with the system sidebar toggle, *(inferred)* added automatically by `NavigationSplitView`) · Leads to: V-LIB, V-PL (and P-PINNED → V-PLD), V-FOLD, V-SYNC, V-SRC, V-REV, V-DISC, V-QUEUE, W-SETTINGS
- Code: `MLM/Views/Sidebar/SidebarView.swift:9-281`, `MLM/Views/ContentView/ContentView.swift:548-630` (section labels, icons, shortcuts)
- Purpose: pick which part of the library to look at, and notice at a glance where something needs attention (drive, sync, sign-in, review backlog, recommendations).
- User goals:
  1. Jump to Library or a pinned playlist in one click — daily.
  2. See without clicking that the library drive is unplugged, a sync is running, a source sign-in has expired, or duplicates/conflicts are waiting — daily.
  3. Open the Queue to see what plays next — weekly *(inferred)*.
  4. Open Settings — rare.
- What the user wants to see, in priority order:
  1. The destinations, with the current one highlighted.
  2. His pinned playlists, so he can go straight to their contents.
  3. Warning and attention signals on the affected rows, in words when critical.
  4. Counts of pending work (review, recommendations).
- Elements today (verbatim labels, top to bottom):
  - P-SIDEBAR.E01 Section header `LIBRARY` (`MLM/Views/Sidebar/SidebarView.swift:36-40`).
  - P-SIDEBAR.E02 Row `Library`, icon `music.note.list`. Badge: a red 7 pt dot with tooltip `Library drive disconnected`, shown only while the library drive is unmounted (`MLM/Views/Sidebar/SidebarView.swift:135-143`, `MLM/Views/ContentView/ContentView.swift:590`, `MLM/Views/ContentView/ContentView.swift:604`).
  - P-SIDEBAR.E03 Row `Playlists`, icon `list.bullet`. It is the label of the pinned-playlists disclosure (→ P-PINNED) (`MLM/Views/Sidebar/SidebarView.swift:107-126`).
  - P-SIDEBAR.E04 Row `Folders`, icon `folder` (`MLM/Views/Sidebar/SidebarView.swift:27`).
  - P-SIDEBAR.E05 Row `Sync`, icon `arrow.triangle.2.circlepath`. Badge: a mini spinner with tooltip `Sync in progress`, shown while any sync runs (`MLM/Views/Sidebar/SidebarView.swift:145-153`).
  - P-SIDEBAR.E06 Row `Sources`, icon `globe`. Badge: an amber 7 pt dot with tooltip `A source sign-in has expired` (`MLM/Views/Sidebar/SidebarView.swift:155-163`). It is computed from stored credentials (`MLM/Views/Sidebar/SidebarView.swift:274-280`).
  - P-SIDEBAR.E07 Section header `WORK` (`MLM/Views/Sidebar/SidebarView.swift:49-53`).
  - P-SIDEBAR.E08 Row `Review`, icon `doc.on.doc`. Badge: an amber capsule `‹d› dup · ‹c› conf`, with tooltip and accessibility label `‹d› duplicate groups and ‹c› metadata conflicts need review`, shown when either count is above 0 (`MLM/Views/Sidebar/SidebarView.swift:165-176`, `MLM/Views/Sidebar/SidebarView.swift:252-262`).
  - P-SIDEBAR.E09 Row `Discover`, icon `sparkles`. Badge: a muted number `‹n›`, with tooltip `‹n› recommendations pending`. The count is the Discovery inbox tracks only, not Reels (`MLM/Views/Sidebar/SidebarView.swift:178-186`, `MLM/Views/Sidebar/SidebarView.swift:264-272`).
  - P-SIDEBAR.E10 Footer row `Queue`, icon `list.number`. It is a custom-drawn button pinned at the bottom outside the list, with its own accent-filled highlight when selected, and carries `.keyboardShortcut("8")` (`MLM/Views/Sidebar/SidebarView.swift:198-221`).
  - P-SIDEBAR.E11 Divider, then the footer row `Settings`, icon `gearshape`, which opens the Settings window (`MLM/Views/Sidebar/SidebarView.swift:223-241`) → W-SETTINGS.
- Interactions:
  - Single click: rows are plain buttons inside a selectable list. A click sets the selection and the detail area follows (`MLM/Views/Sidebar/SidebarView.swift:128-134`, `MLM/Views/Sidebar/SidebarView.swift:192-193`).
  - Keyboard: ⌘1 Library, ⌘2 Playlists, ⌘3 Folders, ⌘4 Sync, ⌘5 Sources, ⌘6 Review, ⌘7 Discover, ⌘8 Queue, via the Navigate menu (M-NAVIGATE, shell.md; `MLM/App/MLMApp.swift:107-116`, `MLM/Views/ContentView/ContentView.swift:617-629`). ⌘8 is bound twice (→ K-SIDEBAR-QUEUE8). Shortcut hints are not shown on the rows.
  - Drag & drop: dragging tracks over a row for 600 ms switches to that section, with a pulsing accent outline. Rows do **not** accept the drop (→ D-SIDEBAR-SPRINGLOAD).
  - Right-click: only on pinned playlist rows (→ CM-SIDEBAR-PINNED). Main rows have no context menu.
  - Hover: tooltips on the badges only.
  - Multi-select: none.
- States:
  - default: as above.
  - drive not connected: red dot on Library (icon only, tooltip text).
  - sync running: spinner on Sync.
  - source expired: amber dot on Sources. It refreshes only on first appearance and after an import (`MLM/Views/Sidebar/SidebarView.swift:60-72`), so signing back in elsewhere does not clear it until the next import *(inferred)*.
  - review backlog: capsule on Review. It refreshes on `.reviewQueueDidChange` and `.libraryDidImport` (`MLM/Views/Sidebar/SidebarView.swift:65-71`).
  - recommendations: count on Discover. It refreshes on `.libraryDidImport` and `.downloadDidComplete` (`MLM/Views/Sidebar/SidebarView.swift:68-75`).
  - loading: badges start at 0 until their async counts arrive (`MLM/Views/Sidebar/SidebarView.swift:12-15`). Nothing indicates loading.
  - error: count failures are silent (`try?`).
  - downloads and imports running: no sidebar indicator (only Activity).
- Data scale / performance notes: the Discover count loads the full discovery-inbox track list just to count it (`MLM/Views/Sidebar/SidebarView.swift:267`).
- Pain points today:
  - There are 8 destinations plus Settings, against the 7 + Settings contract. Queue is the eighth (UI-009, UI-GROUNDTRUTH §2.2, Part 6).
  - The Queue footer is styled differently from every other row (custom button with its own selection fill) and sits outside the list.
  - The drive-disconnected and sign-in-expired signals are coloured dots with tooltip-only text (violates "critical states always text").
  - The `SidebarView` doc comment says "⌘1–⌘7", but code binds ⌘8 too (`MLM/Views/Sidebar/SidebarView.swift:7-8`).
  - The section headers are hand-styled with custom fonts and colours instead of system sidebar headers (`MLM/Views/Sidebar/SidebarView.swift:37-39`, `MLM/Views/Sidebar/SidebarView.swift:50-52`). This is relevant to the native-look rule.
- Related flows: daily-listening, drive-unplugged, review-duplicates, discover, sync-device, settings-changes, build-playlist (spring-loading).
- Constraints / locked decisions: native look (system sidebar materials and colours). Glossary words `Library`, `Playlists`, `Folders`, `Sync`, `Sources`, `Review`, `Discover`, `Settings` (UI-GROUNDTRUTH §5.1). Critical states always text.
- Open questions for the designer:
  - Where does Queue live if the sidebar must stay at 7 destinations: player, a toolbar button, or a popover?
  - How should "library drive disconnected" and "sign-in expired" read in words in the sidebar, while staying compact?
  - Should sidebar rows accept dropped tracks (pinned playlists → add; Queue → play next)?
  - Should the ⌘-number shortcuts be visible in the sidebar?
  - Should the Discover badge include Reels items?

### P-PINNED — Pinned playlists (nested under "Playlists" in the sidebar)
- Reached via: the `Playlists` row in P-SIDEBAR (a disclosure triangle). Playlists are pinned elsewhere, in the V-PL grid (playlists.md area) · Leads to: V-PLD (direct), V-PL (label click / `Reveal in Grid`), CM-SIDEBAR-PINNED, A-SIDEBAR-DELETEPL, A-SIDEBAR-RENAMEFAIL
- Code: `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:33-192`, `MLM/Views/Sidebar/SidebarView.swift:107-126`
- Purpose: one-click access to the handful of playlists Oliver plays most, Apple-Music style. The playlist's tracks open directly, with no grid in between.
- User goals:
  1. Open a favourite playlist instantly — daily.
  2. Tidy the list (unpin, rename, delete) without leaving the sidebar — rare.
  3. Drop tracks onto a pinned playlist to add them — wish (not possible today, see D-).
- What the user wants to see, in priority order:
  1. Pinned playlist names, in a stable order.
  2. Which one is open.
  3. *(inferred)* whether a playlist is incomplete or importing (not shown today).
- Elements today:
  - P-PINNED.E01 Disclosure label `Playlists` (icon `list.bullet`). Clicking the label opens the grid (V-PL). Clicking the triangle expands or collapses the list. The expanded state is remembered across launches (`@AppStorage("sidebar.pinnedPlaylists.expanded")`, default expanded) (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:41`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:53`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:67-75`).
  - P-PINNED.E02 Child rows: playlist name with icon `music.note.list`, one line, truncated at the tail, full name as tooltip. **At most 8** are shown (`prefix(8)`), sorted alphabetically (case-insensitive) (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:63-65`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:111-124`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:185-191`).
  - P-PINNED.E03 Empty caption `No pinned playlists`: muted italic, not selectable (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:54-61`).
  - P-PINNED.E04 Inline rename field: the row turns into a rounded text field with the current name, focused (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:94-110`).
- Interactions:
  - Click a child row: selects `playlistDetail(id)`, and V-PLD opens directly (`MLM/Views/ContentView/ContentView.swift:361-368`).
  - Right-click: CM-SIDEBAR-PINNED. While renaming, right-click shows CM-SIDEBAR-PINNEDRENAME.
  - Rename: Return commits, Escape cancels (→ K-SIDEBAR-RENAME). An empty or unchanged name closes the field silently (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:157-165`).
  - Drag & drop: spring-loading on the label and on each child row. Hovering a drag for 600 ms opens the grid or that playlist. Rows don't accept drops (→ D-SIDEBAR-SPRINGLOAD).
  - Refresh: the list reloads on `.playlistDidChange` (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:76-79`).
- States:
  - default: as above.
  - empty: E03.
  - more than 8 pinned: extra pins are silently not shown. The pin limit itself is enforced in V-PL (UI-017).
  - loading: none (empty until loaded).
  - error: load failures are silent (`try?`).
  - rename failed: alert A-SIDEBAR-RENAMEFAIL, after which the field closes and the typed name is lost.
  - deleted while open: the detail view only reloads when the id changes (`MLM/Views/Playlists/PlaylistDetailViewLoader.swift:53-70`), so *(inferred)* a deleted playlist stays on screen until the user navigates away.
- Data scale / performance notes: it loads **all** playlists to filter the pinned ones (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:187`). That is small today.
- Pain points today:
  - UI-013 is partly fixed: a rename failure now raises an alert, but the edit still closes and the input is lost (`MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:166-174`). The alert shows the raw `error.localizedDescription`.
  - Unpin and delete failures are silent: `try?` in `MLM/Views/Sidebar/SidebarView.swift:115`, and the delete error is only logged at `MLM/Views/Sidebar/SidebarView.swift:91-95`.
  - Rows carry no status (importing, incomplete, linked to a source).
  - The 8-item cap is not explained in the sidebar.
- Related flows: daily-listening, build-playlist, import-remote-playlist (the result lives in a playlist).
- Constraints / locked decisions: UI-GROUNDTRUTH §2.2 keeps the context-menu copy (`Unpin from Sidebar`, `Rename…`, `Reveal in Grid`, `Delete`) and the empty text `No pinned playlists`.
- Open questions for the designer:
  - Alphabetical or user-ordered (drag to reorder)?
  - Should a pinned row show progress or failure for a linked playlist that is still downloading?
  - Should the 8-pin limit be visible here?
  - Should the Liked playlist always appear?

### P-TOOLBAR — Window toolbar
- Reached via: always visible at the top of the main window · Leads to: P-PLAYER, V-SEARCH, (section-contributed items) V-LIB actions
- Code: `MLM/Views/ContentView/ContentView.swift:254-271`, `MLM/Views/ContentView/ContentView.swift:664-724` (search field), `MLM/Views/Library/LibraryView.swift:102-133` (Library items), `MLM/Views/Folders/FoldersView.swift:73-79` (Folders item), `MLM/App/MLMApp.swift:74-75`
- Purpose: always-available playback and search, plus a few actions for the current section.
- User goals:
  1. Control playback from anywhere — daily.
  2. Start a search from anywhere (⌘F) — daily.
  3. Shuffle the library or re-scan the library folder — weekly.
  4. Collapse the sidebar — rare.
- What the user wants to see, in priority order: now playing and transport → search field → actions that belong to the current section.
- Elements today (left to right as placed):
  - P-TOOLBAR.E01 Sidebar toggle (system, *(inferred)* added by `NavigationSplitView`; no explicit code).
  - P-TOOLBAR.E02 `.principal` (centred): the player (→ P-PLAYER), shown only when a playback view model exists (`MLM/Views/ContentView/ContentView.swift:255-259`).
  - P-TOOLBAR.E03 `.primaryAction`: the search field (→ V-SEARCH.E01), 240 pt wide, a custom rounded background (not `.searchable`), placeholder `Search…` (`MLM/Views/ContentView/ContentView.swift:260-270`, `MLM/Views/ContentView/ContentView.swift:670-717`).
  - P-TOOLBAR.E04 Contributed by V-LIB, `.primaryAction`: `Shuffle` (icon `shuffle`, tooltip `Shuffle play library`, disabled when the Library table is empty) and `Re-scan Library` (icon `arrow.clockwise`, tooltip `Re-scan the library folder for changes`, ⌘R). While re-scanning, this button becomes a small spinner (`MLM/Views/Library/LibraryView.swift:102-133`). Because V-LIB stays mounted (hidden) in every section, *(inferred, needs visual confirmation)* these two items stay in the toolbar on **every** section except while the search pane is open (V-LIB is removed then, `MLM/Views/ContentView/ContentView.swift:326-339`).
  - P-TOOLBAR.E05 Contributed by V-FOLD, `.automatic`: the muted text `‹n› folders` (`MLM/Views/Folders/FoldersView.swift:73-79`).
- Interactions: click; ⌘F focuses the search field (K-SEARCH-CMDF); ⌘R re-scans (owned by library.md; the same key is bound in `MLM/Views/Sync/SyncProfileDetailView.swift:144`).
- States:
  - no playback view model: the centre is empty.
  - while searching: the Library items disappear *(inferred)*.
  - while re-scanning: E04 shows a spinner.
- Data scale / performance notes: the player has a minimum width of 440 pt (P-PLAYER), and the search field has a fixed 240 pt. At the minimum window width of 900 pt, toolbar crowding is likely *(inferred)*.
- Pain points today:
  - UI-GROUNDTRUTH §2.3 says "No other items". The code adds Shuffle, Re-scan Library and `‹n› folders` (doc-vs-code).
  - The placeholder is `Search…`, not `Search library…` (§2.3, §5.1).
  - The scope picker `Library · All sources` sits in the search pane header, not inline in the toolbar (§2.3).
  - UI-010 (the extra globe button) has been resolved by removing the button. That also removed the only way to open S-SEARCH-UNIVERSAL.
  - Section actions from a hidden view leaking into other sections' toolbars *(inferred)*.
- Related flows: daily-listening, find-fast.
- Constraints / locked decisions: the native toolbar stays. `.principal` centres between the leading and trailing groups, not in the window (ROADMAP §3 B1). No floating player.
- Open questions for the designer:
  - Which per-section actions earn a toolbar slot, and how should they appear or disappear per section?
  - Should the search field be the system search field (`.searchable`) for native look?
  - Where should the scope choice (Library / All sources) live?

### P-PLAYER — Player bar (in the toolbar)
- Reached via: always in the toolbar centre · Leads to: S-PLAYER-COVER; nothing else (no link to the queue, inspector or track location)
- Code: `MLM/Views/Player/PlayerBar.swift:8-258`, `MLM/ViewModels/PlaybackViewModel.swift:17-697`, `MLM/Services/Playback/PlaybackQueue.swift:55-121`
- Purpose: see what's playing and control it without leaving the current screen.
- User goals:
  1. Play, pause and skip — daily.
  2. Know what's playing (title, artist) — daily.
  3. Scrub within the track — daily.
  4. Change volume — weekly.
  5. Understand why something didn't play, and retry — weekly.
  6. *(wish)* Press space to play or pause the selected track (`.planning/REQUIREMENTS.md:186-190` PLAY-01..03, `.planning/PROJECT.md:40`).
- What the user wants to see, in priority order: play/pause state → title → artist → position/duration → artwork → volume → errors in words, with a fix.
- Elements today:
  - P-PLAYER.E01 Back button (icon `backward.fill`), disabled with no track. Back restarts the track if more than 7 s in, otherwise plays the previous track from history (`MLM/Views/Player/PlayerBar.swift:41-52`, `MLM/ViewModels/PlaybackViewModel.swift:425-470`, `MLM/Services/Playback/PlaybackQueue.swift:44`).
  - P-PLAYER.E02 Play/Pause button (`play.fill` / `pause.fill`), disabled with no track (`MLM/Views/Player/PlayerBar.swift:54-63`).
  - P-PLAYER.E03 Forward button (icon `forward.fill`), disabled with no track. It plays the next queued track. **If the queue is empty, it stops and unloads** (`MLM/Views/Player/PlayerBar.swift:65-76`, `MLM/ViewModels/PlaybackViewModel.swift:409-419`).
  - P-PLAYER.E04 Cover thumbnail, 40 × 40 pt. Clicking it toggles a large-cover popover when a track is loaded (→ S-PLAYER-COVER) (`MLM/Views/Player/PlayerBar.swift:84-98`).
  - P-PLAYER.E05 Title (12 pt semibold, one line) and subtitle `‹artist› · ‹album›` (10 pt secondary, one line, empty parts dropped). The column is only 80–160 pt wide (`MLM/Views/Player/PlayerBar.swift:123-135`, `MLM/Views/Player/PlayerBar.swift:164`, `MLM/Views/Player/PlayerBar.swift:253-257`). The album may literally read `YouTube` / `SoundCloud` / `Downloads` / `Web` (source-as-album, see S-SEARCH-UNIVERSAL).
  - P-PLAYER.E06 Idle text `Not Playing` (`MLM/Views/Player/PlayerBar.swift:158-161`).
  - P-PLAYER.E07 Error line: a red triangle plus the error text (one line, truncated), and a bordered `Retry` button when a specific track failed (`MLM/Views/Player/PlayerBar.swift:136-157`, `MLM/Views/Player/PlayerBar.swift:168-187`).
  - P-PLAYER.E08 Elapsed time (left of the scrubber) and duration (right), `m:ss`. Both read `—:——` with no track (`MLM/Views/Player/PlayerBar.swift:193-196`, `MLM/Views/Player/PlayerBar.swift:211-214`).
  - P-PLAYER.E09 Scrubber slider, disabled with no track. The seek is applied when the user releases (`MLM/Views/Player/PlayerBar.swift:198-209`).
  - P-PLAYER.E10 Volume icon (`speaker.slash.fill` < 1 %, `speaker.fill` < 40 %, else `speaker.wave.2.fill`) and a 76 pt slider. It starts at 100 % on every launch and is not persisted (`MLM/Views/Player/PlayerBar.swift:13`, `MLM/Views/Player/PlayerBar.swift:221-236`, `MLM/Views/Player/PlayerBar.swift:247-251`).
- Interactions:
  - Click: buttons, cover, scrubber, volume.
  - Keyboard (owned by shell.md M-PLAYBACK): `Play`/`Pause` (no shortcut), `Stop` ⌘., `Previous Track`, `Next Track` (no shortcut), `Skip Back 10s` ⌘←, `Skip Forward 10s` ⌘→. ←/→ seek ±5 s, and holding repeats every 100 ms after 500 ms (`MLM/App/MLMApp.swift:119-163`, `MLM/App/MLMApp.swift:205-230`). **No spacebar binding exists anywhere** (no `.space` shortcut in `MLM/`).
  - System media keys and Control Center (play, pause, toggle, next, previous) via `MLM/Services/Playback/RemoteCommandService.swift:72-99`, fed by the `.playbackTrackDidChange` / `.playbackStateDidChange` posts (`MLM/ViewModels/PlaybackViewModel.swift:678-696`).
  - No right-click, no drag (the cover can't be dragged to a playlist), no hover affordances.
- States:
  - nothing playing: transport greyed out and disabled, cover placeholder, `Not Playing`, times `—:——`, scrubber disabled. The volume stays enabled.
  - playing / paused: the icon toggles. The now-playing row in any track table shows a speaker icon and accent colour while playing (`MLM/Views/Library/TrackTable.swift:125-134`).
  - remote track: never started from a double-click (see V-MAIN-LAYOUT). If a remote track is reached through the queue (auto-advance, Next, a Queue double-click), `loadAndPlay` finds no local file and shows `Playback unavailable: ‹title› — file could not be found on disk.` plus `Retry`. That wording is wrong for a track that was never downloaded (`MLM/ViewModels/PlaybackViewModel.swift:165-187`).
  - missing file: the same text `Playback unavailable: ‹title› — file could not be found on disk.` plus `Retry`. If another track was playing, it **keeps playing**, and the error appears under the old track's title, naming the new one (`MLM/ViewModels/PlaybackViewModel.swift:153-188`, LOGIC-031).
  - unsupported format (load throws): any previous track is cleared and stopped, and the error text is format-specific: `Opus is not supported by macOS audio. Download an AAC version or transcode it to M4A.` / `Vorbis/Ogg is not supported by macOS audio. Transcode it to M4A.` / `WebM is not supported by macOS audio. Transcode it to M4A.`, otherwise `Playback unavailable: ‹name› — ‹system error›` (`MLM/ViewModels/PlaybackViewModel.swift:228-244`, `MLM/ViewModels/PlaybackViewModel.swift:258-262`).
  - control errors (toggle, seek, back): the raw `error.localizedDescription` is shown in E07 (`MLM/ViewModels/PlaybackViewModel.swift:302-304`, `MLM/ViewModels/PlaybackViewModel.swift:350-352`).
  - drive offline: playback is paused automatically on unmount (`MLM/Views/ContentView/ContentView.swift:126-133`). The player keeps showing the paused track. What Play does then is not determinable from code ("Unresolved from code"). New play attempts fail with the generic "file could not be found on disk" text, with no mention of the drive.
  - end of queue: playback stops and unloads, and the player returns to `Not Playing` (`MLM/ViewModels/PlaybackViewModel.swift:391-398`).
- Data scale / performance notes: the position is polled every 50 ms while playing (`MLM/ViewModels/PlaybackViewModel.swift:493-500`). A waveform is decoded and cached for every played track, though the player bar never shows it (`MLM/ViewModels/PlaybackViewModel.swift:543-651`).
- Pain points today:
  - **The queue stalls at an unplayable track.** The queue is only committed on a successful load, so after a failure, Next or auto-advance retries the same remote or missing track forever. The user must double-click another track (`MLM/ViewModels/PlaybackViewModel.swift:391-419`, `MLM/Services/Playback/PlaybackQueue.swift:55-62`).
  - No spacebar play/pause, even though it is the core of the daily-driver wish (PLAY-01..03). `.planning/STATE.md:57` claims a spacebar CommandMenu, but the Swift Playback menu has no shortcut for `Play`/`Pause`.
  - Error copy is raw or misleading. UI-GROUNDTRUTH §2.4 wants `File missing` / `Download failed` plus `Show in Review` / `Retry`.
  - LOGIC-031 is partly fixed: history and queue are now committed only on success (`MLM/ViewModels/PlaybackViewModel.swift:118-141`, `MLM/ViewModels/PlaybackViewModel.swift:264-271`). The missing-file branch still leaves A playing while the error names B.
  - Title column capped at 160 pt.
  - Doc-vs-code: §2.4 says the previous/next buttons are permanently disabled, but they are wired today. §2.4 says times should be hidden when idle, but they show `—:——`.
  - No access to the queue, the inspector or the track's location from the player.
- Related flows: daily-listening, drive-unplugged, fix-failed-downloads.
- Constraints / locked decisions: the player stays in the native toolbar `.principal` slot. No floating player. Critical states in text.
- Open questions for the designer:
  - What does the player show and offer for: never-downloaded track, file missing, drive unplugged, unsupported format?
  - Should Next skip unplayable tracks automatically, and how is that communicated?
  - Should the player expose the queue (button or popover) and "show playing track in library"?
  - Space bar: global play/pause, or "play selected row"?
  - Should the volume persist?
  - Is a waveform or scrubber preview wanted in the bar?

### V-QUEUE — Queue
- Reached via: sidebar footer `Queue` (P-SIDEBAR.E10), ⌘8 (twice, K-SIDEBAR-QUEUE8) · Leads to: P-PLAYER (playback), CM-TRACK
- Code: `MLM/Views/Queue/PlaybackQueueView.swift:6-147`, `MLM/ViewModels/PlaybackViewModel.swift:82-89`, `MLM/ViewModels/PlaybackViewModel.swift:474-488`, `MLM/Services/Playback/PlaybackQueue.swift:55-121`
- Purpose: see what played, what's playing and what plays next, and jump to any of them.
- User goals:
  1. See what comes next after the current track — weekly.
  2. Jump ahead to a queued track — weekly.
  3. Replay something from recent history — weekly.
  4. *(wish, inferred)* reorder, remove or clear queued tracks. Today the only way to add is `Play Next` in CM-TRACK.
- What the user wants to see, in priority order: Next up (in order) → currently playing → history (most recent first).
- Elements today:
  - V-QUEUE.E01 Section header `History`, then a track table of played tracks, most recent first. The history keeps 50 by default (`playback_history_size`, set in ST-PLAYBACK) (`MLM/Views/Queue/PlaybackQueueView.swift:15-20`, `MLM/Views/Queue/PlaybackQueueView.swift:66-85`, `MLM/ViewModels/PlaybackViewModel.swift:666-669`).
  - V-QUEUE.E02 Section header `Currently playing`, then a one-row track table, 64 pt tall (`MLM/Views/Queue/PlaybackQueueView.swift:24-29`, `MLM/Views/Queue/PlaybackQueueView.swift:89-108`).
  - V-QUEUE.E03 Section header `Next up`, then a track table: "Play Next" items first, then the context (rows below the clicked track, max 100 by default, `playback_context_cap`) (`MLM/Views/Queue/PlaybackQueueView.swift:33-38`, `MLM/Views/Queue/PlaybackQueueView.swift:112-131`, `MLM/ViewModels/PlaybackViewModel.swift:671-674`).
  - Each table is the full shared track table: Title (with cover and playing indicator), Artist, Album, Time, Format, Status, kbps, Genre, Year, Energy, Dance, BPM, Added (`MLM/Views/Library/TrackTable.swift:117-219`).
  - V-QUEUE.E04 Empty texts: `No history yet` (icon `clock`), `Nothing playing` (`pause.circle`), `Queue is empty` (`list.number`) (`MLM/Views/Queue/PlaybackQueueView.swift:79-81`, `MLM/Views/Queue/PlaybackQueueView.swift:102-104`, `MLM/Views/Queue/PlaybackQueueView.swift:125-127`, `MLM/Views/Queue/PlaybackQueueView.swift:135-146`).
  - V-QUEUE.E05 No-playback fallback: `No Playback` / `Playback is not available.` (icon `speaker.slash`) (`MLM/Views/Queue/PlaybackQueueView.swift:39-45`).
- Interactions:
  - Double-click a History row: plays it and **clears the context part of Next up** (Play Next items stay) (`MLM/Views/Queue/PlaybackQueueView.swift:75-78`, `MLM/ViewModels/PlaybackViewModel.swift:118-125`).
  - Double-click the Currently playing row: restarts it and clears the context the same way (`MLM/Views/Queue/PlaybackQueueView.swift:98-101`).
  - Double-click a Next up row: plays it and drops everything before it (`MLM/Views/Queue/PlaybackQueueView.swift:121-124`, `MLM/Services/Playback/PlaybackQueue.swift:113-121`).
  - Right-click: CM-TRACK. No playlists or sync profiles are passed, so *(inferred)* the add-to-playlist and add-to-sync-profile submenus are empty here.
  - Drag: rows can be dragged out as tracks (D-QUEUE-ROWS). No dropping or reordering inside the queue.
  - Column headers: clicking them changes the sort indicator (initially Added, descending) but **does not re-sort** the rows, because no sort handler is passed (`MLM/Views/Library/TrackTable.swift:58-62`, `MLM/Views/Library/TrackTable.swift:245-264`).
  - Multi-select: allowed (the selection is a set) and only useful for CM-TRACK.
  - Double-clicks in the queue do not open the inspector (unlike other tables).
- States:
  - empty: E04 per section.
  - no playback service: E05.
  - unplayable track in Next up: the player stalls on it (see P-PLAYER).
  - not persisted: the queue and history are in memory only and are lost on relaunch (`MLM/ViewModels/PlaybackViewModel.swift:83-86`).
  - Status chips: none, because availability data is not passed to these tables (`MLM/Views/Library/TrackTable.swift:37`). A remote track in the queue looks local apart from its Format.
- Data scale / performance notes: up to 100 + Play Next rows. Three full 13-column tables stacked vertically, with fixed min heights 150 / 64 / 150 pt.
- Pain points today:
  - It is an eighth sidebar destination (UI-009).
  - There are no queue-editing actions.
  - The sort headers are inert.
  - Replaying from history silently discards the upcoming context.
  - There are no availability chips.
  - Section header casing differs from the sidebar's uppercase headers.
- Related flows: daily-listening.
- Constraints / locked decisions: `.planning/REQUIREMENTS.md:177` (v1.4 era) declared playback "preview-grade" with full queue management out of scope. The Swift app nevertheless ships a queue. Treat queue editing as an open wish, not a commitment.
- Open questions for the designer:
  - Is the queue a destination (sidebar) or a transient panel attached to the player?
  - Which queue edits are needed (remove, reorder, clear, save as playlist)?
  - Should history replay keep or replace what's next?
  - Which columns are useful in a queue?

### V-SEARCH — Toolbar search field and search results pane
- Reached via: clicking the toolbar search field, ⌘F (K-SEARCH-CMDF), menu `Library > Search Library` (M-LIBRARY, shell.md; it posts `.searchCommandTriggered`, `MLM/App/MLMApp.swift:165-170`, `MLM/Views/ContentView/ContentView.swift:159-161`) · Leads to: P-PLAYER / P-INSPECTOR (double-click), CM-TRACK, D-SEARCH-ROWS
- Code: `MLM/Views/ContentView/ContentView.swift:659-724` (field), `MLM/ViewModels/SearchCoordinator.swift:13-61`, `MLM/Views/ContentView/ContentView.swift:324-338` (pane routing), `MLM/Views/Search/GlobalSearchPresentationView.swift:5-211`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:8-247`, `MLM/Services/Search/RemoteTrackMaterializer.swift:17-58`, `MLM/Services/Search/SearchResultsMerger.swift:13-40`
- Purpose: find a track fast, either in the library or across connected sources (SoundCloud, Spotify, YouTube, DAB).
- User goals:
  1. Filter the visible Library or playlist table by typing — daily.
  2. Find any track in the library from anywhere — daily.
  3. Look a track up on the sources when it's not in the library — weekly *(inferred from the All-sources scope)*.
  4. Play or inspect a result — daily.
- What the user wants to see, in priority order: matching tracks immediately, best match first → where each result comes from (library vs. which source), whether it is playable or needs downloading → which sources failed → a way to download remote hits.
- Elements today:
  - V-SEARCH.E01 Search field: a `magnifyingglass` icon and the text field `Search…`. Its accessibility label is `Search library`. It applies typing after a 100 ms debounce (`MLM/Views/ContentView/ContentView.swift:670-694`, `MLM/Views/ContentView/ContentView.swift:715-716`).
  - V-SEARCH.E02 Clear button (`xmark.circle.fill`), shown while text is present. It clears the text, closes the pane and unfocuses the field (`MLM/Views/ContentView/ContentView.swift:695-709`).
  - V-SEARCH.E03 Pane title `Search` (`MLM/Views/Search/GlobalSearchPresentationView.swift:35-38`).
  - V-SEARCH.E04 Scope segmented control `Library` | `All sources`, 220 pt wide, default `Library`. It resets each time the pane opens (`MLM/Views/Search/GlobalSearchPresentationView.swift:14`, `MLM/Views/Search/GlobalSearchPresentationView.swift:42-48`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:16-21`).
  - V-SEARCH.E05 Progress: `Preparing search…` (the view model is being built), then `Searching library…` or `Searching sources…` (`MLM/Views/Search/GlobalSearchPresentationView.swift:24`, `MLM/Views/Search/GlobalSearchPresentationView.swift:72-74`).
  - V-SEARCH.E06 Empty-query prompt: `Search library` / `Type in the toolbar search field to search your library.` (icon `magnifyingglass`) (`MLM/Views/Search/GlobalSearchPresentationView.swift:75-81`).
  - V-SEARCH.E07 Error line (red, triangle): `Could not search the library. Try again.` or `Could not save remote results. Try again.` (`MLM/Views/Search/GlobalSearchPresentationView.swift:90-97`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:100`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:121`).
  - V-SEARCH.E08 Source-failure notice (amber): `‹n› sources unreachable — results incomplete`, with a disclosure `Details` listing `‹Source›: ‹raw error message›`. The source names are `SoundCloud`, `Spotify`, `YouTube` and `DAB` (`MLM/Views/Search/GlobalSearchPresentationView.swift:99-120`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:157-241`).
  - V-SEARCH.E09 Results: one merged track table (the same 13 columns as the Library). Order: tracks of the current playlist (when searching from V-PLD), then library matches (max 500), then remote hits. **There are no group headers, no source label column and no download button** (`MLM/Views/Search/GlobalSearchPresentationView.swift:122-142`, `MLM/Services/Search/SearchResultsMerger.swift:13-40`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:138-143`).
  - V-SEARCH.E10 No results: the system "no results" view for the query (`ContentUnavailableView.search(text:)`; system copy) (`MLM/Views/Search/GlobalSearchPresentationView.swift:137-140`).
- Interactions:
  - Typing in **Library** or **playlist detail**: live-filters that table in place, and the pane does not open. In **any other section**, typing opens the pane (`MLM/ViewModels/SearchCoordinator.swift:55-60`, `MLM/Views/ContentView/ContentView.swift:263-268`).
  - Return: always opens the pane, even with an empty field, which then shows E06 (`MLM/Views/ContentView/ContentView.swift:677-682`, `MLM/ViewModels/SearchCoordinator.swift:40-42`).
  - Escape inside the pane: closes it and clears the query (`MLM/Views/Search/GlobalSearchPresentationView.swift:30`, `MLM/Views/ContentView/ContentView.swift:329-333`).
  - Changing section: closes the pane and clears the query (`MLM/Views/ContentView/ContentView.swift:199-202`).
  - Changing scope: re-runs the search (`MLM/Views/Search/GlobalSearchPresentationView.swift:57-59`, `MLM/Views/Search/GlobalSearchPresentationView.swift:66-68`).
  - Double-click a result: the inspector opens. Local results play, with all results below them queued, including remote ones (see the P-PLAYER stall). Remote results don't play and show no message (`MLM/Views/Search/GlobalSearchPresentationView.swift:127-133`, `MLM/Views/ContentView/ContentView.swift:335-337`).
  - Right-click: CM-TRACK, with playlists and sync profiles loaded (`MLM/Views/Search/GlobalSearchPresentationView.swift:134-135`, `MLM/Views/Search/GlobalSearchPresentationView.swift:153-165`). Download of remote hits is presumably via CM-TRACK (library.md owns it).
  - Drag: D-SEARCH-ROWS.
  - Sort headers: inert, as in V-QUEUE (no sort handler passed).
- States:
  - preparing: E05.
  - empty query: E06.
  - searching: the whole results area is replaced by the spinner on every keystroke-driven search *(inferred)*.
  - error: E07 above the (possibly empty) table.
  - partial source failure: E08.
  - no results: E10.
  - All sources: **nothing is shown until every source has answered**. Library hits are not shown first (`MLM/ViewModels/GlobalSearchPresentationViewModel.swift:104-133`).
  - no sources connected: SoundCloud and Spotify are skipped, but YouTube (yt-dlp) is always queried and DAB whenever token storage exists, so the scope control always shows (`MLM/Views/Search/GlobalSearchPresentationView.swift:172-204`).
  - expired sign-in: credentials still exist, so the source is queried, fails, and appears in E08 with a raw message *(inferred)*.
  - drive offline: search still works, because it runs on the database.
  - huge data: the library limit is 500 rows.
- Data scale / performance notes:
  - The search is debounced 100 ms. Requests are stamped, so stale responses are dropped (`MLM/ViewModels/GlobalSearchPresentationViewModel.swift:59-61`, `MLM/ViewModels/GlobalSearchPresentationViewModel.swift:91`).
  - **Every All-sources search permanently writes each new remote hit into the library database** as a remote track. Its album is set to the source name (`SoundCloud` / `Spotify` / `YouTube` / `DAB`) and it gets a `track_sources` link (`MLM/ViewModels/GlobalSearchPresentationViewModel.swift:108-123`, `MLM/Services/Search/RemoteTrackMaterializer.swift:39-52`). These rows then appear in Library's Remote tab *(inferred)*.
- Pain points today:
  - Remote search pollutes the library with source-as-album rows (second write site, not listed in ROADMAP §0.3).
  - There are no per-source groups or labels and no per-row download, and remote rows have no `Not downloaded` chip (UI-GROUNDTRUTH §3.13 rules 3–4).
  - There is no link mode (§3.13 rule 5). The pane cannot resolve a pasted URL.
  - The All-sources scope waits for the slowest source.
  - The field placeholder diverges from `Search library…`.
  - ⌘F is caught by a local event monitor for **all** MLM windows, so ⌘F in the Settings or remote-playlists window jumps focus back to the main search field *(inferred)* (`MLM/Views/ContentView/ContentView.swift:290-303`).
  - The menu item `Search Library` shows no ⌘F shortcut (`MLM/App/MLMApp.swift:166-170`).
  - The Library and playlist-detail tables filter in place, while other sections open a pane. That is two behaviours for one field.
  - LOGIC-012 (playlist id dropped) is fixed: `MLM/Views/Search/GlobalSearchPresentationView.swift:205-208`.
- Related flows: find-fast, import-remote-playlist (looking up a track), daily-listening.
- Constraints / locked decisions: one search entry point (UI-GROUNDTRUTH §3.13 rule 1). English. No raw errors in alerts (§3.17). Glossary: `Not downloaded`, `Download failed`.
- Open questions for the designer:
  - Should typing ever filter in place, or always open results?
  - How are remote hits distinguished from library tracks, and how are they downloaded from the results?
  - Should remote hits stay transient until the user acts on them, rather than being saved to the library?
  - Where does pasting a URL go (link mode)?
  - How should partial source failure read?

### S-SEARCH-UNIVERSAL — Universal search panel ("Paste a URL or search for music…")
- Reached via: **nothing today**. `showUniversalSearch` is declared `false` and only ever set back to `false` (`MLM/Views/ContentView/ContentView.swift:52`, `MLM/Views/ContentView/ContentView.swift:87-94`). The globe toolbar button that used to open it was removed (UI-010). The view's own comment promises "pastes a URL in the toolbar search field or presses ⌘K (future)" (`MLM/Views/Search/UniversalSearchView.swift:10-11`), and the coordinator comment promises "a separate toolbar button" (`MLM/ViewModels/SearchCoordinator.swift:10-12`). Neither exists. · Leads to: (if reachable) download into the library via `handleUniversalDownload` → P-ACTIVITY
- Code: `MLM/Views/Search/UniversalSearchView.swift:12-448`, `MLM/ViewModels/UniversalSearchViewModel.swift:4-169`, `MLM/Services/Search/UniversalSearchRouter.swift:32-69`, `MLM/Views/ContentView/ContentView.swift:406-473` (download handler)
- Purpose (as designed): paste any YouTube, SoundCloud, direct-audio or web link and download it into the library, or type text to search.
- User goals (from code intent; wish while unreachable):
  1. Paste a single-track URL and download it — weekly.
  2. Paste a playlist URL and import it — weekly (the button is disabled, and the flow points to Sources/W-REMOTE).
  3. Quick text search — duplicate of V-SEARCH.
- What the user wants to see: what was detected (source, title, artist, artwork) → one clear action → progress or result of that action.
- Elements today (presented as a `.sheet` containing a 680 pt panel over a 40 % black backdrop):
  - .E01 Search bar: a `magnifyingglass` icon and a text field with prompt `Paste a URL or search for music…`, focused on open (`MLM/Views/Search/UniversalSearchView.swift:54-74`).
  - .E02 Source tag chip, from the typed text: `YouTube · Playlist`, `YouTube · Video`, `SoundCloud · Playlist`, `SoundCloud`, `Spotify`, `Web Page`, `Search` (`MLM/Views/Search/UniversalSearchView.swift:77-122`).
  - .E03 Idle body: a `link` icon and `Paste a YouTube, SoundCloud, or direct audio URL` (`MLM/Views/Search/UniversalSearchView.swift:146-157`).
  - .E04 `Resolving…` with a spinner, and `Searching…` with a spinner (`MLM/Views/Search/UniversalSearchView.swift:159-181`).
  - .E05 Detected card: section label `DETECTED`, artwork (48 pt, from the source thumbnail, or a source-tinted placeholder with icon), title (fallbacks `YouTube Video`, `SoundCloud Track`, the filename for direct audio, `Unknown Track` for web pages), and subtitle `‹artist› · ‹YouTube | SoundCloud | Audio File | Web›`. Button `Download` (prominent) (`MLM/Views/Search/UniversalSearchView.swift:183-196`, `MLM/Views/Search/UniversalSearchView.swift:281-327`, `MLM/ViewModels/UniversalSearchViewModel.swift:56-128`).
  - .E06 Playlist card: section label `PLAYLIST`, `Playlist detected`, the pasted URL, and the button `Import`, **disabled**, with tooltip `Playlist imports are not available from this search panel. Use Sources to import a playlist.` (`MLM/Views/Search/UniversalSearchView.swift:198-228`).
  - .E07 Text results: section label `RESULTS`, then title/artist rows (max 50 local library matches) or `No matching tracks`. The rows are not clickable (`MLM/Views/Search/UniversalSearchView.swift:230-262`, `MLM/ViewModels/UniversalSearchViewModel.swift:144-160`).
  - .E08 Error: a triangle and `Library search is unavailable.` or `Could not search the library. Please try again.` (`MLM/Views/Search/UniversalSearchView.swift:264-275`, `MLM/ViewModels/UniversalSearchViewModel.swift:148`, `MLM/ViewModels/UniversalSearchViewModel.swift:158`).
  - .E09 Footer hints: `↵ to action · tab to navigate · esc to close` and `⌘K to reopen` (`MLM/Views/Search/UniversalSearchView.swift:364-380`).
- Interactions:
  - Return submits the field (it re-resolves; it does **not** press `Download`). Escape or a click on the backdrop closes it. ⌘K is not bound anywhere.
  - `Download` calls `handleUniversalDownload` (`MLM/Views/ContentView/ContentView.swift:90-92`). It:
    - creates a library track with artist = resolved uploader or `Unknown Artist`, title = resolved title or `Unknown Title`, **album = `YouTube` / `SoundCloud` / `Downloads` / `Web`**, format `audio` (direct) or `youtube` (everything else, including SoundCloud), and original path = the URL (`MLM/Views/ContentView/ContentView.swift:424-441`);
    - links it to a source row named `YouTube` / `SoundCloud` / `Direct` / `Web` (`MLM/Views/ContentView/ContentView.swift:445-453`, `MLM/Views/ContentView/ContentView.swift:466-473`);
    - starts a one-track download pinned to SoundCloud or YouTube (auto for the others), passing the artwork URL for embedding (`MLM/Views/ContentView/ContentView.swift:416-422`, `MLM/Views/ContentView/ContentView.swift:455-462`).
  - The panel stays open, the button stays enabled, and nothing in the panel reports progress or outcome.
- States:
  - idle, resolving, searching, resolved, playlist, results, error (`MLM/ViewModels/UniversalSearchViewModel.swift:4-26`).
  - Spotify URLs are routed to *text search of the URL string* in the local library (`MLM/Services/Search/UniversalSearchRouter.swift:63-64`). The likely result is `No matching tracks` *(inferred)*.
  - yt-dlp missing: no metadata, and the title falls back to `YouTube Video` (`MLM/ViewModels/UniversalSearchViewModel.swift:65-73`).
  - Another download batch running: the new download is **silently rejected** (log only), but the track row has already been inserted, leaving an orphan `Not downloaded` track (`MLM/ViewModels/DownloadViewModel.swift:195-198`, `MLM/Views/ContentView/ContentView.swift:433-443`).
  - Insert errors are thrown inside a detached Task and are invisible.
- Pain points today:
  - Unreachable (dead surface).
  - The first source-as-album write site (ROADMAP §0.3 cites `MLM/Views/ContentView/ContentView.swift:400-407`; it is actually `MLM/Views/ContentView/ContentView.swift:424-431` inside `handleUniversalDownload` at `MLM/Views/ContentView/ContentView.swift:408-464`).
  - UI-004 (text search stuck in searching) is fixed in code: `MLM/ViewModels/UniversalSearchViewModel.swift:144-160` now performs a local search.
  - UI-005 changed from an empty action to an explicitly disabled button with a tooltip: still no import.
  - LOGIC-011 (stale submissions) is fixed with request stamps (`MLM/ViewModels/UniversalSearchViewModel.swift:44-49`, `MLM/ViewModels/UniversalSearchViewModel.swift:74`, `MLM/ViewModels/UniversalSearchViewModel.swift:99`, `MLM/ViewModels/UniversalSearchViewModel.swift:153`). `clear()` exists but nothing calls it (`MLM/ViewModels/UniversalSearchViewModel.swift:163-168`).
  - UI-018: custom glass styling, a 20 pt corner, brand colours, and a dimmed backdrop inside a sheet.
  - The footer hints are partly false: ↵ doesn't action, and ⌘K doesn't exist.
  - Clicking repeatedly creates duplicate tracks.
- Related flows: import-remote-playlist, find-fast, fix-failed-downloads.
- Constraints / locked decisions: one search entry point (§3.13). Native look (UI-018). Wish to stop source-as-album and keep provenance in `track_sources` (todo_dump lines 9–10 of 10, ROADMAP §4 C3).
- Open questions for the designer:
  - Does link resolution belong in the toolbar search (link mode), in Sources, or in a dedicated "Add from URL…" command?
  - What album and artist should a URL download get when the source has none?
  - What does the user see after pressing Download (row state, Activity, a jump to the track)?
  - Should a pasted playlist URL hand off to the W-REMOTE import flow?

## Context menus

### CM-SIDEBAR-PINNED — Pinned playlist row
- Where: P-PINNED child rows · Code: `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:117`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:130-147`, handlers `MLM/Views/Sidebar/SidebarView.swift:113-121`
- Items, in order:
  1. `Unpin from Sidebar`: toggles the pin off and posts `.playlistDidChange`, so the row disappears. Failure is silent (`MLM/Views/Sidebar/SidebarView.swift:113-118`).
  2. `Rename…`: turns the row into an inline text field (P-PINNED.E04).
  3. — separator —
  4. `Reveal in Grid`: switches to the Playlists grid (V-PL). It does not scroll to or highlight the playlist *(inferred)*.
  5. — separator —
  6. `Delete` (destructive role): opens A-SIDEBAR-DELETEPL. **Hidden for the Liked playlist** (`isLiked != 0`), which leaves a trailing separator in that case *(inferred)*.
- Rules: single row only, with no multi-selection in the sidebar.

### CM-SIDEBAR-PINNEDRENAME — Row in rename mode
- Where: P-PINNED.E04 · Code: `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:108-110`
- Items: `Cancel`, which leaves rename mode without saving.

### Uses of CM-TRACK in this area (menu owned by library.md)
- V-QUEUE tables: CM-TRACK without playlists or sync profiles (`MLM/Views/Queue/PlaybackQueueView.swift:72-83`, `MLM/Views/Queue/PlaybackQueueView.swift:95-106`, `MLM/Views/Queue/PlaybackQueueView.swift:118-129`).
- V-SEARCH results: CM-TRACK with playlists and sync profiles (`MLM/Views/Search/GlobalSearchPresentationView.swift:122-142`).
- CM-TRACK's `New Playlist from Selection` / `New Sync Profile from Selection` items post notifications that ContentView turns into the S-SEL-* sheets (`MLM/Views/Library/TrackContextMenu.swift:90`, `MLM/Views/Library/TrackContextMenu.swift:126`, `MLM/Views/ContentView/ContentView.swift:138-147`). CM-TRACK `Play Next` feeds V-QUEUE (`MLM/Views/Library/TrackContextMenu.swift:77`, `MLM/Views/Library/TrackContextMenu.swift:339`).

## Sheets, popovers, panels, alerts

### S-PLAYER-COVER — Large cover popover
- Trigger: click the 40 pt cover in P-PLAYER while a track is loaded · Code: `MLM/Views/Player/PlayerBar.swift:93-118`
- Content: the track's cover at 320 × 320 pt with a drop shadow, on a clear popover background, arrow pointing up at the thumbnail.
- Buttons: none. Clicking the large cover or clicking the thumbnail again closes it, and so does clicking outside (system popover behaviour).
- Error handling: the cover placeholder when no artwork exists (TrackCoverView, library.md).

### A-SIDEBAR-DELETEPL — "Delete playlist?"
- Trigger: CM-SIDEBAR-PINNED › `Delete` · Code: `MLM/Views/Sidebar/SidebarView.swift:76-104`
- Content: title `Delete playlist?` (visible). Message `Delete “‹name›”? Its music files will remain in your library.`
- Buttons: `Delete Playlist` (destructive) deletes the playlist and posts `.playlistDidChange`. `Cancel` (cancel role) closes.
- Escape: cancel.
- Error handling: a delete failure is only logged (`MLM/Views/Sidebar/SidebarView.swift:91-96`), so the user sees nothing and the row stays.
- Doc: UI-GROUNDTRUTH §3.17 asks for `Delete "Name"? This does not delete any files.`. The code copy differs (doc-vs-code, wording only).

### A-SIDEBAR-RENAMEFAIL — "Could not rename playlist"
- Trigger: the inline rename's database write throws · Code: `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:80-87`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:166-174`
- Content: title `Could not rename playlist`. Message = the raw `error.localizedDescription` (fallback `Please try again.`).
- Buttons: `OK` (cancel role).
- Consequence: the edit field has already closed, and the typed name is lost (UI-013 remnant).

### Universal search sheet (see S-SEARCH-UNIVERSAL)
Full entry under Surfaces (sheet; unreachable today).

### Sheets and alerts owned elsewhere but presented from ContentView
- S-SEL-* (New Playlist from Selection): `.sheet(item:)` keyed by the selected track ids, opened by `.triggerNewPlaylistFromSelection` (`MLM/Views/ContentView/ContentView.swift:138-142`, `MLM/Views/ContentView/ContentView.swift:193-195`). Owned by library.md.
- S-SEL-* (New Sync Profile from Selection): opened by `.triggerNewSyncProfileFromSelection` (`MLM/Views/ContentView/ContentView.swift:143-147`, `MLM/Views/ContentView/ContentView.swift:196-198`). Owned by library.md.
- S-ADOPT: shown as an always-presented sheet (`.constant(true)`) over an empty base background while the launch coordinator offers adoption (`MLM/Views/ContentView/ContentView.swift:97-108`). Owned by shell.md. Because the binding is constant, the sheet can only go away by changing the launch state, not by the user dismissing it *(inferred)*.
- S-WIZARD: a full-window overlay (not a sheet) when no library folder is set (`MLM/Views/ContentView/ContentView.swift:69-86`). Owned by shell.md.
- S-NEWLIB: `.sheet(item:)` driven by the launch coordinator's `newLibraryRequest` (`MLM/Views/ContentView/ContentView.swift:735-741`). Owned by shell.md.
- A-LIB-SWITCH: `Switch to "‹name›"?` / `MLM relaunches to open this library. Finish active downloads and syncs first.` / `Relaunch` · `Cancel` (`MLM/Views/ContentView/ContentView.swift:742-750`). Owned by shell.md.
- Library-problem alert (one `.alert` with four variants; A-LIB-COPY is its "copy" variant; shell.md assigns the IDs) (`MLM/Views/ContentView/ContentView.swift:751-809`):
  - Unavailable: title `"‹name›" can't be opened`. Messages `The library file is on a disk that isn't connected. Connect the disk, then try again.` (not connected) or `The library file isn't where MLM last found it. Open it from its new location, or create a new library.`. Buttons `Open Library…` · `New Library…` · `Cancel`. **No `Try again`**, although §3.17 lists one for "not connected".
  - Mismatch: title `"‹name›" can't be opened`. Message `The library file and its database don't belong together. This can happen when files inside a library file were replaced. MLM didn't change anything.`. Buttons `Show in Finder` · `OK`.
  - Invalid: title `"‹name›" isn't a valid library file.`. No message. Button `OK`.
  - Copy (A-LIB-COPY): title `"‹name›" is a copy of "‹original›"`. Message `To open it, MLM makes the copy a separate library. "‹original›" is not changed.`. Buttons `Open as separate library` · `Cancel`.
- These are attached to the root group, so they can appear over any root state (`MLM/Views/ContentView/ContentView.swift:123`).

## Menu items & keyboard shortcuts (area-local)

- **K-SEARCH-CMDF**: ⌘F (no ⌥/⌃/⇧) · `Focus search field` · scope: any key-down in **any MLM window** while the main content view is on screen (a local NSEvent monitor; the event is swallowed) · focuses V-SEARCH.E01 · `MLM/Views/ContentView/ContentView.swift:282-310` · Conflicts: it overrides ⌘F in other MLM windows (Settings, W-REMOTE) *(inferred)*. The menu twin `Library > Search Library` has no shortcut shown (`MLM/App/MLMApp.swift:166-170`).
- **K-SEARCH-RETURN**: Return in the search field · `Open search results` · always opens the V-SEARCH pane, even when empty · `MLM/Views/ContentView/ContentView.swift:677-682`.
- **K-SEARCH-ESC**: Escape in the search pane · closes the pane and clears the query · `MLM/Views/Search/GlobalSearchPresentationView.swift:30`, `MLM/Views/ContentView/ContentView.swift:329-333`.
- **K-SIDEBAR-QUEUE8**: ⌘8 · `Queue` · bound twice: the Navigate menu item (M-NAVIGATE, via `SidebarSection.topLevelCases`, `MLM/App/MLMApp.swift:107-116`, `MLM/Views/ContentView/ContentView.swift:586`, `MLM/Views/ContentView/ContentView.swift:627`) **and** the sidebar footer button (`MLM/Views/Sidebar/SidebarView.swift:218`) · Conflict: duplicate binding, and the contract says ⌘1–⌘7 only (UI-009).
- **K-SIDEBAR-NAV** (relation only; M-NAVIGATE is owned by shell.md): ⌘1 `Library`, ⌘2 `Playlists`, ⌘3 `Folders`, ⌘4 `Sync`, ⌘5 `Sources`, ⌘6 `Review`, ⌘7 `Discover`, ⌘8 `Queue`. They write the sidebar selection through a focused binding, so they only work while the main window is focused (`MLM/Views/ContentView/ContentView.swift:5-27`, `MLM/Views/ContentView/ContentView.swift:124`, `MLM/Views/ContentView/ContentView.swift:617-629`).
- **K-SIDEBAR-RENAME**: Return commits, Escape cancels, in P-PINNED.E04 · `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:102-103`.
- **K-SEARCH-UNIVERSAL-KEYS**: Return re-submits, Escape closes (S-SEARCH-UNIVERSAL). The advertised ⌘K and "tab to navigate" have no implementation · `MLM/Views/Search/UniversalSearchView.swift:32`, `MLM/Views/Search/UniversalSearchView.swift:68`, `MLM/Views/Search/UniversalSearchView.swift:364-375`.
- **Playback keys affecting P-PLAYER** (owned by shell.md, M-PLAYBACK): `Play`/`Pause` (no key), `Stop` ⌘., `Previous Track` (no key), `Next Track` (no key), `Skip Back 10s` ⌘←, `Skip Forward 10s` ⌘→. ←/→ ±5 s with hold-repeat (`MLM/App/MLMApp.swift:67-72`, `MLM/App/MLMApp.swift:119-163`).
- **Expected, missing**: Space = play/pause or play the selected row (daily-driver wish PLAY-01..03, `.planning/REQUIREMENTS.md:186-190`; no space binding exists in `MLM/`). ⌘I `More Info` and ⌘⇧I `Import from Folder…` exist as menu items, but nothing in ContentView or elsewhere observes `.showTrackDetail` / `.showImportDialog`, so both do nothing (`MLM/App/MLMApp.swift:174-188`).

## Drag & drop

- **D-SIDEBAR-SPRINGLOAD**: a track drag (`UTType.trackDrag`) hovering over a sidebar row (P-SIDEBAR rows, the P-PINNED label or any pinned row) shows a pulsing accent outline. After 600 ms of hover it navigates to that section or playlist. The drop itself is **rejected** (`return false`), so the user must then drop inside the detail view · Code: `MLM/Views/Shared/SpringLoadableHover.swift:10-57`, `MLM/Views/Sidebar/SidebarView.swift:188-190`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:70-72`, `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift:119-123` · Feedback: the outline only. The Queue and Settings footers have no spring-loading.
- **D-QUEUE-ROWS**: V-QUEUE rows can be dragged out as `TrackDragData` (track id, no source playlist) to any track drop target (playlist detail, etc.) · Code: `MLM/Views/Library/TrackTable.swift:218-221`, used by `MLM/Views/Queue/PlaybackQueueView.swift:72-129`.
- **D-SEARCH-ROWS**: V-SEARCH results can be dragged out the same way · Code: `MLM/Views/Library/TrackTable.swift:218-221`, `MLM/Views/Search/GlobalSearchPresentationView.swift:122-142`.
- **Expected, missing**:
  - Drop tracks **onto a pinned playlist row** to add them. This is the standard Music/Finder sidebar behaviour and part of the daily-driver "drag selection into playlist" loop (`.planning/REQUIREMENTS.md:229`). Today the rows explicitly reject the drop.
  - Drop tracks onto **Queue** (footer or V-QUEUE) to play next. Reorder within Next up by dragging.
  - Drop a URL or text onto the search field or the window to resolve and download it (the S-SEARCH-UNIVERSAL purpose).
  - Drop audio files or folders from Finder onto the window to import them (the menu `Import from Folder…` is dead).
  - Drag the now-playing track from the player (cover or title) into a playlist.

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Library drive not connected**:
  - The `Library` sidebar row shows a red dot with tooltip `Library drive disconnected` (`MLM/Views/Sidebar/SidebarView.swift:135-143`). The state is seeded from the mount check at start-up (`MLM/App/DependencyContainer.swift:384`) and updated on mount/unmount (`MLM/Views/ContentView/ContentView.swift:126-137`).
  - Playback pauses on unmount and does not resume on remount (`MLM/Views/ContentView/ContentView.swift:129-132`).
  - New play attempts say `Playback unavailable: ‹title› — file could not be found on disk.`, with no mention of the drive (`MLM/ViewModels/PlaybackViewModel.swift:180`).
  - Search keeps working, because it runs on the database.
  - Downloads and imports: no gate in this area. ImportViewModel reports `Library root does not exist: ‹path›` when the folder is gone (`MLM/ViewModels/ImportViewModel.swift:104-107`), surfaced by its callers (ST-LIB / V-LIB).
- **Library loading / failed / not open**:
  - `Loading Library...` (`MLM/Views/ContentView/ContentView.swift:497-507`).
  - `Failed to Initialize` plus the raw error, with no actions (`MLM/Views/ContentView/ContentView.swift:477-493`).
  - Launch placeholders and library-file alerts are routed (shell.md) (`MLM/Views/ContentView/ContentView.swift:97-118`, `MLM/Views/ContentView/ContentView.swift:730-809`).
- **Source disconnected or expired**:
  - The amber dot on `Sources` (`MLM/Views/Sidebar/SidebarView.swift:155-163`, `MLM/Views/Sidebar/SidebarView.swift:274-280`) refreshes only on appear and on import.
  - In V-SEARCH, SoundCloud and Spotify are queried only when credentials exist (`MLM/Views/Search/GlobalSearchPresentationView.swift:174-193`). Expired credentials lead to E08 `‹n› sources unreachable — results incomplete` with raw messages *(inferred)*.
- **Background processing**:
  - Sync: spinner on the `Sync` sidebar row (`MLM/Views/Sidebar/SidebarView.swift:145-153`).
  - Downloads and imports: no indicator in the sidebar, toolbar or player. They appear only in P-ACTIVITY.
  - Re-scan: a spinner replaces the toolbar button (`MLM/Views/Library/LibraryView.swift:117-131`).
- **Track availability**:
  - Remote tracks don't play on double-click, with no message (`MLM/Views/ContentView/ContentView.swift:399`).
  - Missing or unplayable files: P-PLAYER.E07 shows text and `Retry` (`MLM/Views/Player/PlayerBar.swift:136-187`).
  - The queue stalls on an unplayable track (`MLM/ViewModels/PlaybackViewModel.swift:409-419`).
  - V-QUEUE and V-SEARCH tables show **no** Status chips, because no availability data is passed (`MLM/Views/Library/TrackTable.swift:37`). Remote rows are identifiable only by Format (`SOUNDCLOUD`, `YOUTUBE`, …) (`MLM/Views/Library/TrackTable.swift:301-304`).

### Background work touchpoints

- **Downloads** (`DownloadViewModel`):
  - Progress (`isDownloading`, `currentTrack`, `progress`, `completedCount` / `failedCount` / `totalCount`, per-item `queueItems` with `queued` / `downloading` / `completed` / `skipped` / `cancelled` / `failed` plus a reason) is consumed by P-ACTIVITY / P-ACTIVITY-OPS (`MLM/ViewModels/DownloadViewModel.swift:75-90`, `MLM/ViewModels/DownloadViewModel.swift:535-559`, `MLM/Views/Activity/ActivityPanel.swift:121`, `MLM/Views/Activity/OperationsTab.swift:61`).
  - Item error texts: `downloaded but not saved to library`, `download cancelled`, or the orchestrator's reason (default "sources exhausted" user text) (`MLM/ViewModels/DownloadViewModel.swift:541-557`). Persisted failure reason `Downloaded file could not be saved to library` (`MLM/ViewModels/DownloadViewModel.swift:936-938`).
  - User control:
    - Cancel stops after the current track (`MLM/ViewModels/DownloadViewModel.swift:592-599`, called from `MLM/Views/Activity/OperationsTab.swift:294`).
    - Retry all failed (`MLM/ViewModels/DownloadViewModel.swift:630-648`, called from `MLM/Views/Activity/OperationsTab.swift:330`).
    - `retryDownload(trackId:)` and legacy `retryFailed()` have **no UI callers** (`MLM/ViewModels/DownloadViewModel.swift:320-405`, `MLM/ViewModels/DownloadViewModel.swift:604-625`).
  - A second batch while one is running is **rejected silently** (log only) (`MLM/ViewModels/DownloadViewModel.swift:195-198`). LOGIC-014's re-entrancy is fixed by this guard, but the rejection is invisible.
  - Completion posts `.downloadDidComplete` (`MLM/ViewModels/DownloadViewModel.swift:571-578`).
  - Entry points:
    - S-SEARCH-UNIVERSAL `Download` (`MLM/Views/ContentView/ContentView.swift:457`, unreachable).
    - CM-TRACK (`MLM/Views/Library/TrackContextMenu.swift:352`).
    - V-PLD (`MLM/Views/Playlists/PlaylistDetailView.swift:735-752`).
    - V-PL (`MLM/Views/Playlists/PlaylistsView.swift:648`).
    - W-REMOTE (`MLM/ViewModels/RemotePlaylistsViewModel.swift:127`).
    - Discover / Similar (`MLM/Views/TrackDetail/GrooveView.swift:981`, discovery queue `MLM/ViewModels/DownloadViewModel.swift:651-820`, statuses read at `MLM/Views/TrackDetail/GrooveView.swift:585`).
  - LOGIC-020 is fixed: the missing-dependency message is `Downloads are unavailable until a library is configured.` (`MLM/ViewModels/DownloadViewModel.swift:664-672`). LOGIC-022 is fixed by claiming before spawning (`MLM/ViewModels/DownloadViewModel.swift:686-690`).
  - Discovery downloads land in `Discovered Neighbors/‹seed artist› - ‹seed title›` with album fallback `Discovered Neighbors` (`MLM/ViewModels/DownloadViewModel.swift:722-777`).
- **Imports** (`ImportViewModel`):
  - Each run registers an Activity operation titled `Rescan library` (detail `Scanning ‹folder›…`) or `Import: ‹folder›`. Live progress comes from the current file or phase. The completion detail is `‹n› imported, ‹m› skipped`, `Cancelled`, or the failure text. A cancellation token is wired to the Activity panel (`MLM/ViewModels/ImportViewModel.swift:141-227`).
  - VM-level errors: `No library root configured`, `Library root does not exist: ‹path›`, `‹n› file(s) failed to import`, `Failed to load library root: …`, `Failed to save library root: …` (`MLM/ViewModels/ImportViewModel.swift:62-114`, `MLM/ViewModels/ImportViewModel.swift:185-187`).
  - Entry points: toolbar `Re-scan Library` ⌘R (`MLM/Views/Library/LibraryView.swift:117-131`, `MLM/Views/Library/LibraryView.swift:173-181`), ST-LIB (`MLM/Views/Settings/LibrarySetupView.swift:223-359`), S-WIZARD (`MLM/Views/Shared/FirstRunWizard.swift:360-361`). The menu `Import from Folder…` is dead (no observer).
- **Search fan-out**: remote searches run only in V-SEARCH All sources. Their progress is the inline spinner, and their failures are E08. Nothing is shown in Activity.
- **Waveform extraction**: runs silently in the background for every played track (`MLM/ViewModels/PlaybackViewModel.swift:543-651`).
- **Sync**: only the sidebar spinner here.

### Flow notes

- **daily-listening** (browse → space preview → play → queue):
  1. P-SIDEBAR: click `Library` or a pinned playlist (P-PINNED). The intent is to get to music in one click. This works, and pinned playlists open directly.
  2. V-LIB / V-PLD: select a row and want to hear it with **Space**. **This breaks: no space binding exists.** He must double-click (or press Return, the table's primary action).
  3. Double-click: the track plays, the inspector opens on the right (every time; this is a side effect he may not want), and the rows below it become Next up. If the row is remote, nothing plays and there is no message.
  4. P-PLAYER: pause, skip, scrub. When the queue reaches a remote or missing track, playback stops with `Playback unavailable: … file could not be found on disk.`, and Next keeps retrying the same track. **This is the biggest break in the loop.**
  5. V-QUEUE (⌘8): check what's next. He can jump ahead, but can't remove or reorder. Replaying from History silently drops the upcoming context. Volume resets on every launch.
- **find-fast** (search):
  1. ⌘F (K-SEARCH-CMDF) focuses the toolbar field.
  2. In Library or a playlist, typing filters that table in place. Anywhere else, typing opens the V-SEARCH pane. The behaviour differs by section, without explanation.
  3. Return always opens the pane. The scope defaults to `Library`.
  4. Switching to `All sources` shows nothing until SoundCloud, Spotify, YouTube and DAB have all answered. Library hits are not shown first. **Every remote hit is saved into the library** with album = source name.
  5. Double-click a local result to play it, or a remote result to inspect it (no play, no download action on the row).
  6. Escape or a section change closes the pane and clears the query, so the search is lost on navigation.
- **import-remote-playlist** (YouTube/SoundCloud import + download):
  1. The intent is to paste a playlist or track URL. The toolbar search has **no link mode**, and S-SEARCH-UNIVERSAL, which detects URLs, **cannot be opened**.
  2. Had it been reachable: a playlist URL shows `Playlist detected` with a disabled `Import` whose tooltip says `Use Sources to import a playlist.`, so the user is sent to V-SRC / W-REMOTE (sources-review.md area). A track URL shows a `Download` card. The download writes album `YouTube` / `SoundCloud` / `Downloads` / `Web` (`MLM/Views/ContentView/ContentView.swift:424-431`). The panel gives no feedback, and progress shows only in P-ACTIVITY. A second click duplicates the track. If another download is running, the track is created but never downloaded, silently.
  3. Today's real path is entirely in sources-review.md (W-REMOTE). Its downloads run through `DownloadViewModel.downloadTracks` and surface in P-ACTIVITY.
- **drive-unplugged**:
  1. The drive is ejected. MLM pauses playback and shows the red dot on `Library` (tooltip only).
  2. The player still shows the paused track. What Play then does is unknown ("Unresolved from code"). Double-clicking any track gives `Playback unavailable: … file could not be found on disk.`, with no mention of the drive.
  3. Search, queue and sidebar navigation keep working from the database.
  4. When the drive is plugged back in, the dot disappears. Playback does not resume, and nothing tells him he can continue.
  - What breaks: the state is never stated in words outside a tooltip, and the error copy blames the file, not the drive.
- **fix-failed-downloads** (touch only): the only player-side recovery is `Retry`, which retries playback, not a download. Download retry lives in P-ACTIVITY-OPS (`Retry all` → `retryAllFailed`).
- **build-playlist** (touch only): dragging tracks over the sidebar spring-loads into a playlist after 600 ms, but the drop must happen in the detail view. Dropping onto the sidebar row itself is rejected.
- **first-launch** / **switch-library** (touch only): ContentView routes to S-WIZARD (overlay), S-ADOPT (unclosable sheet), V-LAUNCH-*, S-NEWLIB, A-LIB-SWITCH and the library-problem alert. See shell.md.

### Unresolved from code

- **What Play does on a paused track after the drive is ejected.** This depends on `AudioPlayer`'s buffered file handle on an unmounted volume. Not determinable without running the app, which is forbidden.
- **Toolbar ordering of `.primaryAction` items.** The search field (ContentView) and Shuffle / Re-scan (V-LIB) share the same placement, and whether the hidden V-LIB's items show in other sections is SwiftUI runtime behaviour. Strongly suspected from code, but needs a visual check.
- **Whether the system sidebar-toggle button appears.** No explicit toolbar item exists; `NavigationSplitView` normally adds one.
- **What a deleted-while-open pinned playlist shows.** The loader only refetches on id change. The likely outcome is a stale detail view.
- **Whether `RemoteTrackMaterializer` reuses existing rows for repeated hits** (`materializeRemoteTrack` returns a "canonical" track). This affects how fast All-sources searches grow the library. The repository code (sources-review.md or library.md) was not read in depth.
- **Exact appearance of the 64 pt `Currently playing` table** (header plus one row), and whether rows are clipped.
- **Whether CM-TRACK in V-QUEUE shows empty playlist submenus or hides them.** That depends on `TrackContextMenu` (library.md).
- **LOGIC-003 status.** `initializationError` is now assigned (`MLM/App/DependencyContainer.swift:102`), but whether every bootstrap failure path reaches it was not traced (shell.md).

