# Roadmap: MusicLibraryManager

## Milestones

- ✅ **v1.0 MVP** - Phases 1-7 (shipped 2026-02-05)
- 🚧 **v1.1 Library Foundation & UX Polish** - Phases 8-11 (in progress)

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

### 🚧 v1.1 Library Foundation & UX Polish (In Progress)

**Milestone Goal:** Make the local library real — files live on external SSD, remote songs are separated into a staging area, and the UI feels responsive.

#### Phase 8: Library Configuration & Drive Detection
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

#### Phase 9: Library/Remote Separation
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
- [ ] 09-01-PLAN.md — Backend query filtering (schema v7, library/remote queries, count command)
- [ ] 09-02-PLAN.md — Sidebar Remote nav item with badge count and event listeners
- [ ] 09-03-PLAN.md — Route-based view switching for /library and /remote
- [ ] 09-04-PLAN.md — Human verification of library/remote separation

#### Phase 10: Track Actions & More Info
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

#### Phase 11: Download Flow & UX Polish
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
- [ ] 11-01-PLAN.md — Backend download with progress streaming and download_status updates
- [ ] 11-02-PLAN.md — Frontend download UI with real-time progress and auto-refresh
- [ ] 11-03-PLAN.md — Human verification of download flow and context menu responsiveness

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

### Phase 11.1: Functional & E2E Test Harness (INSERTED)

**Goal:** Regression safety net — backend integration tests for download pipeline and library/remote filtering, frontend component rendering tests for key UI components
**Requirements**: (no specific IDs — inserted phase for regression coverage)
**Depends on:** Phase 11
**Plans:** 3/3 plans complete

Plans:
- [ ] 11.1-01-PLAN.md — Backend test infrastructure: tests/common helpers, JSON API fixtures, audio fixtures, fix failing DAB test
- [ ] 11.1-02-PLAN.md — Backend integration tests: library/remote filtering (6 tests) and download pipeline DB transitions (5 tests)
- [ ] 11.1-03-PLAN.md — Frontend test setup: Vitest + @testing-library/react + 4 component rendering test files

### Phase 12: Import External Playlists

**Goal:** User can import M3U/M3U8 and Spotify JSON playlist files into the music library, with fuzzy track matching and a match preview before confirming playlist creation
**Requirements**: IMP-01, IMP-02, IMP-03, IMP-04
**Depends on:** Phase 11
**Plans:** 3/3 plans complete

Plans:
- [ ] 12-01-PLAN.md — Backend: playlist_importer module (M3U + JSON parsers, fuzzy matching, import command)
- [ ] 12-02-PLAN.md — Frontend: ImportModal + MatchPreview components, Import button in PlaylistList
- [ ] 12-03-PLAN.md — Human verification of end-to-end import flow

### Phase 12.1: Consistent Path Resolution — organized_path always relative to root (INSERTED)

**Goal:** Enforce the Phase 8-01 invariant: organized_path is always relative to library root, never absolute. Migrate 38 existing absolute paths, harden write paths with fail-fast validation, and clean up defensive read-side code.
**Requirements**: PATH-01, PATH-02, PATH-03, PATH-04
**Depends on:** Phase 12
**Plans:** 2 plans

Plans:
- [ ] 12.1-01-PLAN.md — Write-path hardening: validate_organized_path guard, fail-fast strip_prefix, schema migration v9 (strip absolute paths from 38 existing DB rows)
- [ ] 12.1-02-PLAN.md — Read-path cleanup: remove defensive absolute-path acceptance from reveal_in_file_manager and resolve_track_path; integration tests for path consistency
