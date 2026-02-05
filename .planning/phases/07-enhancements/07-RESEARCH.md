# Phase 7: Enhancements - Research

**Researched:** 2026-02-05
**Domain:** Acoustic fingerprinting, album artwork, ReplayGain loudness normalization (Rust)
**Confidence:** HIGH (core libraries verified via official docs and crates.io)

## Summary

Phase 7 adds three quality-of-life enhancements to an existing Rust/Tauri music library manager: acoustic fingerprinting for improved duplicate detection (ENH-01), automatic album artwork fetching and embedding (ENH-02), and ReplayGain volume normalization (ENH-03). The existing codebase already has metadata-based dedup, lofty-based tag reading, symphonia-based audio decoding, and a sync pipeline to Rockbox devices.

The Rust ecosystem has mature, pure-Rust solutions for all three areas. `rusty-chromaprint` provides Chromaprint fingerprinting without C dependencies. The `ebur128` crate implements EBU R128 loudness measurement (the basis for ReplayGain 2.0). The existing `lofty` crate (already in the project at v0.22) supports reading and writing pictures and ReplayGain tags via `ItemKey` variants. The `musicbrainz_rs` crate provides MusicBrainz API access including Cover Art Archive queries. For AcoustID lookups, there is no dedicated Rust client, so `reqwest` (already in the project) will be used to call the REST API directly.

The key architectural pattern across all three features is background processing with progress reporting via Tauri events, matching the existing `sync:started`/`sync:progress`/`sync:completed` event pattern. All three features involve processing individual tracks in batches, making them natural extensions of the existing import and sync pipelines.

**Primary recommendation:** Use pure-Rust crates (`rusty-chromaprint`, `ebur128`, `lofty`, `musicbrainz_rs`) with symphonia for audio decoding. Write ReplayGain tags only to synced copies (not library originals). Store fingerprints in a new database table. Use MusicBrainz Cover Art Archive as the primary artwork source.

## Standard Stack

The established libraries/tools for this domain:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `rusty-chromaprint` | 0.3.0 | Audio fingerprint generation (pure Rust Chromaprint port) | No C dependencies, uses rustfft, compatible with AcoustID |
| `ebur128` | 0.1.10 | EBU R128 loudness measurement for ReplayGain | Pure Rust port of libebur128, passes all EBU TECH 3341/3342 tests |
| `lofty` | 0.22 (already in project) | Write ReplayGain tags, embed artwork into audio files | Already used for metadata reading; has `ItemKey::ReplayGainTrackGain` etc. and `Picture` support |
| `symphonia` | 0.5.5 (already in project) | Decode audio to raw PCM for fingerprinting and loudness analysis | Already used for audio format detection; supports all needed formats |
| `musicbrainz_rs` | 0.12.0 | MusicBrainz API client with Cover Art Archive support | Official Rust library listed on MusicBrainz docs, built-in rate limiting (1 req/sec) |
| `reqwest` | 0.12 (already in project) | AcoustID API HTTP calls, artwork image downloads | Already in project for download infrastructure |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `image` | latest | Resize artwork before embedding (e.g., 500x500 for embedded, 1200 for cache) | When artwork is larger than target resolution |
| `sha2` | 0.10 (already in project) | Hash fingerprints for database indexing | Already used for sync state checksums |
| `tokio` | 1 (already in project) | Async background processing for batch operations | Already the async runtime |
| `serde_json` | 1 (already in project) | Parse AcoustID JSON responses | Already in project |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `rusty-chromaprint` | `chromaprint` (C FFI bindings) | FFI bindings require Chromaprint C library installed; pure Rust is simpler for cross-platform |
| `ebur128` | `replaygain` crate (1.0.1) | `replaygain` wraps ffmpeg's af_replaygain; `ebur128` is pure Rust and more flexible |
| `musicbrainz_rs` | Direct `reqwest` calls to MusicBrainz API | `musicbrainz_rs` handles rate limiting, typed responses, and the builder pattern |
| MusicBrainz Cover Art | Spotify/Discogs APIs | MusicBrainz is free, no API key for cover art, community-curated; Spotify requires auth tokens already managed by the app but has usage restrictions |

**Installation (Cargo.toml additions):**
```toml
# Phase 7: Enhancements
rusty-chromaprint = "0.3"
ebur128 = "0.1"
musicbrainz_rs = "0.12"
image = "0.25"
```

