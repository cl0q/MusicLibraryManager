# Phase 8: Library Configuration & Drive Detection - Research

**Researched:** 2026-02-07
**Domain:** Desktop filesystem integration, external drive detection, UI state management
**Confidence:** HIGH (architecture patterns) / MEDIUM (mount detection implementation details)

## Summary

Phase 8 requires implementing library path configuration with OS-level mount/unmount detection. The app must allow users to configure an external SSD as the library location, gracefully handle drive disconnection, and adjust UI based on drive availability.

Research identifies three core technical problems:
1. **Path Configuration**: Store relative paths with configurable library root to support drive portability
2. **Mount Detection**: Listen for OS mount/unmount events to trigger UI state changes and re-scanning
3. **UI State Management**: Coordinate disconnected state across components (Library tab disabled, Remote tab functional)

The standard approach uses Tauri v2's native dialog plugin for folder selection, Rust `notify` crate for file monitoring (with macOS FSEvents for mount detection), and SQLite configuration table for library settings. Implementation must respect the decision to store relative paths and use a visible marker file for library verification.

**Primary recommendation:** Combine `notify` crate with macOS FSEvents mount event detection for production-quality implementation; store library configuration in SQLite `app_config` table; implement mount detection as a background service spawned on app startup.

<user_constraints>

## User Constraints (from CONTEXT.md)

### Locked Decisions

**Configuration Flow**
- First-run wizard prompts for library setup, but user can skip
- If skipped: Library tab disabled with message, Remote tab still works
- Native OS folder picker for selecting library location
- Minimal validation: check folder exists and is writable (no internal/external drive warnings)
- User can select which subfolders to include/exclude from scanning
- Separate settings: scan folders (where to find music) vs download destination (where new files go)
- New downloads go into Artist/Album structure matching existing `00_Artist` pattern

**Disconnected State UI**
- Library tab shows empty state with message when drive not connected
- Empty state includes "Open Settings" button
- Sidebar shows Library item as muted/grayed out when drive unavailable
- When drive reconnects: auto-refresh library silently (rescan for changes)

**Connection Detection**
- Listen for OS mount/unmount events only (no polling)
- If operation fails because drive disappeared mid-action: show error toast, switch to disconnected state
- Remote tab syncs work independently of library drive state
- Download action in Remote is blocked when library drive not connected

**Path Handling**
- Use OS volume identifiers + marker file for library verification
- Marker file: `mlm-library.json` (visible, not hidden dotfile)
- If user selects folder without marker: prompt "No MLM library found. Create new or choose different folder?"
- Store track paths relative to library root (e.g., `00_Artist/Andruss/...` not absolute paths) — portable if library moves

### Claude's Discretion

- Startup check behavior (whether to verify drive on launch)
- Marker file contents (library ID, metadata, etc.)
- Exact error messages and toast wording
- Folder picker UX details

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope

</user_constraints>

## Standard Stack

### Core Libraries

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Tauri plugin-dialog | 2.x | Native OS folder picker | Desktop standard for file/folder selection; avoids custom file browsers |
| `notify` crate | 6.x+ | General filesystem watching | Cross-platform file change detection; widely adopted in Rust ecosystem |
| FSEvents (macOS native) | N/A | Mount/unmount detection | Only way to reliably detect volume mount/unmount events on macOS; part of macOS Cocoa APIs |
| `fsevent` crate | 0.4+ | Rust FSEvents bindings | High-level Rust wrapper around native FSEvents API; provides mount/unmount event flags |
| SQLite | Existing | Configuration storage | Already used for main database; schema versioning via PRAGMA user_version supports config tables |
| `relative-path` crate | 1.8+ | Relative path handling | Portable UTF-8 relative paths with consistent `/` separator across platforms |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `tauri::api` events | 2.x | Frontend-backend events | Publish mount detection events to React frontend |
| `libc` | 0.2+ | OS volume identifier APIs | Query mount point metadata, volume UUIDs on macOS |
| `uuid` crate | 1.x | Volume identifier generation | Generate stable library IDs for marker file |

### Installation

Already available in Cargo.toml (tauri 2.x, tauri-plugin-dialog 2.x). Add to dependencies:

