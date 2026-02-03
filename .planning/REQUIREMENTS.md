# Requirements: MusicLibraryManager

**Defined:** 2026-02-03
**Core Value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Library Foundation

- [x] **LIB-01**: User can import existing local music files into library via directory scan
- [x] **LIB-02**: System reads and writes metadata (ID3v2 for MP3/AAC, Vorbis for FLAC)
- [x] **LIB-03**: User can search library by artist, album, or title
- [x] **LIB-04**: System detects duplicate tracks via metadata matching
- [x] **LIB-05**: Files are organized in Artist/Album/Track directory structure
- [x] **LIB-06**: SoundCloud content stored in dedicated folder (different content nature)

### Source Integration

- [ ] **SRC-01**: System fetches liked songs, saved albums, and playlists from Spotify API
- [ ] **SRC-02**: System fetches likes and playlists from SoundCloud API
- [ ] **SRC-03**: User can refresh source data on demand
- [ ] **SRC-04**: System tracks which tracks came from which source

### Download Pipeline

- [x] **DL-01**: System downloads FLAC files from dabmusic.xyz for Spotify tracks
- [ ] **DL-02**: System downloads 248kbps AAC from SoundCloud via scdl with Go+ auth
- [x] **DL-03**: System falls back to YouTube when track not found on primary sources
- [x] **DL-04**: System transcodes FLAC to 248kbps AAC M4A for device copies
- [x] **DL-05**: Download operations are atomic (no partial/corrupt files)
- [x] **DL-06**: Downloads are idempotent (can resume, won't re-download completed)
- [x] **DL-07**: System handles API rate limits gracefully with backoff

### Playlist Management

- [ ] **PL-01**: User can create new playlists from library tracks
- [ ] **PL-02**: User can add/remove tracks from playlists
- [ ] **PL-03**: User can reorder tracks within playlists
- [ ] **PL-04**: System preserves playlist order during all operations
- [ ] **PL-05**: Liked/Favorites playlists maintain date-added descending order
- [ ] **PL-06**: User can view playlist contents and search within them

### Device Sync

- [ ] **SYNC-01**: System copies transcoded files to device via filesystem
- [ ] **SYNC-02**: System generates M3U8 playlists with Rockbox-compatible paths
- [ ] **SYNC-03**: Sync is incremental (only new/changed files transfer)
- [ ] **SYNC-04**: System tracks sync state per device
- [ ] **SYNC-05**: User can see what will sync before syncing (dry run)

### Dashboard UI

- [ ] **UI-01**: Dashboard shows library status (size, recent additions, sync state)
- [ ] **UI-02**: Dashboard shows real-time progress during download/transcode/sync
- [ ] **UI-03**: User can trigger sync operations from dashboard
- [ ] **UI-04**: User can view and edit playlists visually in dashboard
- [ ] **UI-05**: UI is cross-platform (macOS, Windows, Linux)

### Enhancements

- [ ] **ENH-01**: System uses acoustic fingerprinting (AcoustID/Chromaprint) for better duplicate detection
- [ ] **ENH-02**: System fetches and embeds album artwork automatically
- [ ] **ENH-03**: System applies ReplayGain for consistent volume across tracks

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Additional Sources

- **SRC-V2-01**: System fetches library and playlists from Apple Music API
- **SRC-V2-02**: System fetches from YouTube Music playlists
- **SRC-V2-03**: System fetches from Tidal library

### Advanced Features

- **ADV-01**: Smart playlists with rule-based auto-generation
- **ADV-02**: Lyrics fetching and embedding
- **ADV-03**: Multiple device profiles with different sync settings
- **ADV-04**: Background/scheduled sync

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Music playback | This is a library manager, not a player. Rockbox handles playback. |
| Mobile app | Desktop only for v1. Dashboard is web-based, works on mobile browsers. |
| Streaming from library | Files are for offline use on devices, not remote streaming. |
| Direct iTunes integration | Using Rockbox bypasses iTunes complexity. |
| CD ripping | Niche in 2026, dedicated tools exist (Picard). |
| Video management | Completely different problem space (Plex/Jellyfin). |
| Social features | Users have social in Spotify/Apple Music already. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| LIB-01 | Phase 1 | Complete |
| LIB-02 | Phase 1 | Complete |
| LIB-03 | Phase 1 | Complete |
| LIB-04 | Phase 1 | Complete |
| LIB-05 | Phase 1 | Complete |
| LIB-06 | Phase 1 | Complete |
| DL-05 | Phase 1 | Complete |
| DL-06 | Phase 1 | Complete |
| DL-01 | Phase 2 | Pending |
| DL-03 | Phase 2 | Pending |
| DL-04 | Phase 2 | Pending |
| DL-07 | Phase 2 | Pending |
| SRC-01 | Phase 3 | Pending |
| SRC-02 | Phase 3 | Pending |
| SRC-03 | Phase 3 | Pending |
| SRC-04 | Phase 3 | Pending |
| DL-02 | Phase 3 | Pending |
| PL-01 | Phase 4 | Pending |
| PL-02 | Phase 4 | Pending |
| PL-03 | Phase 4 | Pending |
| PL-04 | Phase 4 | Pending |
| PL-05 | Phase 4 | Pending |
| PL-06 | Phase 4 | Pending |
| SYNC-01 | Phase 5 | Pending |
| SYNC-02 | Phase 5 | Pending |
| SYNC-03 | Phase 5 | Pending |
| SYNC-04 | Phase 5 | Pending |
| SYNC-05 | Phase 5 | Pending |
| UI-01 | Phase 6 | Pending |
| UI-02 | Phase 6 | Pending |
| UI-03 | Phase 6 | Pending |
| UI-04 | Phase 6 | Pending |
| UI-05 | Phase 6 | Pending |
| ENH-01 | Phase 7 | Pending |
| ENH-02 | Phase 7 | Pending |
| ENH-03 | Phase 7 | Pending |

**Coverage:**
- v1 requirements: 33 total
- Mapped to phases: 33
- Unmapped: 0

---
*Requirements defined: 2026-02-03*
*Last updated: 2026-02-03 after Phase 1 completion*
