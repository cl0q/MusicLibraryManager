# Phase 6: Desktop UI - Research

**Researched:** 2026-02-04
**Domain:** Cross-platform desktop UI (Tauri + React + TypeScript + Tailwind)
**Confidence:** HIGH (Tauri/React core stack), MEDIUM (table library choice), MEDIUM (toast/state management patterns)

## Summary

Phase 6 implements a unified desktop UI for Music Library Manager using Tauri (Rust backend), React 19, TypeScript, and Tailwind CSS. The UI integrates five existing feature modules (PlaylistList, PlaylistDetail, SyncProfiles, SyncPreview, and new Downloads) into a persistent sidebar navigation pattern with real-time progress tracking and activity feeds.

The standard stack consists of:
- **Routing:** React Router in Framework Mode for persistent sidebar layout and nested routes
- **Tables:** TanStack React Table v8 (headless) with TanStack Virtual for virtualization, providing full control over styling and sorting
- **Notifications:** Sonner for toast notifications (minimal API, TypeScript-first, no setup required)
- **State Management:** Tauri's built-in state management (Rust) with React Context for local UI state, avoiding Redux/Zustand complexity for a single-window desktop app
- **Real-time Events:** Tauri's event system for backend→frontend push updates (progress, activity feeds)
- **Context Menus:** react-contexify for right-click menus with customizable styling
- **Audio Visualization:** wavesurfer.js for waveform/spectrogram display in track detail view
- **File Manager Integration:** Tauri's opener plugin for "reveal in file manager" functionality

**Primary recommendation:** Use React Router Framework Mode with TanStack React Table + TanStack Virtual for the library browser. Leverage Tauri's built-in state management for backend coordination and event system for real-time dashboard updates. Use Tauri's opener plugin for file manager integration.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| React | 19.2.0 | UI framework | Already in project, excellent Tauri integration, hooks-based for simplicity |
| React Router | 7.x (Framework Mode) | Persistent sidebar + nested routing | Official React routing library, built-in support for persistent layouts across route changes, type-safe in Framework Mode |
| TypeScript | ~5.9.3 | Type safety | Already in project, prevents runtime errors in command boundary |
| Tailwind CSS | 4.1.18 | Styling + dark mode | Already in project, built-in `dark:` variant support with `prefers-color-scheme` (default) |
| Vite | 7.2.4 | Build tool + HMR | Already in project, excellent for React development |
| Tauri | 2.x | Desktop framework + state management | Already in project, provides Rust backend integration, command system, event system, opener plugin |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| TanStack React Table | 8.x | Headless table logic | For library browser (sortable columns, no pre-styled components to override) |
| TanStack Virtual | latest | Virtualization for large tables | Render 10,000+ tracks without performance degradation |
| react-contexify | 5.x | Right-click context menu | Library browser row context menus (add to playlist, download, sync, reveal in file manager) |
| Sonner | latest | Toast notifications | Download completions, sync finished, error notifications (minimal 5KB, TypeScript-first) |
| wavesurfer.js | 7.x | Audio waveform + spectrogram | Track detail view for power users inspecting audio quality |
| @hello-pangea/dnd | 18.0.1 | Drag-drop playlist reordering | Playlist detail view (already in project) |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| TanStack React Table | Material React Table | Material React Table provides styled components out-of-box but couples your design to Material Design, harder to customize for clean/airy aesthetic |
| TanStack React Table | Glide Data Grid | Glide scales to millions of rows but adds 100KB+ bundle size; overkill unless handling 1M+ tracks |
| React Router | Wouter/TanStack Router | Wouter is lightweight but lacks persistent layout patterns; TanStack Router is newer/less proven in Tauri context |
| Sonner | react-toastify | react-toastify requires wrapper component setup; Sonner's provider-less API fits Tauri's flexibility better |
| Sonner | react-hot-toast | Both similar; Sonner better integrated with shadcn/ui ecosystem (future component expansion) |
| Tauri state | Redux/Zustand | Desktop apps with single window don't need global client-side store; Tauri's Rust state + Context works fine for UI-local state |
| wavesurfer.js | Web Audio API custom | Custom implementation requires 200+ lines of Canvas/FFT code; wavesurfer.js proven, maintained, includes spectrograms |

