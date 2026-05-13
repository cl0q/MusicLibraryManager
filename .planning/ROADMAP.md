# Roadmap: MusicLibraryManager

## Milestones

- ✅ **v1.0 MVP** - Phases 1-7 (shipped 2026-02-05)
- ✅ **v1.1 Library Foundation & UX Polish** - Phases 8-12.1 (shipped 2026-03-31)
- ✅ **v1.2 Solar Design System & Loudness** - Phases 13-19 (shipped 2026-04-22)
- ⏸️ **v1.3 Yeat Expansion** - Phases 20-27 (opened 2026-04-23, **paused 2026-05-04** mid-flight; phases 20/21/21.1 shipped, 22-27 retained as locked spec for resumption)
- 🚧 **v1.4 Daily Driver** - Phases 28-33 (opened 2026-05-04)

## Phases

<details>
<summary>✅ v1.0 MVP (Phases 1-7) - SHIPPED 2026-02-05</summary>

### Phase 1: Library Foundation
**Goal**: Local library with metadata extraction and search
**Plans**: 7 plans

Plans:
- [x] 01-01: Database schema (tracks, albums, artists, playlists, sources)
- [x] 01-02: Metadata extraction with lofty
- [x] 01-03: File import with duplicate detection
- [x] 01-04: SQLite with atomic transactions
- [x] 01-05: Tantivy search index
- [x] 01-06: Quality-based duplicate detection
- [x] 01-07: Scan directory command

### Phase 2: Download Pipeline
**Goal**: Download songs from multiple sources with fallback
**Plans**: 6 plans

Plans:
- [x] 02-01: dabmusic.xyz FLAC download
- [x] 02-02: YouTube fallback with yt-dlp
- [x] 02-03: AAC transcode with ffmpeg
- [x] 02-04: Download queue and progress tracking
- [x] 02-05: Metadata preservation
- [x] 02-06: Error handling and retries

### Phase 3: Source Integration
**Goal**: Spotify and SoundCloud integration with incremental sync
**Plans**: 5 plans

Plans:
- [x] 03-01: OAuth 2.0 PKCE flow
- [x] 03-02: Spotify liked songs import
- [x] 03-03: SoundCloud likes import
- [x] 03-04: Incremental sync (check last_synced timestamps)
- [x] 03-05: Cross-source deduplication

### Phase 4: Playlist Management
**Goal**: User can create and reorder playlists with drag-drop
**Plans**: 4 plans

Plans:
- [x] 04-01: Playlist CRUD operations
- [x] 04-02: Fractional indexing for O(1) reorder
- [x] 04-03: Smart playlists with filters
- [x] 04-04: Drag-drop reorder UI

### Phase 5: Device Sync
**Goal**: Sync library to Rockbox iPod with incremental updates
**Plans**: 5 plans

Plans:
- [x] 05-01: Rockbox device detection
- [x] 05-02: M3U8 playlist generation
- [x] 05-03: SHA256 checksums for incremental sync
- [x] 05-04: File copy with progress
- [x] 05-05: Sync state tracking

### Phase 6: Desktop UI
**Goal**: Cross-platform desktop app with library browser
**Plans**: 6 plans

Plans:
- [x] 06-01: Tauri project setup
- [x] 06-02: Library browser with TanStack Table
- [x] 06-03: Virtual scrolling for large libraries
- [x] 06-04: Real-time progress display
- [x] 06-05: Playlist UI
- [x] 06-06: Device sync UI

### Phase 7: Enhancements
**Goal**: Audio fingerprinting, artwork, and ReplayGain
**Plans**: 5 plans

Plans:
- [x] 07-01: Chromaprint fingerprinting
- [x] 07-02: MusicBrainz artwork fetching
- [x] 07-03: EBU R128 ReplayGain
- [x] 07-04: Waveform and spectrogram generation
- [x] 07-05: ffprobe integration
- [x] 07-06: Tauri commands & Review Queue UI

</details>

### ✅ v1.1 Library Foundation & UX Polish (Shipped 2026-03-31)

**Milestone Goal:** Make the local library real — files live on external SSD, remote songs are separated into a staging area, and the UI feels responsive.

#### ✅ Phase 8: Library Configuration & Drive Detection
**Goal**: User can configure an external drive as library location and app handles drive state
**Depends on**: Nothing (milestone foundation)
**Requirements**: LCFG-01, LCFG-02, LCFG-03, LCFG-04
**Success Criteria** (what must be TRUE):
  1. User can configure a directory as the library location in settings
  2. App detects when configured library drive is not connected
  3. Library tab shows a message when drive is not connected (blocks access)
  4. Remote tab remains accessible when library drive is not connected
**Plans**: 4 plans

Plans:
- [x] 08-01-PLAN.md — Backend foundation: database schema, LibraryConfig model, Tauri commands, marker file
- [x] 08-02-PLAN.md — Mount detection service with macOS FSEvents via /Volumes monitoring
- [x] 08-03-PLAN.md — Settings UI page, library setup form, first-run wizard modal
- [x] 08-04-PLAN.md — Disconnected state UI: mount context, sidebar graying, empty state

#### ✅ Phase 9: Library/Remote Separation
**Goal**: Library shows only local files, Remote shows undownloaded staging
**Depends on**: Phase 8
**Requirements**: REM-01, REM-02, REM-03, REM-04, LVIEW-01, LVIEW-02, LVIEW-03
**Success Criteria** (what must be TRUE):
  1. Remote appears as a sidebar item alongside Library
  2. Remote view shows only songs from streaming services not yet downloaded
  3. Remote syncs with connected streaming services on startup
  4. Library view shows only songs that exist locally on disk
  5. Format column shows audio format (FLAC, AAC, MP3) instead of source name
  6. All library columns show correct metadata from local files
  7. Downloaded songs disappear from Remote and appear in Library
**Plans**: 4 plans

Plans:
- [x] 09-01-PLAN.md — Backend query filtering (schema v7, library/remote queries, count command)
- [x] 09-02-PLAN.md — Sidebar Remote nav item with badge count and event listeners
- [x] 09-03-PLAN.md — Route-based view switching for /library and /remote
- [x] 09-04-PLAN.md — Human verification of library/remote separation

#### ✅ Phase 10: Track Actions & More Info
**Goal**: Context menu actions work correctly for local tracks
**Depends on**: Phase 9
**Requirements**: ACT-01, ACT-02, ACT-03, ACT-04
**Success Criteria** (what must be TRUE):
  1. More Info shows real file data (fingerprint, waveform, spectrogram, ffprobe output)
  2. Add to playlist works for local tracks
  3. Add to sync profile works for local tracks
  4. Open in file manager works for local tracks
