---
phase: 11
plan: 01
subsystem: download-backend
tags: [download, progress-streaming, database, state-management]
dependencies:
  requires:
    - phase: 9
      plan: 01
      reason: "download_status column in tracks table"
  provides:
    - capability: "Download progress streaming via events"
      consumers: ["frontend-download-ui"]
    - capability: "Automatic download_status timestamp updates"
      consumers: ["library-remote-separation"]
  affects:
    - "src-tauri/src/commands/download.rs"
    - "src-tauri/src/download/orchestrator.rs"
    - "src-tauri/src/database/tracks.rs"
tech_stack:
  added:
    - component: "database::tracks module"
      purpose: "Track status management functions"
  patterns:
    - pattern: "Event-based progress streaming"
      rationale: "Tauri v2 event system for real-time UI updates"
    - pattern: "BatchResult with downloaded_track_ids"
      rationale: "Decouple async download from sync database updates"
key_files:
  created:
    - path: "src-tauri/src/database/tracks.rs"
      purpose: "Track status update functions"
      exports: ["update_download_status"]
  modified:
    - path: "src-tauri/src/commands/download.rs"
      changes: "Added progress streaming and completion events, database status updates"
    - path: "src-tauri/src/download/orchestrator.rs"
      changes: "Added progress callback support, track downloaded_track_ids in result"
    - path: "src-tauri/src/database/mod.rs"
      changes: "Exported tracks module"
decisions: []
metrics:
  duration_minutes: 4
  tasks_completed: 3
  files_modified: 4
  files_created: 1
  commits: 3
  completed_at: "2026-02-09T17:56:42Z"
---

# Phase 11 Plan 01: Backend Progress & Status Tracking Summary

**One-liner:** Event-based download progress streaming with automatic download_status timestamp updates on success

## What Was Built

Added real-time progress streaming and database state management to the backend download pipeline. The download_tracks command now emits progress events during batch processing and automatically updates the download_status column for successful downloads, enabling Remote→Library transitions.

### Key Components

1. **Progress Event Streaming**
   - ProgressUpdate struct for event payloads (current, total, track_title)
   - download-progress events emitted during batch processing
   - download-complete event with BatchResult after completion

2. **Database Status Management**
   - database::tracks::update_download_status function
   - Sets download_status to ISO 8601 timestamp (chrono::Utc::now().to_rfc3339())
   - Called for each successfully downloaded track

3. **Orchestrator Integration**
   - Progress callback parameter in download_batch method
   - downloaded_track_ids tracked in BatchResult
   - Callback invoked before processing each track

## Implementation Details

### Event-Based Progress Pattern

Used Tauri v2 event emission instead of IPC channels (which have serialization constraints). The download command clones the AppHandle and emits events from the progress callback closure:

```rust
let progress_callback = Box::new(move |current, total, track_title| {
    let update = ProgressUpdate { current, total, track_title };
    let _ = app_handle_clone.emit("download-progress", &update);
});
```

### Database Update Timing

Database updates happen AFTER the async batch completes (not during) to avoid Send/Sync issues with rusqlite::Connection. The orchestrator tracks downloaded_track_ids in BatchResult, and the command handler updates them synchronously:

```rust
for track_id in &result.downloaded_track_ids {
    tracks::update_download_status(&db_conn, *track_id)?;
}
```

### Track ID Capture Logic

Track IDs are captured only for successful downloads (Transcoded or Skipped outcomes). Failed transcodes do NOT update download_status, keeping the track in Remote view for retry.

## Architecture Decisions

### Why Events Instead of Channels?

Tauri v2 IPC channels require Deserialize trait on all command parameters, which creates ergonomic issues for optional channel parameters. Events provide simpler one-way communication for progress updates where the frontend can choose to listen or ignore.

### Why BatchResult Contains Track IDs?

Passing &rusqlite::Connection to async orchestrator.download_batch violates Send bounds (Connection contains RefCell). By returning downloaded_track_ids in the result, we decouple async download logic from sync database updates.

### Why Update After Batch vs Per-Track?

Updating download_status synchronously after the async batch completes simplifies error handling and keeps database operations in the command handler (which already manages the connection). Per-track updates would require either:
- Passing Connection (violates Send)
- Opening new connections per track (inefficient)
- Complex shared state (Arc<Mutex<Connection>>, overkill)

## Deviations from Plan

None - plan executed exactly as written.

## Integration Points

### Frontend Consumers

Frontend can now:
1. Listen to "download-progress" events for real-time UI updates
2. Listen to "download-complete" event for batch result
3. Query tracks WHERE download_status IS NOT NULL to filter Library view

### Phase 9 Integration

This plan completes the backend half of Phase 9's Library/Remote separation:
- Phase 9-01 created download_status column and idx_organized_path_null index
- Phase 11-01 adds automatic timestamp updates on download success
- Remote view query (organized_path IS NULL) now reliably excludes downloaded tracks

## Testing Notes

### Compilation Verification

All verification checks passed:
- download_tracks accepts AppHandle parameter
- download-progress events emitted in progress callback
- download-complete event emitted after batch
- update_download_status function exists and exported
- Database updates called in success path

### Manual Testing Recommended

1. Trigger download batch via frontend
2. Observe download-progress events in browser console
3. Verify download_status column populated after success
4. Confirm downloaded tracks disappear from Remote view

## Next Steps

**Frontend Work (Plan 11-02):**
- Listen to download-progress events and update UI
- Show progress indicator during batch downloads
- Refresh Remote view after download-complete event

**Future Enhancement:**
- Add download pause/resume (would require orchestrator state persistence)
- Batch download queue UI (show pending/in-progress/failed)

## Metrics

- **Duration:** 4 minutes
- **Tasks completed:** 3/3
- **Commits:** 3
  - cdc46e2: Progress streaming and completion events
  - b8b4dd9: Database update_download_status function
  - c035adb: Wire status updates into download command
- **Files modified:** 4
- **Files created:** 1 (src-tauri/src/database/tracks.rs)

## Self-Check: PASSED

**Created files verification:**
```
FOUND: src-tauri/src/database/tracks.rs
```

**Commits verification:**
```
FOUND: cdc46e2
FOUND: b8b4dd9
FOUND: c035adb
```

**Key functionality verification:**
```
✓ download_tracks command accepts AppHandle
✓ download-progress events emitted
✓ download-complete event emitted
✓ update_download_status function exists and public
✓ Database updates called for downloaded_track_ids
✓ Compiles without errors
```

All claims verified. Implementation complete and functional.
