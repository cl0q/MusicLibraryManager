/**
 * BatchBar — floating multi-select action bar (Phase 19).
 *
 * Renders when the library table has ≥ 2 selected tracks. Actions map
 * directly to the existing row-context commands plus two new destructive
 * Tauri commands (`remove_tracks_from_library`, `delete_tracks_from_disk`).
 *
 * Dismissal: Esc already clears selection from `LibraryTable`, so the bar
 * unmounts naturally. Click-outside of the table container is handled here
 * via a pointerdown listener that fires on the window and clears selection
 * when the pointer target is outside the library table view.
 */

import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { toast } from "sonner";
import type { Track } from "../../types/library";

interface Playlist {
  id: number;
  name: string;
  category: string;
  is_smart: boolean;
}

interface SyncProfile {
  id: number;
  name: string;
}

interface BatchBarProps {
  /** Currently selected tracks (>= 2 when the bar is visible). */
  selected: Track[];
  /** Called when the user clears the selection (Esc, Clear button, success). */
  onClear: () => void;
  /**
   * Called after destructive operations so the parent can refresh the
   * library table rows. Arg is a hint of what happened; the parent
   * usually re-runs its data hook.
   */
  onMutated?: (kind: "removed" | "deleted") => void;
}

export default function BatchBar({ selected, onClear, onMutated }: BatchBarProps) {
  const count = selected.length;
  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [syncProfiles, setSyncProfiles] = useState<SyncProfile[]>([]);
  const [openMenu, setOpenMenu] = useState<null | "playlist" | "sync">(null);
  const [confirm, setConfirm] = useState<null | "remove" | "delete">(null);
  const [busy, setBusy] = useState(false);
  const barRef = useRef<HTMLDivElement>(null);

  // Load playlist / sync-profile options on first render.
  useEffect(() => {
    invoke<Playlist[]>("get_playlists_command")
      .then(setPlaylists)
      .catch((e) => console.error("BatchBar: playlists fetch failed", e));
    invoke<SyncProfile[]>("list_sync_profiles")
      .then(setSyncProfiles)
      .catch((e) => console.error("BatchBar: sync profiles fetch failed", e));
  }, []);

  // Close submenus on outside click. We don't clear selection — Esc does
  // that globally from LibraryTable.
  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (!barRef.current) return;
      const target = e.target as Node | null;
      if (target && !barRef.current.contains(target)) {
        setOpenMenu(null);
        setConfirm(null);
      }
    };
    window.addEventListener("mousedown", onDown);
    return () => window.removeEventListener("mousedown", onDown);
  }, []);

  if (count < 2) return null;

  const trackIds = selected
    .map((t) => t.id)
    .filter((id): id is number => id !== null);

  async function handleAddToPlaylist(playlistId: number) {
    setBusy(true);
    try {
      await Promise.all(
        trackIds.map((trackId) =>
          invoke("add_track_to_playlist_command", { playlistId, trackId }),
        ),
      );
      toast.success(`Added ${trackIds.length} tracks to playlist`);
      setOpenMenu(null);
    } catch (err) {
      toast.error(`Add to playlist failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  async function handleAddToSync(profileId: number) {
    setBusy(true);
    try {
      await Promise.all(
        trackIds.map((trackId) =>
          invoke("add_track_to_profile", { profileId, trackId }),
        ),
      );
      toast.success(`Added ${trackIds.length} tracks to sync profile`);
      setOpenMenu(null);
    } catch (err) {
      toast.error(`Add to sync profile failed: ${err}`);
    } finally {
      setBusy(false);
    }
  }

  async function handleRemoveFromLibrary() {
    setBusy(true);
    try {
      const removed = await invoke<number>("remove_tracks_from_library", {
        trackIds,
      });
      toast.success(`Removed ${removed} tracks from library (files kept)`);
      onMutated?.("removed");
      onClear();
    } catch (err) {
      toast.error(`Remove failed: ${err}`);
    } finally {
      setBusy(false);
      setConfirm(null);
    }
  }

  async function handleDeleteFromDisk() {
    setBusy(true);
    try {
      const r = await invoke<{
        files_deleted: number;
        files_missing: number;
        rows_deleted: number;
        errors: string[];
      }>("delete_tracks_from_disk", { trackIds });
      const parts = [`${r.files_deleted} files deleted`];
      if (r.files_missing > 0) parts.push(`${r.files_missing} already missing`);
      if (r.errors.length > 0) parts.push(`${r.errors.length} errors`);
      toast.success(parts.join(" · "));
      if (r.errors.length > 0) {
        console.error("delete_tracks_from_disk errors:", r.errors);
      }
      onMutated?.("deleted");
      onClear();
    } catch (err) {
      toast.error(`Delete failed: ${err}`);
    } finally {
      setBusy(false);
      setConfirm(null);
    }
  }

  // Filter out smart playlists — the "Add track" command doesn't apply to them.
  const regularPlaylists = playlists.filter((p) => !p.is_smart);

  return (
    <div
      ref={barRef}
      className="absolute bottom-5 left-1/2 z-20"
      style={{ transform: "translateX(-50%)", fontFamily: "var(--font-ui)" }}
    >
      {/* Confirmation prompt for destructive actions — rendered above the bar */}
      {confirm && (
        <div
          className="mb-2 mx-auto max-w-[420px] bg-surface border border-edge rounded-[8px] shadow-xl p-3"
          style={{ boxShadow: "0 12px 40px rgba(0,0,0,0.4), 0 0 0 1px rgba(0,0,0,0.2)" }}
        >
          <p className="text-[13px] text-ink font-semibold mb-1">
            {confirm === "remove"
              ? `Remove ${count} tracks from library?`
              : `Delete ${count} files from disk?`}
          </p>
          <p className="text-[11px] text-ink-muted mb-3">
            {confirm === "remove"
              ? "Files stay on disk. You can re-import them later."
              : "This cannot be undone."}
          </p>
          <div className="flex gap-2 justify-end">
            <button
              onClick={() => setConfirm(null)}
              disabled={busy}
              className="h-[28px] px-3 rounded-[5px] bg-transparent border border-edge text-ink-secondary hover:text-ink hover:bg-raised text-[12px] transition-colors disabled:opacity-40"
            >
              Cancel
            </button>
            <button
              onClick={
                confirm === "remove" ? handleRemoveFromLibrary : handleDeleteFromDisk
              }
              disabled={busy}
              className="h-[28px] px-3 rounded-[5px] bg-rose-500/15 border border-rose-500/40 text-rose-400 hover:bg-rose-500/25 text-[12px] font-semibold transition-colors disabled:opacity-40"
            >
              {busy
                ? "Working…"
                : confirm === "remove"
                  ? `Remove ${count} tracks from library`
                  : `Delete ${count} files from disk`}
            </button>
          </div>
        </div>
      )}

      {/* The bar itself */}
      <div
        className="flex items-center gap-0.5 rounded-[10px] p-1"
        style={{
          background: "var(--color-overlay, var(--color-surface))",
          border: "1px solid var(--color-edge)",
          boxShadow: "0 12px 40px rgba(0,0,0,0.4), 0 0 0 1px rgba(0,0,0,0.2)",
        }}
      >
        {/* Count */}
        <div className="flex items-center gap-2 px-3 py-1.5">
          <span className="text-[12px] font-semibold" style={{ color: "var(--color-accent)" }}>
            {count}
          </span>
          <span className="text-[12px] text-ink-secondary">selected</span>
        </div>
        <Divider />

        {/* Add to playlist */}
        <DropdownButton
          icon="playlist"
          label="Add to playlist"
          open={openMenu === "playlist"}
          onToggle={() => setOpenMenu(openMenu === "playlist" ? null : "playlist")}
          disabled={busy}
        >
          {regularPlaylists.length === 0 ? (
            <MenuEmpty>No playlists</MenuEmpty>
          ) : (
            regularPlaylists.map((pl) => (
              <MenuItem key={pl.id} onClick={() => handleAddToPlaylist(pl.id)}>
                {pl.name}
              </MenuItem>
            ))
          )}
        </DropdownButton>

        {/* Add to sync profile */}
        <DropdownButton
          icon="sync"
          label="Add to sync"
          open={openMenu === "sync"}
          onToggle={() => setOpenMenu(openMenu === "sync" ? null : "sync")}
          disabled={busy}
        >
          {syncProfiles.length === 0 ? (
            <MenuEmpty>No sync profiles</MenuEmpty>
          ) : (
            syncProfiles.map((pr) => (
              <MenuItem key={pr.id} onClick={() => handleAddToSync(pr.id)}>
                {pr.name}
              </MenuItem>
            ))
          )}
        </DropdownButton>

        <Divider />

        {/* Destructive: Remove from library */}
        <BarButton
          icon="minus"
          label="Remove from library"
          onClick={() => setConfirm("remove")}
          disabled={busy}
          destructive
        />
        {/* Destructive: Delete from disk */}
        <BarButton
          icon="trash"
          label="Delete from disk"
          onClick={() => setConfirm("delete")}
          disabled={busy}
          destructive
        />

        <Divider />

        {/* Clear selection */}
        <BarButton icon="x" label="Clear" onClick={onClear} disabled={busy} muted />
      </div>
    </div>
  );
}

/* ── Atoms ──────────────────────────────────────── */

function Divider() {
  return <span className="mx-0.5 w-px h-[18px] bg-edge" />;
}

interface BarButtonProps {
  icon: keyof typeof ICON_PATHS;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  destructive?: boolean;
  muted?: boolean;
}

function BarButton({ icon, label, onClick, disabled, destructive, muted }: BarButtonProps) {
  const color = destructive
    ? "var(--color-rose, #f43f5e)"
    : muted
      ? "var(--color-ink-muted)"
      : "var(--color-ink-2, var(--color-ink))";
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`flex items-center gap-1.5 h-[28px] px-2.5 rounded-[6px] bg-transparent border-none cursor-pointer transition-colors text-[12px] disabled:opacity-40 disabled:cursor-not-allowed ${
        destructive
          ? "hover:bg-rose-500/10"
          : "hover:bg-raised"
      }`}
      style={{ color, fontFamily: "var(--font-ui)" }}
      title={label}
    >
      <BarIcon name={icon} />
      <span>{label}</span>
    </button>
  );
}

interface DropdownButtonProps {
  icon: keyof typeof ICON_PATHS;
  label: string;
  open: boolean;
  onToggle: () => void;
  disabled?: boolean;
  children: React.ReactNode;
}

function DropdownButton({ icon, label, open, onToggle, disabled, children }: DropdownButtonProps) {
  return (
    <div className="relative">
      <button
        onClick={onToggle}
        disabled={disabled}
        className={`flex items-center gap-1.5 h-[28px] px-2.5 rounded-[6px] border-none cursor-pointer transition-colors text-[12px] disabled:opacity-40 disabled:cursor-not-allowed ${
          open ? "bg-raised text-ink" : "bg-transparent text-ink-2 hover:bg-raised"
        }`}
        style={{ fontFamily: "var(--font-ui)" }}
      >
        <BarIcon name={icon} />
        <span>{label}</span>
        <svg
          className={`w-[10px] h-[10px] transition-transform ${open ? "rotate-180" : ""}`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          strokeWidth={2}
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M6 9l6 6 6-6" />
        </svg>
      </button>
      {open && (
        <div
          className="absolute bottom-full left-0 mb-1 min-w-[200px] max-h-[280px] overflow-auto bg-surface border border-edge rounded-[6px] shadow-xl"
          style={{ boxShadow: "0 8px 24px rgba(0,0,0,0.4)" }}
        >
          {children}
        </div>
      )}
    </div>
  );
}

function MenuItem({ onClick, children }: { onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className="w-full text-left px-3 py-1.5 text-[12px] text-ink hover:bg-raised bg-transparent border-none cursor-pointer block"
      style={{ fontFamily: "var(--font-ui)" }}
    >
      {children}
    </button>
  );
}

function MenuEmpty({ children }: { children: React.ReactNode }) {
  return <div className="px-3 py-2 text-[11px] text-ink-muted">{children}</div>;
}

const ICON_PATHS = {
  playlist: "M3.75 12h16.5m-16.5 3.75h16.5M3.75 19.5h16.5M5.6 4.5h12.8a1.9 1.9 0 010 3.75H5.6a1.9 1.9 0 010-3.75z",
  sync: "M16 9h5V4M3 20v-5h5M3 15a9 9 0 0015.4 3.4M21 9a9 9 0 00-15.4-3.4",
  minus: "M5 12h14",
  trash: "M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16",
  x: "M6 6l12 12M18 6L6 18",
} as const;

function BarIcon({ name }: { name: keyof typeof ICON_PATHS }) {
  return (
    <svg
      className="w-[13px] h-[13px]"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      strokeWidth={1.7}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d={ICON_PATHS[name]} />
    </svg>
  );
}
