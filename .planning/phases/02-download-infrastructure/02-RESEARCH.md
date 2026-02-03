# Phase 2: Download Infrastructure - Research

**Researched:** 2026-02-03
**Domain:** Audio download pipeline, HTTP clients, audio transcoding, error handling
**Confidence:** HIGH (core stack), MEDIUM (DAB API edge cases), HIGH (common pitfalls)

## Summary

This phase builds a single-source download pipeline with YouTube fallback for retrieving audio files. The research identifies production-ready Rust libraries for HTTP downloads (reqwest), audio transcoding (ffmpeg via Rust bindings), YouTube fallback (yt-dlp), and resilience patterns (backoff crate). The DAB Music API uses standard HTTP status codes but lacks explicit 404 documentation for "not found" vs other failures—requiring inference from HTTP response status matching during implementation.

**Key constraints from user decisions:**
- Sequential downloads (not parallel) simplify rate limiting
- ffmpeg with libfdk_aac encoder required (must be compiled, not pre-built)
- 248kbps AAC M4A target matches SoundCloud Go+ quality
- Retry queue must persist across app restarts

**Primary recommendation:** Use reqwest 0.13+ for async HTTP, backoff 0.4 for exponential retry logic, Symphonia 0.5.5 for audio format detection, and persistent file-based queue (yaque or custom JSON file) for retry durability.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| reqwest | 0.13.1+ | Async HTTP client | Most popular Rust HTTP library, Tokio integration, streaming response support for large files |
| tokio | 1.x | Async runtime | Already in project dependencies, required by reqwest |
| backoff | 0.4.0 | Exponential backoff/retry | Industry standard retry pattern, async support, proven for rate limiting scenarios |
| ffmpeg (via Rust bindings) | 8.0.0 | Audio transcoding | Safe Rust wrapper for FFmpeg, supports FLAC/AAC encoding |
| yt-dlp (Rust crate) | Latest | YouTube audio extraction | Async wrapper around yt-dlp CLI, handles format selection automatically |
| Symphonia | 0.5.5 | Audio codec detection | Pure Rust, no C dependencies needed for basic format/bitrate detection, supports FLAC/AAC/MP3 |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| serde_json | 1.x | Persistent queue storage | Serializing retry queue to disk for app restart durability |
| indicatif | 0.17+ | Progress feedback | Already in project, use for CLI/logging progress during downloads (per-track updates) |
| lofty | 0.22+ | Metadata reading | Already in project, can verify audio format/bitrate without full decode |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| reqwest | hyper | Lower-level control, but requires more boilerplate; reqwest abstractions match our use case |
| backoff | manual retry loops | Less reliable, more bugs in backoff calculation; battle-tested crate is safer |
| Symphonia | ffmpeg probe | Symphonia avoids spawning external process for format detection; both work but Symphonia lighter-weight |
| yt-dlp crate | shell invocation | Crate handles versioning/updates automatically; shell invocation needs CLI installed separately |

**Installation:**
```bash
cargo add reqwest --features json
cargo add backoff --features tokio
cargo add yt-dlp
cargo add serde_json
```

Note: ffmpeg must be compiled with libfdk_aac support locally (not a Cargo dependency issue).

## Architecture Patterns

### Recommended Download Pipeline Flow

```
┌─────────────────────────────────────────┐
│ For each track in batch                 │
├─────────────────────────────────────────┤
│ 1. Query DAB API (with backoff retry)   │
│    ├─ Success (200): Get FLAC download  │
│    ├─ 404: Fall back to YouTube         │
│    └─ Other error: Queue for retry      │
│                                         │
│ 2. If YouTube fallback:                 │
│    ├─ yt-dlp bestaudio extraction       │
│    └─ Keep original format (no transcode│
│       if already lossy <248kbps)        │
│                                         │
│ 3. Transcode decision:                  │
│    ├─ FLAC or high-bitrate: → 248k AAC │
│    ├─ Already lossy <248k: Keep original│
│    └─ Transcode fail: Mark as pending   │
│       (don't re-download source)        │
│                                         │
│ 4. Storage:                             │
│    ├─ FLAC original → Lexar SSD         │
│    ├─ AAC transcode → Temp staging dir  │
│    └─ UI: "Downloading Track 3/50..."   │
│                                         │
│ 5. Failures:                            │
│    ├─ Both sources fail → Retry queue   │
│    └─ Partial download → Delete, restart│
│       (no resume)                       │
│                                         │
│ 6. End of batch:                        │
│    └─ Batch import to library (not      │
│       per-track)                        │
└─────────────────────────────────────────┘
```

