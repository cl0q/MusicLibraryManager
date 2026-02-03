# Project Research Summary

**Project:** Music Library Manager
**Domain:** Multi-Source Music Library Aggregation and Synchronization
**Researched:** 2026-02-03
**Confidence:** MEDIUM-HIGH

## Executive Summary

Music library management is a well-understood problem space with established patterns around pipeline architectures (download → process → transcode → sync), normalized database schemas, and worker-pool parallelism. The unique challenge here is aggregating music from multiple streaming services (Spotify, Apple Music, SoundCloud) plus local files into a unified library while preserving playlist order and downloading high-fidelity versions for device sync.

The recommended approach is a Python-based backend with PySide6 desktop UI, leveraging SQLite for metadata, FFmpeg for transcoding, and established API clients (Spotipy, apple-music-python, yt-dlp). The architecture follows a pipeline pattern with atomic checkpoints, per-source rate limiting, and acoustic fingerprinting for deduplication. Critical to success is implementing idempotent operations from day one and preserving playlist order through explicit position tracking.

Key risks center around API reliability (especially SoundCloud's unofficial API and YouTube's anti-download measures), character encoding in metadata, and naive deduplication creating library chaos. Mitigation requires fallback download sources, UTF-8 standardization with filename sanitization, and acoustic fingerprinting via AcoustID/Chromaprint rather than metadata-only matching.

## Key Findings

### Recommended Stack

Python 3.11+ provides the richest ecosystem for music library management, with mature libraries for every layer of the stack. The technology choices balance developer productivity (SQLAlchemy, loguru) with production-grade reliability (FFmpeg, SQLite) and native platform integration (PySide6 Qt).

**Core technologies:**
- **PySide6 (6.10.2)**: Cross-platform desktop UI — Official Qt bindings, native look and feel, actively maintained with Python 3.9-3.14 support
- **SQLAlchemy (2.0.46) + SQLite**: ORM and database — Type-safe queries, async support, zero-config embedded database perfect for local library state
- **FFmpeg (7.x) via subprocess**: Audio transcoding — Industry standard for FLAC→AAC conversion, direct subprocess calls avoid unmaintained wrapper abstractions
- **Mutagen (1.47.0)**: Metadata reading/writing — Comprehensive format support (MP3/FLAC/AAC/M4A/OGG), used by professional tools (Beets, Picard)
- **Spotipy (2.25.2)**: Spotify API client — Official community library, full API coverage, active maintenance
- **apple-music-python (1.0.6)**: Apple Music API — Most recently updated Python wrapper (Dec 2024), only viable option
- **soundcloud-v2 / yt-dlp**: SoundCloud/YouTube downloads — Internal API usage (risk of breakage), but no official alternatives exist
- **httpx (0.28.1)**: HTTP client — Modern dual sync/async API, HTTP/2 support for faster concurrent API requests
- **watchdog (6.0.0)**: Filesystem monitoring — Cross-platform file system event detection for library changes
- **loguru (0.7.3)**: Logging — Zero-config, beautiful output, automatic exception tracing

**Critical version dependencies:** Python 3.11+ for performance and typing. PySide6 6.10.2 released Feb 2, 2026. FFmpeg 7.x for latest codec support.

**Risk assessment:** SoundCloud integration is highest risk (unofficial API, MEDIUM-HIGH risk). All other components are production-grade with LOW risk. Apple Music python library has limited adoption (MEDIUM risk) but is actively maintained and only option available.

### Expected Features

The project sits in a unique position: existing tools handle either streaming OR local files, but not unified multi-source aggregation with ownership focus (download high-fidelity for devices).

**Must have (table stakes):**
- **Metadata Management** — Core to any music library, must support ID3v2.3/2.4, Vorbis comments
- **Multiple Format Support** — MP3, FLAC, AAC/M4A, OGG at minimum
- **Duplicate Detection** — Essential when aggregating from multiple sources
- **File Organization** — Customizable Artist/Album/Track structure
- **Search & Query** — Fast search by artist/album/title/genre even with 20k+ tracks
- **Playlist Management** — Create, edit, reorder playlists with M3U8 export
- **Basic Tagging/Editing** — Fix incorrect metadata, batch operations
- **Import/Scan Library** — Recursive directory scanning, monitor for new files

