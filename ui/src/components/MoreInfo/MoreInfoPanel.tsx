import { useEffect, useState } from "react";
import type { Track } from "../../types/library";
import CollapsibleSection from "./CollapsibleSection";
import { getTrackAnalysis } from "../../utils/tauri-commands";

interface MoreInfoPanelProps {
  track: Track | null;
  isOpen: boolean;
  onClose: () => void;
}

interface TrackAnalysisData {
  ffprobe?: {
    format?: {
      filename?: string;
      format_name?: string;
      format_long_name?: string;
      duration?: string;
      size?: string;
      bit_rate?: string;
    };
    streams?: Array<{
      codec_name?: string;
      codec_long_name?: string;
      sample_rate?: string;
      channels?: number;
      bit_rate?: string;
      duration?: string;
    }>;
  };
  fingerprint?: string;
  waveform_path?: string;
  spectrogram_path?: string;
}

export default function MoreInfoPanel({
  track,
  isOpen,
  onClose,
}: MoreInfoPanelProps) {
  const [analysisData, setAnalysisData] = useState<TrackAnalysisData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Load ffprobe data automatically when panel opens or track changes
  useEffect(() => {
    if (!track || !isOpen) {
      setAnalysisData(null);
      setError(null);
      return;
    }

    const loadAnalysis = async () => {
      setLoading(true);
      setError(null);
      try {
        const data = await getTrackAnalysis(track.id!);
        setAnalysisData(data);
      } catch (err) {
        // Backend command doesn't exist yet (Plan 03) - graceful fallback
        console.log("Track analysis not available yet:", err);
        setError("Analysis data not available (backend pending Plan 03)");
        setAnalysisData(null);
      } finally {
        setLoading(false);
      }
    };

    loadAnalysis();
  }, [track, isOpen]);

  if (!isOpen || !track) return null;

  const localPath = track.organized_path || track.metadata.original_path;

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-black bg-opacity-25 z-40 transition-opacity"
        onClick={onClose}
      />

      {/* Slide-in Panel */}
      <div
        className={`fixed top-0 right-0 h-full w-96 bg-white dark:bg-gray-900 shadow-xl z-50 transform transition-transform duration-300 ease-in-out ${
          isOpen ? "translate-x-0" : "translate-x-full"
        }`}
      >
        <div className="flex flex-col h-full">
          {/* Header with close button */}
          <div className="flex items-center justify-between p-4 border-b border-gray-200 dark:border-gray-700">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white">
              More Info
            </h2>
            <button
              onClick={onClose}
              className="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
              aria-label="Close panel"
            >
              <svg
                className="w-5 h-5 text-gray-500 dark:text-gray-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          {/* Scrollable content */}
          <div className="flex-1 overflow-y-auto">
            {/* Track Overview */}
            <div className="p-4 border-b border-gray-200 dark:border-gray-700">
              {/* Artwork placeholder */}
              <div className="mb-4 aspect-square bg-gray-200 dark:bg-gray-700 rounded-lg flex items-center justify-center">
                <svg
                  className="w-16 h-16 text-gray-400 dark:text-gray-500"
                  fill="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z" />
                </svg>
              </div>

              {/* Track metadata */}
              <div className="space-y-2">
                <h3 className="text-lg font-bold text-gray-900 dark:text-white truncate">
                  {track.metadata.title}
                </h3>
                <p className="text-sm text-gray-600 dark:text-gray-400 truncate">
                  {track.metadata.artist}
                </p>
                <p className="text-sm text-gray-600 dark:text-gray-400 truncate">
                  {track.metadata.album}
                </p>
                <p className="text-xs text-gray-500 dark:text-gray-500">
                  {track.metadata.format?.toUpperCase() || "Unknown format"}
                  {track.metadata.bitrate && ` • ${track.metadata.bitrate} kbps`}
                  {track.metadata.duration && ` • ${formatDuration(track.metadata.duration)}`}
                </p>
              </div>
            </div>

            {/* Technical Data Sections */}
            {loading && (
              <div className="p-4 text-center text-gray-500 dark:text-gray-400">
                <div className="inline-flex items-center gap-2">
                  <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-gray-500"></div>
                  Loading analysis data...
                </div>
              </div>
            )}

            {error && (
              <div className="p-4">
                <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
                  <p className="text-sm text-yellow-800 dark:text-yellow-200">{error}</p>
                </div>
              </div>
            )}

            {!loading && !error && analysisData?.ffprobe && (
              <>
                <CollapsibleSection title="Format Information" defaultOpen={true}>
                  <div className="space-y-2">
                    <InfoRow
                      label="Format"
                      value={analysisData.ffprobe.format?.format_long_name || "Unknown"}
                    />
                    <InfoRow
                      label="Codec"
                      value={analysisData.ffprobe.format?.format_name || "Unknown"}
                    />
                    <InfoRow
                      label="Duration"
                      value={analysisData.ffprobe.format?.duration || "Unknown"}
                    />
                    <InfoRow
                      label="Bitrate"
                      value={
                        analysisData.ffprobe.format?.bit_rate
                          ? `${Math.round(Number(analysisData.ffprobe.format.bit_rate) / 1000)} kbps`
                          : "Unknown"
                      }
                    />
                    <InfoRow
                      label="File Size"
                      value={
                        analysisData.ffprobe.format?.size
                          ? formatBytes(Number(analysisData.ffprobe.format.size))
                          : "Unknown"
                      }
                    />
                  </div>
                </CollapsibleSection>

                {analysisData.ffprobe.streams && analysisData.ffprobe.streams.length > 0 && (
                  <CollapsibleSection title="Stream Information">
                    {analysisData.ffprobe.streams.map((stream, idx) => (
                      <div key={idx} className="mb-3 pb-3 border-b border-gray-200 dark:border-gray-700 last:border-0">
                        <p className="font-medium mb-2">Stream {idx + 1}</p>
                        <div className="space-y-1">
                          <InfoRow label="Codec" value={stream.codec_long_name || stream.codec_name || "Unknown"} />
                          {stream.sample_rate && (
                            <InfoRow label="Sample Rate" value={`${Number(stream.sample_rate) / 1000} kHz`} />
                          )}
                          {stream.channels && (
                            <InfoRow label="Channels" value={stream.channels.toString()} />
                          )}
                          {stream.bit_rate && (
                            <InfoRow label="Bitrate" value={`${Math.round(Number(stream.bit_rate) / 1000)} kbps`} />
                          )}
                        </div>
                      </div>
                    ))}
                  </CollapsibleSection>
                )}

                <CollapsibleSection title="FFprobe Output (Raw)">
                  <pre className="text-xs bg-gray-50 dark:bg-gray-800 p-3 rounded overflow-x-auto">
                    {JSON.stringify(analysisData.ffprobe, null, 2)}
                  </pre>
                </CollapsibleSection>
              </>
            )}

            {/* On-demand analysis buttons */}
            {localPath && (
              <div className="p-4 space-y-3 border-t border-gray-200 dark:border-gray-700">
                <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100 mb-2">
                  Advanced Analysis
                </h3>
                <button
                  disabled
                  className="w-full px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-500 dark:text-gray-400 rounded hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                  title="Available after Plan 03 backend implementation"
                >
                  Generate Waveform
                </button>
                <button
                  disabled
                  className="w-full px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-500 dark:text-gray-400 rounded hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                  title="Available after Plan 03 backend implementation"
                >
                  Generate Spectrogram
                </button>
                <button
                  disabled
                  className="w-full px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-500 dark:text-gray-400 rounded hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                  title="Available after Plan 03 backend implementation"
                >
                  Generate Fingerprint
                </button>
              </div>
            )}

            {!localPath && (
              <div className="p-4">
                <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
                  <p className="text-sm text-yellow-800 dark:text-yellow-200">
                    Advanced analysis is only available for downloaded tracks.
                  </p>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </>
  );
}

// Helper component for info rows
function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between items-start gap-2">
      <span className="text-gray-600 dark:text-gray-400 text-xs">{label}:</span>
      <span className="text-gray-900 dark:text-white text-xs font-mono text-right break-all">
        {value}
      </span>
    </div>
  );
}

// Helper functions
function formatDuration(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${minutes}:${secs.toString().padStart(2, "0")}`;
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 Bytes";
  const k = 1024;
  const sizes = ["Bytes", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return Math.round((bytes / Math.pow(k, i)) * 100) / 100 + " " + sizes[i];
}
