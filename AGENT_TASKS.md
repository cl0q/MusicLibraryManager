
3
1
8
6
rest




# Agent Task Prompts

Self-contained prompts for future coding sessions. Each can be given to a fresh agent as-is.
Copy one prompt, paste it into a new session, and the agent should be able to execute it autonomously.

---

## Task 1: Unified Error Handling

```
## Task: Unify error handling across the Rust backend

This is a Tauri desktop app (Rust backend + React frontend). The codebase at `src-tauri/src/` currently mixes three error patterns:

1. `anyhow::Result` in internal modules
2. Custom error enums (`SoundCloudError` in sources/soundcloud.rs, `AppleMusicError` in sources/apple_music.rs, `SpotifyError` in sources/spotify.rs)  
3. `Result<T, String>` at Tauri `#[tauri::command]` boundaries with `.map_err(|e| format!(...))` everywhere

### What to do

1. **Create `src-tauri/src/error.rs`** with a unified `AppError` enum that:
   - Has variants for each domain: `Database(String)`, `Network(String)`, `Auth(String)`, `Sync(String)`, `Download(String)`, `Transcode(String)`, `Config(String)`, `Io(String)`, `NotFound(String)`
   - Implements `From<rusqlite::Error>`, `From<reqwest::Error>`, `From<std::io::Error>`, `From<anyhow::Error>`
   - Implements `From<SoundCloudError>`, `From<AppleMusicError>`, `From<SpotifyError>`
   - Implements `serde::Serialize` so Tauri can send it to the frontend
   - Implements `std::fmt::Display` and `std::error::Error`

2. **Update Tauri commands** in `src-tauri/src/commands/*.rs`:
   - Change `Result<T, String>` to `Result<T, AppError>` 
   - Remove all the `.map_err(|e| format!(...))` chains
   - Tauri commands that return `Result<T, E>` where E: Serialize will auto-serialize the error

3. **Update the frontend** in `ui/src/utils/tauri-commands.ts`:
   - Create an `AppError` type matching the Rust enum
   - Add a helper `parseError(err: unknown): { domain: string; message: string }` that extracts structured error info
   - Update error handling in `ui/src/pages/Sources.tsx` and other pages to use this

4. **Keep the domain-specific error enums** (SoundCloudError etc.) but add `From` impls so they convert into `AppError` at the command boundary.

Run `cargo check` after changes to verify compilation. Check `ui/src/` for TypeScript errors too.
```

---

## Task 2: Persistent Download Queue with Resume

```
## Task: Add persistent download queue with resume-on-restart

This is a Tauri app (Rust + React). Downloads are triggered from the UI and executed in `src-tauri/src/download/`. The database is SQLite via rusqlite at `src-tauri/src/database/`.

### Current state
- Look at `src-tauri/src/commands/download.rs` for the download command
- Look at `src-tauri/src/download/` for the download pipeline  
- The database schema is in `src-tauri/src/database/schema.rs`

### What to implement

1. **Database table `download_queue`:**
   ```sql
   CREATE TABLE IF NOT EXISTS download_queue (
     id INTEGER PRIMARY KEY,
     track_id INTEGER NOT NULL,
     source TEXT NOT NULL,           -- 'soundcloud', 'spotify', 'apple_music'
     external_id TEXT NOT NULL,
     url TEXT,
     status TEXT NOT NULL DEFAULT 'pending',  -- 'pending', 'downloading', 'completed', 'failed', 'paused'
     progress REAL DEFAULT 0.0,
     error_message TEXT,
     retry_count INTEGER DEFAULT 0,
     created_at TEXT NOT NULL,
     updated_at TEXT NOT NULL,
     FOREIGN KEY (track_id) REFERENCES tracks(id)
   );
   ```

2. **Queue manager** in `src-tauri/src/download/queue.rs`:
   - `enqueue(conn, track_id, source, external_id)` — add to queue
   - `dequeue_batch(conn, limit)` — get next N pending items
   - `update_status(conn, queue_id, status, progress, error)` — update item
   - `get_pending_count(conn)` — count remaining
   - `resume_interrupted(conn)` — on startup, reset any 'downloading' items back to 'pending'

3. **Startup hook** in `src-tauri/src/startup.rs`:
   - Call `resume_interrupted()` to recover from crashes
   - Optionally auto-start processing the queue

4. **Tauri commands:**
   - `get_download_queue()` — return current queue state  
   - `pause_downloads()` / `resume_downloads()` — toggle processing
   - `retry_failed()` — reset failed items to pending
   - `clear_completed()` — clean up