**Should have (competitive differentiators):**
- **Multi-Source Aggregation** — YOUR CORE VALUE: Unify Spotify + Apple Music + SoundCloud + local files (rare, most tools do one or the other)
- **Playlist Order Preservation** — YOUR CRITICAL FEATURE: Maintain date-added descending across platforms (major pain point others neglect)
- **Automatic High-Fidelity Download** — Get best quality from source (FLAC from dabmusic.xyz), transcode to target quality (248kbps AAC)
- **Device-Optimized Transcoding** — Automatically convert to format/quality for Rockbox iPod
- **Acoustic Fingerprinting** — Identify tracks even with missing/wrong metadata (Beets/Picard do this)
- **Smart Playlists** — Auto-generate based on rules (genre, BPM, date added)
- **ReplayGain/Volume Normalization** — Consistent volume across tracks
- **Incremental Sync** — Only sync changes, not entire library each time
- **Filesystem + Playlist Sync** — Copy both files AND M3U8 playlists to device

**Defer (v2+):**
- **Lyrics Integration** — Nice-to-have, not essential for core "like anywhere → ends up on device" flow
- **Cloud Service Integration** — Dropbox/Drive support adds complexity
- **UPnP/DLNA Streaming** — Not needed if syncing to device with its own player
- **Additional Streaming Services** — YouTube Music, Tidal, Deezer (expand after core 3 work)
- **Multiple Device Sync** — Just Rockbox iPod for MVP

**Anti-features to avoid:**
- Built-in music player (scope creep, excellent players exist)
- Social features (infrastructure burden, network effects needed)
- DRM management (legal minefield)
- CD ripping (hardware dependency, niche in 2026)
- Mobile playback app (platform-specific burden, use web dashboard instead)

### Architecture Approach

Music library systems follow a **pipeline architecture** with clear separation: metadata (SQLite database) ↔ audio files (filesystem) connected by file path references. Long-running operations use worker-pool parallelism with atomic checkpoints for resumability.

**Major components:**
1. **Orchestrator / Job Scheduler** — Coordinates phases (download → transcode → sync), persists state, manages resume capability
2. **Aggregation Manager** — Polls streaming APIs (Spotify/Apple/SoundCloud), normalizes metadata, detects duplicates via acoustic fingerprinting
3. **Pipeline Engine** — Executes download→clean→transcode→sync pipeline with parallel workers (ThreadPoolExecutor for I/O-bound, threading for CPU-bound FFmpeg)
4. **Download Manager** — Multi-source downloads with fallback chain (dabmusic.xyz → scdl → yt-dlp), per-source rate limiting
5. **Metadata Processor** — Clean/normalize ID3 tags via Mutagen, embed artwork, UTF-8 standardization
6. **Transcoding Engine** — FLAC→AAC conversion via FFmpeg subprocess, quality validation (duration, bitrate, stream info)
7. **Sync Manager** — Hash-based differential sync to device, parallel file copy workers, M3U8 playlist generation
8. **Metadata Store** — SQLite for tracks/albums/artists/playlists/sources with normalized schema following MusicBrainz model, JSON for snapshots
9. **Desktop UI** — PySide6 Qt interface with progress tracking via IPC from backend workers

**Data flow pattern:**
```
User likes song → API polling → Metadata DB (status: pending) →
Download queue → Parallel workers → File saved (temp → atomic rename) →
Metadata cleaning → Transcoding (if needed) →
Sync diff (compare device state) → Parallel copy to device →
M3U8 generation → UI completion notification
```