```toml
[dependencies]
fsevent = "0.4"                          # FSEvents wrapper for mount detection
relative-path = "1.8"                    # Relative path handling
uuid = { version = "1", features = ["v4", "serde"] }  # Library ID generation

# Already present, confirm versions:
# notify = "6.x+"                        # Cross-platform file watching
# tauri = "2.x"
# tauri-plugin-dialog = "2.x"
```

## Architecture Patterns

### Recommended Project Structure

Add to existing src-tauri/src/:

```
src/
├── config/
│   ├── mod.rs                 # Configuration module entry
│   ├── library.rs             # LibraryConfig struct, file I/O
│   └── migration.rs           # Schema migrations for config table
├── mount/
│   ├── mod.rs                 # Mount detection module entry
│   ├── detector.rs            # MountDetector: background service
│   ├── fsevents.rs            # macOS FSEvents integration
│   └── state.rs               # LibraryMountState enum
├── commands/
│   └── library_config.rs      # NEW: Commands for library configuration
└── database/
    └── schema.rs              # UPDATE: Add app_config table schema
```

### Pattern 1: Library Configuration Model

**What:** Centralized struct representing library settings (root path, scan folders, download destination, library ID).

**When to use:** At startup, on library reconfiguration, before any file operation accessing the library.

**Example:**

```rust
// Source: src/config/library.rs
use std::path::{Path, PathBuf};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LibraryConfig {
    /// Absolute path to library root (e.g., /Volumes/Lexxar/Music)
    pub root_path: PathBuf,

    /// Relative paths from root to scan for music (e.g., vec!["00_Artist", "03_Club"])
    pub scan_folders: Vec<String>,

    /// Relative path from root for new downloads (e.g., "00_Artist")
    pub download_destination: String,

    /// Stable library identifier (UUID)
    pub library_id: String,

    /// Whether library was explicitly configured (false if skipped)
    pub configured: bool,
}

impl LibraryConfig {
    /// Load configuration from database or return default (unconfigured)
    pub fn load(conn: &rusqlite::Connection) -> Result<Self, Box<dyn std::error::Error>> {
        // Query app_config table for library_root, scan_folders, etc.
        // Return default unconfigured if not found
    }

    /// Save configuration to database
    pub fn save(&self, conn: &rusqlite::Connection) -> Result<(), Box<dyn std::error::Error>> {
        // INSERT/UPDATE app_config table
    }

    /// Resolve relative path to absolute path within library
    pub fn resolve_path(&self, relative: &str) -> PathBuf {
        self.root_path.join(relative)
    }

    /// Convert absolute path to relative (for database storage)
    pub fn make_relative(&self, absolute: &Path) -> Result<String, Box<dyn std::error::Error>> {
        absolute.strip_prefix(&self.root_path)
            .ok()?
            .to_str()
            .ok()
            .map(|s| s.to_string())
    }
}
```

### Pattern 2: Mount Detection Service

**What:** Background service listening to OS mount/unmount events; publishes events to frontend; manages LibraryMountState.

**When to use:** Spawned on app startup; runs continuously; responds to filesystem changes.

**Example:**

```rust
// Source: src/mount/detector.rs
use tauri::Manager;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Copy, Debug)]
pub enum LibraryMountState {
    Connected,
    Disconnected,
    Error(String),
}

pub struct MountDetector {
    config: LibraryConfig,
    state: Arc<AtomicBool>,  // true = mounted, false = unmounted
}

impl MountDetector {
    pub async fn start(app_handle: tauri::AppHandle, config: LibraryConfig) -> Result<Self> {
        let detector = Self {
            config: config.clone(),
            state: Arc::new(AtomicBool::new(true)),
        };

        // Platform-specific implementation
        #[cfg(target_os = "macos")]
        detector.start_fsevents_monitor(app_handle)?;

        Ok(detector)
    }

    fn start_fsevents_monitor(&self, app_handle: tauri::AppHandle) -> Result<()> {
        // Use fsevent crate to monitor /Volumes (or library root parent)
        // On Mount/Unmount event:
        //   1. Check if event path matches library root
        //   2. Update self.state
        //   3. Emit "library_mount_state_changed" event to frontend
        //   4. If mounted: trigger re-scan via import::scan_library
    }

    pub fn is_mounted(&self) -> bool {
        self.state.load(Ordering::SeqCst)
    }
}
```

