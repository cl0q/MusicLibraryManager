import { useState, useEffect } from "react";
import { useNavigate, NavLink } from "react-router";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { toast } from "sonner";
import type { VisibilityState } from "@tanstack/react-table";
import { useLibraryTracks } from "../hooks/useLibraryTracks";
import { useEnhancementProgress } from "../hooks/useEnhancements";
import { useLibraryMount } from "../contexts/LibraryMountContext";
import LibraryTable from "../components/LibraryTable/LibraryTable";
import FilterBar from "../components/LibraryTable/FilterBar";
import ReviewQueue from "../components/ReviewQueue/ReviewQueue";
import MoreInfoPanel from "../components/MoreInfo/MoreInfoPanel";
import type { Track } from "../types/library";
import {
  fingerprintLibrary,
  fetchArtwork,
  analyzeLoudnessAll,
  deepScan,
  getReviewQueueCount,
  getRemoteTrackCount,
  stopAnalysis,
} from "../utils/tauri-commands";

interface LibraryBrowserProps {
  view?: "library" | "remote";
}

/**
 * Library page shell. Solar restyle (table.jsx):
 * - Local/Remote segmented tabs with counts (not separate NavLinks styled
 *   as plain text).
 * - Search input (FilterBar) with ⌘F kbd hint.
 * - Analyze / Match / Filters icon buttons on the right.
 * - Rows at 36px height (driven by --row-h token on :root).
 */
