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

## v1.2+ Requirements

Deferred to future milestones.

### Playlist Import

- [ ] **IMP-01**: User can select an M3U or M3U8 file and import it as a playlist
- [ ] **IMP-02**: User can select a Spotify JSON export file and import it as a playlist
- [ ] **IMP-03**: Import preview shows matched/unmatched track counts before confirming playlist creation
- [ ] **IMP-04**: Import creates playlist with matched tracks in original order

### Similar Songs Grouping

- **SIM-01**: Songs with similar titles grouped with expandable triangle
- **SIM-02**: Expanding shows child variants (original mix, remixes, etc.)

### Streaming Service Enhancements

- **STRM-01**: SoundCloud playlists sync
- **STRM-02**: Spotify JSON one-time migration from backup file

## Out of Scope

| Feature | Reason |
|---------|--------|
| Music playback | This is a library manager, not a player |
| Mobile app | Desktop only |
| Direct iTunes integration | Using Rockbox bypasses this |
| Streaming from the library | Files are for offline use on devices |

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

**Coverage:**
- v1.1 requirements: 19 total
- v1.2 requirements: 4 total (IMP-01 through IMP-04)
- Mapped to phases: 23
- Unmapped: 0

---
*Requirements defined: 2026-02-05*
*Last updated: 2026-03-29 — added IMP-01 through IMP-04 for Phase 12*
