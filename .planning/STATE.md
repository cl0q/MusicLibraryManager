# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-03)

**Core value:** Like a song anywhere and it reliably ends up in your owned library and on your devices in high quality
**Current focus:** Phase 4 verified - ready for Phase 5 Device Sync

## Current Position

Phase: 7 of 7 (Enhancements)
Plan: 2 of 6 in current phase
Status: In progress
Last activity: 2026-02-05 — Completed 07-02-PLAN.md (Acoustic Fingerprinting)

Progress: [█████████████████████████████████] 100.0% (34 of 34 concrete plans complete)

## Tech Stack Change

**Previous:** Python with Mutagen, Whoosh, RapidFuzz
**Current:** Rust + Tauri with lofty, tantivy, strsim

The Python implementation has been archived to `_archive/python/`.
New project structure:
- `src-tauri/` — Rust backend
- `ui/` — React + TypeScript + Tailwind frontend

## Performance Metrics

**Velocity:**
- Total plans completed: 34
- Average duration: 21m 35s
- Total execution time: 12.23 hours

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
- **10 Tauri sync commands** — create/list/get/delete profiles, add track/playlist/rule, detect devices, preview/execute sync (2026-02-04)
- **React sync UI with profile management** — SyncProfiles component for create/list/delete profiles, navigation to sync preview (2026-02-04)
- **Sync preview with space validation** — SyncPreview component shows detailed file list, size calculation, device space check before execution (2026-02-04)
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
- **Schema version 5 for Phase 7** — Fingerprints, artwork, replaygain, review_queue tables with indexes (2026-02-05)
- **Shared PCM decode pipeline** — Single decode_to_pcm function using Symphonia for both fingerprinting and ReplayGain to avoid code duplication (2026-02-05)
- **Clone codec_params before decode loop** — Cloning codec params avoids borrow checker issues with format.next_packet() during decode (2026-02-05)
- **Graceful decode error handling** — Skip corrupted packets and recreate decoder on ResetRequired instead of failing entire file (2026-02-05)
- **BLOB storage for fingerprints** — Raw u32 fingerprint data stored as BLOB with little-endian encoding for platform independence (2026-02-05)
- **Base64 encoding for AcoustID API** — Converts raw u32 fingerprints to base64 strings for api.acoustid.org submission (2026-02-05)
- **0.5 default duplicate threshold** — Conservative threshold for fingerprint-based duplicate detection balances precision/recall (2026-02-05)
- **Segment-based fingerprint scoring** — Similarity score is ratio of longest matching segment to shorter fingerprint length (2026-02-05)
- **Configuration::preset_test2() for Chromaprint** — Consistent fingerprint configuration for reproducible results (2026-02-05)
- **Three-source union for profile content** — Manual tracks + playlists + query rules combined via HashSet for deduplicated track IDs (2026-02-04)
- **Query-time content resolution** — get_all_track_ids() computes union on each call for dynamic smart-playlist-like behavior (2026-02-04)
- **Field/operator/value filter rule structure** — Extensible query pattern supporting eq/ne/gt/lt/contains/in operators across genre/artist/bitrate/date_added/source/tag (2026-02-04)
- **DTO computed statistics** — SyncProfileDto.from_profile() runs database queries to compute track counts rather than storing redundant data (2026-02-04)
- **rusqlite::Result for collect()** — Used rusqlite's Result type instead of custom Result alias for query_map iterator conversions (2026-02-04)
- **Track ID as cache filename** — {track_id}.m4a simpler than content hashing, stable reference once assigned (2026-02-04)
- **Hardlink-first strategy on Unix** — Hardlinks save disk space when cache and profile on same filesystem, copy fallback for cross-filesystem (2026-02-04)
- **Windows always copies files** — Symlinks require elevated privileges, copying is more reliable (2026-02-04)
- **SHA256 for checksums** — Industry-standard cryptographic hash for file change detection in sync state tracking (2026-02-04)
- **64KB buffer for file operations** — Fixed memory usage regardless of file size, efficient for typical 5-10MB AAC files (2026-02-04)
- **df/wmic for disk space** — std::process::Command avoids unsafe FFI and external crates, subprocess overhead negligible (2026-02-04)
- **Relative M3U8 paths** — Rockbox requires relative paths from device root, format Artist/Album/Track.m4a (2026-02-04)
- **album_artist in M3U8 paths** — Matches profile folder structure for consistent file resolution (2026-02-04)
- **#EXTINF format with artist - title** — Industry standard M3U8 metadata format, duration defaults to 0 if missing (2026-02-04)
- **50MB space buffer for sync** — Safety margin prevents out-of-space failures during sync operations (2026-02-04)
- **SHA256 checksums for change detection** — Industry standard cryptographic hash enables reliable incremental sync (2026-02-04)
- **Sync preview returns full file list** — User needs to see exactly what will be synced before committing (2026-02-04)
- **Auto-clean stale sync_state entries** — Tracks removed from profile automatically removed from sync_state for accuracy (2026-02-04)
- **React Router for desktop UI** — Client-side routing with nested routes for five main sections (Dashboard, Library, Playlists, Sync, Downloads) (2026-02-04)
- **Sonner for toast notifications** — Modern, clean UX with built-in dark mode support and good DX (2026-02-04)
- **Sidebar 240px width** — Standard side navigation width balancing visibility with content space (2026-02-04)
- **Clickable status bar header** — Expand/collapse via click interaction for user discovery without dedicated button (2026-02-04)
- **Status bar expanded height 240px** — Enough space for 5-7 operations visible without dominating screen (2026-02-04)
- **Type-only imports with 'type' keyword** — TypeScript verbatimModuleSyntax compliance requires explicit type-only imports (2026-02-04)
- **Tauri v2 uses @tauri-apps/api/core** — Invoke function moved from api/tauri (v1) to api/core (v2) (2026-02-04)
- **invokeTauriCommand result tuple** — Returns { ok, data?, error? } for consistent error handling across all Tauri commands (2026-02-04)
- **Event listener cleanup pattern** — All useEffect event listeners return unlisten() cleanup function to prevent memory leaks (2026-02-04)
- **Activity feed 50-event limit** — Maximum 50 events retained to prevent unbounded memory growth (2026-02-04)
- **Relative time formatting** — Dashboard timestamps use "just now", "Xm ago", "Xh ago", "Xd ago" for human readability (2026-02-04)
- **Activity type color coding** — Visual differentiation: green (track_added), blue (sync_completed), purple (download_completed), red (error) (2026-02-04)
- **Map-based download state** — Map<string, DownloadProgressEvent> for O(1) updates by track_id during real-time progress events (2026-02-04)
- **Download display sort priority** — Active downloads first (downloading/transcoding), then failed, completed, queued for user awareness (2026-02-04)
- **Separate queue status API** — Retry queue (pending_count, failed_count) tracked independently from real-time progress events (2026-02-04)
- **TanStack React Table + Virtual for library browser** — Handles 10k+ tracks with smooth scrolling via virtualization (2026-02-04)
- **Client-side filtering with useMemo** — Instant search responsiveness for <100k tracks, simpler than server-side filtering (2026-02-04)
- **40px row height with 5 row overscan** — Standard table density with smooth virtual scrolling (2026-02-04)
- **Empty query returns all tracks** — search_library("") fetches entire library, consistent search UX pattern (2026-02-04)
- **react-contexify for context menus** — Lightweight library with dark mode support for library table right-click actions (2026-02-04)
- **wavesurfer.js for audio visualization** — Established library for waveform rendering in track detail page (2026-02-04)
- **Tauri opener plugin for file reveal** — plugin:opener|reveal_item_in_dir invocation opens native file manager to track location (2026-02-04)
- **convertFileSrc for Tauri audio URLs** — @tauri-apps/api/core function converts local paths to Tauri-compatible URLs for WaveSurfer (2026-02-04)
- **Page wrapper pattern for component integration** — Thin wrapper pages route existing Phase 3-5 components into MainLayout (2026-02-04)
- **color-scheme meta tag** — <meta name="color-scheme" content="dark light" /> enables proper OS dark mode detection (2026-02-04)
- **File size sum from original_path** — Dashboard storage stat calculated from actual file system metadata, not database field (2026-02-04)
- **Skip missing files in storage calculation** — Tracks may be moved/deleted; sum available files without failing entire query (2026-02-04)
- **Global last sync from sync_state DESC** — Most recent synced_timestamp across all profiles for dashboard display (2026-02-04)
- **formatBytes utility** — Standard byte formatting (B/KB/MB/GB/TB) with 2 decimal places for human readability (2026-02-04)
- **formatRelativeTime utility** — Relative time display (m/h/d ago) for recent events, full date for older (2026-02-04)
- **sync:completed event for auto-refresh** — Dashboard listens for sync events to update last sync time in real-time (2026-02-04)
- **tauri::Emitter trait for event emission** — Rust backend uses app.emit() for real-time sync progress events (2026-02-05)
- **Optional AppHandle in sync_profile_to_folder** — Event emission optional for test compatibility, production passes Some(&app) (2026-02-05)
- **useSyncProgress hook for real-time sync tracking** — Map-based state keyed by profile_id, auto-removes completed operations after 3 seconds (2026-02-05)
- **Four sync event types** — sync:started, sync:progress, sync:completed, sync:failed for comprehensive operation tracking (2026-02-05)
- **StatusBar combines download and sync operations** — Unified operation display using useDownloadProgress and useSyncProgress hooks (2026-02-05)

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

