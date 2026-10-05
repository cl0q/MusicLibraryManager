# Sources, Remote Playlists & Review

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): SRC, REMOTE, REV · Files covered: `MLM/Views/Sources/SourcesView.swift`, `MLM/Views/Sources/RemotePlaylistsView.swift`, `MLM/Views/ReviewQueue/ReviewQueueView.swift`, `MLM/ViewModels/SourcesViewModel.swift`, `MLM/ViewModels/RemotePlaylistsViewModel.swift`, `MLM/ViewModels/ReviewQueueViewModel.swift`, `MLM/Services/Sources/{RemotePlaylistProvider,SoundCloudClient,SpotifyClient,AppleMusicClient}.swift` (user-visible parts), `MLM/App/AppDelegate.swift:86-144` (W-REMOTE creation); supporting reads: `AnalysisRepository.swift`, `DuplicateDetectionService.swift`, `TokenStorage.swift`, `TokenRefresh.swift`, `TokenAccessStatus.swift`, `CredentialsLoader.swift`, `OAuthManager.swift`, `SidebarView.swift`, `SourcesSetupView.swift` (reference only)

## Surfaces

### V-SRC — Sources
- Reached via: sidebar row `Sources` in the library.md group (P-SIDEBAR, `MLM/Views/Sidebar/SidebarView.swift:33-35`) · menu Navigate → `Sources` ⌘5 (M-NAVIGATE, `MLM/App/MLMApp.swift:106-116`) · Leads to: W-REMOTE (via `Playlists` / `Import playlist...`), system browser OAuth (S-SRC-OAUTH), macOS keychain prompt (A-SRC-KEYCHAIN). The card text points the user to Settings (`reconnect in Settings`) but there is no button to it from V-SRC; the Sources tab of Settings is ST-SRC (owned by settings.md).
- Code: `MLM/Views/Sources/SourcesView.swift:22-132` (view), `MLM/Views/Sources/SourcesView.swift:137-345` (`SourceCard`), `MLM/Views/Sources/SourcesView.swift:350-398` (`YouTubePlaylistCard`), `MLM/ViewModels/SourcesViewModel.swift:8-355` (view model), clients `MLM/Services/Sources/SoundCloudClient.swift:182-217`, `MLM/Services/Sources/SpotifyClient.swift:65-111`, `MLM/Services/Sources/AppleMusicClient.swift:44-76`.
- Purpose: see which streaming accounts MLM is signed in to, sign in or out, pull liked tracks (and, for SoundCloud, account playlists) into the library as "Not downloaded" tracks, and open the playlist importer for SoundCloud, Spotify or YouTube.
- User goals (jobs to be done):
  1. Pull newly liked SoundCloud tracks into MLM so they can be downloaded — weekly *(inferred: Sync merges likes; SoundCloud is "highest priority — 585 tracks", `MLM/Views/Sources/SourcesView.swift:74`)*.
  2. Import a YouTube or SoundCloud playlist by URL, or one of the user's own SoundCloud/Spotify playlists — weekly (flow: import-remote-playlist; seed `.planning/seeds/soundcloud-playlist-import.md`).
  3. Notice and fix a source whose sign-in stopped working (expired session, keychain locked after a rebuild) — rare but blocking (flow: source-expired).
  4. Connect a source for the first time (OAuth in the browser) — rare (flow: settings-changes / first-launch).
  5. Disconnect an account — rare.
- What the user wants to see, in priority order:
  1. For each source: is it working right now — Connected / Not connected / sign-in expired / needs keychain permission.
  2. What it would take to fix a broken one (one action, in place).
  3. Whether liked tracks are up to date: when it last synced and what the last sync brought in (new tracks count, failures).
  4. How many tracks in the library came from this source.
  5. A way into that source's playlists.
- Elements today:
  - V-SRC.E01 Page title `Sources` (`MLM/Views/Sources/SourcesView.swift:103-113`). No toolbar items, no subtitle.
  - V-SRC.E02 Load-error banner: warning icon + text `Could not load source details. <system error>` + button `Retry` (re-runs load). Shown only when the database read of source rows/counts fails (`MLM/Views/Sources/SourcesView.swift:51-66`, `MLM/ViewModels/SourcesViewModel.swift:192-198`).
  - V-SRC.E03 Card grid, adaptive 280–340 pt columns, fixed order: SoundCloud, Spotify, Apple Music, YouTube (`MLM/Views/Sources/SourcesView.swift:68-96`).
  - V-SRC.E04 Account card (SoundCloud / Spotify / Apple Music), each with (`MLM/Views/Sources/SourcesView.swift:137-294`):
    - E04a SF-symbol icon tinted with the brand colour (`cloud.fill` SoundCloud, `music.note.list` Spotify, `music.note` Apple Music) (`MLM/Views/Sources/SourcesView.swift:323-344`).
    - E04b Name: `SoundCloud` / `Spotify` / `Apple Music` (`MLM/Services/Auth/TokenStorage.swift:64-70`).
    - E04c Status line, text: `Syncing…` while syncing, else `Connected` or `Not connected` (`MLM/Views/Sources/SourcesView.swift:312-315`). There is no "expired", "connecting" or "needs permission" status text.
    - E04d Status dot at the right: green when connected, muted grey otherwise; accessibility label `<Name>: <status>` (`MLM/Views/Sources/SourcesView.swift:159-161`, `317-321`).
    - E04e (connected only) `Tracks` + count of tracks linked to that source; `Last Sync` + relative time (abbreviated, e.g. "2 hr. ago") or `Never` — only the *liked songs* sync timestamp is read (`MLM/Views/Sources/SourcesView.swift:168-190`, `MLM/ViewModels/SourcesViewModel.swift:117-130`, `184-189`).
    - E04f (connected) button `Sync` with circular-arrows icon; shows a small spinner instead of the icon and is disabled while syncing (`MLM/Views/Sources/SourcesView.swift:195-209`). What it does per source (`MLM/ViewModels/SourcesViewModel.swift:295-342`): SoundCloud = sync likes + the first 50 account playlists (each becomes a linked local playlist whose track list is replaced) (`MLM/Services/Sources/SoundCloudClient.swift:753-775`); Spotify = sync liked songs only — the playlist step does nothing (`MLM/Services/Sources/SpotifyClient.swift:309-326`); Apple Music = stubs that return 0 (`MLM/Services/Sources/AppleMusicClient.swift:65-76`). If new tracks arrived it posts `libraryDidImport` so the Library refreshes (`MLM/ViewModels/SourcesViewModel.swift:324-331`). No result message is shown ("12 new tracks" or "up to date"); only `Last Sync` changes.
    - E04g (connected + keychain token unreadable) button `Reconnect` with `arrow.uturn.backward` icon; disabled while reconnecting (`MLM/Views/Sources/SourcesView.swift:211-221`). It first tries one interactive keychain read (may trigger A-SRC-KEYCHAIN) and falls back to a full OAuth sign-in (S-SRC-OAUTH) (`MLM/ViewModels/SourcesViewModel.swift:249-271`).
    - E04h (connected) button `Disconnect`, destructive role, **no confirmation**: deletes the keychain tokens straight away and clears count/last sync. Tracks and playlists stay (`MLM/Views/Sources/SourcesView.swift:223-227`, `MLM/ViewModels/SourcesViewModel.swift:277-289`).
    - E04i (not connected) button `Connect` with `link` icon, prominent, brand-tinted; disabled when the credentials file has no client ID/secret for that source (`MLM/Views/Sources/SourcesView.swift:229-241`, `MLM/Utilities/CredentialsLoader.swift:52-63`). Starts S-SRC-OAUTH. Apple Music always counts as "has credentials", so `Connect` is enabled but always fails with `Apple Music integration not yet implemented (Phase 10)` (`MLM/Services/Sources/AppleMusicClient.swift:44-48`, `87`).
    - E04j (not connected + credentials missing) hint `Add credentials to ~/Library/Application Support/MLM/.env` (`MLM/Views/Sources/SourcesView.swift:243-248`, `MLM/ViewModels/SourcesViewModel.swift:101-104`).
    - E04k Error line in red, max 2 lines: the last connect/sync/disconnect error for that source, e.g. `SoundCloud session expired — click Connect to re-authenticate`, `Spotify API error (401): <raw body>`, `SoundCloud credentials missing — add SOUNDCLOUD_CLIENT_ID and SOUNDCLOUD_CLIENT_SECRET to ~/Library/Application Support/MLM/.env`, `Authorization was cancelled`, `Token exchange failed (HTTP <code>): <body>` (`MLM/Views/Sources/SourcesView.swift:253-258`; strings `MLM/Services/Sources/SoundCloudClient.swift:1027-1041`, `MLM/Services/Sources/SpotifyClient.swift:460-479`, `MLM/Services/Auth/OAuthManager.swift:275-282`). Raw API bodies are truncated, not explained.
    - E04l Amber notice: warning icon + `<Name> token inaccessible — reconnect in Settings` (`MLM/Views/Sources/SourcesView.swift:262-271`) — shown together with the `Reconnect` button on the same card.
    - E04m (connected, SoundCloud and Spotify only) button `Playlists` with `music.note.list` icon → W-REMOTE for that source (`MLM/Views/Sources/SourcesView.swift:274-284`, `300-306`). Apple Music has no playlist browser.
  - V-SRC.E05 YouTube card (no sign-in) (`MLM/Views/Sources/SourcesView.swift:350-398`): red `play.rectangle.fill` icon, name `YouTube`, subtitle `Import a playlist`, body `Paste a playlist URL to download tracks.`, button `Import playlist...` (three periods, not an ellipsis character) → W-REMOTE (YouTube). No status (e.g. whether yt-dlp is installed), no count, no last import.