**Plans**: 3 plans

Plans:
- [x] 10-01-PLAN.md — Context menu with submenus (playlists, sync profiles), multi-track selection, inline confirmation
- [x] 10-02-PLAN.md — More Info side panel with track overview, collapsible sections, auto-load light data
- [x] 10-03-PLAN.md — Backend file operations (copy clipboard, ffprobe extraction, track_analysis caching)

#### ✅ Phase 11: Download Flow & UX Polish
**Goal**: Users can download from Remote to Library with responsive UI
**Depends on**: Phase 9, Phase 10
**Requirements**: DL-01, DL-02, DL-03, UX-01
**Success Criteria** (what must be TRUE):
  1. User can download a single song from Remote view
  2. User can download multiple songs in batch from Remote view
  3. Downloaded songs move from Remote to Library automatically
  4. Context menu appears immediately on right-click with no delay
**Plans**: 3 plans

Plans:
- [x] 11-01-PLAN.md — Backend download with progress streaming and download_status updates
- [x] 11-02-PLAN.md — Frontend download UI with real-time progress and auto-refresh
- [x] 11-03-PLAN.md — Human verification of download flow and context menu responsiveness

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → ... → 11

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Library Foundation | v1.0 | 7/7 | Complete | 2026-02-05 |
| 2. Download Pipeline | v1.0 | 6/6 | Complete | 2026-02-05 |
| 3. Source Integration | v1.0 | 5/5 | Complete | 2026-02-05 |
| 4. Playlist Management | v1.0 | 4/4 | Complete | 2026-02-05 |
| 5. Device Sync | v1.0 | 5/5 | Complete | 2026-02-05 |
| 6. Desktop UI | v1.0 | 6/6 | Complete | 2026-02-05 |
| 7. Enhancements | v1.0 | 6/6 | Complete | 2026-02-05 |
| 8. Library Configuration & Drive Detection | v1.1 | 4/4 | Complete | 2026-02-07 |
| 9. Library/Remote Separation | v1.1 | 0/4 | Not started | - |
| 10. Track Actions & More Info | v1.1 | 3/3 | Complete | 2026-02-07 |
| 11. Download Flow & UX Polish | v1.1 | 0/3 | Not started | - |

### ✅ Phase 11.1: Functional & E2E Test Harness (INSERTED)

**Goal:** Regression safety net — backend integration tests for download pipeline and library/remote filtering, frontend component rendering tests for key UI components
**Requirements**: (no specific IDs — inserted phase for regression coverage)
**Depends on:** Phase 11
**Plans:** 3/3 plans complete

Plans:
- [x] 11.1-01-PLAN.md — Backend test infrastructure: tests/common helpers, JSON API fixtures, audio fixtures, fix failing DAB test
- [x] 11.1-02-PLAN.md — Backend integration tests: library/remote filtering (6 tests) and download pipeline DB transitions (5 tests)
- [x] 11.1-03-PLAN.md — Frontend test setup: Vitest + @testing-library/react + 4 component rendering test files

### ✅ Phase 12: Import External Playlists

**Goal:** User can import M3U/M3U8 and Spotify JSON playlist files into the music library, with fuzzy track matching and a match preview before confirming playlist creation
**Requirements**: IMP-01, IMP-02, IMP-03, IMP-04
**Depends on:** Phase 11
**Plans:** 3/3 plans complete

Plans:
- [x] 12-01-PLAN.md — Backend: playlist_importer module (M3U + JSON parsers, fuzzy matching, import command)
- [x] 12-02-PLAN.md — Frontend: ImportModal + MatchPreview components, Import button in PlaylistList
- [x] 12-03-PLAN.md — Human verification of end-to-end import flow

### ✅ Phase 12.1: Consistent Path Resolution — organized_path always relative to root (INSERTED)

**Goal:** Enforce the Phase 8-01 invariant: organized_path is always relative to library root, never absolute. Migrate 38 existing absolute paths, harden write paths with fail-fast validation, and clean up defensive read-side code.
**Requirements**: PATH-01, PATH-02, PATH-03, PATH-04
**Depends on:** Phase 12
**Plans:** 2/2 plans complete

Plans:
- [x] 12.1-01-PLAN.md — Write-path hardening: validate_organized_path guard, fail-fast strip_prefix, schema migration v9 (strip absolute paths from 38 existing DB rows)
- [x] 12.1-02-PLAN.md — Read-path cleanup: remove defensive absolute-path acceptance from reveal_in_file_manager and resolve_track_path; integration tests for path consistency

---

## ✅ v1.2 Solar Design System & Loudness (Shipped 2026-04-22)

**Milestone Goal:** Port the "Solar — Pro Audio Light" design system across every screen, surface existing loudness analysis data, and add multi-select batch actions.

**Source of truth:** `.planning/research/solar-design/CONTRACT.md` — locked scope cuts and decisions every phase agent must read. The mock bundle lives at `.planning/research/solar-design/project/mlm/`.

**Autonomous execution plan:** `/gsd-autonomous` runs Phases 13-19 with a single hard pause after Phase 13 for user eyeball review. Final `/gsd-ui-review` after Phase 19.

### ✅ Phase 13: Solar Theme Foundation
**Goal**: Solar palette + IBM Plex fonts + theme tokens live app-wide; Solar is default on fresh install; Solarized Dark/Light retained as picker options
**Depends on**: Nothing (milestone foundation)
**Requirements**: THEME-01, THEME-02, THEME-03, THEME-04
**Success Criteria** (what must be TRUE):
  1. App boots in Solar theme on fresh install (existing user theme preference preserved)
  2. Settings theme picker offers Solar, Solarized Dark, and Solarized Light
  3. IBM Plex Sans, Mono, and Serif load from bundled `@font-face` declarations (works offline)
  4. `[data-theme="solar"]` block maps every `--color-*` and font token to Solar values
  5. Global density tokens (`--row-h: 36px`, `--row-py: 6px`) defined

**→ UI-review gate here — autonomous run pauses for user eyeball ←**

