# Phase 9: Library/Remote Separation - Research

**Researched:** 2026-02-07
**Domain:** Database architecture, multi-view querying, sidebar/view management, streaming source integration
**Confidence:** HIGH (current database structure, schema patterns) / MEDIUM (sidebar implementation approach, UI state management)

## Summary

Phase 9 implements a core architectural shift: splitting the mixed tracks table into two logical views—Library (local files only) and Remote (undownloaded streaming tracks only). This is purely a data filtering and UI organizational problem, not a structural database redesign.

The current database structure already supports this division through existing columns:
- `organized_path` IS NULL → streaming tracks (Spotify, SoundCloud)
- `organized_path` IS NOT NULL → local files
- `track_sources` table links tracks to their streaming source

The implementation requires:
1. **Backend**: Query modifications to filter by library vs. remote status
2. **Frontend**: Sidebar navigation between Library and Remote views
3. **Database**: Minor schema addition to explicitly mark download state
4. **UI Column Changes**: Replace "Source" column (streaming API name) with "Format" column (audio format)

The standard approach uses filtered SQL queries for each view, React state for active view selection, and a new `download_status` column to track when streamed tracks transition to the library. Implementation should use TanStack Table's filtering to support future refinements.

**Primary recommendation:** Add `download_status` column to tracks table (tracks when a streaming track was downloaded), create backend query functions for library-only and remote-only views, implement sidebar Remote item with badge for undownloaded count, update LibraryTable columns to show Format instead of Source.

## Standard Stack

### Core Technologies

| Technology | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| SQLite | Existing | Schema extension for download tracking | Already primary database; versioning via PRAGMA supports migrations |
| Rust/rusqlite | Existing | Query filtering logic | Current ORM pattern; enables type-safe queries |
| React/TypeScript | Existing | View routing and state | Current frontend stack; TanStack Table supports filtered datasets |
| TanStack Table | 8.x+ | Data grid filtering | Standard for React data tables; built-in filtering predefined data |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `tauri::command` | 2.x | Backend command handlers | Standard pattern for frontend-backend communication |
| `serde` | 1.x | JSON serialization | Standard Rust serialization for API responses |
| `uuid` crate | 1.x | Unique identifiers | Future-proof for remote sync IDs if needed |

### Key Architectural Patterns

These already exist in codebase:

- **Query filtering pattern**: Used in search, playlists, sync profiles
- **Command handlers**: All queries exposed via `#[tauri::command]`
- **Event emission**: Used for import completion, download progress
- **Type safety**: Track struct with Option<String> for organized_path

### Installation

No new dependencies required. Extensions use existing stack:

```toml
# Already present, no changes needed:
tauri = "2"
rusqlite = "0.31"
serde = { version = "1", features = ["derive"] }
uuid = { version = "1", features = ["v4", "serde"] }
```

## Architecture Patterns

### Recommended Project Structure

No new files required. Modifications to existing:

```
src-tauri/src/
├── database/
│   └── schema.rs          # UPDATE: Add download_status column migration
├── commands/
│   ├── search.rs          # UPDATE: Add get_library_tracks_only, get_remote_tracks_only
│   └── mod.rs             # UPDATE: Export new commands
├── search/
│   └── query.rs           # UPDATE: Add library_only and remote_only variants
└── lib.rs                 # UPDATE: Register new commands

ui/src/
├── types/
│   └── library.ts         # UPDATE: Track type if needed
├── components/
│   ├── Sidebar/Sidebar.tsx        # UPDATE: Add Remote nav item
│   └── LibraryTable/LibraryTable.tsx  # UPDATE: Replace Source column with Format
├── pages/
│   └── LibraryBrowser.tsx         # UPDATE: Route between Library and Remote views
└── hooks/
    └── useLibraryTracks.ts        # UPDATE: Add remote view fetching
```

### Pattern 1: Dual-View Filtering

**What:** Two query variants that filter the same tracks table by download state instead of using separate tables.