- Interactions: click only. No double-click, no context menus, no keyboard shortcuts inside the view, no drag & drop, no hover tooltips (other than default). Cards are not selectable.
- States:
  - Default: four cards.
  - Loading: `Loading sources…` spinner until the view model exists (`MLM/Views/Sources/SourcesView.swift:28-34`). If the library container has no token storage/source repository (library not loaded), it stays on this spinner forever — no message (`MLM/Views/Sources/SourcesView.swift:117-120`).
  - Error (DB read): V-SRC.E02 banner with `Retry`; cards still render with whatever connection state was read from the keychain (`MLM/ViewModels/SourcesViewModel.swift:154-199`). (Addresses audit UI-016.)
  - Per-source error: E04k.
  - Connecting (OAuth in browser): **not shown** — card remains `Not connected` with `Connect` enabled; there is no timeout in the loopback wait (`MLM/Services/Auth/OAuthManager.swift:189-262`), so an abandoned browser login leaves a pending task with no UI.
  - Syncing: `Syncing…` + spinner on `Sync`, indeterminate, no counts. State lives in a view-owned model that is rebuilt when the user switches sidebar sections (`MLM/Views/ContentView/ContentView.swift:375-376`), so after leaving and returning mid-sync the card shows idle and `Sync` is enabled again *(inferred from code structure)*.
  - Expired sign-in: **no dedicated state**. SoundCloud: when a request gets 401 and the refresh fails, Sync shows E04k `SoundCloud session expired — click Connect to re-authenticate` and flips the card to `Not connected` (`MLM/ViewModels/SourcesViewModel.swift:332-336`) — but the client deliberately leaves the tokens in the keychain (`MLM/Services/Sources/SoundCloudClient.swift:306-315`, `395-427`), so the next load shows `Connected` again *(inferred)*. Spotify: no token refresh is registered (only SoundCloud is, `MLM/App/DependencyContainer.swift:123-135`) and 401 is not handled (`MLM/Services/Sources/SpotifyClient.swift:121-155`), so after the access token lifetime Sync fails with raw `Spotify API error (401): …` while the card still says `Connected`.
  - Keychain inaccessible (e.g. after rebuild changed code identity): E04g + E04l (`MLM/Services/Auth/TokenAccessStatus.swift:1-25`, `MLM/Services/Auth/TokenRefresh.swift:206-231`).
  - Offline: surfaces only as a per-card error string from URLSession when the user presses Sync/Connect.
  - Drive not connected: not handled/not relevant here (sync writes remote tracks to DB only).
- Data scale / performance notes: 4 cards. SoundCloud Sync walks all likes and the first 50 playlists (no pagination in `syncPlaylists`, `MLM/Services/Sources/SoundCloudClient.swift:753-775`); 19,596 `track_sources` rows exist (ROADMAP §0). Track counts are fetched per source row on every load (`MLM/ViewModels/SourcesViewModel.swift:176-191`).
- Pain points today:
  - No "Sign-in expired" state in Sources although the sidebar shows an amber dot `A source sign-in has expired` (`MLM/Views/Sidebar/SidebarView.swift:155-163`, `274-280`) and Settings shows `Sign-in expired` (`MLM/Views/Settings/SourcesSetupView.swift:168-178`) — three places, three different answers.
  - Apple Music `Connect` is enabled but can never succeed (`MLM/Services/Sources/AppleMusicClient.swift:44-48`).
  - `Disconnect` has no confirmation here, while the same action in Settings has one (`MLM/Views/Settings/SourcesSetupView.swift:86-98`) — audit UI-014 / §3.17 "every destructive action confirms".
  - Notice says `reconnect in Settings` while a `Reconnect` button is right there (`MLM/Views/Sources/SourcesView.swift:211-221` vs `265`).
  - Sync gives no result (how many new, how many playlists updated, any failures); Spotify "Sync" silently skips playlists.
  - Raw technical errors in E04k (HTTP bodies, `Invalid API URL: …`), violating copy rule §1.7(4).
  - Credentials hint shows a hidden file path (`.env`) instead of the glossary term "Credentials file" with a Show-in-Finder action (UI-GROUNDTRUTH §1.5).
  - Status word `Not connected` vs glossary `Disconnected` (§1.6) and Settings `Disconnected`.
  - Synced tracks get album `SoundCloud`/`YouTube` written in at import (`MLM/Services/Sources/RemotePlaylistProvider.swift:204`, `408`) — the exact thing `todo_dump.md:8` wants gone.