## Architecture Patterns

### Recommended Module Structure
```
src-tauri/src/
├── fingerprint/            # NEW: Acoustic fingerprinting
│   ├── mod.rs              # Public API: fingerprint_track, compare_fingerprints
│   ├── chromaprint.rs      # Fingerprint generation using rusty-chromaprint + symphonia
│   ├── acoustid.rs         # AcoustID API client (lookup by fingerprint)
│   └── matcher.rs          # Local fingerprint comparison, duplicate grouping
├── artwork/                # NEW: Album artwork fetching and embedding
│   ├── mod.rs              # Public API: fetch_artwork, embed_artwork
│   ├── sources.rs          # Cover Art Archive + MusicBrainz lookups
│   ├── cache.rs            # Artwork file cache (avoid re-downloading)
│   └── embed.rs            # Embed artwork into audio files via lofty
├── replaygain/             # NEW: ReplayGain loudness analysis
│   ├── mod.rs              # Public API: analyze_track, analyze_album, write_gain_tags
│   ├── analyzer.rs         # EBU R128 loudness analysis using ebur128 + symphonia
│   └── tagger.rs           # Write ReplayGain tags to files via lofty
├── dedup/                  # EXISTING: Extended with fingerprint support
│   ├── matcher.rs          # EXISTING: Fuzzy string matching (unchanged)
│   ├── normalize.rs        # EXISTING: String normalization (unchanged)
│   └── fingerprint.rs      # NEW: Fingerprint-based duplicate detection
├── commands/
│   ├── enhancements.rs     # NEW: Tauri commands for fingerprint/artwork/replaygain
│   └── ...                 # EXISTING commands unchanged
├── database/
│   └── schema.rs           # EXTENDED: Phase 7 migration (fingerprints, artwork, review_queue tables)
└── models/
    └── track.rs            # EXTENDED: Add fingerprint, artwork_path fields
```

### Pattern 1: Background Processing with Progress Events
**What:** All three features involve processing tracks one at a time in a background thread, reporting progress via Tauri events.
**When to use:** Any batch operation (fingerprint library, fetch artwork, analyze ReplayGain).
**Example:**
```rust
// Pattern matching existing sync:started / sync:progress / sync:completed events
use tauri::Emitter;

pub async fn fingerprint_library(
    app: tauri::AppHandle,
    track_ids: Vec<i64>,
) -> Result<FingerprintResult, String> {
    let total = track_ids.len();
    let _ = app.emit("fingerprint:started", serde_json::json!({ "total": total }));

    for (i, track_id) in track_ids.iter().enumerate() {
        // Process track...
        let _ = app.emit("fingerprint:progress", serde_json::json!({
            "current": i + 1,
            "total": total,
            "track_id": track_id,
        }));
    }

    let _ = app.emit("fingerprint:completed", serde_json::json!({ "processed": total }));
    Ok(result)
}
```

### Pattern 2: Symphonia Decode-to-Samples Pipeline
**What:** Decode any audio format to raw PCM samples for fingerprinting or loudness analysis.
**When to use:** Both fingerprinting and ReplayGain analysis need raw audio data.
**Example:**
```rust
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use std::fs::File;

fn decode_to_samples(path: &std::path::Path) -> Result<(Vec<i16>, u32, u16), String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| e.to_string())?;

    let mut format = probed.format;
    let track = format.default_track().ok_or("No audio track")?;
    let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
    let channels = track.codec_params.channels.map(|c| c.count() as u16).unwrap_or(2);

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| e.to_string())?;

    let mut all_samples: Vec<i16> = Vec::new();

    loop {
        match format.next_packet() {
            Ok(packet) => {
                let decoded = decoder.decode(&packet).map_err(|e| e.to_string())?;
                let spec = *decoded.spec();
                let mut sample_buf = SampleBuffer::<i16>::new(decoded.capacity() as u64, spec);
                sample_buf.copy_interleaved_ref(decoded);
                all_samples.extend_from_slice(sample_buf.samples());
            }
            Err(_) => break, // End of stream
        }
    }

    Ok((all_samples, sample_rate, channels))
}
```

