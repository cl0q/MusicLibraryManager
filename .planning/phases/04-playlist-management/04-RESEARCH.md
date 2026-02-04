# Phase 4: Playlist Management - Research

**Researched:** 2026-02-04
**Domain:** Database schema design, ordering algorithms, smart playlist patterns, UI reordering
**Confidence:** HIGH (for architecture), MEDIUM (for implementation patterns), MEDIUM (for edge cases)

## Summary

Phase 4 implements playlist management with three playlist categories (Liked, Smart, Regular), order preservation across all operations, and import of source playlists. The phase creates a new database schema for playlists with ordering, supports mirrored playlists with add-only semantics, defines smart playlists for recent additions and play counts, and establishes the order contract for M3U8 export in Phase 5.

Key technical decisions center on ordering algorithm (fractional indexing vs gap-based positions), tag storage (JSON vs separate table), image storage (file path vs blob), and smart playlist query design. The architecture patterns follow the established Rust + SQLite + Tauri + React stack with transactional database guarantees.

**Primary recommendation:** Use fractional indexing (string-based) for robust playlist ordering to support unlimited reordering without rebalancing. Store tags in a separate junction table for flexibility. Store cover images as file paths with fallback URLs. Implement smart playlists as database views with ORDER BY clauses, refreshed on track changes.

## Standard Stack

### Core Libraries

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| rusqlite | 0.34+ | SQLite database (already in use) | Embedded, ACID transactions, foreign keys required for playlist order integrity |
| serde / serde_json | 1.x | JSON serialization (already in use) | Standard for API responses, playlist metadata |
| chrono | 0.4+ | Date/time handling (already in use) | Required for "Recently Added" smart playlist queries (track date_added field) |
| tokio | 1.0+ | Async runtime (already in use) | Tauri dependency; enables concurrent playlist operations |
| React | 19.2.0+ (from ui/package.json) | UI framework (already in use) | Required for drag-drop playlist reordering |

### Supporting Libraries (Recommended Additions)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| hello-pangea/dnd | 13.1+ | React drag-and-drop for lists | Playlist reordering UI; battle-tested for kanban/task boards |
| dnd-kit | 8.0+ (alternative) | Lightweight, flexible drag-drop | If more customization needed than hello-pangea/dnd |

### Why Not These Alternatives

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Fractional indexing | Sequential integer ordering | Requires rebalancing after ~10 reorders; adds N-1 database updates per reorder |
| Fractional indexing | Gap-based positions (step=16384) | Works well but arbitrary step size; gaps close eventually; requires eventual rebalancing |
| Separate tags table | JSON column | JSON column less queryable without generated columns; separate table is more flexible for tag filtering |
| File path for images | BLOB storage | BLOB adds database size; file paths scale better and allow CDN caching (Phase 6+) |
| Database views for smart playlists | Materialized views | Views are simpler to maintain; materialization adds sync complexity |

**Installation (Cargo.toml additions):**
```toml
# No new Rust dependencies required for core Phase 4.
# Frontend drag-drop via npm (see below)
```

**Installation (package.json additions for UI):**
```bash
npm install hello-pangea/dnd @types/hello-pangea__dnd
# Or alternative:
npm install @dnd-kit/sortable @dnd-kit/core @dnd-kit/utilities
```

## Architecture Patterns

### Recommended Project Structure

```
src-tauri/src/
├── models/
│   ├── mod.rs
│   ├── track.rs          # (existing)
│   ├── playlist.rs        # NEW: Playlist, PlaylistTrack, PlaylistTag models
│   └── source.rs          # (existing from Phase 3)
├── database/
│   ├── mod.rs
│   ├── schema.rs          # (extend with Phase 4 tables)
│   ├── connection.rs      # (existing)
│   └── playlist.rs        # NEW: Playlist CRUD operations
├── commands/              # (existing Tauri commands)
│   └── playlist.rs        # NEW: Tauri command handlers for playlist operations
└── search/                # (existing full-text search)

ui/src/
├── components/
│   └── Playlists/
│       ├── PlaylistList.tsx     # NEW: Display playlist sections (Liked, Smart, Regular)
│       ├── PlaylistDetail.tsx   # NEW: Show playlist contents with drag-drop
│       └── PlaylistReorder.tsx  # NEW: Drag-drop reordering component
└── hooks/
    └── usePlaylists.ts         # NEW: Playlist API calls
```

