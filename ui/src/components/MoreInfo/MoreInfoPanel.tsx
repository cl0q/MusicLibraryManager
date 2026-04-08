import { useEffect, useState } from "react";
import type { Track } from "../../types/library";
import CollapsibleSection from "./CollapsibleSection";
import {
  getTrackAnalysis,
  getTrackArtwork,
  generateTrackFingerprint,
  generateTrackWaveform,
  generateTrackSpectrogram,
} from "../../utils/tauri-commands";

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

export default function MoreInfoPanel({ track, isOpen, onClose }: MoreInfoPanelProps) {
  const [analysisData, setAnalysisData] = useState<TrackAnalysisData | null>(null);
  const [artworkSrc, setArtworkSrc] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!track || !isOpen) {
      setAnalysisData(null);
      setArtworkSrc(null);
      setError(null);
      return;
    }

    const loadData = async () => {
      setLoading(true);
      setError(null);
      try {
        if (!track.id) {
          setError("Track ID not available");
          setLoading(false);
          return;
        }
        const [data, artwork] = await Promise.all([
          getTrackAnalysis(track.id).catch(() => null),
          getTrackArtwork(track.id).catch(() => null),
        ]);
        if (data) setAnalysisData(data);
        else setError("Analysis data not available");
        setArtworkSrc(artwork);
      } catch (err) {
        console.log("Track data not available yet:", err);
        setError("Analysis data not available");
        setAnalysisData(null);
      } finally {
        setLoading(false);
      }
    };

    loadData();
  }, [track, isOpen]);

  if (!isOpen || !track) return null;

  const localPath = track.organized_path;

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-black/40 z-40"
        onClick={onClose}
      />

      {/* Slide-in panel */}
      <div
        className={`fixed top-0 right-0 h-full w-80 bg-surface border-l border-edge shadow-2xl z-50 transform transition-transform duration-200 ${
          isOpen ? "translate-x-0" : "translate-x-full"
        }`}
      >
        <div className="flex flex-col h-full">
          {/* Header */}
          <div className="flex items-center justify-between px-4 h-11 border-b border-edge shrink-0">
            <span className="text-xs font-semibold uppercase tracking-wide text-ink-secondary">Track Info</span>
            <button
              onClick={onClose}
              className="p-1 rounded hover:bg-raised transition-colors"
              aria-label="Close"
            >
              <svg className="w-4 h-4 text-ink-muted" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          {/* Content */}
          <div className="flex-1 overflow-y-auto">
            {/* Track overview */}
            <div className="p-4 border-b border-edge-subtle">
              <div className="w-full aspect-square bg-raised rounded-lg flex items-center justify-center mb-3 overflow-hidden">
                {artworkSrc ? (
                  <img
                    src={artworkSrc}
                    alt={`${track.metadata.album || track.metadata.title} artwork`}
                    className="w-full h-full object-cover rounded-lg"
                  />
                ) : (
                  <svg className="w-10 h-10 text-ink-muted" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z" />
                  </svg>
                )}
              </div>
              <h3 className="text-sm font-medium text-ink truncate">{track.metadata.title}</h3>
              <p className="text-xs text-ink-secondary truncate mt-0.5">{track.metadata.artist}</p>
              {track.metadata.album && (
                <p className="text-xs text-ink-muted truncate mt-0.5">{track.metadata.album}</p>
              )}
              <div className="flex items-center gap-2 mt-2 text-[11px] text-ink-muted">
                <span>{track.metadata.format?.toUpperCase() || "Unknown"}</span>
                {track.metadata.bitrate && (
                  <>
                    <span className="text-edge">·</span>
                    <span className="tabular-nums">
                      {track.metadata.bitrate > 10000
                        ? Math.round(track.metadata.bitrate / 1000)
                        : track.metadata.bitrate} kbps
                    </span>
                  </>
                )}
                {track.metadata.duration && (
                  <>
                    <span className="text-edge">·</span>
                    <span className="tabular-nums">{formatDuration(track.metadata.duration)}</span>
                  </>
                )}
              </div>
            </div>

            {/* Loading state */}
            {loading && (
              <div className="p-4 flex items-center gap-2 text-xs text-ink-muted">
                <span className="w-3 h-3 border border-ink-muted border-t-sky-400 rounded-full animate-spin" />
                Loading analysis...
              </div>
            )}

            {/* Error state */}
            {error && (
              <div className="p-4">
                <div className="bg-amber-500/10 border border-amber-500/20 rounded px-3 py-2">
                  <p className="text-xs text-amber-400">{error}</p>
                </div>
              </div>
            )}

            {/* FFprobe data */}
            {!loading && !error && analysisData?.ffprobe && (
              <>
                <CollapsibleSection title="Format" defaultOpen>
                  <div className="space-y-1.5">
                    <InfoRow label="Format" value={analysisData.ffprobe.format?.format_long_name || "Unknown"} />
                    <InfoRow label="Codec" value={analysisData.ffprobe.format?.format_name || "Unknown"} />
                    <InfoRow label="Duration" value={analysisData.ffprobe.format?.duration || "Unknown"} />
                    <InfoRow
                      label="Bitrate"
                      value={(() => {
                        const audioStream = analysisData.ffprobe?.streams?.find(s => s.sample_rate);
                        const streamBitrate = audioStream?.bit_rate;
                        if (streamBitrate) return `${Math.round(Number(streamBitrate) / 1000)} kbps`;
                        if (analysisData.ffprobe?.format?.bit_rate) return `${Math.round(Number(analysisData.ffprobe.format.bit_rate) / 1000)} kbps`;
                        return "Unknown";
                      })()}
                    />
                    <InfoRow
                      label="Size"
                      value={
                        analysisData.ffprobe.format?.size
                          ? formatBytes(Number(analysisData.ffprobe.format.size))
                          : "Unknown"
                      }
                    />
                  </div>
                </CollapsibleSection>

                {analysisData.ffprobe.streams && analysisData.ffprobe.streams.length > 0 && (
                  <CollapsibleSection title="Streams">
                    {analysisData.ffprobe.streams.map((stream, idx) => (
                      <div key={idx} className="mb-2 pb-2 border-b border-edge-subtle last:border-0">
                        <p className="text-xs font-medium text-ink-secondary mb-1">Stream {idx + 1}</p>
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

                <CollapsibleSection title="Raw FFprobe">
                  <pre className="text-[10px] bg-raised p-2 rounded overflow-x-auto text-ink-muted font-mono leading-relaxed">
                    {JSON.stringify(analysisData.ffprobe, null, 2)}
                  </pre>
                </CollapsibleSection>
              </>
            )}

            {/* Advanced analysis buttons and results */}
            {localPath && track.id && (
              <AdvancedAnalysis trackId={track.id} />
            )}

            {!localPath && (
              <div className="p-4">
                <div className="bg-amber-500/10 border border-amber-500/20 rounded px-3 py-2">
                  <p className="text-xs text-amber-400">
                    Analysis only available for downloaded tracks.
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

function AdvancedAnalysis({ trackId }: { trackId: number }) {
  const [waveform, setWaveform] = useState<string | null>(null);
  const [spectrogram, setSpectrogram] = useState<string | null>(null);
  const [fingerprint, setFingerprint] = useState<string | null>(null);
  const [running, setRunning] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const run = async (
    label: string,
    fn: () => Promise<string>,
    setter: (v: string) => void,
  ) => {
    setRunning(label);
    setError(null);
    try {
      const result = await fn();
      setter(result);
    } catch (err: unknown) {
      setError(String(err));
    } finally {
      setRunning(null);
    }
  };

  return (
    <div className="p-4 space-y-2 border-t border-edge-subtle">
      <p className="text-[10px] font-semibold uppercase tracking-wide text-ink-muted mb-2">
        Advanced Analysis
      </p>

      <button
        onClick={() => run("waveform", () => generateTrackWaveform(trackId), setWaveform)}
        disabled={running !== null}
        className="w-full px-3 py-1.5 text-xs text-ink bg-raised rounded hover:bg-edge transition-colors disabled:opacity-50"
      >
        {running === "waveform" ? "Generating..." : "Generate Waveform"}
      </button>
      {waveform && (
        <img src={waveform} alt="Waveform" className="w-full rounded border border-edge-subtle" />
      )}

      <button
        onClick={() => run("spectrogram", () => generateTrackSpectrogram(trackId), setSpectrogram)}
        disabled={running !== null}
        className="w-full px-3 py-1.5 text-xs text-ink bg-raised rounded hover:bg-edge transition-colors disabled:opacity-50"
      >
        {running === "spectrogram" ? "Generating..." : "Generate Spectrogram"}
      </button>
      {spectrogram && (
        <img src={spectrogram} alt="Spectrogram" className="w-full rounded border border-edge-subtle" />
      )}

      <button
        onClick={() => run("fingerprint", () => generateTrackFingerprint(trackId), setFingerprint)}
        disabled={running !== null}
        className="w-full px-3 py-1.5 text-xs text-ink bg-raised rounded hover:bg-edge transition-colors disabled:opacity-50"
      >
        {running === "fingerprint" ? "Generating..." : "Generate Fingerprint"}
      </button>
      {fingerprint && (
        <pre className="text-[10px] bg-raised p-2 rounded overflow-x-auto text-ink-muted font-mono leading-relaxed max-h-32 overflow-y-auto">
          {fingerprint}
        </pre>
      )}

      {error && (
        <p className="text-[10px] text-red-400 bg-red-500/10 rounded px-2 py-1">{error}</p>
      )}
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between items-start gap-2">
      <span className="text-[11px] text-ink-muted shrink-0">{label}</span>
      <span className="text-[11px] text-ink font-mono text-right break-all">{value}</span>
    </div>
  );
}

function formatDuration(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${minutes}:${secs.toString().padStart(2, "0")}`;
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
}