### Pattern 3: Database-Backed Review Queue
**What:** When fingerprint matching finds conflicts or dedup decisions are made automatically, log them to a review queue table.
**When to use:** Any automated decision the user wants to audit later.
**Example:**
```sql
-- Review queue table (Phase 7 migration)
CREATE TABLE IF NOT EXISTS review_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action_type TEXT NOT NULL,      -- 'fingerprint_dedup' | 'artwork_fetch' | 'metadata_conflict'
    track_id INTEGER NOT NULL,
    related_track_id INTEGER,       -- For dedup: the duplicate
    details TEXT NOT NULL,           -- JSON with specifics
    status TEXT DEFAULT 'pending',   -- 'pending' | 'approved' | 'rejected'
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    resolved_at TEXT,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_review_queue_status ON review_queue(status);
```

### Pattern 4: Write-on-Sync for ReplayGain
**What:** Library files stay pristine. ReplayGain tags are written only to transcoded/synced copies.
**When to use:** ReplayGain values are calculated and stored in the database, then written to file tags during the sync pipeline.
**Example:**
```rust
// During sync pipeline (extends existing sync::progress::execute_sync)
fn write_replaygain_to_synced_file(
    synced_file_path: &Path,
    track_gain: f64,
    track_peak: f64,
    album_gain: Option<f64>,
    album_peak: Option<f64>,
) -> Result<()> {
    use lofty::prelude::*;
    use lofty::probe::Probe;
    use lofty::tag::{TagItem, ItemKey, ItemValue};
    use lofty::config::WriteOptions;

    let mut tagged_file = Probe::open(synced_file_path)?.read()?;
    let tag = tagged_file.primary_tag_mut()
        .ok_or_else(|| anyhow::anyhow!("No tag in synced file"))?;

    // Write track gain: format is "-6.43 dB"
    tag.insert(TagItem::new(
        ItemKey::ReplayGainTrackGain,
        ItemValue::Text(format!("{:.2} dB", track_gain)),
    ));
    tag.insert(TagItem::new(
        ItemKey::ReplayGainTrackPeak,
        ItemValue::Text(format!("{:.6}", track_peak)),
    ));

    if let (Some(ag), Some(ap)) = (album_gain, album_peak) {
        tag.insert(TagItem::new(
            ItemKey::ReplayGainAlbumGain,
            ItemValue::Text(format!("{:.2} dB", ag)),
        ));
        tag.insert(TagItem::new(
            ItemKey::ReplayGainAlbumPeak,
            ItemValue::Text(format!("{:.6}", ap)),
        ));
    }

    tag.save_to_path(synced_file_path, WriteOptions::default())?;
    Ok(())
}
```

### Anti-Patterns to Avoid
- **Modifying library originals for ReplayGain:** User decision is to keep originals pristine. Only synced copies get RG tags.
- **Auto-merging fingerprint conflicts:** User decision is to flag for review, never auto-resolve metadata disagreements.
- **Blocking UI during batch fingerprinting:** Must use background processing with progress events.
- **Re-fingerprinting unchanged files:** Incremental processing -- only fingerprint new/changed tracks unless user triggers full scan.
- **Storing full fingerprint data in memory:** Fingerprints are arrays of u32 values; store in database, load on demand for comparison.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Audio fingerprint generation | Custom FFT-based fingerprinting | `rusty-chromaprint` | Chromaprint algorithm is complex and must be compatible with AcoustID database |
| Loudness measurement | Custom RMS/LUFS calculator | `ebur128` crate | EBU R128 spec has complex K-weighting, gating, and multi-channel handling |
| Audio decoding to PCM | Custom format decoders | `symphonia` (already in project) | Handles MP3, FLAC, AAC, OGG, WAV, AIFF transparently |
| MusicBrainz API access | Custom HTTP client with rate limiting | `musicbrainz_rs` | Handles rate limiting (1 req/sec), typed responses, entity resolution |
| Cover Art Archive access | Manual HTTP calls to coverartarchive.org | `musicbrainz_rs` `FetchCoverart` trait | Integrated with release/release-group lookups |
| ReplayGain tag format | Manual tag key/value management | `lofty` `ItemKey::ReplayGainTrackGain` etc. | Handles format-specific mapping (ID3v2 TXXX, Vorbis comments, MP4 atoms) |
| Fingerprint comparison | Hamming distance from scratch | `rusty-chromaprint::match_fingerprints` | Handles alignment, offset detection, segment matching |
| Image resizing | Manual pixel manipulation | `image` crate | Proper resampling filters, format conversion |

