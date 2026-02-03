# Phase 2: Download Infrastructure - Context

**Gathered:** 2026-02-03
**Status:** Ready for planning

<domain>
## Phase Boundary

Build a download pipeline that retrieves audio files from dabmusic.xyz with YouTube fallback, transcodes to 248kbps AAC, and handles failures gracefully. This phase proves single-source reliability before Phase 3 adds multi-source complexity.

</domain>

<decisions>
## Implementation Decisions

### Source Priority & Fallback
- dabmusic.xyz is the primary source — try it first for every track
- Fall back to YouTube only when track is NOT FOUND on dabmusic (404)
- On dabmusic errors (timeout, rate limit): retry dabmusic 2-3 times before falling back
- YouTube fallback uses best available audio (yt-dlp bestaudio) — no minimum threshold

### Transcode Behavior
- If source is already lossy and below 248kbps: keep original format, don't transcode (avoid quality loss)
- If source is FLAC or high-quality: transcode to 248kbps AAC
- Keep both FLAC originals and AAC transcodes
- FLAC storage: expand existing file structure on Lexar SSD (existing library location)
- AAC storage: temp location mirroring the FLAC structure (staging for device sync)
- Encoder: ffmpeg with libfdk_aac (highest quality AAC encoder)

### Progress & Feedback
- Per-track updates: "Downloading Track 3/50: Artist - Title..."
- Sequential downloads (one at a time) — simpler, avoids rate limits
- Standard logging: start/complete per track, errors, summary at end
- Batch import to library at end of download session, not per-track

### Failure Handling
- When both sources fail: queue for retry (don't block batch, don't lose track)
- Partial/interrupted downloads: delete and restart fresh (no resume)
- 3 retries with backoff before marking as failed
- Transcode failure: keep the original file, mark transcode as pending (don't re-download)

### Claude's Discretion
- Exact retry backoff timing
- Temp directory location for AAC staging
- How to detect "not found" vs other errors from dabmusic API
- Retry queue persistence format

</decisions>

<specifics>
## Specific Ideas

- Lexar SSD is the canonical FLAC storage location — expand existing structure there
- AAC files are staging for iPod sync — treat as derived/temporary
- "Pending retry" queue should survive app restart

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-download-infrastructure*
*Context gathered: 2026-02-03*
