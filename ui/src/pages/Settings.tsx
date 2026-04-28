import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { toast } from "sonner";
import LibrarySetup from "../components/Settings/LibrarySetup";
import {
  getAppSetting,
  setAppSetting,
  analyzeLoudnessAll,
  rescanAlbums,
  backfillYeatTagsFromDb,
} from "../utils/tauri-commands";
import { useTheme, type ThemeName } from "../contexts/ThemeContext";

const themes: {
  value: ThemeName;
  label: string;
  colors: { bg: string; surface: string; text: string; accent: string };
}[] = [
  {
    value: "solar",
    label: "Solar",
    colors: { bg: "#f0ebe1", surface: "#e8e2d4", text: "#1a1612", accent: "#b8541e" },
  },
  {
    value: "midnight",
    label: "Midnight",
    colors: { bg: "#0c0c12", surface: "#14141c", text: "#e8e8f0", accent: "#d4940c" },
  },
  {
    value: "solarized-dark",
    label: "Solarized Dark",
    colors: { bg: "#002b36", surface: "#073642", text: "#93a1a1", accent: "#b58900" },
  },
  {
    value: "solarized-light",
    label: "Solarized Light",
    colors: { bg: "#fdf6e3", surface: "#eee8d5", text: "#586e75", accent: "#b58900" },
  },
];