**Installation:**
```bash
npm install react-router react-contexify sonner wavesurfer.js
# TanStack libraries already resolve via monorepo or:
npm install @tanstack/react-table @tanstack/react-virtual
```

## Architecture Patterns

### Recommended Project Structure

```
ui/src/
├── App.tsx                          # Root layout with Tauri initialization
├── layouts/
│   ├── MainLayout.tsx               # Persistent sidebar + right content area
│   └── DetailLayout.tsx             # Full-width for detail views
├── pages/
│   ├── Dashboard.tsx                # Stats cards + activity feed
│   ├── LibraryBrowser.tsx           # Table with sortable columns + filter bar
│   ├── PlaylistList.tsx             # Existing component (import and wrap)
│   ├── PlaylistDetail.tsx           # Existing component (import and wrap)
│   ├── SyncProfiles.tsx             # Existing component (import and wrap)
│   ├── Downloads.tsx                # Queue view with progress bars
│   └── TrackDetail.tsx              # Spectrogram + waveform + metadata
├── components/
│   ├── Sidebar/
│   │   └── Sidebar.tsx              # 5-section navigation with icons
│   ├── LibraryTable/
│   │   ├── LibraryTable.tsx         # TanStack table + TanStack virtual
│   │   ├── FilterBar.tsx            # Search-as-you-type filter
│   │   └── RowContextMenu.tsx       # react-contexify for right-click
│   ├── StatusBar/
│   │   ├── StatusBar.tsx            # Bottom persistent status bar
│   │   └── StatusBarExpanded.tsx    # Expanded view (optional modal)
│   ├── Dashboard/
│   │   ├── StatsCards.tsx           # 5 stat displays
│   │   └── ActivityFeed.tsx         # Scrollable activity list with Tauri events
│   ├── Notifications/
│   │   └── ToastProvider.tsx        # Sonner setup with custom styling
│   └── TrackDetail/
│       ├── WaveformView.tsx         # wavesurfer.js integration
│       ├── MetadataPanel.tsx        # ffprobe output display
│       └── SpectrumView.tsx         # Spectrogram display
├── hooks/
│   ├── useLibraryTracks.ts          # Fetch tracks, manage search state
│   ├── useTauriCommand.ts           # Invoke Rust commands with error handling
│   ├── useTauriEvents.ts            # Listen to backend events, manage listeners
│   ├── useDownloadQueue.ts          # Listen to download progress events
│   └── useActivityFeed.ts           # Subscribe to activity stream events
├── types/
│   ├── library.ts                   # Track, Album, Artist types
│   ├── sync.ts                      # SyncProfile, DeviceProfile types
│   ├── downloads.ts                 # DownloadItem, TranscodeStep types
│   └── events.ts                    # Tauri event payloads (ActivityEvent, SyncEvent, etc.)
└── utils/
    ├── tauri-commands.ts            # Typed command wrappers
    └── formatter.ts                 # Format bytes, duration, etc.
```

### Pattern 1: React Router Framework Mode Layout

**What:** Root layout component wraps page content with persistent sidebar, maintains sidebar state across all routes.

**When to use:** Implement once at app root level to establish persistent navigation across all five sections.

**Example:**
```typescript
// src/App.tsx
import { RouterProvider, createBrowserRouter } from "react-router";
import MainLayout from "./layouts/MainLayout";
import Dashboard from "./pages/Dashboard";
import LibraryBrowser from "./pages/LibraryBrowser";
import PlaylistList from "./pages/PlaylistList";
import SyncProfiles from "./pages/SyncProfiles";
import Downloads from "./pages/Downloads";

const router = createBrowserRouter([
  {
    Component: MainLayout,
    children: [
      { path: "/", Component: Dashboard },
      { path: "/library", Component: LibraryBrowser },
      { path: "/playlists", Component: PlaylistList },
      { path: "/playlists/:id", Component: PlaylistDetail },
      { path: "/sync", Component: SyncProfiles },
      { path: "/downloads", Component: Downloads },
    ],
  },
]);

export default function App() {
  return <RouterProvider router={router} />;
}
```

MainLayout renders `<Sidebar />` on left (fixed width), `<Outlet />` on right (flex-grow).

