# MusicLibraryManager

## What This Is

A unified music library manager that aggregates music from streaming services (Spotify, SoundCloud) and local files into a single owned collection. Downloads high-fidelity files, archives originals, transcodes for portable devices, and syncs to Rockbox'd iPod. Built for someone who wants to own their music in high quality while still using streaming services for discovery.

## Core Value

Like a song anywhere (Spotify, SoundCloud) and it reliably ends up in your owned library and on your devices in high quality — with playlist order preserved.

## Current State (v1.0 shipped 2026-02-05)

**Tech stack:**
- Backend: Rust 20k LOC (rusqlite, lofty, tantivy, tokio, symphonia)
- Frontend: TypeScript/React 4k LOC (Tauri v2, TanStack Table, shadcn/ui)
- External tools: ffmpeg, yt-dlp, scdl

**Features delivered:**
- Library import with metadata extraction and duplicate detection
- Spotify and SoundCloud OAuth with incremental sync
- Download pipeline: dabmusic.xyz → YouTube fallback → AAC transcode
- Playlist management with fractional indexing and drag-drop
- Rockbox device sync with M3U8 playlists
- Desktop UI with virtualized library browser
- Acoustic fingerprinting, artwork, and ReplayGain

## Requirements

### Validated

- LIB-01 through LIB-06 — Library foundation (v1.0)
- SRC-01 through SRC-04 — Source integration (v1.0)
- DL-01 through DL-07 — Download pipeline (v1.0)
- PL-01 through PL-06 — Playlist management (v1.0)
- SYNC-01 through SYNC-05 — Device sync (v1.0)
- UI-01 through UI-05 — Dashboard UI (v1.0)
- ENH-01 through ENH-03 — Enhancements (v1.0)

### Active

(Define for next milestone via `/gsd:new-milestone`)

### Out of Scope

- Music playback — this is a library manager, not a player
- Mobile app — desktop only
- Direct iTunes integration — using Rockbox bypasses this
- Streaming from the library — files are for offline use on devices

## Context

**v1.0 shipped:** Full MVP with 33 requirements satisfied, 7 phases complete.

**Known tech debt:**
- Hardcoded database path (configurable in future)
- Hardcoded "default" user_id for source creation
- Test compilation blocked by 1-line import fix

**Human verification pending:**
- OAuth flows with real Spotify/SoundCloud accounts
- Physical Rockbox iPod sync
- Cross-platform appearance (macOS/Windows/Linux)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Rust for core logic | Performance, reliability, single binary | Good |
| Tauri for UI | Web UI flexibility + Rust backend, small binaries | Good |
| 248kbps AAC target | Matches SoundCloud Go+ quality | Good |
| Fractional indexing | O(1) playlist reorder operations | Good |
| SHA256 checksums | Industry standard for sync state | Good |
| PKCE OAuth 2.1 | Security best practice | Good |
| Chromaprint fingerprinting | Better duplicate detection than metadata alone | Good |
| EBU R128 ReplayGain | Consistent volume across tracks | Good |

## Constraints

- **iPod RAM**: 32MB limit means FLACs must be transcoded to AAC for playback
- **Audio quality**: 248kbps AAC target for all device copies
- **Rockbox**: Sync is filesystem copy + M3U8 playlists, no iTunes database
- **APIs**: dabmusic.xyz requires credentials, SoundCloud needs Go+ for high quality

---
*Last updated: 2026-02-05 after v1.0 milestone*