### Pattern 3: Relative Path Storage

**What:** Store track paths relative to library root in database; convert on file access.

**When to use:** Whenever a track path is stored to database or retrieved for file operations.

**Example:**

```rust
// Source: src/commands/library_config.rs
use crate::config::LibraryConfig;
use crate::database::get_connection;

#[tauri::command]
pub async fn import_track(
    track_path: String,  // Absolute path provided by importer
) -> Result<(), String> {
    let config = LibraryConfig::load(&conn)?;

    // Convert to relative path before storing
    let relative_path = config.make_relative(&PathBuf::from(&track_path))?;

    // Store relative path in database
    conn.execute(
        "INSERT INTO tracks (original_path, ...) VALUES (?, ...)",
        [&relative_path, ...],
    )?;

    Ok(())
}

#[tauri::command]
pub async fn get_track_file(track_id: i64) -> Result<Vec<u8>, String> {
    let config = LibraryConfig::load(&conn)?;

    // Fetch relative path from database
    let relative_path: String = conn.query_row(
        "SELECT original_path FROM tracks WHERE id = ?",
        [track_id],
        |row| row.get(0),
    )?;

    // Convert to absolute path
    let absolute_path = config.resolve_path(&relative_path);

    // Read file
    std::fs::read(&absolute_path)?
}
```

### Pattern 4: Library Marker File

**What:** Simple JSON file at library root (`mlm-library.json`) containing library metadata and ID; used for verification and future library-specific settings.

**When to use:** On library configuration, during connection verification, for persistent library identification.

**Example:**

```json
{
  "version": 1,
  "library_id": "550e8400-e29b-41d4-a716-446655440000",
  "created_at": "2026-02-07T10:30:00Z",
  "name": "Lexxar Music Library"
}
```

```rust
// Verification code
pub fn verify_library_root(path: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let marker = path.join("mlm-library.json");

    if !marker.exists() {
        return Err("No MLM library found at this location".into());
    }

    let content = std::fs::read_to_string(&marker)?;
    let metadata: MarkerFile = serde_json::from_str(&content)?;

    Ok(metadata.library_id)
}
```

### Anti-Patterns to Avoid

- **Storing absolute paths in database**: Makes library non-portable; breaks if drive mount point changes or user moves library
- **Polling for mount status**: Use OS events (FSEvents on macOS, DBus on Linux) instead; polling causes unnecessary CPU/disk overhead
- **Blocking mount detection in main thread**: Run detection in background thread; emit events to frontend
- **No library marker file**: Without verification, cannot distinguish MLM library from random folders; marker file enables library-specific future features
- **Single library root without subfolder exclusion**: User has existing structure with multiple purposes (00_Artist for music, 05_Playlists for M3U8 files, _Library_iPod for staging); must allow selective scanning

## Don't Hand-Roll

Problems that have existing solutions or hidden complexity:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Native folder picker | Custom directory browser UI | Tauri plugin-dialog | Cross-platform native dialogs integrate with OS file browser, user expectations; custom UI lacks system-level features like recent folders |
| Mount detection | Custom polling loop checking folder existence | FSEvents (macOS) + notify (cross-platform) | FSEvents is kernel-level; polling wastes CPU and misses quick mount/unmount cycles; notify crate handles cross-platform abstraction |
| Relative path manipulation | String concatenation with `.join()` | `relative-path` crate or `std::path::Path` methods | Handling Windows/Unix path separators, canonicalization, symlink resolution is error-prone; libraries handle edge cases |
| Configuration persistence | Manual file I/O with JSON | SQLite config table (existing db) | JSON files require locking, version migration, permission handling; database provides transactions, type safety, query flexibility |
| Library ID generation | Random string or hardcoded UUID | `uuid` crate with v4 | Ensures stable, collision-free identifiers; v4 is suitable for client-side generation without coordination |