### Pattern 2: TanStack React Table with Virtualization

**What:** Headless table hook provides sorting/filtering state; TanStack Virtual renders only visible rows.

**When to use:** Render library tracks (10,000+ items) without performance degradation. Replaces custom table implementation.

**Example:**
```typescript
// src/components/LibraryTable/LibraryTable.tsx
import { useReactTable, getCoreRowModel, getSortedRowModel } from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";

export function LibraryTable({ tracks }: { tracks: Track[] }) {
  const table = useReactTable({
    data: tracks,
    columns: libraryColumns, // Define: Title, Artist, Album, Duration, Source, Quality, Date Added
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  const { rows } = table.getRowModel();
  const virtualizer = useVirtualizer({ count: rows.length, estimateSize: 40 });
  const virtualRows = virtualizer.getVirtualItems();

  return (
    <div className="overflow-auto h-[600px]">
      <table className="w-full">
        <thead>
          {table.getHeaderGroups().map(group => (
            <tr key={group.id}>
              {group.headers.map(header => (
                <th
                  key={header.id}
                  onClick={header.column.getToggleSortingHandler()}
                  className="cursor-pointer select-none"
                >
                  {flexRender(header.column.columnDef.header, header.getContext())}
                  {header.column.getIsSorted() && <span>{header.column.getIsSorted() === "asc" ? "↑" : "↓"}</span>}
                </th>
              ))}
            </tr>
          ))}
        </thead>
        <tbody style={{ height: `${virtualizer.getTotalSize()}px` }}>
          {virtualRows.map(virtualRow => {
            const row = rows[virtualRow.index];
            return (
              <tr key={row.id} style={{ transform: `translateY(${virtualRow.start}px)` }}>
                {row.getVisibleCells().map(cell => (
                  <td key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</td>
                ))}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
```

### Pattern 3: Tauri Event System for Real-Time Updates

**What:** Rust backend emits events; React listens with `listen()`, updates state on event.

**When to use:** Dashboard activity feed, download progress bar, sync completion notifications.

**Example:**
```typescript
// src/hooks/useTauriEvents.ts
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";

type ActivityEvent = {
  type: "track_added" | "sync_complete" | "download_progress" | "error";
  data: Record<string, unknown>;
  timestamp: number;
};

export function useActivityFeed() {
  const [activities, setActivities] = useState<ActivityEvent[]>([]);

  useEffect(() => {
    let unlistens: UnlistenFn[] = [];

    async function setupListeners() {
      unlistens.push(
        await listen<ActivityEvent>("library:activity", event => {
          setActivities(prev => [event.payload, ...prev].slice(0, 50)); // Keep last 50
        })
      );
    }

    setupListeners();
    return () => unlistens.forEach(u => u());
  }, []);

  return activities;
}
```

Rust side emits:
```rust
// src-tauri/src/main.rs
app_handle.emit("library:activity", ActivityEvent {
  type: "track_added".to_string(),
  data: serde_json::json!({ "count": 42 }),
  timestamp: SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis(),
}).ok();
```

### Pattern 4: Right-Click Context Menu with react-contexify

**What:** Library table row → right-click → menu with actions (Add to Playlist, Download, Sync, etc.).

**When to use:** Implement per library table cell or row.

**Example:**
```typescript
// src/components/LibraryTable/RowContextMenu.tsx
import { Contextify, Item, contextMenu } from "react-contexify";
import "react-contexify/dist/ReactContextify.css";
import { invoke } from "@tauri-apps/api/core";

type ContextMenuProps = {
  track: Track;
  onAddToPlaylist: (playlistId: string) => void;
};

export function RowContextMenu({ track, onAddToPlaylist }: ContextMenuProps) {
  const handleDownload = async () => {
    await invoke("download_track", { trackId: track.id });
  };

  const handleSync = async () => {
    // Trigger sync modal or direct to SyncProfiles page
  };

  const handleRevealInFinder = async () => {
    await invoke("reveal_item_in_file_manager", { path: track.local_path });
  };

  return (
    <Contextify id={`track-${track.id}`}>
      <Item onClick={() => contextMenu.show({ event: event as any, id: `track-${track.id}` })}>
        <Item onClick={handleDownload}>Download</Item>
        <Item onClick={handleSync}>Sync to Device</Item>
        <Item onClick={() => onAddToPlaylist(track.id)}>Add to Playlist</Item>
        <Item onClick={handleRevealInFinder}>Reveal in File Manager</Item>
        <Item onClick={() => { /* navigate to detail view */ }}>View Details</Item>
      </Item>
    </Contextify>
  );
}
```