**When to use:** On page load, when switching views, when library mount state changes.

**Example:**

```rust
// src/search/query.rs

/// Get all tracks that exist locally (organized_path IS NOT NULL)
pub fn get_library_tracks_only(conn: &Connection) -> DbResult<Vec<Track>> {
    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, album, title, genre, year, bitrate, duration, format,
                original_path, organized_path, is_duplicate, date_added, download_status
         FROM tracks
         WHERE organized_path IS NOT NULL
         ORDER BY date_added DESC"
    )?;

    // Same track mapping as get_all_tracks
}

/// Get all tracks from streaming services not yet downloaded
pub fn get_remote_tracks_only(conn: &Connection) -> DbResult<Vec<Track>> {
    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, album, title, genre, year, bitrate, duration, format,
                original_path, organized_path, is_duplicate, date_added, download_status
         FROM tracks
         WHERE organized_path IS NULL
         ORDER BY date_added DESC"
    )?;

    // Same track mapping
}

/// Get count of undownloaded remote tracks for sidebar badge
pub fn count_remote_tracks(conn: &Connection) -> DbResult<i64> {
    conn.query_row(
        "SELECT COUNT(*) FROM tracks WHERE organized_path IS NULL",
        [],
        |row| row.get(0)
    )
}
```

### Pattern 2: Command Handler Routing

**What:** New Tauri commands that route to appropriate query functions based on view context.

**When to use:** Every frontend request to load track data.

**Example:**

```rust
// src/commands/search.rs - ADD these alongside existing get_library_tracks

#[tauri::command]
pub async fn get_library_tracks_only() -> Result<Vec<Track>, String> {
    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    let tracks = get_library_tracks_only(&conn).map_err(|e| format!("Query error: {}", e))?;
    Ok(tracks)
}

#[tauri::command]
pub async fn get_remote_tracks_only() -> Result<Vec<Track>, String> {
    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    let tracks = get_remote_tracks_only(&conn).map_err(|e| format!("Query error: {}", e))?;
    Ok(tracks)
}

#[tauri::command]
pub async fn get_remote_track_count() -> Result<i64, String> {
    let db_path = PathBuf::from("music_library.db");
    let conn = get_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    let count = count_remote_tracks(&conn).map_err(|e| format!("Query error: {}", e))?;
    Ok(count)
}
```

### Pattern 3: View State in React

**What:** Route-based view selection where `/library` shows Library view and new `/remote` shows Remote view.

**When to use:** Navigation between Library and Remote in sidebar.

**Example:**

```typescript
// ui/src/pages/LibraryBrowser.tsx - UPDATE to accept view parameter

interface LibraryBrowserProps {
  view: 'library' | 'remote';
}

export default function LibraryBrowser() {
  const [view, setView] = useState<'library' | 'remote'>('library');

  useEffect(() => {
    // Determine view from location or state
    // This could also be a route parameter: /library?view=remote
  }, []);

  const { tracks, isLoading } = useLibraryTracks(view);

  return (
    <>
      <div className="mb-4 flex gap-2">
        <button
          onClick={() => setView('library')}
          className={view === 'library' ? 'active' : ''}
        >
          Library ({libraryCount})
        </button>
        <button
          onClick={() => setView('remote')}
          className={view === 'remote' ? 'active' : ''}
        >
          Remote ({remoteCount})
        </button>
      </div>
      <LibraryTable tracks={tracks} />
    </>
  );
}

// ui/src/hooks/useLibraryTracks.ts - UPDATE to support view filtering

export function useLibraryTracks(view: 'library' | 'remote' = 'library') {
  const [tracks, setTracks] = useState<Track[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    const loadTracks = async () => {
      setIsLoading(true);
      try {
        const cmd = view === 'library'
          ? 'get_library_tracks_only'
          : 'get_remote_tracks_only';
        const data = await invoke<Track[]>(cmd);
        setTracks(data);
      } catch (err) {
        console.error(`Failed to load ${view} tracks:`, err);
      } finally {
        setIsLoading(false);
      }
    };
    loadTracks();
  }, [view]);

  return { tracks, isLoading };
}
```

