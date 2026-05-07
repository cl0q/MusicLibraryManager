import { useState, useCallback, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import FolderTree from "../components/FolderTree/FolderTree";
import FolderTreeBanner from "../components/FolderTree/FolderTreeBanner";
import FolderTreeContextMenu from "../components/FolderTree/FolderTreeContextMenu";
import LibraryTable from "../components/LibraryTable/LibraryTable";
import { useLibraryMount } from "../contexts/LibraryMountContext";
import { getFolderTracks, getAppSetting, setAppSetting } from "../utils/tauri-commands";
import type { Track } from "../types/library";

interface TreeState {
  expanded: string[];
  lastSelected: string | null;
  showDotPrefixed: boolean;
}

export default function Folders() {
  const { isLibraryAvailable } = useLibraryMount();
  const [selectedFolder, setSelectedFolder] = useState<string | null>(null);
  const [tracks, setTracks] = useState<Track[]>([]);
  const [loadingTracks, setLoadingTracks] = useState(false);
  const [showDotPrefixed, setShowDotPrefixed] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);
  const [contextMenu, setContextMenu] = useState<{
    folderPath: string;
    position: { x: number; y: number };
  } | null>(null);

  // Load persisted tree state on mount (D-17)
  useEffect(() => {
    getAppSetting("folders.tree_state")
      .then((raw) => {
        if (raw) {
          try {
            const state: TreeState = JSON.parse(raw);
            if (state.lastSelected) {
              setSelectedFolder(state.lastSelected);
              getFolderTracks(state.lastSelected)
                .then(setTracks)
                .catch((err) => console.error("Failed to load folder tracks:", err));
            }
            setShowDotPrefixed(state.showDotPrefixed ?? false);
          } catch {
            // Ignore corrupt settings
          }
        }
      })
      .catch((err) => console.error("Failed to load tree state:", err));
  }, []);

  // Persist tree state on changes (D-17: debounced 250ms)
  useEffect(() => {
    const timer = setTimeout(() => {
      const state: TreeState = {
        expanded: [], // TODO: extract from react-arborist tree ref
        lastSelected: selectedFolder,
        showDotPrefixed,
      };
      setAppSetting("folders.tree_state", JSON.stringify(state)).catch((err) =>
        console.error("Failed to save tree state:", err),
      );
    }, 250);
    return () => clearTimeout(timer);
  }, [selectedFolder, showDotPrefixed]);

  // Listen for organized-path mutations to invalidate cache (D-08)
  useEffect(() => {
    const unlisteners: (() => void)[] = [];
    const events = ["download-complete", "import-complete", "sync-complete"];

    const subscribe = async () => {
      for (const event of events) {
        try {
          const unlisten = await listen(event, () => {
            setRefreshKey((k) => k + 1);
          });
          unlisteners.push(unlisten);
        } catch (err) {
          console.error(`Failed to listen to ${event}:`, err);
        }
      }
    };
    subscribe();

    return () => {
      unlisteners.forEach((u) => u());
    };
  }, []);

  // Clear cache on mount transition false → true (D-15)
  useEffect(() => {
    if (isLibraryAvailable) {
      setRefreshKey((k) => k + 1);
    }
  }, [isLibraryAvailable]);

  const handleFolderSelect = useCallback(async (folderPath: string) => {
    setSelectedFolder(folderPath);
    setLoadingTracks(true);
    try {
      const folderTracks = await getFolderTracks(folderPath);
      setTracks(folderTracks);
    } catch (err) {
      console.error("Failed to load folder tracks:", err);
      setTracks([]);
    } finally {
      setLoadingTracks(false);
    }
  }, []);

  const handleContextMenu = useCallback(
    (e: React.MouseEvent, folderPath: string) => {
      e.preventDefault();
      setContextMenu({ folderPath, position: { x: e.clientX, y: e.clientY } });
    },
    [],
  );

  return (
    <div className="flex h-full overflow-hidden">
      {/* Left pane: Folder tree — 240px fixed (D-04) */}
      <div className="w-60 shrink-0 border-r border-edge flex flex-col bg-surface">
        {/* Tree header with "Show staging" toggle (D-07) */}
        <div className="flex items-center justify-between px-3 h-9 border-b border-edge-subtle">
          <span className="text-[11px] font-medium uppercase tracking-wider text-ink-muted">
            Folders
          </span>
          <label className="flex items-center gap-1.5 cursor-pointer">
            <input
              type="checkbox"
              checked={showDotPrefixed}
              onChange={(e) => setShowDotPrefixed(e.target.checked)}
              className="w-3 h-3 accent-accent"
            />
            <span className="text-[10px] text-ink-muted">Staging</span>
          </label>
        </div>

        {/* Disconnect banner (D-14) */}
        <FolderTreeBanner mounted={isLibraryAvailable} />

        {/* Tree body */}
        <div className="flex-1 overflow-hidden">
          <FolderTree
            onFolderSelect={handleFolderSelect}
            onNodeContextMenu={handleContextMenu}
            selectedFolder={selectedFolder}
            showDotPrefixed={showDotPrefixed}
            refreshKey={refreshKey}
          />
        </div>
      </div>

      {/* Right pane: Track list (D-03, D-04) */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {selectedFolder ? (
          loadingTracks ? (
            <div className="flex items-center justify-center h-full text-ink-muted text-[13px]">
              Loading tracks…
            </div>
          ) : (
            <LibraryTable tracks={tracks} view="library" />
          )
        ) : (
          /* D-03: First-open empty state */
          <div className="flex flex-col items-center justify-center h-full gap-3 text-ink-muted">
            <svg
              className="w-10 h-10 opacity-40"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              strokeWidth={1}
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
              />
            </svg>
            <span className="text-[13px]">Select a folder to view tracks</span>
          </div>
        )}
      </div>

      {/* Right-click context menu (D-12) */}
      {contextMenu && (
        <FolderTreeContextMenu
          folderPath={contextMenu.folderPath}
          position={contextMenu.position}
          onClose={() => setContextMenu(null)}
          disabled={!isLibraryAvailable}
        />
      )}
    </div>
  );
}