**Key insight:** Audio processing and metadata standards have subtle format-specific requirements. Each audio format stores ReplayGain tags differently (ID3v2 uses TXXX frames, Vorbis uses comments, MP4 uses freeform atoms). Lofty abstracts this through `ItemKey`, so a single code path works for all formats.

## Common Pitfalls

### Pitfall 1: Fingerprinting Requires Raw PCM, Not Compressed Audio
**What goes wrong:** Attempting to feed compressed audio bytes directly to Chromaprint produces garbage fingerprints.
**Why it happens:** Chromaprint operates on decoded PCM samples (interleaved i16), not on encoded bitstreams.
**How to avoid:** Always decode through symphonia first, then feed the PCM samples to `rusty-chromaprint::Fingerprinter`.
**Warning signs:** Fingerprints that never match anything, extremely short fingerprints.

### Pitfall 2: Interleaved vs Planar Sample Layout
**What goes wrong:** Feeding planar audio to a function expecting interleaved samples (or vice versa) produces incorrect fingerprints or loudness values.
**Why it happens:** `rusty-chromaprint` expects interleaved samples (L,R,L,R...). `ebur128` supports both via separate methods (`add_frames_i16` for interleaved, `add_frames_planar_i16` for planar). Symphonia's `SampleBuffer::copy_interleaved_ref` produces interleaved output.
**How to avoid:** Always use `SampleBuffer::copy_interleaved_ref` from symphonia, which produces interleaved output. Use `ebur128::EbuR128::add_frames_i16` (interleaved variant).
**Warning signs:** Loudness values that are wildly off, fingerprints that differ for identical files.

### Pitfall 3: ReplayGain Reference Level is -18 LUFS, Not -23 LUFS
**What goes wrong:** Using EBU R128's -23 LUFS reference level produces gain values that are 5 dB too high for ReplayGain 2.0.
**Why it happens:** EBU R128 targets -23 LUFS for broadcast. ReplayGain 2.0 targets -18 LUFS for compatibility with ReplayGain 1.0.
**How to avoid:** Calculate gain as: `gain_db = -18.0 - ebur128.loudness_global()`. Always use -18 LUFS as the reference.
**Warning signs:** All tracks sound too quiet after applying ReplayGain.

### Pitfall 4: Rockbox Requires Native Tag Format for ReplayGain
**What goes wrong:** ReplayGain tags are written but Rockbox ignores them.
**Why it happens:** Rockbox only reads ReplayGain from the codec's native tagging format. For AAC/M4A (the sync target format), this means MP4 freeform atoms, not ID3v2.
**How to avoid:** Lofty handles this automatically when you use `ItemKey::ReplayGainTrackGain` with the appropriate `TagType`. Ensure the tag being written matches the file format.
**Warning signs:** Rockbox shows "No ReplayGain info" for synced files.

### Pitfall 5: AcoustID Rate Limiting (3 requests/second)
**What goes wrong:** Batch lookups get rejected or IP gets temporarily banned.
**Why it happens:** AcoustID allows max 3 requests per second for free tier.
**How to avoid:** Add a 350ms delay between requests. Use `tokio::time::sleep`. Batch lookups where possible. Consider caching AcoustID results in the database.
**Warning signs:** HTTP 429 responses, empty results for known tracks.

### Pitfall 6: Cover Art Archive Returns 307 Redirects
**What goes wrong:** Artwork fetch returns redirect instead of image data.
**Why it happens:** Cover Art Archive uses 307 redirects to Internet Archive CDN. The front cover endpoint (`/release/{mbid}/front`) returns a redirect.
**How to avoid:** Ensure `reqwest` client follows redirects (it does by default). Handle 404 gracefully when no cover art exists.
**Warning signs:** Getting HTML/redirect responses instead of image bytes.

### Pitfall 7: Fingerprint Comparison Needs Alignment
**What goes wrong:** Two fingerprints from the same track don't match because they start at different offsets.
**Why it happens:** Different encodings may have different leading silence, intro detection, etc.
**How to avoid:** Use `rusty-chromaprint::match_fingerprints` which handles offset alignment automatically, rather than doing naive element-by-element comparison.
**Warning signs:** Low match scores for tracks that are obviously the same recording.

