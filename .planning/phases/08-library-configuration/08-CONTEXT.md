# Phase 8: Library Configuration & Drive Detection - Context

**Gathered:** 2026-02-07
**Status:** Ready for planning

<domain>
## Phase Boundary

User can configure an external drive as the library location and the app gracefully handles drive connection state. Library files live on external SSD. App detects mount/unmount and adjusts UI accordingly.

**Existing structure context:** User has existing library at `/Volumes/Lexxar/Music/` with:
- `00_Artist/` — Main artist-organized collection (508 artists, Artist/Release/Track structure)
- `05_Playlists/` — M3U8 files for Rockbox
- `06_Symlink_Playlists/` — Symlink folders with ordered tracks
- `_Library_iPod/toSync/` — Downloads staging area
- Various category folders (03_Club, 04_Slow, etc.)

MLM must work with this structure — index what exists, don't force reorganization. Playlists/organization live in MLM database, not filesystem.

</domain>

<decisions>
## Implementation Decisions

### Configuration Flow
- First-run wizard prompts for library setup, but user can skip
- If skipped: Library tab disabled with message, Remote tab still works
- Native OS folder picker for selecting library location
- Minimal validation: check folder exists and is writable (no internal/external drive warnings)
- User can select which subfolders to include/exclude from scanning
- Separate settings: scan folders (where to find music) vs download destination (where new files go)
- New downloads go into Artist/Album structure matching existing `00_Artist` pattern

### Disconnected State UI
- Library tab shows empty state with message when drive not connected
- Empty state includes "Open Settings" button
- Sidebar shows Library item as muted/grayed out when drive unavailable
- When drive reconnects: auto-refresh library silently (rescan for changes)

### Connection Detection
- Listen for OS mount/unmount events only (no polling)
- If operation fails because drive disappeared mid-action: show error toast, switch to disconnected state
- Remote tab syncs work independently of library drive state
- Download action in Remote is blocked when library drive not connected

### Path Handling
- Use OS volume identifiers + marker file for library verification
- Marker file: `mlm-library.json` (visible, not hidden dotfile)
- If user selects folder without marker: prompt "No MLM library found. Create new or choose different folder?"
- Store track paths relative to library root (e.g., `00_Artist/Andruss/...` not absolute paths) — portable if library moves

### Claude's Discretion
- Startup check behavior (whether to verify drive on launch)
- Marker file contents (library ID, metadata, etc.)
- Exact error messages and toast wording
- Folder picker UX details

</decisions>

<specifics>
## Specific Ideas

- Library lives on external SSD (currently "Lexxar" volume)
- Marker file (`mlm-library.json`) acts as secondary verification and future-proofs for library-specific settings
- Downloads should blend into existing `00_Artist/` structure, not create separate MLM folder
- User has symlink-based playlists and m3u8 files — MLM playlists are database-level, separate from these filesystem artifacts

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 08-library-configuration*
*Context gathered: 2026-02-07*
