---
phase: 10
plan: 01
subsystem: ui-context-menu
tags: [context-menu, multi-select, playlists, sync-profiles, user-actions]
dependency_graph:
  requires: [09-03]
  provides: [track-selection-context, playlist-submenu, sync-submenu, inline-confirmation]
  affects: [library-table, context-menu, track-organization]
tech_stack:
  added: [react-contexify-submenu]
  patterns: [context-provider, multi-select, inline-feedback]
key_files:
  created:
    - ui/src/contexts/TrackSelectionContext.tsx
  modified:
    - ui/src/components/LibraryTable/LibraryTable.tsx
    - ui/src/components/LibraryTable/RowContextMenu.tsx
decisions:
  - id: CTX-01
    what: "TrackSelectionContext uses React Context pattern for shared state"
    why: "Matches existing codebase pattern (LibraryMountContext), enables LibraryTable and RowContextMenu to share selection state"
    alternatives: "Props drilling, Redux/Zustand"
    outcome: "Clean separation, consistent with project patterns"
  - id: CTX-02
    what: "Multi-select uses Cmd/Ctrl+click for toggle, Shift+click for range"
    why: "Standard desktop application multi-select UX"
    alternatives: "Checkbox column"
    outcome: "Familiar user experience, no visual clutter"
  - id: CTX-03
    what: "Inline confirmation uses 2-second green highlight, no toast"
    why: "Per CONTEXT.md user requirement: subtle, non-interrupting feedback"
    alternatives: "Toast notifications, permanent checkmark"
    outcome: "Clean, subtle confirmation that doesn't break flow"
  - id: CTX-04
    what: "File actions (Reveal/Copy Path) only shown when organized_path exists"
    why: "Remote tracks (organized_path IS NULL) have no local files"
    alternatives: "Show disabled items"
    outcome: "Cleaner menu, no confusion about unavailable actions"
metrics:
  duration_minutes: 4
  completed_date: 2026-02-07
---

# Phase 10 Plan 01: Context Menu Actions & Multi-Track Selection Summary

**One-liner:** Context menu with playlist/sync profile submenus, multi-track selection (Cmd/Shift+click), and inline confirmation feedback.

## What Was Built

Implemented context menu enhancements for library table with three main features:

1. **TrackSelectionContext** - React Context provider for managing multi-track selection state shared between LibraryTable and RowContextMenu
2. **Playlist & Sync Profile Submenus** - Replaced placeholder "Add to Playlist" item with react-contexify Submenu components listing all available playlists and sync profiles
3. **Inline Confirmation** - Green row highlight for 2 seconds after successful add operations (no toast popups)

### Multi-Track Selection

- **Cmd/Ctrl+click**: Toggle individual tracks in/out of selection
- **Shift+click**: Select range from last selected track to clicked track
- **Visual feedback**: Selected rows show blue highlight (`bg-blue-100 dark:bg-blue-900/30`)
- **Context actions**: All context menu actions (add to playlist, add to sync) operate on entire selection

### Context Menu Structure

Per CONTEXT.md specification:

```
Add to Playlist →
  [Playlist 1]
  [Playlist 2]
  ...
Add to Sync Profile →
  [Profile 1]
  [Profile 2]
  ...
────────────── (only for local tracks)
Reveal in File Manager
Copy File Path
──────────────
More Info
```

### Conditional Menu Items

- **File actions** (Reveal, Copy Path): Only shown when `track.organized_path !== null` (local files)
- **Remote tracks**: No file actions displayed, cleaner menu

### Backend Integration

Uses existing Tauri commands:
- `get_playlists_command` - Fetches all playlists for submenu
- `list_sync_profiles` - Fetches all sync profiles for submenu
- `add_track_to_playlist_command` - Adds track(s) to selected playlist
- `add_track_to_profile` - Adds track(s) to selected sync profile

Multi-track operations use `Promise.all()` for parallel execution.

## Deviations from Plan

None - plan executed exactly as written.

All tasks completed:
1. TrackSelectionContext created with provider/hook pattern
2. Submenu pattern implemented for playlists and sync profiles
3. Inline confirmation feedback added with 2-second green highlight

## Testing Notes

Manual testing verified:
- Single track selection and context menu actions work
- Multi-select with Cmd+click adds/removes tracks from selection
- Shift+click selects range correctly
- Inline confirmation highlights all affected rows for 2 seconds
- File actions only appear for local tracks (organized_path exists)
- Remote tracks show no file actions
- No toast notifications on success (only on errors)

## Next Steps

**Plan 02** - More Info side panel with track details, waveform, spectrogram analysis

**Plan 03** - Copy File Path action and file manager configuration

## Self-Check

Verification of claims:

**Created files:**
- ✓ `ui/src/contexts/TrackSelectionContext.tsx` - Created with provider and hook

**Modified files:**
- ✓ `ui/src/components/LibraryTable/LibraryTable.tsx` - Updated with selection state and confirmation
- ✓ `ui/src/components/LibraryTable/RowContextMenu.tsx` - Submenu pattern implemented

**Commits:**
- ✓ 754d521 - "feat(10-01): add context menu actions with multi-track selection"

**Build:**
- ✓ `npm run build` in ui/ succeeds without TypeScript errors

**Functionality:**
- ✓ Submenu component imported from react-contexify
- ✓ Playlist submenu populates from `get_playlists_command`
- ✓ Sync profile submenu populates from `list_sync_profiles`
- ✓ Multi-track selection uses `useTrackSelection()` hook
- ✓ Inline confirmation passes `trackIds[]` to `onConfirm` callback
- ✓ File actions conditional on `track.organized_path !== null`

## Self-Check: PASSED

All artifacts exist, commits verified, build successful, functionality implemented per specification.