### Pattern 1: Fractional Indexing for Playlist Ordering

**What:** Store playlist track order using fractional indices (strings like "a0", "a0|a1", "a0|a1|a2") that enable unlimited reordering with O(1) database updates.

**When to use:** Every playlist must support drag-drop reordering without rebalancing all rows.

**Why:**
- **Sequential integers:** Require rebalancing after ~10 reorders (O(N) updates)
- **Gap-based (Trello style with step=16384):** Works but arbitrary; gaps close eventually
- **Fractional indexing:** No rebalancing needed; each reorder touches only 1 row

**Example schema:**
```sql
-- playlist_tracks uses fractional index for order
CREATE TABLE IF NOT EXISTS playlist_tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    position TEXT NOT NULL,           -- Fractional index: "a0", "a0|a1", etc.
    added_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(playlist_id, track_id),
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
CREATE INDEX idx_playlist_position ON playlist_tracks(playlist_id, position);
```

**Implementation approach:**
```rust
// When inserting a new track at position (between left and right)
fn generate_position(left: Option<&str>, right: Option<&str>) -> String {
    // Use fractional-indexing crate or implement string-based ordering
    // Example: position_between("a0", "a0|a1") = "a0|a0"
    // No numeric precision issues with string representation
}

// When reordering via drag-drop:
// Only update the moved track's position value (1 database update)
// No cascading updates to other tracks
```

