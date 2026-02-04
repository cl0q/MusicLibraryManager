---
phase: 06-desktop-ui
plan: 03
subsystem: ui-library
tags: [react, tanstack-table, tanstack-virtual, ui, performance]
requires: [06-01]
provides:
  - Library Browser page with virtualized table
  - Sortable columns for 10k+ track performance
  - Real-time search filtering
  - Formatter utilities for duration/date/quality
affects: []
tech-stack:
  added: []
  patterns:
    - TanStack React Table for data grids
    - TanStack Virtual for list virtualization
    - Client-side filtering with useMemo
decisions:
  - Use TanStack React Table + TanStack Virtual for 10k+ track performance
  - Client-side filtering via useMemo for instant responsiveness
  - 40px row height with 5 row overscan for smooth scrolling
  - Sticky table headers for persistent column visibility
  - Source-specific colors (Spotify green, SoundCloud orange)
  - Empty query to search_library returns all tracks
key-files:
  created:
    - ui/src/utils/formatter.ts
    - ui/src/hooks/useLibraryTracks.ts
    - ui/src/components/LibraryTable/LibraryTable.tsx
    - ui/src/components/LibraryTable/FilterBar.tsx
    - ui/src/pages/LibraryBrowser.tsx
  modified:
    - ui/src/App.tsx
metrics:
  tasks: 3
  commits: 3
  duration: 146s
  completed: 2026-02-04
---

# Phase 6 Plan 3: Library Browser Summary

**One-liner:** Library Browser with virtualized table handling 10k+ tracks using TanStack React Table + Virtual

## What Was Built

### Formatter Utilities (`formatter.ts`)
- `formatDuration(seconds)`: Convert to M:SS format (e.g., "3:45")
- `formatBytes(bytes)`: Human-readable sizes (e.g., "3.5 MB")
- `formatDate(timestamp)`: Locale date strings (e.g., "Jan 15, 2026")
- `formatQuality(quality)`: Clean quality strings

### Library Tracks Hook (`useLibraryTracks.ts`)
- Fetches all tracks via `search_library("")` on mount
- Client-side filtering via `useMemo` for instant search
- Filters by title/artist/album/album_artist
- Returns `{ tracks, loading, filterQuery, setFilterQuery }`

### LibraryTable Component (`LibraryTable.tsx`)
- **Seven columns:** Title, Artist, Album, Duration, Source, Quality, Date Added
- **TanStack React Table** with sortable columns
- **TanStack Virtual** with 40px row height, 5 row overscan
- Sticky headers with sort indicators (↑/↓)
- Source-specific colors (Spotify green, SoundCloud orange)
- Dark mode support

### FilterBar Component (`FilterBar.tsx`)
- Search input with magnifying glass icon
- Track count display
- Loading state handling
- Dark mode support

### LibraryBrowser Page (`LibraryBrowser.tsx`)
- Composes `useLibraryTracks`, `FilterBar`, `LibraryTable`
- Loading state: "Loading library..."
- Empty states: "No tracks in library" / "No tracks match your search"
- Full-height layout with flex-1 table container

### Router Integration (`App.tsx`)
- Updated `/library` route to use `LibraryBrowser`
- Replaced placeholder `Library` component

## Technical Implementation

### Performance Strategy
- **Virtualization:** Only render visible rows (TanStack Virtual)
- **Client-side filtering:** useMemo prevents re-filter on unrelated updates
- **Overscan:** 5 rows above/below viewport for smooth scrolling
- **Fixed row height:** 40px enables predictable virtual scrolling

### Table Architecture
- `createColumnHelper<Track>()` for type-safe column definitions
- `useReactTable()` with core + sorting row models
- `useVirtualizer()` with scroll container ref
- Padding rows for virtual scrolling (paddingTop/paddingBottom)

### Data Flow
1. LibraryBrowser renders → useLibraryTracks fetches tracks
2. search_library("") returns all tracks
3. User types in FilterBar → setFilterQuery updates
4. useMemo filters allTracks by query
5. LibraryTable receives filtered tracks, virtualizes rendering

## Deviations from Plan

None - plan executed exactly as written.

## Testing Notes

### Manual Verification Needed
Run `npm run dev` and verify:
1. Navigate to /library, library browser page loads
2. Table shows all tracks with seven columns
3. Click column headers to sort (↑/↓ indicators appear)
4. Type in filter bar, table updates instantly
5. Dark mode styling works (toggle system theme)
6. No console errors

### Expected Behavior
- Empty library shows "No tracks in library"
- Search with no matches shows "No tracks match your search"
- Scrolling is smooth even with 10k+ tracks
- Sorting works on all columns (alphabetical/numeric)
- Filter matches partial strings (case-insensitive)

## Next Phase Readiness

### Enables Future Work
- **Plan 06-04 (Playlist Detail):** Can reuse LibraryTable for playlist track views
- **Plan 06-05 (Download Queue):** Can adapt FilterBar pattern for queue filtering
- **Later phases:** Table virtualization pattern established for all list views

### Dependencies
- Requires existing database with tracks (from Phase 1-3 imports)
- Tauri `search_library` command must be functional
- TanStack dependencies already installed in package.json

### Known Limitations
- No bulk selection yet (deferred to future plans)
- No context menu for tracks (deferred to future plans)
- No column width persistence (uses default widths)
- Date Added column assumes ISO string format from Rust

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Client-side filtering vs server-side | Instant responsiveness, simple architecture | Works well for <100k tracks, may need server-side later |
| 40px row height | Balances information density with readability | Standard table row height, works well with font sizes |
| Empty query returns all tracks | Simpler than separate "get all" command | Consistent with search UX pattern |
| Source-specific colors | Visual differentiation of track origins | Improves scannability, aligns with source branding |
| Sticky headers | Persistent column labels during scroll | Better UX for large datasets |

## Statistics

- **Files created:** 5
- **Files modified:** 1
- **Lines of code:** ~380
- **Tasks completed:** 3/3
- **Commits:** 3
  - f1920be: Formatter utilities + library tracks hook
  - 6b60a16: LibraryTable with TanStack virtualization
  - eddc8ad: FilterBar + LibraryBrowser page

**Duration:** 146 seconds (2m 26s)