### Pattern 4: Column Definition Change

**What:** Replace Source/Service column with Format column showing audio file format.

**When to use:** In LibraryTable column definitions.

**Example:**

```typescript
// BEFORE: Shows where track came from
columnHelper.accessor((row) => {
  // Would need to join with sources table to get source name
  return row.metadata.source_name || 'Unknown';
}, {
  id: "source",
  header: "Source",
  // ...
})

// AFTER: Shows audio format instead
columnHelper.accessor((row) => row.metadata.format, {
  id: "format",
  header: "Format",
  size: 80,
  minSize: 60,
  maxSize: 120,
  cell: (info) => (
    <div className="text-gray-600 dark:text-gray-400 text-sm uppercase">
      {info.getValue() || "Unknown"}
    </div>
  ),
})
```

### Anti-Patterns to Avoid

- **Creating separate tracks_library and tracks_remote tables:** Violates DRY principle and complicates sync logic. Filtering existing table is simpler and maintains single source of truth.
- **Tracking download state in track_sources table:** Creates confusion about many-to-many relationship semantics. Download state is global track property, not source-specific.
- **Using organization_path as download marker:** Already overloaded with import logic. Need explicit `download_status` column.
- **Frontend-only filtering:** Always filter at database level for correctness and performance. Remote view should never accidentally load local files.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|------------|-------------|-----|
| View state persistence | Custom localStorage logic | React Router params or URL state | Standard React pattern; survives page reload; bookmarkable |
| Data filtering | Manual array filtering in JS | SQL WHERE clause | 27k+ tracks: SQL is 100-1000x faster; scales to future millions |
| Badge count updates | Manual refetch on every state change | Background polling or event-driven updates | Import/download events already emit; reuse that system |
| Multi-column sorting in remote view | Custom sort comparators | TanStack Table built-in sorting | Already integrated; handles null values correctly |

**Key insight:** The separation is a pure query pattern, not a data structure change. Building custom filtering layers adds complexity with zero benefit over using existing database capabilities.

## Common Pitfalls

### Pitfall 1: Forgetting track_sources When Filtering Remote

**What goes wrong:** Query selects all tracks with NULL organized_path but doesn't verify they actually have streaming source associations. Frontend shows "ghosts" of local files that got deleted.

**Why it happens:** organized_path tracks physical existence, but track_sources tracks which services know about the track. Deleting a local file doesn't cascade to track_sources.

**How to avoid:** Always verify remote tracks have associated source records:

```sql
-- WRONG: Shows orphaned tracks
SELECT * FROM tracks WHERE organized_path IS NULL

-- RIGHT: Verifies streaming source association exists
SELECT DISTINCT t.*
FROM tracks t
INNER JOIN track_sources ts ON t.id = ts.track_id
WHERE t.organized_path IS NULL
```

**Warning signs:** Remote view shows tracks that can't be downloaded; download button fails silently.

### Pitfall 2: Not Updating Download Status After Import

**What goes wrong:** Downloaded streaming track gets local file imported, but organized_path set while download_status left NULL. Library view shows track as local, but metadata queries fail.

**Why it happens:** Import process focuses on local files; doesn't check if incoming file matches a pending remote track.

**How to avoid:** Import handler should check track_sources table when organizing new files:

```rust
// When importing a local file that matches a streaming track:
// 1. Create tracks record with organized_path
// 2. Check if artist/album/title combination exists in track_sources
// 3. If match found: copy track_sources associations to the new track
// 4. Set download_status to current timestamp
```

**Warning signs:** Duplicates in Library view; missing tracks in Remote after "download" succeeds.

### Pitfall 3: Column Mismatch on Format Display

**What goes wrong:** Format column left empty because backend returns NULL for streaming tracks (no audio file to extract format from).