export default function LibraryBrowser({ view = "library" }: LibraryBrowserProps) {
  const navigate = useNavigate();
  const { mountState, isLibraryAvailable } = useLibraryMount();
  const [showReviewQueue, setShowReviewQueue] = useState(false);
  const [reviewQueueCount, setReviewQueueCount] = useState(0);
  const [refreshKey, setRefreshKey] = useState(0);
  const [moreInfoTrack, setMoreInfoTrack] = useState<Track | null>(null);
  const [moreInfoOpen, setMoreInfoOpen] = useState(false);

  const { tracks, loading, filterQuery, setFilterQuery } = useLibraryTracks(view, refreshKey);
  const [cachedTrackIds, setCachedTrackIds] = useState<Set<number>>(new Set());
  const [remoteCount, setRemoteCount] = useState<number | null>(null);
  const [localCount, setLocalCount] = useState<number | null>(null);
  // Phase 18: energy column is hidden by default; toggle from header.
  const [columnVisibility, setColumnVisibility] = useState<VisibilityState>({ energy: false });
  const energyOn = columnVisibility.energy !== false;

  useEffect(() => {
    invoke<number[]>("get_cached_track_ids")
      .then((ids) => setCachedTrackIds(new Set(ids)))
      .catch(() => {});
  }, [refreshKey]);

  // Keep the segmented tab counts fresh. Use the fetched tracks for the
  // active view, query the other side on demand.
  useEffect(() => {
    if (view === "library") {
      setLocalCount(tracks.length);
    } else {
      setRemoteCount(tracks.length);
    }
  }, [view, tracks.length]);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      if (view === "library") {
        try {
          const n = await getRemoteTrackCount();
          if (!cancelled) setRemoteCount(n);
        } catch {
          /* ignore */
        }
      } else {
        // On the remote view, fetch local total by counting search_library results.
        try {
          const result = await invoke<Track[]>("get_library_tracks_only");
          if (!cancelled) setLocalCount(result.length);
        } catch {
          /* ignore */
        }
      }
    };
    load();
    return () => { cancelled = true; };
  }, [view, refreshKey]);

  const fingerprintProgress = useEnhancementProgress("fingerprint");
  const artworkProgress = useEnhancementProgress("artwork");
  const loudnessProgress = useEnhancementProgress("loudness");
  const deepscanProgress = useEnhancementProgress("deepscan");

  useEffect(() => {
    const loadCount = async () => {
      try {
        const count = await getReviewQueueCount();
        setReviewQueueCount(count);
      } catch (err) {
        console.error("Failed to load review queue count:", err);
      }
    };
    loadCount();
  }, []);

  useEffect(() => {
    const handleReconnect = () => setRefreshKey((prev) => prev + 1);
    window.addEventListener("library-reconnected", handleReconnect);
    return () => window.removeEventListener("library-reconnected", handleReconnect);
  }, []);

  useEffect(() => {
    const unlisten = listen("download-complete", () => {
      setRefreshKey((prev) => prev + 1);
    });
    return () => { unlisten.then((fn) => fn()); };
  }, []);

  // Phase 20: each enhancement button is a toggle. First click starts
  // the op; a click while it's running signals the backend to stop
  // between tracks (within one track of latency). The button flips
  // back to its idle label once the backend emits `{prefix}:stopped`.
  const toggleOp = async (
    prefix: string,
    prog: ReturnType<typeof useEnhancementProgress>,
    start: () => Promise<unknown>,
    onDone?: () => void,
  ) => {
    if (prog.isRunning) {
      prog.setIsStopping(true);
      try {
        await stopAnalysis(prefix);
      } catch (err) {
        console.error(`Stop ${prefix} failed:`, err);
        prog.setIsStopping(false);
      }
      return;
    }
    try {
      await start();
      onDone?.();
    } catch (err) {
      console.error(`${prefix} failed:`, err);
    }
  };

  const handleFingerprintLibrary = () =>
    toggleOp("fingerprint", fingerprintProgress, fingerprintLibrary);

  const handleFetchArtwork = () =>
    toggleOp("artwork", artworkProgress, fetchArtwork);

  // Library-header "Analyze": Phase 18 wires this to `analyze_loudness_all`,
  // which queues every local track where `lufs_i IS NULL`. Phase 20 turns
  // it into a start/stop toggle so the user can bail mid-backfill.
  const handleAnalyzeLoudness = () =>
    toggleOp(
      "loudness",
      loudnessProgress,
      async () => {
        const r = await analyzeLoudnessAll();
        if (r.cancelled) {
          toast.info(`Loudness stopped — ${r.analyzed} analyzed, ${r.failed} failed`);
        } else {
          toast.success(`Loudness — ${r.analyzed} analyzed, ${r.failed} failed`);
        }
      },
    );

  const handleDeepScan = () =>
    toggleOp("deepscan", deepscanProgress, deepScan, async () => {
      const count = await getReviewQueueCount();
      setReviewQueueCount(count);
    });

  const handleOpenMoreInfo = (track: Track) => {
    setMoreInfoTrack(track);
    setMoreInfoOpen(true);
  };

  // Disconnected state
  if (view === "library" && !isLibraryAvailable) {
    return (
      <div className="flex flex-col items-center justify-center h-full">
        <div className="max-w-xs text-center space-y-3">
          <div className="w-10 h-10 mx-auto rounded-lg bg-raised flex items-center justify-center">
            <svg className="w-5 h-5 text-ink-muted" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M21.75 17.25v-.228a4.5 4.5 0 00-.12-1.03l-2.268-9.64a3.375 3.375 0 00-3.285-2.602H7.923a3.375 3.375 0 00-3.285 2.602l-2.268 9.64a4.5 4.5 0 00-.12 1.03v.228m19.5 0a3 3 0 01-3 3H5.25a3 3 0 01-3-3m19.5 0a3 3 0 00-3-3H5.25a3 3 0 00-3 3" />
            </svg>
          </div>
          <p className="text-sm text-ink-secondary">
            {mountState === "not_configured"
              ? "Library not configured yet."
              : "External drive not connected."}
          </p>
          <button
            onClick={() => navigate("/settings")}
            className="text-xs text-accent hover:text-accent-bright font-medium transition-colors"
          >
            Open Settings
          </button>
        </div>
      </div>
    );
  }

  // Phase 20: track whether *any* op is running so sibling buttons can
  // grey themselves out. The running button itself stays clickable so
  // the user can stop it — that's handled inline via `running` on each
  // IconBtn.
  const anyRunning =
    fingerprintProgress.isRunning ||
    artworkProgress.isRunning ||
    loudnessProgress.isRunning ||
    deepscanProgress.isRunning;

  return (
    <div className="flex flex-col h-full" style={{ fontFamily: "var(--font-ui)" }}>
      {/* Header bar: segmented tabs + search + actions */}
      <div className="flex items-center gap-2.5 px-4 py-2.5 border-b border-edge-subtle shrink-0">
        {/* Segmented Local / Remote pills with counts */}
        <div className="flex gap-0.5 bg-raised rounded-[5px] p-0.5">
          <SegTab to="/" label="Local" count={localCount} active={view === "library"} />
          <SegTab to="/remote" label="Remote" count={remoteCount} active={view === "remote"} />
        </div>

        {/* Search */}
        <div className="flex-1 min-w-0">
          <FilterBar
            value={filterQuery}
            onChange={setFilterQuery}
            loading={loading}
            trailing={
              view === "library" ? (
                <div className="flex items-center gap-1.5">
                  <IconBtn
                    icon="bolt"
                    label="Analyze"
                    onClick={handleAnalyzeLoudness}
                    running={loudnessProgress.isRunning}
                    stopping={loudnessProgress.isStopping}
                    progress={loudnessProgress.progress}
                    disabled={anyRunning && !loudnessProgress.isRunning}
                  />
                  <IconBtn
                    icon="refresh"
                    label="Match"
                    onClick={handleFingerprintLibrary}
                    running={fingerprintProgress.isRunning}
                    stopping={fingerprintProgress.isStopping}
                    progress={fingerprintProgress.progress}
                    disabled={anyRunning && !fingerprintProgress.isRunning}
                  />
                  <IconBtn
                    icon="filter"
                    label="Scan"
                    onClick={handleDeepScan}
                    running={deepscanProgress.isRunning}
                    stopping={deepscanProgress.isStopping}
                    disabled={anyRunning && !deepscanProgress.isRunning}
                  />
                  <IconBtn
                    icon="image"
                    label="Artwork"
                    onClick={handleFetchArtwork}
                    running={artworkProgress.isRunning}
                    stopping={artworkProgress.isStopping}
                    progress={artworkProgress.progress}
                    disabled={anyRunning && !artworkProgress.isRunning}
                  />
                  {/* Energy column toggle — unhides the hidden-by-default
                      energy column so users can see the 1-5 bucket inline. */}
                  <button
                    onClick={() =>
                      setColumnVisibility((v) => ({ ...v, energy: !energyOn }))
                    }
                    title={energyOn ? "Hide energy column" : "Show energy column"}
                    className={`flex items-center gap-1.5 h-[30px] px-2.5 rounded-[5px] border text-[12px] transition-colors ${
                      energyOn
                        ? "bg-accent/15 border-accent/40 text-accent"
                        : "bg-raised border-edge text-ink-secondary hover:text-ink hover:bg-overlay"
                    }`}
                    style={{ fontFamily: "var(--font-ui)" }}
                  >
                    <EnergyGlyph on={energyOn} />
                    <span>Energy</span>
                  </button>
                </div>
              ) : null
            }
          />
        </div>
      </div>

      {/* Review Queue — only shows when there are items */}
      {view === "library" && reviewQueueCount > 0 && (
        <div className="px-4 pt-2">
          <button
            onClick={() => setShowReviewQueue(!showReviewQueue)}
            className="flex items-center gap-2 text-xs text-ink-secondary hover:text-ink transition-colors"
          >
            <span>Review Queue</span>
            <span className="bg-rose-500/15 text-rose-400 px-1.5 py-0.5 rounded text-[10px] font-medium tabular-nums">
              {reviewQueueCount}
            </span>
            <svg
              className={`w-3 h-3 transition-transform ${showReviewQueue ? "rotate-180" : ""}`}
              fill="none" stroke="currentColor" viewBox="0 0 24 24"
            >
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
            </svg>
          </button>
          {showReviewQueue && (
            <div className="mt-2">
              <ReviewQueue />
            </div>
          )}
        </div>
      )}

      {/* Track table */}
      <div className="flex-1 min-h-0 px-4 pt-2 pb-2">
        {loading ? (
          <div className="flex items-center justify-center h-full">
            <span className="text-sm text-ink-muted">Loading...</span>
          </div>
        ) : tracks.length === 0 ? (
          <div className="flex items-center justify-center h-full">
            <span className="text-sm text-ink-muted">
              {filterQuery ? "No tracks match your search" : "No tracks yet"}
            </span>
          </div>
        ) : (
          <LibraryTable
            tracks={tracks}
            view={view}
            onOpenMoreInfo={handleOpenMoreInfo}
            cachedTrackIds={cachedTrackIds}
            columnVisibility={columnVisibility}
            onColumnVisibilityChange={setColumnVisibility}
            onTracksMutated={() => setRefreshKey((k) => k + 1)}
          />
        )}
      </div>

      <MoreInfoPanel track={moreInfoTrack} isOpen={moreInfoOpen} onClose={() => setMoreInfoOpen(false)} />
    </div>
  );
}