### ✅ Phase 14: Shell Chrome Restyle
**Goal**: Sidebar and Activity Panel match Solar mock with cosmetic Meters tab
**Depends on**: Phase 13
**Requirements**: SHELL-01, SHELL-02, SHELL-03
**Success Criteria**:
  1. Sidebar is 192px wide with section labels, kbd hints (⌘1–⌘4), and Settings footer per `shell.jsx`
  2. Activity Panel has Operations and Meters tabs with collapsed 36px / expanded 240px states
  3. Meters tab renders cosmetic VU + Spectrum components that animate only while an op is active

### ✅ Phase 15: Library Table & Header Restyle
**Goal**: Library table and header toolbar ported to Solar with Archivist columns only
**Depends on**: Phase 13
**Requirements**: TBL-01, TBL-02, TBL-03
**Success Criteria**:
  1. Rows are 36px dense with hover, playing, and selected states matching `table.jsx`
  2. Title cell shows cached/remote status dot and SourceBadge; columns remain `title · artist · album · time · fmt · kbps · added`
  3. Header toolbar shows Local/Remote tab switcher with counts, search with ⌘F hint, and Analyze/Match/Filters icon buttons
  4. No BPM, Key, or Waveform columns are added

### ✅ Phase 16: Content Screens Restyle
**Goal**: Playlists (list + detail), Sources, Review Queue, and Import Modal ported to Solar
**Depends on**: Phase 13
**Requirements**: SCRN-01, SCRN-02, SCRN-03, SCRN-04, SCRN-05
**Success Criteria**:
  1. Playlist list renders Solar grid with pinned + all sections, cover, play indicator, and source/sync badges
  2. Playlist detail hero matches Solar mock — IBM Plex Serif title, duration + updated-at (no BPM range)
  3. Sources cards render with brand color, status dot, stats grid, and connect/disconnect controls
  4. Review queue rows render with confidence bar, art thumb, inline Accept/Use buttons, and kbd hints
  5. Import modal matches Solar — source card, per-row match %, summary counts, auto-download toggle

### ✅ Phase 17: Sync UI Restyle
**Goal**: Sync profiles and sync preview ported to Solar — frontend only (backend `preview_sync_cmd` already exists)
**Depends on**: Phase 13
**Requirements**: SYNCUI-01, SYNCUI-02
**Success Criteria**:
  1. Sync profiles page shows device cards with usage bar, attached-playlist chips, and Preview Sync action
  2. Sync preview diff screen shows add/remove/unchanged sections wired to existing `preview_sync_cmd`
  3. No BPM or Camelot key columns appear in diff rows (CONTRACT override of mock)

### ✅ Phase 18: More Info Restyle + Loudness Data Pipeline
**Goal**: More Info panel restructured into Solar sections and loudness data (LUFS-I, LRA, True Peak, Energy bucket) captured end-to-end
**Depends on**: Phase 13
**Requirements**: LOUD-01, LOUD-02, LOUD-03, LOUD-04, MINFO-01, MINFO-02, MINFO-03
**Success Criteria**:
  1. DB migration adds `lufs_i`, `lufs_range`, `true_peak`, `energy_bucket` columns (all nullable)
  2. Ebur128 analysis persists LUFS-I, LRA, and True Peak; spectral centroid pass feeds `energy_bucket` derivation
  3. "Analyze loudness" action queues re-analysis for all tracks where `lufs_i IS NULL`
  4. More Info panel uses Musical / File / Loudness / Library sections with "—" fallback on NULL values
  5. Optional `energy` column available in the library table column registry, hidden by default

### ✅ Phase 19: Multi-Select Batch Bar
**Goal**: Floating batch bar with four actions wired to existing commands; destructive actions confirm
**Depends on**: Phase 15
**Requirements**: BATCH-01, BATCH-02, BATCH-03
**Success Criteria**:
  1. Batch bar appears when library selection has ≥2 rows and dismisses on Esc or click-outside
  2. Actions offered: Add to playlist, Add to sync profile, Remove from library (DB only), Delete from disk
  3. Remove from library and Delete from disk require explicit confirmation dialogs with track count in the button labels

---

## v1.2 Progress Table

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 13. Solar Theme Foundation | v1.2 | 0/TBD | Not started | - |
| 14. Shell Chrome Restyle | v1.2 | 0/TBD | Not started | - |
| 15. Library Table & Header Restyle | v1.2 | 0/TBD | Not started | - |
| 16. Content Screens Restyle | v1.2 | 0/TBD | Not started | - |
| 17. Sync UI Restyle | v1.2 | 0/TBD | Not started | - |
| 18. More Info + Loudness Pipeline | v1.2 | 0/TBD | Not started | - |
| 19. Multi-Select Batch Bar | v1.2 | 0/TBD | Not started | - |

---

## 🚧 v1.3 Yeat Expansion (Opened 2026-04-23)

**Milestone Goal:** Treat Yeat as a first-class, library-featured artist. Backfill the custom on-disk taxonomy (era, variant, unreleased) into DB-canonical tags, build variant-aware album UI (UFO toggle + Winamp cycler), migrate Rockbox m3u8 playlists, add a two-pass era assigner (metadata → fingerprint), port user's Python cover/FLAC scripts to Rust, and ship a Yeat dossier page with optional stan theme.

**Scope rules (locked in prior session — see .planning/REQUIREMENTS.md v1.3 section):**
- Yeat-only initially (no generalization to "any starred artist")
- DB is canonical for era/variant/tag; disk drift surfaces in sync reports
- `yëat typa shi` stays a separate playlist — never unioned with Yeat discography in shuffle/play-all
- Era assignment uses fuzzy metadata match + existing fingerprint module (no ML)
- Droppy iOS migration OUT OF SCOPE — iMazing recon 2026-04-23 yielded nothing extractable

**Execution model:** α (autonomous) — `/gsd-autonomous` chains discuss→plan→execute for phases 20-27 without per-phase approval gates.

### Phase 20: Tags & Provenance
**Goal**: Backfill `track_tags` and `playlist_tags` from the on-disk Yeat folder taxonomy so era/variant/artist data is DB-canonical
**Depends on**: Nothing (milestone foundation)
**Requirements**: TAG-01, TAG-02, TAG-03
**Success Criteria**:
  1. Every track under `/Volumes/Lexxar/Music/00_Artist/Yeat/` has `artist=yeat`, inferred `era`, and a `variant` flag persisted in `track_tags`
  2. Playlist-level tags backfilled into `playlist_tags` for Yeat-scoped playlists on disk
  3. Backfill is idempotent — re-running produces zero mutations when disk state is unchanged
  4. Disk state that drifts from DB is reported in a sync report (not silently rewritten to DB)

