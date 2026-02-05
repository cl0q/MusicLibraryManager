# Roadmap: MusicLibraryManager

## Overview

This roadmap transforms the unreliable streaming2ipod system into a production-grade music library manager that aggregates from Spotify, Apple Music, SoundCloud, and local files. The journey starts with atomic file operations and metadata foundations (Phase 1), proves download infrastructure with single-source reliability (Phase 2), expands to multi-source aggregation with deduplication (Phase 3), implements playlist management with order preservation (Phase 4), delivers device sync to Rockbox iPod (Phase 5), wraps everything in a PySide6 desktop UI (Phase 6), and concludes with enhancements for quality and usability (Phase 7).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Library Foundation** - Database schema, atomic file operations, local import, search
- [x] **Phase 2: Download Infrastructure** - Single-source pipeline with dabmusic.xyz and YouTube fallback
- [x] **Phase 3: Multi-Source Aggregation** - Spotify, Apple Music, SoundCloud API integration with deduplication
- [x] **Phase 4: Playlist Management** - Create, edit, reorder playlists with order preservation
- [x] **Phase 5: Device Sync** - Incremental sync to Rockbox iPod with M3U8 playlist generation
- [x] **Phase 6: Desktop UI** - Tauri + React dashboard with library browser and real-time progress
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

**Plans**: 5 plans in 3 waves

Plans:
- [x] 01-01-PLAN.md — Database schema and connection management with foreign key enforcement
- [x] 01-02-PLAN.md — Metadata extraction with lofty and path sanitization
- [x] 01-03-PLAN.md — Local file import with recursive scanning and batch transactions
- [x] 01-04-PLAN.md — Full-text search with Tantivy indexing and fuzzy matching
- [x] 01-05-PLAN.md — Duplicate detection with quality comparison

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

**Plans**: 4 plans in 3 waves

Plans:
- [x] 02-01-PLAN.md — DAB API client with exponential backoff retry logic
- [x] 02-02-PLAN.md — YouTube fallback with yt-dlp integration
- [x] 02-03-PLAN.md — Transcode pipeline with format detection and 248kbps AAC encoding
- [x] 02-04-PLAN.md — Retry queue persistence and batch orchestration

### Phase 3: Multi-Source Aggregation
**Goal**: Integrate Spotify and SoundCloud APIs with deduplication across sources

**Depends on**: Phase 2

**Requirements**: SRC-01, SRC-02, SRC-03, SRC-04, DL-02

**Success Criteria** (what must be TRUE):
  1. User can fetch liked songs, saved albums, and playlists from Spotify API
  2. User can fetch likes and playlists from SoundCloud API with Go+ quality
  3. User can refresh source data on demand to pull new additions
  4. System tracks which tracks came from which source (many-to-many relationship)
  5. System detects duplicate tracks across sources and prevents duplicate downloads

**Plans**: 6 plans in 3 waves

Plans:
- [x] 03-01-PLAN.md — Schema migration and OAuth token infrastructure
- [x] 03-02-PLAN.md — Spotify API integration with incremental sync
- [x] 03-03-PLAN.md — SoundCloud API integration with incremental sync
- [x] 03-04-PLAN.md — Duplicate detection with normalization and fuzzy matching
- [x] 03-05-PLAN.md — Tauri commands and auto-sync on startup
- [x] 03-06-PLAN.md — SoundCloud direct download via scdl CLI

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

**Plans**: 5 plans in 3 waves

Plans:
- [x] 04-01-PLAN.md — Database schema and models with fractional indexing for playlist ordering
- [x] 04-02-PLAN.md — Core playlist operations (create, add/remove tracks, reorder with O(1) updates)
- [x] 04-03-PLAN.md — Smart playlists (Recently Added, Most Played) and per-source liked playlists
- [x] 04-04-PLAN.md — Source playlist import from Spotify/SoundCloud with add-only mirroring
- [x] 04-05-PLAN.md — Tauri commands and React UI with drag-drop reordering

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

**Plans**: 5 plans in 4 waves

Plans:
- [x] 05-01-PLAN.md — Sync profile model and database schema with content resolution
- [x] 05-02-PLAN.md — Shared transcode cache with platform-aware file linking
- [x] 05-03-PLAN.md — Rockbox device detection and M3U8 playlist generation
- [x] 05-04-PLAN.md — Incremental sync orchestration with dry-run and state tracking
- [x] 05-05-PLAN.md — Tauri commands and React UI for sync management

### Phase 6: Desktop UI
**Goal**: Cross-platform desktop UI with Tauri + React for library browser, dashboard, playlists, sync, and downloads

**Depends on**: Phase 5

**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05

**Success Criteria** (what must be TRUE):
  1. Dashboard shows library status (total tracks, storage size, recent additions, sync state)
  2. Dashboard shows real-time progress during download, transcode, and sync operations
  3. User can trigger sync operations from dashboard with visual feedback
  4. User can view and edit playlists visually with drag-and-drop reordering
  5. UI runs on macOS, Windows, and Linux with native look and feel

**Plans**: 7 plans in 4 waves

Plans:
- [x] 06-01-PLAN.md — App layout, routing, sidebar navigation, status bar, toast notifications
- [x] 06-02-PLAN.md — Dashboard page with stats cards and real-time activity feed
- [x] 06-03-PLAN.md — Library browser with virtualized table, sorting, and filtering
- [x] 06-04-PLAN.md — Downloads page with queue view and real-time progress tracking
- [x] 06-05-PLAN.md — Context menus, track detail view, and component integration
- [x] 06-06-PLAN.md — Gap closure: dashboard stats (storage size, last sync time)
- [x] 06-07-PLAN.md — Gap closure: sync operations trigger and StatusBar wiring

### Phase 7: Enhancements
**Goal**: Add quality-of-life features for better duplicate detection and audio quality

**Depends on**: Phase 6

**Requirements**: ENH-01, ENH-02, ENH-03

**Success Criteria** (what must be TRUE):
  1. System uses acoustic fingerprinting (AcoustID/Chromaprint) to identify tracks even with missing metadata
  2. System fetches and embeds high-quality album artwork automatically for tracks and albums
  3. System applies ReplayGain for consistent volume across tracks during playback

**Plans**: 6 plans in 4 waves

Plans:
- [ ] 07-01-PLAN.md — Database schema v5 migration and shared audio PCM decoder
- [ ] 07-02-PLAN.md — Acoustic fingerprinting (Chromaprint + AcoustID + local comparison)
- [ ] 07-03-PLAN.md — Album artwork fetching, caching, and embedding
- [ ] 07-04-PLAN.md — ReplayGain analysis and sync pipeline integration
- [ ] 07-05-PLAN.md — Fingerprint-based dedup and review queue logic
- [ ] 07-06-PLAN.md — Tauri commands, review queue UI, and integration

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Library Foundation | 5/5 | ✓ Complete | 2026-02-03 |
| 2. Download Infrastructure | 4/4 | ✓ Complete | 2026-02-03 |
| 3. Multi-Source Aggregation | 6/6 | ✓ Complete | 2026-02-04 |
| 4. Playlist Management | 5/5 | ✓ Complete | 2026-02-04 |
| 5. Device Sync | 5/5 | ✓ Complete | 2026-02-04 |
| 6. Desktop UI | 7/7 | ✓ Complete | 2026-02-05 |
| 7. Enhancements | 0/6 | Not started | - |

---
*Last updated: 2026-02-05 after planning Phase 7 enhancements*
