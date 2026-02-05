# Requirements: MusicLibraryManager

**Defined:** 2026-02-05
**Core Value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality

## v1.1 Requirements

Requirements for milestone v1.1: Library Foundation & UX Polish.

### Library Configuration

- [ ] **LCFG-01**: User can configure a directory as the library location
- [ ] **LCFG-02**: App detects when library drive is not connected
- [ ] **LCFG-03**: App blocks Library tab when drive not connected (shows message)
- [ ] **LCFG-04**: App allows Remote tab access when library drive not connected

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
| LCFG-01 | — | Pending |
| LCFG-02 | — | Pending |
| LCFG-03 | — | Pending |
| LCFG-04 | — | Pending |
| REM-01 | — | Pending |
| REM-02 | — | Pending |
| REM-03 | — | Pending |
| REM-04 | — | Pending |
| LVIEW-01 | — | Pending |
| LVIEW-02 | — | Pending |
| LVIEW-03 | — | Pending |
| ACT-01 | — | Pending |
| ACT-02 | — | Pending |
| ACT-03 | — | Pending |
| ACT-04 | — | Pending |
| DL-01 | — | Pending |
| DL-02 | — | Pending |
| DL-03 | — | Pending |
| UX-01 | — | Pending |

**Coverage:**
- v1.1 requirements: 19 total
- Mapped to phases: 0
- Unmapped: 19

---
*Requirements defined: 2026-02-05*
*Last updated: 2026-02-05 after initial definition*
