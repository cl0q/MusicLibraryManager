# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-03)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 3 verified - ready for Phase 4 Playlist Management

## Current Position

Phase: 4 of 7 (Playlist Management)
Plan: 2 of 4 in current phase
Status: In progress
Last activity: 2026-02-04 — Completed 04-02-PLAN.md

Progress: [█████████████████████░░] 100% (17 of 17 concrete plans complete)

## Tech Stack Change

**Previous:** Python with Mutagen, Whoosh, RapidFuzz
**Current:** Rust + Tauri with lofty, tantivy, strsim

The Python implementation has been archived to `_archive/python/`.
New project structure:
- `src-tauri/` — Rust backend
- `ui/` — React + TypeScript + Tailwind frontend

## Performance Metrics

**Velocity:**
- Total plans completed: 17
- Average duration: 4m 24s
- Total execution time: 1.24 hours

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **Rust for core logic** — Performance, reliability, single binary (2026-02-03)
- **Tauri for UI** — Web UI flexibility + Rust backend, native webview (2026-02-03)
- **Single tracks table for Phase 1** — Albums/Artists normalization deferred to Phase 7 (2026-02-03)
- **&mut Connection for transactions** — rusqlite transaction() requires mutable borrow (2026-02-03)
- **Lofty ItemKey for album artist** — Cross-format extraction via ItemKey::AlbumArtist (2026-02-03)
- **Manual reserved name prefix** — windows:false + manual _CON prefix, sanitize-filename removes names otherwise (2026-02-03)
- **Continue scanning on subdir errors** — Warnings printed but doesn't halt scan (2026-02-03)
- **50-file batch size** — Matches Python implementation for incremental commits (2026-02-03)
- **Database path hardcoded for now** — `music_library.db` in cwd, Phase 6 makes configurable (2026-02-03)
- **Two-pass search** — Database LIKE for candidates, fuzzy scoring for ranking (2026-02-03)
- **Multi-strategy scoring** — Jaro-Winkler + Levenshtein + token matching for different error types (2026-02-03)
- **0.75 fuzzy threshold** — Balances precision/recall, relaxed from Python's 0.80 for Jaro-Winkler (2026-02-03)
- **Mutable connection for mark_duplicates** — with_transaction requires &mut Connection (2026-02-03)
- **AIFF in lossless formats** — Learning from Python implementation preserved (2026-02-03)
- **404 as permanent error** — No retry, enables fast YouTube fallback (2026-02-03)
- **Streaming downloads to disk** — FLAC files can be 30-50MB, avoid OOM (2026-02-03)
- **Atomic write pattern** — Temp file + rename prevents partial files (2026-02-03)
- **backoff crate for retry** — Battle-tested exponential backoff vs manual loops (2026-02-03)
- **CLI invocation over yt-dlp crate** — Direct yt-dlp CLI call avoids rusqlite version conflict (2026-02-03)
- **Ignore integration tests by default** — CI compatibility without external dependencies (2026-02-03)
- **Symphonia for codec detection** — Pure Rust, no subprocess overhead vs ffprobe (2026-02-03)
- **libfdk_aac with fallback** — Primary encoder for quality, fallback to native AAC (2026-02-03)
- **Preserve lossy <248kbps** — Skip transcoding to avoid generation loss (2026-02-03)
- **Codec-based lossless detection** — Read actual codec from headers not file extension (2026-02-03)
- **Max 3 retry attempts** — Prevents unbounded queue growth, drops permanently failing tracks (2026-02-03)
- **Sequential batch processing** — One download at a time, simpler rate limiting, easier debug (2026-02-03)
- **Atomic queue writes** — Temp file + rename prevents corruption on crash (2026-02-03)
- **Continue on download failure** — Queue failed tracks, don't block batch (2026-02-03)
- **Preserve FLAC on transcode failure** — Only retry transcode, avoid re-download (2026-02-03)
- 248kbps AAC target (matches SoundCloud Go+ quality)
- Rockbox for iPod (enables direct filesystem sync)
- YouTube as fallback (acceptable quality tradeoff)
- **Schema version 2 for Phase 3** — PRAGMA user_version tracking for safe migrations (2026-02-03)
- **Keychain service name: com.musiclibrarymanager** — Consistent identifier for keyring entries (2026-02-03)
- **Proactive token refresh 5 minutes before expiration** — Industry best practice for OAuth (2026-02-03)
- **Featuring substitution before punctuation removal** — Ampersand stripped by normalize(), must substitute first (2026-02-03)
- **70/30 title/artist weighting for similarity** — Title is more discriminating than artist for duplicate detection (2026-02-03)
- **LazyLock for compiled regex patterns** — Zero-cost after first use, thread-safe static initialization (2026-02-03)
- **OAuth 2.1 mandatory PKCE S256 for SoundCloud** — Deadline passed Oct 1 2024, always use PkceCodeChallenge::new_random_sha256() (2026-02-04)
- **external_id format soundcloud:{id}** — Consistent provenance tracking in track_sources, parallel to spotify:track:{id} (2026-02-04)
- **dotenvy for .env credential loading** — Credentials in .env file loaded at app startup, no shell env vars needed (2026-02-04)
- **SpotifyAuth/SpotifyClient separation** — Auth flow is stateless (URL + code exchange), client is stateful (token + refresh) (2026-02-04)
- **Spotify URI as original_path for phantom tracks** — Tracks from Spotify without local files use URI as path, matched later by dedup (2026-02-04)
- **Env var tests ignored in parallel** — set_var/remove_var not safe in multi-threaded test runner, mark #[ignore] (2026-02-04)
- **SoundCloudDownloader optional in orchestrator** — scdl may not be installed; orchestrator continues without SoundCloud downloads (2026-02-04)
- **SoundCloud downloads to aac_dir** — scdl produces AAC already, no FLAC staging needed (2026-02-04)
- **find_most_recent_audio_file for scdl output** — scdl filenames unpredictable; search by modification time (2026-02-04)
- **spawn_blocking + block_on for rusqlite in async Tauri commands** — Connection is !Send; spawn_blocking keeps it on one thread, block_on re-enters runtime (2026-02-04)
- **OAuthState with Mutex for PKCE verifiers** — Temporary storage between auth URL generation and code exchange command invocations (2026-02-04)
- **default_user placeholder for startup sync** — Single-user desktop app; multi-user deferred to Phase 6 (2026-02-04)
- **Schema version 3 for Phase 4** — Playlists, playlist_tracks, playlist_tags tables with fractional indexing (2026-02-04)
- **Fractional indexing for playlist ordering** — TEXT column for position eliminates rebalancing, supports unlimited reordering (2026-02-04)
- **PlaylistCategory enum** — Type-safe representation of liked/smart/regular playlist types (2026-02-04)
- **String-based fractional indexing** — Base-62 alphanumeric alphabet with delimiter for midpoint calculation (2026-02-04)
- **position_between algorithm** — Lexicographic midpoint generation handles all four insertion cases (2026-02-04)
- **O(1) reorder operations** — Only moved track's position updated, no cascading changes needed (2026-02-04)
- **Transaction pattern with execute_batch** — Explicit BEGIN/COMMIT for atomic multi-table writes (2026-02-04)

