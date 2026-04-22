import { useState, useEffect } from "react";
import { useNavigate, NavLink } from "react-router";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
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
  analyzeReplayGain,
  deepScan,
  getReviewQueueCount,
} from "../utils/tauri-commands";

interface LibraryBrowserProps {
  view?: "library" | "remote";
}

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

  useEffect(() => {
    invoke<number[]>("get_cached_track_ids")
      .then((ids) => setCachedTrackIds(new Set(ids)))
      .catch(() => {});
  }, [refreshKey]);

  const fingerprintProgress = useEnhancementProgress("fingerprint");
  const artworkProgress = useEnhancementProgress("artwork");
  const replaygainProgress = useEnhancementProgress("replaygain");
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

  const handleFingerprintLibrary = async () => {
    try { await fingerprintLibrary(); } catch (err) { console.error("Fingerprint failed:", err); }
  };
  const handleFetchArtwork = async () => {
    try { await fetchArtwork(); } catch (err) { console.error("Artwork failed:", err); }
  };
  const handleAnalyzeReplayGain = async () => {
    try { await analyzeReplayGain(); } catch (err) { console.error("ReplayGain failed:", err); }
  };
  const handleDeepScan = async () => {
    try {
      await deepScan();
      const count = await getReviewQueueCount();
      setReviewQueueCount(count);
    } catch (err) { console.error("Deep scan failed:", err); }
  };

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

  return (
    <div className="flex flex-col h-full">
      {/* Header bar: tabs + tools */}
      <div className="flex items-center justify-between px-4 h-11 border-b border-edge-subtle shrink-0">
        {/* View tabs */}
        <div className="flex items-center gap-0.5">
          <NavLink
            to="/"
            end
            className={({ isActive }) =>
              `px-3 py-1 text-[13px] rounded transition-colors ${
                isActive
                  ? "bg-raised text-ink font-medium"
                  : "text-ink-secondary hover:text-ink"
              }`
            }
          >
            Local
          </NavLink>
          <NavLink
            to="/remote"
            className={({ isActive }) =>
              `px-3 py-1 text-[13px] rounded transition-colors ${
                isActive
                  ? "bg-raised text-ink font-medium"
                  : "text-ink-secondary hover:text-ink"
              }`
            }
          >
            Remote
          </NavLink>
        </div>

        {/* Enhancement tools — compact toolbar */}
        {view === "library" && (
          <div className="flex items-center gap-0.5">
            <ToolButton
              label="Fingerprint"
              onClick={handleFingerprintLibrary}
              running={fingerprintProgress.isRunning}
              progress={fingerprintProgress.progress}
            />
            <ToolButton
              label="Artwork"
              onClick={handleFetchArtwork}
              running={artworkProgress.isRunning}
            />
            <ToolButton
              label="ReplayGain"
              onClick={handleAnalyzeReplayGain}
              running={replaygainProgress.isRunning}
              progress={replaygainProgress.progress}
            />
            <ToolButton
              label="Scan"
              onClick={handleDeepScan}
              running={deepscanProgress.isRunning}
            />
          </div>
        )}
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

      {/* Search + track count */}
      <div className="px-4 py-2.5 shrink-0">
        <FilterBar
          value={filterQuery}
          onChange={setFilterQuery}
          trackCount={tracks.length}
          loading={loading}
        />
      </div>

      {/* Track table */}
      <div className="flex-1 min-h-0 px-4 pb-2">
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
          <LibraryTable tracks={tracks} view={view} onOpenMoreInfo={handleOpenMoreInfo} cachedTrackIds={cachedTrackIds} />
        )}
      </div>

      <MoreInfoPanel track={moreInfoTrack} isOpen={moreInfoOpen} onClose={() => setMoreInfoOpen(false)} />
    </div>
  );
}

/** Compact toolbar button for enhancement tools */
function ToolButton({
  label,
  onClick,
  running,
  progress,
}: {
  label: string;
  onClick: () => void;
  running: boolean;
  progress?: { current: number; total: number } | null;
}) {
  return (
    <button
      onClick={onClick}
      disabled={running}
      className="px-2 py-1 text-[11px] text-ink-muted hover:text-ink hover:bg-raised rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
      title={label}
    >
      {running ? (
        <span className="flex items-center gap-1">
          <span className="w-2.5 h-2.5 border border-ink-muted border-t-sky-400 rounded-full animate-spin" />
          <span className="tabular-nums">
            {progress ? `${progress.current}/${progress.total}` : "..."}
          </span>
        </span>
      ) : (
        label
      )}
    </button>
  );
}
