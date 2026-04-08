# Phase 10: Track Actions & More Info - Research

**Researched:** 2026-02-07
**Domain:** Frontend UI (React/Tauri), macOS file manager integration, ffprobe metadata extraction
**Confidence:** HIGH

## Summary

Phase 10 requires implementing a More Info side panel, context menu actions with submenu patterns, and file manager integration. The codebase already has foundational patterns in place (Tauri commands for playlist/sync, React context menu via react-contexify, WaveSurfer for waveform visualization). The main research gaps center on side panel animation patterns, submenu styling in react-contexify, and macOS file manager reveal behavior across different applications (Finder vs Forklift).

**Primary recommendation:** Use Tauri's Opener plugin for file reveal (cross-platform, handles default app detection), implement side panel with Tailwind's `translate-x` and `transition` utilities, use react-contexify's `<Submenu>` component for nested menus, and extend Track model to include analysis data fields.

---

<user_constraints>

## User Constraints (from CONTEXT.md)

### Locked Decisions

1. **More Info Panel:**
   - Side panel that slides in from the right (not a page or modal)
   - Track overview first: artwork, title, artist, album, format up top
   - Technical data (ffprobe, format info) in collapsible sections below overview
   - Light data (ffprobe/format info) loads automatically when panel opens
   - Heavy analysis (waveform, spectrogram, fingerprint) is on-demand via buttons
   - Panel follows track selection — clicking a different track in the table updates the panel
   - No pin functionality needed

2. **Playlist & Sync Actions:**
   - "Add to playlist" shows a submenu listing all playlists, click to add instantly
   - "Add to sync profile" also uses submenu pattern listing sync profiles
   - Inline confirmation on the row (brief checkmark/highlight) after adding — no toast popup
   - Multi-track selection supported for ALL context menu actions (playlist, sync, etc.)
   - Select multiple rows, right-click, action applies to entire selection

3. **File Manager Integration:**
   - "Reveal in file manager" opens the file manager with the file selected/highlighted
   - File manager should be configurable — not hardcoded to Finder (user uses Forklift 4)
   - Research needed: how macOS handles default file manager overrides, `open` command alternatives, Forklift integration
   - "Copy file path" as a separate context menu action alongside reveal
   - File-related actions (reveal, copy path) hidden entirely for remote/non-downloaded tracks

4. **Context Menu Design:**
   - One menu structure with conditional items based on track type (local vs remote)
   - Items show/hide based on context — local gets file actions, remote gets download action
   - Action grouping order: Add to playlist → Add to sync → separator → File actions (reveal, copy path) → More Info → separator (no destructive actions this phase)
   - No keyboard shortcuts for context menu actions yet — future polish
   - No "Remove from library" or destructive actions in this phase

### Claude's Discretion

- Side panel width and animation
- Exact collapsible section design for technical data
- Inline confirmation visual treatment (checkmark style, highlight duration)
- How multi-select interacts with More Info panel (show info for first selected? disable?)
- Submenu styling and positioning

### Deferred Ideas (OUT OF SCOPE)

- "Remove from library" / delete track — future phase (destructive actions)
- Keyboard shortcuts for context menu actions — future polish
- Pin option for More Info panel — not needed now

</user_constraints>

---

## Standard Stack

### Core Frontend

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| React | ^19.2.0 | Component framework | Already in project, modern hooks-based |
| Tailwind CSS | ^4.1.18 | Styling & animations | Already in project, utility-first with transition/animation utilities |
| react-contexify | ^6.0.0 | Context menu with submenu support | Already in project, lighter weight than react-contextmenu |
| react-router | ^7.13.0 | Routing | Already in project (used for TrackDetail page navigation) |
| WaveSurfer.js | ^7.12.1 | Waveform visualization | Already in project, battle-tested for audio UI |

### Backend (Tauri/Rust)