### Pitfall 8: Large Library Fingerprinting is CPU-Intensive
**What goes wrong:** UI freezes or system becomes unresponsive during batch fingerprinting.
**Why it happens:** Decoding + fingerprinting requires reading and processing entire audio files. A 1000-track library could take 30+ minutes.
**How to avoid:** Use `tokio::task::spawn_blocking` for CPU-intensive work. Process in batches with progress events. Allow cancellation. Consider limiting concurrent decode operations (e.g., 2-4 parallel, not all at once).
**Warning signs:** Application becomes unresponsive, memory usage spikes.

## Code Examples

Verified patterns from official sources:

### Generate Chromaprint Fingerprint
```rust
// Sources: rusty-chromaprint docs, symphonia docs
use rusty_chromaprint::{Configuration, Fingerprinter};

fn generate_fingerprint(samples: &[i16], sample_rate: u32, channels: u16) -> Option<Vec<u32>> {
    let mut printer = Fingerprinter::new(&Configuration::preset_test2());
    printer.start(sample_rate, channels as u32).ok()?;
    printer.consume(samples);
    printer.finish();
    printer.fingerprint()
}
```

### Compare Two Fingerprints Locally
```rust
// Source: rusty-chromaprint match_fingerprints function
use rusty_chromaprint::{match_fingerprints, Configuration};

fn are_duplicates(fp1: &[u32], fp2: &[u32]) -> bool {
    let segments = match_fingerprints(fp1, fp2, &Configuration::preset_test2());
    // If there are matching segments covering most of the track, it's a duplicate
    if let Some(segments) = segments {
        // Check if any segment is long enough to indicate a match
        segments.iter().any(|seg| seg.score > 0.5) // Threshold TBD during implementation
    } else {
        false
    }
}
```

### AcoustID Lookup via REST API
```rust
// Source: AcoustID web service docs (acoustid.org/webservice)
use reqwest::Client;
use serde::Deserialize;

#[derive(Deserialize)]
struct AcoustIdResponse {
    status: String,
    results: Vec<AcoustIdResult>,
}

#[derive(Deserialize)]
struct AcoustIdResult {
    id: String,
    score: f64,
    recordings: Option<Vec<AcoustIdRecording>>,
}

#[derive(Deserialize)]
struct AcoustIdRecording {
    id: String,  // MusicBrainz recording ID
    title: Option<String>,
    artists: Option<Vec<AcoustIdArtist>>,
}

#[derive(Deserialize)]
struct AcoustIdArtist {
    id: String,
    name: String,
}

async fn lookup_acoustid(
    client: &Client,
    api_key: &str,
    fingerprint: &str,  // Base64-encoded compressed fingerprint
    duration: u32,
) -> Result<AcoustIdResponse, reqwest::Error> {
    let response = client
        .post("https://api.acoustid.org/v2/lookup")
        .form(&[
            ("client", api_key),
            ("duration", &duration.to_string()),
            ("fingerprint", fingerprint),
            ("meta", "recordings+releasegroups+compress"),
        ])
        .send()
        .await?
        .json::<AcoustIdResponse>()
        .await?;
    Ok(response)
}
```

### EBU R128 Loudness Analysis for ReplayGain
```rust
// Source: ebur128 docs (docs.rs/ebur128)
use ebur128::{EbuR128, Mode};

fn analyze_loudness(
    samples: &[i16],
    sample_rate: u32,
    channels: u16,
) -> Result<(f64, f64), String> {
    let mode = Mode::I | Mode::TRUE_PEAK;  // Integrated loudness + true peak
    let mut r128 = EbuR128::new(channels as u32, sample_rate, mode)
        .map_err(|e| format!("Failed to create analyzer: {:?}", e))?;

    r128.add_frames_i16(samples)
        .map_err(|e| format!("Failed to add frames: {:?}", e))?;

    let loudness = r128.loudness_global()
        .map_err(|e| format!("Failed to get loudness: {:?}", e))?;

    // Get max true peak across all channels
    let mut max_peak = 0.0f64;
    for ch in 0..channels {
        let peak = r128.true_peak(ch as u32)
            .map_err(|e| format!("Failed to get peak: {:?}", e))?;
        if peak > max_peak {
            max_peak = peak;
        }
    }

    // ReplayGain 2.0: reference level is -18 LUFS
    let gain = -18.0 - loudness;

    Ok((gain, max_peak))
}
```

