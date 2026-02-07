import { useState, useEffect } from "react";
import { useNavigate } from "react-router";
import { useLibraryTracks } from "../hooks/useLibraryTracks";
import { useEnhancementProgress } from "../hooks/useEnhancements";
import { useLibraryMount } from "../contexts/LibraryMountContext";
import LibraryTable from "../components/LibraryTable/LibraryTable";
import FilterBar from "../components/LibraryTable/FilterBar";
import ReviewQueue from "../components/ReviewQueue/ReviewQueue";
import {
  fingerprintLibrary,
  fetchArtwork,
  analyzeReplayGain,
  deepScan,
  getReviewQueueCount,
} from "../utils/tauri-commands";

export default function LibraryBrowser() {
  const navigate = useNavigate();
  const { mountState, isLibraryAvailable } = useLibraryMount();
  const [showReviewQueue, setShowReviewQueue] = useState(false);
  const [reviewQueueCount, setReviewQueueCount] = useState(0);
  const [refreshKey, setRefreshKey] = useState(0);

  const { tracks, loading, filterQuery, setFilterQuery } = useLibraryTracks(refreshKey);

  const fingerprintProgress = useEnhancementProgress("fingerprint");
  const artworkProgress = useEnhancementProgress("artwork");
  const replaygainProgress = useEnhancementProgress("replaygain");
  const deepscanProgress = useEnhancementProgress("deepscan");

  // Load review queue count on mount
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

  // Listen for library reconnection events to auto-refresh
  useEffect(() => {
    const handleReconnect = () => {
      // Increment refresh key to trigger re-fetch in useLibraryTracks
      setRefreshKey((prev) => prev + 1);
    };
    window.addEventListener("library-reconnected", handleReconnect);
    return () => window.removeEventListener("library-reconnected", handleReconnect);
  }, []);

  const handleFingerprintLibrary = async () => {
    try {
      const result = await fingerprintLibrary();
      console.log("Fingerprint result:", result);
    } catch (err) {
      console.error("Failed to fingerprint library:", err);
    }
  };

  const handleFetchArtwork = async () => {
    try {
      const result = await fetchArtwork();
      console.log("Artwork result:", result);
    } catch (err) {
      console.error("Failed to fetch artwork:", err);
    }
  };

  const handleAnalyzeReplayGain = async () => {
    try {
      const result = await analyzeReplayGain();
      console.log("ReplayGain result:", result);
    } catch (err) {
      console.error("Failed to analyze ReplayGain:", err);
    }
  };

  const handleDeepScan = async () => {
    try {
      const result = await deepScan();
      console.log("Deep scan result:", result);
      // Refresh review queue count after deep scan
      const count = await getReviewQueueCount();
      setReviewQueueCount(count);
    } catch (err) {
      console.error("Failed to run deep scan:", err);
    }
  };

  // Show disconnected state if library is not available
  if (!isLibraryAvailable) {
    return (
      <div className="flex flex-col items-center justify-center h-full p-6 text-center">
        <div className="max-w-md space-y-4">
          {/* Hard drive icon */}
          <svg
            className="w-16 h-16 mx-auto text-gray-400"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M8 7H5a2 2 0 00-2 2v9a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-3m-1 4l-3 3m0 0l-3-3m3 3V4"
            />
          </svg>
          <h2 className="text-xl font-semibold text-gray-700 dark:text-gray-300">
            {mountState === "not_configured"
              ? "Library Not Configured"
              : "Library Drive Not Connected"}
          </h2>
          <p className="text-gray-500 dark:text-gray-400">
            {mountState === "not_configured"
              ? "Set up your music library location to browse your collection."
              : "Connect your external drive to access your music library."}
          </p>
          <button
            onClick={() => navigate("/settings")}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
          >
            Open Settings
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full p-6 space-y-6">
      <h1 className="text-2xl font-bold text-gray-900 dark:text-white">
        Library
      </h1>

      {/* Enhancement Actions */}
      <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
        <h2 className="text-lg font-semibold mb-3 text-gray-900 dark:text-gray-100">
          Enhancement Tools
        </h2>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
          <button
            onClick={handleFingerprintLibrary}
            disabled={fingerprintProgress.isRunning}
            className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {fingerprintProgress.isRunning ? (
              <span className="flex items-center justify-center gap-2">
                <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-white"></div>
                Fingerprinting... {fingerprintProgress.progress?.current}/{fingerprintProgress.progress?.total}
              </span>
            ) : (
              "Fingerprint Library"
            )}
          </button>

          <button
            onClick={handleFetchArtwork}
            disabled={artworkProgress.isRunning}
            className="px-4 py-2 bg-purple-600 text-white rounded hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {artworkProgress.isRunning ? (
              <span className="flex items-center justify-center gap-2">
                <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-white"></div>
                Fetching Artwork...
              </span>
            ) : (
              "Fetch Artwork"
            )}
          </button>

          <button
            onClick={handleAnalyzeReplayGain}
            disabled={replaygainProgress.isRunning}
            className="px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {replaygainProgress.isRunning ? (
              <span className="flex items-center justify-center gap-2">
                <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-white"></div>
                Analyzing... {replaygainProgress.progress?.current}/{replaygainProgress.progress?.total}
              </span>
            ) : (
              "Analyze ReplayGain"
            )}
          </button>

          <button
            onClick={handleDeepScan}
            disabled={deepscanProgress.isRunning}
            className="px-4 py-2 bg-orange-600 text-white rounded hover:bg-orange-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {deepscanProgress.isRunning ? (
              <span className="flex items-center justify-center gap-2">
                <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-white"></div>
                Scanning...
              </span>
            ) : (
              "Deep Scan"
            )}
          </button>
        </div>
      </div>

      {/* Review Queue Section */}
      <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
        <button
          onClick={() => setShowReviewQueue(!showReviewQueue)}
          className="w-full flex items-center justify-between text-lg font-semibold text-gray-900 dark:text-gray-100 hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
        >
          <span className="flex items-center gap-2">
            Review Queue
            {reviewQueueCount > 0 && (
              <span className="px-2 py-0.5 bg-red-500 text-white text-xs rounded-full">
                {reviewQueueCount}
              </span>
            )}
          </span>
          <svg
            className={`w-5 h-5 transform transition-transform ${
              showReviewQueue ? "rotate-180" : ""
            }`}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M19 9l-7 7-7-7"
            />
          </svg>
        </button>
        {showReviewQueue && (
          <div className="mt-4">
            <ReviewQueue />
          </div>
        )}
      </div>

      {/* Library Table */}
      <FilterBar
        value={filterQuery}
        onChange={setFilterQuery}
        trackCount={tracks.length}
        loading={loading}
      />

      <div className="flex-1 min-h-0">
        {loading ? (
          <div className="flex items-center justify-center h-full">
            <div className="text-gray-600 dark:text-gray-400">
              Loading library...
            </div>
          </div>
        ) : tracks.length === 0 ? (
          <div className="flex items-center justify-center h-full">
            <div className="text-gray-600 dark:text-gray-400">
              {filterQuery
                ? "No tracks match your search"
                : "No tracks in library"}
            </div>
          </div>
        ) : (
          <LibraryTable tracks={tracks} />
        )}
      </div>
    </div>
  );
}