5. **Frontend** — look at `ui/src/components/ActivityPanel/ActivityPanel.tsx` which already shows download progress. Add a queue view showing pending/active/failed items with retry/cancel buttons.

Don't break existing download functionality — integrate the queue around it.
```

---

## Task 3: Database Migration System

```
## Task: Add versioned database migrations

This is a Tauri app with SQLite via rusqlite. The schema is defined in `src-tauri/src/database/schema.rs` and the connection setup is in `src-tauri/src/database/connection.rs`.

### What to do

1. **Check Cargo.toml** for existing migration dependencies. If none, add `rusqlite_migration` to `src-tauri/Cargo.toml`.

2. **Create migration files** in `src-tauri/src/database/migrations/`:
   - `001_initial_schema.sql` — extract the current CREATE TABLE statements from schema.rs
   - `002_add_library_size_limit.sql` — for the `app_config` table entry (check if it exists)
   - Future migrations get sequential numbers

3. **Update `src-tauri/src/database/connection.rs`** (or `mod.rs`):
   - On `get_connection()`, run pending migrations automatically
   - Store migration version in a `_migrations` table
   - Log which migrations were applied

4. **Update `schema.rs`**:
   - Remove the inline CREATE TABLE statements that are now in migration files
   - Keep `ensure_tables()` as a migration runner instead of raw SQL executor

5. **Add a Tauri command** `get_db_version()` that returns the current migration version (useful for debugging).

Read the existing schema.rs and connection.rs first to understand the current approach before making changes.
```

---

## Task 4: Rectangle Selection in Track Tables

```
## Task: Implement rectangle (marquee) selection in track table

This is a React + TypeScript frontend at `ui/src/`. Track listings appear in table components.

### What to investigate first
- Search for table/track list components in `ui/src/components/` — look for files with "Track", "Table", "Library", "List" in the name
- Find the component that renders rows of tracks with checkboxes or selection state
- Check what selection state management exists (single select? multi-select with Ctrl+click?)

### What to implement

1. **Selection hook** `ui/src/hooks/useRectangleSelection.ts`:
   - Track mousedown position (x, y) on the table container
   - On mousemove while button held, render a semi-transparent blue rectangle overlay
   - Calculate which table rows intersect the rectangle (using `getBoundingClientRect()` on each row)
   - On mouseup, commit selection — set those rows as selected
   - Only activate when Shift is held (to avoid interfering with normal clicks)
   - Support additive selection (Ctrl+Shift+drag adds to existing selection)

2. **Visual overlay**: Absolute-positioned div with `border: 1px solid #3b82f6; background: rgba(59, 130, 246, 0.1)` positioned between mousedown point and current mouse position.

3. **Integration**: Apply the hook to whatever track table component exists. The hook should accept:
   - `containerRef: RefObject<HTMLElement>` — the scrollable table container
   - `rowSelector: string` — CSS selector for rows (e.g. `'tr[data-track-id]'` or `'[data-row-index]'`)
   - `onSelectionChange: (selectedIds: Set<string>) => void`

4. **Performance**: Use `requestAnimationFrame` for mousemove updates. For tables with 1000+ rows, only check visible rows (intersection with viewport).

Look at the existing selection patterns in the codebase first and integrate with them rather than creating a parallel system.
```

---

## Task 5: Parallel Download Streams

```
## Task: Add concurrent download support with bounded parallelism

This is a Tauri app (Rust backend). Downloads happen in `src-tauri/src/download/`.

### What to investigate
1. Read `src-tauri/src/download/` — understand the current download pipeline
2. Read `src-tauri/src/commands/download.rs` — understand how downloads are triggered
3. Check if downloads are currently sequential or already have some concurrency
4. Look for any rate limiting, token bucket, or semaphore patterns

### What to implement

1. **Concurrency control** using `tokio::sync::Semaphore`:
   - Default: 3 concurrent downloads
   - Configurable via a Tauri command `set_download_concurrency(n: usize)` (min 1, max 10)
   - Store the setting in the app_config table

2. **Download manager** (if not already present):
   - Accepts download requests and spawns them as tokio tasks
   - Each task acquires a semaphore permit before starting the HTTP request  
   - Releases the permit when done (success or failure)
   - Emits progress events per-download so the UI can show multiple progress bars