**Phase 5 (Device Sync):** ✓ COMPLETE
- Plan 05-01 (Sync Profile Model): ✓ COMPLETE
  - Schema version 4 with five sync tables
  - SyncProfile model with get_all_track_ids() union resolution (manual + playlists + rules)
  - Tauri IPC DTOs with computed statistics
  - 9 unit tests passing
- Plan 05-02 (Shared Transcode Cache): ✓ COMPLETE
  - TranscodeCache with platform-aware file linking (hardlinks on Unix, copies on Windows)
  - SHA256 checksum computation for sync state tracking
  - Profile path builder with FAT32-safe sanitized names
  - 12 unit tests passing
- Plan 05-03 (Rockbox Device Detection): ✓ COMPLETE
  - RockboxDevice detection via .rockbox directory marker
  - Platform-specific mount scanning (macOS /Volumes, Linux /mnt and /media, Windows drive letters)
  - Disk space query using df on Unix, wmic on Windows
  - M3U8 playlist generation with #EXTM3U header and relative paths
  - FAT32-safe filename sanitization in playlist paths
  - 15 unit tests passing (5 device, 10 playlist)
- Plan 05-04 (Incremental Sync Orchestration): ✓ COMPLETE
  - Sync preview computation with dry-run mode (compute_sync_preview)
  - Incremental sync execution with SHA256 change detection (execute_sync)
  - Sync state persistence for resumption support (update_sync_state)
  - Space validation with 50MB buffer requirement
  - High-level orchestration: preview_sync(), sync_profile_to_folder()
  - 9 unit tests passing, 54 total sync module tests passing