### Embed Album Artwork with Lofty
```rust
// Source: lofty docs (docs.rs/lofty), Picture struct docs
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::picture::{Picture, PictureType};
use lofty::config::WriteOptions;
use std::io::Cursor;

fn embed_artwork(audio_path: &std::path::Path, image_data: &[u8]) -> Result<(), String> {
    let mut tagged_file = Probe::open(audio_path)
        .map_err(|e| format!("Cannot open: {}", e))?
        .read()
        .map_err(|e| format!("Cannot read: {}", e))?;

    let tag = tagged_file.primary_tag_mut()
        .ok_or("No primary tag")?;

    // Create Picture from image bytes
    let mut picture = Picture::from_reader(&mut Cursor::new(image_data))
        .map_err(|e| format!("Invalid image: {}", e))?;
    picture.set_pic_type(PictureType::CoverFront);

    // Remove existing front cover, add new one
    tag.remove_picture_type(PictureType::CoverFront);
    tag.push_picture(picture);

    // Save
    tag.save_to_path(audio_path, WriteOptions::default())
        .map_err(|e| format!("Failed to save: {}", e))?;

    Ok(())
}
```

### Fetch Cover Art from MusicBrainz
```rust
// Source: musicbrainz_rs docs (docs.rs/musicbrainz_rs), Cover Art Archive API
use musicbrainz_rs::prelude::*;
use musicbrainz_rs::entity::release_group::ReleaseGroup;

async fn fetch_cover_art(mbid: &str) -> Result<Vec<u8>, String> {
    // Direct Cover Art Archive API call (simpler than going through musicbrainz_rs)
    let url = format!(
        "https://coverartarchive.org/release-group/{}/front-500",
        mbid
    );

    let client = reqwest::Client::new();
    let response = client.get(&url)
        .send()
        .await
        .map_err(|e| format!("Request failed: {}", e))?;

    if response.status() == 404 {
        return Err("No cover art available".to_string());
    }

    response.bytes()
        .await
        .map(|b| b.to_vec())
        .map_err(|e| format!("Failed to download: {}", e))
}
```

## Database Schema Extensions

