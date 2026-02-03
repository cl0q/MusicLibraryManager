# MusicLibraryManager

## What This Is

A unified music library manager that aggregates music from streaming services (Spotify, Apple Music, SoundCloud) and local files into a single owned collection. Downloads high-fidelity files, archives originals, transcodes for portable devices, and syncs to Rockbox'd iPod and other players. Built for someone who wants to own their music in high quality while still using streaming services for discovery.

## Core Value

Like a song anywhere (Spotify, Apple Music, SoundCloud) and it reliably ends up in your owned library and on your devices in high quality — with playlist order preserved.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Fetch liked songs, saved albums, and playlists from Spotify API
- [ ] Fetch library and playlists from Apple Music API
- [ ] Fetch likes and playlists from SoundCloud API
- [ ] Import existing local music files into library
- [ ] Download tracks from dabmusic.xyz (FLAC, quality 27)
- [ ] Download tracks from SoundCloud via scdl (248kbps AAC with Go+ subscription)
- [ ] Fall back to YouTube when tracks not found on primary sources
- [ ] Archive original files in Artist/Album/Track structure
- [ ] Store SoundCloud content in dedicated folder (different nature: singles, DJ mixes)
- [ ] Transcode FLACs to 248kbps AAC M4A for devices
- [ ] Preserve playlist order during all operations
- [ ] Support "date added descending" sort for Liked/Favorites playlists
- [ ] Generate M3U8 playlists for Rockbox compatibility
- [ ] Sync transcoded files to devices via filesystem copy
- [ ] Incremental sync — only process new/changed files
- [ ] View playlist contents and search within them
- [ ] Create new playlists from library
- [ ] Edit playlist membership (add/remove tracks)
- [ ] Reorder tracks within playlists
- [ ] Dashboard UI showing library status and sync progress
- [ ] Transparent progress reporting — show what's happening

### Out of Scope

- Music playback — this is a library manager, not a player
- Mobile app — desktop only for now
- Direct iTunes integration — using Rockbox bypasses this
- Streaming from the library — files are for offline use on devices
- Automatic background sync — manual trigger, runs weekly-ish

## Context

**Existing reference implementation:** A working but unreliable system exists at `./streaming2ipod/` (symlinked). It contains:
- dabmusic.xyz API integration (auth, search, download FLAC)
- SoundCloud download via scdl with Go+ auth token
- FLAC-to-AAC transcoding via ffmpeg
- M3U8 playlist generation with fuzzy matching
- Orchestrator attempting to tie it all together

The old system's problems:
- Unreliable syncing — "gambling" whether runs work
- Loose coupling — scripts hanging together, not a cohesive system
- Lack of transparency — unclear what's happening during runs
- Hasn't been used in months due to friction

**Target devices:**
- iPod Video 5 (32MB RAM, runs Rockbox, can't decode FLAC efficiently)
- Other MP3 players
- All use same transcoded format: 248kbps AAC M4A

**Storage:**
- External drive (Lexxar) for main library
- Artist/Album/Track hierarchy for traditional albums
- Special folder for SoundCloud content

## Constraints

- **iPod RAM**: 32MB limit means FLACs must be transcoded to AAC for playback
- **Audio quality**: 248kbps AAC target for all device copies (matches SoundCloud Go+ quality)
- **Rockbox**: Sync is filesystem copy + M3U8 playlists, no iTunes database
- **APIs**: dabmusic.xyz requires account credentials, SoundCloud needs Go+ for high quality
- **Apple Music**: Requires MusicKit API and Apple Developer credentials
- **Cross-platform**: Would like the UI to work on macOS, Windows, Linux eventually

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Rust for core logic | Performance, reliability, single binary distribution | ✓ Decided 2026-02-03 |
| Tauri for UI | Web UI flexibility + Rust backend, small binaries, native webview | ✓ Decided 2026-02-03 |
| 248kbps AAC target | Matches SoundCloud Go+ quality, good balance of size/quality | — Pending |
| Rockbox for iPod | Enables direct filesystem sync, avoids iTunes complexity | — Pending |
| YouTube as fallback | Acceptable quality tradeoff for tracks not on dabmusic | — Pending |

## Tech Stack

**Backend (Rust):**
- `rusqlite` — SQLite database
- `lofty` — Audio metadata extraction (like Mutagen)
- `tantivy` — Full-text search (like Whoosh)
- `strsim` or `fuzzy-matcher` — Fuzzy string matching
- `indicatif` — Progress bars
- `tokio` — Async runtime
- `serde` — Serialization

**Frontend (Tauri + Web):**
- Tauri v2 — Desktop app framework
- TypeScript + React — UI components
- Tailwind CSS — Styling
- shadcn/ui — Component library (clean, modern look)

**External tools (invoked via CLI):**
- `ffmpeg` — Audio transcoding
- `yt-dlp` — YouTube downloads

---
*Last updated: 2026-02-03 after Rust+Tauri decision*
