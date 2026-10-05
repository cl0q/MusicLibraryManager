# Sync — device/folder sync profiles, device playlist read-back, playlist picker

> Part of the [B1 UI inventory](../B1-UI-INVENTORY.md). IDs are stable; pain points for this area are in the index, [§11](../B1-UI-INVENTORY.md#11-known-pain-points--doc-vs-code-discrepancies); code-coverage mapping in [§12](../B1-UI-INVENTORY.md#12-coverage-proof).

> Area code(s): SYNC · Files covered: `MLM/Views/Sync/SyncView.swift`, `SyncProfileDetailView.swift`, `SyncContentSections.swift`, `SyncSettingsForm.swift`, `SyncFailedDisclosure.swift`, `SyncToast.swift`, `IngestPreviewView.swift`, `DeviceIngestResultsView.swift`, `Pickers/PlaylistPickerSheet.swift`, `Pickers/PlaylistPickerModel.swift`, `MLM/ViewModels/SyncViewModel.swift`; services read for user-visible behaviour: `MLM/Services/Sync/SyncService.swift`, `TranscodeCache.swift`, `DeviceDetector.swift`, `SyncTurboLevel.swift`, `PlaylistIngestService.swift`, `MLM/Database/SyncRepository.swift`, `MLM/Models/SyncProfile.swift`

**Orientation for the designer (what "sync" means in MLM today).** A *sync profile* is a named destination folder (`Output folder`) plus a selection of content (whole playlists and/or single tracks) plus export settings. Running a sync copies (or transcodes to AAC, then copies) every selected track that is not already on the destination, optionally deletes files that were removed from the selection, and optionally writes playlist files (`.m3u8`/`.m3u`) next to the music. There is no device database (no iTunes/iPod database); the destination is a plain folder, typically the root of a Rockbox-flashed iPod mounted under `/Volumes/…`, but any folder works (USB stick, local folder, a folder copied to a phone app). "Ingest" (`Read playlist changes from device…`) is the reverse direction **for playlists only**: MLM reads playlist files that exist on the destination, matches their entries to library tracks and rewrites MLM playlists to match. **No audio files are ever pulled from a device into the library.** (`MLM/ViewModels/SyncViewModel.swift:617-688`, `MLM/Services/Sync/PlaylistIngestService.swift:4-9`, `MLM/Services/Sync/PlaylistIngestService.swift:375-438`)

**Device types the code supports:**
- *Rockbox* — the only type that can be **detected**: `Detect device…` scans `/Volumes/*` for a `.rockbox` directory (`MLM/Services/Sync/DeviceDetector.swift:15-46`). Detection fills the output folder with the volume root and applies "device defaults".
- *Any folder* — any path typed or chosen with `Browse…`; treated as "connected" whenever the path exists (`MLM/ViewModels/SyncViewModel.swift:193-195`, `MLM/Services/Sync/SyncService.swift:332`).
- Playlist-file dialects (setting `Format & app`): `Rockbox` (`.m3u8` in the output root, absolute paths relative to the volume), `Doppi` (an iOS player app; writes `.m3u`, not `.m3u8`), `iOS` (MLM's own dialect: audio under `<output>/Music/`, playlists under `<output>/Playlists/`, plus an `mlm-library.json` manifest) (`MLM/Services/Sync/SyncService.swift:27-43`, `MLM/Services/Sync/SyncService.swift:1036-1071`, `MLM/Services/Sync/SyncService.swift:1163-1171`, `MLM/Services/Sync/SyncService.swift:888-890`).
- Not supported: stock iPod/iTunes database, MTP devices (explicit non-goal: `.planning/PROJECT.md:85`, `.planning/PROJECT.md:121`).

Sync profiles live in the library database, so each library (`.mlibm`) has its own profiles and its own "already synced" state (`MLM/Database/SyncRepository.swift:30-43`, `A0-LIBRARY-DEFINITION.md:38`).

## Surfaces

### V-SYNC — Sync (profile list)
- Reached via: sidebar item `Sync` (P-SIDEBAR; ⌘4 via M-NAVIGATE, `MLM/Views/ContentView/ContentView.swift:623`) · Leads to: V-SYNC-DETAIL (selection), S-SYNC-NEWPROFILE (`+`), CM-SYNC-PROFILE (right-click row) → S-SYNC-RENAME, A-SYNC-DELETEPROFILE, S-SYNC-DEVICEINGEST.
- Code: `MLM/Views/Sync/SyncView.swift:25-79` (root split), `MLM/Views/Sync/SyncView.swift:84-157` (list), `MLM/Views/Sync/SyncView.swift:342-376` (row), `MLM/ViewModels/SyncViewModel.swift:64-83`, `MLM/ViewModels/SyncViewModel.swift:188-206` (status text), host `MLM/Views/ContentView/ContentView.swift:373-374`.
- Purpose: see every place music gets synced to and whether each one is up to date, connected, or currently syncing.
- User goals:
  1. Check whether the iPod is up to date before leaving the house — weekly *(inferred from product facts: syncs to Rockbox/iPod)*.
  2. Pick the profile to work on (add content, sync) — weekly.
  3. Create a profile for a new device/folder — rare.
  4. Rename / duplicate / delete a profile — rare.
  5. Pull playlist edits made on the device back into MLM — rare (`Read playlist changes from device…`).
- What the user wants to see, in priority order:
  1. Profile name and whether its device is connected right now.
  2. Whether anything is pending / when it was last synced / that a sync is running with its count.
  3. The destination path (to tell two profiles pointing at different volumes apart).
- Elements today:
  - V-SYNC.E01 — header label `Sync Profiles` (`MLM/Views/Sync/SyncView.swift:86-89`).
  - V-SYNC.E02 — icon-only `+` button (SF `plus`, no tooltip, no accessibility label) → clears the VM error and opens S-SYNC-NEWPROFILE (`MLM/Views/Sync/SyncView.swift:90-96`).
  - V-SYNC.E03 — profile list, single selection, sidebar list style; width 200–280 pt (`MLM/Views/Sync/SyncView.swift:30-31`, `MLM/Views/Sync/SyncView.swift:123-149`).
  - V-SYNC.E04 — row line 1: profile name (`MLM/Views/Sync/SyncView.swift:363-364`).
  - V-SYNC.E05 — row line 2: output folder path, one line, middle-truncated (`MLM/Views/Sync/SyncView.swift:365-369`).
  - V-SYNC.E06 — row line 3: status label (icon + text, colour-coded) — one of `Syncing n/m` · `Device not connected` · `n track(s) pending` · `Synced <relative time>` (e.g. "Synced 2 hours ago", system RelativeDateTimeFormatter) · `No sync yet` (`MLM/ViewModels/SyncViewModel.swift:188-206`, `MLM/Views/Sync/SyncView.swift:346-359`, `MLM/Views/Sync/SyncView.swift:370-372`).
  - V-SYNC.E07 — empty state: icon + `No sync profiles` + `Create a profile to sync music to an external device` (no button; the only way in is E02) (`MLM/Views/Sync/SyncView.swift:107-121`).
  - V-SYNC.E08 — small spinner while profiles load and the list is empty (`MLM/Views/Sync/SyncView.swift:103-106`).
  - V-SYNC.E09 — whole-view `Loading...` while the sync view model does not exist yet (`MLM/Views/Sync/SyncView.swift:43-45`; VM created after library load in `MLM/App/DependencyContainer.swift:334-360`).
  - V-SYNC.E10 — right pane placeholder when nothing selected: icon + `Select a profile from the list` (`MLM/Views/Sync/SyncView.swift:165-175`).
  - V-SYNC.E11 — bottom toast overlay S-SYNC-TOAST (`MLM/Views/Sync/SyncView.swift:74-77`).
- Interactions: click row → selects, loads cached preview and content, starts preview refresh (`MLM/Views/Sync/SyncView.swift:150-153`, `MLM/ViewModels/SyncViewModel.swift:221-238`) · right-click → CM-SYNC-PROFILE · arrow keys move selection (system List behaviour) · no Delete-key binding · no double-click action · no drag & drop (see D-SYNC-*) · no hover tooltips on rows.
- States:
  - default: list + detail.
  - empty: V-SYNC.E07.
  - loading: E08 / E09. E09 has no timeout or error; if the VM is never created (repositories missing) it stays `Loading...` *(inferred from `MLM/App/DependencyContainer.swift:336-338`)*.
  - error: profile-load failure sets `errorMessage` (`MLM/ViewModels/SyncViewModel.swift:78-81`) but the list itself shows nothing; the message only appears inside V-SYNC-DETAIL.E25 once a profile is selected, or in S-SYNC-NEWPROFILE.
  - device not connected: per row, `Device not connected` with `externaldrive.badge.xmark` in attention colour; computed live with a file-exists check on the output folder each render (`MLM/ViewModels/SyncViewModel.swift:193-195`).
  - syncing: only the **currently selected** row shows `Syncing n/m` (`MLM/ViewModels/SyncViewModel.swift:190-192`); sidebar shows a mini spinner on `Sync` with tooltip `Sync in progress` (`MLM/Views/Sidebar/SidebarView.swift:145-153`).
  - pending: `n tracks pending` only for the selected profile and only when its preview is loaded (`MLM/ViewModels/SyncViewModel.swift:196-201`); other rows fall back to last-synced text even if they have pending changes.
  - filtered-empty: n/a (no search/filter).
  - huge data: profile count is small in practice; no scaling concern.
- Data scale: typically 1–5 profiles *(inferred)*; each profile can reference thousands of the 12,935 tracks.
- Pain points today:
  - Selection-dependent status: if the user selects another profile while profile A syncs, A's row loses `Syncing…` and the newly selected row shows A's progress (`MLM/ViewModels/SyncViewModel.swift:190-192`, `isSyncing` is VM-global `MLM/ViewModels/SyncViewModel.swift:18`).
  - `Synced …` time is not refreshed after a sync (executeSync never reloads profiles/timestamps) — it stays `No sync yet` / old time until something else reloads the list (`MLM/ViewModels/SyncViewModel.swift:379-400` vs `MLM/ViewModels/SyncViewModel.swift:69-72`).
  - "Last synced" = newest per-track sync timestamp; a sync that only removes files does not update it (`MLM/Database/SyncRepository.swift:121-135`).
  - Adding tracks/playlists to a profile from elsewhere (`Sync to ▸` in CM-TRACK / CM-PL-CARD / Inspector) silently switches this view's selected profile (`MLM/Views/Library/LibraryTable.swift:43-44`, `MLM/Views/Playlists/PlaylistsView.swift:613-614`).
  - No profile is auto-selected on first visit; the detail pane starts as a placeholder (`MLM/Views/Sync/SyncView.swift:163-175`).
  - `+` is icon-only without label/tooltip (`MLM/Views/Sync/SyncView.swift:90-96`).
  - Doc says rows show only name+folder and delete has no confirmation (UI-GROUNDTRUTH §3.7 line 638) — outdated; both now exist.
- Related flows: sync-device, drive-unplugged, device-ingest, switch-library.
- Constraints / locked decisions: native macOS look; critical states always text (status line is text + icon today); English only; glossary term "Sync profile" (UI-GROUNDTRUTH §1.5 line ~141).
- Open questions for the designer:
  - Should every row show its own pending count and connection state, independent of which profile is selected?
  - Where should "syncing" live when the syncing profile is not the selected one?
  - Should the list distinguish "device" destinations (removable volume) from plain folders?
  - What does a first-time visitor need beyond `No sync profiles` to understand what a profile is?

### V-SYNC-DETAIL — Sync profile detail
- Reached via: selecting a row in V-SYNC · Leads to: S-SYNC-PLAYLISTPICKER (`+` on Playlists card), A-SYNC-REMOVECONTENT (row trash / CM), P-INSPECTOR (failed track double-click / `Show Details`), Finder (`Show in Finder`), P-ACTIVITY-OPS (the same sync appears there).
- Code: `MLM/Views/Sync/SyncProfileDetailView.swift:45-113` (layout), `:118-174` (header), `:179-209` (preview status), `:212-359` (stats + file lists), `:362-400` (progress), `:405-431` (result); `MLM/Views/Sync/SyncSettingsForm.swift:37-235`; `MLM/Views/Sync/SyncContentSections.swift:40-352`; `MLM/Views/Sync/SyncFailedDisclosure.swift:18-238`; VM `MLM/ViewModels/SyncViewModel.swift:210-605`; service `MLM/Services/Sync/SyncService.swift:200-912`.
- Purpose: decide what goes onto a device and in what form, see the plan (what will be added/removed, size vs. free space) before anything happens, run the sync, and fix what failed.
- User goals:
  1. Sync the iPod with the latest changes — weekly *(inferred: product facts, PROJECT.md "syncs to Rockbox'd iPod")*.
  2. See exactly what will be copied/deleted and whether it fits — weekly.
  3. Add/remove playlists that go onto the device — weekly.
  4. See which tracks failed and why, retry one — after each sync with failures.
  5. Pause/cancel a long transcode-heavy sync (e.g. to free the CPU) — occasional.
  6. Change export settings (transcode, normalise, playlist format) — rare.
- What the user wants to see, in priority order:
  1. Can I sync now? (device connected, enough space, anything to do) and the reason if not.
  2. How much will change: n to add / n to remove, ≈ size, free space.
  3. During sync: n of m, current file, whether it is transcoding or copying, ability to pause/cancel.
  4. After sync: n synced / n failed, the failed tracks with plain reasons and a way to retry; also tracks that were *skipped* (today invisible).
  5. Which playlists/tracks are in the profile.
  6. Export settings (rarely changed).
- Elements today (visual order top → bottom; whole pane scrolls):
  - **Header**
    - V-SYNC-DETAIL.E01 — profile name, page title (`MLM/Views/Sync/SyncProfileDetailView.swift:123-125`).
    - V-SYNC-DETAIL.E02 — output folder path, one line middle-truncated; not editable anywhere in the UI (`MLM/Views/Sync/SyncProfileDetailView.swift:126-130`).
    - V-SYNC-DETAIL.E03 — small spinner while the preview recomputes (`MLM/Views/Sync/SyncProfileDetailView.swift:133-137`).
    - V-SYNC-DETAIL.E04 — `Refresh` (SF `arrow.clockwise`), ⌘R (K-SYNC-REFRESH), tooltip `Refresh the preview and profile content (Command-R)`; disabled while the preview updates; forces a full recompute ignoring the cache (`MLM/Views/Sync/SyncProfileDetailView.swift:138-145`, `MLM/ViewModels/SyncViewModel.swift:216-218`).
    - V-SYNC-DETAIL.E05 — `Sync now`, prominent/accent; disabled with a reason; tooltip = the reason or `Sync this profile to its destination` (`MLM/Views/Sync/SyncProfileDetailView.swift:147-153`).
    - V-SYNC-DETAIL.E06 — reason banner (info icon) shown whenever E05 is disabled. Reasons, verbatim, checked in this order: `Sync is already running` · `Preview is updating…` (only when no previous preview) · `Preview has not been loaded. Select Refresh to try again.` · `Device not connected — preview unchecked` · `Not enough space on device` · `No changes — everything is already synced` (`MLM/Views/Sync/SyncProfileDetailView.swift:29-41`, `:156-172`).
  - **Settings card** (collapsed by default; whole header row toggles; every change saves immediately, invalidates the preview and schedules a debounced 1 s recompute) (`MLM/Views/Sync/SyncSettingsForm.swift:40-68`, `MLM/ViewModels/SyncViewModel.swift:473-515`, `MLM/ViewModels/SyncViewModel.swift:241-261`)
    - V-SYNC-DETAIL.E07 — card header `Settings` + chevron.
    - V-SYNC-DETAIL.E08 — `Playlists` / `Create .m3u8 files for Rockbox or Doppi` — switch. Default **off** (manual create), **on** with device defaults (`MLM/Views/Sync/SyncSettingsForm.swift:77-87`, `MLM/Views/Sync/SyncView.swift:285`, `MLM/Models/SyncProfile.swift:40`).
    - V-SYNC-DETAIL.E09 — `Format & app` / `Choose the playlist format for the target app` — segmented `Rockbox` · `Doppi` · `iOS`; only visible while E08 is on; default `Rockbox` (`MLM/Views/Sync/SyncSettingsForm.swift:89-107`, `MLM/Models/SyncProfile.swift:44`). Note: the value still controls folder layout (`Music/` subfolder) and manifest writing for `iOS` even when E08 is off and E09 is hidden (`MLM/Services/Sync/SyncService.swift:27-32`, `:888-890`).
    - V-SYNC-DETAIL.E10 — `Transcode mode` / `Originals, AAC 248k, or AAC 320k` — segmented `Originals` · `AAC 248k` · `AAC 320k`. Default `Originals` (manual), `AAC 248k` (device defaults) (`MLM/Views/Sync/SyncSettingsForm.swift:111-126`, `MLM/Views/Sync/SyncView.swift:286`).
    - V-SYNC-DETAIL.E11 — `Normalize volume` / `−14 LUFS, AAC modes only` — switch, disabled in `Originals`; default off; only affects tracks with measured loudness, gain clamped −24…+12 dB (`MLM/Views/Sync/SyncSettingsForm.swift:130-141`, `MLM/Services/Sync/SyncService.swift:569-575`).
    - V-SYNC-DETAIL.E12 — `Artwork` / description `Resize cover art for low-RAM players` or, in Originals, `No effect in Originals mode` — segmented `Original` · `250 px`, disabled in Originals; default `Original` (manual), `250 px` (device defaults) (`MLM/Views/Sync/SyncSettingsForm.swift:145-162`, `MLM/Views/Sync/SyncView.swift:289`).
    - V-SYNC-DETAIL.E13 — `Compatible paths` / `Use FAT32-safe file paths` — switch, default on. **Has no effect today**: path sanitising is always applied; the flag is only part of the preview cache key (`MLM/Views/Sync/SyncSettingsForm.swift:166-176`, `MLM/Services/Sync/SyncService.swift:435`, `MLM/Services/Sync/TranscodeCache.swift:403-404`).
    - V-SYNC-DETAIL.E14 — `Clean up` / `Remove deleted tracks from the destination` — switch, default on; when on, files of tracks no longer in the profile are moved to Trash (or deleted outright on FAT32/exFAT, which has no Trash) (`MLM/Views/Sync/SyncSettingsForm.swift:180-190`, `MLM/Services/Sync/SyncService.swift:754-794`).
    - V-SYNC-DETAIL.E15 — `Background processing` / detail text per level: `Keeps the Mac responsive` (Conservative) · empty (Standard) · `Uses all cores, fans may spin up` (Fast) — segmented `Conservative` · `Standard` · `Fast`; default Standard (80 % of cores). **App-global**, not per profile; same setting as in ST-MAINT (`MLM/Views/Sync/SyncSettingsForm.swift:194-209`, `MLM/Services/Sync/SyncTurboLevel.swift:4-43`, `MLM/Services/Sync/SyncService.swift:149-156`, `MLM/Views/Settings/MaintenanceView.swift:33-49`).
    - No validation on any setting; no field for `playlist_path_prefix` (exists in the model, used for Rockbox paths when the output is not under `/Volumes/`) (`MLM/Models/SyncProfile.swift:35`, `MLM/Services/Sync/SyncService.swift:1048-1059`).
  - **Content cards** (both collapsed by default; whole header toggles) (`MLM/Views/Sync/SyncContentSections.swift:40-210`)
    - V-SYNC-DETAIL.E16 — `Playlists (N)` header + `+` (SF `plus.circle.fill`, tooltip `Add playlists…`) → S-SYNC-PLAYLISTPICKER + chevron (`MLM/Views/Sync/SyncContentSections.swift:43-95`).
    - V-SYNC-DETAIL.E17 — playlist rows: icon + name; on hover the icon becomes a red trash button → A-SYNC-REMOVECONTENT; right-click CM-SYNC-PLROW; empty text `No playlists — select the plus button to add playlists` (`MLM/Views/Sync/SyncContentSections.swift:99-119`, `:246-297`).
    - V-SYNC-DETAIL.E18 — `Tracks (N)` header (tooltip = hint) + chevron; **no add button** — single tracks are added only from other screens via `Sync to ▸` (CM-TRACK). Hint text verbatim: `Add individual tracks from the Library: right-click a track and choose Sync to ▸ your profile from the context menu.` (`MLM/Views/Sync/SyncContentSections.swift:15-16`, `:133-158`).
    - V-SYNC-DETAIL.E19 — track rows `Artist — Title`, hover trash, CM-SYNC-TRACKROW; empty text `No tracks — ` + hint (`MLM/Views/Sync/SyncContentSections.swift:178-199`, `:301-352`). N counts **only directly added tracks**, not tracks contributed by playlists.
  - **Preview**
    - V-SYNC-DETAIL.E20 — preview status line, one of: `Preview: updating… n/m` (spinner + `Cancel` button) · `Device not connected — preview unchecked` · `Preview: outdated — updating in background` · `Preview: up to date` + ` · computed just now` / ` · computed Nm ago` / ` · computed Nh ago` (`MLM/Views/Sync/SyncProfileDetailView.swift:179-209`, `:445-451`). `Cancel` stops the recompute and marks the preview outdated (`MLM/ViewModels/SyncViewModel.swift:264-271`).
    - V-SYNC-DETAIL.E21 — `Preview` label + four stat cards (only when the device is connected): `Add` (count; click toggles file list) · `Remove` (count; click toggles list) · `≈ <size>` / `New size` · `<free space>` / `Available` (green if enough, red if not) (`MLM/Views/Sync/SyncProfileDetailView.swift:212-258`). Sizes in decimal GB/MB/KB (`:435-443`). Size is estimated: Originals = real file size, AAC = bitrate × duration (default 240 s if unknown) (`MLM/Services/Sync/SyncService.swift:1330-1351`).
    - V-SYNC-DETAIL.E22 — expandable lists `Files to add` / `Files to remove`: per row `Artist – Title`, destination path (middle-truncated), size; right-click CM-SYNC-PREVIEWFILE (`MLM/Views/Sync/SyncProfileDetailView.swift:260-265`, `:317-359`). Remove rows always show 0-size *(they are never sized: `MLM/Services/Sync/SyncService.swift:294-302`)*.
    - V-SYNC-DETAIL.E23 — red banner `Not enough space on device — need ≈X, Y available` (`MLM/Views/Sync/SyncProfileDetailView.swift:267-283`). Rule: free space ≥ new size + 50 MB hidden buffer; space freed by removals is **not** credited (`MLM/Services/Sync/SyncService.swift:306-313`, `:171`).
  - **During sync**
    - V-SYNC-DETAIL.E24 — progress block: linear bar; `Syncing… n of m` or `Paused n of m`; current item line (`Transcoding: Artist – Title`, `Copying: …`, `Removing: …`, `Skipped: …`, `Failed: …`); buttons `Pause`/`Resume` and `Cancel`; note `Settings changes apply to the next sync.` when a setting was changed mid-run (`MLM/Views/Sync/SyncProfileDetailView.swift:362-400`, `MLM/Services/Sync/SyncService.swift:527-535`, `:555`, `:690`, `:791`). m = files to add + files to remove (`MLM/Services/Sync/SyncService.swift:729`).
  - **Errors and results**
    - V-SYNC-DETAIL.E25 — red error banner showing the VM's single `errorMessage` (any source: preview failure `Could not update the sync preview. Try Refresh.`, `Failed to add playlists: …`, `Failed to update profile settings: …`, `Could not rename sync profile.`, `Could not duplicate sync profile.`, `Retry failed: …`, raw sync errors e.g. `Insufficient space: need XMB, have YMB`) (`MLM/Views/Sync/SyncProfileDetailView.swift:80-96`, `MLM/ViewModels/SyncViewModel.swift:344`, `:417`, `:513`, `:166`, `:182`, `:582`, `:395`, `MLM/Services/Sync/TranscodeCache.swift:488-494`). No dismiss button; cleared only when a sync starts or `+` (new profile) is pressed (`MLM/ViewModels/SyncViewModel.swift:383`, `MLM/Views/Sync/SyncView.swift:91`).
    - V-SYNC-DETAIL.E26 — result line `N synced` (green check) and, if any, `· M failed` (red) (`MLM/Views/Sync/SyncProfileDetailView.swift:405-425`).
    - V-SYNC-DETAIL.E27 — `Failed tracks (M)` disclosure, collapsed by default; rows: warning icon, **title** + artist, red reason, `·` album; `Retry` button per row; hover highlight; double-click = open P-INSPECTOR for the track and play it if local; right-click CM-SYNC-FAILED (`MLM/Views/Sync/SyncFailedDisclosure.swift:18-137`, `MLM/Views/ContentView/ContentView.swift:172-191`). Reasons the user can see, verbatim: `Destination is full` · `Source file is missing` · `The destination is not writable` · `Could not sync this track` · `Transcode failed` · `Source file not found` · `No organized path for keepOriginals` · `Track metadata not found in database` · `Unknown transcode mode` (`MLM/Services/Sync/SyncService.swift:1353-1365`, `:531`, `:626`, `:630`, `:698`, `:702`).
- Interactions: click card headers to expand/collapse · hover content rows reveals trash · right-click → CM-SYNC-PLROW / CM-SYNC-TRACKROW / CM-SYNC-PREVIEWFILE / CM-SYNC-FAILED · ⌘R (K-SYNC-REFRESH) · double-click failed row → P-INSPECTOR + play · stat cards `Add`/`Remove` are buttons · mount/unmount of **any** volume triggers a connectivity re-check and, if changed, an immediate preview recompute (`MLM/Views/Sync/SyncProfileDetailView.swift:107-112`, `MLM/ViewModels/SyncViewModel.swift:274-281`) · no multi-select anywhere · no drag & drop.
- States:
  - default (connected, preview fresh): E20 `Preview: up to date · computed …`, E21 visible, E05 enabled if anything to do.
  - no changes: E05 disabled, E06 `No changes — everything is already synced`.
  - empty profile (no playlists/tracks): preview 0/0 → same as "no changes"; content cards show empty texts.
  - loading: first visit without cache → E20 `Preview: updating… n/m`, E06 `Preview is updating…`, no stat cards. With cache → cached numbers shown immediately, `Preview: outdated — updating in background` *(the outdated line shows only after a cancel/invalidation; during a refresh the "updating" line wins)* (`MLM/ViewModels/SyncViewModel.swift:284-300`, `:303-350`).
  - device not connected: E20 `Device not connected — preview unchecked`; stat cards hidden; E05 disabled with the same text (`MLM/Views/Sync/SyncProfileDetailView.swift:33-35`, `:71-73`, `:185-188`). "Connected" = output folder path exists; a mounted device whose chosen subfolder does not exist yet also counts as "not connected"; profiles created with an empty output folder are permanently "not connected" (`MLM/Views/Sync/SyncView.swift:277-303`).
  - mounted (device plugged in while viewing): automatic recompute via mount notification (above).
  - ejected mid-sync: **no dedicated state.** The sync keeps running; each remaining file fails with a generic or misleading reason (a missing destination folder surfaces as `Source file is missing` because the error text contains "no such file") (`MLM/Services/Sync/SyncService.swift:827-836`, `:1353-1364`); the unmount notification simultaneously starts a preview recompute. If `Playlists` is on, writing playlist files then throws, so the run ends with only a raw error in E25 and **no result line / failed list** (`MLM/Services/Sync/SyncService.swift:883-885`, `MLM/ViewModels/SyncViewModel.swift:394-396`) *(inferred from control flow; not run)*.
  - out of space (before sync): E21 `Available` red, E23 banner, E05 disabled `Not enough space on device`. Out of space mid-run (estimate too low): affected files fail with `Destination is full`.
  - transcoding in progress: E24 current line `Transcoding: …`; after each file completes the line switches to `Copying: …` even in AAC mode (`MLM/Services/Sync/SyncService.swift:534-535`, `:690`). Pause takes effect between files; an in-flight ffmpeg transcode is not interrupted *(inferred: `waitForSyncPermission` checkpoints `MLM/Services/Sync/SyncService.swift:505-517`)*.
  - paused: `Paused n of m`, button `Resume`.
  - cancelled: no "cancelled" text in this view — the result line shows only what synced; cancelled files count as skipped; playlist files and iOS manifest are **not** written (`MLM/Services/Sync/SyncService.swift:853-890`). Activity shows `Cancelled — x synced · y failed` (`MLM/Services/Sync/SyncService.swift:897-902`).
  - partial failure: E26 + E27.
  - skipped tracks (not downloaded / file missing / library drive offline): counted in `skippedCount` but **never shown**; they stay in the next preview as "Add" forever (`MLM/Services/Sync/SyncService.swift:550-557`, `:863-864`).
  - error: E25.
  - huge data: E22 and E19 are non-lazy stacks inside a scroll view; a first sync of thousands of tracks renders thousands of rows at once *(inferred performance risk)*; AAC previews probe every already-synced destination file with ffprobe (bounded by Background processing) — slow over USB 2 (`MLM/Services/Sync/SyncService.swift:366-420`).
- Data scale: a full-library profile could reference up to 12,935 tracks; playlists contribute tracks via `playlist_tracks`; preview progress `n/m` counts included + previously-synced tracks (`MLM/Services/Sync/SyncService.swift:107`).
- Pain points today:
  - `lastResult`, `errorMessage`, `isSyncing` are VM-global, not per profile: profile A's failed list and error banner stay visible after selecting profile B, and `Retry` there retries into B's destination (`MLM/ViewModels/SyncViewModel.swift:18-21`, `:559-562`).
  - Skipped tracks are invisible and perpetually "pending" (see States).
  - `Remove N` is shown and makes `Sync now` enabled even when `Clean up` is off, although nothing will be deleted (`MLM/Services/Sync/SyncService.swift:236`, `:761`).
  - Space check ignores space freed by removals and replacements (e.g. switching Originals → AAC re-adds every file) (`MLM/Services/Sync/SyncService.swift:306-313`).
  - `Compatible paths` toggle does nothing (E13).
  - Hidden `Format & app` still changes folder layout for `iOS` when `Playlists` is off (E09).
  - Doppi playlists are written as `.m3u` but described as `.m3u8`, and S-SYNC-DEVICEINGEST only finds `.m3u8` (`MLM/Services/Sync/SyncService.swift:1163`, `MLM/ViewModels/SyncViewModel.swift:646`, `:662`).
  - Output folder cannot be changed after creation (VM supports it, no UI: `MLM/ViewModels/SyncViewModel.swift:475`).
  - Single-track `Retry` has no busy state, can be clicked repeatedly, and does not rewrite playlist files, so a retried track is missing from device playlists until the next full sync (`MLM/Views/Sync/SyncFailedDisclosure.swift:118-122`, `MLM/Services/Sync/SyncService.swift:935-997`).
  - Activity's `Retry` for a failed sync calls the service directly; this view then shows no progress and no result (`MLM/Services/Sync/SyncService.swift:749`).
  - Raw technical strings reach E25 (`Insufficient space: need 4200MB, have 900MB`, OS error texts) — violates §1.7 rule 4.
  - Failed reasons like `No organized path for keepOriginals` and `Track metadata not found in database` are developer language.
  - Tracks card count/list excludes playlist-derived tracks; rule-based content (DB supports rules, no UI) would be invisible if any rules exist (`MLM/Database/TrackRepository.swift:917-946`, `MLM/Database/SyncRepository.swift:162-235`).
  - Stat card clip radius 8 vs stroke radius 10 (`MLM/Views/Sync/SyncProfileDetailView.swift:309-311`) — cosmetic remnant of UI-019.
- Related flows: sync-device, fix-failed-sync, drive-unplugged, settings-changes, build-playlist (adding playlists to a device), device-ingest.
- Constraints / locked decisions: native look; critical states as text; Background processing is one global setting (UI-GROUNDTRUTH §4.2 line 1018); sync must be visible + pausable + cancelable both in Activity and in the detail view (line 1019); rules engine "hide until designed" (line 690).
- Open questions for the designer:
  - How should "can't sync because …" be communicated — banner, disabled button tooltip, both?
  - Should skipped (not-downloaded/missing) tracks be a visible category next to Add/Remove/Failed?
  - Should settings that apply app-wide (Background processing) appear inside a per-profile form at all?
  - Should the preview be per profile and survive switching profiles, including the last result?
  - What does "Device disconnected mid-sync" look like, and is "resume" expected?
  - Should the output folder be editable, and how is a missing subfolder on a mounted device presented?
  - How much of the plan (file lists with thousands of rows) needs to be browsable vs. summarised?

### S-SYNC-DEVICEINGEST — Read Playlist Changes (device ingest results sheet)
- Reached via: CM-SYNC-PROFILE `Read playlist changes from device…` · Leads to: modified/created MLM playlists (V-PL / V-PLD); nothing navigates there automatically.
- Code: `MLM/Views/Sync/DeviceIngestResultsView.swift:16-187`, `MLM/Views/Sync/SyncView.swift:68-72`, `:138-142`, VM `MLM/ViewModels/SyncViewModel.swift:617-720`, service `MLM/Services/Sync/PlaylistIngestService.swift:41-459`.
- Purpose: take playlist edits made on the device (or in a phone app that edits the synced playlist files) and apply them to the matching MLM playlists.
- What "ingest" does (from code): scans the output folder for `.m3u8` files (iOS dialect: `<output>/Playlists/*.m3u8` then root `*.m3u8`; Rockbox/Doppi: every `.m3u8` anywhere below the output folder); for each file finds the target MLM playlist (special case `Liked.m3u8` → the "Liked" playlist; else by embedded playlist UUID; else by file name = playlist name; else **creates a new playlist**), resolves each entry to a library track (embedded track UUID, else filename-suffix match), diffs against the snapshot MLM wrote at the last iOS-dialect sync, and on `Apply` **replaces the MLM playlist's track list with the resolved device entries** (`MLM/ViewModels/SyncViewModel.swift:642-667`, `MLM/Services/Sync/PlaylistIngestService.swift:106-174`, `:228-296`, `:375-438`).
- User goals: 1. Bring a playlist reordered/edited on the iPod/phone back into MLM — rare. 2. Import a playlist created on the device as a new MLM playlist — rare.
- What the user wants to see: which device playlists changed; which MLM playlist each one will change (or create); what exactly is added/removed/reordered; which entries could not be matched and why; consequence for tracks that are in MLM but not on the device.
- Elements today:
  - E01 header icon `ipod` + title `Read Playlist Changes`; subtitle `From <profile name> — <output folder>` (`MLM/Views/Sync/DeviceIngestResultsView.swift:19-32`).
  - E02 states area (below).
  - E03 count line `N playlist(s) with changes` (`:95-98`).
  - E04 one card per changed file: file name (e.g. `Playlists/Road.m3u8`), target playlist name, `(new)` if it will be created, chips `+n` / `-n` / `↕ n` / `⚠ n` (icon + symbol text), `Apply` button (small, bordered) (`:121-187`).
  - E05 footer `Close` (clears results and dismisses) (`:46-52`).
- States: `Loading…` (VM missing, `:39`) · `Scanning device for playlist changes…` with spinner (`:60-68`) · error text in red: `Device not connected — output folder not found` / `Ingest service not available` / `Failed to apply <file>: <raw error>` (`MLM/ViewModels/SyncViewModel.swift:619`, `:630`, `:710`) · empty: green check `No playlist changes found` + `All playlists on the device match the last sync.` (`:78-90`) · list. Files that fail to parse are silently skipped (logged only) (`MLM/ViewModels/SyncViewModel.swift:678-683`). After a successful `Apply` the card disappears; there is no success message.
- Interactions: `Apply` per card (no confirmation, no detailed entry list — the detailed diff sheet S-SYNC-INGESTPREVIEW is **not** used here); `Close`; no Escape binding; scrolling list.
- Pain points:
  - An apply error replaces the whole list with the error text (error branch precedes the list), hiding the remaining unapplied files (`MLM/Views/Sync/DeviceIngestResultsView.swift:69-91`).
  - `Apply` has no busy/disabled state; double-click can apply twice *(inferred)*; LOGIC-007 index crash is fixed (removal by file name now, `MLM/ViewModels/SyncViewModel.swift:702-707`) but the list still uses positional identity (`MLM/Views/Sync/DeviceIngestResultsView.swift:100`).
  - For Rockbox/Doppi profiles no snapshot is ever written, so every non-empty device playlist always shows as "changes" with all entries as `+n` (`MLM/Services/Sync/SyncService.swift:1173-1190` iOS only; `MLM/Services/Sync/PlaylistIngestService.swift:233-251`).
  - Device playlists only contain tracks that were physically synced (`MLM/Services/Sync/SyncService.swift:1077-1080`, `:1138`); applying replaces the MLM playlist with those, so MLM playlist tracks that were never synced (e.g. `Not downloaded`) would be dropped *(inferred from code, high risk, unverified)*.
  - Removed entries display as title `Unknown` (`MLM/Services/Sync/PlaylistIngestService.swift:260-266`).
  - Unresolved reasons are technical: `No track with mlm_uuid=<uuid> and filename fallback failed`, `No track matched filename: <path>` (`MLM/Services/Sync/PlaylistIngestService.swift:126-131`).
  - Doppi `.m3u` files are never found.
  - Rockbox recursive scan may pick up unrelated `.m3u8` files anywhere on the device (e.g. Rockbox's own) *(inferred)*.
- Related flows: device-ingest.
- Open questions for the designer: Should users see the entry-level diff before applying? How is "this will create a new playlist" vs "this overwrites playlist X" made unmistakable? Should applying be undoable? What happens to MLM-only tracks in an overwritten playlist?

## Context menus

### CM-SYNC-PROFILE — profile row
- Where: V-SYNC.E03 rows · Code: `MLM/Views/Sync/SyncView.swift:129-147`
- Items in order (all always enabled, single profile only):
  1. `Rename…` → S-SYNC-RENAME (prefilled with current name).
  2. `Duplicate` → immediately creates `<name> copy` (then `copy 2`, …) with the same output folder, settings (except Artwork — not copied, resets to `Original`) and content; selects the copy (`MLM/ViewModels/SyncViewModel.swift:172-185`, `MLM/Database/SyncRepository.swift:63-117`). Error → E25 `Could not duplicate sync profile.`
  3. `Read playlist changes from device…` → opens S-SYNC-DEVICEINGEST and starts the scan.
  4. `Delete…` (destructive) → A-SYNC-DELETEPROFILE.
- No separators. Right-clicking a row does not select it, so the detail pane may show another profile.

### CM-SYNC-PLROW — playlist row in profile
- Where: V-SYNC-DETAIL.E17 · Code: `MLM/Views/Sync/SyncContentSections.swift:290-296`
- Item: `Remove from profile` (destructive, SF `minus.circle`) → A-SYNC-REMOVECONTENT.

### CM-SYNC-TRACKROW — track row in profile
- Where: V-SYNC-DETAIL.E19 · Code: `MLM/Views/Sync/SyncContentSections.swift:345-351`
- Item: `Remove from profile` (destructive) → A-SYNC-REMOVECONTENT. No Play / Show in Library / Show Details here.

### CM-SYNC-PREVIEWFILE — file in preview list
- Where: V-SYNC-DETAIL.E22 (both Add and Remove lists) · Code: `MLM/Views/Sync/SyncProfileDetailView.swift:345-349`
- Item: `Show in Finder` → reveals the **destination** path; for files still to be added the path does not exist yet, so the action has no visible effect *(inferred)*. The planned `Exclude from sync` (UI-GROUNDTRUTH §3.8 line 683) does not exist.

### CM-SYNC-FAILED — failed track row
- Where: V-SYNC-DETAIL.E27 · Code: `MLM/Views/Sync/SyncFailedDisclosure.swift:134-188`
- Items in order:
  1. `Play` (SF `play.fill`) — disabled until the track record is loaded or if the track is not local; opens P-INSPECTOR and plays (`:143-148`, `:192-198`).
  2. `Play Next` — disabled if track not loaded; inserts after current in queue (`:150-157`).
  3. — separator —
  4. `Show Details` — opens P-INSPECTOR without playing (`:161-165`).
  5. `Retry Sync` — same as row `Retry` (`:167-171`).
  6. — separator —
  7. `Show in Finder` — reveals the **library source** file (organized path under library root, else original path); silently does nothing if not found (`:175-180`, `:200-222`).
  8. `Copy File Path` — copies the resolved source path, quoted if it contains spaces; silent if unresolved (`:182-187`, `:227-238`).

## Sheets, popovers, panels, alerts

### S-SYNC-NEWPROFILE — New Sync Profile sheet
- Trigger: V-SYNC.E02 `+` · Code: `MLM/Views/Sync/SyncView.swift:180-308` (width 420)
- Content: title `New Sync Profile`; `Name` text field; `Output folder` text field (free text) + `Browse…` → S-SYNC-OPENPANEL; `Detect device…` (prominent) → after running: `No devices found — is it connected?` or one button per detected Rockbox volume showing icon, volume name, mount path and a checkmark when chosen. Choosing a device sets output folder = volume root, sets name to `<Volume name> iPod` if empty, arms "device defaults" and shows S-SYNC-TOAST (`:204-256`). Inline red error text from the VM (`:258-263`).
- Buttons: `Cancel` (Escape, disabled while creating) · `Create` (Return; disabled when name empty or creating).
- Consequence of Create: creates profile; applies defaults — manual: Playlists off, Originals, Artwork Original; device defaults: Playlists on, AAC 248k, Artwork 250 px; both: Compatible paths on, Clean up on, Format Rockbox, Normalize off (`:277-301`, `MLM/Models/SyncProfile.swift:40-52`); selects the new profile and starts its preview (`MLM/ViewModels/SyncViewModel.swift:114-118`). Sheet closes only on success; fields reset.
- Validation/errors: name required (non-empty, untrimmed check); **output folder not required** — an empty or non-existent path is accepted; duplicate name → `A sync profile with this name already exists.`; other errors raw (`MLM/ViewModels/SyncViewModel.swift:119-126`). Device defaults stay armed even if the user afterwards edits the folder by hand *(inferred)*.
- Related but owned elsewhere: a second create sheet `NewSyncProfileFromSelectionSheet` (from CM-TRACK `Sync to ▸` › `Create new profile…`) with different copy (`For example, Walkman or USB drive`, `No folder selected`, `Browse...`, button `Add n tracks`), requires an output folder, has no device detection and applies no device defaults (`MLM/Views/Shared/SelectionCreationSheets.swift:143-207`, `:249`).

### S-SYNC-OPENPANEL — Output folder chooser (file dialog)
- Trigger: `Browse…` in S-SYNC-NEWPROFILE · Code: `MLM/Views/Sync/SyncView.swift:191-201`
- System NSOpenPanel: directories only, single selection, can create folders, prompt button `Choose`. OK → fills `Output folder` with the path; Cancel → no change. Runs app-modal on top of the sheet.

### S-SYNC-RENAME — Rename sync profile sheet
- Trigger: CM-SYNC-PROFILE `Rename…` · Code: `MLM/Views/Sync/SyncView.swift:310-336` (width 360)
- Content: title `Rename sync profile`; `Name` field prefilled.
- Buttons: `Cancel` (Escape) · `Rename` (Return; disabled when trimmed name empty).
- Consequence: saves trimmed name; sheet closes immediately; failure (e.g. duplicate name) → E25 `Could not rename sync profile.` in the detail pane, not in the sheet (`MLM/ViewModels/SyncViewModel.swift:154-169`).

### S-SYNC-PLAYLISTPICKER — Add playlists to profile sheet
- Trigger: V-SYNC-DETAIL.E16 `+` · Code: `MLM/Views/Sync/Pickers/PlaylistPickerSheet.swift:27-199`, model `MLM/Views/Sync/Pickers/PlaylistPickerModel.swift:7-65` (400×500)
- Content: title `Add playlists to profile`; search field `Search playlist names...` (auto-focused; clear button; case-insensitive name contains); list of all playlists: tap toggles a selection circle; playlists already in the profile show a muted check + badge `In profile` and cannot be toggled.
- States: `Loading playlists...` · error `Could not load playlists` + `Playlists are unavailable. Try again after the library finishes loading.` or `Playlists could not be loaded. Try again.` + `Retry` · empty `No playlists` / `Create one first, then add it to this sync profile.` · no matches: system search-empty view (`:108-139`, `:175-199`).
- Buttons: `Cancel` (no Escape binding) · `Add` / `Add (n)` (Return; disabled with nothing selected).
- Consequence: adds playlists to the **currently selected** profile, reloads content, schedules preview, posts `syncProfileDidChange`; dismisses after the await; failure → E25 `Failed to add playlists: …` (`MLM/ViewModels/SyncViewModel.swift:405-419`). No multi-select via keyboard/shift; no playlist covers/track counts shown.

### S-SYNC-INGESTPREVIEW — Import Playlist (m3u diff preview sheet)
- Trigger: owned by playlists.md — V-PLD m3u/m3u8 file import (`MLM/Views/Playlists/PlaylistDetailView.swift:134-176`, triggers at `:533`, `:678`). **Not** used by S-SYNC-DEVICEINGEST.
- Code: `MLM/Views/Sync/IngestPreviewView.swift:11-255` (480–560 × 400–640)
- Content: header `Import Playlist` + `From <file name>`; target card: playlist name + `Will create new playlist` or `Existing playlist`; summary `n Added` · `n Removed` · `n Reordered` (+ `n Unresolved`); collapsible lists `Added (n)` / `Removed (n)` / `Reordered (n)` (title — artist, path); `Unresolved (n)` warning box with path + reason; inline red apply error.
- Buttons: `Cancel` (disabled while applying; no Escape binding) · `Create & Import` (if new) or `Apply` (disabled while applying or when nothing to do); spinner while applying.
- Consequence (from caller): applies with sentinel profile −1 (no snapshot → all resolved entries count as "added"), then alert `Import Complete` / `Imported n tracks` (`MLM/Views/Playlists/PlaylistDetailView.swift:153-160`, `:188-197`).

### S-SYNC-TOAST — "device defaults" toast
- Trigger: choosing a detected device in S-SYNC-NEWPROFILE · Code: `MLM/Views/Sync/SyncToast.swift:10-38`, `MLM/Views/Sync/SyncView.swift:74-77`, `:227-228`
- Content: green bar + check + `Rockbox device detected — device defaults applied`; bottom of the Sync view; auto-hides after 3 s; not interactive.
- Issues: drawn in the main window **behind** the still-open modal sheet; says "applied" although defaults only apply on `Create` (and not at all on Cancel); does not say which defaults.

### A-SYNC-DELETEPROFILE — Delete sync profile?
- Trigger: CM-SYNC-PROFILE `Delete…` · Code: `MLM/Views/Sync/SyncView.swift:50-64`
- Title `Delete sync profile?`; message `Delete "<name>"? This removes the sync profile but does not delete any music files.`
- Buttons: `Cancel` (cancel) · `Delete` (destructive).
- Consequence: deletes profile, its content links, rules, sync state and playlist snapshots; files on the device stay (`MLM/Database/SyncRepository.swift:48-57`); clears selection if it was selected. Not blocked while that profile is syncing. Error → E25 raw text.

### A-SYNC-REMOVECONTENT — Remove from profile?
- Trigger: hover trash or CM-SYNC-PLROW / CM-SYNC-TRACKROW · Code: `MLM/Views/Sync/SyncContentSections.swift:214-241`
- Title `Remove from profile?`; message `“<playlist name | Artist — Title>” will no longer sync to <profile>'s destination. This does not delete the library original. If enabled, destination cleanup happens on the next sync.`
- Buttons: `Remove` (destructive, listed first) · `Cancel`.
- Consequence: removes the link; preview recomputed; on next sync files are trashed only if `Clean up` is on. Error → E25 `Failed to remove playlists: …` / `Failed to remove tracks: …`. (Resolves audit UI-003.)

## Menu items & keyboard shortcuts (area-local)

- **K-SYNC-REFRESH** — ⌘R · `Refresh` · scope: only while V-SYNC-DETAIL is on screen · forces preview + content recompute · `MLM/Views/Sync/SyncProfileDetailView.swift:144` · same combo is used by LibraryView's own ⌘R while V-LIB is on screen (`MLM/Views/Library/LibraryView.swift:128`) — no live conflict because the views are never shown together, but one key has two meanings.
- **K-SYNC-NEWPROFILE-KEYS** — Escape = `Cancel`, Return = `Create` in S-SYNC-NEWPROFILE · `MLM/Views/Sync/SyncView.swift:272`, `:302`.
- **K-SYNC-RENAME-KEYS** — Escape = `Cancel`, Return = `Rename` in S-SYNC-RENAME · `MLM/Views/Sync/SyncView.swift:321`, `:330`.
- **K-SYNC-PICKER-RETURN** — Return = `Add (n)` in S-SYNC-PLAYLISTPICKER (no Escape binding for Cancel) · `MLM/Views/Sync/Pickers/PlaylistPickerSheet.swift:90`.
- Navigation ⌘4 to Sync belongs to M-NAVIGATE (shell.md) · `MLM/Views/ContentView/ContentView.swift:623`.
- Missing: no shortcut for `Sync now`, no menu-bar command for sync/new profile, no Escape in S-SYNC-DEVICEINGEST / S-SYNC-INGESTPREVIEW, no Delete-key on profiles or content rows.

## Drag & drop

No drag source or drop target exists in any Sync file.

Expected, missing:
- **D-SYNC-PLAYLIST-TO-PROFILE** (expected, missing) — drag playlists from V-PL / sidebar pins onto a profile row or the Playlists card. Today: `+` picker or `Sync to ▸` submenu on playlist cards (`MLM/Views/Playlists/PlaylistCard.swift:320-344`).
- **D-SYNC-TRACKS-TO-PROFILE** (expected, missing) — drag tracks from V-LIB / V-PLD / V-FOLD onto a profile. Today only CM-TRACK `Sync to ▸` (`MLM/Views/Library/TrackContextMenu.swift:122-156`); the Tracks card itself has no add path (wish: multi-select bulk actions, `.planning/research/v1.4-daily-driver/FEATURES.md:151`).
- **D-SYNC-FOLDER-TO-OUTPUT** (expected, missing) — drop a Finder folder or mounted volume onto `Output folder`.
- **D-SYNC-REORDER-PROFILES** (expected, missing) — reorder profiles in V-SYNC (list order is DB order).

## Area notes

Condensed into the index §8–§10; kept here at full detail.

### Global-state touchpoints

- **Target device not connected**: row text `Device not connected` (V-SYNC.E06); detail `Device not connected — preview unchecked` + disabled `Sync now`; ingest `Device not connected — output folder not found`. Defined purely as "output folder path exists" (`MLM/ViewModels/SyncViewModel.swift:193-195`, `MLM/Views/Sync/SyncProfileDetailView.swift:33-35`, `MLM/ViewModels/SyncViewModel.swift:629-633`). Auto-refresh on any volume mount/unmount while the detail is visible (`MLM/Views/Sync/SyncProfileDetailView.swift:107-112`).
- **Library drive not connected** (source audio on `/Volumes/Lexxar`): **nothing in the Sync area says so.** Preview still lists files to add (destination-based); running the sync skips every track whose source is missing (`Skipped:` flashes in the current-file line), result `0 synced` with no failures; tracks remain pending forever (`MLM/Services/Sync/SyncService.swift:537-557`). Even tracks already in the transcode cache are skipped because the source check runs first. The live transcode cache also lives on the library drive (ROADMAP.md:96). The sidebar shows a library-drive indicator owned by main.md (`MLM/Views/Sidebar/SidebarView.swift:140-142` area).
- **Library loading/failed**: V-SYNC.E09 `Loading...` until the VM exists; S-SYNC-PLAYLISTPICKER `Playlists are unavailable. Try again after the library finishes loading.`
- **Track availability**: `Not downloaded` / `File missing` tracks inside synced playlists are silently skipped (see above); failed-row `Play` is disabled for non-local tracks (`MLM/Views/Sync/SyncFailedDisclosure.swift:148`). No availability vocabulary (§1.6) is used in Sync.
- **Source disconnected/expired**: not relevant to Sync; not shown.
- **Background processing**: E15 mirrors the global setting (also ST-MAINT); preview computation registers with the performance queue (pauses lower-priority analysis) (`MLM/ViewModels/SyncViewModel.swift:314-319`).
- **Switch library**: profiles and sync state are per library; switching relaunches (A-LIB-SWITCH copy asks to finish syncs first, UI-GROUNDTRUTH line 991); a running sync would be killed *(inferred)*.

### Background work touchpoints

- **Sync run**: progress inline (V-SYNC-DETAIL.E24), sidebar mini spinner (`MLM/Views/Sidebar/SidebarView.swift:145-153`), Activity Operations row `Sync: <profile>` with `n / m — <current file>`, Pause/Resume and Cancel (`MLM/Services/Sync/SyncService.swift:744-751`, `:477-490`, `MLM/Views/Activity/ActivityFeed.swift:504-537`, `MLM/Views/Activity/OperationsTab.swift:299-305`, `:336-340`). Final Activity state: completed `x synced · y failed`, failed (only failures), or `Cancelled — …` (`MLM/Services/Sync/SyncService.swift:896-909`). Activity `Retry` re-runs the service directly (bypasses the VM, so V-SYNC-DETAIL shows nothing) (`:749`). The `syncDidComplete` notification is declared but never posted (`MLM/Utilities/Notifications.swift:73`).
- **Transcoding**: happens inside the sync, per file, into the transcode cache (separate cache entries per bitrate, normalisation, artwork size: `MLM/Services/Sync/TranscodeCache.swift:47-52`, `:141-143`); user control = Pause/Cancel of the whole sync, Background processing level. No pre-warming exists (UI-GROUNDTRUTH §4.1 line 1011 is a plan). Cache location/size are in ST-MAINT / ST-STORAGE (`MLM/Views/Settings/MaintenanceView.swift:51-84`).
- **Preview computation**: per profile, cached in memory (lost on relaunch), recomputed on selection, content/settings change (1 s debounce), mount/unmount, after sync; progress `Preview: updating… n/m` with `Cancel` (V-SYNC-DETAIL.E20) (`MLM/ViewModels/SyncViewModel.swift:241-261`, `MLM/Services/Sync/SyncService.swift:200-324`).
- **Device scan (ingest)**: only inside S-SYNC-DEVICEINGEST; not in Activity; not cancellable.
- **Single-track retry**: no progress anywhere, not in Activity.

### Flow notes

**sync-device**
1. V-SYNC — pick the iPod profile (intent: "is it ready?"). Row says `Device not connected` until plugged in.
2. Plug in → V-SYNC-DETAIL recomputes automatically (mount notification) → E20 `Preview: updating… n/m`.
3. Read E21 (Add/Remove/size/free); optionally expand E22 to check what goes on. Breaks: Remove shown even with Clean up off; space check may block a net-neutral swap; not-downloaded tracks inflate "Add" and never go away.
4. `Sync now` (E05) → E24 progress, Pause/Cancel; same row in Activity.
5. Result E26/E27. Breaks: skipped tracks invisible; cancelled runs not labelled in-view and leave device playlists stale; result belongs to the VM, not the profile.
6. Eject the device in Finder (no eject action in MLM).
**fix-failed-sync** (area-specific)
1. Expand E27 `Failed tracks (n)`, read reason. 2. `Retry` per row or CM-SYNC-FAILED `Retry Sync`; or `Show in Finder` / `Show Details` to investigate the source. Breaks: no "Retry all"; retry has no feedback while running and doesn't update device playlists; reasons partly developer jargon or misleading (`Source file is missing` for a missing destination).
**drive-unplugged**
- *Target device unplugged before*: clear text states ("Global-state touchpoints"). *Ejected mid-sync*: no detection; remaining files fail one by one; with Playlists on, the run ends in a raw error with no failure list (see V-SYNC-DETAIL states). *Library drive unplugged*: nothing warns; sync "succeeds" with `0 synced`; also transcode cache unavailable (lives on that drive).
**settings-changes**
1. Expand Settings (E07), change e.g. `Transcode mode` → saves instantly, preview marked outdated and recomputed after 1 s. 2. Switching Originals ↔ AAC changes every destination file extension → all tracks re-added, old files cleaned per file; space check counts full new size. 3. Changing during a sync shows `Settings changes apply to the next sync.` 4. Background processing here changes the app-wide level (same as ST-MAINT). 5. Transcode cache location is changed in ST-MAINT, not here; each bitrate/normalise/artwork combination creates its own cache files, invisible from Sync. Breaks: `Compatible paths` is a no-op; `Format & app` hidden but active.
**device-ingest**
1. V-SYNC right-click profile → `Read playlist changes from device…` (CM-SYNC-PROFILE). 2. S-SYNC-DEVICEINGEST scans, lists changed playlist files with counts. 3. `Apply` per file → MLM playlist overwritten/created; card disappears. 4. `Close`. Breaks: no entry-level preview here, no undo, no success feedback; Rockbox/Doppi always show "changes"; Doppi `.m3u` never found; possible loss of MLM-only tracks; an apply error hides the rest. Wish: Rockbox m3u8 path remap `/<HDD0>/` (paused Phase 24, `.planning/REQUIREMENTS.md:112`, `:142`).
**build-playlist** (sync side)
1. From V-PL card or CM-TRACK `Sync to ▸ <profile>` or V-SYNC-DETAIL.E16 `+` → S-SYNC-PLAYLISTPICKER. 2. Content appears in E16/E18; preview recomputes. Breaks: `Sync to ▸` switches Sync's selected profile; `Create new profile… (Settings)` / `Create New Profile…` in those submenus post `navigateToCreateSyncProfile`, which nothing observes — dead items (`MLM/Views/Library/TrackContextMenu.swift:148-152`, `MLM/Views/Playlists/PlaylistCard.swift:336-340`, `MLM/Utilities/Notifications.swift:132`).
**switch-library**: profiles are per library file; a sync must finish before switching (relaunch).

### Unresolved from code

- Whether any `sync_profile_rules` rows exist in the live library (rules affect profile content with no UI); not checked — live data is off-limits.
- Exact on-device effect of writing into `/Volumes/<name>/…` after the volume is ejected (whether `createDirectory` fails with a permission error or creates a stray folder on the boot disk) — depends on `/Volumes` permissions at runtime; not run.
- Whether the toast is visible at all behind the create sheet depends on window size/rendering; not run.
- Whether playlist files on the device are removed when a playlist is removed from the profile — no cleanup code for `.m3u8` files was found in the sync path; not confirmed by running.
- Escape-key behaviour of SwiftUI sheets without a `.cancelAction` button on macOS 15 — not verified at runtime.
- Real duration of preview recompute (ffprobe over USB) for large profiles — no measurement possible without running.
- Whether `Doppi` and `iOS` dialects are used by Oliver at all (only Rockbox is evidenced in planning docs).