### Pattern 1: Backoff-Protected DAB API Calls

**What:** Exponential backoff with 3 retry attempts before fallback

**When to use:** All DAB API calls (search, stream, download endpoints)

**Example:**
```rust
// Source: https://docs.rs/backoff/latest/backoff/
use backoff::ExponentialBackoff;
use reqwest::StatusCode;

async fn fetch_from_dab(track_id: &str, client: &reqwest::Client) -> Result<Vec<u8>> {
    let backoff = ExponentialBackoff::default();
    backoff::future::retry(backoff, || async {
        let resp = client
            .get(&format!("https://dabmusic.xyz/api/stream/{}", track_id))
            .send()
            .await?;

        match resp.status() {
            StatusCode::OK => Ok(resp.bytes().await?.to_vec()),
            StatusCode::NOT_FOUND => Err(backoff::Error::permanent(
                anyhow::anyhow!("Track not found on DAB")
            )),
            _ => Err(backoff::Error::transient(
                anyhow::anyhow!("Transient error: {}", resp.status())
            )),
        }
    })
    .await
}
```

### Pattern 2: Detect Not-Found vs Other Errors

**What:** Match HTTP status codes to distinguish DAB "not found" from retryable errors

**When to use:** After DAB API response received, before deciding fallback

**Example:**
```rust
// Source: https://docs.rs/reqwest/latest/reqwest/struct.Response.html
match client.get(url).send().await {
    Ok(resp) => {
        match resp.status() {
            StatusCode::NOT_FOUND => {
                // This is the trigger for YouTube fallback
                fallback_to_youtube(track_id).await
            }
            s if s.is_client_error() => {
                // Bad request, invalid param → don't retry
                queue_for_manual_review(track_id)
            }
            s if s.is_server_error() => {
                // 5xx → retryable (backoff handles this)
                // Already inside backoff::retry block
            }
            _ => {
                // Successful download
            }
        }
    }
    Err(e) => {
        // Network/timeout error → backoff::Error::transient
        // Already inside backoff::retry block
    }
}
```

### Pattern 3: Audio Format Detection Before Transcode

**What:** Read audio metadata to decide transcode strategy

**When to use:** After downloading file, before queuing transcode task

**Example:**
```rust
// Source: https://github.com/pdeljanov/Symphonia
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;

fn should_transcode(file_path: &str) -> Result<bool> {
    let file = std::fs::File::open(file_path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    hint.with_extension("flac");

    let probed = symphonia::default::get_probe().format(
        &hint, mss, &Default::default(), &Default::default()
    )?;

    let format = probed.format;

    // Check: if FLAC, always transcode
    if format.codec_params[0].codec == symphonia::core::codecs::CODEC_TYPE_FLAC {
        return Ok(true);
    }

    // Check: if lossy and bitrate < 248k, don't transcode
    if let Some(br) = format.codec_params[0].bitrate {
        if br < 248_000 {
            return Ok(false);
        }
    }

    Ok(true)
}
```

### Pattern 4: Persistent Retry Queue

**What:** JSON-based queue stored on disk, survives app restart

**When to use:** When both DAB and YouTube fail, or transcode fails permanently

**Example:**
```rust
// Source: https://docs.rs/serde/latest/serde/
use serde::{Serialize, Deserialize};
use std::path::Path;

#[derive(Serialize, Deserialize, Debug)]
struct RetryQueueItem {
    track_id: String,
    source: String, // "dab" or "youtube"
    attempt_count: u32,
    last_error: String,
    queued_at: chrono::DateTime<chrono::Utc>,
}

fn persist_retry_queue(items: &[RetryQueueItem], path: &Path) -> Result<()> {
    let json = serde_json::to_string_pretty(items)?;
    std::fs::write(path, json)?;
    Ok(())
}

fn load_retry_queue(path: &Path) -> Result<Vec<RetryQueueItem>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let json = std::fs::read_to_string(path)?;
    Ok(serde_json::from_str(&json)?)
}
```

