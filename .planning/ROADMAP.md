# Roadmap: MusicLibraryManager

## Overview

This roadmap transforms the unreliable streaming2ipod system into a production-grade music library manager that aggregates from Spotify, Apple Music, SoundCloud, and local files. The journey starts with atomic file operations and metadata foundations (Phase 1), proves download infrastructure with single-source reliability (Phase 2), expands to multi-source aggregation with deduplication (Phase 3), implements playlist management with order preservation (Phase 4), delivers device sync to Rockbox iPod (Phase 5), wraps everything in a PySide6 desktop UI (Phase 6), and concludes with enhancements for quality and usability (Phase 7).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Library Foundation** - Database schema, atomic file operations, local import, search
- [ ] **Phase 2: Download Infrastructure** - Single-source pipeline with dabmusic.xyz and YouTube fallback
- [ ] **Phase 3: Multi-Source Aggregation** - Spotify, Apple Music, SoundCloud API integration with deduplication
- [ ] **Phase 4: Playlist Management** - Create, edit, reorder playlists with order preservation
- [ ] **Phase 5: Device Sync** - Incremental sync to Rockbox iPod with M3U8 playlist generation
- [ ] **Phase 6: Desktop UI** - PySide6 dashboard with library browser and real-time progress
- [ ] **Phase 7: Enhancements** - Acoustic fingerprinting, artwork, ReplayGain normalization

## Phase Details

### Phase 1: Library Foundation
**Goal**: Establish reliable foundation with atomic file operations, metadata management, and local library import

**Depends on**: Nothing (first phase)

**Requirements**: LIB-01, LIB-02, LIB-03, LIB-04, LIB-05, LIB-06, DL-05, DL-06

**Success Criteria** (what must be TRUE):
  1. User can import existing local music files from a directory into the library
  2. System stores music files in Artist/Album/Track directory structure with separate SoundCloud folder
  3. User can search library by artist, album, or title and get results instantly
  4. System detects duplicate tracks via metadata matching and alerts user
  5. File operations are atomic (no corrupt files from interrupted operations)

**Plans**: TBD

Plans:
- [ ] 01-01: TBD during planning
- [ ] 01-02: TBD during planning
- [ ] 01-03: TBD during planning

### Phase 2: Download Infrastructure
**Goal**: Prove download pipeline works reliably with single-source downloads before multi-source complexity

**Depends on**: Phase 1

**Requirements**: DL-01, DL-03, DL-04, DL-07

**Success Criteria** (what must be TRUE):
  1. System downloads FLAC files from dabmusic.xyz for a given track query
  2. System falls back to YouTube when track not found on dabmusic.xyz
  3. System transcodes FLAC to 248kbps AAC M4A with verified quality
  4. Download operations can be interrupted and resumed without re-downloading completed files
  5. System handles API rate limits gracefully with backoff and retry logic

**Plans**: TBD

Plans:
- [ ] 02-01: TBD during planning
- [ ] 02-02: TBD during planning
- [ ] 02-03: TBD during planning

### Phase 3: Multi-Source Aggregation
**Goal**: Integrate Spotify, Apple Music, and SoundCloud APIs with deduplication across sources

**Depends on**: Phase 2

**Requirements**: SRC-01, SRC-02, SRC-03, SRC-04, DL-02

**Success Criteria** (what must be TRUE):
  1. User can fetch liked songs, saved albums, and playlists from Spotify API
  2. User can fetch likes and playlists from SoundCloud API with Go+ quality
  3. User can refresh source data on demand to pull new additions
  4. System tracks which tracks came from which source (many-to-many relationship)
  5. System detects duplicate tracks across sources and prevents duplicate downloads

**Plans**: TBD

Plans:
- [ ] 03-01: TBD during planning
- [ ] 03-02: TBD during planning
- [ ] 03-03: TBD during planning

### Phase 4: Playlist Management
**Goal**: User can create, edit, and reorder playlists with order preservation guaranteed

**Depends on**: Phase 3

**Requirements**: PL-01, PL-02, PL-03, PL-04, PL-05, PL-06

**Success Criteria** (what must be TRUE):
  1. User can create new playlists and add library tracks to them
  2. User can add and remove tracks from existing playlists
  3. User can reorder tracks within playlists via drag-and-drop
  4. Playlist order is preserved during all operations (download, transcode, sync)
  5. Liked/Favorites playlists maintain date-added descending order automatically
  6. User can view playlist contents and search within specific playlists

**Plans**: TBD

Plans:
- [ ] 04-01: TBD during planning
- [ ] 04-02: TBD during planning

### Phase 5: Device Sync
**Goal**: Incremental sync to Rockbox iPod with M3U8 playlists and filesystem copy

**Depends on**: Phase 4

**Requirements**: SYNC-01, SYNC-02, SYNC-03, SYNC-04, SYNC-05

**Success Criteria** (what must be TRUE):
  1. System copies transcoded AAC files to connected Rockbox iPod via filesystem
  2. System generates M3U8 playlists with Rockbox-compatible relative paths
  3. Sync is incremental (only new and changed files transfer, not entire library)
  4. System tracks sync state per device and shows what's synced vs pending
  5. User can preview what will sync before syncing (dry run mode)

**Plans**: TBD

Plans:
- [ ] 05-01: TBD during planning
- [ ] 05-02: TBD during planning
- [ ] 05-03: TBD during planning

### Phase 6: Desktop UI
**Goal**: Cross-platform PySide6 dashboard with library browser, progress tracking, and sync controls

**Depends on**: Phase 5

**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05

**Success Criteria** (what must be TRUE):
  1. Dashboard shows library status (total tracks, storage size, recent additions, sync state)
  2. Dashboard shows real-time progress during download, transcode, and sync operations
  3. User can trigger sync operations from dashboard with visual feedback
  4. User can view and edit playlists visually with drag-and-drop reordering
  5. UI runs on macOS, Windows, and Linux with native look and feel

**Plans**: TBD

Plans:
- [ ] 06-01: TBD during planning
- [ ] 06-02: TBD during planning
- [ ] 06-03: TBD during planning

### Phase 7: Enhancements
**Goal**: Add quality-of-life features for better duplicate detection and audio quality

**Depends on**: Phase 6

**Requirements**: ENH-01, ENH-02, ENH-03

**Success Criteria** (what must be TRUE):
  1. System uses acoustic fingerprinting (AcoustID/Chromaprint) to identify tracks even with missing metadata
  2. System fetches and embeds high-quality album artwork automatically for tracks and albums
  3. System applies ReplayGain for consistent volume across tracks during playback

**Plans**: TBD

Plans:
- [ ] 07-01: TBD during planning
- [ ] 07-02: TBD during planning

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Library Foundation | 0/3 | Not started | - |
| 2. Download Infrastructure | 0/3 | Not started | - |
| 3. Multi-Source Aggregation | 0/3 | Not started | - |
| 4. Playlist Management | 0/2 | Not started | - |
| 5. Device Sync | 0/3 | Not started | - |
| 6. Desktop UI | 0/3 | Not started | - |
| 7. Enhancements | 0/2 | Not started | - |

---
*Last updated: 2026-02-03 after roadmap creation*