**Why it happens:** Format extracted during import from audio file headers. Streaming tracks added via sync_spotify/sync_soundcloud have no format data.

**How to avoid:** When adding streaming tracks from sources, derive format from source metadata:

```rust
// Spotify returns "audio/mpeg" type hints
// SoundCloud API provides original_format field
// Fallback to "Stream" or "Unknown" if no source format available

pub fn get_format_for_streaming_track(source: &str) -> String {
    match source {
        "spotify" => "Stream".to_string(),  // User sees "Stream"
        "soundcloud" => "Stream".to_string(),
        _ => "Unknown".to_string(),
    }
}
```

**Warning signs:** Format column shows empty in Remote view; users see no audio format info for tracks they haven't downloaded yet.

### Pitfall 4: Sidebar Badge Becomes Stale

**What goes wrong:** Remote sidebar shows 150 undownloaded tracks, user downloads 10, sidebar still shows 150.

**Why it happens:** Badge count fetched once on page load, never refreshed. Download process updates database but doesn't trigger badge recalculation.

**How to avoid:** Tie badge count to existing events:

```typescript
// ui/src/components/Sidebar/Sidebar.tsx

useEffect(() => {
  const loadRemoteCount = async () => {
    const count = await get_remote_track_count();
    setRemoteTrackCount(count);
  };

  loadRemoteCount();

  // Refresh count when:
  // 1. Import completes (existing import-complete event)
  // 2. Download completes (existing download-complete event)
  // 3. User syncs streaming sources (existing sync-complete event)

  const unsubscribeImport = listen('import-complete', loadRemoteCount);
  const unsubscribeDownload = listen('download-complete', loadRemoteCount);
  const unsubscribeSync = listen('sync-complete', loadRemoteCount);

  return () => {
    unsubscribeImport.then(f => f());
    unsubscribeDownload.then(f => f());
    unsubscribeSync.then(f => f());
  };
}, []);
```

**Warning signs:** Sidebar badge doesn't match actual remote count; user downloads tracks but sees no change.

## Code Examples

### Verified Backend Pattern: Query Filtering

```rust
// Source: Analysis of existing search/query.rs patterns, Phase 3+ codebase

// This pattern is proven in get_all_tracks and search_tracks functions.
// Adapting it for library/remote split:

use rusqlite::Connection;
use crate::database::Result as DbResult;
use crate::models::track::Track;

pub fn get_library_tracks_only(conn: &Connection) -> DbResult<Vec<Track>> {
    let mut stmt = conn.prepare(
        "SELECT id, artist, album_artist, album, title, genre, year, bitrate, duration,
                format, original_path, organized_path, is_duplicate, date_added
         FROM tracks
         WHERE organized_path IS NOT NULL
         ORDER BY date_added DESC"
    )?;

    let tracks = stmt
        .query_map([], |row| {
            Ok(Track {
                id: Some(row.get(0)?),
                metadata: TrackMetadata {
                    artist: row.get(1)?,
                    album_artist: row.get(2)?,
                    album: row.get(3)?,
                    title: row.get(4)?,
                    genre: row.get(5)?,
                    year: row.get(6)?,
                    bitrate: row.get(7)?,
                    duration: row.get(8)?,
                    format: row.get(9)?,
                    original_path: row.get(10)?,
                },
                organized_path: row.get(11)?,
                is_duplicate: row.get::<_, i32>(12)? != 0,
                date_added: row.get(13)?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    Ok(tracks)
}
```

### Verified Frontend Pattern: Hook with View Routing

