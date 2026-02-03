# Architecture Patterns for Music Library Management

**Domain:** Multi-Source Music Library Aggregation and Sync
**Researched:** 2026-02-03
**Confidence:** HIGH

## Executive Summary

Music library management systems follow a **pipeline architecture** with clear separation between metadata management (database), audio storage (filesystem), and transformation operations (download → process → transcode → sync). The existing reference implementation demonstrates a mature worker-queue pattern with parallel processing throughout.

**Key Architectural Decision:** Separate metadata (SQLite/JSON) from audio files (filesystem), connected by file path references. This enables independent scaling of metadata operations vs. file operations.

## Recommended Architecture

### High-Level Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                         Desktop UI Layer                         │
│              (Electron/Tauri + Web Frontend)                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │ IPC/Commands
┌───────────────────────────▼─────────────────────────────────────┐
│                     Backend Core (Rust/Python)                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Orchestrator / Job Scheduler                 │   │
│  └──────┬────────────────────────┬──────────────────────────┘   │
│         │                        │                               │
│  ┌──────▼───────┐      ┌────────▼────────┐                      │
│  │  Aggregation │      │  Pipeline Engine │                      │
│  │   Manager    │      │  (Download→Sync) │                      │
│  └──────────────┘      └─────────────────┘                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────▼────────┐  ┌───────▼────────┐  ┌──────▼──────┐
│ Metadata Store │  │  File System   │  │ Worker Pool │
│ (SQLite/JSON)  │  │  (Organized)   │  │ (Threads)   │
└────────────────┘  └────────────────┘  └─────────────┘
```

### Component Boundaries

| Component | Responsibility | Communicates With | Technology |
|-----------|---------------|-------------------|------------|
| **Desktop UI** | User interaction, display progress, settings | Backend Core via IPC | Electron/Tauri + React/Vue |
| **Orchestrator** | Job scheduling, phase coordination, state persistence | All subsystems | Python/Rust |
| **Aggregation Manager** | Query streaming APIs, normalize metadata, detect duplicates | Metadata Store, External APIs | Python + API clients |
| **Pipeline Engine** | Execute download→clean→transcode→sync pipeline | All pipeline modules, Worker Pool | Python orchestration |
| **Download Manager** | Multi-source downloads (dabmusic.xyz, scdl, yt-dlp) | Worker Pool, File System | Python + subprocess |
| **Metadata Processor** | Clean/normalize ID3 tags, embed artwork | File System, Metadata Store | Python + mutagen |
| **Transcoding Engine** | FLAC→AAC conversion, loudness normalization | Worker Pool, File System | Python + ffmpeg subprocess |
| **Sync Manager** | Compare source/dest, copy/verify files | File System, State DB | Python + file operations |
| **Metadata Store** | Track/album/artist/playlist data, download state | All data consumers | SQLite (primary) + JSON (snapshots) |
| **Worker Pool** | Parallel execution of CPU/IO intensive tasks | Orchestrator, Pipeline modules | ThreadPoolExecutor/multiprocessing |
| **State Manager** | Resume capability, progress tracking | Orchestrator, UI | SQLite + JSON checkpoints |

### Data Flow

```
1. User Likes Song in Streaming App
   ↓
2. Aggregation Manager polls APIs (Spotify/Apple/SoundCloud)
   ↓
3. New tracks added to Metadata Store (status: pending)
   ↓
4. Orchestrator queues download jobs
   ↓
5. Worker Pool executes downloads in parallel
   │  ├─> dabmusic.xyz API (primary)
   │  ├─> scdl subprocess (SoundCloud)
   │  └─> yt-dlp fallback (YouTube)
   ↓
6. Files saved to: Artists/{artist}/{album}/{track}.{ext}
   ↓
7. Metadata Processor cleans tags, embeds artwork
   ↓
8. Transcoding Engine converts FLAC→AAC (if needed)
   ↓
9. Sync Manager compares with device state
   ↓
10. Changed files copied to device (parallel workers)
    ↓
11. M3U8 playlists generated for device
    ↓
