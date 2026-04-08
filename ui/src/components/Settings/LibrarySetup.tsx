import { useState, useEffect } from "react";
import { toast } from "sonner";
import {
  select_library_folder,
  get_subfolders,
  configure_library,
  get_library_config,
} from "../../utils/tauri-commands";

interface LibrarySetupProps {
  onConfigured?: () => void;
}

export default function LibrarySetup({ onConfigured }: LibrarySetupProps) {
  const [rootPath, setRootPath] = useState<string | null>(null);
  const [subfolders, setSubfolders] = useState<string[]>([]);
  const [selectedFolders, setSelectedFolders] = useState<Set<string>>(new Set());
  const [downloadDest, setDownloadDest] = useState<string>("00_Artist");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showMarkerInfo, setShowMarkerInfo] = useState(false);

  useEffect(() => {
    const loadConfig = async () => {
      try {
        const config = await get_library_config();
        if (config.configured && config.root_path) {
          setRootPath(config.root_path);
          setDownloadDest(config.download_destination);
          setSelectedFolders(new Set(config.scan_folders));
          try {
            const folders = await get_subfolders(config.root_path);
            setSubfolders(folders);
          } catch (err) {
            console.error("Failed to load subfolders:", err);
          }
        }
      } catch (err) {
        console.error("Failed to load library config:", err);
      }
    };
    loadConfig();
  }, []);

  const handleSelectFolder = async () => {
    try {
      setLoading(true);
      setError(null);
      const path = await select_library_folder();
      if (!path) return;

      setRootPath(path);
      const folders = await get_subfolders(path);
      setSubfolders(folders);
      setShowMarkerInfo(folders.length === 0);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      toast.error(`Failed to select folder: ${message}`);
    } finally {
      setLoading(false);
    }
  };

  const handleToggleFolder = (folder: string) => {
    const newSelected = new Set(selectedFolders);
    if (newSelected.has(folder)) {
      newSelected.delete(folder);
    } else {
      newSelected.add(folder);
    }
    setSelectedFolders(newSelected);
  };

  const handleSelectAll = () => setSelectedFolders(new Set(subfolders));
  const handleDeselectAll = () => setSelectedFolders(new Set());

  const handleSave = async () => {
    if (!rootPath) {
      toast.error("Select a library folder first");
      return;
    }
    if (selectedFolders.size === 0) {
      toast.error("Select at least one folder to scan");
      return;
    }

    try {
      setLoading(true);
      setError(null);
      await configure_library(rootPath, Array.from(selectedFolders), downloadDest);
      toast.success("Library configuration saved");
      window.dispatchEvent(new CustomEvent("library-configured"));
      onConfigured?.();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      toast.error(`Failed to save: ${message}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="space-y-4">
      {/* Library path */}
      <div>
        <label className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted block mb-1.5">
          Library Path
        </label>
        <div className="flex items-center gap-2">
          <div className="flex-1 px-3 py-1.5 bg-raised border border-edge rounded text-[13px] text-ink-secondary truncate">
            {rootPath || "Not configured"}
          </div>
          <button
            onClick={handleSelectFolder}
            disabled={loading}
            className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
          >
            Browse
          </button>
        </div>

        {showMarkerInfo && (
          <div className="mt-2 bg-sky-500/10 border border-sky-500/20 rounded px-3 py-1.5">
            <p className="text-xs text-sky-400">New library will be created at this location.</p>
          </div>
        )}
      </div>

      {/* Scan folders */}
      {rootPath && subfolders.length > 0 && (
        <div>
          <div className="flex items-center justify-between mb-1.5">
            <label className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
              Scan Folders
            </label>
            <div className="flex gap-2">
              <button
                onClick={handleSelectAll}
                className="text-[11px] text-accent hover:text-accent-bright transition-colors"
              >
                All
              </button>
              <button
                onClick={handleDeselectAll}
                className="text-[11px] text-ink-muted hover:text-ink transition-colors"
              >
                None
              </button>
            </div>
          </div>
          <div className="space-y-0.5 max-h-48 overflow-y-auto border border-edge rounded p-2 bg-raised/30">
            {subfolders.map((folder) => (
              <label
                key={folder}
                className="flex items-center gap-2 cursor-pointer hover:bg-raised px-2 py-1 rounded text-[13px] text-ink-secondary"
              >
                <input
                  type="checkbox"
                  checked={selectedFolders.has(folder)}
                  onChange={() => handleToggleFolder(folder)}
                  className="w-3.5 h-3.5 rounded border-edge bg-raised text-accent focus:ring-accent/30"
                />
                <span>{folder}</span>
              </label>
            ))}
          </div>
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="bg-rose-500/10 border border-rose-500/20 rounded px-3 py-1.5">
          <p className="text-xs text-rose-400">{error}</p>
        </div>
      )}

      {/* Save */}
      {rootPath && (
        <div className="flex justify-end">
          <button
            onClick={handleSave}
            disabled={loading || selectedFolders.size === 0}
            className="px-4 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {loading ? "Saving..." : "Save Configuration"}
          </button>
        </div>
      )}
    </div>
  );
}