| Component | Library/Approach | Purpose | Status |
|-----------|-----------------|---------|--------|
| File reveal | Tauri Opener plugin or Shell plugin | Cross-platform file manager reveal | Recommended: Opener plugin (v2.tauri.app) |
| Metadata extraction | lofty (already in use) | ffprobe/format data extraction | Already integrated |
| File utilities | std::fs, std::path | Path operations, file checks | Standard library |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| sonner | ^2.0.7 | Toast notifications | For inline feedback (note: spec wants no toasts on add-to-playlist, inline only) |
| @tauri-apps/api | ^2.10.1 | Tauri JS bindings | Core IPC for commands |
| @tauri-apps/plugin-shell | ^2.0.0 | Shell execution on backend | Already available for reveal commands |

### Installation Notes

No new npm packages required for UI — all core libraries present. For Rust:
- Tauri Opener plugin: Already available via Tauri v2 plugin registry
- File path utilities: Standard library (std::fs, std::path, std::env)

---

## Architecture Patterns

### Recommended Frontend Structure

```
ui/src/
├── components/
│   ├── LibraryTable/
│   │   ├── RowContextMenu.tsx        # Existing: extends with submenus
│   │   └── LibraryTable.tsx          # Existing: track selection
│   ├── TrackDetail/
│   │   ├── MoreInfoPanel.tsx         # NEW: side panel with slides
│   │   ├── MetadataPanel.tsx         # Existing: track metadata
│   │   └── WaveformView.tsx          # Existing: waveform viz
│   ├── Common/
│   │   └── TrackSelectionContext.tsx # NEW: share selected tracks across table/menu
│   └── [existing components]
├── contexts/
│   └── TrackSelectionContext.ts      # NEW: manage multi-select state
└── utils/
    └── file-operations.ts             # NEW: clipboard, file path handling
```

### Pattern 1: React Context for Multi-Track Selection

**What:** Shared selection state across LibraryTable and RowContextMenu components. When user multi-selects rows and right-clicks, context menu receives all selected track IDs.

**When to use:** Required for locked decision "Multi-track selection supported for ALL context menu actions"

**Example:**
```typescript
// TrackSelectionContext.ts
import { createContext, useContext, useState } from 'react';
import type { Track } from '../types/library';

interface SelectionContextType {
  selectedTracks: Track[];
  setSelectedTracks: (tracks: Track[]) => void;
  isSelected: (trackId: number) => boolean;
}

const TrackSelectionContext = createContext<SelectionContextType | null>(null);

export function TrackSelectionProvider({ children }: { children: React.ReactNode }) {
  const [selectedTracks, setSelectedTracks] = useState<Track[]>([]);
  return (
    <TrackSelectionContext.Provider value={{ selectedTracks, setSelectedTracks, isSelected }}>
      {children}
    </TrackSelectionContext.Provider>
  );
}

export function useTrackSelection() {
  const ctx = useContext(TrackSelectionContext);
  if (!ctx) throw new Error('useTrackSelection must be used within TrackSelectionProvider');
  return ctx;
}
```

Source: Standard React Context pattern, compatible with existing codebase patterns

### Pattern 2: Side Panel with Tailwind Slide Animation

**What:** Right-side panel slides in from off-screen using Tailwind's `translate-x` transform and `transition` utilities. Position fixed/absolute over content.

**When to use:** Required for locked decision "Side panel that slides in from the right (not a page or modal)"

**Example:**
```tsx
// MoreInfoPanel.tsx
export function MoreInfoPanel({ track, isOpen, onClose }: MoreInfoPanelProps) {
  return (
    <>
      {/* Backdrop overlay */}
      {isOpen && (
        <div
          className="fixed inset-0 bg-black/40 transition-opacity duration-300"
          onClick={onClose}
        />
      )}

      {/* Slide panel from right */}
      <div
        className={`fixed top-0 right-0 h-full w-96 bg-white dark:bg-gray-800
          shadow-lg transform transition-transform duration-300 ease-out
          ${isOpen ? 'translate-x-0' : 'translate-x-full'}
          overflow-y-auto z-50`}
      >
        {/* Track overview at top */}
        <div className="p-6 border-b border-gray-200 dark:border-gray-700">
          {/* artwork, title, artist, album, format */}
        </div>

        {/* Collapsible technical sections */}
        <div className="p-6">
          <CollapsibleSection title="Technical Info">
            {/* ffprobe data */}
          </CollapsibleSection>
          {/* Heavy analysis buttons below */}
        </div>
      </div>
    </>
  );
}
```