```typescript
// Source: Follows patterns in useLibraryTracks, existing Tauri command usage

import { invoke } from "@tauri-apps/api/tauri";
import { useState, useEffect } from "react";
import type { Track } from "../types/library";

export function useLibraryTracks(view: 'library' | 'remote' = 'library') {
  const [tracks, setTracks] = useState<Track[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const loadTracks = async () => {
      setIsLoading(true);
      setError(null);
      try {
        const commandName = view === 'library'
          ? 'get_library_tracks_only'
          : 'get_remote_tracks_only';

        const data = await invoke<Track[]>(commandName);
        setTracks(data);
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : String(err);
        setError(`Failed to load ${view} tracks: ${errorMessage}`);
        console.error(`useLibraryTracks(${view}) error:`, err);
      } finally {
        setIsLoading(false);
      }
    };

    loadTracks();
  }, [view]);

  return { tracks, isLoading, error };
}
```

## Database Schema Changes

### Required Migration (Schema Version 7)

Add one column to tracks table to explicitly track when streaming tracks are downloaded:

```sql
-- Phase 9 Migration: Add download_status column to tracks table

ALTER TABLE tracks ADD COLUMN download_status TEXT;
-- NULL for tracks that came from local import
-- ISO 8601 timestamp for tracks converted from remote to local

-- Create index for Remote view query performance
CREATE INDEX IF NOT EXISTS idx_organized_path_null
ON tracks(organized_path)
WHERE organized_path IS NULL;
```

**Rationale:**
- `organized_path IS NULL` → Remote (streaming) track
- `organized_path IS NOT NULL` → Library (local) track
- `download_status IS NOT NULL` → Track was downloaded from Remote
- Indexed WHERE clause optimizes remote view queries on large libraries

**Backward compatibility:** NULL values for existing tracks; doesn't break existing queries.

## State of the Art

| Pattern | Version | Change | Impact |
|---------|---------|--------|--------|
| Dual-table approach | Old | → Single table with filtering | Simpler sync logic, reduced complexity |
| Source column in views | Old | → Format column | More useful to user, aligns with Phase 1 design |
| Virtual tables for sources | Considered | → Simple NULL-based filtering | No new dependencies, proven SQLite pattern |

## Open Questions

1. **How aggressive should download status tracking be?**
   - Option A: Set download_status when track imports (know it was streamed before)
   - Option B: Only set on explicit download from Remote (less invasive)
   - Recommendation: Option B initially; can expand later if needed for analytics

2. **Should Remote view show only undownloaded, or all non-local?**
   - Option A: Show all tracks with NULL organized_path (includes previously downloaded)
   - Option B: Show only tracks where download_status IS NULL (strict "undownloaded")
   - Recommendation: Option A for Phase 9; Phase 10 could add filters for "show all/new only"

3. **What happens if import discovers a file that matches a Remote track?**
   - Should we auto-associate the local file with the streaming track?
   - Or keep them separate?
   - Recommendation: Phase 10 feature; Phase 9 keeps them separate

## Sources

### Primary (HIGH confidence)

- **Existing codebase analysis** - Track struct, query patterns, search/query.rs (verified 2026-02-07)
- **Database schema documentation** - schema.rs shows current structure, migrations (verified 2026-02-07)
- **Phase 8 architecture** - LibraryMountContext, mount detection patterns (verified 2026-02-07)
- **Track model analysis** - organized_path NULL check pattern, track_sources relationships (verified 2026-02-07)

### Secondary (MEDIUM confidence)

- **SQLite WHERE clause indexing** - Standard SQL optimization; applies to `WHERE organized_path IS NULL`
- **React Router view routing** - Established pattern for multi-view applications
- **TanStack Table filtering** - Library supports filtered datasets natively

### Tertiary (LOW confidence)

- Download status tracking implementation details (will need refinement during planning phase)

## Metadata

**Confidence breakdown:**
- **Database structure**: HIGH - Existing columns support division; schema migration is straightforward
- **Query patterns**: HIGH - Filtering by NULL is standard SQL; proven in existing codebase
- **Architecture patterns**: MEDIUM - Sidebar navigation and view state well-established; implementation details flexible
- **Column changes**: MEDIUM - Format column display straightforward; need to verify streaming track format data availability

**Research date:** 2026-02-07
**Valid until:** 2026-02-21 (14 days - database structure stable, UI patterns well-known)