**Key design decisions:**
- Separate metadata from audio files (independent scaling)
- Atomic file operations (temp file → verify → rename, never direct overwrite)
- Per-source rate limiters (dabmusic.xyz fast, SoundCloud slow, don't share limits)
- Acoustic fingerprinting for deduplication (not metadata-only which creates chaos)
- Explicit playlist position field (never rely on implicit ordering)
- Many-to-many tracks ↔ sources (one track can exist in Spotify + Apple Music)

### Critical Pitfalls

Research identified 16 domain pitfalls, with 7 critical failures requiring prevention from day one.

1. **Non-Atomic File Operations Leading to Corruption** — Downloads/transcoding crash mid-write leaving corrupt files that pass validation. Prevention: Write to `.tmp-{uuid}`, verify integrity (checksum, duration), atomic rename only after verification, use `fsync()` before rename.

2. **Ignoring Idempotency in Long-Running Operations** — Failed downloads retry but create duplicates, waste bandwidth, or skip tracks. The system becomes "gambling whether runs work." Prevention: Track state in database (pending/in-progress/completed/failed), resume partial downloads via HTTP Range headers, store operation fingerprint (track ID + source + quality) to detect duplicates, exponential backoff with retry budgets.

3. **Naive Track Matching Leading to Duplicates** — Same song from different sources treated as separate tracks, or different songs merged incorrectly. Library fills with duplicates. Prevention: Implement acoustic fingerprinting with AcoustID/Chromaprint, use fingerprint as primary match key (metadata secondary), store multiple source IDs per track, normalize metadata for comparison.

4. **Character Encoding Nightmares in Metadata** — Tags with non-ASCII characters (é, ñ, ü, 中文) display as garbage. Filenames fail to copy to iPod. Prevention: Standardize on UTF-8 everywhere, use ID3v2.4 tags (UTF-8), convert filenames to ASCII-safe format, NFD normalization on macOS / NFC on Windows/Linux, test with emoji/CJK/RTL scripts.

5. **API Token Expiration Without Graceful Handling** — Bulk operations fail midway when tokens expire. Background sync stops silently. Prevention: Store token expiration time in DB, check expiration before each operation (5-minute buffer), implement automatic refresh flow (Spotify refresh_token), detect 401 and prompt re-auth, surface token status in UI.

6. **Transcoding Without Quality Validation** — FLAC transcodes to AAC but sounds terrible or is silent. Files pass checks but are unusable. Prevention: Validate output with FFmpeg (stream info, duration, sample rate), never transcode lossy→lossy (keep original if already AAC/MP3), match output duration to input (±1 second), test with diverse files before bulk operations, use EBU R128 loudness normalization.

7. **Playlist Order Not Preserved** — Playlist syncs but tracks in random order. User curated order lost. Prevention: Store explicit position/index field (0-based), use array/list data structures, never rely on implicit ordering, add unique constraint on (playlist_id, position), assign position before parallel downloads, validate with known playlists.

**Moderate pitfalls:**
- Spotify API rate limiting without backoff (implement exponential backoff, honor Retry-After header)
- YouTube download fragility (keep yt-dlp updated to nightly, use cookies, have fallback sources)
- SoundCloud download unreliability (use yt-dlp directly, scdl v3 is just a wrapper)
- Cross-platform filesystem incompatibilities (sanitize for FAT32, test on all platforms)
- Database schema without source tracking (many-to-many tracks ↔ sources schema required)

## Implications for Roadmap

Based on component dependencies and pitfall mitigation needs, recommended phase structure:

### Phase 1: Core Library Foundation
**Rationale:** Establish database schema, file utilities, and configuration before any external integrations. Everything else depends on data models. This phase must implement atomic file operations and idempotency patterns from day one to avoid "gambling whether runs work."

**Delivers:**
- Normalized database schema (tracks, artists, albums, playlists, sources, download_queue, device_tracks)
- File utilities (path sanitization, atomic write/rename, hash calculation)
- Configuration management (pydantic-settings for type-safe config)
- Basic import/scan local files with metadata reading via Mutagen
- Simple search by artist/album/title

**Addresses from FEATURES.md:**
- Import/Scan Library
- Metadata Management (read/write ID3 tags)
- Basic Search
- File Organization (Artist/Album/Track structure)

**Avoids from PITFALLS.md:**
- Pitfall 1 (Non-atomic operations) — Implement temp file + atomic rename pattern
- Pitfall 4 (Character encoding) — UTF-8 standardization, filename sanitization for FAT32
- Pitfall 14 (Hardcoded paths) — Config-driven base paths

**Research needs:** Standard patterns, skip phase-specific research.

---

### Phase 2: Download Infrastructure
**Rationale:** Prove basic download pipeline works with single source before adding multi-source complexity. Must implement state tracking, retry logic, and worker pool for parallelism.

**Delivers:**
- Download manager with fallback chain (dabmusic.xyz API → yt-dlp)
- Worker pool (ThreadPoolExecutor) with progress tracking
- State manager with checkpoint save/load for resume capability
- Per-source rate limiting with adaptive backoff
- Queue management (priority, retry budgets, transient vs permanent failures)

**Addresses from FEATURES.md:**
- High-Fidelity Download (FLAC from dabmusic.xyz, AAC from sources)
- Download Queue Management (batches, retries, errors)

**Avoids from PITFALLS.md:**
- Pitfall 2 (Ignoring idempotency) — State tracking, resume via HTTP Range headers
- Pitfall 8 (Spotify rate limiting) — Exponential backoff, Retry-After header
- Pitfall 13 (No progress indication) — Emit progress events, calculate ETA

**Research needs:** Investigate dabmusic.xyz API specifics, rate limits, authentication requirements. Standard yt-dlp usage is well-documented.

---

### Phase 3: Multi-Source Aggregation
**Rationale:** Add Spotify, Apple Music, SoundCloud API polling now that download infrastructure is proven. Deduplication via acoustic fingerprinting is critical before accumulating duplicates.

**Delivers:**
- API adapters (Spotipy for Spotify, apple-music-python, yt-dlp for SoundCloud)
- Aggregation manager (poll APIs, normalize metadata)
- Deduplication engine with AcoustID/Chromaprint acoustic fingerprinting
- Many-to-many tracks ↔ sources schema implementation
- Duplicate detection UI (manual override: "Keep both versions")

**Addresses from FEATURES.md:**
- Spotify Integration (pull liked songs, playlists)
- Apple Music Integration (pull library, playlists)
- SoundCloud Integration (pull likes)
- Duplicate Detection (critical when merging sources)
- Playlist Order Preservation (date-added tracking)
- Acoustic Fingerprinting (identify tracks with wrong metadata)

**Avoids from PITFALLS.md:**
- Pitfall 3 (Naive track matching) — Acoustic fingerprinting as primary match key
- Pitfall 5 (Token expiration) — Monitor TTL, refresh flow, surface status in UI
- Pitfall 12 (No source tracking) — Many-to-many schema with source metadata

**Research needs:** HIGH priority. Apple Music API authentication flow (MusicKit setup), token refresh patterns. SoundCloud unofficial API specifics, current state of yt-dlp SoundCloud support.

---

### Phase 4: Processing Pipeline
**Rationale:** Need downloaded files before building metadata cleaning and transcoding. Quality validation is critical to avoid silent corruption.

**Delivers:**
- Metadata processor (clean/normalize tags, embed artwork via Mutagen)
- Transcoding engine (FFmpeg FLAC→AAC 248kbps with quality validation)
- Output validation (duration match, stream info check, bitrate verification)
- ReplayGain/volume normalization (EBU R128)

**Addresses from FEATURES.md:**
- Device-Optimized Transcoding (FLAC→248kbps AAC for Rockbox)
- ReplayGain/Volume Normalization
- Album Art Management (fetch/embed high-quality cover art)

**Avoids from PITFALLS.md:**
- Pitfall 6 (Transcoding without validation) — Validate duration, format, stream info
- Anti-pattern: Eager transcoding — Archive FLAC, transcode only for device sync

**Research needs:** Standard FFmpeg patterns, skip phase-specific research. Validate EBU R128 parameters for loudness normalization.

---

### Phase 5: Device Sync
**Rationale:** Transcoding must work before syncing to devices. Filesystem compatibility testing critical for Rockbox iPod support.

**Delivers:**
- Device scanner (read iPod state, build file index)
- Diff engine (hash-based comparison, detect new/modified/deleted)
- Sync manager (parallel copy workers, verify integrity, update device_tracks table)
- M3U8 playlist generation with relative paths
- Incremental sync (only changed files, not full library)

**Addresses from FEATURES.md:**
- Filesystem Sync (copy to Rockbox iPod)
- M3U8 Playlist Generation
- Incremental Sync (track changes, sync deltas only)
- Filesystem + Playlist Sync (files AND playlists)

**Avoids from PITFALLS.md:**
- Pitfall 7 (Playlist order not preserved) — Explicit position field, validate order
- Pitfall 11 (Cross-platform incompatibilities) — Sanitize for FAT32, test on actual iPod

**Research needs:** MEDIUM priority. Rockbox iPod filesystem requirements, M3U8 format specifics for Rockbox, optimal sync strategies for USB 2.0 transfer speeds.

---

### Phase 6: Desktop UI
**Rationale:** Backend must be stable before building UI. PySide6 provides native Qt integration without Electron/Tauri complexity.

**Delivers:**
- PySide6 main window with library browser
- Progress visualization (real-time updates from workers via Qt signals/slots)
- Settings UI (configuration editor for API keys, paths, quality)
- Playlist editor (create, reorder, manage playlists)
- Sync trigger controls

**Addresses from FEATURES.md:**
- Web Dashboard UI → Changed to native desktop UI (PySide6 is better fit)
- Library browser (search, filter by artist/album/genre)
- Playlist Management UI

**Avoids from PITFALLS.md:**
- Pitfall 13 (No progress indication) — Live progress bars, ETA calculation

**Research needs:** Standard PySide6 patterns, skip phase-specific research. Validate worker-to-UI communication patterns (Qt signals/slots vs IPC).

---

### Phase 7: Polish & Enhancement
**Rationale:** Nice-to-have features that aren't critical path. Can be added incrementally after MVP is functional.

**Delivers:**
- Smart playlists (rule-based auto-generation)
- Lyrics integration (fetch/embed lyrics)
- Background sync job (periodic polling of streaming APIs)
- Cloud backup/export (library snapshots to JSON/Dropbox)
- Advanced deduplication (manual merge, confidence scores)

**Addresses from FEATURES.md:**
- Smart Playlists
- Lyrics Integration (defer to post-MVP per FEATURES.md)

**Research needs:** LOW priority. These are optional enhancements.

---

### Phase Ordering Rationale

- **Phase 1 before 2:** Database schema and file utilities are foundational dependencies
- **Phase 2 before 3:** Prove single-source download works before multi-source complexity
- **Phase 3 requires 2:** API adapters need download infrastructure to queue tracks
- **Phase 4 requires 2:** Can't transcode without downloaded files
- **Phase 5 requires 4:** Device sync needs transcoding working first
- **Phase 6 requires all:** UI wraps backend functionality, needs stable backend
- **Phase 7 independent:** Enhancement layer, not blocking MVP

**Dependency graph validates order:** Foundation → Download → Aggregation → Processing → Sync → UI → Polish

**Pitfall mitigation timing:**
- Atomic operations (Pitfall 1): Must be in Phase 1 from day one
- Idempotency (Pitfall 2): Must be in Phase 2 with download infrastructure
- Deduplication (Pitfall 3): Must be in Phase 3 before accumulating duplicates
- Character encoding (Pitfall 4): Must be in Phase 1 with file operations
- Token handling (Pitfall 5): Must be in Phase 3 with API integrations
- Transcoding validation (Pitfall 6): Must be in Phase 4 with transcoding
- Playlist order (Pitfall 7): Must be in Phase 3 with playlist management

### Research Flags

**Phases needing deeper research during planning:**
- **Phase 2 (Download Infrastructure):** dabmusic.xyz API documentation, rate limits, authentication flow
- **Phase 3 (Multi-Source Aggregation):** Apple Music MusicKit setup, token lifecycle; SoundCloud unofficial API current state, yt-dlp integration reliability
- **Phase 5 (Device Sync):** Rockbox iPod filesystem specifics, M3U8 format compatibility testing

**Phases with standard patterns (skip research-phase):**
- **Phase 1 (Foundation):** SQLAlchemy schema design, pathlib usage are well-documented
- **Phase 4 (Processing):** FFmpeg transcoding patterns are extensively documented
- **Phase 6 (Desktop UI):** PySide6 documentation is comprehensive
- **Phase 7 (Polish):** Optional enhancements, defer research until needed

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified current versions from PyPI/official sources. PySide6 6.10.2 released Feb 2, 2026. All core libraries actively maintained. |
| Features | MEDIUM-HIGH | Feature expectations verified via ecosystem research (Beets, Picard, MediaMonkey). Unique positioning ("like anywhere" aggregation) clear from competitive analysis. |
| Architecture | HIGH | Pipeline architecture patterns verified through MusicBrainz schema, Microsoft Azure patterns, FFmpeg documentation. Validated against existing reference implementations. |
| Pitfalls | HIGH | Critical pitfalls (atomic operations, idempotency, character encoding) verified through official docs (Spotify API, AWS reliability patterns, Stripe idempotency). Tool-specific issues (yt-dlp, scdl) confirmed via GitHub issues and community reports. |

**Overall confidence: MEDIUM-HIGH**

The stack is solid and architecture patterns are well-established. Main uncertainty is around API reliability: SoundCloud uses unofficial internal API (risk of breakage), Apple Music python library has limited adoption (but actively maintained), yt-dlp requires constant updates as YouTube counters download tools. These risks are mitigated through fallback sources and graceful degradation strategies.

### Gaps to Address

- **Apple Music API:** Limited Python examples in the wild. MusicKit authentication flow needs hands-on testing during Phase 3. Gap severity: MEDIUM. Mitigation: Budget extra time in Phase 3 for API integration debugging.

- **SoundCloud unofficial API:** Using internal v2 API carries risk of breakage without notice. Gap severity: MEDIUM-HIGH. Mitigation: Abstract SoundCloud behind interface for easy swap, have fallback plan (manual downloads if API breaks), monitor GitHub issues proactively.

- **dabmusic.xyz API:** No official documentation found in research. Unclear if API key required, rate limits, supported search methods. Gap severity: HIGH for Phase 2. Mitigation: Phase 2 research must investigate API specifics before implementation. If API is unreliable, fall back to yt-dlp as primary source.

- **Rockbox M3U8 compatibility:** Research confirmed M3U8 format but not specific Rockbox quirks (relative vs absolute paths, encoding, max playlist size). Gap severity: MEDIUM. Mitigation: Test early with actual Rockbox iPod in Phase 5, iterate on M3U8 generation based on results.

- **Character encoding edge cases:** UTF-8 normalization (NFD vs NFC) is documented but testing with actual iPod filesystem (FAT32) needed. Gap severity: LOW. Mitigation: Phase 5 testing on real device will catch issues.

- **Acoustic fingerprinting performance:** AcoustID/Chromaprint integration patterns are documented but performance with large libraries (10k+ tracks) unclear. Gap severity: LOW. Mitigation: Can defer full fingerprinting to Phase 7 if Phase 3 implementation is too slow, use fuzzy metadata matching as interim solution.

## Sources

### Primary Sources (HIGH confidence)

**Official Documentation:**
- [PySide6 PyPI](https://pypi.org/project/PySide6/) — Version 6.10.2, Feb 2, 2026
- [SQLAlchemy PyPI](https://pypi.org/project/SQLAlchemy/) — Version 2.0.46, Jan 21, 2026
- [Spotipy GitHub](https://github.com/spotipy-dev/spotipy) — Version 2.25.2, Nov 26, 2025
- [Mutagen Documentation](https://mutagen.readthedocs.io/) — Python 3.10+ compatibility
- [httpx PyPI](https://pypi.org/project/httpx/) — Version 0.28.1, Dec 6, 2024
- [Spotify API Rate Limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits)
- [Apple Music API - Generating Developer Tokens](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens)
- [FFmpeg Documentation](https://ffmpeg.org/ffmpeg.html)
- [MusicBrainz Database Schema](https://musicbrainz.org/doc/MusicBrainz_Database/Schema)
- [AcoustID - Open source audio identification](https://acoustid.org/)
- [Chromaprint fingerprinting library](https://github.com/acoustid/chromaprint)

**Architecture & Reliability:**
- [Web-Queue-Worker Architecture (Microsoft)](https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/web-queue-worker)
- [Making Retries Safe with Idempotent APIs (AWS)](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/)
- [Mastering Idempotency: Building Reliable APIs](https://blog.bytebytego.com/p/mastering-idempotency-building-reliable)
- [Stripe API Idempotent Requests](https://docs.stripe.com/api/idempotent_requests)
- [Atomic File Operations](https://dev.to/martinhaeusler/towards-atomic-file-modifications-2a9n)

### Secondary Sources (MEDIUM confidence)

**Ecosystem Research:**
- [Best Software with Music Library Management Functionality (2026)](https://appmus.com/feature/music-library-management)
- [Beets GitHub](https://github.com/beetbox/beets) — Reference implementation for local library management
- [MusicBrainz Picard Homepage](https://picard.musicbrainz.org/) — Industry standard tagging tool
- [Which Python GUI library should you use in 2026?](https://www.pythonguis.com/faq/which-python-gui-library/)
- [Tauri vs Electron Comparison](https://raftlabs.medium.com/tauri-vs-electron-a-practical-guide-to-picking-the-right-framework-5df80e360f26)
- [Long-Running Tasks Architecture](https://www.ichaoran.com/posts/2024-11-26-long-running-task-app/)

**Tool-Specific:**
- [yt-dlp Not Working? Fix 403 Forbidden Errors](https://www.winxdvd.com/streaming-video/yt-dlp-not-working-fixed.htm)
- [Bypassing the 2026 YouTube "Great Wall"](https://dev.to/ali_ibrahim/bypassing-the-2026-youtube-great-wall-a-guide-to-yt-dlp-v2rayng-and-sabr-blocks-1dk8)
- [scdl - Soundcloud Music Downloader (PyPI)](https://pypi.org/project/scdl/)

### Tertiary Sources (LOW-MEDIUM confidence)

**Domain Pain Points:**
- [Music Playlist Preservation: Why It Matters Most](https://freeyourmusic.com/blog/music-playlist-preservation-explained)
- [What Is Playlist Syncing? Complete Guide](https://freeyourmusic.com/blog/what-is-playlist-syncing-guide)
- [Apple Community - Playlist Ordering by Date Added Issue](https://discussions.apple.com/thread/7728143)
- [Fixing Tags Encoding with Tag Editor](https://amvidia.com/guides/music-organising/fixing-tags-encoding)
- [AAC vs. FLAC: Which is the best for your Audio?](https://www.gumlet.com/learn/aac-vs-flac/)

---
*Research completed: 2026-02-03*
*Ready for roadmap: YES*

**Next Steps:**
1. Roadmapper agent will use phase structure suggestions to create detailed ROADMAP.md
2. Phases 2, 3, 5 flagged for deeper research during planning (dabmusic.xyz API, Apple Music MusicKit, Rockbox specifics)
3. Begin Phase 1 with foundation implementation (database schema, file utilities, atomic operations)