### Pattern 5: Toast Notifications with Sonner

**What:** Minimal, provider-less toast API for success/error feedback.

**When to use:** Download completion, sync finished, command errors, user feedback.

**Example:**
```typescript
// src/components/Notifications/ToastProvider.tsx
import { Toaster } from "sonner";

export function ToastProvider() {
  return <Toaster position="bottom-right" />;
}

// Usage anywhere in app:
import { toast } from "sonner";

// In a command invocation:
invoke("start_download", { trackId: "123" })
  .then(() => toast.success("Download started"))
  .catch(err => toast.error(`Download failed: ${err}`));
```

### Pattern 6: Tailwind Dark Mode with OS Preference

**What:** Use `prefers-color-scheme` media query (default); user's OS dark mode setting controls styling.

**When to use:** Apply once in `tailwind.config.js`; use `dark:` classes in components.

**Example:**
```typescript
// tailwind.config.js (already defaults to prefers-color-scheme)
export default {
  darkMode: "media", // or omit since it's default
  theme: {
    extend: {
      colors: {
        background: "hsl(0 0% 100%)",
        "background-dark": "hsl(0 0% 10%)",
      },
    },
  },
};

// Component usage:
<div className="bg-white dark:bg-gray-950 text-gray-900 dark:text-gray-50">
  Light on light, dark on dark
</div>
```

### Anti-Patterns to Avoid

- **Avoid Redux/Zustand for a single-window desktop app:** Tauri's Rust state + React Context handles coordination without global store boilerplate. Use Context only for UI-local state (sidebar expanded, modal open).
- **Avoid Material React Table if you want a clean aesthetic:** Material components force Material Design, making Apple Music/Notion aesthetic difficult. Use headless TanStack + custom CSS.
- **Avoid custom table virtualization:** Don't implement virtualization manually; TanStack Virtual is battle-tested and handles edge cases (scrollbar position, dynamic row heights).
- **Avoid storing sensitive state in Tauri events:** Events are JSON-serializable and pass through multiple layers; keep Rust backend as source of truth for auth, credentials.
- **Avoid direct DOM manipulation for Tauri window controls:** Use Tauri's webview APIs or CSS (no custom resizing logic).

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Table sorting/filtering state | Custom useState + useCallback | TanStack React Table | Handles edge cases: multi-column sort, filter combos, pagination, selection state; 100+ LOC if custom |
| Rendering 10k+ rows | Custom infinite scroll | TanStack Virtual | Precise scroll position, dynamic row heights, RTL support, mobile smoothness all built-in |
| Right-click menu UI | Custom `<div>` positioned on mousedown | react-contexify | Handles submenu positioning, keyboard nav, accessibility, click-outside dismissal |
| Dark mode toggle | Custom localStorage + useState | Tailwind `dark:` + prefers-color-scheme | Respects OS preference, no flash on page load, zero JavaScript required |
| Audio waveform rendering | Custom Web Audio API + Canvas | wavesurfer.js | FFT, spectrogram, playhead sync, zoom/pan, touch support, browser compatibility |
| Toast notifications | Custom Portals + animations | Sonner | Queue system, dismiss animations, stacking behavior, accessibility (ARIA), CSS-in-JS isolation |
| File manager "reveal" | Custom shell commands (open, xdg-open) | Tauri opener plugin | Permission-gated, cross-platform (macOS Finder, Windows Explorer, Linux file manager), maintains security boundary |

**Key insight:** Desktop UI patterns have mature libraries that handle cross-platform inconsistencies (window focus, system preferences, file manager APIs). Building custom implementations introduces platform-specific bugs and 2-3x more code.

## Common Pitfalls

### Pitfall 1: Trying to Share State Between React and Tauri Without Events

**What goes wrong:** Component state updates don't propagate to other windows; Rust state changes don't update React UI unless explicitly synced via events.