- Related flows: settings-changes (sources sign-in), source-expired, import-remote-playlist, first-launch.
- Constraints / locked decisions: native look only; critical states as text not icon-only (the status dot is paired with text, but "expired" has no text here); English only; one meaning per word (`Sync` here means "pull from account", while `Sync` in the sidebar means device sync — V-SYNC).
- Open questions for the designer:
  - Should "pull likes from SoundCloud" be called something other than `Sync`, given `Sync` is the device-sync section?
  - Where should the per-source result of the last pull live (new tracks, updated playlists, failures), and how long should it stay?
  - How should an unfinished feature (Apple Music) present itself — hidden, disabled with reason, or listed as "coming later"?
  - What should a source card say about prerequisites that are not sign-ins (yt-dlp for YouTube, scdl config for SoundCloud, Qobuz cookie in Settings)?
  - Should the connect/reconnect action ever leave this view (Settings) or always be in place?
  - Is Sources a daily destination or a setup page? Does it deserve a top-level sidebar slot?

### W-REMOTE — Remote playlists window (SoundCloud Playlists / Spotify Playlists / Import YouTube Playlist)
- Reached via: V-SRC.E04m `Playlists` (SoundCloud, Spotify; only when connected) · V-SRC.E05 `Import playlist...` (YouTube). Not reachable from any menu, shortcut, Library, Playlists or the universal search (S-SEARCH-UNIVERSAL detects playlist URLs but its `Import` button is disabled with tooltip `Playlist imports are not available from this search panel. Use Sources to import a playlist.`, `MLM/Views/Search/UniversalSearchView.swift:198-224`). · Leads to: V-PLD embedded inside this window (`Open playlist`), W-SETTINGS (`Open Settings`), P-ACTIVITY-OPS (download batch, via shared download model — owned by activity.md).
- Code: window creation `MLM/App/AppDelegate.swift:86-144`; view `MLM/Views/Sources/RemotePlaylistsView.swift:1-209` (browse), `MLM/Views/Sources/RemotePlaylistsView.swift:213-432` (review / progress / result), `MLM/Views/Sources/RemotePlaylistsView.swift:436-489` (provider setup); view model `MLM/ViewModels/RemotePlaylistsViewModel.swift:7-206`; providers `MLM/Services/Sources/RemotePlaylistProvider.swift:1-476`.
- Window behaviour: AppKit `NSWindow`, 760×620, titled/closable/miniaturizable/resizable, centered, title = `SoundCloud Playlists` / `Spotify Playlists` / `Import YouTube Playlist` (`MLM/App/AppDelegate.swift:112-120`, `MLM/Views/Sources/RemotePlaylistsView.swift:10-18`). Only one remote window exists at a time: asking for the same source re-focuses the existing window (keeping whatever step it was on); asking for a different source **closes** the current one and builds a new one (`MLM/App/AppDelegate.swift:98-109`). The window is retained after closing (`isReleasedWhenClosed = false`), so reopening the same source shows the previous state *(see "Unresolved from code")*.
- Purpose: preview a remote playlist (from the user's account list or a pasted URL), pick all / first N / random N tracks, then either download them or save them as a linked local playlist without downloading, and see what happened.
- User goals:
  1. Paste a YouTube playlist URL and get its tracks into MLM as a playlist with audio — weekly (flow: import-remote-playlist).
  2. Bring one of my own SoundCloud playlists into MLM — weekly *(seed `.planning/seeds/soundcloud-playlist-import.md`)*.
  3. Grab only part of a big playlist (first N / random N) to try it — rare *(inferred from selection modes)*.
  4. Re-import a playlist that has grown and only download the new tracks — weekly (`MLM/ViewModels/RemotePlaylistsViewModel.swift:105-108` describes exactly this).
  5. Find out which tracks failed and why, then go to the resulting playlist — after every import.
- What the user wants to see, in priority order:
  1. The playlist's name, size and source before committing.
  2. Which of these tracks are already in the library / already downloaded, and what will actually be downloaded.
  3. The track list with enough identity to recognise songs (title, artist/uploader, duration).
  4. Progress during download (n of m) and the result (downloaded / failed, with reasons per failed track).
  5. A way to the created playlist inside the main window.
- Elements today:
  - Toolbar
    - W-REMOTE.E01 Toolbar button `Done` (placement `.cancellationAction`) — closes the window (`MLM/Views/Sources/RemotePlaylistsView.swift:43-53`). Window title as above (`MLM/Views/Sources/RemotePlaylistsView.swift:54`).
  - Screen 1 — Browse (`MLM/Views/Sources/RemotePlaylistsView.swift:87-102`). Layout differs by source (`MLM/Services/Sources/RemotePlaylistProvider.swift:4-8`, `93`, `362`): SoundCloud = URL bar above account list; Spotify = account list only; YouTube = URL bar only.
    - W-REMOTE.E02 URL text field, placeholder `https://www.youtube.com/playlist?list=…` / `https://soundcloud.com/…/sets/…` / `https://open.spotify.com/playlist/…` (the Spotify placeholder is never visible because Spotify has no URL field) (`MLM/Views/Sources/RemotePlaylistsView.swift:111`, `142-148`). Return does nothing (no submit action).
    - W-REMOTE.E03 Button `Load` — fetches a preview from the URL; disabled while loading or when the field is empty; small spinner next to it while loading (`MLM/Views/Sources/RemotePlaylistsView.swift:113-123`, `MLM/ViewModels/RemotePlaylistsViewModel.swift:76-82`).
    - W-REMOTE.E04 Inline error under the URL field (red), e.g. `yt-dlp not installed — open Settings`, `That link is not a SoundCloud playlist`, `Video unavailable`, `Network error`, `Private video` (`MLM/Views/Sources/RemotePlaylistsView.swift:125-137`; strings `MLM/Services/Sources/RemotePlaylistProvider.swift:75-84`, `MLM/Services/Download/DownloadOrchestrator.swift:69-82`).
    - W-REMOTE.E05 Button `Open Settings` next to the error — only when the error text is exactly `yt-dlp not installed — open Settings` (`MLM/Views/Sources/RemotePlaylistsView.swift:130-135`, `MLM/ViewModels/RemotePlaylistsViewModel.swift:52-54`) → W-SETTINGS (no specific tab).
    - W-REMOTE.E06 Account playlist list (SoundCloud, Spotify): rows with title, `<n> tracks`, optional `Private` label with lock icon (SoundCloud only), chevron; whole row is a button that loads the preview (`MLM/Views/Sources/RemotePlaylistsView.swift:170-197`). No search, sort, filter, artwork or "already imported" marker.
    - W-REMOTE.E07 List loading: `Loading playlist…` (also shown while a URL preview loads — the list disappears) (`MLM/Views/Sources/RemotePlaylistsView.swift:152-154`).
    - W-REMOTE.E08 List error: large warning icon, error text, `Open Settings` (yt-dlp case only), `Retry` (reloads the account list) (`MLM/Views/Sources/RemotePlaylistsView.swift:155-164`, `202-208`).
    - W-REMOTE.E09 List empty: `No playlists found` (`MLM/Views/Sources/RemotePlaylistsView.swift:165-168`).
    - W-REMOTE.E10 Fallback `No import method available` (should not occur) (`MLM/Views/Sources/RemotePlaylistsView.swift:95-100`).
  - Screen 2 — Review (`MLM/Views/Sources/RemotePlaylistsView.swift:273-332`)
    - W-REMOTE.E11 `Back` (chevron) — discards the preview and returns to Browse (`MLM/Views/Sources/RemotePlaylistsView.swift:275-283`, `MLM/ViewModels/RemotePlaylistsViewModel.swift:84-88`).
    - W-REMOTE.E12 Heading `"<Title>" · <n> tracks · from <SoundCloud|Spotify|YouTube>` (`MLM/Views/Sources/RemotePlaylistsView.swift:285-286`).
    - W-REMOTE.E13 Caption `Metadata completes after download` (`MLM/Views/Sources/RemotePlaylistsView.swift:288-290`).
    - W-REMOTE.E14 Source note (Spotify only): `Spotify does not provide audio files — tracks are found through SoundCloud or YouTube.` (`MLM/Views/Sources/RemotePlaylistsView.swift:292-296`, `MLM/Services/Sources/RemotePlaylistProvider.swift:248-250`).
    - W-REMOTE.E15 Selection mode segmented control `All` · `First N` · `Random N` (label `Select:` hidden) (`MLM/Views/Sources/RemotePlaylistsView.swift:224-229`, `388-396`). Random is shuffled once per change of mode/count, so the shown list is exactly what is committed (`MLM/Views/Sources/RemotePlaylistsView.swift:231-244`).
    - W-REMOTE.E16 (First N / Random N) number field `N` (digits only, clamped 1…track count) + stepper (`MLM/Views/Sources/RemotePlaylistsView.swift:398-431`). Default 50.
    - W-REMOTE.E17 Track list: `<index>  <title>` only — no artist/uploader, duration, availability or "already in library" (`MLM/Views/Sources/RemotePlaylistsView.swift:300-303`). The data (artist, duration) exists in the preview (`MLM/Services/Sources/RemotePlaylistProvider.swift:199-208`).
    - W-REMOTE.E18 Error line (red caption) for save/download failures (`MLM/Views/Sources/RemotePlaylistsView.swift:305-309`).
    - W-REMOTE.E19 Primary button `Download All (<n> tracks)` in All mode, `Download <n> tracks` otherwise; disabled when 0 (`MLM/Views/Sources/RemotePlaylistsView.swift:311-324`). Saves the playlist + selected tracks to the DB, then sends only not-yet-downloaded tracks to the download pipeline (`MLM/ViewModels/RemotePlaylistsViewModel.swift:109-139`).
    - W-REMOTE.E20 Button `Save without downloading` — saves the linked playlist and its selected tracks as "Not downloaded" (`MLM/Views/Sources/RemotePlaylistsView.swift:326-329`, `MLM/ViewModels/RemotePlaylistsViewModel.swift:91-100`).
  - Saving (`MLM/Views/Sources/RemotePlaylistsView.swift:248-250`): full-area spinner, no text.
  - Screen 3 — Downloading (`MLM/Views/Sources/RemotePlaylistsView.swift:334-343`)
    - W-REMOTE.E21 `Downloading… <done> of <total>` + determinate bar + `Cancel` (cancels the global download batch) (`MLM/ViewModels/RemotePlaylistsViewModel.swift:45-48`, `146-148`). No per-track list or current-track name.
  - Screen 4 — Result (`MLM/Views/Sources/RemotePlaylistsView.swift:346-386`)
    - W-REMOTE.E22 Headline `<n> downloaded · <m> failed`, or `Nothing downloaded yet` after Save — and also after Download when every track was already downloaded (`MLM/ViewModels/RemotePlaylistsViewModel.swift:115-125`).
    - W-REMOTE.E23 `Show failed` (toggle, only if failed > 0) → list of failed track titles with a plain reason (`Video unavailable`, `Video unavailable in your region`, `Private video`, `yt-dlp not installed — open Settings`, `Network error`) (`MLM/Views/Sources/RemotePlaylistsView.swift:351-357`, `375-386`, `MLM/ViewModels/RemotePlaylistsViewModel.swift:150-159`). No retry.
    - W-REMOTE.E24 `Open playlist` → shows the created playlist (V-PLD via `PlaylistDetailViewLoader`) inside this window, with a back action to the result; double-click on tracks there does nothing (`MLM/Views/Sources/RemotePlaylistsView.swift:64-69`, `365-367`).
    - W-REMOTE.E25 `Done` → closes the window (`MLM/Views/Sources/RemotePlaylistsView.swift:368-370`).
- What a commit does to data: creates or reuses a linked playlist keyed by source + external ID (SoundCloud: never adopts a same-named playlist, adds " 2" etc.; Spotify/YouTube: if a synced playlist with the same name exists from another source, it is **adopted and its track list replaced**) (`MLM/Services/Sources/RemotePlaylistProvider.swift:165-176`, `335-345`, `457-468`; `MLM/Database/PlaylistRepository.swift:481-530`, `565-594`). The playlist's track list is replaced by exactly the selected tracks (so "First 10" on an existing linked playlist truncates it to 10). Tracks already known by external ID are reused; new ones are inserted as remote tracks with album set to `SoundCloud` / `YouTube` / Spotify album name (`MLM/Services/Sources/RemotePlaylistProvider.swift:213-238`, `204`, `295`, `408`). Posts `playlistDidChange` so Playlists/sidebar refresh (`MLM/Services/Sources/RemotePlaylistProvider.swift:177-181`, `347-351`, `469-473`).
- Interactions: click; typing in E02/E16; segmented control; stepper. No context menus, no multi-select in the track list (selection is by mode only), no drag & drop, no keyboard shortcut except the toolbar `Done` placement (K-REMOTE-DONE).
- States: Initialising (spinner; forever if the library container is not ready, `MLM/Views/Sources/RemotePlaylistsView.swift:437-444`) · Browse idle · Loading list · Loading preview · List error · List empty · Review · Saving · Downloading · Result (complete / partial / nothing downloaded) · Embedded playlist. Offline/expired sign-in: any non-provider error (SoundCloud session expired, `Not authenticated — connect SoundCloud first`, Spotify 401) is mapped to the generic `Video unavailable` (`MLM/ViewModels/RemotePlaylistsViewModel.swift:197-205`, `MLM/Services/Download/DownloadOrchestrator.swift:125-129`) with `Retry` — the user is never told to sign in again. Drive not connected during download: not checked here; failures surface only as generic reasons. Another download already running: the request is rejected silently (`MLM/ViewModels/DownloadViewModel.swift:195-198`); the window then shows the *other* batch's progress and afterwards its stale result (`MLM/ViewModels/RemotePlaylistsViewModel.swift:127-138`) *(inferred)*.
- Data scale / performance notes: SoundCloud account list paginates up to 40 pages of 50 (`MLM/Services/Sources/SoundCloudClient.swift:836-848`); Spotify pages of 50 until done; previews pull every track (Spotify 100/page). A large playlist (hundreds of tracks) is shown as a plain list of titles; persistence inserts tracks one by one.
- Pain points today:
  - Expired SoundCloud/Spotify sign-in shows `Video unavailable` (wrong word for a sign-in problem, and wrong for audio-only sources).
  - Opening another source's window silently closes the current one, even mid-download (`MLM/App/AppDelegate.swift:107-109`).
  - Track list shows titles only; no "already in library" count (UI-GROUNDTRUTH §3.6 edge case `12 already in library` not implemented); "all already downloaded" reports `Nothing downloaded yet`.
  - A URL error on the SoundCloud combined screen replaces the whole account list with the error and a `Retry` that reloads the list, not the URL (`MLM/Views/Sources/RemotePlaylistsView.swift:151-164`).
  - Replacing the track list of an existing linked playlist with a partial selection; Spotify/YouTube adopting a same-named playlist from another source (data loss risk).
  - Return key does not trigger `Load`.
  - Failed tracks have no retry here; result is lost when the window closes or another source opens (§3.6 rule 4 "result state persists").
  - Mixed case `Download All (n tracks)` vs sentence-case rule (§1.7.2); `Import playlist...` uses three periods.
  - Album field gets the source name (`todo_dump.md:8`).
  - Shared global download state (audit LOGIC-014: now rejects the second batch, but silently).
- Related flows: import-remote-playlist, fix-failed-downloads, source-expired, build-playlist.
- Constraints / locked decisions: remote-playlists window is an AppKit `NSWindow` from `AppDelegate` (brief "Product facts"); native look; English only.
- Open questions for the designer:
  - Should importing live in its own window at all, or in the main window (sheet, Playlists, Sources)?
  - How should "already in library / already downloaded / will be downloaded" be communicated before the commit?
  - What should happen to an existing linked playlist when the user re-imports only part of it?
  - Where does the outcome of an import live after the window closes (playlist header, Activity, both)?
  - Should a pasted playlist URL anywhere in the app (search field, drag & drop) lead straight here?
  - How should a sign-in problem discovered mid-import be presented, and what's the one action?

### V-REV — Review (duplicates & metadata conflicts)
- Reached via: sidebar row `Review` in the WORK group, with badge `<d> dup · <c> conf` when anything is pending (P-SIDEBAR, `MLM/Views/Sidebar/SidebarView.swift:43-45`, `165-177`) · menu Navigate → `Review` ⌘6 (M-NAVIGATE) · P-INSPECTOR `Show in Review` on a track marked as possible duplicate (posts `showReview` with the track ID → Review opens with that group expanded) (`MLM/Views/TrackDetail/MetadataPanel.swift:522-542`, `MLM/Views/ContentView/ContentView.swift:162-171`) · ST-MAINT `Open Review` (`MLM/Views/Settings/MaintenanceView.swift:220-232`). · Leads to: playback (P-PLAYER) via `Preview`.
- Code: `MLM/Views/ReviewQueue/ReviewQueueView.swift:5-742` (view), `MLM/ViewModels/ReviewQueueViewModel.swift:5-246` (view model + `ReviewGroup`), `MLM/Database/AnalysisRepository.swift:166-179`, `315-471` (queue, resolution, undo), `MLM/Services/Analysis/DuplicateDetectionService.swift:246-482` (scan).
- Purpose: run a fingerprint scan that proposes groups of possibly-identical recordings and metadata conflicts, decide per group, and undo or restore decisions — all without touching audio files.
- User goals:
  1. Find out whether the library has duplicate recordings, e.g. after a big import — weekly/rare *(inferred)*.
  2. Decide which version to keep (best quality) for each duplicate group — rare bursts.
  3. Harmonise conflicting tags (title/artist/album artist/album/genre/year) between two copies of the same recording — rare (flow: edit-metadata).
  4. Say "these are different versions" so they stop being flagged — rare.
  5. Undo a wrong decision immediately or later — rare.
  6. Jump from a track's inspector to its group — rare.
- What the user wants to see, in priority order:
  1. How many groups need a decision, split by duplicates vs conflicts.
  2. Per group: which tracks, why they were flagged (similarity %), what MLM recommends and why.
  3. The differences that matter for the choice: format, bitrate, duration, location, local vs not downloaded, tag completeness — and a way to listen.
  4. What a decision will do (DB-only vs files) before making it, and a way back.
  5. Scan progress and when the last scan happened.
- Elements today:
  - V-REV.E01 Title `Review` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:100-101`).
  - V-REV.E02 Header button `Run scan` (prominent, icon `waveform.badge.magnifyingglass`) or, while scanning, `Cancel scan` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:103-115`).
  - V-REV.E03 Header status line, one of: progress bar + `Comparing <n> of <total>…` (pairs, not tracks, `MLM/Services/Analysis/DuplicateDetectionService.swift:321-327`); `Scan cancelled. Existing review decisions were left unchanged.`; `Last scan: <n> comparisons · <d> duplicate groups · <c> metadata conflicts` (this session only); or intro `Find possible duplicate recordings and metadata conflicts by comparing audio fingerprints.` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:118-137`).
  - V-REV.E04 Error banner (amber): warning icon + raw error text (`MLM/Views/ReviewQueue/ReviewQueueView.swift:68-76`).
  - V-REV.E05 Segmented control `Duplicates <n>` · `Conflicts <n>` · `Resolved <n>` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:142-151`).
  - V-REV.E06 Group card (Duplicates and Conflicts tabs) (`MLM/Views/ReviewQueue/ReviewQueueView.swift:209-270`):
    - E06a Title `<n> versions of "<Title>" — <Artist>` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:577-584`).
    - E06b Reason: `Identical recording (audio fingerprint <p>% match)` / `Same recording, different version (…)` / `Metadata conflict in <fields> (…)` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:586-597`).
    - E06c Recommendation line: `Recommended: keep <Artist — Title> — <reasons>` (falls back to `best available quality`) or `Recommendation: keep both — <reasons>` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:599-610`). The recommended track and the alternative often have the same "Artist — Title", so the line does not identify which file.
    - E06d Badge `Duplicate group` / `Metadata conflict` (amber capsule) (`MLM/Views/ReviewQueue/ReviewQueueView.swift:225-230`).
    - E06e Button `Review group` / `Hide details` — expands one group at a time (`MLM/Views/ReviewQueue/ReviewQueueView.swift:239-246`).
    - E06f Button `Keep all` (always visible on the card, no confirmation; undo toast follows) — toast `All versions kept` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:253-260`). Replaced by a small spinner while any decision on this group runs (`MLM/Views/ReviewQueue/ReviewQueueView.swift:250-251`).
  - V-REV.E07 Duplicate group detail (`MLM/Views/ReviewQueue/ReviewQueueView.swift:281-335`):
    - E07a One row per member track: check icon + `Recommended` or `Alternative`; format in caps (or `Unknown format`); `Artist — Title`; bitrate `<n> kbps` or `—`; duration or `—`; relative file path (middle-truncated, 140 pt) or `Local`/`Not downloaded`/format word; `Preview` button for local tracks (plays the track through the main player, replacing current playback) or the source word for others. Recommended row has a light green background (`MLM/Views/ReviewQueue/ReviewQueueView.swift:337-381`).
    - E07b `Keep recommended` (prominent) — toast `Recommended version kept` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:289-296`).
    - E07c Picker `Keep version` listing `Artist — Title` of each member (identical names are indistinguishable) + `Keep selected` — toast `Selected version kept` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:298-314`).
    - E07d `Never suggest again` — toast `Group will not be suggested again` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:316-323`).
    - E07e Variant note (music-note icon) `Same recording, different version` when flagged as variant (`MLM/Views/ReviewQueue/ReviewQueueView.swift:326-330`).
    - E07f Footer `Keeping all clears duplicate markers. Media files are not renamed, moved, or deleted.` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:331-333`).
  - V-REV.E08 Metadata conflict detail (`MLM/Views/ReviewQueue/ReviewQueueView.swift:384-485`):
    - E08a Intro `Same recording; choose the value to keep for each highlighted field.`
    - E08b Grid with header `Field` · `Version A` · `Version B` · `Keep`; one row per differing field (`Title`, `Artist`, `Album artist`, `Album`, `Genre`, `Year`; empty shown as `—`), field name amber, per-row segmented `A`/`B` (default A) (`MLM/Views/ReviewQueue/ReviewQueueView.swift:409-436`, `MLM/Models/ReviewDomain.swift:192-210`). Only the first two tracks of the group are compared even if there are more (`MLM/Views/ReviewQueue/ReviewQueueView.swift:385-403`).
    - E08c `Use all from A` · `Use all from B` · `These are different versions — keep both` (toast `Versions kept separately`) (`MLM/Views/ReviewQueue/ReviewQueueView.swift:438-456`).
    - E08d Preview line `After merge: Title "…", Artist "…", …` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:458`, `679-689`).
    - E08e Footer `Applies to the database only. Media files are not renamed or moved.` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:461-463`).
    - E08f `Apply merge` (prominent) — toast `Metadata merge applied`; writes the chosen values into **every** track of the group (`MLM/Views/ReviewQueue/ReviewQueueView.swift:465-473`, `MLM/Database/AnalysisRepository.swift:410-417`).
    - E08g `Never suggest again` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:475-482`).
    - E08h Fallback when fewer than 2 tracks still exist: `The source tracks are no longer available, so this conflict can only be kept as separate versions.` + `These are different versions — keep both` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:386-397`).
  - V-REV.E09 Resolved tab list: per group title + outcome (`Recommended version kept`, `Selected version kept`, `All versions kept`, `Metadata merged`, `Never suggest again`, `Earlier decision cannot be restored`, `Resolved`) + `Restore` button (if an undo snapshot exists) or label `Earlier decision` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:488-528`, `702-712`). No date, no filter, newest first.
  - V-REV.E10 Undo toast — S-REV-UNDOTOAST.
- What each decision does (files untouched in every case; DB only, one transaction, undo snapshot stored) (`MLM/Database/AnalysisRepository.swift:341-434`):
  - `Keep recommended` / `Keep selected`: kept track gets `is_duplicate = 0`; every other member gets `is_duplicate = 1, variant_of = <kept>`. The other tracks stay in the library, playlists and syncs unchanged.
  - `Keep all` / `These are different versions — keep both`: all members `is_duplicate = 0`.
  - `Apply merge`: same as Keep all + chosen tag values written to all members (search text rebuilt).
  - `Never suggest again`: only marks the queue rows resolved.
  - Undo / `Restore`: restores markers and tags from the snapshot and puts the group back to pending (`MLM/Database/AnalysisRepository.swift:438-471`).
  - Each decision posts `reviewQueueDidChange` (sidebar badge) and `libraryDidImport` (library reload) (`MLM/ViewModels/ReviewQueueViewModel.swift:225-230`).
- Interactions: click only; segmented controls/pickers. No keyboard navigation between groups, no multi-select or bulk decisions, no context menus, no drag & drop, no search/sort/filter.
- States:
  - Model not ready: `Loading Review…` (forever if library not loaded, `MLM/Views/ReviewQueue/ReviewQueueView.swift:37`, `41-43`).
  - Loading: `Loading Review…` centred (`MLM/Views/ReviewQueue/ReviewQueueView.swift:80-83`).
  - Never scanned (this session) and empty: icon + `Find duplicates and conflicts` + `A scan compares local audio fingerprints and creates review proposals without changing your library.` + `Run scan` (`MLM/Views/ReviewQueue/ReviewQueueView.swift:186-207`, `714-732`). "Never scanned" is per session — `scanResult` is not persisted, so after relaunch an empty library-clean state looks like "never scanned".
  - Scanned, no duplicates: `No duplicates found — your library is clean` + `Run another scan after importing more music.`
  - Conflicts empty: green check + `No metadata conflicts` + `Conflicting tags for the same recording appear here.`
  - Resolved empty: `No resolved reviews` + `Resolved duplicate and metadata decisions appear here and can be restored.`
  - Scanning: determinate pair progress, cancellable. Scan state lives in the view; switching sidebar sections rebuilds the view, losing progress display while the scan continues *(inferred, `MLM/Views/ContentView/ContentView.swift:377-378`)*. Scan is not shown in P-ACTIVITY (no registration found in `MLM/Services/Analysis/DuplicateDetectionService.swift:246-416`).
  - Error: E04 raw text.
  - Drive not connected: rows still show paths; `Preview` will try to play and fail in the player (not handled here).
  - Huge data: all pending groups in one scrolling list of cards; no paging.
- Data scale / performance notes: scan only covers tracks that have a fingerprint (`MLM/Database/TrackRepository.swift:906-914`); candidate pairs are duration-blocked; library has 12,935 tracks (ROADMAP §0). Number of fingerprinted tracks and typical group counts are unknown ("Unresolved from code").
- Pain points today:
  - **Rescans ignore earlier decisions**: a scan deletes all pending proposals and re-inserts every group it finds, without excluding resolved or `Never suggest again` groups (`MLM/Services/Analysis/DuplicateDetectionService.swift:404-410`, `MLM/Database/AnalysisRepository.swift:315-334`) — dismissals are not remembered (contradicts UI copy and §3.9).
  - "Keep recommended" removes nothing — the unkept copies remain everywhere, now permanently flagged; their inspector shows `Possible duplicate of …` + `Show in Review`, which finds no pending group and lands on an unrelated list (`MLM/Views/TrackDetail/MetadataPanel.swift:522-542`, `MLM/ViewModels/ReviewQueueViewModel.swift:88-90`).
  - Version rows are hard to tell apart: identical `Artist — Title`, path truncated to 140 pt, recommendation names a title not a file.
  - `Preview` hijacks main playback instead of a preview.
  - No bulk actions ("keep recommended for all") — one-by-one only *(daily-driver wish for multi-select bulk actions, `.planning/PROJECT.md:31`, `41`)*.
  - Conflicts compare only two tracks; merge writes the same tags into all copies but leaves both copies, with no "keep one" option on conflict cards.
  - Toast stays until Undo or the view is left; no timeout *(from code: only cleared on undo, `MLM/Views/ReviewQueue/ReviewQueueView.swift:530-548`, `571-575`)*.
  - "Last scan" is not persisted (no date).
- Related flows: review-duplicates, edit-metadata, daily-listening (Preview).
- Constraints / locked decisions: decisions are DB-only by design ("no reversible file restore", `MLM/ViewModels/ReviewQueueViewModel.swift:160-161`); native look; critical states in text.
- Open questions for the designer:
  - Should resolving a duplicate group ever affect playlists/syncs/visibility of the unkept copies (hide, replace in playlists), and how is that explained?
  - Is there a place for file actions (move unkept to Trash), given the code promises files are never touched?
  - How should 3+ versions be compared side by side, including metadata completeness?
  - What does "preview" mean here vs main playback (spacebar preview wish)?
  - How should bulk review work for dozens/hundreds of groups?
  - Should scanning be visible as background work (Activity) and continue across navigation?

## Context menus
None exist in these files: no `.contextMenu` in `SourcesView.swift`, `RemotePlaylistsView.swift` or `ReviewQueueView.swift`.

Expected, missing (evidence: analogous Finder/Music behaviour; inspector already links to Review):
- On a Review track row (V-REV.E07a): Show in Library / Show in Finder / Open in inspector / Play.
- On a remote playlist row (W-REMOTE.E06): Import / Open on SoundCloud.
- On a source card (V-SRC.E04): Sync / Disconnect / Open playlists.

## Sheets, popovers, panels, alerts

**S-REV-UNDOTOAST — Review undo toast**
- Trigger: any successful decision in V-REV (`Keep all`, `Keep recommended`, `Keep selected`, `Never suggest again`, `These are different versions — keep both`, `Apply merge`) (`MLM/Views/ReviewQueue/ReviewQueueView.swift:571-575`).
- Code: `MLM/Views/ReviewQueue/ReviewQueueView.swift:89-94`, `530-548`.
- Content: bottom-right floating panel (material background, shadow) with the decision text verbatim: `All versions kept` · `Recommended version kept` · `Selected version kept` · `Group will not be suggested again` · `Versions kept separately` · `Metadata merge applied`.
- Buttons: `Undo` (prominent) → restores the snapshot and puts the group back to pending; toast disappears on success.
- Cancel/escape: none; no close button, no timeout; replaced by the next decision's toast; gone when the view is rebuilt. Error: undo failure shows in V-REV.E04.

**S-SRC-OAUTH — Sign-in in the web browser (external)**
- Trigger: V-SRC `Connect`, or `Reconnect` when the keychain read fails (`MLM/ViewModels/SourcesViewModel.swift:205-240`, `267`).
- Code: `MLM/Services/Sources/SoundCloudClient.swift:182-217`, `MLM/Services/Sources/SpotifyClient.swift:65-111`, `MLM/Services/Auth/OAuthManager.swift:189-262`.
- Content: MLM opens the provider's authorization page in the default browser and waits for the loopback redirect. Nothing is shown in MLM during the wait (no "Waiting for browser…", no cancel).
- Outcome: success → card flips to `Connected`; failure → E04k with `Authorization was cancelled` / `Token exchange failed (HTTP …): …` / `OAuth state mismatch — possible CSRF attack` etc. No timeout found.

**A-SRC-KEYCHAIN — macOS keychain permission prompt (system)**
- Trigger: `Reconnect` (interactive keychain read, `MLM/ViewModels/SourcesViewModel.swift:256`) or saving tokens after `Connect` (`interactive: true`, `MLM/Services/Sources/SoundCloudClient.swift:205-211`, `MLM/Services/Sources/SpotifyClient.swift:99-107`).
- Content/buttons: macOS system dialog (not MLM copy). Allow → token readable, notice clears. Deny → falls back to browser sign-in (Reconnect) or connect error.

Expected, missing:
- Disconnect confirmation in V-SRC (exists in ST-SRC as `Disconnect <Name>?` / `This removes the saved <Name> credentials from this Mac. Syncing will stop until you reconnect.`, `MLM/Views/Settings/SourcesSetupView.swift:86-98`) — V-SRC's `Disconnect` acts immediately.
- Import result persistence outside the window (§3.6 rule 4).

## Menu items & keyboard shortcuts (area-local)

**K-REMOTE-DONE** — toolbar `Done` in W-REMOTE with `.cancellationAction` placement · scope: W-REMOTE key window · action: close window · `MLM/Views/Sources/RemotePlaylistsView.swift:43-53`. Whether Escape triggers it in an AppKit-hosted window is not verifiable from code ("Unresolved from code").

Cross-references (owned elsewhere): Navigate → `Sources` ⌘5 and `Review` ⌘6 (M-NAVIGATE, `MLM/App/MLMApp.swift:106-116`, keys from `MLM/Views/ContentView/ContentView.swift:624-625`).

Expected, missing: Return in W-REMOTE.E02 to `Load`; keyboard navigation between Review groups and decision shortcuts; Space to preview a Review row (daily-driver spacebar wish, `.planning/PROJECT.md:40`).

## Drag & drop
None implemented in these files.

Expected, missing:
- **D-REMOTE-URL-DROP (expected, missing)** — a playlist URL dragged from the browser onto V-SRC's YouTube card, onto W-REMOTE, or onto the Playlists area → open W-REMOTE preloaded. Evidence: universal search already detects playlist URLs but can't import (`MLM/Views/Search/UniversalSearchView.swift:220-224`).
- **D-REMOTE-PLAYLIST-TO-SIDEBAR (expected, missing)** — drag a remote playlist row to the sidebar/Playlists to import it.
- **D-REV-TRACK-OUT (expected, missing)** — drag a Review version row into a playlist or Finder.

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Source disconnected / expired**: V-SRC shows only `Connected`/`Not connected`/`Syncing…` (`MLM/Views/Sources/SourcesView.swift:312-315`); SoundCloud expiry appears as error text + temporary flip to `Not connected` (`MLM/ViewModels/SourcesViewModel.swift:332-336`) that reverts on reload because tokens stay in the keychain (`MLM/Services/Sources/SoundCloudClient.swift:395-427`); Spotify expiry surfaces only as `Spotify API error (401): …` (`MLM/Services/Sources/SpotifyClient.swift:150-153`). Sidebar dot `A source sign-in has expired` = any stored access token past its expiry time (`MLM/Views/Sidebar/SidebarView.swift:155-163`, `274-280`, `MLM/Services/Auth/TokenStorage.swift:92-95`) — for Spotify this happens after the token lifetime because no refresh is registered (`MLM/App/DependencyContainer.swift:123-135`) *(inferred)*. In W-REMOTE an expired sign-in reads `Video unavailable` (`MLM/ViewModels/RemotePlaylistsViewModel.swift:197-205`).
- **Keychain inaccessible**: amber notice + `Reconnect` (`MLM/Views/Sources/SourcesView.swift:211-221`, `262-271`), driven by `TokenAccessStatus` updated by background refresh with backoff (`MLM/Services/Auth/TokenRefresh.swift:206-246`).
- **Credentials file missing values**: `Connect` disabled + path hint (`MLM/Views/Sources/SourcesView.swift:229-248`).
- **Library loading/failed**: all three surfaces show their spinner indefinitely when the container is not ready (`MLM/Views/Sources/SourcesView.swift:117-120`, `MLM/Views/Sources/RemotePlaylistsView.swift:437-444`, `MLM/Views/ReviewQueue/ReviewQueueView.swift:41-43`).
- **Drive not connected**: not checked anywhere in this area; Review rows show paths and `Preview` regardless; W-REMOTE downloads fail with generic reasons *(inferred)*.
- **Track availability**: Review rows show `Local` / `Not downloaded` / format word (`MLM/Views/ReviewQueue/ReviewQueueView.swift:629-635`) — not the §1.6 chips; W-REMOTE shows no availability at all.
- **Possible duplicate marker** (track-level): written by Review decisions, shown in P-INSPECTOR (`MLM/Views/TrackDetail/MetadataPanel.swift:522-542`).

### Background work touchpoints

- **Source sync (likes/playlists)**: started by V-SRC `Sync`; progress = spinner + `Syncing…` only; result = `Last Sync` time; errors = card text. Not cancellable; not in Activity *(no Activity registration in `MLM/ViewModels/SourcesViewModel.swift:295-342`)*; state lost on navigation.
- **Token refresh** (SoundCloud only): background loop, visible only through the keychain-inaccessible notice (`MLM/Services/Auth/TokenRefresh.swift:160-246`).
- **Remote playlist preview fetch**: inline spinners (E03, E07); not cancellable.
- **Remote import download**: uses the shared download batch (`MLM/ViewModels/RemotePlaylistsViewModel.swift:127-130`) → progress in W-REMOTE.E21 and (per activity.md agent) P-ACTIVITY-OPS; `Cancel` cancels the whole batch; second batch rejected silently (`MLM/ViewModels/DownloadViewModel.swift:195-198`).
- **Duplicate scan**: V-REV only; determinate by pairs; `Cancel scan`; results replace pending proposals atomically; no Activity entry; not persisted "last scan".
- **Review decisions**: synchronous DB transactions with per-group spinner (`MLM/Views/ReviewQueue/ReviewQueueView.swift:250-251`).

### Flow notes

**import-remote-playlist (YouTube)**
1. Sidebar `Sources` (V-SRC) — intent: "import this YouTube playlist". 2. `Import playlist...` (V-SRC.E05) → W-REMOTE opens as a separate window. 3. Paste URL in E02, click `Load` (Return does nothing). If yt-dlp missing: `yt-dlp not installed — open Settings` + `Open Settings` → W-SETTINGS (no deep link to the right tab). 4. Review (E12–E17): title + count; titles only, no "already have" info. 5. Choose All/First N/Random N. 6. `Download All (n tracks)` → saving spinner → E21 progress → E22 result `n downloaded · m failed`, `Show failed`. 7. `Open playlist` shows V-PLD inside the import window (double-click inert) — user must still find it in the main window. Breaks: another download running → wrong progress/result; opening SoundCloud Playlists closes this window; failures can't be retried here; result lost on close.
**import-remote-playlist (SoundCloud/Spotify account)**
1. V-SRC card must be `Connected` → `Playlists` (E04m). 2. W-REMOTE lists account playlists (E06); SoundCloud also offers URL field. 3. Click a row → Review → Download/Save. Spotify: note that audio comes from SoundCloud/YouTube search. Breaks: expired sign-in → `Video unavailable` + `Retry` loop; re-importing with First N truncates the existing linked playlist.
**review-duplicates**
1. Sidebar badge `d dup · c conf` or ⌘6 → V-REV. 2. `Run scan` → `Comparing n of m…` (stay on the page or progress display is lost). 3. Duplicates tab → card reason + recommendation → `Review group`. 4. Compare rows (format, bitrate, duration, path), `Preview` (interrupts current playback). 5. `Keep recommended` / pick + `Keep selected` / `Keep all` / `Never suggest again` → toast with `Undo`. 6. Later: Resolved tab → `Restore`. Breaks: decisions remove nothing from the library — unkept copies remain and are now flagged forever (inspector `Possible duplicate` + dead `Show in Review`); next scan re-proposes everything including dismissed groups; no bulk mode.
**edit-metadata (conflicts)**
1. V-REV `Conflicts` tab → `Review group`. 2. Per-field A/B, `Use all from A/B`, `After merge:` preview. 3. `Apply merge` (DB only) or `These are different versions — keep both`. Breaks: only 2 versions compared; both copies remain with identical tags; tags in files are not written ("Applies to the database only").
**settings-changes (sources sign-in)**
1. V-SRC card `Not connected`; if credentials missing, `Connect` disabled with `.env` path hint — user must edit a hidden file outside MLM. 2. `Connect` → browser (S-SRC-OAUTH), MLM shows nothing while waiting. 3. Return to MLM → `Connected`, `Tracks`, `Last Sync Never`. 4. `Sync`. Apple Music: `Connect` always fails with `Apple Music integration not yet implemented (Phase 10)`. Disconnect in V-SRC is immediate; in ST-SRC it confirms.
**source-expired** *(area-specific flow)*
1. Amber dot on sidebar `Sources` (`A source sign-in has expired`, hover only). 2. User opens V-SRC: cards still say `Connected` — no expired state, no hint which source. 3. User presses `Sync` → SoundCloud: `SoundCloud session expired — click Connect to re-authenticate`, card shows `Connect`; Spotify: raw `Spotify API error (401): …`, card stays `Connected`, no Connect button (must Disconnect then Connect). 4. In ST-SRC the row says `Sign-in expired` with `Reconnect`, which only re-reads the keychain and does not sign in again (`MLM/Views/Settings/SourcesSetupView.swift:183-196`) — dead end. 5. In W-REMOTE the same situation reads `Video unavailable`. Breaks everywhere; the vocabulary state `Sign-in expired` + `Reconnect` (§1.6) is not implemented in V-SRC.
**fix-failed-downloads** (touch only): W-REMOTE.E23 lists failed titles with reasons but offers no retry; fixing happens in V-PLD/V-LIB (other agents).
**daily-listening** (touch only): V-REV `Preview` plays through the main player.

### Unresolved from code

- Whether Escape closes W-REMOTE via the `.cancellationAction` toolbar button in an AppKit-hosted `NSWindow` (needs a run).
- Whether reopening a closed W-REMOTE for the same source shows the old step (preview/result) or reloads: the controller and hosting view are retained (`MLM/App/AppDelegate.swift:98-105`, `118`), but SwiftUI `.task` re-run behaviour on window re-show can't be confirmed from code.
- Exact moment the sidebar "expired" dot appears for Spotify depends on the `expires_in` returned at sign-in (live data, not read).
- Number of fingerprinted tracks, pending/resolved review groups and typical group sizes in the live library — not in ROADMAP §0–§1; no live data read.
- Whether the download batch from W-REMOTE appears in P-ACTIVITY-OPS (owned by activity.md agent; only inferred from the shared `DownloadViewModel`).
- Whether the OAuth loopback server has an implicit timeout outside `MLM/Services/Auth/` (none found by grep).
- Whether `is_duplicate = 1` is used anywhere else to hide/filter tracks (grep found only inspector use, `MLM/Views/TrackDetail/MetadataPanel.swift:522`); if a filter is added later, "Keep recommended" semantics change.