### Phase 7 Migration (Version 5)
```sql
-- Fingerprints table: Store Chromaprint fingerprints per track
CREATE TABLE IF NOT EXISTS fingerprints (
    track_id INTEGER PRIMARY KEY,
    fingerprint BLOB NOT NULL,          -- Raw u32 array as bytes
    duration_seconds INTEGER NOT NULL,  -- Track duration (needed for AcoustID lookup)
    acoustid TEXT,                       -- AcoustID identifier (if looked up)
    musicbrainz_recording_id TEXT,       -- MusicBrainz recording ID (if resolved)
    fingerprinted_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- Artwork cache table: Track artwork state per track
CREATE TABLE IF NOT EXISTS artwork (
    track_id INTEGER PRIMARY KEY,
    artwork_path TEXT,                   -- Path to cached artwork file
    source TEXT,                         -- 'musicbrainz' | 'embedded' | 'manual'
    musicbrainz_release_group_id TEXT,  -- MBID used to fetch
    resolution TEXT,                     -- e.g., '500x500'
    fetched_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- ReplayGain analysis results: Store per track (written to files only during sync)
CREATE TABLE IF NOT EXISTS replaygain (
    track_id INTEGER PRIMARY KEY,
    track_gain REAL NOT NULL,           -- dB value (e.g., -6.43)
    track_peak REAL NOT NULL,           -- Linear peak (e.g., 0.978465)
    album_gain REAL,                    -- dB value for album (nullable until album analyzed)
    album_peak REAL,                    -- Linear peak for album
    analyzed_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

-- Review queue: Audit log for automated decisions
CREATE TABLE IF NOT EXISTS review_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action_type TEXT NOT NULL,           -- 'fingerprint_dedup' | 'metadata_conflict' | 'artwork_mismatch'
    track_id INTEGER NOT NULL,
    related_track_id INTEGER,            -- For dedup: the other track
    details TEXT NOT NULL,               -- JSON with decision details
    auto_action TEXT,                    -- What was auto-done: 'kept_higher_quality' | 'flagged' | etc.
    status TEXT DEFAULT 'pending',       -- 'pending' | 'approved' | 'rejected' | 'dismissed'
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    resolved_at TEXT,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_review_status ON review_queue(status);
CREATE INDEX IF NOT EXISTS idx_review_type ON review_queue(action_type);
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| ReplayGain 1.0 (Fletcher-Munson RMS) | ReplayGain 2.0 (EBU R128, -18 LUFS) | ~2015 | More accurate loudness measurement, industry standard |
| C Chromaprint via FFI | Pure Rust `rusty-chromaprint` 0.3 | 2024 | No C dependencies, cross-platform, uses rustfft |
| libebur128 C bindings | Pure Rust `ebur128` 0.1.2+ | 2020 | Sebastian Dröge's port, passes all EBU test suites |
| Manual MusicBrainz HTTP calls | `musicbrainz_rs` 0.12 with rate limiting | 2024 | Built-in 1req/sec, typed entities, cover art support |

**Deprecated/outdated:**
- ReplayGain 1.0 (still widely used but RG 2.0 is the standard for new implementations)
- `chromaprint_sys` (old C FFI bindings, last updated 6+ years ago) -- use `rusty-chromaprint` instead

## Discretion Decisions (Research Recommendations)

### Artwork Sourcing Strategy
**Recommendation: MusicBrainz Cover Art Archive as primary, embedded artwork as fallback.**

Rationale:
- Cover Art Archive is free, no API key needed, community-curated
- The `musicbrainz_rs` crate already supports it via `FetchCoverart`
- Workflow: Check if file already has embedded artwork -> if not, look up MusicBrainz release group by artist+album -> fetch front cover from Cover Art Archive
- Spotify API has usage restrictions and requires auth; Discogs also requires API key
- If MusicBrainz lookup fails, log it and move on (artwork is nice-to-have)

### Artwork Resolution and Embedding Format
**Recommendation: Fetch 500px thumbnails for embedding, cache 1200px for UI display.**

Rationale:
- Cover Art Archive provides 250px, 500px, and 1200px thumbnails
- 500px is the sweet spot for embedded artwork (good quality, ~50-100KB JPEG)
- Embedded cover art significantly increases file size; keep it reasonable for iPod
- Store 1200px version in a cache directory for the desktop UI to display
- Embed as JPEG (smallest size, universally supported by players including Rockbox)
- Use `PictureType::CoverFront` for the embedded image

### AcoustID API Key Management
**Recommendation: Store API key in `.env` file, loaded via `dotenvy` (already in project).**

Rationale:
- AcoustID requires registering an application at acoustid.org/new-application
- Free for non-commercial use
- API key is a simple string, not a secret token (it identifies the application, not the user)
- Store as `ACOUSTID_API_KEY=xxxxx` in `.env`
- Load via `dotenvy::dotenv()` which already runs in `lib.rs`
- Provide clear error message if key is missing ("Register at acoustid.org to enable online fingerprint lookup")
- Fingerprint generation (local) works without the API key; only AcoustID lookup requires it

### Chromaprint Integration Approach
**Recommendation: Use `rusty-chromaprint` (pure Rust, no C dependency).**

Rationale:
- Pure Rust means no system library requirements, simpler cross-platform build
- Generates fingerprints compatible with AcoustID (uses the same Chromaprint algorithm)
- Has `match_fingerprints` function for local comparison without AcoustID API
- Uses `Configuration::preset_test2()` which is the standard AcoustID-compatible configuration
- Integrates naturally with symphonia (both pure Rust)
- Dependencies: `rustfft` and `rubato` (resampling) -- both pure Rust

### ReplayGain Analysis Tool Selection
**Recommendation: Use `ebur128` crate (pure Rust) with symphonia for decoding.**

Rationale:
- `ebur128` is a pure Rust port of the industry-standard libebur128
- Passes all EBU TECH 3341 and 3342 tests (verified in crate documentation)
- Formula: `gain_db = -18.0 - loudness_global()` (ReplayGain 2.0 reference)
- Peak: use `true_peak()` for accurate intersample peak detection
- Alternative (`replaygain` crate 1.0.1) wraps ffmpeg, adds external dependency
- `ebur128` supports all sample rates (8000-192000 Hz) and channel counts

### Review Queue UI Design
**Recommendation: Add a "Review Queue" section to the existing Library Browser page, accessible via a badge/count indicator.**

Rationale:
- No new pages needed (per phase boundary: "no new UI pages")
- Show a notification badge on the sidebar when pending items exist
- Review queue is a filterable table: type, track, action taken, status
- Bulk actions: "Approve All", "Dismiss All" for non-critical items
- Fingerprint conflicts show side-by-side comparison of the two tracks
- Integrates with existing `LibraryTable` component pattern

## Open Questions

Things that could not be fully resolved:

1. **rusty-chromaprint Configuration Presets**
   - What we know: `preset_test1()` and `preset_test2()` exist. `preset_test2()` is used in the README example.
   - What's unclear: Which preset matches the standard AcoustID/fpcalc configuration? The docs say only 50% is documented.
   - Recommendation: Use `preset_test2()` as default (matches README). Test that generated fingerprints produce valid AcoustID lookups. If not, may need to check `Configuration` fields against fpcalc defaults.

2. **Album Gain Calculation Grouping**
   - What we know: Album gain requires analyzing all tracks in an album together. EBU R128 provides `loudness_global_multiple()` for this.
   - What's unclear: How to reliably group tracks into albums (metadata may be inconsistent across sources).
   - Recommendation: Group by normalized (album_artist, album) tuple from database. If grouping is uncertain, skip album gain and only provide track gain.

3. **Fingerprint Storage Format**
   - What we know: Chromaprint fingerprints are `Vec<u32>` (array of 32-bit integers).
   - What's unclear: Whether to store raw bytes or compressed/base64 in SQLite.
   - Recommendation: Store as BLOB (raw bytes of the u32 array). For AcoustID submission, compress and encode at call time. This is most efficient for local comparison.

4. **musicbrainz_rs Version Currency**
   - What we know: v0.12.0 is on crates.io, it is the officially listed Rust library on MusicBrainz docs.
   - What's unclear: Whether it has been actively maintained in 2025-2026 or is in maintenance mode.
   - Recommendation: Use it for initial implementation. If issues arise, fall back to direct `reqwest` calls to MusicBrainz API (the API itself is stable and well-documented).

## Sources

### Primary (HIGH confidence)
- [rusty-chromaprint on crates.io](https://crates.io/crates/rusty-chromaprint) - v0.3.0, pure Rust Chromaprint port
- [ebur128 on docs.rs](https://docs.rs/ebur128/latest/ebur128/) - v0.1.10, EbuR128 API verified
- [lofty on docs.rs](https://docs.rs/lofty/latest/lofty/) - v0.22.4, Picture struct, ItemKey ReplayGain variants verified
- [lofty ItemKey enum](https://docs.rs/lofty/latest/lofty/tag/enum.ItemKey.html) - All 104 variants documented including ReplayGainTrackGain/Peak/AlbumGain/AlbumPeak
- [AcoustID Web Service API](https://acoustid.org/webservice) - Lookup endpoint, rate limits, meta parameters verified
- [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API) - Endpoints, thumbnail sizes, JSON format verified
- [ReplayGain 2.0 Specification](https://wiki.hydrogenaudio.org/index.php?title=ReplayGain_2.0_specification) - Reference level -18 LUFS, tag format verified

### Secondary (MEDIUM confidence)
- [musicbrainz_rs on docs.rs](https://docs.rs/musicbrainz_rs/latest/musicbrainz_rs/) - v0.12.0, FetchCoverart trait confirmed
- [rusty-chromaprint GitHub](https://github.com/darksv/rusty-chromaprint) - compare example, Fingerprinter API, match_fingerprints function
- [Rockbox ReplayGain Support](https://download.rockbox.org/daily/manual/rockbox-sansafuzeplus/rockbox-buildch7.html) - Confirmed RG tag reading from native formats
- [loudgain project](https://github.com/Moonbase59/loudgain) - Confirmed ReplayGain 2.0 uses -18 LUFS reference

### Tertiary (LOW confidence)
- Chromaprint fingerprint comparison threshold values (no authoritative source for exact thresholds; will need empirical testing)
- `rusty-chromaprint` `Configuration::preset_test2()` compatibility with AcoustID (README implies compatibility but not explicitly confirmed)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All crates verified on crates.io/docs.rs with version numbers and API details
- Architecture: HIGH - Patterns match existing codebase conventions (Tauri events, spawn_blocking, database migrations)
- Pitfalls: HIGH - Verified through official documentation (ReplayGain spec, AcoustID rate limits, Rockbox docs)
- Code examples: MEDIUM - Based on official docs but some examples are composed from API documentation rather than verified working code
- Fingerprint comparison thresholds: LOW - No authoritative source; will need empirical tuning

**Research date:** 2026-02-05
**Valid until:** 2026-03-07 (30 days - libraries are stable, not fast-moving)