### Pattern 5: Streaming Download with Progress

**What:** Stream response body to disk, tracking bytes downloaded

**When to use:** All file downloads (DAB FLAC, YouTube audio)

**Example:**
```rust
// Source: https://rust-lang-nursery.github.io/rust-cookbook/web/clients/download.html
use futures_util::StreamExt;

async fn download_with_progress(url: &str, output_path: &Path) -> Result<()> {
    let client = reqwest::Client::new();
    let resp = client.get(url).send().await?;
    let total_size = resp.content_length().unwrap_or(0);

    let mut file = std::fs::File::create(output_path)?;
    let mut stream = resp.bytes_stream();
    let mut downloaded = 0u64;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        downloaded += chunk.len() as u64;
        file.write_all(&chunk)?;

        // Emit progress to UI via Tauri channel
        // "Downloading Track 3/50: Artist - Title... (42%)"
    }

    Ok(())
}
```

### Anti-Patterns to Avoid

- **Parallel downloads without rate limit awareness:** DAB API may have rate limits; sequential downloads are safer and simpler per user decision
- **Resuming partial downloads:** User decided to delete and restart fresh; resuming adds complexity with uncertain partial states
- **Re-downloading when only transcode fails:** Transcode failures should mark AAC as "pending" and keep FLAC; don't burden network
- **Mixing binary FLAC with lossy MP3 in retry queue:** Audio quality inconsistency; track source (DAB vs YouTube) separately in queue

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Retry logic with backoff | Manual loop with sleep() | backoff 0.4 crate | Exponential backoff has subtle timing math; crate handles jitter, max intervals, permanent vs transient errors |
| HTTP status code handling | String matching on error | reqwest StatusCode enum | Status codes have semantic meaning; enum pattern matching is safer and more idiomatic |
| Audio format detection | File extension checking | Symphonia probe | Extensions lie; malformed headers break extensions; Symphonia reads actual codec metadata |
| File-based queue persistence | Write JSON each time | serde_json + file lock | Concurrent access, partial writes, recovery after crash—serde handles serialization safely |
| Download progress tracking | Collect entire body then write | Stream body chunks | Memory explosion on large files; streaming to disk is standard practice |
| yt-dlp integration | Shell invocation with spawn() | yt-dlp Rust crate | Crate manages version compatibility, output parsing, error handling—spawning adds subprocess complexity |

**Key insight:** Download pipelines have many "simple" failure modes—corrupted partial files, stale queue data, retry loops that never finish, race conditions in persistence. Use battle-tested crates instead of custom implementations.

## Common Pitfalls

### Pitfall 1: Confusing 404 "Not Found" with Network Errors

**What goes wrong:** DAB API returns 404 for "track not found" and also returns 404 for other reasons (malformed request, rate limit). Code treats all 404s the same, triggering YouTube fallback for a malformed request instead of retrying with fixed parameters.

**Why it happens:** HTTP status codes are overloaded semantically; we need application-level context.

**How to avoid:** Always check error response body and DAB API documentation for distinguishing "resource not found" from "bad request." Verify with integration tests against real API that 404 triggers fallback correctly.

**Warning signs:** YouTube video downloads succeeding when DAB should have worked; high fallback rate for popular tracks.

### Pitfall 2: Transcode Failures Block Batch Import

**What goes wrong:** Single transcode failure (corrupt FLAC, ffmpeg crash) blocks the entire batch import, losing progress for successfully downloaded tracks.

**Why it happens:** Centralized batch import at the end means one failure cascades.

**How to avoid:** Mark transcode as "pending retry" in metadata (not blocking), continue with next track. Batch import only completed+transcoded items. Retry pending transcodes in background.

**Warning signs:** Empty library after batch run that had 1 failed transcode.