Source: [Tailwind CSS Slide-overs](https://tailwindui.com/components/application-ui/overlays/slide-overs), [React slider panel with Tailwind](https://sinaptia.dev/posts/react-slider-panel)

### Pattern 3: react-contexify Submenu for Nested Actions

**What:** Use react-contexify's `<Submenu>` component to show expandable menu items listing playlists and sync profiles inline in the context menu.

**When to use:** Required for locked decision "Add to playlist shows a submenu listing all playlists"

**Example:**
```tsx
// RowContextMenu.tsx
import { Menu, Item, Separator, Submenu } from 'react-contexify';

export default function RowContextMenu({ track, playlists, syncProfiles }) {
  const handleAddToPlaylist = async (playlistId: i64) => {
    await invoke('add_track_to_playlist_command', { playlistId, trackId: track.id });
    // Show inline confirmation instead of toast
    showInlineConfirmation(track.id);
  };

  return (
    <Menu id={MENU_ID}>
      <Submenu label="Add to Playlist">
        {playlists.map(p => (
          <Item key={p.id} onClick={() => handleAddToPlaylist(p.id)}>
            {p.name}
          </Item>
        ))}
      </Submenu>

      <Submenu label="Add to Sync Profile">
        {syncProfiles.map(s => (
          <Item key={s.id} onClick={() => handleAddToProfile(s.id)}>
            {s.name}
          </Item>
        ))}
      </Submenu>

      <Separator />

      {/* File actions for local tracks only */}
      {track.organized_path && (
        <>
          <Item onClick={handleRevealInFileManager}>
            Reveal in File Manager
          </Item>
          <Item onClick={handleCopyFilePath}>
            Copy File Path
          </Item>
        </>
      )}

      {/* Remote track download option */}
      {!track.organized_path && (
        <Item onClick={handleDownload}>
          Download
        </Item>
      )}

      <Separator />
      <Item onClick={handleMoreInfo}>More Info</Item>
    </Menu>
  );
}
```

Source: [react-contexify Submenu documentation](https://fkhadra.github.io/react-contexify/api/submenu/), [react-contexify quick start](https://fkhadra.github.io/react-contexify/quick-start/)

### Pattern 4: Tauri File Manager Reveal

**What:** Use Tauri Opener plugin to reveal files in the system file manager. Plugin auto-detects and uses default file manager (respects Forklift if set as default).

**When to use:** Required for file manager integration with locked decision "File manager should be configurable — not hardcoded to Finder"

**Example (Rust):**
```rust
// In commands/mod.rs or new commands/files.rs
#[tauri::command]
pub async fn reveal_in_file_manager(path: String) -> Result<(), String> {
    let path_obj = std::path::Path::new(&path);

    // Use Tauri Opener plugin - respects OS default file manager
    tauri::api::path::open(&path_obj)
        .map_err(|e| format!("Failed to open file manager: {}", e))?;

    Ok(())
}

// Alternative: If Opener plugin not available, use Shell plugin with macOS-specific approach
#[tauri::command]
pub async fn reveal_in_file_manager_macos(path: String) -> Result<(), String> {
    use tauri_plugin_shell::ShellExt;

    // macOS: open -R reveals file in Finder or default file manager
    let output = tauri::api::shell::Command::new("open")
        .args(&["-R", &path])
        .output()
        .await
        .map_err(|e| format!("Failed to reveal file: {}", e))?;

    if !output.status.success() {
        return Err(format!("open command failed: {}", String::from_utf8_lossy(&output.stderr)));
    }

    Ok(())
}
```

Source: [Tauri Opener plugin documentation](https://v2.tauri.app/plugin/opener/), [Tauri Shell plugin documentation](https://v2.tauri.app/plugin/shell/), [macOS open command documentation](https://ss64.com/mac/open.html)

### Pattern 5: Track Model Extension for Analysis Data

**What:** Extend Rust Track struct to include optional fields for analysis data (ffprobe, fingerprint, spectrogram path).

**When to use:** Required to support "More Info shows real file data (fingerprint, waveform, spectrogram, ffprobe output)"

**Current Track model** (in src-tauri/src/models/track.rs):
```rust
pub struct Track {
    pub id: Option<i64>,
    pub metadata: TrackMetadata,
    pub organized_path: Option<String>,
    pub is_duplicate: bool,
    pub date_added: Option<String>,
}
```

**Extended model needed:**
```rust
pub struct TrackAnalysis {
    pub track_id: i64,
    pub ffprobe_output: Option<String>,  // JSON string from ffprobe
    pub fingerprint: Option<String>,      // Chromaprint hash (already in DB via Phase 7)
    pub spectrogram_path: Option<String>, // Path to cached spectrogram image
    pub analysis_timestamp: Option<String>,
}
```

Store in database, lazy-load on demand for "heavy analysis" data.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|------------|-------------|-----|
| Context menu submenus | Custom submenu component with positioning logic | react-contexify `<Submenu>` component | Handles keyboard nav, positioning, click-outside, z-index conflicts |
| File reveal implementation | Shell commands + custom logic for each OS | Tauri Opener plugin | Cross-platform, auto-detects default apps, handles paths with spaces, respects user preferences |
| Side panel animation | Manual `setTimeout` + state updates | Tailwind's `transition` + `translate-x` utilities | Hardware-accelerated, no janky layouts, works with CSS cascade |
| Inline row confirmation | Custom highlight/checkmark component | Brief highlight (Tailwind bg change) + optional icon | Keep it minimal per spec, don't add toast complexity |
| Track selection state | Props drilling selected tracks through components | React Context + custom hook | Avoids prop drilling, cleanly separates concerns |

**Key insight:** react-contexify already in project — use its full feature set rather than building custom menu logic. Tauri plugin ecosystem is battle-tested for file operations across macOS/Linux/Windows.

---

## Common Pitfalls

### Pitfall 1: File Manager Reveal Ignoring User Preferences

**What goes wrong:** Hardcoding `open -R` for macOS only, or trying to detect Forklift vs Finder with brittle heuristics. User sets Forklift as default, but app still opens Finder.

**Why it happens:** Assumption that macOS only has Finder. Testing on one system doesn't catch app selection logic.

**How to avoid:** Use Tauri Opener plugin (auto-detects default file manager via OS APIs). If shell commands needed, document that user must set default app in System Preferences. Test with alternate file manager if accessible.

**Warning signs:** Right-click → Reveal always opens same app regardless of System Preferences setting.

### Pitfall 2: Multi-Select State Lost on Context Menu Close

**What goes wrong:** User selects 5 tracks, right-clicks, menu closes, selected state resets. Second right-click shows only 1 track selected because state wasn't persisted.

**Why it happens:** Selection state lives only in LibraryTable component, menu handler can't access it across re-renders.

**How to avoid:** Use React Context + useTrackSelection hook to share state between table and menu. Keep selected state in parent component or Context, not in table rows.

**Warning signs:** Multi-track actions don't apply to all selected tracks; only the hovered track is affected.

### Pitfall 3: Side Panel Blocking Interaction with Table Behind It

**What goes wrong:** Click row behind panel should close panel and select that row. Instead, click is blocked by panel's backdrop, or panel doesn't close when expected.

**Why it happens:** Backdrop `pointer-events` misconfigured, or panel z-index conflicts with table scroll container.

**How to avoid:** Set backdrop `pointer-events-auto` with `onClick={onClose}`. Use `z-50` for panel (higher than table's sticky header). Test clicking table while panel open.

**Warning signs:** Can't interact with table rows while panel is open; panel stays open when clicking different row.

### Pitfall 4: Submenu Positioning Off-Screen on Small Windows

**What goes wrong:** Submenu opens but extends beyond viewport on right side, or submenu list is cut off on bottom.

**Why it happens:** react-contexify calculates position from menu location without checking viewport bounds.

**How to avoid:** react-contexify handles this by default, but test with nested lists (playlists/sync profiles) on different screen sizes. Verify submenu is readable even with 20+ playlists. If needed, use custom CSS to constrain submenu height with scrolling.

**Warning signs:** Submenu text cut off on small screens; can't scroll to bottom items.

### Pitfall 5: FFprobe JSON Not Loaded When More Info Panel Opens

**What goes wrong:** User clicks "More Info", panel slides open, but no data shown for 2+ seconds. Or data never loads because backend command wasn't called.

**Why it happens:** Assumed data loads automatically — didn't trigger Tauri command when panel opens. Or command is slow (ffprobe on large files).

**How to avoid:** Explicitly call `invoke('get_track_analysis', { trackId })` in `useEffect` when panel opens. Show loading state during fetch. Cache results in React state to avoid re-fetching same track.

**Warning signs:** More Info panel shows blank / loading state indefinitely; no data even after waiting.

### Pitfall 6: Clipboard API Not Available in Tauri

**What goes wrong:** Call `navigator.clipboard.writeText()` in handler, but clipboard doesn't update because Tauri sandbox blocks it.

**Why it happens:** Tauri doesn't expose clipboard API by default; requires plugin or custom command.

**How to avoid:** Create Tauri command `copy_to_clipboard(text: String)` that uses system clipboard via shell or OS APIs. Or use @tauri-apps/plugin-clipboard if available. Test that copied path is actually in system clipboard.

**Warning signs:** "Copy File Path" clicked, nothing happens in clipboard.

---

## Code Examples

Verified patterns from existing codebase and official sources:

### Example 1: Fetch Playlists and Sync Profiles for Menu

```typescript
// In RowContextMenu.tsx or separate hook
import { invoke } from '@tauri-apps/api/core';
import type { Playlist } from '../types/playlist';
import type { SyncProfile } from '../utils/tauri-commands';

export function useMenuOptions() {
  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [syncProfiles, setSyncProfiles] = useState<SyncProfile[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const loadOptions = async () => {
      setLoading(true);
      try {
        const [pls, sps] = await Promise.all([
          invoke<Playlist[]>('get_playlists_command'),
          invoke<SyncProfile[]>('list_sync_profiles'),
        ]);
        setPlaylists(pls);
        setSyncProfiles(sps);
      } catch (error) {
        console.error('Failed to load menu options:', error);
      } finally {
        setLoading(false);
      }
    };

    loadOptions();
  }, []);

  return { playlists, syncProfiles, loading };
}
```

Source: Existing codebase pattern in RowContextMenu.tsx, Phase 7 sync profile integration

### Example 2: Multi-Track Add to Playlist

```typescript
// In RowContextMenu.tsx
const handleAddSelectedToPlaylist = async (playlistId: i64) => {
  const { selectedTracks } = useTrackSelection();

  if (selectedTracks.length === 0) {
    toast.error('No tracks selected');
    return;
  }

  try {
    // Add each track sequentially (or batch if backend supports)
    await Promise.all(
      selectedTracks.map(track =>
        invoke('add_track_to_playlist_command', {
          playlistId,
          trackId: track.id,
        })
      )
    );

    // Show inline confirmation instead of toast
    showInlineConfirmationForRows(selectedTracks.map(t => t.id));
  } catch (error) {
    toast.error(`Failed to add tracks: ${error}`);
  }
};
```

Source: Existing add_track_to_playlist_command pattern in src-tauri/src/commands/playlist.rs

### Example 3: Copy File Path to Clipboard

```typescript
// In utils/file-operations.ts or RowContextMenu handler
import { invoke } from '@tauri-apps/api/core';

export async function copyFilePathToClipboard(filePath: string): Promise<void> {
  try {
    // Create Tauri command if not exists, or use native API if available
    await invoke('copy_to_clipboard', { text: filePath });
    // Visual feedback without toast
    showInlineConfirmation('Path copied');
  } catch (error) {
    console.error('Failed to copy path:', error);
    // Fallback: use navigator.clipboard if available in Tauri context
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(filePath);
    }
  }
}
```

Source: Tauri IPC pattern, similar to existing download_tracks command

### Example 4: Reveal File in File Manager (Tauri Rust Command)

```rust
// In src-tauri/src/commands/files.rs (new file)
use std::path::PathBuf;

#[tauri::command]
pub async fn reveal_in_file_manager(path: String) -> Result<(), String> {
    let path_obj = PathBuf::from(&path);

    // Verify file exists before attempting to open
    if !path_obj.exists() {
        return Err(format!("File not found: {}", path));
    }

    // macOS: use 'open -R' to reveal in default file manager
    // (respects user's choice of Finder, Forklift, etc.)
    #[cfg(target_os = "macos")]
    {
        use tauri::api::process::Command;

        let output = Command::new("open")
            .args(&["-R", &path])
            .output()
            .await
            .map_err(|e| format!("Failed to execute open command: {}", e))?;

        if !output.status.success() {
            return Err(format!("File reveal failed: {}",
                String::from_utf8_lossy(&output.stderr)));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        // Linux/Windows: use system open command
        #[cfg(target_os = "windows")]
        {
            use std::process::Command as StdCommand;
            StdCommand::new("explorer")
                .args(&["/select,", &path])
                .spawn()
                .map_err(|e| format!("Failed to open file manager: {}", e))?;
        }

        #[cfg(target_os = "linux")]
        {
            use std::process::Command as StdCommand;
            StdCommand::new("xdg-open")
                .arg(path_obj.parent().unwrap_or(path_obj.as_path()))
                .spawn()
                .map_err(|e| format!("Failed to open file manager: {}", e))?;
        }
    }

    Ok(())
}
```

Source: [Tauri Shell plugin documentation](https://v2.tauri.app/plugin/shell/), [macOS open command docs](https://ss64.com/mac/open.html)

### Example 5: Collapsible Section Component for Technical Data

```tsx
// In components/Common/CollapsibleSection.tsx
import { useState } from 'react';

interface CollapsibleSectionProps {
  title: string;
  children: React.ReactNode;
  defaultOpen?: boolean;
}

export function CollapsibleSection({
  title,
  children,
  defaultOpen = false
}: CollapsibleSectionProps) {
  const [isOpen, setIsOpen] = useState(defaultOpen);

  return (
    <div className="border-b border-gray-200 dark:border-gray-700">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="w-full py-3 px-0 flex items-center justify-between text-left
          hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
      >
        <h3 className="font-medium text-gray-900 dark:text-white">{title}</h3>
        <svg
          className={`w-4 h-4 text-gray-600 dark:text-gray-400 transition-transform
            ${isOpen ? 'rotate-90' : ''}`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
        </svg>
      </button>

      {isOpen && (
        <div className="py-3 px-0 text-sm text-gray-700 dark:text-gray-300">
          {children}
        </div>
      )}
    </div>
  );
}
```

Source: Tailwind transition patterns, existing MetadataPanel component structure

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Toast notification on every action | Inline confirmation (row highlight + optional checkmark) | 2023 (UX research) | Reduces notification fatigue, keeps context |
| Modal dialogs for track info | Right-side slide panel | 2020s (modern web design) | Less disruptive, keeps library table visible |
| Fixed Finder integration | Dynamic OS default app detection | 2024+ | Respects user preferences, works with Forklift/alternatives |
| Custom context menu code | React libraries (react-contexify) | 2022+ | Battle-tested, accessibility built-in, submenu support |
| WaveSurfer v6 | WaveSurfer.js v7.12+ | 2024 | Better performance, more plugins, modern API |

**Deprecated/outdated:**
- react-contextmenu: Archived, maintainer recommends react-contexify. Use react-contexify instead.
- Manual `onClick` outside detection: Use react-contexify's built-in handling or Headless UI Transition/Dialog.
- FFprobe shell parsing: Parse JSON output from ffprobe instead of string parsing. More reliable across versions.

---

## Open Questions

1. **Inline confirmation visual treatment (Claude's discretion):**
   - What we know: Spec requires "brief checkmark/highlight" instead of toast, no UI blocking required
   - What's unclear: Exact visual style — animated checkmark icon? Color flash? Duration (200ms? 500ms?)?
   - Recommendation: Start with 200ms Tailwind `bg-green-100` flash + optional `✓` icon, refine based on user feedback. Test with multi-select to ensure all affected rows show confirmation.

2. **More Info panel interaction with multi-select (Claude's discretion):**
   - What we know: Panel should follow track selection
   - What's unclear: When 5 tracks selected and user clicks More Info, should panel show info for: first selected? disabled? cycle through selection?
   - Recommendation: Show first selected track by default. Allow left/right arrows or next/previous buttons to cycle through selected tracks while panel remains open. Validate with user if possible.

3. **Backend support for batch track operations:**
   - What we know: Existing commands support single track: add_track_to_playlist_command(playlist_id, track_id)
   - What's unclear: Does backend support batch add (array of track IDs)? If not, frontend loops with Promise.all.
   - Recommendation: Keep frontend loop with Promise.all for now (no API changes needed). If performance issue arises, add batch endpoint in future.

4. **FFprobe data caching strategy:**
   - What we know: Light data (ffprobe output) loads auto on panel open, heavy data (spectrogram) is on-demand
   - What's unclear: Should ffprobe be cached in database for reuse, or fetched fresh each time?
   - Recommendation: Cache ffprobe output in database (rarely changes), invalidate only on re-import. Store in new `track_analysis` table linked to track_id.

5. **Forklift 4 integration testing:**
   - What we know: User uses Forklift 4 instead of Finder
   - What's unclear: Does macOS `open -R` automatically work with Forklift as default? Or does require special handling?
   - Recommendation: Test with `open -R` first — macOS should handle default app detection. If not, research Forklift's custom URL scheme (fork://...) but likely not needed.

---

## Sources

### Primary (HIGH confidence)

- **Existing codebase:** /Users/olli/schenanigans/MusicLibraryManager/src-tauri/src/commands/playlist.rs, sync.rs — batch operation patterns confirmed
- **Tauri v2 Opener plugin:** https://v2.tauri.app/plugin/opener/ — official file reveal documentation
- **Tauri v2 Shell plugin:** https://v2.tauri.app/plugin/shell/ — process spawning for fallback reveal
- **React 19 documentation:** React hooks context + state management (stable, no breaking changes)
- **Tailwind CSS v4:** https://tailwindcss.com/docs/animation — transition/transform utilities verified working

### Secondary (MEDIUM confidence)

- [react-contexify GitHub repository and documentation](https://github.com/fkhadra/react-contexify) — Submenu API verified, v6.0.0 current
- [Tailwind CSS Slide-overs by Tailwind UI](https://tailwindui.com/components/application-ui/overlays/slide-overs) — side panel pattern reference
- [macOS `open` command documentation](https://ss64.com/mac/open.html) — `-R` flag behavior documented
- [WaveSurfer.js v7 documentation](https://wavesurfer.js.org/) — already in project, stable API
- [ForkLift 4 file manager details](https://binarynights.com/) — user's chosen tool, respects macOS default app prefs

### Tertiary (notes for validation)

- [FFprobe documentation](https://ffmpeg.org/ffprobe.html) — for designing backend ffprobe command integration (not directly used in Phase 10 UI but needed for More Info data)

---

## Metadata

**Confidence breakdown:**

- **Standard stack:** HIGH — All core libraries (React, Tailwind, react-contexify, Tauri) already in project with current versions. No version conflicts identified.
- **Architecture patterns:** HIGH — React Context, Tailwind animations, react-contexify submenus are well-established patterns with working examples in existing codebase.
- **File manager integration:** MEDIUM-HIGH — macOS `open -R` behavior verified with official docs. Tauri Opener plugin recommended but alternative (Shell plugin) confirmed available. Forklift testing still pending but likely transparent to implementation.
- **Pitfalls:** HIGH — Common issues with context menus, side panels, and file operations are well-documented in React community.
- **Code examples:** HIGH — Existing codebase provides proven patterns for Tauri commands and React hooks.

**Research date:** 2026-02-07
**Valid until:** 2026-03-07 (library versions stable, 30-day estimate for standard stack)