const fileManagerOptions = [
  { value: "system", label: "System Default" },
  { value: "forklift", label: "ForkLift 4" },
  { value: "custom", label: "Custom" },
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

  const runMaintenance = async (
    key: string,
    action: () => Promise<void>,
  ) => {
    setMaintenanceRunning(key);
    try {
      await action();
    } catch (err) {
      toast.error(`Failed: ${err}`);
    }
    setMaintenanceRunning(null);
  };

  return (
    <div className="p-6 max-w-lg">
      <h1 className="text-[11px] font-semibold uppercase tracking-[0.15em] text-ink-muted mb-8">
        Settings
      </h1>

      {/* ── Theme ─────────────────────────────── */}
      <Section label="Appearance">
        <div className="flex gap-2">
          {themes.map((t) => {
            const active = theme === t.value;
            return (
              <button
                key={t.value}
                onClick={() => setTheme(t.value)}
                className={`group flex-1 rounded-lg p-2.5 transition-all cursor-pointer ${
                  active
                    ? "ring-1 ring-accent bg-raised"
                    : "bg-surface hover:bg-raised/60"
                }`}
              >
                {/* Mini preview */}
                <div
                  className="h-10 rounded-md mb-2 flex items-end p-1.5 gap-1"
                  style={{ background: t.colors.bg }}
                >
                  <span
                    className="w-5 h-2.5 rounded-sm"
                    style={{ background: t.colors.surface }}
                  />
                  <span
                    className="w-3 h-2.5 rounded-sm"
                    style={{ background: t.colors.accent }}
                  />
                  <span
                    className="flex-1 h-[3px] rounded-full mt-auto"
                    style={{ background: t.colors.text, opacity: 0.5 }}
                  />
                </div>
                <span className={`text-[11px] font-medium ${active ? "text-ink" : "text-ink-muted"}`}>
                  {t.label}
                </span>
              </button>
            );
          })}
        </div>
      </Section>

      {/* ── File Manager ──────────────────────── */}
      <Section label="File Manager">
        <Row label="Reveal files with">
          <select
            value={fileManager}
            onChange={(e) => handleFileManagerChange(e.target.value)}
            disabled={saving}
            className="bg-raised border border-edge rounded px-2 py-1 text-xs text-ink focus:outline-none focus:border-accent/50 cursor-pointer"
          >
            {fileManagerOptions.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </Row>
        {fileManager === "custom" && (
          <div className="flex items-center gap-2 mt-2">
            <input
              type="text"
              value={customApp}
              onChange={(e) => setCustomApp(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleCustomAppSave()}
              placeholder="e.g. Path Finder"
              className="flex-1 px-2.5 py-1 text-xs bg-raised border border-edge rounded text-ink placeholder:text-ink-muted focus:outline-none focus:border-accent/50"
            />
            <button
              onClick={handleCustomAppSave}
              disabled={saving || !customApp.trim()}
              className="px-2.5 py-1 text-xs font-medium text-accent hover:text-accent-bright transition-colors disabled:opacity-40"
            >
              {saving ? "..." : "Save"}
            </button>
          </div>
        )}
      </Section>

      {/* ── Library ────────────────────────────── */}
      <Section label="Library">
        <LibrarySetup />
      </Section>

      {/* ── Maintenance ────────────────────────── */}
      <Section label="Maintenance" last>
        <MaintenanceRow
          label="Analyze Loudness"
          hint="LUFS-I, LRA, peak, energy for all tracks"
          running={maintenanceRunning === "loudness"}
          disabled={maintenanceRunning !== null}
          actions={[
            {
              label: "Analyze",
              loadingLabel: "Queuing…",
              onClick: () =>
                runMaintenance("loudness", async () => {
                  const r = await analyzeLoudnessAll();
                  toast.success(
                    `Loudness analysis — ${r.analyzed} analyzed, ${r.failed} failed`,
                  );
                }),
            },
          ]}
        />
        <MaintenanceRow
          label="Clear Analysis Cache"
          hint="Cached ffprobe data"
          running={maintenanceRunning === "reindex"}
          disabled={maintenanceRunning !== null}
          actions={[
            {
              label: "Clear",
              loadingLabel: "Clearing...",
              onClick: () =>
                runMaintenance("reindex", async () => {
                  const n = await invoke<number>("reindex_search");
                  toast.success(`Cleared ${n} cached entries`);
                }),
            },
          ]}
        />
        <MaintenanceRow
          label="Rescan Metadata"
          hint="Re-read tags from all local files"
          running={maintenanceRunning === "rescan"}
          disabled={maintenanceRunning !== null}
          actions={[
            {
              label: "Rescan",
              loadingLabel: "Scanning...",
              onClick: () =>
                runMaintenance("rescan", async () => {
                  toast.info("Rescanning metadata...");
                  const r = await invoke<{ scanned: number; updated: number; errors: number }>("rescan_metadata");
                  toast.success(`${r.scanned} scanned, ${r.updated} updated, ${r.errors} errors`);
                }),
            },
          ]}
        />
        <MaintenanceRow
          label="Rescan Albums"
          hint="Re-index albums, detect variants, refresh siblings"
          running={maintenanceRunning === "rescan-albums"}
          disabled={maintenanceRunning !== null}
          actions={[
            {
              label: "Rescan",
              loadingLabel: "Rescanning…",
              onClick: () =>
                runMaintenance("rescan-albums", async () => {
                  const r = await rescanAlbums();
                  const suffix = r.ambiguous_count > 0 ? ` (${r.ambiguous_count} ambiguous)` : "";
                  toast.success(
                    `${r.sibling_pairs_detected} sibling pairs detected, ${r.backfilled_albums} albums backfilled${suffix}`,
                  );
                }),
            },
          ]}
        />
        <MaintenanceRow
          label="Backfill Yeat Tags"
          hint="Tag Yeat tracks with artist + era + variant from the albums table"
          running={maintenanceRunning === "backfill-yeat-tags"}
          disabled={maintenanceRunning !== null}
          actions={[
            {
              label: "Backfill",
              loadingLabel: "Tagging…",
              onClick: () =>
                runMaintenance("backfill-yeat-tags", async () => {
                  const r = await backfillYeatTagsFromDb();
                  const total = r.artist_tags_written + r.era_tags_written + r.variant_tags_written;
                  const removedSuffix =
                    r.stale_tags_removed > 0 ? `, ${r.stale_tags_removed} stale removed` : "";
                  toast.success(
                    `${r.tracks_processed} tracks tagged, ${total} tags written${removedSuffix}`,
                  );
                }),
            },
          ]}
        />
        <MaintenanceRow
          label="Purge Orphaned Tracks"
          hint="Entries with missing files"
          running={maintenanceRunning === "orphan-scan" || maintenanceRunning === "orphan-purge"}
          disabled={maintenanceRunning !== null}
          actions={[
            {
              label: "Scan",
              loadingLabel: "Scanning...",
              onClick: () =>
                runMaintenance("orphan-scan", async () => {
                  const r = await invoke<{ total_local: number; orphaned: number }>("find_orphaned_tracks");
                  if (r.orphaned === 0) toast.success("No orphans found");
                  else toast.info(`${r.orphaned} orphaned of ${r.total_local} local`);
                }),
            },
            {
              label: "Purge",
              loadingLabel: "Purging...",
              destructive: true,
              onClick: () =>
                runMaintenance("orphan-purge", async () => {
                  const n = await invoke<number>("purge_orphaned_tracks");
                  toast.success(`Purged ${n} orphaned tracks`);
                }),
            },
          ]}
        />
      </Section>
    </div>
  );
}

/* ── Reusable pieces ───────────────────────────── */

function Section({
  label,
  last,
  children,
}: {
  label: string;
  last?: boolean;
  children: React.ReactNode;
}) {
  return (
    <section className={last ? "" : "mb-8"}>
      <h2 className="text-[11px] font-semibold uppercase tracking-[0.12em] text-ink-muted mb-3">
        {label}
      </h2>
      {children}
    </section>
  );
}

function Row({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-xs text-ink-secondary">{label}</span>
      {children}
    </div>
  );
}

function MaintenanceRow({
  label,
  hint,
  running,
  disabled,
  actions,
}: {
  label: string;
  hint: string;
  running: boolean;
  disabled: boolean;
  actions: {
    label: string;
    loadingLabel: string;
    destructive?: boolean;
    onClick: () => void;
  }[];
}) {
  return (
    <div className="flex items-center justify-between py-2 first:pt-0 last:pb-0">
      <div className="min-w-0">
        <p className="text-xs text-ink">{label}</p>
        <p className="text-[11px] text-ink-muted">{hint}</p>
      </div>
      <div className="flex gap-1.5 shrink-0 ml-4">
        {actions.map((a) => (
          <button
            key={a.label}
            onClick={a.onClick}
            disabled={disabled}
            className={`px-2.5 py-1 text-[11px] font-medium rounded transition-colors disabled:opacity-40 ${
              a.destructive
                ? "text-rose-400 hover:text-rose-300 hover:bg-rose-500/10"
                : "text-ink-secondary hover:text-ink hover:bg-raised"
            }`}
          >
            {running ? a.loadingLabel : a.label}
          </button>
        ))}
      </div>
    </div>
  );
}