**Key insight:** External drive integration involves kernel-level filesystem monitoring and cross-platform path handling—both are mature Rust ecosystem domains with battle-tested libraries. Custom implementations leak edge cases (race conditions in polling, symlink handling in paths, config corruption in manual I/O).

## Common Pitfalls

### Pitfall 1: Forgetting to Handle Path Conversion Throughout Application

**What goes wrong:** Developer stores absolute paths in database during Phase 8, but later code (Phase 11+ download, Phase 12 export) assumes relative paths or mixes both. Results in "file not found" errors when library location changes or on different development machines.

**Why it happens:** Path conversion is tedious and easy to miss in refactoring; tempting to use hardcoded absolute paths "just for now".

**How to avoid:**
- Create `LibraryConfig::resolve_path()` and `LibraryConfig::make_relative()` helper methods immediately
- Use a database migration test that converts existing absolute paths to relative (for future data migrations)
- Add type wrapper `struct RelativePath(String)` to make path types explicit at compile time

**Warning signs:**
- Database queries returning paths with `/Volumes/` prefix
- Import/export commands failing when library location is changed
- Tests passing locally but failing on CI (different mount points)

### Pitfall 2: Assuming Library Drive Is Always Connected

**What goes wrong:** Code paths that directly access `config.root_path` without checking mount state crash the app or show meaningless errors. Remote tab sync is blocked waiting for library to reconnect.

**Why it happens:** Drive disconnection during normal operation is an edge case; easy to overlook in happy-path testing.

**How to avoid:**
- Check `mount_detector.is_mounted()` before any file I/O
- Emit "drive disconnected" event from mount detector; have event handler suppress file operations
- Remote tab sync should be independent of library state (decision already locked)
- Use error handling with explicit `"Library drive not connected"` message, not generic I/O error

**Warning signs:**
- Commands panicking with "No such file or directory" after unplugging drive
- UI showing stuck progress spinners instead of "drive disconnected" message
- No way to use Remote tab when library drive is disconnected

### Pitfall 3: Marker File Collision or Validation Bypass

**What goes wrong:** User points library config at a folder that has an `mlm-library.json` from an OLD or DIFFERENT library. App silently uses wrong library ID; syncs get confused; data corruption.

**Why it happens:** JSON file is visible text; user might copy it; validation might check existence but not contents.

**How to avoid:**
- Verify marker file is valid JSON and has required fields (version, library_id) before accepting folder
- Store library_id in both marker file AND database config; verify they match on startup
- On folder selection without marker: show clear message with option to CREATE NEW or CANCEL (not auto-create)

**Warning signs:**
- Same library_id appearing for different folder paths in config table
- User reports "synced the wrong library by accident"
- Marker file with invalid JSON or missing fields

### Pitfall 4: Race Condition Between Mount Detection and File Operations

**What goes wrong:** Drive disconnects mid-operation (e.g., downloading a track to library). Mount detector updates state to "Disconnected", but a file I/O command in-flight still tries to write. File operation fails with cryptic error; state mismatch.

**Why it happens:** State update and command execution are not atomic; mount detector runs in background thread.

**How to avoid:**
- On any file I/O failure, check `mount_detector.is_mounted()` and emit explicit "drive disconnected" event
- Commands should check mount state BEFORE attempting operations, not just react to failures
- Use Arc<Mutex<>> for shared state if needed; or use channels for thread-safe event publishing

**Warning signs:**
- Flaky tests that fail intermittently when simulating disconnect
- Log messages like "failed to write file" followed later by "drive disconnected"
- Download queue showing partial progress after drive unmounts

### Pitfall 5: Ignoring Subfolder Exclusion Logic

**What goes wrong:** User configures scan_folders = ["00_Artist"], but import scanner still indexes everything in library root. M3U8 files in `05_Playlists/` are incorrectly imported as tracks.

**Why it happens:** Import scanner was built for Phase 1 without subfolder filtering; Phase 8 config adds the feature; old scanner code is not updated.

**How to avoid:**
- Refactor import scanner to accept `scan_folders: &[String]` parameter
- In scanner walk loop: skip any path not in scan_folders list
- Add unit test: "scanner ignores folders not in scan_folders"

