# Domain Pitfalls: Music Library Management

**Domain:** Music Library Management System
**Researched:** 2026-02-03
**Confidence:** HIGH (verified with official docs and community sources)

## Critical Pitfalls

These mistakes cause reliability failures, data corruption, or require complete rewrites.

### Pitfall 1: Non-Atomic File Operations Leading to Corruption

**What goes wrong:** Downloads or transcoding operations crash mid-write, leaving partially written files that appear complete but are corrupted. The library index references files that are unusable.

**Why it happens:** Directly writing to the final destination without atomic operations. Power loss, process crashes, or disk full conditions during write operations can leave files in an inconsistent state.

**Consequences:**
- Silent corruption where files exist but won't play
- Database points to corrupt files that passed validation
- User discovers corruption weeks later when playback fails
- No way to distinguish partial files from complete ones

**Prevention:**
- Write to temporary file with unique name (e.g., `.tmp-{uuid}`)
- Verify file integrity (checksum, duration validation)
- Atomic rename to final destination only after verification
- Never overwrite existing files directly
- Use `fsync()` before rename to ensure data persistence

**Detection:**
- File size doesn't match expected size from API
- Audio duration is shorter than metadata claims
- FFmpeg reports stream errors during validation
- Missing file header/footer markers

**Phase relevance:** Phase 1 (Download Infrastructure) must implement this from day one.