- Plan 05-05 (Tauri Commands & React UI): ✓ COMPLETE
  - 10 Tauri commands for sync operations (create/list/get/delete profiles, add track/playlist/rule, detect devices, preview/execute sync)
  - SyncProfiles.tsx component for profile management
  - SyncPreview.tsx component for sync preview and execution
  - Human verification checkpoint approved
- Phase 5 verification pending: Need actual iPod for integration testing
- M3U8 UTF-8 encoding with Rockbox untested (should work but needs verification with device)
- FAT32 long filename edge cases (255 char limit enforced but not tested with actual device)

**Phase 6 (Desktop UI):** ✓ COMPLETE
- Plan 06-01 (App Shell & Navigation): ✓ COMPLETE
  - React Router configuration with 5 routes (/, /library, /playlists, /playlists/:id, /sync, /downloads)
  - MainLayout with persistent sidebar (240px fixed width, 5 navigation sections)
  - Sidebar with active state highlighting, Spotify/Linear aesthetic
  - StatusBar with expand/collapse (collapsed 40px, expanded 240px)
  - Toast notifications via Sonner
  - Type definitions for Track, Album, Artist, ActivityEvent, DownloadProgressEvent
  - Typed Tauri command wrappers for playlists, sync, search, import, downloads
  - Fixed pre-existing bugs in Phase 4/5 components (Tauri v2 imports, TypeScript verbatimModuleSyntax)
- Plan 06-02 (Dashboard Home Screen): ✓ COMPLETE
  - Dashboard page with Quick Actions (Sync Now button), stats cards, and activity feed
  - useTauriCommand hook for generic command invocation with error handling
  - useTauriEvents hooks (useActivityFeed, useDownloadProgress) with proper cleanup
  - StatsCards component: Track Count, Storage Size, Sources Connected, Last Sync, Pending Downloads
  - ActivityFeed component: real-time updates via library:activity events, color-coded by type
  - Responsive grid layouts (1 col mobile, 3-5 cols desktop)
  - Event-driven UI update pattern established for entire app