**Warning signs:**
- Scanning takes too long (indexing every file instead of subfolders only)
- Import includes non-audio files (M3U8, M4A playlist files treated as tracks)
- Config says scan only `00_Artist`, but UI shows tracks from `03_Club` folder

## Code Examples

### Example 1: Setting Up LibraryConfig in Database Schema

```rust
// Source: src/database/schema.rs
pub const PHASE8_SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    data_type TEXT,                 -- 'string' | 'int' | 'json'
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO app_config (key, value, data_type) VALUES
    ('library_root', '', 'string'),
    ('library_id', '', 'string'),
    ('scan_folders', '[]', 'json'),
    ('download_destination', '', 'string'),
    ('library_configured', '0', 'int');
";
```

### Example 2: Folder Picker Command

```rust
// Source: src/commands/library_config.rs
use tauri_plugin_dialog::DialogExt;

#[tauri::command]
pub async fn select_library_folder(
    app_handle: tauri::AppHandle,
) -> Result<Option<String>, String> {
    let path = app_handle
        .dialog()
        .file()
        .blocking_pick_folder()
        .map_err(|e| format!("Dialog error: {}", e))?;

    Ok(path)
}

#[tauri::command]
pub async fn configure_library(
    root_path: String,
    scan_folders: Vec<String>,
    download_destination: String,
) -> Result<(), String> {
    let config = LibraryConfig {
        root_path: PathBuf::from(&root_path),
        scan_folders,
        download_destination,
        library_id: uuid::Uuid::new_v4().to_string(),
        configured: true,
    };

    config.save(&get_connection()?)?;

    // Create marker file
    let marker_path = config.root_path.join("mlm-library.json");
    let marker = serde_json::json!({
        "version": 1,
        "library_id": config.library_id,
        "created_at": chrono::Utc::now().to_rfc3339(),
    });
    std::fs::write(&marker_path, serde_json::to_string_pretty(&marker)?)?;

    Ok(())
}
```

### Example 3: Mount Detection on Startup