**Why it happens:** React state lives in the frontend webview; Rust state lives in backend. They're separate silos. Developers expect React Context to work across window boundaries, but it doesn't.

**How to avoid:** Use Tauri events for backend→frontend updates (status bar, activity feed, download progress). Use Tauri commands for frontend→backend (invoke a command, let Rust emit event on completion).

**Warning signs:** Clicking "Sync" in one window doesn't update progress in another window; dashboard doesn't refresh when background download finishes.

### Pitfall 2: Over-Virtualizing Tables

**What goes wrong:** Table scrolling feels janky or items flicker because virtualization estimates are wrong or row height calculation is off.

**Why it happens:** TanStack Virtual needs accurate row height estimates or actual dynamic heights. Fixed row heights work fine; variable heights need `estimateSize` calibration.

**How to avoid:** For library browser, use fixed-height rows (40px standard). Use TanStack Virtual's `getMeasurementCache()` only if you need variable heights (avoid unless necessary).

**Warning signs:** Scrolling jumps around; selected row disappears and reappears; blank rows appear during scroll.

### Pitfall 3: Coupling UI Layout to File Structure

**What goes wrong:** Move a page component to a different folder; all relative import paths break. Refactoring becomes tedious.

**Why it happens:** Deep folder nesting tempts relative imports (`../../components`); absolute paths are cleaner but require tsconfig setup.

**How to avoid:** Configure `tsconfig.json` with path alias:
```json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@components/*": ["src/components/*"],
      "@pages/*": ["src/pages/*"],
      "@hooks/*": ["src/hooks/*"],
      "@types/*": ["src/types/*"]
    }
  }
}
```

**Warning signs:** Refactoring causes cascading import failures; new team members struggle to import components correctly.

### Pitfall 4: Not Handling Tauri Command Errors

**What goes wrong:** Command fails (library DB error, file not found); UI doesn't show error; user thinks app is broken.

**Why it happens:** `invoke()` promises don't reject; they resolve with string error. Developers forget to check response.

**How to avoid:** Wrap `invoke()` in error-handling hook:
```typescript
export async function useTauriCommand<T>(cmd: string, payload?: Record<string, unknown>): Promise<Result<T>> {
  try {
    const result = await invoke<T>(cmd, payload);
    return { ok: true, data: result };
  } catch (err) {
    return { ok: false, error: err as string };
  }
}
```

**Warning signs:** Error toast never shows; user doesn't know operation failed; status bar stuck in "loading" state.

### Pitfall 5: Forgetting Permission Scopes for Tauri Plugins

**What goes wrong:** File manager reveal works in dev, fails in production release. Opener plugin permission not granted.

**Why it happens:** Tauri security model requires explicit permissions in `capabilities`. Development sometimes skips permission checks.

**How to avoid:** Add to `src-tauri/capabilities/main.json`:
```json
{
  "permissions": [
    "opener:allow-reveal-item-in-dir"
  ]
}
```

**Warning signs:** App works in dev (`tauri dev`), fails after `tauri build` and install; "permission denied" errors in production only.

### Pitfall 6: Blocking Tauri Event Listeners on Component Unmount

**What goes wrong:** Navigate away from page with event listener; listener still fires, calling `setActivityFeed()` on unmounted component. Memory leak warning in console.

**Why it happens:** Async `listen()` setup inside `useEffect` without cleanup.

**How to avoid:** Always clean up listeners:
```typescript
useEffect(() => {
  let unlistenFn: UnlistenFn | null = null;

  listen("library:activity", handler).then(unlisten => {
    unlistenFn = unlisten;
  });

  return () => {
    unlistenFn?.();
  };
}, []);
```

**Warning signs:** "Can't perform React state update on an unmounted component" warnings in console.

## Code Examples

Verified patterns from official sources:

### Library Browser Table Setup

