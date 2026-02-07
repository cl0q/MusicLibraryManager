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

          // Load subfolders for the configured path
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

      if (!path) {
        return; // User cancelled
      }

      setRootPath(path);

      // Get subfolders
      const folders = await get_subfolders(path);
      setSubfolders(folders);

      // Check if marker file exists by looking at folder names
      // (A simple heuristic - if no subfolders, might be new library)
      if (folders.length === 0) {
        setShowMarkerInfo(true);
      } else {
        setShowMarkerInfo(false);
      }
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

  const handleSelectAll = () => {
    setSelectedFolders(new Set(subfolders));
  };

  const handleDeselectAll = () => {
    setSelectedFolders(new Set());
  };

  const handleSave = async () => {
    if (!rootPath) {
      toast.error("Please select a library folder");
      return;
    }

    if (selectedFolders.size === 0) {
      toast.error("Please select at least one folder to scan");
      return;
    }

    if (!downloadDest.trim()) {
      toast.error("Please specify a download destination");
      return;
    }

    try {
      setLoading(true);
      setError(null);

      await configure_library(
        rootPath,
        Array.from(selectedFolders),
        downloadDest
      );

      toast.success("Library configuration saved successfully");
      // Notify LibraryMountContext to refresh state
      window.dispatchEvent(new CustomEvent("library-configured"));
      onConfigured?.();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      toast.error(`Failed to save configuration: ${message}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Library Location Section */}
      <div>
        <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-3">
          Library Location
        </h3>
        <div className="space-y-3">
          <div className="flex items-center gap-3">
            <div className="flex-1 px-3 py-2 bg-gray-50 dark:bg-gray-900 border border-gray-300 dark:border-gray-700 rounded-lg">
              <p className="text-sm text-gray-700 dark:text-gray-300">
                {rootPath || "Not configured"}
              </p>
            </div>
            <button
              onClick={handleSelectFolder}
              disabled={loading}
              className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Select Folder
            </button>
          </div>

          {showMarkerInfo && (
            <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-3">
              <p className="text-sm text-blue-800 dark:text-blue-200">
                No MLM library found at this location. A new library will be created here.
              </p>
            </div>
          )}
        </div>
      </div>

      {/* Scan Folders Section */}
      {rootPath && subfolders.length > 0 && (
        <div>
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white">
              Scan Folders
            </h3>
            <div className="flex gap-2">
              <button
                onClick={handleSelectAll}
                className="text-xs px-2 py-1 text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded"
              >
                Select All
              </button>
              <button
                onClick={handleDeselectAll}
                className="text-xs px-2 py-1 text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded"
              >
                Deselect All
              </button>
            </div>
          </div>
          <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
            Choose which folders to scan for music files
          </p>
          <div className="space-y-2 max-h-64 overflow-y-auto border border-gray-300 dark:border-gray-700 rounded-lg p-3">
            {subfolders.map((folder) => (
              <label
                key={folder}
                className="flex items-center gap-2 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800 p-2 rounded"
              >
                <input
                  type="checkbox"
                  checked={selectedFolders.has(folder)}
                  onChange={() => handleToggleFolder(folder)}
                  className="w-4 h-4 text-blue-600 border-gray-300 rounded focus:ring-blue-500"
                />
                <span className="text-sm text-gray-700 dark:text-gray-300">
                  {folder}
                </span>
              </label>
            ))}
          </div>
        </div>
      )}

      {/* Download Destination Section */}
      {rootPath && (
        <div>
          <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-3">
            Download Destination
          </h3>
          <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
            New downloads will be saved here in Artist/Album structure
          </p>
          <input
            type="text"
            value={downloadDest}
            onChange={(e) => setDownloadDest(e.target.value)}
            placeholder="00_Artist"
            className="w-full px-3 py-2 bg-white dark:bg-gray-900 border border-gray-300 dark:border-gray-700 rounded-lg text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
        </div>
      )}

      {/* Error Display */}
      {error && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-3">
          <p className="text-sm text-red-800 dark:text-red-200">{error}</p>
        </div>
      )}

      {/* Save Button */}
      {rootPath && (
        <div className="flex justify-end">
          <button
            onClick={handleSave}
            disabled={loading || selectedFolders.size === 0}
            className="px-6 py-2 bg-green-600 hover:bg-green-700 text-white font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {loading ? "Saving..." : "Save Configuration"}
          </button>
        </div>
      )}
    </div>
  );
}