/* ── Atoms ─────────────────────────────────────────────── */

function SegTab({ to, label, count, active }: { to: string; label: string; count: number | null; active: boolean }) {
  return (
    <NavLink
      to={to}
      end={to === "/"}
      className={`px-3 py-[5px] text-[12px] font-medium rounded-[3px] transition-colors inline-flex items-center gap-1.5 ${
        active ? "bg-overlay text-ink" : "text-ink-muted hover:text-ink"
      }`}
    >
      {label}
      <span
        className="text-[10px] px-1.5 rounded-full tabular-nums"
        style={{
          background: active ? "var(--color-edge)" : "var(--color-edge-subtle, var(--color-edge))",
          color: active ? "var(--color-ink-muted)" : "var(--color-ink-muted)",
          fontFamily: "var(--font-mono)",
        }}
      >
        {count === null ? "—" : count.toLocaleString()}
      </span>
    </NavLink>
  );
}

/** Tiny 5-bar stepped glyph used on the Energy column toggle. */
function EnergyGlyph({ on }: { on: boolean }) {
  const bars = on ? 5 : 2;
  return (
    <span className="inline-flex items-end gap-[2px]" style={{ height: 12 }}>
      {[1, 2, 3, 4, 5].map((i) => {
        const lit = i <= bars;
        const h = 2 + (i - 1) * 1.6;
        return (
          <span
            key={i}
            className="w-[1.5px] rounded-[0.5px]"
            style={{
              height: `${h}px`,
              background: lit ? "currentColor" : "var(--color-edge)",
            }}
          />
        );
      })}
    </span>
  );
}