3. **Frontend updates** in `ui/src/components/ActivityPanel/ActivityPanel.tsx`:
   - Show multiple concurrent downloads with individual progress bars
   - Show a global throughput indicator (total MB/s across all streams)
   - Add a concurrency slider in settings

4. **Source-specific rate limiting**:
   - SoundCloud may have rate limits — add a per-source delay option
   - If a 429 (Too Many Requests) is received, back off and reduce concurrency temporarily

Don't break existing single-download functionality. The concurrent system should be backwards-compatible.
```

---

## Task 6: macOS Built App Path Resolution (Sidecar Binaries)

```
## Task: Fix helper binary path resolution in macOS .app bundle

This is a Tauri app. In dev mode, helper programs (likely ffmpeg, chromaprint/fpcalc) work fine, but in the built .app bundle they don't resolve.

### What to investigate

1. Read `src-tauri/tauri.conf.json` — look for `bundle.externalBin` configuration
2. Search the Rust code for how ffmpeg/fpcalc/other binaries are invoked:
   - `grep -r "Command::new" src-tauri/src/`
   - `grep -r "ffmpeg\|fpcalc\|chromaprint" src-tauri/src/`
3. Check `src-tauri/src/transcode/` for ffmpeg invocation
4. Check `src-tauri/src/fingerprint/` for chromaprint/fpcalc invocation
5. Look at `src-tauri/src/startup.rs` for any PATH setup

### Common issue and fix

Tauri sidecar binaries need:
1. To be listed in `tauri.conf.json` under `bundle > externalBin` as paths relative to `src-tauri/` WITHOUT the platform triple suffix
2. The actual binaries placed at `src-tauri/binaries/{name}-{target_triple}` (e.g., `ffmpeg-aarch64-apple-darwin`)
3. In Rust code, use `app.shell().sidecar("ffmpeg")` instead of `Command::new("ffmpeg")`

### What to fix

1. If binaries are invoked via `std::process::Command::new("ffmpeg")`, change to use Tauri's sidecar API or resolve the path relative to the app bundle
2. Create a helper `fn resolve_binary(name: &str) -> PathBuf` that:
   - In dev: uses PATH lookup (current behavior)
   - In production: looks in the app bundle's Resources or MacOS directory
3. Update all binary invocations to use this helper
4. Update `tauri.conf.json` if sidecar entries are missing
5. Document in a comment what binaries need to be placed where for building

Test by checking the compiled paths resolve correctly. You can verify the logic without actually building the app.
```

---

## Task 7: Offline Mode / Graceful Degradation

```
## Task: Add offline mode with graceful degradation

This is a Tauri app (Rust + React). When opened without network, source pages may crash or show unhelpful errors.

### What to investigate

1. Read `ui/src/pages/Sources.tsx` — what happens when connect/sync calls fail due to network?
2. Read `ui/src/components/Dashboard/StatsCards.tsx` — does it handle fetch failures?
3. Search for network-dependent operations: `grep -r "invoke\|fetch\|http\|reqwest" ui/src/`
4. Check if there's any network status detection already

### What to implement

1. **Network status hook** `ui/src/hooks/useNetworkStatus.ts`:
   - Use `navigator.onLine` + `online`/`offline` events
   - Also do a lightweight ping to the backend on interval (every 30s)
   - Export `{ isOnline, isBackendReachable }` 

2. **Network status context** wrapping the app — provide the hook's state to all components

3. **StatusBar indicator**: Show a subtle "Offline" badge when disconnected

4. **Graceful degradation per page:**
   - **Sources page**: Disable sync/connect buttons when offline, show "Offline — sync unavailable" message
   - **Dashboard**: Show cached stats from last known state, with "Last updated: X" timestamp
   - **Library/Search**: Should work fully offline (local SQLite)
   - **Download page**: Queue downloads but don't attempt them; show "Downloads will resume when online"

5. **Backend**: Add a `check_connectivity` Tauri command that tries to reach a known endpoint (e.g., `https://clients3.google.com/generate_204`) and returns bool

6. **Error messages**: Replace generic "Failed to..." messages with "Network unavailable — ..." when offline

Focus on not crashing — it's OK if features are limited offline, but the app should remain usable for local library browsing.
```

---

## Task 8: Sync Logic Unit Tests

```
## Task: Add comprehensive unit tests for sync/dedup logic

This is a Rust backend at `src-tauri/src/`. The sync logic deduplicates tracks from external sources against the local library.

### Critical functions to test

