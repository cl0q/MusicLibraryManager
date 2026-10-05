# Settings window — tabs, sheets, alerts

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): SET (plus pre-assigned ST-LIB, ST-SRC, ST-MAINT, ST-BACKUP, ST-STORAGE, ST-PLAYBACK, ST-ADV) · Files covered: `MLM/Views/Settings/SettingsView.swift`, `LibrarySetupView.swift`, `SourcesSetupView.swift`, `MaintenanceView.swift`, `BackupSettingsView.swift`, `DataLocationsView.swift`, `MLM/ViewModels/BackupSettingsViewModel.swift`, `MLM/ViewModels/DataLocationsViewModel.swift`, plus `MLM/Views/TrackDetail/GrooveStudioView.swift` (content of the Advanced tab) and the services that decide what these tabs show (`BackupService`, `LibraryLaunchCoordinator`/`LibraryLaunchResolver`, `ImportViewModel`, `DependencyContainer.relocateTranscodeCache`, `OrganizedPathMigrationService`, `CredentialsLoader`, `SquidWtfClient`, `TokenStorage`, `PlaylistTableCache`, `SyncTurboLevel`, `PlaybackViewModel`/`AudioPlayer` settings reads)

**Reading guide for the designer.** The Settings window (W-SETTINGS, AppKit `NSWindow`, title `Settings`, owned by shell.md) hosts one SwiftUI `TabView` with seven tabs in this order: `Library` · `Sources` · `Maintenance` · `Backup` · `Storage Location` · `Playback` · `Advanced` (`MLM/Views/Settings/SettingsView.swift:12-54`). Every tab except Advanced is a grouped `Form`. Advanced is a full-size, four-screen workspace ("Genre Workshop") squeezed into the same window. Many tabs only work once a library is open; before that, most controls are silently inert (see "Global-state touchpoints").