```typescript
// Source: TanStack React Table v8 docs https://tanstack.com/table/latest
import { createColumnHelper, flexRender, getCoreRowModel, getSortedRowModel, useReactTable } from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";

type Track = {
  id: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  source: string;
  quality: string;
  date_added: number;
  local_path?: string;
};

const columnHelper = createColumnHelper<Track>();

const libraryColumns = [
  columnHelper.accessor("title", { header: "Title" }),
  columnHelper.accessor("artist", { header: "Artist" }),
  columnHelper.accessor("album", { header: "Album" }),
  columnHelper.accessor("duration", { header: "Duration", cell: info => formatDuration(info.getValue()) }),
  columnHelper.accessor("source", { header: "Source" }),
  columnHelper.accessor("quality", { header: "Quality" }),
  columnHelper.accessor("date_added", { header: "Date Added", cell: info => new Date(info.getValue()).toLocaleDateString() }),
];

export function LibraryBrowser() {
  const [tracks, setTracks] = useState<Track[]>([]);

  useEffect(() => {
    invoke<Track[]>("get_library_tracks").then(setTracks);
  }, []);

  const table = useReactTable({
    data: tracks,
    columns: libraryColumns,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  const { rows } = table.getRowModel();
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => tableContainerRef.current,
    estimateSize: () => 40,
  });

  const virtualRows = virtualizer.getVirtualItems();

  return (
    <div ref={tableContainerRef} className="overflow-auto h-full">
      <table className="w-full border-collapse">
        <thead className="sticky top-0 bg-white dark:bg-gray-900">
          {table.getHeaderGroups().map(headerGroup => (
            <tr key={headerGroup.id}>
              {headerGroup.headers.map(header => (
                <th
                  key={header.id}
                  onClick={header.column.getToggleSortingHandler()}
                  className="px-4 py-2 text-left font-semibold cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-800"
                >
                  <div className="flex items-center gap-2">
                    {flexRender(header.column.columnDef.header, header.getContext())}
                    {header.column.getIsSorted() === "asc" ? " ↑" : header.column.getIsSorted() === "desc" ? " ↓" : ""}
                  </div>
                </th>
              ))}
            </tr>
          ))}
        </thead>
        <tbody style={{ height: `${virtualizer.getTotalSize()}px` }}>
          {virtualRows.map(virtualRow => {
            const row = rows[virtualRow.index];
            return (
              <tr
                key={row.id}
                style={{ transform: `translateY(${virtualRow.start}px)` }}
                className="border-t border-gray-200 dark:border-gray-800 hover:bg-gray-50 dark:hover:bg-gray-900"
              >
                {row.getVisibleCells().map(cell => (
                  <td key={cell.id} className="px-4 py-2 text-sm">
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </td>
                ))}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}
```

### Toast Notifications Integration

```typescript
// Source: Sonner docs https://sonner.emilkowal.ski/
import { toast } from "sonner";
import { invoke } from "@tauri-apps/api/core";

export async function handleDownloadTrack(trackId: string) {
  try {
    const result = await invoke<{ status: "queued" }>("download_track", { trackId });
    toast.success(`Track queued for download`);
  } catch (error) {
    toast.error(`Failed to start download: ${error}`);
  }
}

export async function handleSyncToProfile(trackIds: string[], profileId: string) {
  const toastId = toast.loading("Syncing tracks...");
  try {
    await invoke("sync_tracks_to_profile", { trackIds, profileId });
    toast.success("Sync complete", { id: toastId });
  } catch (error) {
    toast.error(`Sync failed: ${error}`, { id: toastId });
  }
}
```

### Dashboard Activity Feed with Tauri Events

```typescript
// Source: Tauri event system docs https://v2.tauri.app/develop/calling-frontend/
import { useEffect, useState } from "react";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { formatDistanceToNow } from "date-fns";

type ActivityEntry = {
  id: string;
  type: "track_added" | "sync_completed" | "download_completed" | "error";
  message: string;
  timestamp: number;
  details?: Record<string, unknown>;
};

export function ActivityFeed() {
  const [activities, setActivities] = useState<ActivityEntry[]>([]);

  useEffect(() => {
    const unlisteners: UnlistenFn[] = [];

    async function setupListeners() {
      unlisteners.push(
        await listen<{ trackCount: number }>("library:tracks-added", event => {
          setActivities(prev => [
            {
              id: crypto.randomUUID(),
              type: "track_added",
              message: `Added ${event.payload.trackCount} tracks`,
              timestamp: Date.now(),
            },
            ...prev,
          ].slice(0, 50));
        })
      );

      unlisteners.push(
        await listen<{ status: string }>("sync:completed", event => {
          setActivities(prev => [
            {
              id: crypto.randomUUID(),
              type: "sync_completed",
              message: `Sync complete: ${event.payload.status}`,
              timestamp: Date.now(),
            },
            ...prev,
          ].slice(0, 50));
        })
      );
    }

    setupListeners();

    return () => unlisteners.forEach(u => u());
  }, []);

  return (
    <div className="space-y-2">
      {activities.map(activity => (
        <div key={activity.id} className={`p-3 rounded text-sm ${activity.type === "error" ? "bg-red-50 dark:bg-red-950" : "bg-blue-50 dark:bg-blue-950"}`}>
          <div className="font-medium">{activity.message}</div>
          <div className="text-xs text-gray-600 dark:text-gray-400">
            {formatDistanceToNow(activity.timestamp, { addSuffix: true })}
          </div>
        </div>
      ))}
    </div>
  );
}
```