1. **`src-tauri/src/sources/soundcloud.rs`**:
   - `insert_track_from_soundcloud()` (~line 647) — deduplicates by external_id, permalink_url, and title/artist similarity
   - `find_similar_track()` — fuzzy matching for track dedup
   - `sync_likes()` on `SoundCloudClient` — the main sync loop

2. **`src-tauri/src/sources/apple_music.rs`**:
   - `sync_library_songs()` — paginates and counts new vs existing
   - `scrape_developer_token()` — the multi-strategy token extraction
   - `extract_jwt_from_text()`, `extract_token_from_meta_tag()`, `extract_token_from_musickit_config()` — test each strategy with sample HTML

3. **`src-tauri/src/sources/spotify.rs`**:
   - `sync_liked_songs()` — similar dedup pattern to SoundCloud

### What to implement

1. **Test helpers** in `src-tauri/src/sources/test_helpers.rs` (or inline `#[cfg(test)] mod tests`):
   - `fn setup_test_db() -> Connection` — create an in-memory SQLite DB with the full schema
   - `fn make_soundcloud_track(id: u64, title: &str, artist: &str) -> SoundCloudTrack` — factory
   - Similar factories for Spotify and Apple Music track types

2. **Dedup tests for SoundCloud:**
   - Insert track → returns true (new)
   - Insert same track again (same external_id) → returns false (existing)
   - Insert track with same permalink_url but different external_id → returns false
   - Insert track with similar title/artist → test the fuzzy matching threshold
   - Insert track with completely different metadata → returns true

3. **Sync count accuracy:**
   - Sync with empty DB → all tracks counted as added
   - Sync again → 0 added, N skipped
   - Add new tracks to mock API response → only new ones counted

4. **Apple Music token extraction tests:**
   - Test `extract_token_from_meta_tag()` with real HTML samples (sanitized)
   - Test `extract_jwt_from_text()` with text containing valid/invalid JWTs
   - Test `is_apple_music_developer_jwt()` with real vs fake JWT headers

5. **Edge cases:**
   - Empty API response (0 tracks)
   - API pagination (multiple pages)
   - Tracks with empty title/artist
   - Unicode track names
   - Very long track titles (>500 chars)

Look at existing tests in `src-tauri/tests/` for patterns. Put unit tests as `#[cfg(test)] mod tests` inside each source file.
```

---

## Task 9: Configurable Transcoding Quality

```
## Task: Make transcoding quality configurable per sync profile

The transcode module is at `src-tauri/src/transcode/mod.rs`. Currently it targets 248kbps AAC globally.

### What to investigate
1. Read `src-tauri/src/transcode/mod.rs` — understand the current pipeline and FfmpegConfig
2. Read `src-tauri/src/sync/profile.rs` — the SyncProfile struct and its DB storage  
3. Read `src-tauri/src/models/sync.rs` — the SyncProfileDto sent to frontend
4. Read `ui/src/components/SyncProfiles.tsx` — the profile editing UI

### What to implement

1. **Add fields to SyncProfile** in `src-tauri/src/sync/profile.rs`:
   - `transcode_codec: String` — "aac", "mp3", "opus", "flac" (default: "aac")
   - `transcode_bitrate: u32` — in kbps (default: 248)
   - `transcode_sample_rate: Option<u32>` — optional, e.g. 44100, 48000

2. **Update the schema** — add columns to `sync_profiles` table (with migration)

3. **Update SyncProfileDto** in `src-tauri/src/models/sync.rs` to include the new fields

4. **Pass config to transcode pipeline** — modify `src-tauri/src/transcode/mod.rs` to accept codec/bitrate from the profile instead of hardcoded values

5. **Frontend — profile editor** in `ui/src/components/SyncProfiles.tsx`:
   - Add a "Quality" section with:
     - Codec dropdown: AAC, MP3, Opus, FLAC (lossless)
     - Bitrate slider: 128-320 kbps (disabled for FLAC)
     - Sample rate dropdown: Auto, 44.1kHz, 48kHz
   - Show estimated file size per track (avg 4 min × bitrate)

6. **Presets**: Add quick-select buttons: "High Quality" (AAC 256), "Standard" (AAC 192), "Compact" (MP3 128), "Lossless" (FLAC)

Update the sync execution path to read these settings from the profile and pass them to the transcoder.
```

---

## Usage

Copy any task block (everything inside the triple backticks) into a new chat session. The agent will have enough context to:
1. Find the relevant files
2. Understand the architecture
3. Make the changes
4. Verify compilation

For best results, start a fresh context window per task.
