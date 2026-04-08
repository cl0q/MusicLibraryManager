import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { toast } from "sonner";
import LibrarySetup from "../components/Settings/LibrarySetup";
import { getAppSetting, setAppSetting } from "../utils/tauri-commands";
import { useTheme, type ThemeName } from "../contexts/ThemeContext";

const themes: { value: ThemeName; label: string; desc: string; preview: string[] }[] = [
  {
    value: "midnight",
    label: "Midnight",
    desc: "Default dark theme",
    preview: ["#0c0c12", "#14141c", "#d4940c"],
  },
  {
    value: "solarized-dark",
    label: "Solarized Dark",
    desc: "Ethan Schoonover's dark palette",
    preview: ["#002b36", "#073642", "#b58900"],
  },
  {
    value: "solarized-light",
    label: "Solarized Light",
    desc: "Warm light palette",
    preview: ["#fdf6e3", "#eee8d5", "#b58900"],
  },
];

export default function Settings() {
  const { theme, setTheme } = useTheme();
  const [fileManager, setFileManager] = useState("system");
  const [customApp, setCustomApp] = useState("");
  const [saving, setSaving] = useState(false);
  const [maintenanceRunning, setMaintenanceRunning] = useState<string | null>(null);

  useEffect(() => {
    getAppSetting("file_manager").then((val) => {
      if (val) {
        if (val === "system" || val === "forklift") {
          setFileManager(val);
        } else {
          setFileManager("custom");
          setCustomApp(val);
        }
      }
    });
  }, []);

  const handleFileManagerChange = async (value: string) => {
    setFileManager(value);
    if (value !== "custom") {
      setSaving(true);
      try {
        await setAppSetting("file_manager", value);
      } catch {
        toast.error("Failed to save setting");
      }
      setSaving(false);
    }
  };

  const handleCustomAppSave = async () => {
    if (customApp.trim()) {
      setSaving(true);
      try {
        await setAppSetting("file_manager", customApp.trim());
        toast.success("File manager saved");
      } catch {
        toast.error("Failed to save setting");
      }
      setSaving(false);
    }
  };

  const fileManagerOptions = [
    { value: "system", label: "System Default", desc: "Finder on macOS" },
    { value: "forklift", label: "ForkLift 4", desc: "Opens folder in ForkLift" },
    { value: "custom", label: "Custom", desc: "Specify an application name" },
  ];

  return (
    <div className="p-6 space-y-6 max-w-xl">
      <h1 className="text-sm font-semibold uppercase tracking-wide text-ink-secondary">
        Settings
      </h1>

      {/* Library */}
      <section className="space-y-3">
        <h2 className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
          Library
        </h2>
        <div className="bg-surface border border-edge rounded-lg p-4">
          <LibrarySetup />
        </div>
      </section>

      {/* Theme */}
      <section className="space-y-3">
        <h2 className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
          Theme
        </h2>
        <div className="bg-surface border border-edge rounded-lg p-4 space-y-1">
          {themes.map((t) => (
            <label
              key={t.value}
              className={`flex items-center gap-3 px-3 py-2 rounded cursor-pointer transition-colors ${
                theme === t.value
                  ? "bg-accent/10 text-ink"
                  : "text-ink-secondary hover:bg-raised/60"
              }`}
            >
              <input
                type="radio"
                name="theme"
                value={t.value}
                checked={theme === t.value}
                onChange={() => setTheme(t.value)}
                className="accent-accent"
              />
              <div className="flex items-center gap-2">
                <div className="flex gap-0.5">
                  {t.preview.map((c) => (
                    <span
                      key={c}
                      className="w-3 h-3 rounded-sm border border-edge"
                      style={{ background: c }}
                    />
                  ))}
                </div>
                <span className="text-xs font-medium">{t.label}</span>
                <span className="text-[11px] text-ink-muted">{t.desc}</span>
              </div>
            </label>
          ))}
        </div>
      </section>

      {/* File Manager */}
      <section className="space-y-3">
        <h2 className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
          File Manager
        </h2>
        <div className="bg-surface border border-edge rounded-lg p-4 space-y-1">
          <p className="text-xs text-ink-muted mb-3">
            App used when revealing files in their folder.
          </p>
          {fileManagerOptions.map((opt) => (
            <label
              key={opt.value}
              className={`flex items-center gap-3 px-3 py-2 rounded cursor-pointer transition-colors ${
                fileManager === opt.value
                  ? "bg-accent/10 text-ink"
                  : "text-ink-secondary hover:bg-raised/60"
              }`}
            >
              <input
                type="radio"
                name="file_manager"
                value={opt.value}
                checked={fileManager === opt.value}
                onChange={() => handleFileManagerChange(opt.value)}
                className="accent-accent"
              />
              <div className="flex items-baseline gap-2">
                <span className="text-xs font-medium">{opt.label}</span>
                <span className="text-[11px] text-ink-muted">{opt.desc}</span>
              </div>
            </label>
          ))}
          {fileManager === "custom" && (
            <div className="flex items-center gap-2 mt-2 pl-8">
              <input
                type="text"
                value={customApp}
                onChange={(e) => setCustomApp(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && handleCustomAppSave()}
                placeholder="e.g. Path Finder"
                className="flex-1 px-2.5 py-1.5 text-xs bg-raised border border-edge rounded text-ink placeholder:text-ink-muted focus:outline-none focus:border-accent/50"
              />
              <button
                onClick={handleCustomAppSave}
                disabled={saving || !customApp.trim()}
                className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors disabled:opacity-50"
              >
                {saving ? "..." : "Save"}
              </button>
            </div>
          )}
        </div>
      </section>

      {/* Maintenance */}
      <section className="space-y-3">
        <h2 className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
          Maintenance
        </h2>
        <div className="bg-surface border border-edge rounded-lg p-4 space-y-3">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs font-medium text-ink">Clear Analysis Cache</p>
              <p className="text-[11px] text-ink-muted">
                Clears cached ffprobe data. Re-fetched on next track view.
              </p>
            </div>
            <button
              onClick={async () => {
                setMaintenanceRunning("reindex");
                try {
                  const cleared = await invoke<number>("reindex_search");
                  toast.success(`Cleared ${cleared} cached entries`);
                } catch (err) {
                  toast.error(`Failed: ${err}`);
                }
                setMaintenanceRunning(null);
              }}
              disabled={maintenanceRunning !== null}
              className="px-3 py-1.5 text-xs font-medium text-ink-secondary hover:text-ink border border-edge hover:bg-raised rounded transition-colors disabled:opacity-50 shrink-0"
            >
              {maintenanceRunning === "reindex" ? "Clearing..." : "Clear"}
            </button>
          </div>

          <div className="border-t border-edge-subtle" />

          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs font-medium text-ink">Rescan Metadata</p>
              <p className="text-[11px] text-ink-muted">
                Re-read tags from all local files. Fixes bitrate, format, and tag data.
              </p>
            </div>
            <button
              onClick={async () => {
                setMaintenanceRunning("rescan");
                toast.info("Rescanning metadata — this may take a few minutes...");
                try {
                  const result = await invoke<{ scanned: number; updated: number; errors: number }>("rescan_metadata");
                  toast.success(`Rescanned ${result.scanned} tracks: ${result.updated} updated, ${result.errors} errors`);
                } catch (err) {
                  toast.error(`Failed: ${err}`);
                }
                setMaintenanceRunning(null);
              }}
              disabled={maintenanceRunning !== null}
              className="px-3 py-1.5 text-xs font-medium text-ink-secondary hover:text-ink border border-edge hover:bg-raised rounded transition-colors disabled:opacity-50 shrink-0"
            >
              {maintenanceRunning === "rescan" ? "Scanning..." : "Rescan"}
            </button>
          </div>
          <div className="border-t border-edge-subtle" />

          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs font-medium text-ink">Purge Orphaned Tracks</p>
              <p className="text-[11px] text-ink-muted">
                Remove DB entries for tracks whose files no longer exist on disk.
              </p>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <button
                onClick={async () => {
                  setMaintenanceRunning("orphan-scan");
                  try {
                    const result = await invoke<{ total_local: number; orphaned: number }>("find_orphaned_tracks");
                    if (result.orphaned === 0) {
                      toast.success("No orphaned tracks found");
                    } else {
                      toast.info(`Found ${result.orphaned} orphaned tracks out of ${result.total_local} local`);
                    }
                  } catch (err) {
                    toast.error(`Failed: ${err}`);
                  }
                  setMaintenanceRunning(null);
                }}
                disabled={maintenanceRunning !== null}
                className="px-3 py-1.5 text-xs font-medium text-ink-secondary hover:text-ink border border-edge hover:bg-raised rounded transition-colors disabled:opacity-50"
              >
                {maintenanceRunning === "orphan-scan" ? "Scanning..." : "Scan"}
              </button>
              <button
                onClick={async () => {
                  setMaintenanceRunning("orphan-purge");
                  try {
                    const deleted = await invoke<number>("purge_orphaned_tracks");
                    toast.success(`Purged ${deleted} orphaned tracks`);
                  } catch (err) {
                    toast.error(`Failed: ${err}`);
                  }
                  setMaintenanceRunning(null);
                }}
                disabled={maintenanceRunning !== null}
                className="px-3 py-1.5 text-xs font-medium text-rose-400 hover:text-rose-300 border border-rose-500/30 hover:bg-rose-500/10 rounded transition-colors disabled:opacity-50"
              >
                {maintenanceRunning === "orphan-purge" ? "Purging..." : "Purge"}
              </button>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