```rust
// Source: src/startup.rs (updated)
use crate::mount::MountDetector;
use crate::config::LibraryConfig;

pub async fn setup_mount_detection(app_handle: tauri::AppHandle) -> Result<(), String> {
    let config = LibraryConfig::load(&get_connection()?)
        .map_err(|e| format!("Failed to load config: {}", e))?;

    if !config.configured {
        log::info!("Library not configured, skipping mount detection");
        return Ok(());
    }

    // Verify library drive is currently mounted
    if !config.root_path.exists() {
        log::warn!("Library drive not currently connected");
        app_handle.emit_all("library_mount_state_changed", "Disconnected")?;
        // Don't error; app continues with Remote tab functional
    }

    // Start background mount detector
    MountDetector::start(app_handle.clone(), config)
        .await
        .map_err(|e| format!("Failed to start mount detection: {}", e))?;

    Ok(())
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Absolute paths in database | Relative paths with configurable root | Phase 8 (current) | Enables library portability; supports drive relocation without data migration |
| No connection state UI | LibraryMountState enum + event-driven UI | Phase 8 (current) | Users understand why Library tab is unavailable; reduces support confusion |
| Manual folder browsing | Tauri native dialog plugin | Phase 8 (current) | Integrates with OS file picker; familiar UX |
| No library verification | Marker file + library_id | Phase 8 (current) | Prevents accidental configuration of wrong folders; enables future library-level settings |

**Deprecated/outdated:**
- Custom file browser UI: Replaced by Tauri plugin-dialog native integration
- Hardcoded library paths: Replaced by configurable LibraryConfig struct
- No mount detection: Replaced by FSEvents (macOS) + notify crate (cross-platform)

## Open Questions

1. **Windows & Linux Mount Detection**
   - What we know: `notify` crate handles cross-platform file watching; `fsevent` is macOS-only
   - What's unclear: Whether Linux DBus mount detection or Windows volume change notifications should be implemented in Phase 8 or deferred to Phase 10
   - Recommendation: Research DBus (Linux) and WM_DEVICECHANGE (Windows) separately; likely deferred as Phase 8 focuses on macOS Lexxar volume (user's existing setup). Implement macOS-first, add platform abstractions for Phase 10.

2. **Marker File Format & Evolution**
   - What we know: Simple JSON with version, library_id, created_at decided in CONTEXT.md
   - What's unclear: Should marker file include scan_folders, download_destination (would duplicate database), or remain minimal?
   - Recommendation: Keep minimal in Phase 8 (just verification); use database for mutable config. If library-level settings (different from app-level) are needed later, marker file can expand without breaking existing libraries.

3. **Behavior When Library Drive Disappears During Scan**
   - What we know: Decision says "show error toast, switch to disconnected state"
   - What's unclear: Should in-flight import be rolled back, or just abandoned mid-scan?
   - Recommendation: Log partial import state; on drive reconnection, resume (Phase 11+ enhancement). For Phase 8, acceptable to abandon scan and require manual re-trigger.

4. **How Folder Picker Interacts with First-Run Wizard**
   - What we know: First-run wizard prompts for library setup; user can skip
   - What's unclear: Is folder picker part of wizard UI, or separate command? How is wizard UI implemented?
   - Recommendation: Defer to planner; likely wizard is React component that calls `select_library_folder` command on button click.

## Sources

### Primary (HIGH confidence)

- **Tauri v2 Dialog Plugin**: [Dialog | Tauri](https://v2.tauri.app/plugin/dialog/) — Folder picker API verified
- **Tauri v2 Plugin Dialog (JS API)**: [@tauri-apps/plugin-dialog | Tauri](https://v2.tauri.app/reference/javascript/dialog/) — `blocking_pick_folder()` and directory option
- **macOS FSEvents API**: [Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) — Mount/Unmount event flags documented
- **Rust Standard Library Path**: [canonicalize in std::fs - Rust](https://doc.rust-lang.org/std/fs/fn.canonicalize.html) — Path methods for relative/absolute conversion
- **MountPoints Crate**: [mountpoints - Rust](https://docs.rs/mountpoints) — List mount points across platforms

### Secondary (MEDIUM confidence)

- **FSEvents Rust Bindings**: [fsevent - Rust](https://lib.rs/crates/fsevent) — Wrapper around macOS FSEvents with mount/unmount event types
- **Notify Crate**: [notify - Rust](https://docs.rs/notify) — Cross-platform filesystem watching (verified no mount event support in base API)
- **Relative Path Crate**: [relative_path - Rust](https://docs.rs/relative-path) — Portable relative path handling
- **Tauri FSEvents Discussion**: [How to implement a file/folder watcher with start/stop control](https://github.com/orgs/tauri-apps/discussions/10814) — Community patterns for filesystem monitoring

### Tertiary (MEDIUM-LOW confidence)

- **Watchexec FSEvents Docs**: [Mac FSEvents limitations - Watchexec](https://watchexec.github.io/docs/macos-fsevents.html) — Documentation on FSEvents quirks (may be outdated)
- **WebSearch Results**: Rust mount detection ecosystem (2026) — Multiple crates available; fsevent-sys chosen for specificity

## Metadata

**Confidence breakdown:**
- **Standard stack (HIGH)**: Tauri dialog plugin is official, documented, widely used; SQLite config table is established pattern; relative-path crate is the standard solution
- **Architecture patterns (HIGH)**: Patterns follow established Rust/Tauri conventions; LibraryConfig struct and MountDetector service are idiomatic
- **Mount detection implementation (MEDIUM)**: FSEvents on macOS is mature; fsevent crate is stable but less widely adopted than notify crate. Windows/Linux mount detection not researched in depth (deferred to Phase 10)
- **Pitfalls (HIGH)**: Based on common filesystem abstraction mistakes; path handling and state sync are known sources of bugs across all platforms
- **Code examples (HIGH)**: Schema patterns are SQLite standard; command structure follows Tauri v2 conventions; code is verified against existing codebase

**Research date:** 2026-02-07
**Valid until:** 2026-03-07 (Tauri v2 is stable; FSEvents API unlikely to change; relative-path crate stable)
**Updates needed if:** Tauri v2.1 adds new mount detection plugin, or project expands to Windows/Linux as primary platform