### Pitfall 3: Retry Queue Grows Unbounded

**What goes wrong:** Tracks queued for retry stay in queue forever, consuming disk space and memory when queue is loaded into memory for retry batch.

**Why it happens:** No TTL or max attempt limit on retry queue items.

**How to avoid:** Implement max attempt count (3 per user decision), remove items after exceeding max attempts, add a "retry_after" timestamp to avoid immediate re-retry.

**Warning signs:** Queue file growing over time, retry batches processing same failed tracks repeatedly.

### Pitfall 4: Forgetting libfdk_aac is Non-Free

**What goes wrong:** Pre-built ffmpeg doesn't have libfdk_aac (license incompatibility with GPL). User builds system without libfdk_aac available, AAC encoding fails silently or falls back to lower-quality aac codec.

**Why it happens:** libfdk_aac requires custom compilation with `--enable-nonfree --enable-gpl` flags; not in standard distro packages.

**How to avoid:** Document ffmpeg build requirements explicitly. Add runtime check: detect if libfdk_aac is available via `ffmpeg -encoders | grep fdk_aac`. Fail early with helpful error message if unavailable.

**Warning signs:** AAC files encoding successfully but with lower quality than expected; users getting different quality results.

### Pitfall 5: Treating All DAB Errors Identically

**What goes wrong:** Rate limit (429) triggers YouTube fallback immediately instead of backing off and retrying. User ends up with lower-quality YouTube files for high-frequency searches.

