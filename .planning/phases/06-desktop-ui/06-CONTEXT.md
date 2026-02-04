# Phase 6: Desktop UI - Context

**Gathered:** 2026-02-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Cross-platform desktop UI using Tauri + React + TypeScript + Tailwind. Ties together existing backend capabilities (library, playlists, sync, downloads) into a cohesive app with dashboard, library browser, playlist management, sync controls, and download queue. Existing React components from Phases 3-5 (PlaylistList, PlaylistDetail, SyncProfiles, SyncPreview) get integrated into the unified layout.

Note: Roadmap says "PySide6" but project migrated to Tauri+React. This phase builds on the existing Tauri/React stack.

</domain>

<decisions>
## Implementation Decisions

### App Layout & Navigation
- Persistent left sidebar with icons + labels (Spotify/Linear style)
- Five top-level sections: Dashboard, Library, Playlists, Sync, Downloads
- Playlists section is a single sidebar entry linking to a list view (not inline playlist listing)
- Light default aesthetic, clean/airy (Apple Music/Notion feel)
- Dark mode support via Tailwind `dark:` variant classes, following OS preference
- Architecture allows CSS theming since it's standard HTML/CSS in Tauri webview

### Library Browser
- Table/list view with sortable columns (not card grid)
- Default visible columns: Title, Artist, Album, Duration, Source, Quality, Date Added
- Filter bar at top of library view for real-time search-as-you-type filtering
- Right-click context menu with actions:
  - Add to playlist (pick from existing)
  - Download (trigger if not yet local)
  - Sync (push to device/profile)
  - Add to library (add to sync profiles / "sublibraries")
  - Reveal in file manager (Finder/Forklift/system file manager)
  - View details (spectrogram, waveform visualization, cleaned ffprobe output, backend metadata)

### Progress & Activity Feed
- Bottom status bar persistent on all pages showing current operation + progress, clickable to expand
- Dedicated Downloads page (sidebar section) with full queue view, progress bars, statuses, history
- Detailed per-item info: track name, source, current step (downloading FLAC → transcoding → importing), speed, ETA, file size
- Failed items stay inline in queue with red status, expandable error message, retry button per item
- Toast notifications for completed operations (downloads done, syncs finished, errors)

### Dashboard Home Screen
- Mixed layout: stats cards at top, recent activity in middle, quick actions accessible
- Stats cards: Track count, Storage size, Sources connected, Last sync time, Pending downloads count
- Activity feed shows all activity types: tracks added, syncs completed, sources refreshed, errors encountered
- Live updates via Tauri event system — dashboard refreshes in real-time as operations complete

### Claude's Discretion
- Exact sidebar width and icon choices
- Table virtualization approach for large libraries
- Toast notification positioning and duration
- Status bar design and expand/collapse behavior
- Dashboard card layout and responsive breakpoints
- Spectrogram/waveform rendering approach in detail view
- Router implementation (likely React Router or similar)
- Integration approach for existing Phase 3-5 React components into new layout

</decisions>

<specifics>
## Specific Ideas

- Track detail view should show spectrogram, waveform visualization, cleaned ffprobe output, and "backend" info — power-user feature for inspecting audio quality
- "Add to library" in context menu refers to sync profiles (the user's concept of sublibraries/device profiles)
- Reveal in file manager should detect system default or support Forklift 4 as alternative on macOS
- Light theme should feel clean and airy, not sterile — think Notion or Apple Music aesthetic
- Dark mode follows OS preference automatically

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-desktop-ui*
*Context gathered: 2026-02-04*