const ICON_PATHS: Record<string, string> = {
  bolt: "M13 2L3 14h8l-1 8 10-12h-8l1-8z",
  refresh: "M3 10a9 9 0 0115-6l3 3M3 13a9 9 0 0015 6l3-3M3 4v6h6m12 10v-6h-6",
  filter: "M4 4h16l-6 8v6l-4 2v-8L4 4z",
  image: "M3 5a2 2 0 012-2h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V5zm4 5a2 2 0 100-4 2 2 0 000 4zm12 6l-5-5-4 4-2-2-3 3v2a2 2 0 002 2h10a2 2 0 002-2v-2z",
};

/**
 * Enhancement action button. Doubles as a start/stop toggle: clicking
 * while `running` sends the cancel signal. The toggled state uses a
 * y2k-style inset shadow + crimson glow so the button visually reads as
 * "pressed in and hot". `stopping` keeps the pressed look after the
 * click and swaps the label to "Stopping…" while workers drain.
 */
function IconBtn({
  icon,
  label,
  onClick,
  running,
  stopping,
  progress,
  disabled,
}: {
  icon: keyof typeof ICON_PATHS;
  label: string;
  onClick: () => void;
  running?: boolean;
  stopping?: boolean;
  progress?: { current: number; total: number } | null;
  disabled?: boolean;
}) {
  const toggled = !!running;
  const displayLabel = stopping
    ? "Stopping…"
    : running
    ? "Stop"
    : label;
  const title =
    (running
      ? stopping
        ? "Stopping — waiting for in-flight workers…"
        : `Stop ${label.toLowerCase()}`
      : label) + (running && progress ? ` — ${progress.current}/${progress.total}` : "");

  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className={
        "relative flex items-center gap-1.5 h-[30px] px-2.5 rounded-[5px] border text-[12px] transition-colors disabled:opacity-50 disabled:cursor-not-allowed " +
        (toggled
          ? "bg-rose-500/15 border-rose-400/50 text-rose-200 hover:bg-rose-500/20"
          : "bg-raised border-edge text-ink-secondary hover:text-ink hover:bg-overlay")
      }
      style={{
        fontFamily: "var(--font-ui)",
        // Y2K toggled shadow: inner gradient for the "pressed-in glass"
        // look, plus an outer rose glow that subtly pulses.
        boxShadow: toggled
          ? [
              "inset 0 1px 0 rgba(0,0,0,0.45)",
              "inset 0 -1px 0 rgba(255,255,255,0.08)",
              "inset 0 2px 6px rgba(244,63,94,0.35)",
              "0 0 0 1px rgba(244,63,94,0.25)",
              "0 0 14px rgba(244,63,94,0.45)",
            ].join(", ")
          : undefined,
        animation: toggled && !stopping ? "y2kPulse 1.6s ease-in-out infinite" : undefined,
      }}
    >
      {running ? (
        stopping ? (
          <span className="w-3 h-3 border border-rose-200/60 border-t-rose-200 rounded-full animate-spin" />
        ) : (
          // Stop glyph — square inside a faintly glowing ring.
          <span className="relative inline-flex items-center justify-center w-[13px] h-[13px]">
            <span
              className="absolute inset-0 rounded-full"
              style={{ boxShadow: "inset 0 0 0 1px rgba(244,63,94,0.55)" }}
            />
            <span
              className="w-[6px] h-[6px] rounded-[1px]"
              style={{
                background: "linear-gradient(180deg, #fda4af 0%, #e11d48 100%)",
                boxShadow: "0 0 4px rgba(244,63,94,0.7)",
              }}
            />
          </span>
        )
      ) : (
        <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.7}>
          <path strokeLinecap="round" strokeLinejoin="round" d={ICON_PATHS[icon]} />
        </svg>
      )}
      <span>
        {running && progress ? (
          <span className="tabular-nums" style={{ fontFamily: "var(--font-mono)" }}>
            {stopping ? displayLabel : `${progress.current}/${progress.total}`}
          </span>
        ) : (
          displayLabel
        )}
      </span>
    </button>
  );
}
