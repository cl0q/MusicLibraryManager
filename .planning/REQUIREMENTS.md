# Requirements: MusicLibraryManager

**Defined:** 2026-02-05
**Core Value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality

## v1.1 Requirements

Requirements for milestone v1.1: Library Foundation & UX Polish.

### Library Configuration

- [x] **LCFG-01**: User can configure a directory as the library location
- [x] **LCFG-02**: App detects when library drive is not connected
- [x] **LCFG-03**: App blocks Library tab when drive not connected (shows message)
- [x] **LCFG-04**: App allows Remote tab access when library drive not connected

### Remote Staging

- [ ] **REM-01**: Remote appears as sidebar item
- [ ] **REM-02**: Remote view shows only songs from streaming services not yet downloaded
- [ ] **REM-03**: Remote syncs with connected streaming services on startup
- [ ] **REM-04**: Downloaded songs are removed from Remote view

### Library View

- [ ] **LVIEW-01**: Library view shows only songs that exist locally on disk
- [ ] **LVIEW-02**: Format column shows audio format (FLAC, AAC, MP3) not source name
- [ ] **LVIEW-03**: All columns show correct metadata from local files

### Track Actions

- [ ] **ACT-01**: More Info shows real file data (fingerprint, waveform, spectrogram, ffprobe output)
- [ ] **ACT-02**: Add to playlist works for local tracks
- [ ] **ACT-03**: Add to sync profile works for local tracks
- [ ] **ACT-04**: Open in file manager works for local tracks

### Download Flow

- [ ] **DL-01**: User can download a single song from Remote
- [ ] **DL-02**: User can download multiple songs in batch from Remote
- [ ] **DL-03**: Downloaded song moves from Remote to Library

### UX Polish

- [ ] **UX-01**: Context menu appears immediately on right-click (no delay)

## v1.2 Requirements — Solar Design System & Loudness

Source of truth: `.planning/research/solar-design/CONTRACT.md` — locks scope cuts, formulas, and gray-area decisions that this milestone's phases must honor.

### Solar Theme Foundation

- [ ] **THEME-01**: Solar — Pro Audio Light palette available as a theme token set (`[data-theme="solar"]`) across all UI
- [ ] **THEME-02**: IBM Plex Sans, Mono, and Serif fonts bundled locally and loaded via `@font-face`
- [ ] **THEME-03**: Theme picker in Settings offers Solar, Solarized Dark, and Solarized Light (Solar is new-install default; existing user theme preference preserved)
- [ ] **THEME-04**: Global density tokens (`--row-h: 36px`, `--row-py: 6px`) used by tables and lists

### Shell Chrome

- [ ] **SHELL-01**: Sidebar matches Solar design — 192px width, section labels, nav items with kbd hints (⌘1–⌘4), Settings footer
- [ ] **SHELL-02**: Activity Panel has Operations and Meters tabs with collapsed 36px summary bar and expanded 240px panel
- [ ] **SHELL-03**: Meters tab shows cosmetic VU + Spectrum components that animate while any op is active and freeze otherwise

### Library Table

- [ ] **TBL-01**: Library table rows use 36px dense Solar styling with hover, selected, and playing states
- [ ] **TBL-02**: Library header toolbar shows Local/Remote tab switcher with counts, search input with ⌘F hint, and Analyze/Match/Filters icon buttons
- [ ] **TBL-03**: Title cell shows cached/remote status dot and SourceBadge where applicable; columns remain `title · artist · album · time · fmt · kbps · added` (Archivist only)

### Content Screens

- [ ] **SCRN-01**: Playlist list page restyled to Solar — pinned + all-playlists grids with cover, play indicator, source/sync badges
- [ ] **SCRN-02**: Playlist detail page restyled to Solar — hero block with cover, display font title, duration + updated-at only (no BPM range)
- [ ] **SCRN-03**: Sources page restyled to Solar — per-source card with brand icon, status dot, stats grid, connect/disconnect controls
- [ ] **SCRN-04**: Review queue restyled to Solar — candidate rows with confidence bar, art thumb, inline Accept/Use controls, keyboard hints
- [ ] **SCRN-05**: Playlist import modal restyled to Solar — source card, match-preview list with per-row confidence %, summary counts, auto-download toggle

### Sync UI