### Phase 21: Album Pairs + UFO Toggle
**Goal**: Detect exactly-2 sibling album pairs via a `variant_of` column and render a two-state UFO-opening toggle that swaps the visible tracklist between base and variant
**Depends on**: Phase 20
**Requirements**: VAR-01, VAR-02, VAR-03
**Success Criteria**:
  1. Schema adds `variant_of` column linking siblings; backfill detects pairs (e.g., `AftërLyfe` ↔ `AftërLyfe [U]`)
  2. UFO toggle component renders only on album pages with exactly 2 detected siblings
  3. Toggle transitions with a spacey "UFO opening" animation (exaggeration of the iOS 15 Figma reference — not a literal copy)
  4. Active state is persisted per-user so returning to the album restores last-viewed variant
  5. Toggle is Yeat-only (gated by `artist=yeat`)

### Phase 21.1: Album Backfill Remediation (URGENT hotfix)
**Goal**: Fix stale Phase 21 album data — re-normalize `title_normalized`, dedupe albums split by `album_artist` casing, re-link tracks, auto-run sibling detection, add a Settings trigger for rescan
**Depends on**: Phase 21
**Requirements**: VAR-01 (reaffirm), VAR-02 (reaffirm)
**Success Criteria**:
  1. Schema migration v17 re-normalizes all existing `albums.title_normalized` via current `normalize_title_stem` (fixes `aft_rlyfe` → `afterlyfe` and any other non-ASCII stems)
  2. Duplicate album rows caused by `album_artist` casing differences (e.g., `Yeat` + `yeat`) are merged; `tracks.album_id` is re-linked to the kept row
  3. Unique constraint prevents future casing-induced splits: `UNIQUE(LOWER(album_artist), title_normalized, variant_kind)` or equivalent
  4. Ongoing `backfill_albums_from_tracks` aggregation uses case-insensitive `album_artist` so future imports merge cleanly
  5. Sibling detection auto-runs after remediation so `variant_of` is populated
  6. Settings page exposes a "Rescan albums" button invoking `rescan_albums_cmd` (re-backfill + re-normalize + re-detect siblings) — non-destructive to user variant preferences