**Tab container facts (contributes to W-SETTINGS; window shell itself is shell.md's):**
- Tab labels + SF Symbols: `Library` (`music.note.house`), `Sources` (`antenna.radiowaves.left.and.right`), `Maintenance` (`wrench.and.screwdriver`), `Backup` (`externaldrive.badge.timemachine`), `Storage Location` (`internaldrive`), `Playback` (`play.circle`), `Advanced` (`slider.horizontal.3`) — `MLM/Views/Settings/SettingsView.swift:13-53`.
- Selected tab persisted in `@AppStorage("settings.selectedTab")`, default `"library"`; tags `library`, `sources`, `maintenance`, `backup`, `storage`, `playback`, `advanced` — `MLM/Views/Settings/SettingsView.swift:9`.
- Size: SwiftUI min 500×400 (`MLM/Views/Settings/SettingsView.swift:55`), hosting min 600×500, initial 720×560, resizable; window is kept alive after closing (`isReleasedWhenClosed = false`) so tab state survives close/reopen — `MLM/App/AppDelegate.swift:67-84`.
- Opened by: `Settings…` ⌘, (M-APP, `MLM/App/MLMApp.swift:81-90`), sidebar footer `Settings` (P-SIDEBAR, `MLM/Views/Sidebar/SidebarView.swift:227`), `Open Settings` buttons in V-PLD failed-track rows (`MLM/Views/Playlists/PlaylistDetailView.swift:623-626`) and W-REMOTE (`MLM/Views/Sources/RemotePlaylistsView.swift:130-134,201-206`), and ST-SRC's own YouTube `Reconnect` (`MLM/Views/Settings/SourcesSetupView.swift:143-146`). **No caller can choose a tab** — every "Open Settings" lands on whatever tab was last selected. A `.openSettings` notification exists (`MLM/Utilities/Notifications.swift:125`) but nothing posts or observes it.

---

## Surfaces

### ST-LIB — Library
- Reached via: W-SETTINGS tab `Library` (default tab on first open) · Leads to: S-SET-LIBROOT, S-SET-IMPORTFOLDER, Finder (`Show in Finder`), P-ACTIVITY-OPS (import operations appear there), ST-STORAGE (points here for "No library folder set")
- Code: `MLM/Views/Settings/LibrarySetupView.swift:13-366` (view), `MLM/ViewModels/ImportViewModel.swift:59-215` (view model), `MLM/Services/Library/LibraryLaunchCoordinator.swift:93-94,263-271` (launch toggle), `MLM/Services/Library/LibraryLaunchResolver.swift:46-48` (what the toggle does at launch), `MLM/Services/Common/ManagedLibraryLayout.swift:6-8` (folder names)
- Purpose: Tell the user which library file is open and where the music folder is, let them point MLM at a different music folder, and (re)import audio from disk.
- User goals:
  1. See which library (name + `.mlibm` file location) is open and reveal it in Finder — rare (A3; `UI-GROUNDTRUTH.md` §3.14 Library file row).
  2. Decide whether MLM opens the last library automatically or asks at launch — rare (todo_dump.md line 4 "remember last opened library"; A0 D5).
  3. Point MLM at the music folder after moving music / on first setup — rare.
  4. Re-scan the music folder after adding files outside MLM — weekly *(inferred: new files copied in by Finder are not watched; Re-scan is the only catch-up besides V-FOLD)*.
  5. Import a folder of audio files from elsewhere — rare/weekly.
  6. Understand what the `Downloads (SoundCloud)` / `Downloads (YouTube)` / `Transcode originals` folders inside the music folder are — rare (`UI-GROUNDTRUTH.md` §3.14 "Storage layout (new)").
- What the user wants to see, in priority order:
  1. Which library is open and whether its music folder is reachable right now (drive connected or not).
  2. The music folder path, with an obvious way to change it and an honest warning of what changing it does to existing tracks.
  3. Import status: is something importing, how far, what happened last time (n imported / skipped / failed and which ones).
  4. The launch behaviour toggle.
  5. Reference info (managed folder explanations, supported formats).
- Elements today:
  - ST-LIB.E01 — Section `Library file` (header symbol `opticaldisc`), **only rendered when a library file is open** (`container.activeLibrary?.packageURL != nil`; hidden on the pre-A3 legacy layout) — `MLM/Views/Settings/LibrarySetupView.swift:23-37`.
  - ST-LIB.E02 — Library row: label = library display name (registry name, fallback file name without `.mlibm`); value = full path of the `.mlibm` file (data font, one line, middle-truncated, selectable) — `MLM/Views/Settings/LibrarySetupView.swift:91-99`.
  - ST-LIB.E03 — Button `Show in Finder` (reveals the `.mlibm` file) — `MLM/Views/Settings/LibrarySetupView.swift:100-102`.
  - ST-LIB.E04 — Toggle `Open the last library at launch`. Default **on**. Persistence: `remember_last_library` in the registry file `libraries.json` (not UserDefaults, not app_config) via `LibraryLaunchCoordinator.setRememberLastLibrary` — `MLM/Views/Settings/LibrarySetupView.swift:26-29`, `MLM/Services/Library/LibraryLaunchCoordinator.swift:263-271`, `MLM/Services/Library/LibraryRegistry.swift:23-40`. Effect: only at the **next launch** (no relaunch offered): when off, launch resolves to "no library" → V-LAUNCH-NOLIB (`MLM/Services/Library/LibraryLaunchResolver.swift:46-48`). Save failure is only logged; the toggle snaps back silently because its getter reads the unchanged coordinator value.
  - ST-LIB.E05 — Footer `When off, MLM asks which library to open at launch.` — `MLM/Views/Settings/LibrarySetupView.swift:33`.
  - ST-LIB.E06 — Section `Library Root` (symbol `folder.fill`). With a root: folder icon + path (one line, middle-truncated, not selectable) + bordered button `Change...`. Without a root: `No library folder selected` + prominent button `Select Folder...`. Both buttons open S-SET-LIBROOT — `MLM/Views/Settings/LibrarySetupView.swift:40-48,107-142`. Persistence: `app_config.library_root` via `ImportViewModel.setLibraryRoot` → posts `.libraryRootDidChange` (download pipeline, V-LIB, V-PLD re-read the root) — `MLM/ViewModels/ImportViewModel.swift:75-90`. No relaunch. No validation, no confirmation, no rescan, no warning that existing tracks' relative paths now resolve against the new folder.
  - ST-LIB.E07 — Footer `The root folder containing your music files. MLM will scan this folder recursively for audio files.` — `MLM/Views/Settings/LibrarySetupView.swift:45`.
  - ST-LIB.E08 — Section `Statistics` (only when a root is set): `Tracks in library` + count of local tracks from the DB (`countLocalTracks`) — `MLM/Views/Settings/LibrarySetupView.swift:51-57,164-174,316-318`.
  - ST-LIB.E09 — Row `Library path` + plain accent button `Show in Finder` (symbol `arrow.right.circle`) revealing the root folder (duplicate of E06's path, second reveal button) — `MLM/Views/Settings/LibrarySetupView.swift:176-191`.
  - ST-LIB.E10 — Section `Storage layout` (always shown): `MLM creates these folders inside your library when they are needed:` then three rows in mono: `Downloads (SoundCloud)` — `Music downloaded from SoundCloud.`; `Downloads (YouTube)` — `Music downloaded from YouTube and fallback sources.`; `Transcode originals` — `Original files retained while MLM creates a transcode.` — `MLM/Views/Settings/LibrarySetupView.swift:59-63,146-162`. Read-only, no reveal buttons.
  - ST-LIB.E11 — Section `Import` (only when a root is set), button `Re-scan Library` (`arrow.clockwise`): imports the whole root; Activity operation `Rescan library` / `Scanning ‹folder›…` — `MLM/Views/Settings/LibrarySetupView.swift:234-239`, `MLM/ViewModels/ImportViewModel.swift:96-114`.
  - ST-LIB.E12 — Button `Import Folder...` (`folder.badge.plus`) → S-SET-IMPORTFOLDER; Activity operation `Import: ‹folder›` — `MLM/Views/Settings/LibrarySetupView.swift:241-246,349-365`, `MLM/ViewModels/ImportViewModel.swift:118-124`.
  - ST-LIB.E13 — Import in progress (replaces E11/E12): determinate bar with phase label (`Scanning...` / `Extracting metadata...` / `Saving to database...` / `Complete`, from `MLM/Services/Import/ImportService.swift:140-229`) + `‹processed› / ‹total› files`; indeterminate small spinner before the first progress; red bordered `Cancel` (`xmark.circle`) — `MLM/Views/Settings/LibrarySetupView.swift:199-230`.
  - ST-LIB.E14 — Last result line: `‹n› imported` (green, `checkmark.circle`), `‹n› skipped` (only if >0), `‹n› failed` (amber, only if >0). No list of which files failed — `MLM/Views/Settings/LibrarySetupView.swift:250-268`.
  - ST-LIB.E15 — Error line (red text): e.g. `‹n› file(s) failed to import`, `Library root does not exist: ‹path›`, `No library root configured`, `Failed to save library root: …`, raw `localizedDescription` — `MLM/Views/Settings/LibrarySetupView.swift:270-274`, `MLM/ViewModels/ImportViewModel.swift:67,88,98,105,186,210`.
  - ST-LIB.E16 — Section `Supported Formats`: badge grid `MP3`, `FLAC`, `AAC`, `M4A`, `OGG`, `WAV`, `AIFF`, `ALAC` (static) — `MLM/Views/Settings/LibrarySetupView.swift:75-79,281-296`.
- Interactions: click only. Path text in E02 is selectable; E06 path is not. No context menus, no drag & drop (see D- section), no keyboard shortcuts. State loads once `onAppear` (`MLM/Views/Settings/LibrarySetupView.swift:82-85,311-322`).
- States:
  - default: as above.
  - no library open (V-LAUNCH-NOLIB in main window): E01 hidden; view model never created (`importService`/`configRepository` nil, `MLM/Views/Settings/LibrarySetupView.swift:300-309`) → E06 shows `No library folder selected` + `Select Folder...`; choosing a folder **writes nothing** (view-model call is a no-op) but the row then displays the chosen path as if saved (`MLM/Views/Settings/LibrarySetupView.swift:333-337`).
  - legacy (not-yet-adopted) layout: E01 hidden.
  - loading: no indicator; `trackCount` shows `0` until loaded.
  - error: E15 red text, raw strings.
  - offline / drive not connected: **not handled** — E06/E09 show the path exactly like when connected; `Show in Finder` on an unmounted path does nothing visible; `Re-scan Library` ends with `Library root does not exist: /Volumes/…` (`MLM/ViewModels/ImportViewModel.swift:104-107`). Contrast: ST-STORAGE shows `Not connected` for the same folder.
  - in-progress background work: E13; same work also appears in P-ACTIVITY-OPS (`MLM/ViewModels/ImportViewModel.swift:147-151`). Cancel stops scanning/extraction but not the later batch-saving phase (LOGIC-023).
  - huge data: full re-scan walks ~12,935 files on the external disk; progress is per file.
- Data scale / performance notes: 12,935 tracks (ROADMAP §0–§1); count is a single DB query; re-scan skips already-known paths (`MLM/Services/Import/ImportService.swift:319-326`) so most files report as `skipped`.
- Pain points today:
  - Changing the music folder has no consequence warning, no availability check, no rescan offer (`MLM/Views/Settings/LibrarySetupView.swift:324-339`); every organized path is relative to it (A0 D2), so a wrong pick silently turns tracks into "File missing" elsewhere.
  - Header says `Library Root`; glossary term is `Library folder` (`UI-GROUNDTRUTH.md` §1.5); ST-STORAGE says `Library folder` for the same thing.
  - Path shown twice (E06 and E09) with two different reveal styles.
  - No offline state (see States).
  - Failed imports: count only, no file list or reason.
  - `...` instead of `…` in `Change...`, `Select Folder...`, `Import Folder...` (`UI-GROUNDTRUTH.md` §3.14 uses `Change…`).
  - Library file section has no rename / switch / "open another library" — those live only in the File menu (M-FILE, shell.md).
  - Toggle failure silent (E04).
- Related flows: switch-library (Settings side: see which library is open, set launch behaviour), first-launch (alternative to S-WIZARD for setting the root), settings-changes (library folder), drive-unplugged.
- Constraints / locked decisions: one active library per process (A0 D4); switching = relaunch (ROADMAP §2 A3 step 0 #1); "Library file" / `Show in Finder` wording locked (`UI-GROUNDTRUTH.md` §1.5, §5.6); audio is referenced, never inside the library file (A0 D2).
- Open questions for the designer:
  - Should the library file section offer switching/renaming/opening another library, or stay informational with menus as the only entry?
  - How should "music folder not connected" read here, given the same fact is already shown in ST-STORAGE?
  - What must a user be told (and asked) before the music folder changes, given all track paths are relative to it?
  - Should import results be inspectable (which files failed and why) from here, from P-ACTIVITY, or both?
  - Does the Storage layout explainer belong in the Library tab, the Storage Location tab, or the wizard?

### ST-SRC — Sources
- Reached via: W-SETTINGS tab `Sources`; implicitly via every `Open Settings` button (only if Sources was the last tab) · Leads to: A-SET-DISCONNECT; keychain prompt on `Reconnect`
- Code: `MLM/Views/Settings/SourcesSetupView.swift:9-198`, `MLM/Services/Auth/TokenStorage.swift:59-78` (service names), `MLM/Services/Download/SquidWtfClient.swift:40-74` (cookie storage/expiry)
- Purpose: See which streaming accounts are signed in, sign them out, unlock a keychain-blocked token, and paste the Squid.wtf (Qobuz mirror) captcha cookie that lossless downloads need.
- User goals:
  1. Check whether SoundCloud/Spotify/Apple Music are connected or expired — weekly *(inferred from status vocabulary `UI-GROUNDTRUTH.md` §1.6 Source status)*.
  2. Renew the Squid captcha cookie when downloads say it expired — weekly (cookie expiry is flagged by the download pipeline, `MLM/Services/Download/SquidWtfClient.swift:330-335`).
  3. Disconnect an account (remove credentials from this Mac) — rare.
  4. Recover from "Token inaccessible" (keychain refused a silent read) — rare.
- What the user wants to see, in priority order:
  1. Per source: connected / disconnected / sign-in expired, and what that blocks (imports, downloads, syncing).
  2. One clear action per state (Connect, Reconnect, Disconnect).
  3. Cookie status (`Active` / `Expired — renew` / `Not configured`) and when it was last saved.
  4. How to obtain the cookie.
- Elements today:
  - ST-SRC.E01 — Section `Connected sources`: rows `SoundCloud`, `Spotify`, `Apple Music`, `YouTube`; each with status text below the name: `Connected` (green) / `Sign-in expired` / `Token inaccessible` / `Disconnected` (muted) — `MLM/Views/Settings/SourcesSetupView.swift:18-23,125-132,165-179`. Status is read from the keychain on every render; YouTube has no service and is **always `Disconnected`**.
  - ST-SRC.E02 — Destructive button `Disconnect` (only when `Connected`) → A-SET-DISCONNECT — `MLM/Views/Settings/SourcesSetupView.swift:134-138`.
  - ST-SRC.E03 — Button `Reconnect` (any non-connected state for SoundCloud/Spotify/Apple Music): one interactive keychain read (may show a macOS keychain prompt); on success clears refresh backoff and marks the token accessible; on failure or no stored credentials **nothing happens, no message** — `MLM/Views/Settings/SourcesSetupView.swift:139-142,184-197`. There is no OAuth sign-in from Settings.
  - ST-SRC.E04 — YouTube `Reconnect`: calls `showSettingsWindow()`, i.e. re-focuses the window the user is already in — a no-op — `MLM/Views/Settings/SourcesSetupView.swift:143-146`.
  - ST-SRC.E05 — Section `Squid.wtf (Qobuz Mirror)`, label `captcha_verified_at Cookie` — `MLM/Views/Settings/SourcesSetupView.swift:25-29`.
  - ST-SRC.E06 — Text field, placeholder `For example: 1779157770721`; Return saves (K-SET-COOKIE-RETURN) — `MLM/Views/Settings/SourcesSetupView.swift:30-35`. Persistence: UserDefaults `squid.captcha_cookie`; loaded on appear; env vars `MLM_SQUID_CAPTCHA` / `MLM_SQUID_CF_COOKIE` (process env or `.env`) take precedence over the field without the UI saying so (`MLM/Services/Download/SquidWtfClient.swift:50-59`).
  - ST-SRC.E07 — Helper text `Open qobuz.squid.wtf, complete one download (this passes the captcha), then copy the value of the 'captcha_verified_at' cookie from your browser's developer tools and paste it here.` — `MLM/Views/Settings/SourcesSetupView.swift:36`.
  - ST-SRC.E08 — Status label: `Not configured` (red `xmark.circle.fill`) / `Expired — renew` (orange `exclamationmark.triangle.fill`) / `Active` (green `checkmark.circle.fill`); expiry flag = UserDefaults `squid.captcha_cookie_expired`, set by the downloader; view listens to `.qobuzCookieStatusDidChange` — `MLM/Views/Settings/SourcesSetupView.swift:41-57,82-84`, `MLM/Services/Download/SquidWtfClient.swift:66-74`.
  - ST-SRC.E09 — `Save` (disabled when field blank): stores trimmed value, clears expired flag, stamps `squid_cookie_saved_at`, logs — `MLM/Views/Settings/SourcesSetupView.swift:60-61,101-116`. No validation of the value.
  - ST-SRC.E10 — Destructive `Clear`: empties field and removes the stored cookie **immediately, no confirmation** — `MLM/Views/Settings/SourcesSetupView.swift:62-65`.
  - ST-SRC.E11 — `Saved ‹relative time›` (e.g. "Saved 3 hr. ago"), persisted across launches — `MLM/Views/Settings/SourcesSetupView.swift:66-70,80,118-122`.
- Interactions: click; Return in E06; keychain system prompt on E03. No hover help.
- States: default · no library open: `tokenStorage` is nil → every row `Disconnected`, `Reconnect` does nothing (credentials are global per A0 D3, yet this tab depends on a library being open) · token inaccessible: `Token inaccessible` + `Reconnect` · expired: `Sign-in expired` + `Reconnect` (which only re-reads the keychain, does not refresh/sign in) · cookie expired: E08 orange · error on disconnect: logged only (`MLM/Views/Settings/SourcesSetupView.swift:153-163`) · offline drive: n/a.
- Data scale: 4 rows.
- Pain points: YouTube row is permanently "Disconnected" with a dead `Reconnect` (E04); `Reconnect` with nothing stored silently does nothing; no way to *connect* a source here (sign-in lives in V-SRC); `Clear` cookie destructive without confirmation (UI-014, still open for the cookie); developer jargon (`captcha_verified_at Cookie`, devtools instructions); hard-coded red/orange/green colours instead of the `mlm*` status tokens; env-var override invisible; `Token inaccessible` is not in the source-status vocabulary (`UI-GROUNDTRUTH.md` §1.6).
- Related flows: settings-changes (sources sign-in), import-remote-playlist, fix-failed-downloads (cookie renewal).
- Constraints: credentials are global, never per library (A0 D3); status words `Connected` / `Disconnected` / `Sign-in expired` (`UI-GROUNDTRUTH.md` §1.6); critical states always text.
- Open questions for the designer:
  - Should Settings → Sources be the single place to connect/disconnect, or a mirror of V-SRC cards? What happens to the YouTube row (no account concept)?
  - How should "this setting is overridden by an environment variable / credentials file" be communicated?
  - How much of the Squid cookie procedure belongs in the UI vs. a help link, given it is a personal workaround?
  - What does a user need to see when Settings is opened with no library open (credentials are global)?

### ST-MAINT — Maintenance
- Reached via: W-SETTINGS tab `Maintenance` · Leads to: S-SET-CACHEFOLDER, A-SET-PATHAPPLY, A-SET-PATHROLLBACK, V-REV (`Open Review`), V-PL (new "Liked from SoundCloud" playlist), P-ACTIVITY-OPS (only cache migration)
- Code: `MLM/Views/Settings/MaintenanceView.swift:8-881`; `MLM/App/DependencyContainer.swift:419-504` (cache relocation); `MLM/Services/Maintenance/OrganizedPathMigrationService.swift:110-146,181-193,744-749`; `MLM/Services/Maintenance/LibraryRepairService.swift:18-43`; `MLM/Services/Sync/SyncTurboLevel.swift:4-43`; `MLM/Services/Common/PlaylistTableCache.swift:39-74`; `MLM/ViewModels/SyncViewModel.swift:550-554`
- Purpose: Run batch jobs that keep the library healthy (analysis, artwork, tag rescans, path repair), set how hard background work may push the Mac, and move the transcode cache.
- User goals:
  1. Choose how aggressively background work uses the CPU (`Conservative`/`Standard`/`Fast`) — rare.
  2. Run analysis (fingerprint, loudness, danceability, similarity embeddings) for tracks that lack it — weekly *(inferred; todo `.planning/todos/pending/audio-analysis-ux-cleanup.md` says Oliver avoids these because feedback is poor)*.
  3. Fill missing artwork (embedded, then MusicBrainz) — weekly.
  4. Re-read tags after editing files externally — rare.
  5. Repair organized paths that no longer match files on disk, with preview and rollback — rare.
  6. Move the transcode cache to another disk to free space — rare.
  7. Recreate the "Liked from SoundCloud" playlist link — rare.
  8. Get to duplicate/conflict review — weekly (redirect only).
- What the user wants to see, in priority order:
  1. Which jobs are running, their progress, and a reliable Cancel.
  2. What each job will touch (how many tracks lack X) **before** running, and per-job results afterwards (not one shared line).
  3. Whether a job needs a missing tool (ffmpeg/fpcalc) and how to fix it.
  4. Where the transcode cache is, how big, and how to move or clear it.
  5. For path migration: what will change, what's ambiguous, where the safety backup/manifest went.
- Elements today:
  - ST-MAINT.E01 — Section `Background processing`: segmented picker (label hidden) with `Conservative — Keeps the Mac responsive` · `Standard` · `Fast — Uses all cores, fans may spin up`. Default `Standard`. Persistence: UserDefaults `sync_turbo_level` (raw values `60%`/`80%`/`100%`), written via `SyncViewModel.setBackgroundProcessing` (also invalidates the selected sync profile's preview) — `MLM/Views/Settings/MaintenanceView.swift:33-49,289-294`, `MLM/Services/Sync/SyncTurboLevel.swift:4-36`. Effect: next job start; maintenance workers only distinguish Conservative vs. not (`MLM/Views/Settings/MaintenanceView.swift:23-29`); worker count = cores × 0.6/0.8/1.0. Same setting is shown in V-SYNC-DETAIL.
  - ST-MAINT.E02 — Section `Transcode Cache`: `Location for transcoded audio files` + current path (mono, middle-truncated) or `Default location (internal)` (only when no cache object exists, i.e. no library) + `Change…` (disabled while any maintenance job runs) → S-SET-CACHEFOLDER — `MLM/Views/Settings/MaintenanceView.swift:51-82`. Persistence: `app_config.transcode_cache_path` (per library). No size, no `Clear cache`.
  - ST-MAINT.E03 — Helper `Changing the location moves existing cache files in the background and removes the old copies to free storage space.` — `MLM/Views/Settings/MaintenanceView.swift:84`.
  - ST-MAINT.E04 — Section `Table Cache`: row `Local Library` + `‹n› rows · ‹size›` where n = currently *displayed* (filtered) Library rows × 2 KB estimate — `MLM/Views/Settings/MaintenanceView.swift:91-107`.
  - ST-MAINT.E05 — Cached playlist rows (`music.note.list` + playlist name + `‹n› rows · ‹size›`) or `No playlists cached` — `MLM/Views/Settings/MaintenanceView.swift:109-138`.
  - ST-MAINT.E06 — Stepper `Cached playlists: ‹n›`, range 0–20, default 5, 0 disables; persisted UserDefaults `table_cache_playlist_cap`; immediate eviction — `MLM/Views/Settings/MaintenanceView.swift:140-155`, `MLM/Services/Common/PlaylistTableCache.swift:39-74`.
  - ST-MAINT.E07 — `Fingerprint all tracks` — `Generate audio fingerprints for tracks missing them` (`hand.point.up.braille`); result `Fingerprint: ‹n› processed, ‹n› failed`; missing tool: `fpcalc not found. Install via: brew install chromaprint` — `MLM/Views/Settings/MaintenanceView.swift:161-168,505-539`.
  - ST-MAINT.E08 — `ReplayGain analysis` — `Analyze loudness (LUFS) and compute energy buckets` (`waveform`); `ReplayGain: ‹n› analyzed, ‹n› failed`; `ffmpeg not found. Install via: brew install ffmpeg` — `MLM/Views/Settings/MaintenanceView.swift:170-177,541-576`.
  - ST-MAINT.E09 — `Danceability analysis` — `Analyze rhythmic beat regularity and compute danceability scores` (`sparkles`); `Danceability: ‹n› analyzed, ‹n› failed` — `MLM/Views/Settings/MaintenanceView.swift:179-186,578-611`.
  - ST-MAINT.E10 — `Similarity analysis (embeddings)` — `Generate on-device embeddings for similar-track suggestions` (`music.note.list`); `Similarity analysis: ‹n› analyzed, ‹n› failed`; `CoreML preprocessor or model not available. Ensure ffmpeg is installed.` — `MLM/Views/Settings/MaintenanceView.swift:188-195,613-646`.
  - ST-MAINT.E11 — `Refresh embedded artwork` — `Extract embedded artwork from audio files (ffmpeg, no network)` (`waveform.circle.fill`); `Embedded artwork: refresh complete` / `Artwork backfill service not available` — `MLM/Views/Settings/MaintenanceView.swift:197-204,649-673`.
  - ST-MAINT.E12 — `Fetch from MusicBrainz` — `Download missing album art from MusicBrainz Cover Art Archive (rate-limited)` (`globe`); `Artwork: ‹n› fetched, ‹n› cached, ‹n› not found` — `MLM/Views/Settings/MaintenanceView.swift:206-213,679-714`.
  - ST-MAINT.E13 — Shared job-row pattern for E07–E12 and E15: title + description; `Run` (disabled while any job runs) → small spinner while running; determinate bar + `Processing: ‹artist› - ‹title›` / `Processing...` + `‹current› / ‹total› (‹pct›%)`; bordered `Cancel` sets the result line to `‹title›: cancellation requested` — `MLM/Views/Settings/MaintenanceView.swift:424-501`. Only one job at a time. Jobs do **not** appear in P-ACTIVITY.
  - ST-MAINT.E14 — Section `Review`: `Duplicates and metadata conflicts` — `Run and manage review scans from Review so progress, decisions, and undo stay together.` + `Open Review` → posts `.showReview`, main window switches to V-REV (Settings window stays open/in front) — `MLM/Views/Settings/MaintenanceView.swift:216-234`, `MLM/Views/ContentView/ContentView.swift:162-171`.
  - ST-MAINT.E15 — Section `Library`: `Rescan metadata` — `Re-read audio tags from all local files` (`arrow.clockwise`); `Metadata rescan: ‹n› updated · ‹n› failed` / `Metadata rescan failed: …`; with no root set it returns 0/0 silently — `MLM/Views/Settings/MaintenanceView.swift:237-244,785-816`, `MLM/Services/Maintenance/LibraryRepairService.swift:22-29`.
  - ST-MAINT.E16 — Organized-path migration block: `Organized-path migration` + `Read only → Preview → Backup/manifest → confirmed database transaction`; `Preview changes` (spinner while auditing); after audit: summary `‹n› reviewed · ‹n› already valid · ‹n› unambiguous · ‹n› ambiguous · ‹n› audio files inventoried`; disclosure `Candidate report` (auto-expanded if ambiguous rows exist; max 360 pt tall) listing per track `#‹trackID› · ‹artist› — ‹title›`, badge `UNAMBIGUOUS` (green) / `AMBIGUOUS` (orange), `Before: ‹path›`, `After: ‹path›`, a note, candidate paths with internal reason codes (e.g. `deterministic_track_id`, `exact_basename`); prominent `Apply ‹n› unambiguous changes` (disabled at 0 or while running) → A-SET-PATHAPPLY; `Roll back last migration…` → A-SET-PATHROLLBACK. Results: `Path audit: ‹n› unambiguous changes ready; ‹n› ambiguous entries unchanged.` / `Path audit failed: …` / `Path migration did not start: finish all downloads first.` / `Path migration: ‹n› organized paths updated. Manifest: ‹path› · Backup: ‹path›` / `Path migration cancelled: …` / `Rollback: ‹n› organized paths restored. Manifest: … · Backup: …[ Warning: …]` / `Rollback cancelled: …` — `MLM/Views/Settings/MaintenanceView.swift:246,321-422,716-783`. Artifacts go to `~/Library/Application Support/com.musiclibrary.app/PathMigrations/` (`MLM/Services/Maintenance/OrganizedPathMigrationService.swift:744-749`). Error texts e.g. `Library root does not exist or is not a directory.` (`MLM/Services/Maintenance/OrganizedPathMigrationService.swift:122-145`).
  - ST-MAINT.E17 — Section `Source Playlists`: `Recreate or link a liked playlist for a source.`; picker `Source Type` with the single option `SoundCloud`; `Create or link playlist` (spinner while running) → finds/creates playlist `Liked from SoundCloud`, posts `.playlistDidChange`; result `Successfully created or linked playlist '‹name›'` / `Failed to create/link playlist: …` — `MLM/Views/Settings/MaintenanceView.swift:249-277,818-858`.
  - ST-MAINT.E18 — Shared result section (one line, last job only, body text) — `MLM/Views/Settings/MaintenanceView.swift:279-285`.
- Interactions: click; disclosure; selectable text in the candidate report. No keyboard shortcuts, no context menus.
- States:
  - default: all `Run` enabled.
  - running: one row shows progress + Cancel; all other `Run`/`Change…`/path buttons disabled.
  - no library open: every `Run` silently returns (guards on nil repositories), no message — e.g. `MLM/Views/Settings/MaintenanceView.swift:506-507`.
  - offline drive: jobs run and count every unreadable file as `failed`; path audit fails with `Library root does not exist or is not a directory.`; nothing on the tab says the drive is missing.
  - missing tools: one-line result with `brew install …`.
  - error: free-text result line incl. raw `localizedDescription`.
  - huge data: analysis over up to 12,935 tracks; candidate report rows lazily loaded.
  - in-progress background work elsewhere: only path *apply* checks for active downloads (`MLM/Views/Settings/MaintenanceView.swift:748-752`).
- Data scale: see ROADMAP §0–§1 (12,935 tracks); table-cache estimate 2 KB/row.
- Pain points: one shared result slot erases earlier results (`MLM/Views/Settings/MaintenanceView.swift:279-285`; `UI-GROUNDTRUTH.md` §3.15); Cancel does not stop queued workers or running tools (LOGIC-010) yet immediately says "cancellation requested"; maintenance jobs invisible in Activity while cache migration *is* in Activity (inconsistent); job state is view-local `@State` — what survives closing the Settings window is undetermined ("Unresolved from code"); no "how many tracks need this" before `Run`; no `Clear cache…` and no cache size here (`UI-GROUNDTRUTH.md` §3.15 asks for both); transcode cache path label does not refresh after relocation (`TranscodeCache` is not observable, `MLM/Services/Sync/TranscodeCache.swift:8`); "Table Cache" is developer-facing; candidate report exposes raw track IDs and internal reason codes (banned, `UI-GROUNDTRUTH.md` §1.5) and all-caps badges; result lines contain full filesystem paths; `Fetch from MusicBrainz` differs from doc `Fetch metadata from MusicBrainz`; Review row only opens Review, doc wants `Find duplicates & conflicts` that also starts the scan; todo "I click a button and I don't know what's happening" (`.planning/todos/pending/audio-analysis-ux-cleanup.md`).
- Related flows: settings-changes (transcode cache), fix-failed-downloads (path repair), review-duplicates (redirect), drive-unplugged, analysis-batch *(area-specific: run analysis/artwork jobs)*.
- Constraints: one concurrency setting, one name `Background processing` (`UI-GROUNDTRUTH.md` §1.5, Part 4 rule 2); "Rollback" reserved for path migration (§1.5); path migration flow (audit → preview → confirm → rollback) is called "genuinely good" and kept (§3.15).
- Open questions for the designer:
  - Should batch jobs live in Settings at all, or in Activity / a library-health view, given they are the only long-running work not visible in Activity?
  - How should per-job "last run / result / tracks still missing X" be presented so results don't overwrite each other?
  - How should tool prerequisites (ffmpeg, fpcalc, chromaprint) be surfaced — per job, or once?
  - Where does transcode cache management (location, size, clear) belong — here, ST-STORAGE, or V-SYNC?
  - Which parts of the path-migration report should a non-developer see?

### ST-BACKUP — Backup
- Reached via: W-SETTINGS tab `Backup`; ST-STORAGE hint `Change the backup folder in the Backup tab.` (text only, no link) · Leads to: S-SET-BACKUPFOLDER, A-SET-RESTORE, A-SET-RESTOREFAILED, app relaunch (→ W-MAIN / V-LAUNCH-NOLIB), Finder
- Code: `MLM/Views/Settings/BackupSettingsView.swift:7-270`, `MLM/ViewModels/BackupSettingsViewModel.swift:10-299`, `MLM/Services/Backup/BackupService.swift:5-26,120-126,160-216,274-376,395-438`, `MLM/App/DependencyContainer.swift:310-332`
- Purpose: Show that the library database and playlist covers are being backed up, where, and let the user back up now or restore an earlier state.
- User goals:
  1. Reassure: "is my library backed up, when was the last one?" — weekly (todo_dump.md line 4: lost DB when deleting the .app; "backup functionality built in by default").
  2. Back up now before a risky action — rare.
  3. Restore after something went wrong (bad merge, bad migration) — rare, high stakes.
  4. Put backups on another disk — rare.
  5. Decide how often backups happen and how many are kept — rare (todo_dump.md line 4 "user can decide how often"; ROADMAP §2 A2 "configurable interval" — **not implemented**).
- What the user wants to see, in priority order:
  1. Last backup time and whether backups are healthy.
  2. List of backups with date, why it was made, size and track count — enough to pick the right one to restore.
  3. Where backups live, and whether that place is reachable.
  4. The schedule/retention rules (and ideally control over them).
  5. A safe, explained restore.
- Elements today:
  - ST-BACKUP.E01 — Placeholder (no library loaded): `Backups are available once the library has loaded.` — `MLM/Views/Settings/BackupSettingsView.swift:16-25`.
  - ST-BACKUP.E02 — Busy section: small spinner + `Restoring…` / `Relaunching…` — `MLM/Views/Settings/BackupSettingsView.swift:42-51`.
  - ST-BACKUP.E03 — Error section: red `exclamationmark.triangle` + plain message; `Details` disclosure with selectable technical text — `MLM/Views/Settings/BackupSettingsView.swift:53-57,235-251`; messages from `MLM/ViewModels/BackupSettingsViewModel.swift:27-39,201-232`: `MLM can't write to the backup folder. Choose another folder.` · `The backup couldn't be created. Try again.` · `The backup copy failed its integrity check and was discarded. Try again.` · `This backup is damaged and can't be restored. Choose another backup.` · `This backup is incomplete and can't be restored. Choose another backup.` · `MLM couldn't save a copy of your current library, so nothing was restored. Check the backup folder and try again.` · `Something went wrong. Try again.` (also used for "backup belongs to another library").
  - ST-BACKUP.E04 — `Backup folder`: path (data font, middle-truncated, selectable) + muted `Default location` when default — `MLM/Views/Settings/BackupSettingsView.swift:115-129`. Default: `~/Library/Application Support/com.musiclibrary.app/backups/<library_id>/` (`MLM/Services/Backup/BackupService.swift:107-120`). Persistence of a custom folder: `app_config.backup_destination` (per library; empty = default).
  - ST-BACKUP.E05 — `Change…` → S-SET-BACKUPFOLDER; chosen folder is write-probed first, unwritable → E03 `MLM can't write…` and the old folder stays — `MLM/Views/Settings/BackupSettingsView.swift:133-135,253-265`, `MLM/ViewModels/BackupSettingsViewModel.swift:124-139`. Existing backups are **not moved**; the list then shows only bundles in the new folder.
  - ST-BACKUP.E06 — `Use default` (only when custom) — `MLM/Views/Settings/BackupSettingsView.swift:136-140`, `MLM/ViewModels/BackupSettingsViewModel.swift:142-152`.
  - ST-BACKUP.E07 — `Show in Finder` (folder; disabled if none) — `MLM/Views/Settings/BackupSettingsView.swift:141-146`.
  - ST-BACKUP.E08 — `Last backup` ‹date, abbreviated + time› / `Never` (newest *complete* bundle) — `MLM/Views/Settings/BackupSettingsView.swift:149`.
  - ST-BACKUP.E09 — `Backups` ‹count› — `MLM/Views/Settings/BackupSettingsView.swift:150`.
  - ST-BACKUP.E10 — `Total size` ‹size› (allocated size of all listed bundles) — `MLM/Views/Settings/BackupSettingsView.swift:151`.
  - ST-BACKUP.E11 — Section header `Status`, footer `Each backup contains the library database and playlist covers. Audio files and account credentials are never included.` — `MLM/Views/Settings/BackupSettingsView.swift:152-158`.
  - ST-BACKUP.E12 — Section `Backups`: one row per bundle of the open library, newest first: date; muted `‹Reason› · ‹n› tracks · ‹size›` (reasons `Automatic` / `Before update` / `Manual` / `Before restore` / `Before library file setup` / `Unknown`); incomplete bundles add `Incomplete — can't be restored` (`exclamationmark.circle`, attention colour); hover help `Database version: ‹schema›` — `MLM/Views/Settings/BackupSettingsView.swift:163-202`, `MLM/ViewModels/BackupSettingsViewModel.swift:189-198,247-256`.
  - ST-BACKUP.E13 — Row button `Restore…` (complete bundles only) → A-SET-RESTORE — `MLM/Views/Settings/BackupSettingsView.swift:192-196`.
  - ST-BACKUP.E14 — Row button `Show in Finder` (reveals the bundle folder) — `MLM/Views/Settings/BackupSettingsView.swift:197-199`.
  - ST-BACKUP.E15 — Empty: `No backups yet. MLM backs up automatically at launch, at most once a day.` — `MLM/Views/Settings/BackupSettingsView.swift:165-168`.
  - ST-BACKUP.E16 — Section `Actions`: `Back up now`; while running spinner + `Backing up…`; afterwards green `Backup created` — `MLM/Views/Settings/BackupSettingsView.swift:206-223`, `MLM/ViewModels/BackupSettingsViewModel.swift:108-120`.
  - ST-BACKUP.E17 — Footer `The 10 most recent backups are kept. MLM also backs up at launch (at most once a day) and before updating the library database.` — `MLM/Views/Settings/BackupSettingsView.swift:226-230`. Retention fixed at 10 (`MLM/Services/Backup/BackupService.swift:126`), schedule fixed (launch, ≥24 h since newest complete bundle, `MLM/Services/Backup/BackupService.swift:211-220`, `MLM/App/DependencyContainer.swift:321-331`), pre-migration backup at startup (`MLM/Services/Backup/BackupService.swift:405-438`). No controls for interval or retention.
- Interactions: click; hover help on rows; `Details` disclosure; whole status/list/actions group disabled while busy (`MLM/Views/Settings/BackupSettingsView.swift:59-64`). Data refreshes on tab appear only (`MLM/Views/Settings/BackupSettingsView.swift:68-70`) — the launch backup finishing while the tab is open does not update it.
- States: not loaded (E01) · empty (E15) · loading: no indicator (list appears when measured) · backing up (E16) · restoring/relaunching (E02 + all controls disabled) · error (E03) · restore failed after DB closed (A-SET-RESTOREFAILED) · offline: a custom folder on an unplugged disk is **not flagged here** (path shown normally; listing/creation then fails — exact message undetermined, "Unresolved from code"); ST-STORAGE shows `Not connected` for it · incomplete bundle (E12 label, no Restore).
- Data scale: ≤10 bundles + "Before restore" bundles (never pruned during restore); each holds a ~130 MB DB snapshot (A0 D7) + 36 covers.
- Pain points: interval/retention not configurable despite todo_dump/ROADMAP A2; restore does not check for active downloads/syncs — it only *asks* the user to finish them (`MLM/ViewModels/BackupSettingsViewModel.swift:157-179`, contrast path apply guard `MLM/Views/Settings/MaintenanceView.swift:748-752`); restore relaunch ignores which library to reopen — with `Open the last library at launch` off the relaunch lands on V-LAUNCH-NOLIB (`MLM/Services/Backup/BackupService.swift:344-376` sets no pending library, unlike `MLM/Services/Library/LibraryLaunchCoordinator.swift:404-410`; resolver `MLM/Services/Library/LibraryLaunchResolver.swift:46-48`) *(inferred from code)*; "belongs to another library" error shows generic `Something went wrong. Try again.`; changing folder strands old backups without saying so; no offline state for the folder; footer claims "before updating the library database" — true only at startup migrations.
- Related flows: backup-restore, switch-library (backups are per library), drive-unplugged (custom folder on external disk).
- Constraints: Backup/Restore wording locked (`UI-GROUNDTRUTH.md` §1.5, §5.6); restores never cross libraries (ROADMAP §2 A3 step 0 #4); credentials never in backups (A0 D3); "Rollback" reserved for path migration.
- Open questions for the designer:
  - Which backup controls should exist (interval, retention count, destination) and how prominent should "last backup" health be outside Settings?
  - How should a restore communicate "MLM will quit and reopen" and what the user lands on?
  - How should backups in a folder that is currently unreachable be shown?
  - Should backups of *other* libraries in a shared folder be visible at all?

### ST-STORAGE — Storage Location
- Reached via: W-SETTINGS tab `Storage Location` · Leads to: Finder only (no navigation; hints point to ST-BACKUP, ST-MAINT, ST-LIB in text)
- Code: `MLM/Views/Settings/DataLocationsView.swift:8-229`, `MLM/ViewModels/DataLocationsViewModel.swift:4-443`, `MLM/Utilities/CredentialsLoader.swift:14-19`
- Purpose: Answer "where does MLM keep my stuff, how big is it, is it reachable?" — transparency only, no moving.
- User goals:
  1. Find the library file / database / covers / backups / credentials file / music folder / transcode cache on disk — rare (todo_dump.md line 4 "more transparency and especially more control over where all data is").
  2. See sizes before cleaning up disk space — rare.
  3. Check whether the music folder / cache disk is connected — weekly *(inferred: external disk often unmounted, product facts)*.
  4. Know what survives deleting the app — rare (todo_dump.md line 4 anecdote).
- What the user wants to see, in priority order:
  1. Every location, its path, reachable or not (in words), and a `Show in Finder`.
  2. Sizes (library file, DB incl. pending changes, covers, backups, cache, music folder on request).
  3. Which locations are per-library vs. global, and what survives deleting the app.
  4. Where to change each location.
- Elements today:
  - ST-STORAGE.E01 — Placeholder `Storage locations are shown once the library has loaded.` — `MLM/Views/Settings/DataLocationsView.swift:17-26`.
  - ST-STORAGE.E02 — Section `Library data`, row `Library file` (only when a `.mlibm` is open): path + total size — `MLM/Views/Settings/DataLocationsView.swift:74-77`, `MLM/ViewModels/DataLocationsViewModel.swift:264-272`.
  - ST-STORAGE.E03 — Row `Database`: path + `‹total› · database file ‹size› · recent changes ‹size›`; hover help `Recent changes are kept in a separate file (-wal) and merged into the database automatically.` — `MLM/Views/Settings/DataLocationsView.swift:78-79`, `MLM/ViewModels/DataLocationsViewModel.swift:274-284`.
  - ST-STORAGE.E04 — Row `Playlist covers`: path + `‹n› files · ‹size›` — `MLM/Views/Settings/DataLocationsView.swift:80`, `MLM/ViewModels/DataLocationsViewModel.swift:286-292`.
  - ST-STORAGE.E05 — Row `Backups`: path + `‹n› backups · ‹size›` + muted `Change the backup folder in the Backup tab.` — `MLM/Views/Settings/DataLocationsView.swift:81-85`.
  - ST-STORAGE.E06 — `Last backup` ‹date› / `Never` — `MLM/Views/Settings/DataLocationsView.swift:86`.
  - ST-STORAGE.E07 — Row `Credentials file`: path of `~/Library/Application Support/MLM/.env` + size, or `Not found` (contents never read) — `MLM/Views/Settings/DataLocationsView.swift:87`, `MLM/ViewModels/DataLocationsViewModel.swift:306-310`.
  - ST-STORAGE.E08 — Section `Music`, row `Library folder`: path; state line; `‹n› tracks`; stored size `‹size› · calculated ‹date›` or `Size not calculated` (shown even when not connected); `Calculate size` (disabled unless available) → while running small spinner + `Calculating…` + `Cancel`; error `The size couldn't be calculated. Check that the drive is connected and try again.`; `Show in Finder` hidden when no root — `MLM/Views/Settings/DataLocationsView.swift:90-91,144-189`, `MLM/ViewModels/DataLocationsViewModel.swift:198-229,318-331`. Persistence of the size: `app_config` keys `library_size_bytes` / `library_size_calculated_at` / `library_size_root`; discarded when the folder changes (`MLM/ViewModels/DataLocationsViewModel.swift:30-56,191-193`).
  - ST-STORAGE.E09 — Row `Transcode cache`: path + size + muted `Change the location in the Maintenance tab.` — `MLM/Views/Settings/DataLocationsView.swift:92-96`.
  - ST-STORAGE.E10 — Section `Sign-in`, `Sign-in tokens` — `Stored in the macOS Keychain` (no button) — `MLM/Views/Settings/DataLocationsView.swift:99-103`.
  - ST-STORAGE.E11 — Footer `Library files and the credentials file remain on your Mac if you delete the app. Audio files are never moved by this tab.` — `MLM/Views/Settings/DataLocationsView.swift:103-107`.
  - ST-STORAGE.E12 — State line under any path: `Not found` (`questionmark.folder`) / `Not connected` (`externaldrive.badge.xmark`, path under an unmounted `/Volumes/<name>`) / `No library folder set — choose one in the Library tab.` (`folder.badge.questionmark`); secondary colour, no hue — `MLM/Views/Settings/DataLocationsView.swift:205-213`, `MLM/ViewModels/DataLocationsViewModel.swift:233-250,437-442`.
  - ST-STORAGE.E13 — Per-row `Show in Finder`, disabled unless the location is available — `MLM/Views/Settings/DataLocationsView.swift:221-228`.
- Interactions: click; selectable paths; hover help on Database. Refresh only on tab appear (`MLM/Views/Settings/DataLocationsView.swift:111-113`) — plugging the drive in while the tab is open does not update it.
- States: not loaded (E01) · default · not found / not connected / not set (E12) · calculating (E08) · size failed (E08 error) · legacy layout (no Library file row) · huge data: library folder size walks ~13k files on the external disk, so it is on-request only.
- Data scale: DB ~130 MB + WAL (A0 D7); 36 covers; ≤10+ backups.
- Pain points: list is not "every location" (ROADMAP §1.1 claim): missing the library registry `libraries.json` (`MLM/Services/Library/LibraryRegistry.swift:143`), path-migration backups/manifests `PathMigrations/` (`MLM/Services/Maintenance/OrganizedPathMigrationService.swift:744-749`), artwork cache `~/Library/Caches/com.mlm.artwork_cache` (`MLM/Services/Artwork/ArtworkBackfillService.swift:78-79`), waveform cache (`MLM/Services/Library/ActiveLibrary.swift:44`), logs `~/Library/Logs/MLM/mlm.log` (`MLM/Utilities/AppLogger.swift:261-266`), `legacy-adopted-…` folder; no distinction between per-library and global (credentials/tokens) locations; hints are plain text, not links; no auto-refresh.
- Related flows: drive-unplugged, settings-changes, backup-restore, switch-library (which library's files are these?).
- Constraints: transparency only — no move/change actions in this tab (`UI-GROUNDTRUTH.md` §3.14); tab name `Storage Location`, never "Storage" alone; state words `Not found` / `Not connected` text + symbol.
- Open questions for the designer:
  - Should the hints become navigation (jump to Backup/Maintenance/Library tab)?
  - How to group per-library vs. machine-wide locations so a user understands what moves with a library file?
  - Should missing locations (registry, logs, caches, migration artifacts) be listed, and how to keep the tab short?

### ST-PLAYBACK — Playback
- Reached via: W-SETTINGS tab `Playback` · Leads to: nothing
- Code: `MLM/Views/Settings/SettingsView.swift:59-101`; consumers `MLM/ViewModels/PlaybackViewModel.swift:132-137,206,264-270,666-674`, `MLM/Services/Audio/AudioPlayer.swift:419-440`
- Purpose: Tune playback history length, queue length when playing from a list, and loudness normalisation.
- User goals:
  1. Turn loudness normalisation on/off so tracks play at similar volume — rare (set once) *(inferred)*.
  2. Keep more/less playback history — rare.
  3. Limit how many following tracks are queued when starting playback from a table — rare.
- What the user wants to see: whether normalisation is on and what it does (target, requirement that tracks are analysed — LUFS comes from ST-MAINT.E08); plain explanations of history/queue limits.
- Elements today:
  - ST-PLAYBACK.E01 — Section `History`: stepper `History size: ‹n›`, range 10–500, step 1, default 50; persisted UserDefaults `playback_history_size` on change; applied at the next recorded play (`MLM/Views/Settings/SettingsView.swift:62-64,72-81`, `MLM/ViewModels/PlaybackViewModel.swift:264-270`).
  - ST-PLAYBACK.E02 — Section `Queue`: stepper `Queue cap: ‹n›`, range 10–1000, default 100; UserDefaults `playback_context_cap`; applied the next time playback starts from a list (`MLM/Views/Settings/SettingsView.swift:65-67,83-92`, `MLM/ViewModels/PlaybackViewModel.swift:132-137`).
  - ST-PLAYBACK.E03 — Section `Audio`: toggle `Normalize loudness (LUFS)`, default off, `@AppStorage("playback_lufs_normalization")`; applied when the next track loads (target −14 LUFS, max +6 dB boost; tracks without LUFS data play at unity) (`MLM/Views/Settings/SettingsView.swift:68,94-96`, `MLM/Services/Audio/AudioPlayer.swift:419-440`, `MLM/ViewModels/PlaybackViewModel.swift:206`).
- Interactions: stepper arrows / click; no text entry for numbers (stepping to 500 or 1000 is many clicks).
- States: only default; works without a library (UserDefaults). No explanation texts, no "takes effect on next track" note.
- Data scale: n/a.
- Pain points: no help text (what is "Queue cap"? jargon); normalisation silently does nothing for unanalysed tracks; steppers with wide ranges; values are global (UserDefaults), not per library — undocumented.
- Related flows: daily-listening, settings-changes.
- Constraints: `UI-GROUNDTRUTH.md` §3.14 lists the tab but specifies no content.
- Open questions for the designer:
  - Do history size and queue cap need to be user-facing at all?
  - How should the dependency "normalisation needs ReplayGain analysis" be explained, and should Sync's `Normalize volume` (V-SYNC-DETAIL) share wording?

### ST-ADV — Advanced (Genre Workshop)
- Cross-reference: the four screens of this tab are also documented one by one as [ST-STUDIO-GRID, ST-STUDIO-GENRE, ST-STUDIO-MERGE, ST-STUDIO-EXPORT](inspector.md#st-studio-grid--genre-workshop-genre-grid-settings--advanced), because their code lives in `MLM/Views/TrackDetail/GrooveStudioView.swift`. This entry is the tab-level view (elements `ST-ADV.Exx`); the ST-STUDIO-* entries describe the sub-screens. Where the two disagree, read both — each was verified against code independently.
- Reached via: W-SETTINGS tab `Advanced` (the tab label never says "Genre Workshop") · Leads to: CM-TRACK (three placements), S-SET-EXPORTFOLDER, P-ACTIVITY-OPS (CreateML export operation), main playback (P-PLAYER, from merger table)
- Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:15-2196` (view, state and logic in one file), preview players `MLM/Views/TrackDetail/GrooveView.swift:37-60` (`PreviewPlayerManager`), `MLM/Views/TrackDetail/WaveformView.swift:42-140`, `MLM/Database/TrackRepository.swift:1501-1550` (genre queries/merge)
- Purpose: Clean up and expand genre tags using on-device similarity suggestions, merge spelling variants of genres, and export a genre-labelled training set for Apple Create ML.
- User goals:
  1. Tag untagged tracks with a genre by auditioning "sounds like this reference" suggestions — rare/weekly (`UI-GROUNDTRUTH.md` §3.15 "kept feature").
  2. Merge duplicate/variant genre names into one canonical genre — rare.
  3. Export ≥50-tracks-per-genre folders as AAC 248 kbps for training a SoundClassifier — rare.
  4. Mark bad suggestions so they stop appearing — rare.
- What the user wants to see, in priority order:
  1. Genres with counts (and which are too small / likely duplicates).
  2. For a genre: the reference track, suggestions with match strength, quick audition, stage/save.
  3. For merging: which tracks each selected genre contains, and the exact consequence (DB only, no file tags, no undo).
  4. For export: eligible vs. excluded, destination, progress, result.
- Elements today (four screens switched in place with slide transitions; `MLM/Views/TrackDetail/GrooveStudioView.swift:129-155`):
  - **Screen 1 — Genre grid**
    - ST-ADV.E01 — Title `Genre Workshop`, subtitle `Pick a genre to review suggestions and clean up your tags.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:162-170`.
    - ST-ADV.E02 — Button `Consolidate genres` (`circle.grid.3x3.fill`, help `Consolidate inconsistent genres in your library`) → Screen 3 — `MLM/Views/TrackDetail/GrooveStudioView.swift:174-200`.
    - ST-ADV.E03 — Button `Export training set (CreateML)` (`cpu`, help `Export a flat training set for CreateML`) → Screen 4 — `MLM/Views/TrackDetail/GrooveStudioView.swift:202-224`.
    - ST-ADV.E04 — Genre cards (adaptive grid 220–300 pt): note icon, count badge, genre name, `1 Song` / `‹n› Songs`; click → Screen 2 and loads that genre's tracks. Sorted by count descending — `MLM/Views/TrackDetail/GrooveStudioView.swift:256-326`, `MLM/Database/TrackRepository.swift:1501-1513`.
    - ST-ADV.E05 — Loading `Loading genres...`; empty `No genres in your library yet` / `Tag some tracks to use the workshop.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:233-255`.
  - **Screen 2 — Genre detail**
    - ST-ADV.E06 — Back button `Genres` (stops both preview players, discards **unsaved staged edits without asking**) — `MLM/Views/TrackDetail/GrooveStudioView.swift:336-363`.
    - ST-ADV.E07 — Genre title; `Save (‹n›)` (purple, only when edits staged) → writes genre to each track in the DB, records positive similarity feedback, posts `.libraryDidImport`; then message `‹n› track(s) tagged and saved.` for 4 s or `Could not save changes.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:365-392,1857-1908`. DB only; file tags are not written.
    - ST-ADV.E08 — Left preview player card: label `Suggestion player` / `Preview player`, `‹title› · ‹artist›` or `Ready for preview…`, play/pause, waveform (click/drag to seek, pinch to zoom), `‹pos› / ‹dur›` or `0:00` — `MLM/Views/TrackDetail/GrooveStudioView.swift:428-491`.
    - ST-ADV.E09 — Right preview player card: `Reference player` / `Preview player`, same controls — `MLM/Views/TrackDetail/GrooveStudioView.swift:493-556`. Starting either preview **pauses main playback** (`MLM/Views/TrackDetail/GrooveView.swift:42`); a missing file is only logged (`MLM/Views/TrackDetail/GrooveView.swift:58-60`).
    - ST-ADV.E10 — Left column `Suggestions` (`sparkles`); when a reference is set: `Temperature:` slider 0.0–1.0 step 0.1 (default 0.3, value shown), `Suggestions:` segmented `10 tracks` / `20 tracks` (default 10), checkbox `Suggest untagged tracks only` (default off); each change reloads suggestions. Not persisted — `MLM/Views/TrackDetail/GrooveStudioView.swift:567-626`.
    - ST-ADV.E11 — Suggestion rows: cover as play button (overlay play/pause when current), title, artist, badge `‹n›% Match` (green >80, amber >60) or, when staged, a purple outlined genre tag; thumbs-up (help `Mark this genre for saving`) toggles staging; thumbs-down (help `Exclude this track from suggestions`) immediately stores negative feedback in the DB and removes the row; double-click plays in the left player; right-click → CM-TRACK — `MLM/Views/TrackDetail/GrooveStudioView.swift:672-796,1807-1853`.
    - ST-ADV.E12 — Suggestion states: no reference `Choose a reference track` / `Double-click a track on the right to load suggestions.`; loading `Finding suggestions…`; empty `No suggestions found` / `Adjust the temperature or remove filters.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:633-671`. Load errors are only printed.
    - ST-ADV.E13 — Right column `Tracks in ‹genre›`; reference card `Reference track` + title/artist + remove button (help `Remove reference track`), or dashed placeholder `No reference selected` / `Double-click a track below to generate suggestions` — `MLM/Views/TrackDetail/GrooveStudioView.swift:803-893`.
    - ST-ADV.E14 — Known-track rows (all tracks of the genre except the reference): cover play button, title, artist, album; double-click = set as reference (first time; auto-plays it and loads suggestions) or preview in right player (afterwards); right-click → CM-TRACK; loading `Loading genre tracks...`; empty `No known tracks available` — `MLM/Views/TrackDetail/GrooveStudioView.swift:899-1003,1729-1743`.
  - **Screen 3 — Consolidate genres**
    - ST-ADV.E15 — `Back` + title `Consolidate genres` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1013-1040`.
    - ST-ADV.E16 — Intro `Select alternate spellings or duplicate genres and merge them into one canonical genre. Tracks update immediately in the database.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1051-1054`.
    - ST-ADV.E17 — Success banner (green, `Genres merged into '‹name›'.`) / error banner (red, `The target genre name cannot be empty.` or `Could not merge genres: …`) — `MLM/Views/TrackDetail/GrooveStudioView.swift:1056-1078,1912-1948`.
    - ST-ADV.E18 — `SELECT (‹n› selected)` list (fixed 200 pt): checkbox per genre (first checked genre pre-fills the target name), row click previews that genre below, `‹n› Songs` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1081-1151`.
    - ST-ADV.E19 — `MERGE` box: **German** label `Neuer kanonischer Genre-Name:`, placeholder `z.B. Hip Hop & Rap` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1155-1176`.
    - ST-ADV.E20 — `Merge selected genres` (disabled until ≥2 selected and a name) → **immediate** `UPDATE tracks SET genre` (DB only, no confirmation, no undo, file tags untouched), posts `.libraryDidImport` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1178-1193`, `MLM/Database/TrackRepository.swift:1537-1543`.
    - ST-ADV.E21 — Preview area: header `Tracks in "‹genre›" (showing ‹n› of 50)` + `Double-click to preview`; native table, multi-select, sortable columns `Title` (cover + now-playing speaker) · `Artist` · `Album` · `Time` · `Format`; right-click → CM-TRACK (multi-selection); double-click plays in the **main player** (not a preview); loading `Loading tracks…`; empty `No tracks found in this genre.`; nothing chosen `Choose a genre from the list` / `Select a genre above to review up to 50 tracks before merging.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1205-1333`.
  - **Screen 4 — Export CreateML training set**
    - ST-ADV.E22 — `Back` (disabled while exporting; also cancels a running export) + title `Export CreateML training set` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1345-1368`.
    - ST-ADV.E23 — Intro `Export tracks with genres into a flat folder structure. FFmpeg converts each track to **AAC 248 kbps (.m4a)**, ready to load into **Apple Create ML** for training a SoundClassifier model.` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1381-1384`.
    - ST-ADV.E24 — Cards `READY FOR EXPORT (≥ 50 tracks)` (Tracks / Genres) and `EXCLUDED (< 50 tracks)` (Tracks / Genres); `Target format:` `AAC 248kbps (.m4a)` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1386-1490`.
    - ST-ADV.E25 — Disclosure `Show excluded genres (‹n›)` → `These genres have fewer than 50 tracks and are excluded from training. Use Consolidate genres to merge them.` + horizontal chips genre + count — `MLM/Views/TrackDetail/GrooveStudioView.swift:1492-1554`.
    - ST-ADV.E26 — `TRAINING SET DESTINATION:` + `Choose destination…` → S-SET-EXPORTFOLDER; path or `No folder selected` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1556-1604`.
    - ST-ADV.E27 — `Start export` (disabled without destination) / while exporting: status text, linear progress, red `Cancel export` — `MLM/Views/TrackDetail/GrooveStudioView.swift:1606-1656`. Status texts: `Loading tracks from the library...`, `[‹n›/‹total›] Exporting tracks (‹pct›%)...`, `Exported ‹n› tracks into genre folders.`, `Export cancelled.`, `No tracks with genres found. At least 50 tracks per genre are required.`, `Export failed: …` (`MLM/Views/TrackDetail/GrooveStudioView.swift:1974-2163`). Also an Activity operation `CreateML Export: ‹folder›` (type `.createMLExport`). Uses Background processing (E01 of ST-MAINT) for worker count without saying so (`MLM/Views/TrackDetail/GrooveStudioView.swift:1970,2019-2020`). Per-track failures (missing file, transcode failure) only in logs; "Exported n" counts attempts, not successes.
- Interactions: click; double-click (rows); right-click → CM-TRACK; table multi-select + column sort; waveform click/drag seek and pinch zoom (`MLM/Views/TrackDetail/WaveformView.swift:93-140`); hover help on several buttons; hover effect on cards. No keyboard shortcuts (no spacebar preview, no Return/Escape handling except possibly table primary action, K-SET-GW-TABLE-RETURN). Leaving the tab stops both preview players (`MLM/Views/TrackDetail/GrooveStudioView.swift:151-154`).
- States: loading / empty per screen (above) · no library: repositories nil → genre grid shows the empty state `No genres in your library yet` (misleading) · offline drive: previews fail silently (logged); export copies nothing for missing files and still reports them as exported · errors: mostly `print()` only · huge data: a big genre loads all its tracks into the right column.
- Data scale: 12,935 tracks; genre distribution unknown; export requires ≥50 tracks per genre.
- Pain points: a full workspace (two columns + two waveform players) inside a 720×560 Settings window; tab label `Advanced` hides the feature; German strings E19 (`UI-GROUNDTRUTH.md` §1.7 rule 1); merge is destructive with no confirmation or undo (`UI-GROUNDTRUTH.md` §3.17 "every destructive action confirms"); back button drops staged edits silently; title-case `Songs`, all-caps section labels, custom colours (purple, gradients, `.white` on accent) vs. native look; "Double-click to preview" but double-click plays in main player; previews pause main playback; silent failures; borrowed Background processing not labelled (`UI-GROUNDTRUTH.md` §3.15 mandatory fix); Similar/"Groove" internal naming (`GrooveStudioView`) — user copy is fine.
- Related flows: edit-metadata (genre tagging), genre-cleanup *(area-specific: consolidate genres)*, ml-export *(area-specific: CreateML export)*, daily-listening (preview vs. main player interplay).
- Constraints: feature kept and re-homed in Settings → Advanced (`UI-GROUNDTRUTH.md` §2.2 line 270, §3.15); glossary `Genre Workshop`, never "Groove Studio"; English only; native look.
- Open questions for the designer:
  - Is Settings the right home for an interactive, audition-heavy workspace, or does it need its own window/sidebar destination?
  - How should staging vs. saving vs. merging communicate scope (database only, not file tags) and reversibility?
  - How should the two preview players relate to the main player (pause, resume, spacebar)?
  - What does the export need to report so the user trusts the training set (skipped/failed tracks)?

---

## Context menus

No new context menus are defined in this area.

- **CM-TRACK (owned by library.md) — placements in ST-ADV:**
  - ST-ADV.E11 suggestion rows: single track, built per row (`MLM/Views/TrackDetail/GrooveStudioView.swift:774-787`).
  - ST-ADV.E14 known-track rows: single track (`MLM/Views/TrackDetail/GrooveStudioView.swift:980-993`).
  - ST-ADV.E21 merger preview table: current multi-selection (`MLM/Views/TrackDetail/GrooveStudioView.swift:1290-1303`).
  - All three pass `availablePlaylists` (all playlists, loaded once on tab appear) and `availableSyncProfiles`; "add to sync profile" sets the Sync view model's selected profile, then adds the tracks (`MLM/Views/TrackDetail/GrooveStudioView.swift:780-785,1683-1691`) — a side effect on V-SYNC selection. Item list and rules: see CM-TRACK in the library.md draft.
- Expected, missing: right-click on a backup row (ST-BACKUP.E12: Restore… / Show in Finder), on a storage row (ST-STORAGE: Copy path / Show in Finder), on a genre card (ST-ADV.E04: Rename / Merge into…) *(inferred from macOS convention; no wish doc)*.

## Sheets, popovers, panels, alerts

### S-SET-LIBROOT — Select Music Library Folder (NSOpenPanel)
- Trigger: ST-LIB.E06 `Change...` / `Select Folder...` · Code: `MLM/Views/Settings/LibrarySetupView.swift:324-339`
- Content: title `Select Music Library Folder`, message `Choose the root folder of your music library`; folders only, single selection, can create folders; default button = system `Open`.
- Buttons: Open (default) → saves `app_config.library_root`, posts `.libraryRootDidChange`, row shows new path; Cancel → nothing.
- Error handling: save failure → ST-LIB.E15 `Failed to save library root: …`; with no library open the save is a silent no-op but the row still shows the path. No warning about existing tracks, no rescan prompt.

### S-SET-IMPORTFOLDER — Import Audio Files (NSOpenPanel)
- Trigger: ST-LIB.E12 `Import Folder...` · Code: `MLM/Views/Settings/LibrarySetupView.swift:349-365`
- Content: title `Import Audio Files`, message `Choose a folder to import audio files from`; folders only, single selection.
- Buttons: Open → `ImportViewModel.importFromDirectory` (Activity op `Import: ‹folder›`), progress in ST-LIB.E13; Cancel → nothing.
- Error handling: ST-LIB.E14/E15. Whether files outside the music folder are copied is undetermined ("Unresolved from code").

### S-SET-CACHEFOLDER — Choose transcode cache location (NSOpenPanel)
- Trigger: ST-MAINT.E02 `Change…` · Code: `MLM/Views/Settings/MaintenanceView.swift:860-871`, `MLM/App/DependencyContainer.swift:419-504`
- Content: title `Choose transcode cache location`, prompt button `Choose folder`; folders only.
- Buttons: `Choose folder` → **no confirmation**; background move of top-level `.m4a` files (copy then delete each original), Activity operation `Cache migration: ‹folder›` (type sync) with `Scanning existing cache...`, `[‹n›/‹total›] moved...`, `Moved ‹n› cache files.` or failure; then path saved to `app_config.transcode_cache_path`. Same folder → log only. Cancel → nothing.
- Error handling: Activity failure row; Activity offers Cancel but relocation keeps running (LOGIC-013). ST-MAINT path label doesn't refresh.

### S-SET-BACKUPFOLDER — Choose backup folder (NSOpenPanel)
- Trigger: ST-BACKUP.E05 `Change…` · Code: `MLM/Views/Settings/BackupSettingsView.swift:253-265`, `MLM/ViewModels/BackupSettingsViewModel.swift:124-139`
- Content: no title/message; starts in the current backup folder; prompt `Choose folder`; folders only; can create folders.
- Buttons: `Choose folder` → write-probe; OK → saved to `app_config.backup_destination`, list refreshes (old backups stay where they were, not listed); unwritable → ST-BACKUP.E03 `MLM can't write to the backup folder. Choose another folder.`; Cancel → nothing.

### S-SET-EXPORTFOLDER — CreateML destination (NSOpenPanel)
- Trigger: ST-ADV.E26 `Choose destination…` · Code: `MLM/Views/TrackDetail/GrooveStudioView.swift:1952-1962`
- Content: title `Choose a destination folder for the CreateML training set`, prompt `Choose folder`.
- Buttons: `Choose folder` → path shown, `Start export` enabled; Cancel → nothing. No check for free space or existing content (existing same-named files are replaced, `MLM/Views/TrackDetail/GrooveStudioView.swift:2064`).

### A-SET-DISCONNECT — Disconnect source
- Trigger: ST-SRC.E02 `Disconnect` · Code: `MLM/Views/Settings/SourcesSetupView.swift:85-98,153-163`
- Content: title `Disconnect ‹Source›?`; message `This removes the saved ‹Source› credentials from this Mac. Syncing will stop until you reconnect.`
- Buttons: `Disconnect` (destructive) → deletes keychain credentials (global, all libraries); `Cancel` (cancel) → clears pending. Escape = Cancel.
- Error handling: deletion failure only logged; row status re-reads keychain on next render.

### A-SET-RESTORE — Restore backup
- Trigger: ST-BACKUP.E13 `Restore…` · Code: `MLM/Views/Settings/BackupSettingsView.swift:71-85`, `MLM/ViewModels/BackupSettingsViewModel.swift:157-179`, `MLM/Services/Backup/BackupService.swift:274-336,344-376`
- Content: title `Restore backup from ‹date›?`; message `MLM first saves a copy of your current library, then replaces the library database and playlist covers with this backup and relaunches. Audio files are not changed. Finish active downloads and syncs first. To undo, restore the "Before restore" backup.`
- Buttons: `Restore and relaunch` (destructive) → tab shows `Restoring…` (all controls disabled) → validate bundle, safety backup (`Before restore`), stage, close DB, swap, `Relaunching…` → app quits and reopens (relaunch waits for the old process to exit); `Cancel` (cancel) → nothing.
- Error handling: failures before the DB closes → ST-BACKUP.E03 with plain message + Details, tab usable; failure after closing → A-SET-RESTOREFAILED. No guard against active downloads/syncs. Wrong-library bundle → generic message.

### A-SET-RESTOREFAILED — Restore didn't finish
- Trigger: restore swap failed after the DB was closed · Code: `MLM/Views/Settings/BackupSettingsView.swift:86-98`, `MLM/ViewModels/BackupSettingsViewModel.swift:35-36,170-185`
- Content: title `Restore didn't finish`; message `MLM couldn't replace the library files and needs to relaunch. If your library looks wrong afterwards, restore the "Before restore" backup.`
- Buttons: `Relaunch` (only button; cannot be dismissed) → relaunch.

### A-SET-PATHAPPLY — Update organized paths? (confirmation dialog)
- Trigger: ST-MAINT.E16 `Apply ‹n› unambiguous changes` · Code: `MLM/Views/Settings/MaintenanceView.swift:295-306,746-766`
- Content: title `Update organized paths?`; message `Finish all active downloads first and make sure no other process is modifying the library. Only organized paths confirmed unambiguously in the preview will be changed. An SQLite backup and JSON manifest are created outside the audio library first.`
- Buttons: `Confirm and apply` (destructive) → refuses if downloads active (`Path migration did not start: finish all downloads first.`), else applies, result line with manifest and backup paths, posts `.libraryDidImport`; `Cancel`.
- Error handling: `Path migration cancelled: ‹reason›` (e.g. `The database or disk inventory changed since preview. Run the audit again.`).

### A-SET-PATHROLLBACK — Roll back last path migration? (confirmation dialog)
- Trigger: ST-MAINT.E16 `Roll back last migration…` (always enabled when idle, even if nothing was applied) · Code: `MLM/Views/Settings/MaintenanceView.swift:307-318,768-783`
- Content: title `Roll back last path migration?`; message `The organized paths in the most recently applied manifest will be restored. Another SQLite backup is created before the rollback.`
- Buttons: `Confirm rollback` (destructive) → result `Rollback: ‹n› organized paths restored. Manifest: … · Backup: …`; `Cancel`.
- Error handling: `Rollback cancelled: No applied organized-path migration is available to roll back.` etc. No downloads guard on rollback.

Inline disclosures (not separate surfaces): `Details` (ST-BACKUP.E03), `Candidate report` (ST-MAINT.E16), `Show excluded genres (‹n›)` (ST-ADV.E25).

Missing, expected: confirmation for `Clear` Squid cookie (UI-014), for genre merge (ST-ADV.E20), for changing the music folder (S-SET-LIBROOT), for cache relocation (S-SET-CACHEFOLDER); a `Clear cache…` confirmation (`UI-GROUNDTRUTH.md` §3.15) — the action does not exist.

## Menu items & keyboard shortcuts (area-local)

- **M-APP `Settings…` ⌘,** (owned by shell.md) opens W-SETTINGS — `MLM/App/MLMApp.swift:81-90`. Opens on the last-used tab; no per-tab menu items or shortcuts.
- **K-SET-COOKIE-RETURN** — Return · label: none (text field submit) · scope: focused Squid cookie field in ST-SRC · action: same as `Save` (also saves an empty value = clears, bypassing the disabled `Save` button) · `MLM/Views/Settings/SourcesSetupView.swift:35,101-116` · conflicts: none.
- **K-SET-GW-TABLE-RETURN** *(inferred)* — Return / double-click · scope: merger preview table ST-ADV.E21 with selection · action: table primary action = play first selected track in the main player · `MLM/Views/TrackDetail/GrooveStudioView.swift:1303-1312` · conflicts with the header text `Double-click to preview`.
- Not present: tab-switch shortcuts (e.g. ⌘1…⌘7 inside Settings), spacebar preview in Genre Workshop, Escape to go back between Genre Workshop screens, ⌘S for `Save (‹n›)`.

## Drag & drop

No drag & drop is implemented anywhere in this area (no `onDrop`/`draggable`/`dropDestination` in the covered files).

Expected, missing (marked as such):
- **D-SET-FOLDER-TO-LIBROOT** (expected, missing) — Finder folder → ST-LIB.E06 to set the music folder, or → ST-LIB `Import` to import it *(inferred from macOS convention for folder pickers)*.
- **D-SET-GW-TRACK-TO-GENRE** (expected, missing) — track row (ST-ADV.E11/E14 or a V-LIB selection) → genre card / `Tracks in ‹genre›` column to tag it *(inferred)*.
- **D-SET-GW-TRACK-OUT** (expected, missing) — Genre Workshop rows → sidebar playlist (build-playlist flow; CM-TRACK is the only path today) *(inferred; daily-driver loop "native playlists" wish, MEMORY project_daily_driver_loop)*.
- **D-SET-FOLDER-TO-DESTINATION** (expected, missing) — Finder folder → backup folder row / transcode cache row / CreateML destination *(inferred)*.

---

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **No library open / library still loading** (container not initialised; V-LAUNCH-NOLIB in W-MAIN): Settings can still be opened.
  - ST-LIB: library file section hidden; `No library folder selected` + `Select Folder...` that pretends to save (`MLM/Views/Settings/LibrarySetupView.swift:300-309,333-337`).
  - ST-SRC: all sources `Disconnected` (tokenStorage nil), buttons inert — although credentials are global (A0 D3).
  - ST-MAINT: every `Run` silently does nothing; transcode cache shows `Default location (internal)`.
  - ST-BACKUP: `Backups are available once the library has loaded.` (`MLM/Views/Settings/BackupSettingsView.swift:16-25`); view model is created when the backup service appears (`.task(id:)`, line 27-32).
  - ST-STORAGE: `Storage locations are shown once the library has loaded.` (same pattern, `MLM/Views/Settings/DataLocationsView.swift:17-28`).
  - ST-PLAYBACK: fully works (UserDefaults).
  - ST-ADV: `No genres in your library yet` (misleading).
- **Drive not connected (music folder on `/Volumes/…`)**: only ST-STORAGE models it (`Not connected`, Show in Finder disabled, Calculate size disabled — `MLM/ViewModels/DataLocationsViewModel.swift:349-353,437-442`). ST-LIB shows the path as normal; Re-scan fails with raw `Library root does not exist: ‹path›`. ST-MAINT jobs count missing files as failed; path audit fails with `Library root does not exist or is not a directory.` ST-ADV previews/export fail silently. Transcode cache on the external disk (live value per ROADMAP §1.1) shows `Not connected` in ST-STORAGE only.
- **Library file on an unreachable disk**: handled at launch by shell.md (V-LAUNCH-CANTOPEN); Settings shows nothing of it.
- **Source disconnected / expired**: ST-SRC E01 text `Disconnected` / `Sign-in expired` / `Token inaccessible`; Squid cookie `Expired — renew` (flag set by downloader, live-updated via `.qobuzCookieStatusDidChange`).
- **Background processing**: ST-MAINT.E01 is the persisted setting used by analysis, transcode (sync) and CreateML export.
- **Track availability states**: not shown in Settings except ST-ADV rows (no availability chips; missing files only logged).

### Background work touchpoints

| Work | Started from | Progress shown | Result/error shown | User control |
|---|---|---|---|---|
| Re-scan / Import Folder | ST-LIB.E11/E12 | ST-LIB.E13 + P-ACTIVITY-OPS (`Rescan library` / `Import: ‹folder›`) | ST-LIB.E14/E15, Activity completion `‹n› imported, ‹n› skipped` | Cancel (ST-LIB + Activity); batch-save phase not cancellable (LOGIC-023) |
| Analysis & artwork jobs (6) + Rescan metadata | ST-MAINT.E07–E12, E15 | ST-MAINT.E13 only (not in Activity) | ST-MAINT.E18 shared line | Cancel (does not stop queued workers/tools, LOGIC-010); one job at a time |
| Organized-path audit / apply / rollback | ST-MAINT.E16 | small spinner only | ST-MAINT.E18 (with filesystem paths) | Confirmation dialogs; apply blocked while downloading |
| Transcode cache relocation | S-SET-CACHEFOLDER | P-ACTIVITY-OPS `Cache migration: ‹folder›` | Activity row; log | Activity Cancel shown but ineffective (LOGIC-013) |
| Liked playlist create/link | ST-MAINT.E17 | spinner | ST-MAINT.E18 | none |
| Manual backup | ST-BACKUP.E16 | `Backing up…` | `Backup created` / E03 | none (button disabled while running) |
| Launch backup (≤1/day) and pre-migration backup | app launch (`MLM/App/DependencyContainer.swift:321-331`, `MLM/Services/Backup/BackupService.swift:395-438`) | nowhere | log only; appears in ST-BACKUP list on next appear | none (not configurable) |
| Restore | A-SET-RESTORE | ST-BACKUP.E02 `Restoring…` / `Relaunching…` | E03 or A-SET-RESTOREFAILED; relaunch | none after confirm |
| Library folder size | ST-STORAGE.E08 | `Calculating…` | stored size / error | Cancel |
| Genre save / merge | ST-ADV.E07 / E20 | none | message / banner | none (no undo) |
| CreateML export | ST-ADV.E27 | ST-ADV.E27 + P-ACTIVITY-OPS `CreateML Export: ‹folder›` | status text; per-track failures only in Logs | `Cancel export`, `Back` cancels |

### Flow notes

- **backup-restore**
  1. ST-BACKUP (intent: "is my library safe?") → E08 `Last backup`, E12 list. Breaks: no health signal outside this tab; launch backup results only in logs.
  2. (optional) ST-BACKUP.E16 `Back up now` before a risky action → `Backup created`.
  3. Pick a row (intent: "the state from before X") — only date + reason + track count + size to identify it; no description of what changed.
  4. `Restore…` → A-SET-RESTORE (consequence stated; user must remember to stop downloads/syncs — not enforced).
  5. `Restore and relaunch` → `Restoring…` → `Relaunching…` → app quits/reopens. Breaks: with `Open the last library at launch` off, the relaunch lands on V-LAUNCH-NOLIB instead of the restored library *(inferred, see ST-BACKUP pain points)*; failure after DB close → A-SET-RESTOREFAILED (forced relaunch).
  6. Undo = restore the `Before restore` row.
- **settings-changes**
  1. Music folder: ST-LIB.E06 → S-SET-LIBROOT → saved immediately, notification to download pipeline / V-LIB / V-PLD. Breaks: no warning, no rescan offer, no reachability check.
  2. Sources sign-in: ST-SRC — can only disconnect / re-read keychain; actual sign-in elsewhere (V-SRC). YouTube row dead. `Open Settings` buttons in V-PLD/W-REMOTE land on the last tab, not Sources.
  3. Squid cookie: paste → `Save`/Return → `Active`. `Clear` is immediate.
  4. Transcode cache: ST-MAINT.E02 → S-SET-CACHEFOLDER → silent background move visible only in Activity; label doesn't update; no size or clear here (size only in ST-STORAGE.E09).
  5. Background processing: ST-MAINT.E01 → applies to next job/sync; also invalidates the selected sync profile's preview.
  6. Playback: ST-PLAYBACK steppers/toggle → next play/next track; no "takes effect" note.
  7. Backup folder: ST-BACKUP.E05 → write-probe → old backups no longer listed.
- **switch-library (Settings side)**
  1. ST-LIB.E01–E03: see name and path of the open library file, `Show in Finder`.
  2. ST-LIB.E04: decide launch behaviour (effect at next launch; off → V-LAUNCH-NOLIB).
  3. Actual switching/creating/opening is only in the File menu (M-FILE / A-LIB-SWITCH, shell.md); Settings has no entry point.
  4. After a switch (relaunch) all Settings tabs show the new library's data; ST-SRC/ST-PLAYBACK are global; ST-BACKUP lists only the new library's bundles; ST-STORAGE mixes per-library and global rows without saying which.
- **drive-unplugged**
  1. User opens Settings while `/Volumes/Lexxar` is unmounted.
  2. ST-STORAGE: `Library folder` and (custom) `Transcode cache` show `Not connected`, buttons disabled — the only correct offline UI in Settings.
  3. ST-LIB: same folder shown as normal; Re-scan → raw error string.
  4. ST-MAINT: jobs run and fail per file; cache `Change…` would try to move from an unmounted folder (failure in Activity).
  5. ST-BACKUP: custom folder on that disk not flagged.
  6. ST-ADV: previews do nothing, export silently skips files.
- **first-launch**: ST-LIB is an alternative to S-WIZARD for setting the music folder; with no library open it misleadingly appears to save ("Global-state touchpoints").
- **import-remote-playlist / fix-failed-downloads**: `Open Settings` from V-PLD/W-REMOTE (tool missing, e.g. yt-dlp) opens Settings, but no tab configures or even shows tools (yt-dlp, ffmpeg, fpcalc, scdl) — the user lands on the last tab with nothing to do.
- **review-duplicates**: ST-MAINT.E14 `Open Review` → V-REV in the main window; Settings window stays in front.
- **edit-metadata / genre-cleanup** (area-specific): ST-ADV grid → genre → set reference (double-click) → audition suggestions → thumbs up → `Save (n)`; merge: Consolidate → tick ≥2 → type name (German label) → `Merge selected genres` (instant, no undo). Breaks: Back discards staged edits silently; merges don't touch file tags.
- **analysis-batch** (area-specific): ST-MAINT → pick job → `Run` → progress in-row only → result in shared line → next job overwrites it. Breaks: invisible in Activity; Cancel unreliable; no "n tracks still missing".
- **ml-export** (area-specific): ST-ADV → Export → review Ready/Excluded → destination → `Start export` → progress here + Activity → `Exported n tracks…` (counts attempts).

### Unresolved from code

- Whether MaintenanceView's `@State` job state (running job, progress, result) survives switching tabs or closing/reopening the Settings window (window is kept, `isReleasedWhenClosed = false`; SwiftUI TabView tab lifetime on macOS not verifiable without running).
- Exact message when the custom backup folder is on an unmounted disk (listing/creation path through `BackupService.listBundles`/`writeBundle` not traced to the user-facing error).
- Whether `Import Folder...` on a folder outside the music folder copies files or records an organized path that doesn't exist on disk (`MLM/Services/Import/ImportService.swift:329,344` generates an organized path; no copy seen in the save loop) — needs IMPORT/LIBRARY confirmation.
- Whether the merger table's `primaryAction` fires on Return as well as double-click (macOS SwiftUI behaviour, K-SET-GW-TABLE-RETURN marked inferred).
- Whether ST-SRC rows refresh after a successful `Reconnect` (no state change is triggered; keychain read happens per render).
- Restore relaunch landing on V-LAUNCH-NOLIB is inferred from resolver logic; not run.
- Live values (current backup folder, cache path, sizes) were not read, per constraints.