**Sources:**
- [Atomic File Operations](https://dev.to/martinhaeusler/towards-atomic-file-modifications-2a9n)
- [Files are hard](https://danluu.com/file-consistency/)

---

### Pitfall 2: Ignoring Idempotency in Long-Running Operations

**What goes wrong:** Failed downloads retry but create duplicates, waste bandwidth re-downloading completed portions, or skip tracks entirely. Operations that partially complete cannot be safely retried. The system becomes "gambling whether runs work."

**Why it happens:** No mechanism to track partial progress. Operations aren't designed to be safely retried. Missing or incorrect idempotency keys for non-idempotent operations.

**Consequences:**
- Entire playlist downloads fail because one track errors
- Retrying downloads entire 500MB file instead of resuming
- Duplicate tracks in library with different filenames
- API rate limits hit unnecessarily from redundant requests
- "Works sometimes, doesn't work other times" behavior

**Prevention:**
- Design all operations to be idempotent or use idempotency keys
- Track operation state in database (pending/in-progress/completed/failed)
- Resume partial downloads using HTTP Range headers
- Store operation fingerprint (track ID + source + target quality) to detect duplicates
- Implement exponential backoff with retry budgets
- Separate transient failures (429, 5xx) from permanent failures (404, 403)

**Detection:**
- Same track downloaded multiple times in logs
- Download progress resets to 0% on retry
- Database shows multiple entries for same track
- API quota exhausted faster than expected

**Phase relevance:** Phase 1 (Download Infrastructure) must implement state tracking. Phase 2 (Multi-source aggregation) needs duplicate detection across sources.

**Sources:**
- [Making Retries Safe with Idempotent APIs](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/)
- [Mastering Idempotency: Building Reliable APIs](https://blog.bytebytego.com/p/mastering-idempotency-building-reliable)
- [Idempotent requests | Stripe API Reference](https://docs.stripe.com/api/idempotent_requests)

---

### Pitfall 3: Naive Track Matching Leading to Duplicates

**What goes wrong:** The same song from different sources (Spotify, YouTube, local file) is treated as separate tracks. Or completely different songs are treated as duplicates. Library fills with duplicate tracks or loses legitimate alternates.

**Why it happens:** Relying solely on metadata (artist/title) which varies across platforms. Not using acoustic fingerprinting. No canonical track ID system.

**Consequences:**
- 3 copies of same song: "Song Title", "Song Title [Official]", "Song Title (Remastered)"
- Playlist has 50 tracks but only 30 unique songs
- Can't detect when Spotify track matches local FLAC file
- Deleting duplicates risks removing the only working copy
- Different releases (album version vs. single) incorrectly merged

**Prevention:**
- Implement acoustic fingerprinting with AcoustID/Chromaprint
- Generate fingerprint from first 2 minutes of audio
- Use fingerprint as primary match key, metadata as secondary
- Store multiple source IDs per track (spotify:track:xxx, youtube:xxx)
- Allow manual "mark as duplicate" with confidence scores
- Keep both versions if fingerprints differ significantly
- Normalize metadata for comparison (lowercase, remove brackets, trim)

**Detection:**
- Multiple files with nearly identical names
- Same artist/title with different durations (>30 sec difference)
- Playlist import creates new tracks for all items
- Users report seeing duplicates in UI

**Phase relevance:** Phase 2 (Multi-source Aggregation) core requirement. Phase 3 (Playlist Management) needs this for merge logic.

**Sources:**
- [AcoustID - Open source audio identification](https://acoustid.org/)
- [Chromaprint fingerprinting library](https://github.com/acoustid/chromaprint)
- [MusicBrainz Fingerprinting](https://musicbrainz.org/doc/Fingerprinting)

---

### Pitfall 4: Character Encoding Nightmares in Metadata

**What goes wrong:** Tags with non-ASCII characters (é, ñ, ü, 中文, العربية) display as garbage. Filenames with special characters fail to copy to iPod. Database queries fail to find tracks with accented names.

**Why it happens:** Mixing encoding standards. ID3v2.3 uses ISO-8859-1, ID3v2.4 uses UTF-8, but tools disagree. Filesystem encoding differs between macOS (UTF-8-MAC) and Windows (UTF-16). Database configured for wrong collation.

**Consequences:**
- "Beyoncé" becomes "BeyoncÃ©"
- Search for "Björk" finds nothing
- Files fail to copy: "Invalid filename characters"
- Tags look correct on macOS, broken on Windows
- Japanese/Chinese characters completely lost

**Prevention:**
- Standardize on UTF-8 everywhere possible
- ID3v2.4 tags (UTF-8) for all written files
- Convert filenames to ASCII-safe format for filesystem
- Use NFD normalization on macOS, NFC on Windows/Linux
- Database: UTF8MB4 collation (MySQL) or UTF-8 (PostgreSQL/SQLite)
- Validate encoding on import and fix if needed
- Test with pathological cases: emoji, CJK, RTL scripts

**Detection:**
- Special characters display as � or mojibake
- File operations fail with "invalid characters"
- Search doesn't find tracks you know exist
- Different character counts in database vs. display

**Phase relevance:** Phase 1 (Download Infrastructure) must handle this when saving files. Phase 4 (Filesystem Sync) needs filename sanitization.

**Sources:**
- [Fixing Tags Encoding with Tag Editor](https://amvidia.com/guides/music-organising/fixing-tags-encoding)
- [Complete Guide to Audio Metadata Schemas, Tags and File Formats](https://htcutils.cloud/blog/complete-guide-to-audio-metadata-schemas-tags-and-file-formats)
- [Encoding issue for metadata - GitHub Issue](https://github.com/vanilla-music/vanilla/issues/461)

---

### Pitfall 5: API Token Expiration Without Graceful Handling

**What goes wrong:** Bulk operations fail midway when API tokens expire. User sees "Authentication failed" after 6 months. Background sync stops working silently.

**Why it happens:** Not monitoring token TTL. Assuming tokens are permanent. No refresh mechanism. Operations don't handle 401 responses gracefully.

**Consequences:**
- 500-track playlist download fails at track 247 due to expired token
- User doesn't know sync stopped until they notice missing songs weeks later
- Manual re-authentication required every 6 months (Spotify) or 1-2 days (Apple Music)
- Failed operation leaves database in inconsistent state

**Prevention:**
- Store token expiration time in database
- Check expiration before each operation (with 5-minute buffer)
- Implement automatic token refresh flow for Spotify (refresh_token)
- For Apple Music: detect 401, prompt re-authentication, resume operation
- Pause long-running operations to refresh token mid-operation
- Surface token status in UI ("Spotify: expires in 3 days")
- Background job to refresh tokens proactively

**Detection:**
- API calls return 401 Unauthorized after previously working
- Spotify: error "Token expired" after 1 hour
- Apple Music: "Music User Token invalid" after 6 months or password change
- Logs show authentication errors after long idle periods

**Phase relevance:** Phase 1 (Download Infrastructure) needs retry logic. Phase 5 (Background Sync) must handle expired tokens gracefully.

**Sources:**
- [Spotify Rate Limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits)
- [Apple Music API - Generating Developer Tokens](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens)
- [Apple Music user token expiration - Apple Developer Forums](https://developer.apple.com/forums/thread/744156)

---

### Pitfall 6: Transcoding Without Quality Validation

**What goes wrong:** FLAC transcodes to AAC but sounds terrible. Files transcode successfully but are silent. Bitrate is correct but audio is clipped/distorted. User doesn't discover until listening weeks later.

**Why it happens:** Not validating output quality. Relying on exit code alone. Wrong encoder settings. Cascading lossy transcodes (AAC→MP3→AAC). Not testing with diverse input sources.

**Consequences:**
- All transcoded files sound bad but pass all checks
- 500 tracks transcoded with wrong settings, must redo all
- "Successfully transcoded" but file is silence or noise
- Clipping/distortion from incorrect volume normalization
- Generation loss from re-encoding already-lossy sources

**Prevention:**
- Validate output with FFmpeg: check stream info, duration, sample rate
- Never transcode lossy→lossy (keep original if already AAC/MP3)
- Use high-quality encoder: ffmpeg -c:a libfdk_aac or native aac
- Match output duration to input (within 1 second tolerance)
- Test transcoding pipeline with diverse files before bulk operations
- Store source format in database to prevent cascading transcodes
- Use loudness normalization (EBU R128) not peak normalization
- Keep FLAC originals if storage permits

**Detection:**
- Output file duration != input duration
- FFmpeg warnings: "Audio queue is too large", "clipping detected"
- Bitrate correct but file size suspiciously small
- Spectral analysis shows low-pass filter artifacts
- Users report quality issues

**Phase relevance:** Phase 1 (Download Infrastructure) if transcoding immediately. Phase 4 (Filesystem Sync) if transcoding for Rockbox.

**Sources:**
- [AAC vs. FLAC: Which is the best for your Audio?](https://www.gumlet.com/learn/aac-vs-flac/)
- [Audio Transcoding Quality Loss - Fedora Discussion](https://discussion.fedoraproject.org/t/lossless-flac-transcoding-to-lossy-opus-ogg-mp3-aac-formats/86358)
- [Audio transcoding bitrate hard-capped at 256 kbps - Jellyfin Issue](https://github.com/jellyfin/jellyfin/issues/15922)

---

### Pitfall 7: Playlist Order Not Preserved

**What goes wrong:** Playlist syncs but tracks are in random order. Order correct initially but changes after re-sync. User curated order is lost.

**Why it happens:** Using Set instead of List in code. Relying on database ORDER BY without explicit position field. Race conditions in parallel downloads. Not storing playlist position in schema.

**Consequences:**
- DJ mixes play in wrong order, ruining the flow
- Album tracks shuffle randomly
- Re-syncing playlist scrambles the order
- Users lose trust in the system

**Prevention:**
- Store explicit position/index field (0-based or 1-based)
- Use array/list data structures that preserve order
- Never rely on implicit ordering (insertion order, alphabetical)
- Add unique constraint on (playlist_id, position)
- When syncing: diff old vs. new order, only update if changed
- For parallel downloads: assign position first, download later
- Validate order preservation in tests with known playlists
- Include snapshot_id (Spotify) to detect playlist changes

**Detection:**
- Playlist plays tracks in different order than source
- Position field has duplicates or gaps
- Order changes between app restarts
- User reports "playlist is shuffled"

**Phase relevance:** Phase 3 (Playlist Management) core requirement. Phase 4 (Filesystem Sync) needs to preserve order in filesystem layout.

**Sources:**
- [Music Playlist Preservation: Why It Matters Most](https://freeyourmusic.com/blog/music-playlist-preservation-explained)
- [What Is Playlist Syncing? Complete Guide](https://freeyourmusic.com/blog/what-is-playlist-syncing-guide)
- [7 Essential Cross-Platform Playlist Tips](https://freeyourmusic.com/blog/7-essential-cross-platform-playlist-tips)

## Moderate Pitfalls

Mistakes that cause delays, technical debt, or operational pain.

### Pitfall 8: Spotify API Rate Limiting Without Backoff

**What goes wrong:** Bulk operations hit rate limit and fail. Receive 429 errors without retry logic. Entire download batch aborted.

**Why it happens:** No rate limiting strategy. Ignoring Retry-After header. Parallel requests exceeding rate limit. Not using batch endpoints.

**Prevention:**
- Implement exponential backoff with jitter
- Honor Retry-After header in 429 responses (wait specified seconds)
- Use batch endpoints (Get Multiple Tracks) to reduce API calls
- Track API quota usage via Developer Dashboard
- Implement client-side rate limiting (e.g., max 50 req/30sec)
- Cache responses when possible (use snapshot_id for playlists)
- Apply for Extended Quota Mode if building multi-user app
- Monitor retry metrics to detect systemic issues

**Detection:**
- HTTP 429 "Too Many Requests" responses
- Sudden surge in failed API calls
- Quota exhausted earlier than expected
- Retry-After header in response

**Phase relevance:** Phase 2 (Multi-source Aggregation) when fetching metadata. Phase 5 (Background Sync) for continuous operations.

**Sources:**
- [Spotify API Rate Limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits)
- [Spotify API Quota Modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
- [Mastering Spotify API: Graceful Rate Limiting](https://tossthecoin.tcl.com/blog/mastering-spotify-api-graceful-rate)

---

### Pitfall 9: YouTube Download Fragility (yt-dlp)

**What goes wrong:** Downloads that worked yesterday fail today. 403 Forbidden errors. Download speed throttled to unusable levels. YouTube Music downloads fail with signature errors.

**Why it happens:** YouTube constantly updates anti-download measures. Using outdated yt-dlp version. Not using cookies. Corporate firewalls blocking yt-dlp traffic patterns. SABR (Server-Based Adaptive Bit Rate) killing connections.

**Prevention:**
- Keep yt-dlp updated to nightly builds (not just stable releases)
- Extract and use valid browser cookies (--cookies-from-browser chrome)
- Implement sleep intervals between downloads (--sleep-interval)
- Use combined formats instead of separate video+audio when possible
- Install Deno for JS player execution (future requirement)
- Maintain Python 3.10+ for compatibility
- Have fallback strategy when yt-dlp fails (dabmusic.xyz preferred)
- Monitor yt-dlp GitHub/Reddit for breaking changes
- Use yt-dlp as last resort, not primary source

**Detection:**
- HTTP 403 Forbidden on download attempts
- "n challenge solving failed" errors
- Connection reset errors (10054)
- Downloads succeed with --cookies but fail without
- Sudden spike in YouTube download failures

**Phase relevance:** Phase 1 (Download Infrastructure) only for YouTube fallback. Phase 2 (Multi-source Aggregation) if YouTube is a primary source.

**Sources:**
- [Bypassing the 2026 YouTube "Great Wall"](https://dev.to/ali_ibrahim/bypassing-the-2026-youtube-great-wall-a-guide-to-yt-dlp-v2rayng-and-sabr-blocks-1dk8)
- [yt-dlp Not Working? Fix 403 Forbidden & 'Failed to Get Info' Errors](https://www.winxdvd.com/streaming-video/yt-dlp-not-working-fixed.htm)
- [YouTube Music download fails with signature solving errors](https://github.com/JunkFood02/Seal/issues/2404)

---

### Pitfall 10: SoundCloud Download Unreliability (scdl)

**What goes wrong:** scdl downloads work intermittently. Can't batch-download playlists. Service discontinued in some regions. API breakage when SoundCloud updates.

**Why it happens:** scdl development not actively maintained (as of v3, it's a wrapper around yt-dlp). SoundCloud API changes break scdl. Rate limiting issues. Regional restrictions.

**Prevention:**
- Use yt-dlp directly for SoundCloud (scdl v3 uses yt-dlp internally anyway)
- Implement retry logic with exponential backoff
- Have fallback source if SoundCloud download fails
- Track SoundCloud API changes via scdl GitHub issues
- Test SoundCloud downloads regularly to detect breakage
- Don't rely solely on scdl for critical operations
- Consider paid SoundCloud Go+ for better API access

**Detection:**
- scdl returns errors: "preload failed"
- Downloads only work sometimes
- Batch operations fail without clear error
- API authentication errors

**Phase relevance:** Phase 1 (Download Infrastructure) if supporting SoundCloud. Phase 2 (Multi-source Aggregation) may deprioritize SoundCloud.

**Sources:**
- [scdl - Soundcloud Music Downloader (PyPI)](https://pypi.org/project/scdl/)
- [Only works sometimes - scdl GitHub Issue #381](https://github.com/scdl-org/scdl/issues/381)
- [Top 11 Best Free SoundCloud Downloaders in 2026](https://www.macsome.com/music-one-tips/best-soundcloud-downloader.html)

---

### Pitfall 11: Cross-Platform Filesystem Incompatibilities

**What goes wrong:** Files sync correctly on macOS but fail on Windows. Filenames with special characters rejected by Rockbox. Case-sensitive filename collisions (Song.mp3 vs. song.mp3).

**Why it happens:** Different filename restrictions across platforms. macOS (UTF-8-MAC), Windows (UTF-16, invalid chars: `<>:"|?*`), Linux (UTF-8, nearly unrestricted). Case-sensitive (Linux) vs. case-insensitive (macOS/Windows) filesystems. FAT32 limitations on Rockbox iPod.

**Consequences:**
- Sync works on dev machine (macOS) but fails on user's Windows PC
- Files copy to iPod but don't appear in Rockbox
- Two tracks collapse into one due to case collision
- Special characters in filenames cause copy failures

**Prevention:**
- Sanitize filenames for lowest common denominator (FAT32)
- Replace invalid characters with safe alternatives: `<>:"|?*` → `_`
- Limit filename length to 255 bytes (UTF-8 encoded)
- Normalize Unicode: NFD on macOS, NFC elsewhere
- Test sync on all target platforms (macOS, Windows, Linux, Rockbox)
- Use numeric IDs in filenames as fallback: `{track_id}_{artist}_{title}.m4a`
- Avoid case-only filename differences
- Store original filename in metadata/database, use sanitized version on disk

**Detection:**
- File copy operations fail with "invalid characters"
- Tracks visible in database but missing on filesystem
- Duplicate filename errors on case-insensitive systems
- Rockbox doesn't show some tracks

**Phase relevance:** Phase 4 (Filesystem Sync) critical for Rockbox compatibility. Phase 1 (Download Infrastructure) should sanitize filenames immediately.

**Sources:**
- [Rockbox - Free Music Player Firmware](https://www.rockbox.org/)
- [RockBox On The IPod Classic: A Complete Guide](https://partspluspods.com.au/2025/10/29/rockbox-on-the-ipod-classic-a-complete-guide/)
- Project context requirements

---

### Pitfall 12: Database Schema Without Source Tracking

**What goes wrong:** Can't tell which source a track came from. Re-syncing re-downloads everything. Can't update metadata when source updates. Deleting source removes tracks without warning.

**Why it happens:** Schema only stores final track, not source relationships. Treating all sources as equal. No many-to-many relationship between tracks and sources.

**Prevention:**
- Many-to-many schema: tracks ←→ track_sources ←→ sources
- Store source metadata: `source_type` (spotify/apple/soundcloud/youtube/local), `source_id` (external ID), `source_url`, `added_at`, `last_synced_at`
- Track which source provided the file currently on disk
- When re-syncing: compare source_ids to detect changes
- Allow multiple sources per track (track available on both Spotify and YouTube)
- Store source priority: prefer FLAC over AAC over YouTube
- Flag orphaned tracks when source removed

**Detection:**
- Can't answer "where did this track come from?"
- Re-sync downloads files already on disk
- Deleting Spotify integration removes tracks from Apple Music
- No way to update metadata from source

**Phase relevance:** Phase 2 (Multi-source Aggregation) requires this schema. Phase 5 (Background Sync) depends on source tracking.

**Sources:**
- [How to Design a Database for Music Streaming App](https://www.geeksforgeeks.org/sql/how-to-design-a-database-for-music-streaming-app/)
- [Dancing with Data - Building a Music Database](https://medium.com/@patryk.maczek/dancing-with-data-how-i-built-a-tango-music-database-and-what-went-wrong-ff53791a26a1)
- [MusicBrainz Database Schema](https://musicbrainz.org/doc/MusicBrainz_Database/Schema)

## Minor Pitfalls

Mistakes that cause annoyance but are easily fixable.

### Pitfall 13: No Progress Indication for Long Operations

**What goes wrong:** User doesn't know if download is frozen or just slow. No way to estimate completion time. Operations appear stuck.

**Prevention:**
- Emit progress events: current/total tracks, bytes downloaded
- Calculate ETA based on recent throughput
- Show current operation: "Downloading: Artist - Track"
- Persist progress to database (resume after crash)
- Add timeout detection (no progress for 60s = stuck)

**Phase relevance:** Phase 1 (Download Infrastructure). Important for UX but not blocking.

---

### Pitfall 14: Hardcoded File Paths

**What goes wrong:** Breaks when user moves library. Fails on different OS. Can't support multiple libraries.

**Prevention:**
- Store base path in config
- Use relative paths in database
- Resolve full path at runtime: `base_path + relative_path`
- Support environment variables: `$HOME/Music`

**Phase relevance:** Phase 1 (Download Infrastructure). Easy to fix early, painful to migrate later.

---

### Pitfall 15: Ignoring Duplicate Detection Edge Cases

**What goes wrong:** Live versions treated as duplicates of studio versions. Remasters treated as duplicates of originals. Covers/remixes falsely matched.

**Prevention:**
- Use acoustic fingerprinting, not just metadata
- Set fingerprint match threshold (e.g., 85% similarity)
- Allow user to override: "Keep both versions"
- Store release type in metadata (album/single/live/remix)
- Fuzzy match metadata but require high confidence for auto-merge

**Phase relevance:** Phase 2 (Multi-source Aggregation). Can be refined over time.

---

### Pitfall 16: Not Handling Missing Dependencies

**What goes wrong:** ffmpeg not installed, downloads succeed but transcoding fails silently. scdl missing, SoundCloud downloads fail without clear error.

**Prevention:**
- Check for required tools at startup: ffmpeg, yt-dlp, scdl
- Show clear error: "ffmpeg not found. Install with: brew install ffmpeg"
- Gracefully degrade: skip transcoding if ffmpeg missing
- Include installation instructions in README

**Phase relevance:** Phase 1 (Download Infrastructure). One-time setup.

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Download Infrastructure | Non-atomic file operations (Pitfall 1) | Implement temp file + atomic rename pattern immediately |
| Download Infrastructure | No idempotency/retry logic (Pitfall 2) | Build state tracking into database schema from start |
| Multi-source Aggregation | Naive metadata matching (Pitfall 3) | Integrate AcoustID/Chromaprint early, before accumulating duplicates |
| Multi-source Aggregation | API rate limiting (Pitfall 8) | Implement backoff and batch endpoints before bulk operations |
| Playlist Management | Order not preserved (Pitfall 7) | Add position field to schema, test with known playlists |
| Filesystem Sync | Character encoding issues (Pitfall 4) | Sanitize filenames for FAT32, normalize Unicode |
| Filesystem Sync | Cross-platform incompatibilities (Pitfall 11) | Test on all target platforms early |
| Background Sync | Token expiration (Pitfall 5) | Monitor token TTL, implement refresh flow |
| Quality Validation | Transcoding without validation (Pitfall 6) | Validate output duration, format, and stream info |

## Reliability Anti-Patterns

Based on project context ("gambling whether runs work"), avoid these patterns:

1. **Silent Failures**: Operations fail but return success. User discovers issues later. → Always validate results, log failures prominently.

2. **All-or-Nothing Operations**: 500-track download fails at track 247, must restart from beginning. → Checkpoint progress, support resume.

3. **Assuming External Services Are Reliable**: "YouTube will always work." → Implement graceful degradation, fallback sources.

4. **No Observability**: Can't tell what the system is doing or why it failed. → Structured logging, metrics, status dashboard.

5. **Manual Retry Required**: User must manually trigger retry after failure. → Automatic retry with exponential backoff.

6. **Tight Coupling to External APIs**: Direct API calls throughout codebase. → Adapter pattern with fallback strategies.

7. **No Health Checks**: System appears to work but stopped syncing weeks ago. → Periodic health checks, alert on staleness.

## Testing Recommendations

To avoid these pitfalls, test with:

- **Adversarial inputs**: Tracks with emoji, RTL scripts, special characters in titles
- **Failure injection**: Kill process mid-download, disconnect network, full disk
- **Rate limit simulation**: Mock 429 responses, verify backoff behavior
- **Large-scale testing**: 10,000 track library, not just 10 tracks
- **Multi-platform testing**: macOS, Windows, Linux, actual Rockbox iPod
- **Time-based testing**: Token expiration, long-running operations
- **Edge cases**: Empty playlists, deleted tracks, region-restricted content

## Sources

**Official Documentation:**
- [Spotify API Rate Limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits)
- [Apple Music API - Generating Developer Tokens](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens)
- [AcoustID - Open source audio identification](https://acoustid.org/)
- [Chromaprint fingerprinting library](https://github.com/acoustid/chromaprint)
- [MusicBrainz Fingerprinting](https://musicbrainz.org/doc/Fingerprinting)

**Reliability & Architecture:**
- [Making Retries Safe with Idempotent APIs (AWS)](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/)
- [Mastering Idempotency: Building Reliable APIs](https://blog.bytebytego.com/p/mastering-idempotency-building-reliable)
- [Stripe API Idempotent Requests](https://docs.stripe.com/api/idempotent_requests)
- [Atomic File Operations](https://dev.to/martinhaeusler/towards-atomic-file-modifications-2a9n)
- [Files are hard (file consistency)](https://danluu.com/file-consistency/)

**Domain-Specific Issues:**
- [Fixing Tags Encoding with Tag Editor](https://amvidia.com/guides/music-organising/fixing-tags-encoding)
- [Complete Guide to Audio Metadata Schemas, Tags and File Formats](https://htcutils.cloud/blog/complete-guide-to-audio-metadata-schemas-tags-and-file-formats)
- [AAC vs. FLAC: Which is the best for your Audio?](https://www.gumlet.com/learn/aac-vs-flac/)
- [Music Playlist Preservation: Why It Matters Most](https://freeyourmusic.com/blog/music-playlist-preservation-explained)
- [Rockbox - Free Music Player Firmware](https://www.rockbox.org/)

**Tool-Specific:**
- [yt-dlp Not Working? Fix 403 Forbidden Errors](https://www.winxdvd.com/streaming-video/yt-dlp-not-working-fixed.htm)
- [Bypassing the 2026 YouTube "Great Wall"](https://dev.to/ali_ibrahim/bypassing-the-2026-youtube-great-wall-a-guide-to-yt-dlp-v2rayng-and-sabr-blocks-1dk8)
- [scdl - Soundcloud Music Downloader (PyPI)](https://pypi.org/project/scdl/)

**Database Design:**
- [How to Design a Database for Music Streaming App](https://www.geeksforgeeks.org/sql/how-to-design-a-database-for-music-streaming-app/)
- [MusicBrainz Database Schema](https://musicbrainz.org/doc/MusicBrainz_Database/Schema)
- [Dancing with Data - Building a Music Database](https://medium.com/@patryk.maczek/dancing-with-data-how-i-built-a-tango-music-database-and-what-went-wrong-ff53791a26a1)