- [ ] **SYNCUI-01**: Sync profiles page restyled to Solar — device cards with usage bar, attached-playlist chips, Preview Sync + overflow actions
- [ ] **SYNCUI-02**: Sync preview screen restyled to Solar — add/remove/unchanged diff sections wired to existing `preview_sync_cmd` (no BPM or Camelot columns per CONTRACT §2)

### Loudness Data Pipeline

- [ ] **LOUD-01**: Database migration adds `lufs_i REAL`, `lufs_range REAL`, `true_peak REAL`, `energy_bucket INTEGER` columns to the tracks table (all nullable)
- [ ] **LOUD-02**: Existing ffmpeg ebur128 pass persists LUFS-I, LRA, and True Peak values alongside the existing ReplayGain gain
- [ ] **LOUD-03**: Second ffmpeg pass captures spectral centroid and combines with LUFS-I to derive a 1–5 `energy_bucket` per CONTRACT §3 item 5
- [ ] **LOUD-04**: "Analyze loudness" action in Settings (and Library header) queues analysis for all tracks where `lufs_i IS NULL`

### More Info Panel

- [ ] **MINFO-01**: More Info panel uses sectioned Solar layout — Musical / File / Loudness / Library (no row-level waveform, no BPM/Key visuals)
- [ ] **MINFO-02**: Loudness section shows Peak, LUFS-I, LRA, and Gain values with graceful "—" fallback when NULL
- [ ] **MINFO-03**: Optional `energy` column available in the library table column registry, hidden by default, toggleable when `energy_bucket` is populated

### Batch Actions

- [ ] **BATCH-01**: Floating batch bar appears when the library table selection has ≥2 rows and dismisses on Esc or click-outside
- [ ] **BATCH-02**: Batch bar exposes four actions wired to existing Tauri commands: Add to playlist, Add to sync profile, Remove from library (DB), Delete from disk
- [ ] **BATCH-03**: Destructive batch actions (Remove from library and Delete from disk) require an explicit confirmation dialog with the track count surfaced

## v1.3 Requirements — Yeat Expansion

Milestone scope: Yeat-only first-class artist treatment. Disk-to-DB migration for Yeat taxonomy, variant UI, playlist migration, era assignment, Python script ports, dossier page. Do NOT generalize to "any starred artist" — Yeat is the canonical use case.

**Locked decisions (from prior session brainstorm):**

- DB is canonical for era/variant/tag; on-disk folder moves surface in sync reports, do NOT silently rewrite DB
- `yëat typa shi` playlist stays separate from Yeat discography — shuffle-all-Yeat filters by artist, does NOT union with this playlist
- Unreleased-pair UFO toggle handles exactly-2 siblings; 3+ siblings get a distinct skeuomorphic Winamp-style cycler
- Yeat era assignment uses two passes: metadata fuzzy match (fast) → acoustic fingerprint (catches leaks/retitles); NO ML model
- Rockbox m3u8 paths use `/<HDD0>/` prefix required by Rockbox — remap to library root on import
- Droppy migration is OUT OF SCOPE (iMazing recon 2026-04-23 yielded nothing extractable) — Rockbox + symlink folder are sole Yeat playlist source of truth

### Tags & Provenance

- [ ] **TAG-01**: Yeat folder taxonomy on disk (`/Volumes/Lexxar/Music/00_Artist/Yeat/`) backfilled into `track_tags` (era, variant flag, artist=yeat)
- [ ] **TAG-02**: `playlist_tags` table backfilled with playlist-level metadata where inferable from folder structure
- [ ] **TAG-03**: Tag writes are DB-canonical — re-running backfill is idempotent; disk moves since last backfill show up in a sync report, not silent DB mutations

### Album Variant Detection & UFO Toggle

- [ ] **VAR-01**: Tracks/albums carry a `variant_of` column linking siblings (base ↔ `[U]`, `0.5`, `V1/V2/V4`)
- [ ] **VAR-02**: Sibling detection runs over the Yeat corpus and populates `variant_of` for detected pairs/groups
- [ ] **VAR-03**: Two-state UFO-opening toggle component renders on album pages that have exactly 2 siblings, swapping visible tracklist between base and variant (Yeat-only)

### Winamp Variant Cycler (3+ siblings)