### Phase 22: Winamp Variant Cycler
**Goal**: Multi-state skeuomorphic cycler for sibling groups of 3+ (e.g., `4L` + `4L [U]` + `4L 0.5`)
**Depends on**: Phase 21
**Requirements**: VAR-04, VAR-05, VAR-06
**Success Criteria**:
  1. Sibling detection extended to groups of 3+; cycler renders on album pages where the group has ≥3 members
  2. Cycler is visually distinct from the UFO toggle — skeuomorphic, chunky, "Winamp-looking" (designer's choice, not a second UFO)
  3. Clicking advances through all siblings in a defined order; visible tracklist updates on each click
  4. Cycler is Yeat-only initially

### Phase 23: Yeat Artist Flag + Sidebar Surface
**Goal**: Mark Yeat as first-class in the library, add a dedicated sidebar entry, and wire filtered shuffle/play that excludes the `yëat typa shi` playlist
**Depends on**: Phase 20
**Requirements**: ART-01, ART-02, ART-03, ART-04
**Success Criteria**:
  1. Yeat carries a first-class flag (artist table column or dedicated schema marker)
  2. Sidebar exposes a Yeat entry that routes to a Yeat-scoped view
  3. "Shuffle all Yeat" and "Play all Yeat" filter by Yeat artist and explicitly exclude `yëat typa shi` tracks
  4. `yëat typa shi` remains addressable as its own playlist — never unioned in Yeat discography operations

### Phase 24: Rockbox m3u8 + Yeat Playlist Migrate
**Goal**: Parse Rockbox-format m3u8 files (with `/<HDD0>/` prefix) and import both `Yeat.m3u8` (119 paths) and `🔔 yëat typa shi.m3u8` as separate DB playlists, using `06_Symlink_Playlists/Yeat/` as a fallback resolution source
**Depends on**: Phase 23
**Requirements**: MIG-01, MIG-02, MIG-03, MIG-04
**Success Criteria**:
  1. Parser strips `/<HDD0>/` prefix and resolves remaining path against library root
  2. `/Volumes/Lexxar/Music/05_Playlists/Yeat.m3u8` imports into a DB playlist named "Yeat" (119 entries, or explicit miss report for unresolved paths)
  3. `/Volumes/Lexxar/Music/05_Playlists/🔔 yëat typa shi.m3u8` imports into a separate DB playlist named "yëat typa shi"
  4. `/Volumes/Lexxar/Music/06_Symlink_Playlists/Yeat/` symlinks walked as a fallback / cross-check source for tracks unresolved from the m3u8
  5. Import is idempotent — re-running on unchanged input produces zero mutations

### Phase 25: Yeat Era Assigner
**Goal**: One-click era-assignment flow with two-pass matching — fuzzy metadata first, acoustic fingerprint second, using the existing `src-tauri/src/fingerprint` module
**Depends on**: Phase 20
**Requirements**: ERA-01, ERA-02, ERA-03, ERA-04
**Success Criteria**:
  1. Entry points work from both (a) disk → library → Yeat-era and (b) library → Yeat-era
  2. Pass 1 performs fuzzy title + duration match against the Yeat era corpus and returns candidate eras ranked by score
  3. Pass 2 runs acoustic fingerprint matching (via existing `fingerprint` module) for tracks that pass 1 fails to confidently place
  4. UI surfaces existing era names as suggestions — user confirms via click, no hand-typed era names accepted
  5. No ML model is introduced — both passes use the existing primitives

### Phase 26: Port Python Scripts
**Goal**: Port the user's custom `embed_covers.py` and `replace_with_flac.py` to Rust and expose them as Tauri commands with identical behavior
**Depends on**: Phase 20
**Requirements**: TOOL-01, TOOL-02
**Success Criteria**:
  1. `embed_covers.py` behavior replicated in a Rust `embed_covers_cmd` — same input contract, same side effects on disk
  2. `replace_with_flac.py` behavior replicated in a Rust `replace_with_flac_cmd`
  3. Both commands integrate with the library's existing ffmpeg wrapper (no duplicate transcode logic)
  4. A regression harness compares Rust outputs against the Python script outputs on a reference set before the Python scripts are retired

### Phase 27: Yeat Dossier Page + Stan Theme
**Goal**: Dedicated Yeat artist page (era timeline, unreleased variant tree, discography stats) plus an optional Yeat-themed visual skin
**Depends on**: Phase 21, Phase 23
**Requirements**: DASH-01, DASH-02
**Success Criteria**:
  1. Yeat dossier page renders an era timeline across the Yeat corpus
  2. Unreleased variants appear as a tree/graph off their base albums, leveraging `variant_of` from Phase 21
  3. Discography stats panel shows counts per era, per variant type, fingerprint-matched leaks
  4. Optional stan theme is user-toggleable in Settings (independent of Solar — not a theme replacement)
  5. Dossier page is accessible from the Yeat sidebar entry (Phase 23)

---

## v1.3 Progress Table

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 20. Tags & Provenance | v1.3 | 0/TBD | Not started | - |
| 21. Album Pairs + UFO Toggle | v1.3 | 0/TBD | Not started | - |
| 22. Winamp Variant Cycler | v1.3 | 0/TBD | Not started | - |
| 23. Yeat Artist Flag + Sidebar | v1.3 | 0/TBD | Not started | - |
| 24. Rockbox m3u8 + Playlist Migrate | v1.3 | 0/TBD | Not started | - |
| 25. Yeat Era Assigner | v1.3 | 0/TBD | Not started | - |
| 26. Port Python Scripts | v1.3 | 0/TBD | Not started | - |
| 27. Yeat Dossier + Stan Theme | v1.3 | 0/TBD | Not started | - |

---

## v1.4 Daily Driver (Opened 2026-05-04)

**Milestone Goal:** Make MLM a tool the user opens daily — navigate + listen, both in the same surface. Closes the daily-use loop missing despite shipped library + sync features (v1.0–v1.2).

**Source of truth:** `.planning/REQUIREMENTS.md` v1.4 section + `.planning/research/v1.4-daily-driver/SUMMARY.md` (synthesis of STACK / FEATURES / ARCHITECTURE / PITFALLS, 2026-05-04).

**Phase numbering:** Continues from v1.3 (paused at Phase 27). v1.4 begins at **Phase 28**. v1.3 phases 22–27 above remain as paused-not-killed spec; they resume after v1.4 lands AND `.planning/todos/pending/audio-analysis-ux-cleanup.md` is done.

**Execution model:** Standard (not autonomous) — UX work; user wants to feel each phase before chaining.

---

### v1.4 Global UX Banner (anti-pattern guard)

> **U-1 — every phase MUST satisfy:** every interactive surface gives visible feedback in **<100ms**; long ops (>200ms expected) show a spinner; every Tauri command failure surfaces as a toast or inline error — **never silent failure**. Click handler sets local state synchronously **before** any `await`. Spacebar/button debounce at 100ms. Every `useEffect` that calls `listen()` returns a cleanup. This is the highest-priority anti-pattern guard, derived from the audio-analysis clunky-button complaint that paused v1.3.

These global rules apply implicitly to every phase below; phases need not re-state them, but each phase plan must honor them.

---

### Cross-cutting v1.3 Coupling Rules (X-1 / X-2 / X-3 guard rules)

To protect the paused v1.3 milestone (phases 22–27) and the parked SoundCloud-import seed:

1. **No Yeat coupling (X-1).** v1.4 code knows nothing about Yeat, era, variant, `variant_of`, or any artist-specific behavior. Folder explorer treats `🔔 yëat typa shi` as just another folder. Native playlists do NOT auto-populate from `track_tags(tag_key='artist', tag_value='yeat')`. UFO toggle stays display-only. Code-review red flag: any `if artist == "Yeat"` or `if folder LIKE '%yëat%'` in v1.4 PRs.
2. **No new aggregate tables (X-2).** v1.3 Phase 23 owns the future `artists` table. v1.4 reads via `SELECT DISTINCT artist FROM tracks`. v1.4 does NOT extend `albums` or `variant_of`. Default position: **no schema bumps in v1.4**; if unavoidable, v1.4 takes v18+ and v1.3 phases 22+ renumber on resume.
3. **Native playlists are constrained (X-3).** Every v1.4-created playlist is `source_id = NULL`, `external_id = NULL`, `is_smart = false`, `is_liked = false`, `category = 'regular'`. Backend `create_native_playlist_cmd` enforces; UI exposes no source picker. Protects the SoundCloud-import-seed boundary.
4. **Variant tracks are distinct in playlists.** `AftërLyfe` and `AftërLyfe [U]` versions of the same title both add and play. UFO toggle never rewrites playlist membership.

---

### Phase 28: Asset-Protocol Setup
**Goal**: Tauri asset protocol configured so HTML5 `<audio>` can serve files from the library root — un-breaks v1.0 `WaveformView.tsx` retroactively and unblocks all preview playback work
**Depends on**: Nothing (milestone foundation; non-optional prerequisite for Phase 29)
**Requirements**: INFRA-01, INFRA-02, INFRA-03, INFRA-04
**Success Criteria** (what must be TRUE):
  1. Files under `/Volumes/Lexxar/Music/**` and `$HOME/Music/**` resolve via `convertFileSrc` in a `tauri build` production binary
  2. The existing `WaveformView.tsx` (More Info panel) renders waveforms in production builds — verified end-to-end on a real local track
  3. Asset-protocol scope is explicit (`tauri.conf.json` + `Cargo.toml` `protocol-asset` feature + `capabilities/default.json`) — no reliance on permissive dev-mode CSP
  4. CSP remains `null` for v1.4 (security-hardening deferred); no regressions in any v1.0–v1.3 surface
**Plans:** 1 plan — COMPLETE

Plans:
- [x] 28-01-PLAN.md — Wire Tauri asset-protocol (Cargo feature + tauri.conf scope + D-04 capability discovery + 3-format prod smoke + atomic D-08 commit) — **shipped 2026-05-05 commit ed5ee4c** (D-04 Branch 1, 3-format DevTools fetch+canplay PASS in dev mode; SC2 deferred to Phase 29 — see SUMMARY.md for methodology gap)

---

### Phase 29: Inline Preview / Spacebar Playback
**Goal**: Click a track row, hit space, it plays — preview-grade playback (no queue, no gapless, no crossfade) with a persistent mini-bar so the user always knows what's playing
**Depends on**: Phase 28
**Requirements**: PLAY-01, PLAY-02, PLAY-03, PLAY-04, PLAY-05, PLAY-06, PLAY-07, PLAY-08
**Success Criteria** (what must be TRUE):
  1. User can click a row in the Library table and hit Spacebar to start playback of that track
  2. Spacebar toggles play/pause when a track is loaded; second press pauses, third press resumes
  3. Spacebar is suppressed when an `INPUT`, `TEXTAREA`, `[contenteditable]`, or `BUTTON` has focus — typing in inputs is unaffected
  4. A persistent mini-bar surfaces the currently-playing track (title, artist, simple play/pause + progress) and stays visible across views
  5. Playback respects system volume only (no in-app volume slider)
  6. Unsupported formats (outside the WKWebView whitelist) display a clear toast — never silent failure
  7. Drive disconnect during playback shows an inline error and stops cleanly — no crash
  8. LUFS-normalized preview is applied automatically using v1.2 `lufs_i` data — no startle volume jumps between tracks
**Plans**: 4 plans

Plans:
- [x] 29-01-PLAN.md — Backend `resolve_track_audio_path` Tauri command + lib.rs registration
- [ ] 29-02-PLAN.md — `PlaybackContext` provider: audio lifecycle, spacebar handler, LUFS gain, drive-disconnect, cleanup
- [ ] 29-03-PLAN.md — `MiniPlayer` component + MainLayout integration (36px persistent bar)
- [ ] 29-04-PLAN.md — Wave 0 test stubs, grep audits (volume slider / cleanup / Yeat coupling), VALIDATION.md sign-off

**Phase-kickoff resolves:** Open Question O-1 (format prevalence — `SELECT format, COUNT(*) FROM tracks GROUP BY format` to lock audio-format strategy per PITFALLS A-1). RESOLVED: mp3=54.4%, m4a=28.0%, flac=17.6%, wav=0.1%; zero OGG/Opus — whitelist covers 100%.
**UI hint**: yes

---

### Phase 30: Disk-Folder Explorer
**Goal**: Browseable filesystem hierarchy under the library root, derived from `tracks.organized_path` (no disk walking) — gives the user spatial memory for "where is this song on disk"
**Depends on**: Phase 29 (sequential per Standard execution model — explorer immediately benefits from preview as the verb)
**Requirements**: BROWSE-01, BROWSE-02, BROWSE-03, BROWSE-04, BROWSE-05, BROWSE-06, BROWSE-07
**Success Criteria** (what must be TRUE):
  1. A new sidebar entry "Folders" opens a browsable tree of the on-disk hierarchy under the library root
  2. Tree contents are derived from `SELECT DISTINCT folder_prefix FROM tracks WHERE organized_path IS NOT NULL` — no filesystem walk
  3. Tree paints in <100ms on first open at 11k+ tracks (virtualized via `react-arborist`; lazy-loaded children where deep)
  4. Selecting a folder renders that folder's tracks in a right-pane track list (reuses the existing virtualized LibraryTable)
  5. Track counts appear next to each folder name (cheap aggregate)
  6. Tree state persists across app launches — last-expanded nodes and last-selected folder restored ("first paint = right where I left it")
  7. Drive-not-mounted state surfaces a clear empty-state with the existing v1.1 reconnect affordance — no error or crash
**Plans**: 4 plans

**Wave 1** *(backend foundation — no frontend deps)*:
- [x] 30-01: Backend folder queries + organized_path index (BROWSE-02, BROWSE-03, BROWSE-05)
- [x] 30-02: NFC normalization at command boundary (BROWSE-02) *(depends on 30-01)*

**Wave 2** *(frontend — blocked on Wave 1 completion)*:
- [x] 30-03: FolderTree component, FoldersPage route, Sidebar entry (BROWSE-01, BROWSE-02, BROWSE-03, BROWSE-04, BROWSE-05, BROWSE-06)
- [x] 30-04: Drive disconnect UX + sidebar disconnect indicator (BROWSE-06, BROWSE-07)

Cross-cutting constraints:
- D-22: Zero reads of track_tags, albums, variant_of; zero writes; schema stays v17
- D-21: Every listen()/addEventListener() has cleanup
- D-10: Spacebar NOT hijacked — PlaybackContext owns spacebar at window level

**Phase-kickoff resolves:** Open Question O-2 (NFC vs NFD normalization — verify `🔔 yëat typa shi` round-trip JS↔Rust per PITFALLS T-5).
**UI hint**: yes

---

### Phase 31: Native MLM Playlists
**Goal**: User-curated, local-only playlists with create/rename/delete + drag-drop add + within-playlist reorder + remove-from-playlist (≠ delete from library) — the curation surface that answers the user's "no structure inside it" complaint
**Depends on**: Phase 30 (sequential per Standard execution model — Phase 30 provides "drag from folder tree to playlist" as a killer gesture)
**Requirements**: PLAYLIST-01, PLAYLIST-02, PLAYLIST-03, PLAYLIST-04, PLAYLIST-05, PLAYLIST-06, PLAYLIST-07, PLAYLIST-08
**Success Criteria** (what must be TRUE):
  1. User can create a new playlist from the sidebar with a name — no source picker exposed (locked native local-only)
  2. User can rename and delete a playlist from a context menu / row action
  3. User can drag one or more tracks from the library or folder-explorer track list onto a sidebar playlist entry to add them
  4. Drag-drop into a playlist provides immediate visual feedback (drop highlight, post-drop confirmation in <2s green-highlight matching the Phase 10 pattern)
  5. User can reorder tracks within a playlist via drag-drop using the existing fractional-indexing pattern
  6. User can remove a track from a playlist without deleting it from the library
  7. Variant tracks (`AftërLyfe` and `AftërLyfe [U]` of the same title) are stored as distinct playlist entries — UFO toggle is display-only and never rewrites playlist membership
  8. Playlists created in v1.4 are constrained to the local-native shape (`source_id = NULL`, `external_id = NULL`, `is_smart = false`, `is_liked = false`, `category = 'regular'`) — enforced backend-side
**Plans**: TBD
**Phase-kickoff resolves:** Open Question O-3 (`PRAGMA foreign_keys = ON` audit at every `Connection::open` call site per PITFALLS P-3/P-4).
**UI hint**: yes

---

### Phase 32: Bulk-Add to Playlist
**Goal**: Extend Phase 19's multi-select batch bar with an "Add to playlist…" action that wires to the new native playlists from Phase 31
**Depends on**: Phase 31
**Requirements**: BULK-01, BULK-02, BULK-03, BULK-04
**Success Criteria** (what must be TRUE):
  1. The Phase 19 multi-select batch bar gains an "Add to playlist…" action when ≥1 track is selected
  2. Selecting "Add to playlist…" shows the user's playlists (recent-first); selecting one adds the entire selection in one transaction
  3. Bulk-add of 1000+ tracks completes inside a single backend transaction with progress feedback if the op exceeds 500ms
  4. Duplicate tracks added to the same playlist follow `INSERT OR IGNORE` semantics — no error, no duplicates
**Plans**: TBD
**UI hint**: yes

---

### Phase 33: Polish & E2E
**Goal**: Solar pass across all new surfaces, empty/error states everywhere, end-to-end test of the daily-driver loop
**Depends on**: Phase 32
**Requirements**: POLISH-01, POLISH-02, POLISH-03, POLISH-04
**Success Criteria** (what must be TRUE):
  1. All new surfaces (folder explorer, mini-bar, playlist sidebar, drag-drop affordances) honor the Solar design contract (`.planning/research/solar-design/CONTRACT.md`) — colors, density, font stack, motion
  2. All new surfaces have empty-state and error-state visuals — no blank panes, no silent toasts
  3. E2E tests cover the daily-driver loop end-to-end: open app → browse folder → click track → spacebar plays → drag selection into playlist → verify in playlist detail
  4. All new `useEffect` hooks that register Tauri event listeners include cleanup returns (PITFALLS TR-1 grep audit gate passes clean)
**Plans**: TBD
**UI hint**: yes

### Phase 34: Rework Download Orchestrator (drop AAC into artist dirs, retire staging)

**Goal:** Make `<sanitized_artist>/<filename>` the canonical home for downloaded tracks, matching the import-scan convention. Migrate the 103 existing `.mlm_staging/transcoded/` tracks into proper artist dirs and tighten `tauri.conf.json` to remove the interim `.mlm_staging/**` scope entries (commit `27d7e21`).
**Driver:** Phase 29 surfaced that `.mlm_staging/` paths were unreachable via the Tauri asset protocol because glob `**` does not traverse dot-directories. The interim scope fix unblocks playback today, but staging-as-canonical-home is the underlying smell — downloads should land in the same structure as imports.
**Depends on:** Phase 29 (asset-protocol consumer surfaced the bug); does NOT block Phase 30/31/32/33
**Plans:** 0 plans (TBD — likely 3-4: path builder + sanitization, orchestrator rewire, one-shot migration command, scope tightening)
**Requirements**: TBD (DL-?? family)

**Anchor refs:**
- `src-tauri/src/download/orchestrator.rs:278-326` — current transcode terminal (writes to `aac_dir`)
- `src-tauri/src/commands/download.rs:124-148` — persists `organized_path` from orchestrator output
- `src-tauri/src/metadata/sanitize.rs` — existing artist/filename sanitization to reuse
- `src-tauri/tauri.conf.json:26-32` — scope to tighten after migration
- DB query: `SELECT COUNT(*) FROM tracks WHERE organized_path LIKE '.mlm_staging/%'` → 103 (as of 2026-05-07)

**Success criteria** (what must be TRUE):
1. New downloads land at `<sanitized_artist>/<filename>` under library root, not under `.mlm_staging/`
2. The 103 existing staging-rooted tracks have been moved to the new structure with their `organized_path`, `format`, `bitrate` rows updated atomically
3. `tauri.conf.json` asset protocol scope no longer references `.mlm_staging/**`
4. No regression on import-scan flow (existing artist-dir tracks unaffected)
5. Filename collisions are handled deterministically (overwrite vs. rename strategy is decided and documented)

Plans:
- [ ] TBD (run `/gsd-plan-phase 34` to break down)

---


### Phase 35: Waveform-Verbesserungen (Bug-Fix lange Lieder, DJ-Farbkodierung, Trackpad-Scroll)

**Goal:** Drei gezielte Verbesserungen an WaveformView: adaptive Bin-Berechnung fuer lange Tracks (2 bins/sec, Min 200, Max 14.400), DJ-Farbkodierung der Wellenformbalken per Amplitude (Blau → Cyan → Gelb → Orange-Rot), horizontales Scrollen per 2-Finger-Trackpad mit korrekter Seek-Koordinatenberechnung nach dem Scrollen.
**Depends on:** Phase 5 (v2.0 Playback-Pipeline)
**Requirements**: WF-01, WF-02, WF-03, WF-04
**Plans:** 2/2 plans complete

**Success criteria** (what must be TRUE):
1. extractWaveform() benutzt 2 bins/sec (floor 200, cap 14.400) statt hardcoded 200
2. WaveformView-Balken zeigen DJ-Farbramp (Stahl-Blau bei leise → Orange-Rot bei laut) statt flachem .mlmAccent/.mlmEdge
3. Waveform kann mit 2-Finger-Trackpad horizontal gescrollt werden
4. Seek nach dem Scrollen landet an der korrekten Track-Position
5. PlayerBar Zeitstempel-Labels haben frame(width: 44) fuer 3-stellige Minuten
6. swift test gruen (alle WaveformTests)

Plans:
- [x] 35-01-PLAN.md — WaveformHelpers-Modul + adaptive Bins + DJ-Farben + PlayerBar-Fix
- [x] 35-02-PLAN.md — ScrollView-Wrap + scroll-korrigiertes Seek (Wave 2, depends on 35-01)

---


### Phase 36: Playlists (v2.0 macOS Native)

**Goal:** SwiftUI-Playlist-Surface — `PlaylistsView` (Grid aus Playlist-Cards), `PlaylistDetailView` (sortierbare Track-Liste), Drag-and-Drop-Reorder mit Fractional Positioning, Create/Delete/Pin, Add/Remove-Tracks via Context-Menü-Integration aus Phase 3, Playlist-Import (M3U, Spotify JSON). Entspricht Phase 6 in `macos-app/PLAN.md`.
**Depends on:** Phase 3 (v2.0 Library Browser — Context-Menü), Phase 1 (v2.0 Data Layer — `PlaylistRepository`)
**Milestone:** v2.0 macOS Native
**Requirements**: PLV2-01..PLV2-07 (Playlist-Surface) — to be locked in CONTEXT/SPEC
**Plans:** 4/4 plans executed — PHASE COMPLETE (2026-05-13)

**Anchor refs:**
- `macos-app/PLAN.md` §"Phase 6 — Playlists" — Scope definiert
- `macos-app/MLM/Data/Repositories/PlaylistRepository.swift` — Persistenz-Layer (Phase 1)
- `macos-app/MLM/Views/Library/TrackContextMenu.swift:1` — "Add to Playlist" Stub (Phase 3)
- v1.0 Phase 4 `04-playlist-management/04-CONTEXT.md` — Fractional-Indexing-Entscheidungen aus Tauri-Version, als Pattern wiederverwendbar

**Success criteria** (what must be TRUE):
1. PlaylistsView zeigt Grid aus Cards (Cover/Titel/Trackzahl), Create-Button funktioniert
2. PlaylistDetailView listet Tracks mit Drag-Reorder (Fractional Positioning, kein O(N)-Renumbering)
3. Create/Delete/Pin funktionieren mit Confirmation-UX wo nötig (Solar/native macOS-Look)
4. TrackContextMenu „Add to Playlist…" ist live verdrahtet (ersetzt Phase-3-Placeholder)
5. M3U-Import + Spotify-JSON-Import landen als native Playlists in der DB
6. swift test grün (PlaylistRepositoryTests + neue View-Tests wo sinnvoll)

Plans:
- [x] 36-01-PLAN.md — Schema v20 (cover_is_custom) + Model + Repository setter + moveTrack notification fix
- [x] 36-02-PLAN.md — Cover services (ArtworkExtractor + GradientPalette + MosaicCompositor + PlaylistCoverService) + DI wiring + tests
- [x] 36-03-PLAN.md — PlaylistCard cover render + drop-target + Reset menu; PlaylistViewModel 8-pin pre-check + hint banner in PlaylistsView
- [x] 36-04-PLAN.md — Sidebar PinnedPlaylistsDisclosure + ContentView .playlistDetail(Int64) routing + PlaylistDetailViewLoader

---


### Phase 37: Album-Art-Pipeline durchziehen (Import-Trigger + UI-Anzeige + ffmpeg-Pfad)

**Goal:** Album-Art systematisch durch MLM ziehen — beim Import automatisch extrahieren (statt nur manuell via Settings → Maintenance), in LibraryTable + TrackDetail + MiniPlayer anzeigen, und Phase-36-Cover-Pipeline auf den bewährten ffmpeg-Pfad umstellen (statt AVFoundation `commonMetadata`, das bei FLAC/manchen MP3s inkonsistent ist).

**Driver:** Phase-36-UAT zeigt: Auto-Mosaic + Gradient-Fallback laufen visuell durch (Notification-Bug `780a0cc` gefixt), aber selbst wenn der Service triggert findet AVFoundation in vielen User-Files keine Embedded-Artwork. Das ist nicht Phase-36-spezifisch — Album-Art ist in MLM bisher nirgends in der UI sichtbar, `ArtworkService.swift` (mit funktionierendem ffmpeg-Pfad) läuft nur manuell, niemand triggert ihn beim Import. Phase 36 hat das Problem nur sichtbar gemacht.

**Depends on:** Phase 36 (Playlist-Cover-Service bleibt als Konsument); Phase 4 (Import-Pipeline)
**Milestone:** v2.0 macOS Native

**Anchor refs:**
- `macos-app/MLM/Services/Analysis/ArtworkService.swift` — bewährter ffmpeg-Subprocess-Pfad + MusicBrainz-Fallback (existiert, läuft nur on-demand)
- `macos-app/MLM/Services/MetadataExtractor.swift` — Import-Pipeline (extrahiert Tags, **nicht** Artwork — Gap)
- `macos-app/MLM/Services/Playlists/ArtworkExtractor.swift` — Phase-36 AVFoundation-Wrapper (umstellen auf ffmpeg)
- `macos-app/MLM/Views/Settings/MaintenanceView.swift:175` — bisheriger einziger ArtworkService-Trigger
- `macos-app/MLM/Database/DatabaseManager.swift:319` — `track_artwork.artwork_path` Schema-Spalte (schon da, nicht genutzt in UI)

**Success criteria** (what must be TRUE):
1. Import-Pipeline triggert `ArtworkService.fetchArtwork` automatisch nach jedem Track-Insert (Background-Queue, blockt UI nicht)
2. `LibraryTable` zeigt Album-Cover-Thumbnail in der Title-Spalte (16-24pt, Solar-Fallback wenn nicht vorhanden)
3. `TrackDetailView` zeigt großes Cover im Header (128pt min, mit Loading-State)
4. `MiniPlayer` zeigt Track-Cover als 36pt Thumbnail
5. `PlaylistCoverService.ArtworkExtractor` ruft `ArtworkService.extractEmbeddedArtwork` (ffmpeg-Pfad) statt AVFoundation `commonMetadata` — Mosaic-Cover funktioniert für FLAC + MP3 + AAC zuverlässig
6. Settings-Maintenance "Fetch Artwork" funktioniert weiter (rückwärts-kompatibel, plus „Fetch from MusicBrainz" als separate Option)
7. swift test grün (neue Tests: Import→Artwork-Pipeline, LibraryTable-Cover-Render, ArtworkExtractor-ffmpeg-Pfad)

**Out of scope:**
- MusicBrainz-Bulk-Fetch beim Import (Rate-Limit blockt) — bleibt Settings-Maintenance-only
- Cover-Editor / Crop-UI für Track-Artwork (Phase 36 deckt nur Playlist-Cover via Drop)
- Live-Lyrics oder andere Metadata-Bereicherung — eigene Phase

**Plans:** TBD (likely 4: Import-Trigger + ffmpeg-Umbau in ArtworkExtractor + UI-Anzeige Library/Detail/MiniPlayer + Tests)

Plans:
- [ ] TBD (run `/gsd-plan-phase 37` to break down)

---

## v1.4 Progress Table

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 28. Asset-Protocol Setup | v1.4 | 0/1 | Not started | - |
| 29. Inline Preview / Spacebar Playback | v1.4 | 1/4 | In Progress|  |
| 30. Disk-Folder Explorer | v1.4 | 4/4 | Complete | 2026-05-07 |
| 31. Native MLM Playlists | v1.4 | 0/TBD | Not started | - |
| 32. Bulk-Add to Playlist | v1.4 | 0/TBD | Not started | - |
| 33. Polish & E2E | v1.4 | 0/TBD | Not started | - |
| 34. Rework Download Orchestrator | v1.4 | 0/TBD | Not started | - |
| 35. Waveform-Verbesserungen | v2.0 | 2/2 | Complete    | 2026-05-12 |
| 36. Playlists (v2.0) | v2.0 | 4/4 | Complete | 2026-05-13 |
| 37. Album-Art Pipeline | v2.0 | 0/TBD | Not started | - |