- Plan 06-03 (Library Browser): ✓ COMPLETE
  - LibraryBrowser page with search and data management
  - LibraryTable component with TanStack Table and virtualized scrolling
  - FilterBar component with search and quality filter dropdown
  - useLibrary hook for track data fetching and filtering
  - Sortable columns (title, artist, album, quality, duration, date)
  - Performance: Virtualized rendering handles large libraries efficiently
- Plan 06-04 (Downloads Page): ✓ COMPLETE
  - Downloads page at /downloads route with real-time progress tracking
  - DownloadQueue component showing detailed per-item status
  - useDownloadQueue hook managing state via Tauri download:progress events
  - Extended DownloadProgressEvent with source, current_step, speed, eta, file_size
  - Failed download handling with error messages and retry button
  - Event listener cleanup on unmount
- Plan 06-05 (Context Menus & Component Integration): ✓ COMPLETE
  - RowContextMenu component with 6 actions (View Details, Add to Playlist, Download, Sync to Device, Add to Library, Reveal in File Manager)
  - TrackDetail page with MetadataPanel and WaveformView using wavesurfer.js
  - Integration of Phase 3-5 components (PlaylistList, PlaylistDetail, SyncProfiles) via page wrappers
  - All 7 routes working: /, /library, /library/:trackId, /playlists, /playlists/:id, /sync, /downloads
  - Removed leftover Vite template CSS, added color-scheme meta tag
  - Human verification checkpoint approved
- Plan 06-06 (Dashboard Stats - Gap Closure): ✓ COMPLETE
  - Added get_library_storage_size and get_last_sync_time Tauri commands
  - StatsCards now fetches real storage size and last sync time
  - StatsCards listens for sync:completed to auto-refresh last sync time
  - Dashboard stats now show live data instead of placeholders
- Plan 06-07 (Sync Operations - Gap Closure): ✓ COMPLETE
  - Rust backend emits sync:started, sync:progress, sync:completed events via tauri::Emitter
  - Dashboard "Sync Now" button calls execute_sync_cmd with first available profile
  - Sync page profile selection triggers actual sync with toast notifications
  - useSyncProgress hook tracks real-time sync operations
  - StatusBar displays live operations from useDownloadProgress and useSyncProgress
  - Auto-removes completed operations after 3 seconds
  - All Phase 6 verification gaps closed (Gap 1: Sync Operations, Gap 4: StatusBar)

**Phase 7 (Enhancements):** IN PROGRESS
- Plan 07-01 (Foundation Layer): ✓ COMPLETE
  - Schema version 5 with fingerprints, artwork, replaygain, review_queue tables
  - PHASE7_SCHEMA_SQL constant with 4 new tables and 2 indexes
  - migrate_to_v5() function for automatic v4→v5 upgrade
  - Shared audio PCM decoder (decode_to_pcm) using Symphonia
  - Returns (Vec<i16>, sample_rate, channels) for fingerprinting and ReplayGain
  - Phase 7 dependencies added: rusty-chromaprint, ebur128, musicbrainz_rs, image
  - 2 unit tests for decoder, 3 new tests for schema migration
  - All 13 schema tests passing, cargo check passes with new dependencies
- Plan 07-02 (Acoustic Fingerprinting): ✓ COMPLETE
  - Chromaprint fingerprint generation from PCM samples using rusty-chromaprint
  - fingerprint_track() decodes audio and generates fingerprint
  - BLOB storage with little-endian u32 encoding for database persistence
  - save_fingerprint() and load_fingerprint() with roundtrip verification
  - get_unfingerprinted_tracks() for incremental processing
  - batch_fingerprint() for bulk operations with error tracking
  - AcoustID client with compress_fingerprint() and lookup_acoustid()
  - Base64 encoding for api.acoustid.org submission
  - save_acoustid_result() for MusicBrainz recording ID persistence
  - Local matcher with compare_fingerprints() returning 0.0-1.0 similarity score
  - are_duplicates() with 0.5 default threshold
  - find_fingerprint_duplicates() for O(n) duplicate detection
  - 13 unit tests: 4 chromaprint, 4 acoustid, 5 matcher
  - All tests passing, AcoustID requires ACOUSTID_API_KEY in .env for live use
  - Fixed lofty WriteOptions import path (Rule 3 blocking issue)

## Session Continuity

Last session: 2026-02-05
Stopped at: Completed 07-02-PLAN.md (Acoustic Fingerprinting)
Resume file: None

---
*Last updated: 2026-02-05 after completing Plan 07-02 (Acoustic Fingerprinting)*