### Tauri File Manager Reveal

```typescript
// Source: Tauri opener plugin https://v2.tauri.app/plugin/opener/
import { invoke } from "@tauri-apps/api/core";

export async function revealInFileManager(filePath: string): Promise<void> {
  try {
    // Tauri's opener plugin provides reveal_item_in_dir command
    await invoke("plugin:opener|reveal_item_in_dir", { path: filePath });
  } catch (error) {
    console.error("Failed to reveal file:", error);
    // Fallback: show error toast
  }
}

// Usage in context menu:
<Item onClick={() => revealInFileManager(track.local_path)}>
  Reveal in File Manager
</Item>
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Redux for all state | React Context + Tauri state | 2023+ | Smaller bundles, simpler code for desktop apps |
| react-table v7 | TanStack React Table v8 | 2022 | Full TypeScript rewrite, better API, headless design |
| react-hot-toast | Sonner | 2024+ | Provider-less API, smaller bundle, better DX |
| Custom waveform rendering | wavesurfer.js | Ongoing | FFT/spectrogram support, browser compatibility |
| Routing with nested components | React Router Framework Mode | 2023+ | Persistent layouts, type-safe routes, data loaders |
| OS preference detection | Tailwind prefers-color-scheme | 2021+ | No JavaScript needed, respects system setting |

**Deprecated/outdated:**
- **react-contextmenu:** Last update 6 years ago. Use react-contexify instead.
- **Material React Table v2:** Use v3+ which includes TanStack Virtual built-in.
- **Tauri v1:** Use Tauri v2 for improved Rust-JS bridge types, better event system, official plugins.

## Open Questions

Things that couldn't be fully resolved:

1. **Icon Library Choice for Sidebar**
   - What we know: Context mentions "icons + labels" in Spotify/Linear style; no library specified
   - What's unclear: Which icon library (react-icons, heroicons, phosphor, tabler-icons)?
   - Recommendation: Use [Phosphor Icons](https://phosphoricons.com/) (20+ weights, modern aesthetic, good TypeScript support) or [Heroicons](https://heroicons.com/) (Apple-designed, clean). Leave as Claude's Discretion; planner can choose.

2. **Download Queue Persistence**
   - What we know: Downloads page shows queue with history, failed items with retry buttons
   - What's unclear: Are failed downloads persisted to disk? Can user restart app and resume?
   - Recommendation: Implement in backend (Rust) using sled KV store or SQLite for resume-on-startup. Clarify with planner.

3. **Track Detail View — Spectrogram Performance**
   - What we know: Need spectrogram rendering of full track
   - What's unclear: For 10MB FLAC files, rendering full spectrogram may be slow; should we pre-compute or lazy-load?
   - Recommendation: Use wavesurfer.js's built-in spectrogram feature first; if performance issues arise, offload computation to backend (Rust audio processing) and cache results.

4. **Sidebar Collapse/Expand UX**
   - What we know: Sidebar is persistent; decision locked on "left sidebar with icons + labels"
   - What's unclear: Does sidebar collapse on small screens? Mobile responsive behavior?
   - Recommendation: Desktop-first for now (no mobile consideration in Phase 6); sidebar always visible. Leave responsive design for future phase.

5. **Tauri State Synchronization Across Multiple Windows**
   - What we know: Tauri has a state management API; Phase 6 is single-window
   - What's unclear: If user opens second window, should they share state? Library view in Window 1 and Downloads in Window 2?
   - Recommendation: Phase 6 assumes single window. If multi-window support is needed, use Tauri events to sync backend state across windows. Defer to future phase.

## Sources

### Primary (HIGH confidence)

- **Tauri v2 Official Documentation** — State management, event system, opener plugin permissions
  - https://v2.tauri.app/develop/state-management/
  - https://v2.tauri.app/plugin/opener/
  - https://v2.tauri.app/reference/javascript/api/namespaceevent/

- **React Router v7 Official Documentation** — Framework Mode, persistent layouts, routing patterns
  - https://reactrouter.com/start/modes
  - https://reactrouter.com/ (full docs)

- **TanStack React Table v8 Official Documentation** — Headless table API, sorting, virtualization patterns
  - https://tanstack.com/table/latest
  - https://tanstack.com/table/v8/docs/framework/react/react-table

- **TanStack Virtual Official Documentation** — Virtualization for large datasets
  - https://tanstack.com/virtual/latest

- **Tailwind CSS Official Documentation** — Dark mode with prefers-color-scheme (default)
  - https://tailwindcss.com/docs/dark-mode

- **Project Dependencies** — React 19.2.0, Tailwind 4.1.18, Vite 7.2.4, @hello-pangea/dnd 18.0.1 verified in ui/package.json

### Secondary (MEDIUM confidence)

- **Sonner Documentation & NPM** — Toast notification library, TypeScript-first, provider-less API
  - https://react-hot-toast.com/ (comparable alternative)
  - Top React notification libraries 2026 — https://knock.app/blog/the-top-notification-libraries-for-react

- **react-contexify GitHub & NPM** — Context menu library, right-click support
  - https://github.com/fkhadra/react-contexify

- **wavesurfer.js Official** — Audio waveform and spectrogram visualization
  - https://wavesurfer.xyz/

- **Tauri React Template (Community)** — Production-ready example of Tauri + React + TypeScript setup
  - https://github.com/dannysmith/tauri-template

### Tertiary (MEDIUM confidence - WebSearch with verification)

- **React state management for Tauri 2026** — Zustand/Jotai mentioned but verified that single-window desktop apps don't need global stores
  - https://medium.com/@ssamuel.sushant/unifying-state-across-frontend-and-backend-in-tauri-a-detailed-walkthrough-3b73076e912c

- **React table library comparison 2026** — TanStack React Table, Material React Table, Glide Data Grid listed; TanStack chosen for headlessness
  - https://reactscript.com/best-data-table/
  - https://www.dronahq.com/top-react-tables/

- **Tauri event system patterns** — Event system confirmed for real-time frontend updates, not for high-throughput data
  - https://tauritutorials.com/blog/tauri-events-basics

## Metadata

**Confidence breakdown:**
- **Standard stack (HIGH):** Tauri, React, TypeScript, Tailwind already in project; TanStack React Table v8 is official standard for headless tables; React Router v7 is current version. All verified with official docs.
- **Architecture patterns (MEDIUM-HIGH):** React Router Framework Mode recommended by official docs for persistent layouts. TanStack Virtual integrated via official docs. Tauri events documented. Context menu and toast libraries are 2026-current and verified via GitHub/npm.
- **Pitfalls (MEDIUM-HIGH):** Common Tauri patterns from official docs and community tutorials; React pitfalls (unmounted component warnings, virtualization edge cases) are well-documented.
- **Open questions (LOW):** Icon library choice left as discretion (multiple good options). Download persistence and spectrogram performance need backend coordination (unclear from Phase 6 scope alone).

**Research date:** 2026-02-04
**Valid until:** 2026-03-06 (30 days; React/Tauri stable, libraries slow-moving)

**Special notes:**
- The roadmap mentions "PySide6" but project has already migrated to Tauri + React. This research assumes that migration is complete and locked.
- Existing Phase 3-5 components (PlaylistList, PlaylistDetail, SyncProfiles, SyncPreview) are integrated as-is into new MainLayout. No refactoring of those components is necessary in Phase 6.
- Dark mode defaults to OS preference via Tailwind's `prefers-color-scheme`. Manual toggle can be added in Phase 7 if needed.
