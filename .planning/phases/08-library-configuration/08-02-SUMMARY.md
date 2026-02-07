---
phase: 08-library-configuration
plan: 02
subsystem: mount-detection, startup
tags: [notify, fsevents, tauri-events, background-threads]

# Dependency graph
requires:
  - phase: 08-01
    provides: LibraryConfig model for loading library root path
provides:
  - MountDetector service with FSEvents-based volume monitoring
  - LibraryMountState enum (Connected, Disconnected, NotConfigured)
  - Background mount detection spawned on app startup
  - library-mount-changed Tauri events for frontend state updates
  - get_library_mount_state command for querying current state
affects: [08-03-settings-ui, 08-04-library-ui, 09-library-remote-separation]

# Tech tracking
tech-stack:
  added: [notify v6 with macos_fsevent feature]
  patterns: [background service pattern, managed state for services, event-driven UI updates]

key-files:
  created:
    - src-tauri/src/mount/mod.rs
    - src-tauri/src/mount/detector.rs
  modified:
    - src-tauri/Cargo.toml
    - src-tauri/src/lib.rs
    - src-tauri/src/startup.rs
    - src-tauri/src/commands/library_config.rs
    - src-tauri/src/commands/mod.rs

key-decisions:
  - "Use notify crate's /Volumes watching instead of low-level fsevent bindings"
  - "Simple path.exists() check after /Volumes events, not parsing mount flags"
  - "Mount detection runs in background thread, never blocks app startup"
  - "Emit initial state immediately on startup before starting watcher"
  - "Store MountDetector in Tauri managed state for command access"

patterns-established:
  - "Background services spawn threads and return Arc<Self> for managed state"
  - "Startup functions are synchronous but spawn background work internally"
  - "Event emission for state changes + command for state queries"

# Metrics
duration: 12min
completed: 2026-02-07
---

# Phase 8 Plan 02: Mount Detection Summary

**FSEvents-based library drive monitoring with background /Volumes watcher emitting library-mount-changed events**

## Performance

- **Duration:** 12 min
- **Started:** 2026-02-07T10:14:31Z
- **Completed:** 2026-02-07T10:26:47Z
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments
- MountDetector service watches /Volumes directory for volume mount/unmount events
- Background thread monitors library root path existence and emits Tauri events on state changes
- Mount detection integrates into app startup without blocking initialization
- get_library_mount_state command allows frontend to query current mount state
- All 331 tests pass, including 3 new mount detection tests

## Task Commits

Each task was committed atomically:

1. **Task 1: Create mount detection module with FSEvents integration** - `4cf8c2c` (feat)
2. **Task 2: Integrate mount detection into startup and add mount state command** - `97e8acc` (feat, mislabeled as 08-03)

Note: Task 2 work was completed in commit 97e8acc which is labeled as 08-03 but contains the setup_mount_detection function and get_library_mount_state command required for 08-02.

## Files Created/Modified

### Created
- `src-tauri/src/mount/mod.rs` - Mount detection module entry point, re-exports MountDetector and LibraryMountState
- `src-tauri/src/mount/detector.rs` - MountDetector service with background /Volumes watcher, state management, and event emission

### Modified
- `src-tauri/Cargo.toml` - Added notify v6 with macos_fsevent feature
- `src-tauri/Cargo.lock` - Updated dependencies
- `src-tauri/src/lib.rs` - Added mount module, registered get_library_mount_state command, called setup_mount_detection in app setup
- `src-tauri/src/startup.rs` - Added setup_mount_detection function, imports for LibraryConfig and MountDetector
- `src-tauri/src/commands/library_config.rs` - Added get_library_mount_state command with managed state access
- `src-tauri/src/commands/mod.rs` - Re-exported get_library_mount_state command

## Decisions Made

1. **Use notify crate instead of low-level fsevent bindings:** Research suggested fsevent crate directly, but notify v6 wraps FSEvents on macOS with a cleaner API and cross-platform abstraction for future Linux/Windows support
2. **Simple path.exists() check after /Volumes events:** Instead of parsing FSEvents mount flags, check if library root path exists after any /Volumes directory change - simpler and more reliable
3. **Non-blocking startup:** Mount detection errors are logged but never block app initialization - Remote tab must work even if mount detection fails
4. **Periodic fallback checks:** Watcher uses 1-second recv_timeout to check state periodically even without events, ensuring state updates don't get missed
5. **Arc<MountDetector> in managed state:** Detector stored as Arc<MountDetector> in Tauri managed state so commands can access current mount state

## Deviations from Plan

None - plan executed exactly as written. The research recommendation to use fsevent crate was overridden in favor of notify crate, which provides the same FSEvents backend with better cross-platform abstractions.

## Issues Encountered

**Missing trait imports:** Initial compilation failed because Emitter and Manager traits weren't imported. Fixed by adding `use tauri::{Emitter, Manager}` to detector.rs and startup.rs.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Phase 8 Plan 03 (Settings UI):**
- Frontend can listen to `library-mount-changed` events for drive connection state
- Frontend can call `get_library_mount_state()` to query current state
- Mount state includes Connected/Disconnected/NotConfigured variants

**Ready for Phase 8 Plan 04 (Library UI Updates):**
- Library tab can disable/gray out when mount state is Disconnected
- Empty state can show "Library drive not connected" message
- Auto-refresh library when mount state changes from Disconnected to Connected

**No blockers or concerns.**

---
*Phase: 08-library-configuration*
*Completed: 2026-02-07*

## Self-Check: PASSED

All key files verified:
- src-tauri/src/mount/mod.rs
- src-tauri/src/mount/detector.rs

All commits verified:
- 4cf8c2c (Task 1)
- 97e8acc (Task 2)