- [ ] **VAR-04**: Sibling groups of 3+ are identified and grouped in the album-detail UI
- [ ] **VAR-05**: Multi-state skeuomorphic cycler ("Winamp-looking", designer's choice) cycles through all siblings and updates the visible tracklist
- [ ] **VAR-06**: Cycler is Yeat-only initially — no generalization to other artists

### Yeat Artist Flag & Sidebar Surface

- [ ] **ART-01**: Yeat is flagged as first-class in the library (artist-level stan/feature column or dedicated row)
- [ ] **ART-02**: Sidebar exposes a dedicated Yeat entry that routes to the Yeat-scoped view
- [ ] **ART-03**: "Shuffle all Yeat" / "Play all Yeat" filters by Yeat artist and explicitly EXCLUDES the `yëat typa shi` playlist
- [ ] **ART-04**: `yëat typa shi` remains its own addressable playlist — never unioned with Yeat discography operations

### Playlist Migration

- [ ] **MIG-01**: Rockbox m3u8 parser strips the `/<HDD0>/` path prefix and remaps to library root for path resolution
- [ ] **MIG-02**: `/Volumes/Lexxar/Music/05_Playlists/Yeat.m3u8` (119 paths) imports into a DB playlist named "Yeat"
- [ ] **MIG-03**: `/Volumes/Lexxar/Music/05_Playlists/🔔 yëat typa shi.m3u8` imports into a DB playlist named "yëat typa shi" — stays separate from Yeat
- [ ] **MIG-04**: `/Volumes/Lexxar/Music/06_Symlink_Playlists/Yeat/` (205 symlinks) is walked as a cross-check / fallback source when m3u8 resolution misses

### Yeat Era Assigner

- [ ] **ERA-01**: One-click era-assign flow works from both entry points: (a) disk → library → Yeat-era, and (b) library → Yeat-era
- [ ] **ERA-02**: Pass 1 — fuzzy title + duration matching against Yeat era corpus (fast, catches released tracks)
- [ ] **ERA-03**: Pass 2 — acoustic fingerprint matching via existing `src-tauri/src/fingerprint` module (catches leaks and retitles)
- [ ] **ERA-04**: UI presents existing eras as suggestions; user confirms selection (no hand-typed era names)

### Python Script Ports

- [ ] **TOOL-01**: `embed_covers.py` ported to Rust with identical behavior, exposed as a Tauri command
- [ ] **TOOL-02**: `replace_with_flac.py` ported to Rust with identical behavior, exposed as a Tauri command

### Yeat Dossier & Stan Theme

- [ ] **DASH-01**: Dedicated Yeat artist page with era timeline, unreleased variant tree, and discography stats
- [ ] **DASH-02**: Optional Yeat-themed visual skin (user-toggleable, independent from Solar theme)

## v1.4 Requirements — Daily Driver

**Milestone goal:** Make MLM something the user actually opens daily — navigate + listen, both in the same surface. Closes the daily-use loop missing despite shipped library + sync.

**Source of context:** `.planning/research/v1.4-daily-driver/SUMMARY.md` (synthesis of STACK / FEATURES / ARCHITECTURE / PITFALLS, 2026-05-04).

**Locked global rules (apply to every requirement):**

1. **UX baseline** — every interactive surface yields visible feedback in <100ms; long ops show a spinner; every Tauri command failure surfaces as a toast or inline error (no silent failures). This is the highest-priority anti-pattern guard, derived from the audio-analysis-clunky-button complaint that paused v1.3.
2. **DB-derived, never disk-walked** — folder hierarchy comes from `tracks.organized_path` queries, not filesystem walks. Sidesteps drive-disconnect, symlink-loop, and scale failures.
3. **No schema bumps unless strictly necessary.** v1.3 reserves schema v18 for paused phases on resume.
4. **No Yeat coupling.** v1.4 code is unaware of artist/era/variant/`variant_of`/`track_tags` semantics. Folder explorer treats `🔔 yëat typa shi` as just another folder. Native playlists do NOT auto-populate from tags. UFO toggle stays display-only.
5. **Native playlists are local-only.** `source_id = NULL`, `external_id = NULL`, `is_smart = false`, `is_liked = false`, `category = 'regular'`. Protects the SoundCloud-import seed boundary.
6. **Playback is preview-grade.** Click → space → plays. Full media-player ambitions (queue, gapless, crossfade, EQ, scrobbling, lock-screen) stay out of scope.

### Asset Protocol Setup (Phase 0 prerequisite)

- [ ] **INFRA-01**: `tauri.conf.json` `app.security.assetProtocol` enabled with scope covering the user-configured library root (recommendation: `["/Volumes/Lexxar/Music/**", "$HOME/Music/**"]`)
- [ ] **INFRA-02**: `Cargo.toml` `tauri = { features = ["protocol-asset"] }` added
- [ ] **INFRA-03**: `capabilities/default.json` updated with the asset-protocol capability (verify exact name during phase planning)
- [ ] **INFRA-04**: Existing `WaveformView.tsx` confirmed working in `tauri build` production output (retroactive un-break of v1.0 feature)

### Inline Preview & Spacebar Playback

- [x] **PLAY-01**: User can click a row in the Library table and hit Spacebar to start playback of that track
- [ ] **PLAY-02**: Spacebar toggles play/pause when a track is loaded (second press pauses, third press resumes)
- [ ] **PLAY-03**: Spacebar is suppressed when an input field, textarea, contenteditable, or button has focus (does not hijack typing)
- [ ] **PLAY-04**: A persistent mini-bar surfaces what's currently playing (track title, artist, simple play/pause + progress)
- [ ] **PLAY-05**: Playback respects system volume only — no in-app volume slider
- [x] **PLAY-06**: Unsupported formats (initial scope: anything outside the WKWebView-native whitelist; see open question O-1) display a clear toast — never silent failure
- [x] **PLAY-07**: Playback survives the existing v1.1 drive-mount/unmount events: drive disconnect during playback shows an inline error and stops cleanly, does not crash
- [x] **PLAY-08**: LUFS-normalized preview applied automatically — leverage v1.2 `loudness_lufs_i` already captured per track (no startle volume jumps between tracks)

### Disk-Folder Explorer

- [ ] **BROWSE-01**: A new sidebar entry "Folders" (or equivalent Solar-styled label) opens a browsable tree of the on-disk hierarchy under the library root
- [ ] **BROWSE-02**: Tree contents derived from `SELECT DISTINCT folder_prefix FROM tracks WHERE organized_path IS NOT NULL` — no filesystem walk
- [ ] **BROWSE-03**: Tree handles 11k+ tracks at sub-100ms initial paint (virtualized via `react-arborist`; lazy-loaded children where the tree is deep)
- [ ] **BROWSE-04**: Selecting a folder renders that folder's tracks in a right-pane track list (reuses the existing virtualized LibraryTable)
- [ ] **BROWSE-05**: Tree shows track counts per folder (cheap aggregate)
- [ ] **BROWSE-06**: Tree state persists across app launches — last-expanded nodes and last-selected folder restored on next open ("first-paint = right where I left it")
- [ ] **BROWSE-07**: Drive-not-mounted state surfaces a clear empty-state with the existing v1.1 reconnect affordance — folder tree does not error or crash

### Native MLM Playlists

- [ ] **PLAYLIST-01**: User can create a new playlist from the sidebar with a name (no source picker exposed — locked to native local-only)
- [ ] **PLAYLIST-02**: User can rename and delete a playlist from a context menu / row action
- [ ] **PLAYLIST-03**: User can drag one or more tracks from the library/folder-explorer track list onto a sidebar playlist entry to add them
- [ ] **PLAYLIST-04**: Drag-drop into a playlist provides immediate visual feedback (drop highlight, post-drop confirmation in <2s green-highlight pattern from Phase 10)
- [ ] **PLAYLIST-05**: User can reorder tracks within a playlist via drag-drop (existing fractional-indexing pattern)
- [ ] **PLAYLIST-06**: User can remove a track from a playlist without deleting it from the library
- [ ] **PLAYLIST-07**: Variant tracks (`AftërLyfe` and `AftërLyfe [U]` of the same title) are stored as distinct playlist entries — UFO toggle is display-only, never rewrites playlist membership
- [ ] **PLAYLIST-08**: Playlists created in v1.4 are constrained to the local-native shape (`source_id = NULL`, `external_id = NULL`, `is_smart = false`, `is_liked = false`, `category = 'regular'`) — enforced backend-side

### Bulk-Add to Playlist

- [ ] **BULK-01**: The existing Phase 19 multi-select batch bar gains an "Add to playlist…" action when ≥1 track is selected
- [ ] **BULK-02**: "Add to playlist…" shows the user's playlists (recent-first); selecting one adds the entire selection in one transaction
- [ ] **BULK-03**: Bulk-add of 1000+ tracks completes inside a single backend transaction with progress feedback if it exceeds 500ms
- [ ] **BULK-04**: Duplicate tracks added to the same playlist follow `INSERT OR IGNORE` semantics (no error, no duplicates)

### Polish & E2E

- [ ] **POLISH-01**: All new surfaces (folder explorer, mini-bar, playlist sidebar, drag-drop affordances) honor the Solar design contract (`research/solar-design/CONTRACT.md`) — colors, density, font stack, motion
- [ ] **POLISH-02**: All new surfaces have empty-state and error-state visuals (no blank panes; no silent toasts)
- [ ] **POLISH-03**: E2E tests cover the daily-driver loop end-to-end: open app → browse folder → click track → spacebar plays → drag selection into playlist → verify in playlist detail
- [ ] **POLISH-04**: All new `useEffect` hooks that register Tauri event listeners include cleanup returns (PITFALLS TR-1 grep audit gate)

## v1.5+ Deferred

Deferred to future milestones (renamed from prior "v1.4+ Deferred").

### Logical Folders / Collections (deferred from v1.4 scoping)

- **COLL-01**: User-defined logical hierarchy (separate from on-disk structure) for grouping tracks — natural home is v1.3 resumption (`track_tags` infrastructure already half-built) or a follow-on milestone if Yeat resumption ships first
- **COLL-02**: Smart playlists driven by tag/loudness/era queries — depends on COLL-01 + v1.3 tag pipeline

### SoundCloud Playlist Import (parked seed)

- **STRM-01**: One-time SoundCloud playlist import → native MLM playlist, filtered to tracks present on disk. Trigger: native playlists ship and feel solid. Likes filtering is a sub-instance. See `.planning/seeds/soundcloud-playlist-import.md`.
- **STRM-02**: Spotify JSON one-time migration from backup file (existing entry, unchanged)

### Similar Songs Grouping

- **SIM-01**: Songs with similar titles grouped with expandable triangle
- **SIM-02**: Expanding shows child variants (original mix, remixes, etc.)

### Legacy v1.2 Carryover (shipped via Phase 12)

- **IMP-01**: User can select an M3U or M3U8 file and import it as a playlist — shipped in Phase 12
- **IMP-02**: User can select a Spotify JSON export file and import it as a playlist — shipped in Phase 12
- **IMP-03**: Import preview shows matched/unmatched track counts — shipped in Phase 12
- **IMP-04**: Import creates playlist with matched tracks in original order — shipped in Phase 12

## v2.1 Reliability Requirements

### SoundCloud Download Integrity

- [ ] **SCDL-01**: SoundCloud-pinned downloads fail closed without automatic cross-provider fallback
- [ ] **SCDL-02**: A download result can only reference a file created by that specific request
- [ ] **SCDL-03**: YouTube query normalization preserves remix, edit, version, live, slowed, and remaster identity
- [ ] **SCDL-04**: A transient SoundCloud 401 refreshes and retries once without deleting stored credentials
- [ ] **SCDL-05**: SoundCloud token refresh is registered and started during app initialization
- [ ] **SCDL-06**: Operations shows every download item and its truthful terminal status or failure reason
- [ ] **SCDL-07**: Batch success requires validated file output and successful database persistence
- [ ] **SCDL-08**: SoundCloud artwork is retained and artwork maintenance progress is bounded by its total
- [ ] **SCDL-09**: New SoundCloud downloads use `01_SoundCloud`; existing files are not migrated automatically

## Out of Scope

| Feature | Reason |
|---------|--------|
| Full media-player ambitions (queue, gapless, crossfade, EQ, scrobbling, lock-screen, persisted play position) | v1.4 reverses prior "no playback" OOS for **preview-grade** only; full media-player scope stays out — see PROJECT.md scope-rules |
| In-app volume slider | System volume is the single source of truth for preview-grade playback (PITFALLS A-6) |
| Playlists synced bidirectionally to SoundCloud / Spotify | v1.4 native playlists are local-only; SC import is a deferred one-shot (`.planning/seeds/soundcloud-playlist-import.md`) |
| Logical folders / collections (separate from disk hierarchy) | Deferred from v1.4 scoping (FEATURES §5 + ARCHITECTURE §2.5 + PITFALLS X-2 unanimous); natural home is v1.3 resumption or v1.5 |
| Smart playlists driven by tags/loudness/era | Depends on logical folders/collections; same defer |
| Mobile app | Desktop only |
| Direct iTunes integration | Using Rockbox bypasses this |
| Streaming from the library | Files are for offline use on devices |
| Droppy iOS app migration | iMazing sandbox recon 2026-04-23 yielded nothing extractable; Rockbox m3u8 + symlink folder are sole Yeat playlist source of truth |
| Generalized "starred artist" system | v1.3 is Yeat-only by design — generalization deferred until pattern is proven |
| Silent DB rewrites from disk-folder moves | DB is canonical for era/variant/tag; disk drift surfaces in sync reports, not auto-rewrites |
| Yeat-coupled behavior in v1.4 surfaces | v1.4 code is unaware of artist/era/variant semantics — protects v1.3 paused phases (PITFALLS X-1) |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| LCFG-01 | Phase 8 | Done |
| LCFG-02 | Phase 8 | Done |
| LCFG-03 | Phase 8 | Done |
| LCFG-04 | Phase 8 | Done |
| REM-01 | Phase 9 | Pending |
| REM-02 | Phase 9 | Pending |
| REM-03 | Phase 9 | Pending |
| REM-04 | Phase 9 | Pending |
| LVIEW-01 | Phase 9 | Pending |
| LVIEW-02 | Phase 9 | Pending |
| LVIEW-03 | Phase 9 | Pending |
| ACT-01 | Phase 10 | Pending |
| ACT-02 | Phase 10 | Pending |
| ACT-03 | Phase 10 | Pending |
| ACT-04 | Phase 10 | Pending |
| DL-01 | Phase 11 | Pending |
| DL-02 | Phase 11 | Pending |
| DL-03 | Phase 11 | Pending |
| UX-01 | Phase 11 | Pending |
| IMP-01 | Phase 12 | Pending |
| IMP-02 | Phase 12 | Pending |
| IMP-03 | Phase 12 | Pending |
| IMP-04 | Phase 12 | Pending |
| THEME-01 | Phase 13 | Pending |
| THEME-02 | Phase 13 | Pending |
| THEME-03 | Phase 13 | Pending |
| THEME-04 | Phase 13 | Pending |
| SHELL-01 | Phase 14 | Pending |
| SHELL-02 | Phase 14 | Pending |
| SHELL-03 | Phase 14 | Pending |
| TBL-01 | Phase 15 | Pending |
| TBL-02 | Phase 15 | Pending |
| TBL-03 | Phase 15 | Pending |
| SCRN-01 | Phase 16 | Pending |
| SCRN-02 | Phase 16 | Pending |
| SCRN-03 | Phase 16 | Pending |
| SCRN-04 | Phase 16 | Pending |
| SCRN-05 | Phase 16 | Pending |
| SYNCUI-01 | Phase 17 | Pending |
| SYNCUI-02 | Phase 17 | Pending |
| LOUD-01 | Phase 18 | Pending |
| LOUD-02 | Phase 18 | Pending |
| LOUD-03 | Phase 18 | Pending |
| LOUD-04 | Phase 18 | Pending |
| MINFO-01 | Phase 18 | Pending |
| MINFO-02 | Phase 18 | Pending |
| MINFO-03 | Phase 18 | Pending |
| BATCH-01 | Phase 19 | Pending |
| BATCH-02 | Phase 19 | Pending |
| BATCH-03 | Phase 19 | Pending |
| TAG-01 | Phase 20 | Pending |
| TAG-02 | Phase 20 | Pending |
| TAG-03 | Phase 20 | Pending |
| VAR-01 | Phase 21 | Pending |
| VAR-02 | Phase 21 | Pending |
| VAR-03 | Phase 21 | Pending |
| VAR-04 | Phase 22 | Pending |
| VAR-05 | Phase 22 | Pending |
| VAR-06 | Phase 22 | Pending |
| ART-01 | Phase 23 | Pending |
| ART-02 | Phase 23 | Pending |
| ART-03 | Phase 23 | Pending |
| ART-04 | Phase 23 | Pending |
| MIG-01 | Phase 24 | Pending |
| MIG-02 | Phase 24 | Pending |
| MIG-03 | Phase 24 | Pending |
| MIG-04 | Phase 24 | Pending |
| ERA-01 | Phase 25 | Pending |
| ERA-02 | Phase 25 | Pending |
| ERA-03 | Phase 25 | Pending |
| ERA-04 | Phase 25 | Pending |
| TOOL-01 | Phase 26 | Pending |
| TOOL-02 | Phase 26 | Pending |
| DASH-01 | Phase 27 | Pending |
| DASH-02 | Phase 27 | Pending |
| INFRA-01 | Phase 28 | Pending |
| INFRA-02 | Phase 28 | Pending |
| INFRA-03 | Phase 28 | Pending |
| INFRA-04 | Phase 28 | Pending |
| PLAY-01 | Phase 29 | Complete |
| PLAY-02 | Phase 29 | Pending |
| PLAY-03 | Phase 29 | Pending |
| PLAY-04 | Phase 29 | Pending |
| PLAY-05 | Phase 29 | Pending |
| PLAY-06 | Phase 29 | Complete |
| PLAY-07 | Phase 29 | Complete |
| PLAY-08 | Phase 29 | Complete |
| BROWSE-01 | Phase 30 | Pending |
| BROWSE-02 | Phase 30 | Pending |
| BROWSE-03 | Phase 30 | Pending |
| BROWSE-04 | Phase 30 | Pending |
| BROWSE-05 | Phase 30 | Pending |
| BROWSE-06 | Phase 30 | Pending |
| BROWSE-07 | Phase 30 | Pending |
| PLAYLIST-01 | Phase 31 | Pending |
| PLAYLIST-02 | Phase 31 | Pending |
| PLAYLIST-03 | Phase 31 | Pending |
| PLAYLIST-04 | Phase 31 | Pending |
| PLAYLIST-05 | Phase 31 | Pending |
| PLAYLIST-06 | Phase 31 | Pending |
| PLAYLIST-07 | Phase 31 | Pending |
| PLAYLIST-08 | Phase 31 | Pending |
| BULK-01 | Phase 32 | Pending |
| BULK-02 | Phase 32 | Pending |
| BULK-03 | Phase 32 | Pending |
| BULK-04 | Phase 32 | Pending |
| POLISH-01 | Phase 33 | Pending |
| POLISH-02 | Phase 33 | Pending |
| POLISH-03 | Phase 33 | Pending |
| POLISH-04 | Phase 33 | Pending |
| SCDL-01 | Phase 39 | Verification pending |
| SCDL-02 | Phase 39 | Verification pending |
| SCDL-03 | Phase 39 | Verification pending |
| SCDL-04 | Phase 39 | Verification pending |
| SCDL-05 | Phase 39 | Verification pending |
| SCDL-06 | Phase 39 | Verification pending |
| SCDL-07 | Phase 39 | Verification pending |
| SCDL-08 | Phase 39 | Verification pending |
| SCDL-09 | Phase 39 | Verification pending |

**Coverage:**
- v1.1 requirements: 19 total
- v1.2 Legacy (Phase 12): 4 total (IMP-01 through IMP-04)
- v1.2 Solar Design & Loudness: 27 total (THEME/SHELL/TBL/SCRN/SYNCUI/LOUD/MINFO/BATCH)
- v1.3 Yeat Expansion: 24 total (TAG/VAR/ART/MIG/ERA/TOOL/DASH) — phases 22–27 PAUSED 2026-05-04 mid-flight; spec retained
- v1.4 Daily Driver: 35 total (INFRA/PLAY/BROWSE/PLAYLIST/BULK/POLISH)
- v2.1 Reliability: 9 total (SCDL)
- Mapped to phases: 118
- Unmapped: 0

---
*Requirements defined: 2026-02-05*
*Last updated: 2026-07-21 — added SoundCloud Download Integrity requirements for Phase 39*