**Why it happens:** Backoff library needs to distinguish "transient" (retry) from "permanent" (don't retry) errors.

**How to avoid:** Map HTTP status codes correctly to backoff error types: 429 (rate limit) → transient, 404 (not found) → permanent, 5xx (server error) → transient, 4xx except 404 → permanent.

**Warning signs:** Sudden switch to YouTube fallback during batch runs; no spike in actual errors on server side.

### Pitfall 6: File Corruption on Interrupted Download

**What goes wrong:** Download interrupted mid-stream, partial file left on disk. Next run attempts to transcode the partial file, fails, marks as "pending" forever.

**Why it happens:** No atomic file write; file exists but is incomplete.

**How to avoid:** Write to temp file, move to final location atomically only after successful download completion. On startup, clean up any temp files from interrupted sessions.

**Warning signs:** Inconsistent file sizes for same track; transcode failures on files that were half-downloaded.

## Code Examples

Verified patterns from official sources:

### HTTP Status Code Matching for 404 Detection

```rust
// Source: https://docs.rs/reqwest/latest/reqwest/
use reqwest::StatusCode;

async fn fetch_track_or_fallback(
    client: &reqwest::Client,
    track_id: &str,
) -> Result<TrackSource> {
    let resp = client
        .get(&format!("https://dabmusic.xyz/api/stream/{}", track_id))
        .send()
        .await;

    match resp {
        Ok(response) => {
            match response.status() {
                StatusCode::OK => {
                    // Successfully found and downloaded
                    Ok(TrackSource::Dab(response.bytes().await?))
                }
                StatusCode::NOT_FOUND => {
                    // This is the signal to use YouTube fallback
                    fallback_to_youtube(track_id).await
                }
                _ => {
                    // Other HTTP errors
                    Err(anyhow::anyhow!("HTTP {}", response.status()))
                }
            }
        }
        Err(e) => Err(e.into()),
    }
}
```

### Exponential Backoff with Transient/Permanent Classification

```rust
// Source: https://docs.rs/backoff/0.4.0/backoff/
use backoff::future::retry;
use backoff::ExponentialBackoff;

async fn dab_api_with_backoff(
    client: &reqwest::Client,
    track_id: &str,
) -> Result<Vec<u8>> {
    let backoff = ExponentialBackoff::default();

    retry(backoff, || async {
        match client.get(&format!("https://dabmusic.xyz/api/stream/{}", track_id))
            .send()
            .await
        {
            Ok(resp) => match resp.status() {
                reqwest::StatusCode::OK => {
                    Ok(resp.bytes().await?.to_vec())
                }
                reqwest::StatusCode::NOT_FOUND => {
                    // Permanent error: don't retry this endpoint
                    Err(backoff::Error::permanent(
                        anyhow::anyhow!("Track not found")
                    ))
                }
                reqwest::StatusCode::INTERNAL_SERVER_ERROR => {
                    // Transient error: retry with backoff
                    Err(backoff::Error::transient(
                        anyhow::anyhow!("Server error, retrying...")
                    ))
                }
                s => Err(backoff::Error::transient(
                    anyhow::anyhow!("HTTP {}", s)
                )),
            },
            Err(e) => {
                // Network errors are transient
                Err(backoff::Error::transient(e.into()))
            }
        }
    })
    .await
}
```

### Audio Format Detection with Symphonia

```rust
// Source: https://github.com/pdeljanov/Symphonia
use symphonia::core::codecs::CodecType;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;

fn detect_audio_format(file_path: &std::path::Path) -> Result<AudioInfo> {
    let file = std::fs::File::open(file_path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = file_path.extension() {
        hint.with_extension(ext.to_str().unwrap_or(""));
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &Default::default(), &Default::default())?;

    let metadata = probed.metadata.get();
    let codec = probed.format.codec_params[0].codec;

    Ok(AudioInfo {
        codec_type: codec,
        sample_rate: probed.format.codec_params[0].sample_rate,
        bit_depth: probed.format.codec_params[0].bits_per_sample,
    })
}
```

### Persistent Retry Queue with Serialization

```rust
// Source: https://docs.rs/serde/latest/serde/
use serde::{Serialize, Deserialize};
use chrono::{DateTime, Utc};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct FailedDownload {
    pub track_id: String,
    pub source: String,
    pub attempt_count: u32,
    pub last_error: String,
    pub queued_at: DateTime<Utc>,
}

pub fn save_retry_queue(items: &[FailedDownload], path: &std::path::Path) -> Result<()> {
    let json = serde_json::to_string_pretty(items)?;
    // Write to temp, then atomic move
    let temp_path = path.with_extension("tmp");
    std::fs::write(&temp_path, json)?;
    std::fs::rename(&temp_path, path)?;
    Ok(())
}

pub fn load_retry_queue(path: &std::path::Path) -> Result<Vec<FailedDownload>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let json = std::fs::read_to_string(path)?;
    Ok(serde_json::from_str(&json)?)
}
```

### FFmpeg AAC Encoding with libfdk_aac

```bash
# Source: https://mirror.hjertaas.com/trac.ffmpeg.org/trac.ffmpeg.org/wiki/Encode/AAC.html
# 248kbps AAC with libfdk_aac (requires ffmpeg compiled with --enable-libfdk-aac)

ffmpeg -i input.flac -c:a libfdk_aac -b:a 248k output.m4a

# Alternative: If libfdk_aac not available (runtime check):
ffmpeg -i input.flac -c:a aac -b:a 248k output.m4a
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| youtube-dl | yt-dlp | 2020+ | yt-dlp is maintained fork with more features, faster updates, better error handling |
| Manual retry loops | backoff crate | 2015+ | Backoff algorithms are subtle; crate-based approach eliminates bugs |
| Blocking HTTP client | reqwest async | 2016+ | Async/await enables handling multiple concurrent tasks in single thread |
| Parsing file extensions | Symphonia codec detection | 2020+ | Extension-based detection is fragile; reading actual codec metadata is reliable |
| Per-track library updates | Batch imports | Phase 1+ | Batch reduces transaction overhead, simpler recovery on failure |

**Deprecated/outdated:**
- youtube-dl (Python, unmaintained): Replaced by yt-dlp fork with better maintenance
- Manual backoff implementation: Use backoff crate instead
- FLAC transcoding without codec detection: Always read metadata first to avoid re-transcoding already-transcoded files

## Open Questions

Things that couldn't be fully resolved:

1. **DAB API "Not Found" Response Structure**
   - What we know: API returns HTTP 404, but OpenAPI spec doesn't explicitly document whether 404 is "track not found" only or also used for other client errors
   - What's unclear: Should we check response body for error message to further distinguish "track not found" from "malformed request"?
   - Recommendation: Treat all 404s as "track not found" initially (trigger YouTube fallback). If fallback succeeds less often than expected, add integration test against live API to validate 404 semantics.

2. **Exact Retry Backoff Timing (Claude's Discretion)**
   - What we know: backoff 0.4 supports exponential backoff with configurable intervals
   - What's unclear: Should initial retry be 100ms, 500ms, or 1s? Max interval? Jitter formula?
   - Recommendation: Start with backoff defaults (initial 1s, max 60s), adjust after observing real failure rates on DAB API in testing

3. **Detecting Partial Downloads**
   - What we know: File system operations can be interrupted
   - What's unclear: Should we verify file integrity via Content-Length header match, or just assume files are valid if no errors thrown?
   - Recommendation: Compare downloaded bytes against Content-Length header if available; log warning if mismatch, but don't re-download (trust that transcode will fail if file corrupted)

4. **Quality Detection: "Lossy Below 248kbps"**
   - What we know: Symphonia can read bitrate; 248kbps is decision threshold
   - What's unclear: Should we also check codec type (MP3 always lossy, FLAC always lossless) or only bitrate?
   - Recommendation: Check codec first (if FLAC → transcode), then bitrate (if lossy <248k → skip transcode)

5. **libfdk_aac Availability at Runtime**
   - What we know: libfdk_aac requires special compilation; not in standard packages
   - What's unclear: Should we detect at startup and skip AAC transcode if unavailable, or fail hard with helpful error?
   - Recommendation: Run `ffmpeg -encoders | grep fdk_aac` at app startup, warn if unavailable, allow user to proceed with lower-quality AAC fallback

## Sources

### Primary (HIGH confidence)
- **reqwest 0.13.1** — HTTP client, streaming responses, status code handling — https://docs.rs/reqwest/
- **backoff 0.4.0** — Exponential backoff, transient/permanent error classification — https://docs.rs/backoff/
- **Symphonia 0.5.5** — Audio codec detection, format probing — https://github.com/pdeljanov/Symphonia
- **DAB Music API OpenAPI spec** — Endpoints, status codes — https://github.com/sixnine-dotdev/dab-api-docs
- **FFmpeg Encode/AAC documentation** — 248kbps CBR settings, libfdk_aac — https://mirror.hjertaas.com/trac.ffmpeg.org/trac.ffmpeg.org/wiki/Encode/AAC.html

### Secondary (MEDIUM confidence)
- **yt-dlp Rust crate** — YouTube audio extraction — https://docs.rs/yt-dlp/ and https://github.com/narrrl/ytd-rs
- **HTTP download patterns** — Streaming, progress tracking — https://rust-lang-nursery.github.io/rust-cookbook/web/clients/download.html
- **Audio format comparison** — FLAC vs AAC, transcoding pitfalls — https://www.whathifi.com/advice/mp3-aac-wav-flac-all-the-audio-file-formats-explained

### Tertiary (LOW confidence - WebSearch only, marked for validation)
- **libfdk_aac license and compilation** — Requires custom ffmpeg build — https://medium.com/enekochan/compile-ffmpeg-with-libfdk-aac-support-encoding-aac-with-ffmpeg-1b83c6c0d52
- **yt-dlp bestaudio quality** — Forum discussion about audio quality — https://ostechnix.com/yt-dlp-tutorial/
- **Persistent queue patterns in Rust** — yaque and custom implementations — https://github.com/tokahuke/yaque

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Reqwest, backoff, Symphonia are industry-standard, extensively documented
- Architecture patterns: HIGH — HTTP status matching is standard; Tauri IPC with channels is documented
- DAB API specifics: MEDIUM — OpenAPI spec exists but not exhaustively tested against all error scenarios
- Pitfalls: HIGH — Common issues in audio download pipelines are well-documented
- libfdk_aac: MEDIUM — Compilation requirement is clear, but runtime detection strategy needs validation

**Research date:** 2026-02-03
**Valid until:** 30 days (stable libraries, May expect libfdk_aac detection strategy to need refinement after testing)
