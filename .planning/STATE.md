# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-03)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 4 verified - ready for Phase 5 Device Sync

## Current Position

Phase: 5 of 7 (Device Sync) — IN PROGRESS
Plan: 1 of 4 in current phase
Status: Plan 05-01 complete - sync profile model established
Last activity: 2026-02-04 — Completed 05-01-PLAN.md (Sync Profile Model)

Progress: [████████████████████░] 95% (21 of 22 concrete plans complete)

## Tech Stack Change

**Previous:** Python with Mutagen, Whoosh, RapidFuzz
**Current:** Rust + Tauri with lofty, tantivy, strsim

The Python implementation has been archived to `_archive/python/`.
New project structure:
- `src-tauri/` — Rust backend
- `ui/` — React + TypeScript + Tailwind frontend

## Performance Metrics

**Velocity:**
- Total plans completed: 21
- Average duration: 15m 35s
- Total execution time: 5.49 hours

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
- **SQL views for smart playlists** — Auto-updating views query tracks table with date/stats filtering (2026-02-04)
- **INSERT OR IGNORE for idempotent initialization** — All playlist creation functions safe to call multiple times (2026-02-04)
- **Per-source liked playlists** — "{Source} Likes" naming with source_id FK, created on first track import (2026-02-04)
- **Most Played placeholder view** — Uses 0 play_count until Phase 5 adds track_stats table (2026-02-04)
- **Startup playlist initialization** — Synchronous initialize_on_startup before async sync tasks (2026-02-04)
- **Add-only semantics for mirrored playlists** — Tracks removed from source playlist stay in local playlist to preserve user's manual additions (2026-02-04)
- **Cross-source deduplication 0.85 threshold** — Same track from Spotify and SoundCloud references one library track (no duplicate downloads) (2026-02-04)
- **find_or_create_track pattern** — Check external_id first, then fuzzy match by title/artist similarity, create phantom track if not found (2026-02-04)
- **Idempotent add_liked_track** — Safe to call multiple times with same track, prevents duplicate entries in liked playlists (2026-02-04)
- **External_id format for playlist tracking** — spotify:playlist:{id} and soundcloud:{id} stored in playlists.external_id for refresh operations (2026-02-04)
- **Schema version 4 for Phase 5** — Sync profiles, sync_profile_tracks, sync_profile_playlists, sync_profile_rules, sync_state tables (2026-02-04)
- **Three-source union for profile content** — Manual tracks + playlists + query rules combined via HashSet for deduplicated track IDs (2026-02-04)
- **Query-time content resolution** — get_all_track_ids() computes union on each call for dynamic smart-playlist-like behavior (2026-02-04)
- **Field/operator/value filter rule structure** — Extensible query pattern supporting eq/ne/gt/lt/contains/in operators across genre/artist/bitrate/date_added/source/tag (2026-02-04)
- **DTO computed statistics** — SyncProfileDto.from_profile() runs database queries to compute track counts rather than storing redundant data (2026-02-04)
- **rusqlite::Result for collect()** — Used rusqlite's Result type instead of custom Result alias for query_map iterator conversions (2026-02-04)

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

**Phase 4 (Playlist Management):** ✓ VERIFIED
- All 5 plans executed and verified
- Verification report: .planning/phases/04-playlist-management/04-VERIFICATION.md
- 224 tests passing (18 playlist module, 2 spotify import, 2 soundcloud import, 11 command tests)
- Schema version 3 with playlists, playlist_tracks, playlist_tags tables
- Fractional indexing for O(1) reorder operations
- Smart playlists (Recently Added, Most Played) with SQL views
- Per-source liked playlists (Spotify Likes, SoundCloud Likes, Local Likes)
- Source playlist import with add-only mirroring semantics
- Cross-source deduplication via find_or_create_track
- 7 Tauri commands for playlist operations
- React UI: PlaylistList (grouped by category), PlaylistDetail (search + drag-drop)
- @hello-pangea/dnd for drag-drop reordering
- Next: Phase 5 Device Sync

**Phase 5 (Device Sync):** IN PROGRESS
- Plan 05-01 (Sync Profile Model): ✓ COMPLETE
  - Schema version 4 with five sync tables
  - SyncProfile model with get_all_track_ids() union resolution (manual + playlists + rules)
  - Tauri IPC DTOs with computed statistics
  - 9 unit tests passing
- Plan 05-02 (Transcode Cache): READY TO START
- Rockbox M3U8 compatibility specifics unknown (relative vs absolute paths, encoding)
- Need actual iPod for filesystem testing (FAT32, character encoding edge cases)

## Session Continuity

Last session: 2026-02-04
Stopped at: Completed 05-01-PLAN.md (Sync Profile Model)
Resume file: None

---
*Last updated: 2026-02-04 after completing Plan 05-01*