12. UI shows completion, device ready
```

### Data Models

#### Core Entities (Normalized Schema)

**Best Practice:** Follow MusicBrainz model with normalized entities for Artist, Album, Recording, and Release. Reference: [MusicBrainz Schema](https://musicbrainz.org/doc/MusicBrainz_Database/Schema)

```sql
-- Core music entities
CREATE TABLE artists (
    artist_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,  -- for fuzzy matching
    sort_name TEXT,
    musicbrainz_id TEXT UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_artists_normalized ON artists(normalized_name);

CREATE TABLE albums (
    album_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    artist_id INTEGER REFERENCES artists(artist_id),
    release_date TEXT,
    album_art_path TEXT,  -- path to cover image
    musicbrainz_id TEXT UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE tracks (
    track_id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    artist_id INTEGER REFERENCES artists(artist_id),
    album_id INTEGER REFERENCES albums(album_id),
    track_number INTEGER,
    duration_ms INTEGER,
    file_path TEXT UNIQUE NOT NULL,  -- absolute path to audio file
    file_hash TEXT,  -- MD5 or SHA256 for deduplication
    file_size INTEGER,
    format TEXT,  -- flac, m4a, mp3
    bitrate INTEGER,
    sample_rate INTEGER,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    modified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_tracks_file_path ON tracks(file_path);
CREATE INDEX idx_tracks_hash ON tracks(file_hash);

-- Source tracking (which streaming service this came from)
CREATE TABLE track_sources (
    source_id INTEGER PRIMARY KEY,
    track_id INTEGER REFERENCES tracks(track_id),
    source_type TEXT NOT NULL,  -- 'spotify', 'apple_music', 'soundcloud', 'local'
    source_url TEXT NOT NULL,
    source_track_id TEXT,  -- external ID from streaming service
    liked_at TIMESTAMP,
    sync_status TEXT DEFAULT 'pending',  -- pending, downloading, completed, failed
    last_sync TIMESTAMP,
    UNIQUE(source_type, source_url)
);
CREATE INDEX idx_sources_track ON track_sources(track_id);
CREATE INDEX idx_sources_status ON track_sources(sync_status);

-- Playlists (denormalized for flexibility)
CREATE TABLE playlists (
    playlist_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    source_type TEXT,  -- 'spotify', 'apple_music', 'local'
    source_playlist_id TEXT,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE playlist_tracks (
    playlist_id INTEGER REFERENCES playlists(playlist_id),
    track_id INTEGER REFERENCES tracks(track_id),
    position INTEGER NOT NULL,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (playlist_id, track_id)
);
```

#### State Management Schema

```sql
-- Download queue and state
CREATE TABLE download_queue (
    job_id INTEGER PRIMARY KEY,
    track_id INTEGER REFERENCES tracks(track_id),
    source_url TEXT NOT NULL,
    priority INTEGER DEFAULT 0,
    status TEXT DEFAULT 'queued',  -- queued, downloading, completed, failed, rate_limited
    attempts INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 5,
    error_message TEXT,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_queue_status ON download_queue(status);

-- Sync state (what's on each device)
CREATE TABLE devices (
    device_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    mount_path TEXT,
    capacity_bytes INTEGER,
    last_seen TIMESTAMP
);

CREATE TABLE device_tracks (
    device_id INTEGER REFERENCES devices(device_id),
    track_id INTEGER REFERENCES tracks(track_id),
    file_path TEXT NOT NULL,  -- path on device
    file_hash TEXT,
    synced_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (device_id, track_id)
);
```

**Design Rationale:**
- **Normalized core entities:** Eliminates redundancy, enables efficient queries
- **Separate source tracking:** Supports multiple streaming services referencing same track
- **File path references:** Metadata DB doesn't store audio, just references filesystem
- **Denormalized playlists:** Flexibility for streaming service-specific metadata
- **State tables:** Enable resumable operations and device sync tracking

### Storage Architecture

**Two-Tier Storage Model:**

#### 1. Metadata Storage (Database)
- **Primary:** SQLite database (`library.db`)
  - All track/album/artist relationships
  - Download state and queue
  - Device sync state
  - Fast queries, ACID guarantees
- **Secondary:** JSON snapshots (`metadata/*.json`)
  - Playlist metadata from streaming services
  - Portable backups
  - Human-readable debugging

**Why SQLite?** Superior to pure JSON for:
- Concurrent read/write access
- Complex queries (joins, aggregations)
- Indexing for performance
- ACID transactions for state consistency

Reference: [Spotify Database Design](https://medium.com/towards-data-engineering/design-the-database-for-a-system-like-spotify-95ffd1fb5927) uses leader-follower for scale; single-instance SQLite sufficient for personal library.

#### 2. Audio File Storage (Filesystem)

**Archive Structure** (FLAC originals):
```
/Music/
  Artists/
    {Artist}/
      {Album}/
        01 - {Title}.flac
        02 - {Title}.flac
        cover.jpg
```

**Device Sync Structure** (transcoded AAC):
```
/iPod/Music/
  Artists/
    {Artist}/
      {Album}/
        01 - {Title}.m4a
  Fast/
    SoundCloud/
      {Title}.m4a
  Playlists/
    {Playlist}.m3u8
```

**Design Principles:**
- Archive preserves highest quality (FLAC)
- Device storage uses space-efficient transcodes (AAC 248kbps)
- Folder structure = Artist/Album for browsing
- Fast folder = flat structure for quick access
- Playlists = M3U8 files with relative paths

## Pipeline Architecture Patterns

Music library operations follow a **directed acyclic graph (DAG)** of transformations. Reference: [FFmpeg Pipeline Architecture](https://ffmpeg.org/ffmpeg.html).

### Pattern 1: Download Pipeline (DAG with Fallbacks)

```
Liked Track Event
      ↓
┌─────▼─────┐
│ API Query │ (get metadata: title, artist, duration)
└─────┬─────┘
      ↓
┌─────▼──────────┐
│ Download Stage │
└────┬───┬───┬───┘
     │   │   └────> (Fallback Chain)
     │   │
     │   ├─> Try: dabmusic.xyz API (primary, fast, FLAC quality)
     │   │         ↓ (HTTP 429 or not found)
     │   │
     │   ├─> Try: scdl (SoundCloud native)
     │   │         ↓ (rate limit or not available)
     │   │
     │   └─> Try: yt-dlp (YouTube fallback)
     │             ↓ (last resort, variable quality)
     │
     ▼
┌────────────┐
│ Save File  │ → Artists/{artist}/{album}/{track}.{ext}
└─────┬──────┘
      ▼
┌────────────────┐
│ Update DB      │ → track_sources.sync_status = 'completed'
└────────────────┘
```

**Key Pattern:** Fallback chain with rate limit handling. Each source has independent retry logic.

### Pattern 2: Transcoding Pipeline (Parallel Worker Pool)

Reference: [FFmpeg Transcoding Architecture](https://ffmpeg.org/ffmpeg.html) - modern parallel pipeline.

```
Source Files (FLAC)
      ↓
┌─────▼──────┐
│ Queue Jobs │ → ThreadPoolExecutor
└──────┬─────┘
       │
       ├──> Worker 1: ffmpeg -i input.flac -c:a aac -b:a 248k output.m4a
       │               ├─> Read FLAC
       │               ├─> Decode PCM
       │               ├─> Encode AAC
       │               └─> Write M4A
       │
       ├──> Worker 2: ffmpeg [parallel transcoding]
       ├──> Worker 3: ffmpeg [parallel transcoding]
       ...
       └──> Worker N
              ↓
      ┌──────▼──────┐
      │ Post-Process │
      │ - Embed art │
      │ - Copy tags │
      │ - Verify    │
      └─────────────┘
```

**Key Pattern:** CPU-bound parallelism. Workers = CPU cores. Each worker runs independent ffmpeg subprocess.

### Pattern 3: Sync Pipeline (Hash-Based Differential)

```
Source Directory           Device Directory
      ↓                           ↓
┌─────▼──────┐            ┌───────▼────────┐
│ Scan Files │            │  Scan Files    │
│ (parallel) │            │  (parallel)    │
└─────┬──────┘            └───────┬────────┘
      │                           │
      └──────────┬────────────────┘
                 ▼
         ┌───────────────┐
         │ Diff Algorithm │
         │ - Compare hash │
         │ - Compare size │
         │ - Compare mtime│
         └────────┬───────┘
                  │
      ┌───────────┼───────────┐
      ▼           ▼           ▼
   [New]     [Modified]   [Deleted]
      │           │           │
      └───────────┴───────────┘
                  ▼
          ┌───────────────┐
          │  Sync Jobs    │
          │  (parallel)   │
          └───────────────┘
```

**Key Pattern:** Fast mode uses size+mtime (no hash). Verification mode uses MD5 hash. Parallel workers for copy operations.

## Long-Running Task Patterns

Reference: [Long-Running Tasks Architecture](https://www.ichaoran.com/posts/2024-11-26-long-running-task-app/)

### Pattern: Job Queue with Progress Tracking

**Architecture Components:**
1. **Job Queue** (SQLite `download_queue` table)
2. **Worker Pool** (Python `ThreadPoolExecutor`)
3. **Progress Tracker** (Thread-safe counters)
4. **State Persistence** (Atomic DB updates)

**Implementation Pattern:**

```python
class DownloadOrchestrator:
    def __init__(self):
        self.queue = Queue()  # In-memory job queue
        self.db = StateManager()  # SQLite persistence
        self.workers = ThreadPoolExecutor(max_workers=8)
        self.progress = ThreadSafeProgress()  # Atomic counters

    def queue_downloads(self, tracks):
        """Add tracks to queue"""
        for track in tracks:
            self.db.insert_job(track, status='queued')
            self.queue.put(track)

    def process_queue(self):
        """Process queue with parallel workers"""
        futures = []
        while not self.queue.empty():
            job = self.queue.get()
            future = self.workers.submit(self._download_track, job)
            futures.append(future)

        for future in as_completed(futures):
            self.progress.update(completed=1)
            self._save_checkpoint()  # Atomic state update

    def _download_track(self, track):
        """Worker function - runs in thread"""
        self.db.update_job_status(track.id, 'downloading')
        result = download_manager.download(track.url)
        if result.success:
            self.db.update_job_status(track.id, 'completed')
        else:
            self.db.update_job_status(track.id, 'failed')
        return result
```

**Key Mechanisms:**
- **Atomic progress updates:** Thread locks prevent race conditions
- **State persistence:** SQLite updates after each job completion
- **Resume capability:** Query `download_queue` for incomplete jobs
- **Progress UI:** Poll `ThreadSafeProgress.get_stats()` for live updates

Reference: [Web-Queue-Worker Architecture](https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/web-queue-worker)

## UI/Backend Separation Patterns

Reference: [Tauri vs Electron Architecture](https://raftlabs.medium.com/tauri-vs-electron-a-practical-guide-to-picking-the-right-framework-5df80e360f26)

### Recommended: Tauri Architecture

**Separation Model:**
```
Frontend (Web Technologies)          Backend (Rust/Python)
┌────────────────────────┐          ┌──────────────────────┐
│  React/Vue UI          │          │  Core Business Logic │
│  - Display progress    │  IPC     │  - Download manager  │
│  - User settings       │ <─────>  │  - Transcoding       │
│  - Library browser     │  invoke()│  - File operations   │
│  - Playlist editor     │          │  - Database access   │
└────────────────────────┘          └──────────────────────┘
     WebView (sandboxed)              OS-Level Process
```

**Communication Pattern:**

Frontend invokes backend commands:
```javascript
// Frontend (JavaScript)
import { invoke } from '@tauri-apps/api';

async function startDownload(playlistId) {
  const result = await invoke('start_download', {
    playlistId: playlistId
  });
  return result;
}
```

Backend exposes typed commands:
```rust
// Backend (Rust)
#[tauri::command]
async fn start_download(playlist_id: String) -> Result<DownloadStatus, String> {
    // Call Python orchestrator via subprocess or FFI
    let status = orchestrator.queue_downloads(playlist_id)?;
    Ok(status)
}
```

**Event Streaming for Progress:**
```rust
// Backend emits progress events
#[tauri::command]
async fn download_with_progress(window: Window) -> Result<(), String> {
    for progress in download_manager.track_progress() {
        window.emit("download-progress", progress)?;
    }
    Ok(())
}
```

```javascript
// Frontend listens for events
import { listen } from '@tauri-apps/api/event';

await listen('download-progress', (event) => {
  updateProgressBar(event.payload);
});
```

**Why Tauri over Electron:**
- **Cleaner IPC:** `invoke()` abstraction vs manual IPC channels
- **Smaller binary:** WebView (system) vs bundled Chromium
- **Better security:** Rust backend vs Node.js attack surface
- **Existing Python code:** Tauri backend calls Python orchestrator as subprocess

**Alternative: Electron (if staying pure JavaScript)**
- Main process (Node.js) handles backend logic
- Renderer process (Chromium) handles UI
- IPC via `ipcRenderer.send()` and `ipcMain.on()`

## State Management for Long-Running Operations

### Challenge: Resumability

**Problem:** Download queue with 1000 tracks, process crashes at track 347. Must resume without re-downloading.

**Solution: Checkpoint Pattern**

```python
class StateManager:
    """Persistent state with atomic checkpoints"""

    def __init__(self, db_path):
        self.db = sqlite3.connect(db_path)
        self._ensure_schema()

    def checkpoint(self, phase, data):
        """Atomic checkpoint save"""
        with self.db:  # Transaction
            self.db.execute("""
                INSERT OR REPLACE INTO checkpoints
                (phase, data, timestamp)
                VALUES (?, ?, ?)
            """, (phase, json.dumps(data), datetime.now()))

    def resume_from_checkpoint(self, phase):
        """Load last checkpoint"""
        row = self.db.execute("""
            SELECT data FROM checkpoints
            WHERE phase = ?
            ORDER BY timestamp DESC
            LIMIT 1
        """, (phase,)).fetchone()

        return json.loads(row[0]) if row else None

    def get_incomplete_jobs(self):
        """Query for resume"""
        return self.db.execute("""
            SELECT * FROM download_queue
            WHERE status IN ('queued', 'downloading', 'rate_limited')
            ORDER BY priority DESC, created_at ASC
        """).fetchall()
```

**Checkpoint Frequency:**
- After each completed download (job-level granularity)
- After each phase completion (download→transcode→sync)
- On graceful shutdown (save current worker state)

**Trade-off:** More checkpoints = better resumability but slower (write overhead). Balance: checkpoint every job completion (natural boundary).

### Challenge: Progress Tracking Across Multiple Workers

**Problem:** 8 parallel download workers, UI needs real-time aggregate progress.

**Solution: Thread-Safe Aggregator**

Reference implementation from `streaming2ipod/lib/iPod_lib_sync/sync.py`:

```python
class ThreadSafeProgress:
    """Atomic progress tracking for multi-threaded operations"""

    def __init__(self, total: int, operation: str):
        self._lock = threading.Lock()
        self._completed = 0
        self._total = total
        self._current_files = []
        self._start_time = time.time()

    def update(self, completed: int = 1, current_file: str = ""):
        """Thread-safe increment"""
        with self._lock:
            self._completed += completed
            if current_file:
                self._current_files.append(current_file)
                self._current_files = self._current_files[-10:]  # Keep last 10

    def get_stats(self) -> Dict:
        """Thread-safe read"""
        with self._lock:
            elapsed = time.time() - self._start_time
            rate = self._completed / elapsed if elapsed > 0 else 0
            remaining = (self._total - self._completed) / rate if rate > 0 else 0
            return {
                'completed': self._completed,
                'total': self._total,
                'percentage': (self._completed / self._total * 100),
                'elapsed': elapsed,
                'remaining': remaining,
                'rate': rate
            }
```

**UI Polling Pattern:**
```javascript
// Poll every 500ms for smooth updates
setInterval(async () => {
  const stats = await invoke('get_progress_stats');
  updateProgressBar(stats.percentage);
  updateETA(stats.remaining);
  updateCurrentFiles(stats.current_files);
}, 500);
```

## Multi-Source Aggregation Architecture

### Challenge: Merging Spotify + Apple Music + SoundCloud into Unified Library

**Problem:** Same song appears in multiple services with different metadata, URLs, and IDs. Must deduplicate while preserving source references.

**Solution: Source-Agnostic Core with Source Adapters**

```
┌──────────────────────────────────────────────────────────┐
│                  Aggregation Manager                      │
└────────┬───────────────────┬──────────────────┬──────────┘
         │                   │                  │
┌────────▼────────┐  ┌───────▼───────┐  ┌──────▼──────────┐
│ Spotify Adapter │  │ Apple Adapter │  │ SoundCloud Adptr│
│ - Poll API      │  │ - Poll API    │  │ - Poll API      │
│ - Normalize     │  │ - Normalize   │  │ - Normalize     │
│ - Extract liked │  │ - Extract lib │  │ - Extract likes │
└────────┬────────┘  └───────┬───────┘  └──────┬──────────┘
         │                   │                  │
         └───────────────────┼──────────────────┘
                             ▼
                    ┌────────────────┐
                    │ Deduplication  │
                    │ Engine         │
                    └────────┬───────┘
                             ▼
                    ┌────────────────┐
                    │ Unified Track  │
                    │ Database       │
                    └────────────────┘
```

### Deduplication Strategy

**Multi-Stage Matching:**

1. **Exact Match** (fast path):
   ```sql
   SELECT track_id FROM tracks
   WHERE title = ? AND artist_id IN (
     SELECT artist_id FROM artists WHERE name = ?
   ) AND ABS(duration_ms - ?) < 2000  -- ±2 seconds tolerance
   ```

2. **Fuzzy Match** (normalized strings):
   ```python
   def normalize(text):
       return re.sub(r'[^\w\s]', '', text.lower()).strip()

   normalized_title = normalize("Song (feat. Artist)")
   # -> "song feat artist"
   ```

3. **Audio Fingerprint** (when files downloaded):
   ```python
   # Use Chromaprint (fpcalc) for acoustic matching
   fingerprint1 = generate_fingerprint(file1)
   fingerprint2 = generate_fingerprint(file2)
   similarity = compare_fingerprints(fingerprint1, fingerprint2)

   if similarity > 0.95:  # 95% match
       mark_as_duplicate()
   ```

**Schema Design for Multi-Source:**

```sql
-- One track can have multiple sources
INSERT INTO tracks (title, artist_id, file_path)
VALUES ('Song Name', 123, '/Music/Artist/Album/Song.flac');

INSERT INTO track_sources (track_id, source_type, source_url)
VALUES
  (1, 'spotify', 'spotify:track:abc123'),
  (1, 'apple_music', 'https://music.apple.com/...'),
  (1, 'soundcloud', 'https://soundcloud.com/...');
```

**Query Pattern:**
```sql
-- Find all tracks liked on Spotify
SELECT t.* FROM tracks t
JOIN track_sources ts ON t.track_id = ts.track_id
WHERE ts.source_type = 'spotify';

-- Find tracks in multiple sources (potential duplicates)
SELECT t.track_id, COUNT(*) as source_count
FROM tracks t
JOIN track_sources ts ON t.track_id = ts.track_id
GROUP BY t.track_id
HAVING source_count > 1;
```

## Patterns to Follow

### Pattern 1: Pipeline with Checkpoints

**What:** Break long operations into phases with persistent state between phases.

**When:** Any operation taking >5 minutes that could fail partway through.

**Example:**
```python
class Pipeline:
    def run(self):
        if not self.state.is_phase_complete('download'):
            self.download_phase()
            self.state.checkpoint('download', {'completed': True})

        if not self.state.is_phase_complete('transcode'):
            self.transcode_phase()
            self.state.checkpoint('transcode', {'completed': True})

        if not self.state.is_phase_complete('sync'):
            self.sync_phase()
            self.state.checkpoint('sync', {'completed': True})
```

**Benefits:** Crash at any point → restart from last checkpoint, no wasted work.

### Pattern 2: Worker Pool with Rate Limiting

**What:** Parallel workers with adaptive rate limiting to avoid 429 errors.

**When:** Downloading from rate-limited APIs or services.

**Example from reference implementation:**
```python
class AdaptiveRateLimiter:
    def __init__(self, initial_delay=3.0, max_delay=120.0):
        self.delay = initial_delay
        self.max_delay = max_delay
        self.consecutive_successes = 0

    def wait(self):
        time.sleep(self.delay)

    def report_success(self):
        self.consecutive_successes += 1
        if self.consecutive_successes >= 5:
            self.delay *= 0.9  # Gradually reduce delay
            self.consecutive_successes = 0

    def report_rate_limit(self):
        self.delay = min(self.delay * 2.0, self.max_delay)
        self.consecutive_successes = 0
```

**Benefits:** Automatically backs off when hitting rate limits, speeds up when safe.

### Pattern 3: Metadata-First, Files-Second

**What:** Fetch all metadata first (fast API calls), then download files (slow transfers).

**When:** Syncing playlists or large collections.

**Example:**
```python
# Phase 1: Fast metadata fetch (all tracks in ~10 seconds)
metadata = yt_dlp.fetch_playlist_metadata(playlist_url)
db.insert_tracks(metadata, status='pending')

# Phase 2: Slow file downloads (hours, resumable)
pending_tracks = db.get_tracks(status='pending')
for track in pending_tracks:
    download_file(track.url)
    db.update_status(track.id, 'completed')
```

**Benefits:** User sees full track list immediately, downloads happen in background.

### Pattern 4: Optimistic File Organization

**What:** Organize files into Artist/Album structure immediately on download.

**When:** Building music library (not temporary downloads).

**Example:**
```python
def get_output_path(metadata):
    artist = sanitize_filename(metadata['artist'])
    album = sanitize_filename(metadata['album'])
    title = sanitize_filename(metadata['title'])

    return Path(f"Music/Artists/{artist}/{album}/{title}.flac")

# Download directly to final location
download(url, output_path=get_output_path(metadata))
```

**Benefits:** No post-download reorganization needed, files always browsable.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Pure JSON Database

**What:** Storing all track/album/artist data in JSON files without database.

**Why bad:**
- No indexing → slow queries as library grows
- No ACID → corruption on crash
- No concurrent access → workers can't update in parallel
- No schema validation → data inconsistencies

**Instead:** Use SQLite for structured data, JSON only for snapshots/exports.

**Real-world impact:** 10,000 track library, finding tracks by artist takes:
- JSON file scan: ~500ms (reads entire file, filters in memory)
- SQLite index: ~5ms (indexed query)

### Anti-Pattern 2: Synchronous Download Loop

**What:** Downloading tracks one at a time in a single thread.

**Why bad:**
- Network latency dominates → CPU sits idle
- Takes 10x longer than parallel approach
- No recovery from failures

**Instead:** Worker pool pattern with queue and parallel downloads.

**Example mistake:**
```python
# BAD: Sequential downloads
for track in tracks:
    download(track.url)  # Waits for each to complete
```

**Correct:**
```python
# GOOD: Parallel downloads
with ThreadPoolExecutor(max_workers=8) as executor:
    futures = [executor.submit(download, t.url) for t in tracks]
    for future in as_completed(futures):
        result = future.result()
```

### Anti-Pattern 3: Eager Transcoding During Download

**What:** Transcoding files to AAC immediately after downloading FLAC.

**Why bad:**
- Destroys original quality if user wants to change format later
- Can't re-transcode to different bitrate without re-downloading
- Wastes space (have to keep both versions during transition)

**Instead:** Archive originals, transcode only when syncing to device.

**Correct flow:**
```
Download FLAC → Archive/Artists/{artist}/{album}/*.flac
                     ↓ (only when syncing to device)
Transcode AAC → Device/Artists/{artist}/{album}/*.m4a
```

### Anti-Pattern 4: Global Rate Limiting

**What:** Single rate limiter shared across all download sources.

**Why bad:**
- dabmusic.xyz API might allow 10/sec
- SoundCloud might only allow 1/10sec
- Sharing rate limiter means fastest source is throttled by slowest

**Instead:** Per-source rate limiters.

```python
class DownloadManager:
    def __init__(self):
        self.rate_limiters = {
            'dabmusic': RateLimiter(initial_delay=0.1),
            'soundcloud': RateLimiter(initial_delay=3.0),
            'youtube': RateLimiter(initial_delay=1.0)
        }

    def download(self, source, url):
        limiter = self.rate_limiters[source]
        limiter.wait()
        # ... download logic
```

### Anti-Pattern 5: No Deduplication

**What:** Allowing same track to be downloaded multiple times from different sources.

**Why bad:**
- Wastes disk space
- Confuses users (duplicates in library)
- Wastes bandwidth re-downloading

**Instead:** Fuzzy matching on insert before queuing download.

```python
def queue_download(track):
    # Check if track already exists
    existing = db.find_similar_track(
        title=track.title,
        artist=track.artist,
        duration_tolerance=2000  # ±2 seconds
    )

    if existing:
        # Just add source reference, don't re-download
        db.add_track_source(existing.track_id, track.source_url)
    else:
        # New track, queue download
        db.insert_track(track, status='pending')
```

## Build Order Recommendations

Based on component dependencies, suggested implementation order:

### Phase 1: Foundation (No Dependencies)
1. **Database schema** (`tracks`, `artists`, `albums` tables)
2. **File utilities** (path sanitization, hash calculation)
3. **Configuration management** (load settings from YAML/JSON)

**Rationale:** Everything else depends on data models and file operations.

### Phase 2: Core Pipeline (Depends on Phase 1)
4. **Download manager** (single-source first, e.g., just dabmusic.xyz)
5. **Worker pool** (ThreadPoolExecutor wrapper with progress tracking)
6. **State manager** (checkpoint save/load, resume capability)

**Rationale:** Proves basic pipeline works before adding complexity.

### Phase 3: Processing (Depends on Phase 2)
7. **Metadata processor** (ID3 tag cleaning, artwork embedding)
8. **Transcoding engine** (ffmpeg wrapper for FLAC→AAC)

**Rationale:** Need downloaded files to process before building this.

### Phase 4: Multi-Source (Depends on Phase 2)
9. **API adapters** (Spotify, Apple Music, SoundCloud clients)
10. **Aggregation manager** (poll APIs, normalize metadata)
11. **Deduplication engine** (fuzzy matching, fingerprinting)

**Rationale:** Basic download works, now add multiple sources.

### Phase 5: Sync (Depends on Phase 3)
12. **Device scanner** (read device state, build file index)
13. **Diff engine** (compare source vs. device)
14. **Sync manager** (copy files, verify, update state)

**Rationale:** Need transcoding working before syncing to devices.

### Phase 6: UI (Depends on All)
15. **Backend IPC layer** (Tauri commands or Electron main process)
16. **Frontend UI** (React/Vue components for library browsing)
17. **Progress visualization** (real-time updates from workers)

**Rationale:** Backend must be stable before building UI.

### Phase 7: Polish (Independent)
18. **Playlist generator** (fuzzy matching, M3U8 export)
19. **Verification** (audio fingerprinting, quality checks)
20. **Settings UI** (configuration editor)

**Rationale:** Nice-to-have features, not critical path.

## Scalability Considerations

| Concern | At 1K tracks | At 10K tracks | At 100K tracks |
|---------|--------------|---------------|----------------|
| **Metadata queries** | SQLite in-memory | SQLite indexed | SQLite with WAL mode, connection pooling |
| **File scanning** | Single-threaded OK | Parallel workers (8) | Parallel workers (16+), incremental scan cache |
| **Download queue** | In-memory queue | SQLite queue table | SQLite with priority indexing, batch inserts |
| **Deduplication** | Exact match only | Fuzzy match on insert | Pre-computed normalized index, batch fuzzy checks |
| **Transcoding** | Inline (during sync) | Background queue | Dedicated transcode service, cache transcodes |
| **UI responsiveness** | Direct queries | Pagination (100/page) | Virtual scrolling, search index, lazy loading |

**Key Threshold:** ~10K tracks is inflection point where naive approaches start slowing down. Design for 10K from start.

## Technology Stack Implications

Based on architecture requirements:

| Layer | Recommended | Rationale |
|-------|-------------|-----------|
| **Desktop UI** | Tauri + React | Smaller binary than Electron, cleaner IPC, existing Python backend |
| **Backend Orchestration** | Python 3.11+ | Rich ecosystem (mutagen, yt-dlp, sqlite3), matches reference implementation |
| **Worker Pool** | Python ThreadPoolExecutor | IO-bound tasks (downloads, file ops), simple API |
| **Transcoding** | ffmpeg subprocess | Industry standard, mature, supports all formats |
| **Database** | SQLite 3.35+ | ACID guarantees, no server needed, JSON support, WAL mode for concurrency |
| **State Files** | JSON + SQLite | JSON for human-readable exports, SQLite for structured queries |
| **API Clients** | spotipy (Spotify), soundcloud-python, yt-dlp | Mature, well-documented libraries |

## Sources

### Architecture & Patterns
- [MVC Architecture for Music Library](https://www.researchgate.net/figure/MVC-architecture-of-the-Music-Library-Management-System_fig7_309458801)
- [Web-Queue-Worker Architecture (Microsoft)](https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/web-queue-worker)
- [Long-Running Tasks Architecture](https://www.ichaoran.com/posts/2024-11-26-long-running-task-app/)
- [System Design Pattern: Long Running Tasks](https://medium.com/@priyasrivastava18official/system-design-pattern-long-running-tasks-if-it-takes-more-than-3-seconds-it-belongs-in-the-141cc3eb3967)

### Database Design
- [MusicBrainz Database Schema](https://musicbrainz.org/doc/MusicBrainz_Database/Schema)
- [Spotify Database Design](https://medium.com/towards-data-engineering/design-the-database-for-a-system-like-spotify-95ffd1fb5927)
- [Music Streaming Database Design (GeeksforGeeks)](https://www.geeksforgeeks.org/sql/how-to-design-a-database-for-music-streaming-app/)
- [Building Scalable Digital Music Store Database](https://medium.com/@bhargavkoya56/building-a-scalable-digital-music-store-database-from-scratch-edbac98025fc)

### Pipeline & Processing
- [FFmpeg Documentation](https://ffmpeg.org/ffmpeg.html)
- [FFmpeg Transcoding Tutorial](https://github.com/leandromoreira/ffmpeg-libav-tutorial)
- [FFmpeg Ultimate Guide](https://img.ly/blog/ultimate-guide-to-ffmpeg/)

### Desktop Application Architecture
- [Tauri vs Electron Comparison](https://raftlabs.medium.com/tauri-vs-electron-a-practical-guide-to-picking-the-right-framework-5df80e360f26)
- [Electron vs Tauri (DoltHub)](https://www.dolthub.com/blog/2025-11-13-electron-vs-tauri/)
- [Tauri GitHub Repository](https://github.com/tauri-apps/tauri)

### Background Jobs & Workers
- [Job Queues & CQRS](https://softwareontheroad.com/job-queues-cqrs-nodejs-mongodb-agenda)
- [BullMQ - Background Jobs for Node.js](https://bullmq.io/)
- [Worker Dynos and Queueing (Heroku)](https://devcenter.heroku.com/articles/background-jobs-queueing)
- [Queue-Based Load Leveling (Azure)](https://learn.microsoft.com/en-us/azure/architecture/patterns/queue-based-load-leveling)

**Confidence Level: HIGH** - Architecture patterns verified through multiple authoritative sources (MusicBrainz schema, Microsoft Azure patterns, FFmpeg documentation) and validated against existing reference implementation.