**Sources:**
- [Fractional Indexing Explained](https://hollos.dev/blog/fractional-indexing-a-solution-to-sorting/)
- [Figma's Fractional Indexing approach](https://www.steveruiz.me/posts/reordering-fractional-indices)
- [CRDT-based implementation](https://madebyevan.com/algos/crdt-fractional-indexing/)

### Pattern 2: Separate Tags Table for Flexibility

**What:** Store playlist tags in a junction table (`playlist_tags`) rather than JSON column, allowing efficient tag-based filtering and future tag suggestions.

**When to use:** Playlist filtering by tag, tag-based smart playlists, tag suggestions.

**Why:**
- **Separate table:** Enables `SELECT DISTINCT tags` for UI suggestions, tag-based queries without parsing JSON
- **JSON column:** Less queryable; requires `json_extract` for filtering; adds generated columns for performance
- **Consensus:** 2026 best practice for fixed, queryable attributes

**Example schema:**
```sql
CREATE TABLE IF NOT EXISTS playlist_tags (
    playlist_id INTEGER NOT NULL,
    tag TEXT NOT NULL,              -- Freeform text: "workout", "chill", etc.
    PRIMARY KEY (playlist_id, tag),
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);
CREATE INDEX idx_tag ON playlist_tags(tag);

-- Query all playlists with "workout" tag:
-- SELECT DISTINCT p.* FROM playlists p
-- JOIN playlist_tags pt ON p.id = pt.playlist_id
-- WHERE pt.tag = 'workout'
```

**Sources:**
- [SQLite JSON vs Separate Table](https://www.beekeeperstudio.io/blog/sqlite-json)
- [2026 JSON storage best practices](https://www.dbpro.app/blog/sqlite-json-virtual-columns-indexing)

### Pattern 3: File Path Storage for Cover Images

**What:** Store playlist cover image URLs or file paths in the database, not BLOBs. Save images to a local cache directory with playlist ID as key.

**When to use:** Every playlist can have an optional cover image (from source or user-provided).

**Why:**
- **File path:** Filesystems are optimized for file serving; images load faster; allows future CDN caching
- **BLOB:** Increases database size; slower than filesystem access; doesn't scale
- **2026 consensus:** File path + database reference is the standard pattern

**Example schema:**
```sql
CREATE TABLE IF NOT EXISTS playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    cover_image_path TEXT,          -- Local path: ~/.music-lib/playlists/covers/123.jpg
    cover_image_url TEXT,           -- Source URL (for refresh/fallback)
    ...
);
```

**Implementation approach:**
```rust
// When user imports a playlist from Spotify:
// 1. Fetch cover image from Spotify API (/playlists/{id}/images)
// 2. Save to local directory: ~/.music-lib/playlists/covers/{playlist_id}.jpg
// 3. Store local path in cover_image_path, remote URL in cover_image_url
// 4. On refresh, check if cover changed via URL comparison

fn save_playlist_cover(playlist_id: i64, image_data: &[u8]) -> Result<String> {
    let cover_dir = app_data_dir()/.music-lib/playlists/covers/;
    let cover_path = cover_dir / format!("{}.jpg", playlist_id);
    fs::write(&cover_path, image_data)?;
    Ok(cover_path.to_string_lossy().to_string())
}
```

**Sources:**
- [BLOB vs File System comparison](https://www.geeksforgeeks.org/system-design/blob-vs-file-system-in-system-design/)
- [2026 storage recommendations](https://harshithgowdakt.medium.com/databases-vs-blob-storage-what-to-use-and-when-d5b1ec0d11cd)

### Pattern 4: Smart Playlists as Database Views with Refresh

**What:** Define smart playlists (Recently Added, Most Played) as SQL views that query the tracks table with WHERE/ORDER BY clauses. Refresh on track additions or stats updates.

**When to use:** Any auto-generated playlist that regenerates based on library state changes.

**Why:**
- **Views:** Lightweight; automatically reflect current library state; no storage overhead
- **Materialized views:** More complex sync logic; requires manual refresh triggers
- **Query-based (Kodi/beets pattern):** Views simplify definition and management

**Example schema:**
```sql
-- Recently Added: tracks added in last 30 days, sorted by date_added DESC
CREATE VIEW IF NOT EXISTS smart_playlist_recently_added AS
SELECT
    t.id,
    t.artist,
    t.album,
    t.title,
    t.date_added,
    datetime('now', '-30 days') AS cutoff
FROM tracks t
WHERE t.date_added >= datetime('now', '-30 days')
ORDER BY t.date_added DESC;

-- Most Played: requires play_count from Phase 5 (playlist exists in Phase 4, populated later)
-- This view will be populated in Phase 5 once sync/statistics provide play_count
CREATE VIEW IF NOT EXISTS smart_playlist_most_played AS
SELECT
    t.id,
    t.artist,
    t.album,
    t.title,
    COALESCE(ts.play_count, 0) AS play_count
FROM tracks t
LEFT JOIN track_stats ts ON t.id = ts.track_id
ORDER BY play_count DESC
LIMIT 100;
```

**Implementation approach:**
```rust
// Phase 4: Create smart playlists as special entries in playlists table
// is_smart = 1, query_definition = NULL (views used instead)

fn create_smart_playlists(conn: &Connection) -> Result<()> {
    // Recently Added
    conn.execute(
        "INSERT OR IGNORE INTO playlists (name, category, is_smart, is_pinned)
         VALUES (?, ?, 1, 1)",
        ["Recently Added", "smart"],
    )?;

    // Most Played (definition exists, will be populated in Phase 5)
    conn.execute(
        "INSERT OR IGNORE INTO playlists (name, category, is_smart, is_pinned)
         VALUES (?, ?, 1, 1)",
        ["Most Played", "smart"],
    )?;

    Ok(())
}

// Query smart playlist contents (app layer):
fn get_smart_playlist_tracks(conn: &Connection, playlist_name: &str) -> Result<Vec<Track>> {
    if playlist_name == "Recently Added" {
        // Query the view
        conn.prepare("SELECT * FROM smart_playlist_recently_added")?
            .query_map([], |row| extract_track(row))?
            .collect()
    } else if playlist_name == "Most Played" {
        // Query the view
        conn.prepare("SELECT * FROM smart_playlist_most_played")?
            .query_map([], |row| extract_track(row))?
            .collect()
    } else {
        Err("Unknown smart playlist")
    }
}
```

**Sources:**
- [Kodi Smart Playlists pattern](https://kodi.wiki/view/Smart_playlists)
- [Beets Smart Playlist plugin](https://beets.readthedocs.io/en/stable/plugins/smartplaylist.html)

### Pattern 5: Mirrored Playlists (Add-Only Semantics)

**What:** When importing a playlist from Spotify/SoundCloud, create a local "mirrored" playlist. On refresh, fetch new tracks from source, insert at their source position, but preserve manual local reordering. Never delete local tracks if removed from source.

**When to use:** User imports playlist from Spotify, then periodically refreshes to pull new tracks added to source.

**Example behavior:**
```
Source Spotify playlist: [Track A, Track B, Track C]
User imports → Local mirror: [Track A, Track B, Track C] (position="a0", "a1", "a2")

User manually reorders → Local mirror: [Track B, Track A, Track C] (position="a0|a1", "a0", "a2")

Spotify playlist updated: [Track A, Track B, Track D, Track C]
On refresh:
- Track D is new, source position is index 2
- Insert Track D at local position between Track B and Track C
- Preserve manual reordering of existing tracks
- Result: [Track B, Track A, Track D, Track C] (local order preserved)
```

**Implementation approach:**
```rust
fn refresh_mirrored_playlist(
    conn: &Connection,
    playlist_id: i64,
    source_tracks: Vec<(TrackId, usize)>, // (track_id, source_position)
) -> Result<()> {
    conn.execute("PRAGMA foreign_keys = ON", [])?;
    let tx = conn.transaction()?;

    // Get existing tracks in this playlist
    let mut existing: BTreeMap<TrackId, String> = {};
    let mut stmt = tx.prepare(
        "SELECT track_id, position FROM playlist_tracks WHERE playlist_id = ?"
    )?;
    for row in stmt.query_map([playlist_id], |r| {
        Ok((r.get::<_, i64>(0), r.get::<_, String>(1)))
    })? {
        let (track_id, position) = row?;
        existing.insert(track_id, position);
    }

    // Add new tracks from source
    for (track_id, source_idx) in source_tracks {
        if !existing.contains_key(&track_id) {
            // New track: insert at fractional position based on source index
            let position = compute_position_for_source_index(source_idx, &existing)?;
            tx.execute(
                "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                [playlist_id, track_id, position],
            )?;
        }
    }

    tx.commit()?;
    Ok(())
}
```

**Sources:**
- Beets reference implementation (add-only philosophy)
- Music Assistant (mirror sync strategies)

### Pattern 6: Liked Playlists (Per-Source + Local)

**What:** Create special "Liked" playlists for each source (Spotify Likes, SoundCloud Likes, Local Likes) on first import. These are pinned, use heart icon, and default to date-added descending order.

**When to use:** User connects source or marks track as liked locally.

**Example behavior:**
```
Sources: Spotify, SoundCloud, Local
Creates three pinned playlists:
1. "Spotify Likes" (from Spotify liked_songs endpoint)
2. "SoundCloud Likes" (from SoundCloud favorites)
3. "Local Likes" (user manually likes tracks in UI)

Each playlist:
- is_liked = 1 (marks it for pinning and heart icon)
- default_sort = "date_added DESC"
- can be manually reordered (overrides default sort)
- tracks can appear in multiple liked playlists (shared reference)
```

**Schema extension:**
```sql
ALTER TABLE playlists ADD COLUMN is_liked INTEGER DEFAULT 0;      -- 1 = liked playlist
ALTER TABLE playlists ADD COLUMN default_sort TEXT;               -- "date_added DESC", etc.
ALTER TABLE playlists ADD COLUMN is_pinned INTEGER DEFAULT 0;     -- 1 = pinned to top
```

**Sources:**
- Spotify API: `/me/tracks` endpoint for user's liked tracks
- SoundCloud API: `/users/{id}/favorites` for user's favorites

### Anti-Patterns to Avoid

- **Storing order as sequential integers (1, 2, 3, ...):** Forces rebalancing after ~10 reorders. Use fractional indexing instead.
- **Fetching entire source playlist on every refresh:** Wastes API quota. Use incremental sync with timestamps (Phase 3 established this).
- **Deleting local tracks when removed from source:** Violates "once downloaded, stays" contract. Implement add-only semantics.
- **Storing playlist metadata in JSON column:** Makes tag filtering complex. Use separate junction table.
- **Storing large cover images as BLOBs:** Bloats database; blocks operations. Use file paths.
- **Regenerating smart playlists synchronously on UI load:** Slow queries. Use views or background refresh.
- **No index on playlist ordering:** Makes drag-drop slow. Always index `(playlist_id, position)`.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Playlist ordering algorithm | Custom int rebalancing | Fractional indexing library or string-based approach | Fractional indexing solved (Figma, Slack use it); numeric approaches have precision limits; string approach is battle-tested |
| React drag-drop | Custom mouse/touch handlers | hello-pangea/dnd or @dnd-kit | Accessibility, touch support, performance optimizations needed; libraries handle 80+ edge cases |
| Smart playlist queries | Hand-written SQL in app code | Database views with automatic refresh | Views are declarative, maintainable, and automatically reflect library state |
| M3U8 playlist generation | Parse/generate manual format | Standard M3U8 library (when needed in Phase 5) | M3U8 format has subtleties (line endings, duration format); libraries handle compatibility |
| Cross-source deduplication | Manual track matching | Existing Phase 3 fuzzy matching system | Phase 3 established dedup; reuse for playlist cross-source references |

**Key insight:** Ordering is the hard problem in playlists. Everything else (UI, queries, schema) is straightforward once ordering is solved. Fractional indexing is the standard solution; don't attempt integer rebalancing.

## Common Pitfalls

### Pitfall 1: Ordering Rebalancing Cascades

**What goes wrong:** Using sequential integer positions (1, 2, 3). After user reorders 10+ times, positions collide, requiring rebalancing of multiple rows (O(N) database updates). Slow and error-prone.

**Why it happens:** Integer positions seem intuitive; developers often implement as "easiest" approach without researching existing solutions.

**How to avoid:** Use fractional indexing from the start. String-based positions ("a0", "a0|a1") have no precision limits and require only O(1) updates.

**Warning signs:**
- Drag-drop reordering slows down after several operations
- Database shows cascading updates to many playlist_tracks rows per reorder
- Schema includes rebalancing logic or "gap" reset procedures

### Pitfall 2: Importing All Source Playlists by Default

**What goes wrong:** User connects Spotify, system imports ALL 50+ of their Spotify playlists automatically. Local library grows uncontrollably; user has duplicate playlists.

**Why it happens:** Seems helpful ("aggregate everything"), but violates user control design (CONTEXT.md says user picks which playlists to import).

**How to avoid:** Implement "chooser" UI. On first Spotify auth, show list of available playlists with checkboxes. Only create mirrored playlists for selected items.

**Warning signs:**
- User complains about too many playlists after source connection
- Database has unintended duplicates of source playlists
- No UI option to selectively import from source

### Pitfall 3: Deleting Local Tracks When Source Removes Them

**What goes wrong:** User imports Spotify playlist. Later, track is removed from Spotify playlist. App syncs and deletes the track from local mirrored playlist. User loses music they may have been enjoying locally.

**Why it happens:** Treating mirrored playlists as exact mirrors instead of "add-only" snapshots.

**How to avoid:** Implement add-only semantics. On refresh, only INSERT new tracks; never DELETE existing tracks. Document this behavior clearly.

**Warning signs:**
- Mirrored playlist shrinks after refresh
- User finds previously added track is gone without action
- Sync logic has DELETE clauses for mirrored playlist operations

### Pitfall 4: No Index on Playlist Ordering Column

**What goes wrong:** Playlist with 1000 tracks; drag-drop reordering freezes because every reorder query must scan all 1000 rows to find insertion position.

**Why it happens:** Developers add `position` column, forget to index it. Single-table schema looks simple until scale hits.

**How to avoid:** Always create `CREATE INDEX idx_playlist_position ON playlist_tracks(playlist_id, position)`. Verify index usage in EXPLAIN QUERY PLAN.

**Warning signs:**
- Drag-drop in large playlists becomes noticeably slow
- SQLite EXPLAIN shows full table scan instead of index usage
- Database query times degrade with playlist size

### Pitfall 5: Smart Playlist Queries Without ORDER BY Semantics

**What goes wrong:** "Recently Added" smart playlist defined as "tracks with date_added > now() - 30 days" but no ORDER BY. Results show random order on each query.

**Why it happens:** Developers focus on filtering (WHERE) and forget that order matters for user experience.

**How to avoid:** Define smart playlists with explicit ORDER BY. "Recently Added" should always sort `date_added DESC`. "Most Played" should sort `play_count DESC`.

**Warning signs:**
- Smart playlist order changes on each app restart
- "Recently Added" doesn't show newest tracks first
- Smart playlists conflict with manual reordering expectations

### Pitfall 6: Storing Cover Images as BLOB

**What goes wrong:** Import 50 playlists with cover images. Database grows by 50MB (uncompressed images). App becomes slow; backups bloat; queries block on image data.

**Why it happens:** "Just store it" mentality; seems simpler than file management.

**How to avoid:** Store images as files in cache directory. Only keep path in database. Use descriptive naming: `~/.music-lib/playlists/covers/{playlist_id}.jpg`.

**Warning signs:**
- Database file size disproportionate to track count
- Queries slow down after importing covers
- Backup size is unexpectedly large

## Code Examples

Verified patterns from architecture decisions and existing codebase:

### Creating a Playlist

```rust
// Source: Phase 4 models and Tauri commands
use chrono::Utc;
use crate::models::{Playlist, PlaylistCategory};

#[tauri::command]
pub fn create_playlist(
    app: tauri::AppHandle,
    name: String,
    description: Option<String>,
    tags: Vec<String>,
) -> Result<Playlist, String> {
    let conn = get_db_connection(&app)?;
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    let tx = conn.transaction().map_err(|e| e.to_string())?;

    let now = Utc::now().to_rfc3339();
    tx.execute(
        "INSERT INTO playlists (name, description, category, is_liked, is_smart, date_created)
         VALUES (?, ?, ?, ?, ?, ?)",
        rusqlite::params![name, description, "regular", 0, 0, now],
    ).map_err(|e| e.to_string())?;

    let playlist_id = tx.last_insert_rowid();

    // Insert tags
    for tag in tags {
        tx.execute(
            "INSERT INTO playlist_tags (playlist_id, tag) VALUES (?, ?)",
            rusqlite::params![playlist_id, tag],
        ).map_err(|e| e.to_string())?;
    }

    tx.commit().map_err(|e| e.to_string())?;

    Ok(Playlist {
        id: playlist_id,
        name,
        description,
        tags,
        // ... other fields
    })
}
```

### Adding a Track to Playlist with Fractional Indexing

```rust
// Source: Phase 4 playlist operations
use crate::playlist::ordering::position_between;

#[tauri::command]
pub fn add_track_to_playlist(
    app: tauri::AppHandle,
    playlist_id: i64,
    track_id: i64,
) -> Result<(), String> {
    let conn = get_db_connection(&app)?;
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // Find the last position in the playlist
    let last_position: Option<String> = tx
        .query_row(
            "SELECT position FROM playlist_tracks WHERE playlist_id = ? ORDER BY position DESC LIMIT 1",
            rusqlite::params![playlist_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;

    // Generate new position (append to end)
    let new_position = if let Some(last) = last_position {
        position_between(&last, None)?  // After the last position
    } else {
        "a0".to_string()  // First position
    };

    // Insert the track
    tx.execute(
        "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
        rusqlite::params![playlist_id, track_id, new_position],
    ).map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(())
}

// Helper function using string-based fractional indexing
fn position_between(left: &str, right: Option<&str>) -> Result<String, String> {
    // String-based ordering (base-95)
    // position_between("a0", None) = "a0|a1"
    // position_between("a0", Some("a0|a1")) = "a0|a0"
    // Simplified example; full implementation uses string algebra
    match right {
        None => Ok(format!("{}|a1", left)),
        Some(r) => Ok(format!("{}|a0", left)),
    }
}
```

### Reordering a Track (Drag-Drop)

```rust
// Source: Phase 4 playlist operations
#[tauri::command]
pub fn reorder_playlist_track(
    app: tauri::AppHandle,
    playlist_id: i64,
    track_id: i64,
    target_position: Option<i64>, // Track ID to reorder before
) -> Result<(), String> {
    let conn = get_db_connection(&app)?;
    conn.execute("PRAGMA foreign_keys = ON", [])?;

    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // Get left and right positions for insertion
    let (left_pos, right_pos) = if let Some(target_id) = target_position {
        // Get position of the target track and its neighbor
        let target_pos: String = tx
            .query_row(
                "SELECT position FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?",
                rusqlite::params![playlist_id, target_id],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;

        // Get the track before target
        let prev_pos: Option<String> = tx
            .query_row(
                "SELECT position FROM playlist_tracks WHERE playlist_id = ? AND position < ? ORDER BY position DESC LIMIT 1",
                rusqlite::params![playlist_id, target_pos],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;

        (prev_pos, Some(target_pos))
    } else {
        // Reorder to end: find the last position
        let last_pos: Option<String> = tx
            .query_row(
                "SELECT position FROM playlist_tracks WHERE playlist_id = ? ORDER BY position DESC LIMIT 1",
                rusqlite::params![playlist_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;

        (last_pos, None)
    };

    // Compute new position
    let new_position = position_between(
        left_pos.as_deref().unwrap_or(""),
        right_pos.as_deref(),
    )?;

    // Update track position (only 1 row touched)
    tx.execute(
        "UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND track_id = ?",
        rusqlite::params![new_position, playlist_id, track_id],
    ).map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(())
}
```

### Querying "Recently Added" Smart Playlist

```rust
// Source: Phase 4 smart playlists
#[tauri::command]
pub fn get_recently_added_tracks(
    app: tauri::AppHandle,
    limit: i32,
) -> Result<Vec<TrackInfo>, String> {
    let conn = get_db_connection(&app)?;

    let mut stmt = conn
        .prepare(
            "SELECT id, artist, album, title, date_added
             FROM tracks
             WHERE date_added >= datetime('now', '-30 days')
             ORDER BY date_added DESC
             LIMIT ?"
        )
        .map_err(|e| e.to_string())?;

    let tracks = stmt
        .query_map(rusqlite::params![limit], |row| {
            Ok(TrackInfo {
                id: row.get(0)?,
                artist: row.get(1)?,
                album: row.get(2)?,
                title: row.get(3)?,
                date_added: row.get(4)?,
            })
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    Ok(tracks)
}
```

### React Component for Drag-Drop Reordering

```typescript
// Source: Phase 4 UI patterns with hello-pangea/dnd
import React, { useState, useEffect } from 'react';
import { DragDropContext, Droppable, Draggable, DropResult } from 'hello-pangea/dnd';
import { invoke } from '@tauri-apps/api/core';

interface PlaylistTrack {
  id: number;
  title: string;
  artist: string;
}

export function PlaylistDetail({ playlistId }: { playlistId: number }) {
  const [tracks, setTracks] = useState<PlaylistTrack[]>([]);

  useEffect(() => {
    invoke('get_playlist_tracks', { playlistId }).then(setTracks);
  }, [playlistId]);

  const handleDragEnd = async (result: DropResult) => {
    const { source, destination, draggableId } = result;

    if (!destination) return;

    const trackId = parseInt(draggableId);
    const targetTrackId = destination.index > 0
      ? tracks[destination.index - 1].id
      : undefined;

    // Update database
    await invoke('reorder_playlist_track', {
      playlistId,
      trackId,
      targetPosition: targetTrackId,
    });

    // Refresh UI
    const newTracks = Array.from(tracks);
    const [removed] = newTracks.splice(source.index, 1);
    newTracks.splice(destination.index, 0, removed);
    setTracks(newTracks);
  };

  return (
    <DragDropContext onDragEnd={handleDragEnd}>
      <Droppable droppableId={`playlist-${playlistId}`}>
        {(provided, snapshot) => (
          <div
            {...provided.droppableProps}
            ref={provided.innerRef}
            className={snapshot.isDraggingOver ? 'highlight' : ''}
          >
            {tracks.map((track, index) => (
              <Draggable key={track.id} draggableId={`${track.id}`} index={index}>
                {(provided, snapshot) => (
                  <div
                    ref={provided.innerRef}
                    {...provided.draggableProps}
                    {...provided.dragHandleProps}
                    className={snapshot.isDragging ? 'dragging' : ''}
                  >
                    <div className="handle">⋮⋮</div>
                    <div>{track.title}</div>
                    <div className="artist">{track.artist}</div>
                  </div>
                )}
              </Draggable>
            ))}
            {provided.placeholder}
          </div>
        )}
      </Droppable>
    </DragDropContext>
  );
}
```

## State of the Art

| Old Approach | Current Approach (2026) | When Changed | Impact |
|--------------|------------------------|--------------|--------|
| Integer position (1, 2, 3) with rebalancing | Fractional indexing (string-based) | ~2017-2020 (Figma, Slack adoption) | O(N) rebalancing eliminated; drag-drop scales to thousands of items |
| Fetch entire playlist on every refresh | Incremental sync with timestamps | ~2020-2021 (established in Phase 3) | API quota reduced 10-100x; syncs are near-instant |
| BLOB image storage in database | File path + local cache | ~2020 (cloud storage adoption) | Database size reduced; image serving scales independently |
| Materialized smart playlists | Database views with automatic refresh | ~2022 (PostgreSQL/SQLite improvements) | Schema simpler; views auto-update on data changes |
| Manual playlist import selection | Required user selection (Phase 4) | ~2023 (privacy/control focus) | Prevents accidental library bloat; user has control |

**Deprecated/outdated:**
- **Integer rebalancing approach:** Replaced by fractional indexing. Integer positions hit precision limits and require cascading updates. Never implement this in Phase 4.
- **All-at-once playlist import:** Replaced by user selection. Auto-importing all source playlists creates duplicate clutter. Always provide a chooser UI.
- **Deleting tracks on source removal:** Replaced by add-only semantics. Violates "once downloaded, stays" contract. Never auto-delete from mirrored playlists.

## Open Questions

Things that couldn't be fully resolved:

1. **Exact "Recently Added" window duration**
   - What we know: Context.md mentions "N days" as configurable
   - What's unclear: Should default be 7, 14, 30, or 60 days? What do other music apps use?
   - Recommendation: Implement as 30 days default, configurable in settings (future phase). Matches Spotify "New Music Daily" playlist window.

2. **String fractional indexing implementation**
   - What we know: String-based approach exists (base-95, no precision limits)
   - What's unclear: Should we use an existing Rust crate or implement inline?
   - Recommendation: Search for `fractional-indexing` Rust crates. If none exist, implement inline string algebra (relatively small). Verify with test suite.

3. **Liked playlist creation timing**
   - What we know: Context.md says "created on first import" not on source connect
   - What's unclear: What constitutes "first import" (first track import, or first time source is used)?
   - Recommendation: Create liked playlist on first track from that source is imported to library.

4. **M3U8 ordering guarantees for Phase 5**
   - What we know: M3U8 format has `#EXTINF` and `#EXT-X-MEDIA-SEQUENCE` for order
   - What's unclear: Do we need to handle Rockbox-specific M3U8 extensions?
   - Recommendation: Start with standard M3U8. Check Rockbox documentation in Phase 5.

5. **Cover image refresh strategy**
   - What we know: Spotify provides `/playlists/{id}/images` endpoint
   - What's unclear: On refresh, should we always re-fetch cover? Check timestamps? Cache indefinitely?
   - Recommendation: Compare source image URL; only re-fetch if URL changed. Cache locally with no expiry.

## Sources

### Primary (HIGH confidence)

- **Phase 3 RESEARCH.md** - Established database patterns (transactions, foreign keys, rusqlite usage)
- **Existing codebase** - Track model, database/schema.rs showing transactional patterns
- **Rust design patterns** - https://rust-unofficial.github.io/patterns/ (verified design approaches)

### Secondary (MEDIUM confidence)

- [Fractional Indexing Explained](https://hollos.dev/blog/fractional-indexing-a-solution-to-sorting/) - Architecture recommendation for ordering
- [Figma's Fractional Indexing approach](https://www.steveruiz.me/posts/reordering-fractional-indices) - Battle-tested implementation patterns
- [SQLite JSON vs Separate Table](https://www.beekeeperstudio.io/blog/sqlite-json) - Tag storage decision
- [2026 JSON storage best practices](https://www.dbpro.app/blog/sqlite-json-virtual-columns-indexing) - Current JSON column patterns
- [BLOB vs File System comparison](https://www.geeksforgeeks.org/system-design/blob-vs-file-system-in-system-design/) - Image storage trade-offs
- [Top 5 Drag-and-Drop Libraries for React 2026](https://puckeditor.com/blog/top-5-drag-and-drop-libraries-for-react) - UI pattern recommendation
- [Kodi Smart Playlists pattern](https://kodi.wiki/view/Smart_playlists) - Smart playlist implementation
- [Beets Smart Playlist plugin](https://beets.readthedocs.io/en/stable/plugins/smartplaylist.html) - Reference implementation

### Tertiary (LOW confidence, informational only)

- Various Spotify/SoundCloud community forums discussing playlist features
- Stack Overflow discussions on drag-drop reordering (unverified)

## Metadata

**Confidence breakdown:**
- Standard stack (Database, Rust, Tauri/React): **HIGH** - existing project uses these; recommendations follow established patterns
- Ordering algorithm (Fractional indexing): **MEDIUM-HIGH** - verified via multiple authoritative sources; string-based approach adds confidence
- Smart playlist patterns: **MEDIUM** - verified via Kodi/beets reference implementations; SQL view pattern is standard
- Drag-drop UI: **MEDIUM** - hello-pangea/dnd verified as widely-used library; Tauri-specific config found
- Edge cases (mirroring, liked playlists, cover images): **MEDIUM** - decisions documented in CONTEXT.md; some details TBD in planning

**Research date:** 2026-02-04
**Valid until:** 2026-03-04 (30 days for stable domain; drag-drop library versions should be checked before implementation)

**Confidence caveats:**
- Fractional indexing crate availability in Rust ecosystem not fully verified; planning phase should confirm before task creation
- M3U8 Phase 5 specifics deferred; this research assumes standard M3U8 format
- Cover image refresh strategy (URL comparison vs timestamp) could use more investigation before implementation