### Learnings from Python Implementation

Preserved context from prior Python implementation (archived):

**Database patterns:**
- Context manager pattern for connections with foreign key enforcement
- Transaction-wrapped writes for atomicity
- Format quality hierarchy: lossy < lossless, then by bitrate

**Sanitization patterns:**
- Underscore prefix for Windows reserved names (_CON not CON_)
- Underscore replacement for invalid chars (readable output)
- Return 'unknown' placeholder for empty/invalid input

**Import patterns:**
- Metadata fallbacks: album_artist -> artist -> "Various Artists"
- Continue-on-error: collect failures and report at end
- Reference-in-place model: store original paths, no file copying

**Duplicate detection patterns:**
- File ID as tiebreaker when timestamps equal
- AIFF in lossless formats alongside FLAC/WAV/ALAC
- Empty strings not equal for matching (indicates missing metadata)

**Search patterns:**
- token_set_ratio + partial_ratio for typo/substring handling
- Per-field scoring with max() for accuracy

### Pending Todos

None yet.

### Blockers/Concerns

**Phase 1 (Library Foundation):** ✓ VERIFIED
- All 5 plans executed: schema, metadata, import, search, duplicates
- 20/20 must-haves verified, 86 tests passing
- Verification report: .planning/phases/01-library-foundation/01-VERIFICATION.md

**Phase 2 (Download Infrastructure):** ✓ COMPLETE
- All 4 plans executed: dabmusic API, YouTube extraction, audio transcoding, download orchestration
- FFmpeg required for transcode (to be documented in Phase 5 device sync setup)
- yt-dlp CLI required for YouTube downloads (to be documented in Phase 5)
- 116 tests passing (26 in download module)
- Next: Phase 3 multi-source aggregation can begin

**Phase 3 (Multi-Source Aggregation):** ✓ VERIFIED
- All 6 plans executed and verified (5/5 must-haves passed)
- Verification report: .planning/phases/03-multi-source-aggregation/03-VERIFICATION.md
- 185 tests passing (9 spotify, 9 soundcloud, 22 dedup, 6 commands/sources, 1 startup)
- 4,689 lines across 11 key files
- scdl CLI required for SoundCloud direct downloads (pip install scdl)
- Download priority: SoundCloud -> DAB -> YouTube for SC-sourced tracks
- Credentials loaded from .env via dotenvy (src-tauri/.env.example for template)
- OAuth live testing deferred until user configures credentials in .env

**Phase 4 (Playlist Management):** IN PROGRESS
- Plan 04-01 complete: Schema version 3 with playlists, playlist_tracks, playlist_tags
- Plan 04-02 complete: Fractional indexing and playlist CRUD operations
- 203 tests passing (13 new playlist tests: 7 fractional indexing + 6 CRUD)
- Fractional indexing with base-62 alphabet, position_between algorithm
- O(1) reorder operations (only moved track's position updated)
- Transaction pattern with execute_batch for atomic multi-table writes
- Next: 04-03 smart playlists and liked playlists

**Phase 5 (Device Sync):**
- Rockbox M3U8 compatibility specifics unknown (relative vs absolute paths, encoding)
- Need actual iPod for filesystem testing (FAT32, character encoding edge cases)

## Session Continuity

Last session: 2026-02-04
Stopped at: Completed 04-02-PLAN.md
Resume file: None

---
*Last updated: 2026-02-04 after completing plan 04-02*
