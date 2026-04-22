import { useEffect, useState } from "react";
import type { Track } from "../../types/library";
import EnergyBars from "../LibraryTable/EnergyBars";
import {
  getTrackAnalysis,
  getTrackArtwork,
} from "../../utils/tauri-commands";

/**
 * MoreInfoPanel — Solar sectioned track detail.
 *
 * Mock: `screens.jsx` MoreInfoScreen. Per CONTRACT §2:
 *  - No BPM row (scope cut).
 *  - No Key row (scope cut).
 *  - Energy row shown only when `energy_bucket` is populated.
 *  - No big "now playing" waveform visual.
 *
 * Sections: Musical / File / Loudness / Library. Loudness values render
 * "—" when null so users know an analysis pass hasn't run yet.
 */
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
}

export default function MoreInfoPanel({ track, isOpen, onClose }: MoreInfoPanelProps) {
  const [analysisData, setAnalysisData] = useState<TrackAnalysisData | null>(null);
  const [artworkSrc, setArtworkSrc] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!track || !isOpen) {
      setAnalysisData(null);
      setArtworkSrc(null);
      return;
    }

    const loadData = async () => {
      setLoading(true);
      try {
        if (!track.id) {
          setLoading(false);
          return;
        }
        const [data, artwork] = await Promise.all([
          getTrackAnalysis(track.id).catch(() => null),
          getTrackArtwork(track.id).catch(() => null),
        ]);
        if (data) setAnalysisData(data);
        setArtworkSrc(artwork);
      } catch (err) {
        console.log("Track data not available yet:", err);
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
      <div className="fixed inset-0 bg-black/40 z-40" onClick={onClose} />

      {/* Slide-in panel */}
      <div
        className={`fixed top-0 right-0 h-full w-80 bg-surface border-l border-edge shadow-2xl z-50 transform transition-transform duration-200 ${
          isOpen ? "translate-x-0" : "translate-x-full"
        }`}
        style={{ fontFamily: "var(--font-ui)" }}
      >
        <div className="flex flex-col h-full">
          {/* Header */}
          <div className="flex items-center justify-between px-4 h-11 border-b border-edge shrink-0">
            <span className="text-[10px] font-semibold uppercase tracking-[0.1em] text-ink-muted">
              Track info
            </span>
            <button
              onClick={onClose}
              className="p-1 rounded hover:bg-raised transition-colors"
              aria-label="Close"
            >
              <svg className="w-4 h-4 text-ink-muted" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.8}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          </div>

          {/* Content */}
          <div className="flex-1 overflow-y-auto">
            {/* Artwork + title block */}
            <div className="p-4 border-b border-edge-subtle">
              <div className="w-full aspect-square bg-raised rounded-[4px] overflow-hidden flex items-center justify-center mb-3">
                {artworkSrc ? (
                  <img
                    src={artworkSrc}
                    alt={`${track.metadata.album || track.metadata.title} artwork`}
                    className="w-full h-full object-cover"
                  />
                ) : (
                  <svg className="w-10 h-10 text-ink-muted" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z" />
                  </svg>
                )}
              </div>
              <div className="text-[16px] font-semibold text-ink" style={{ letterSpacing: "-0.3px" }}>
                {track.metadata.title || "Unknown"}
              </div>
              <div className="text-[13px] text-ink-secondary mt-0.5">
                {track.metadata.artist || "Unknown artist"}
              </div>
              {track.metadata.album && (
                <div
                  className="text-[11px] text-ink-muted mt-0.5 truncate"
                  style={{ fontFamily: "var(--font-mono)" }}
                >
                  {track.metadata.album}
                </div>
              )}
            </div>

            {loading && (
              <div className="p-4 flex items-center gap-2 text-xs text-ink-muted">
                <span className="w-3 h-3 border border-ink-muted border-t-sky-400 rounded-full animate-spin" />
                Loading analysis…
              </div>
            )}

            {/* Musical */}
            <MetaSection title="Musical">
              <MetaRow k="Genre" v={track.metadata.genre || "—"} />
              {track.energy_bucket != null && (
                <MetaRow k="Energy" v={<EnergyBars value={track.energy_bucket} />} />
              )}
              {track.metadata.year != null && (
                <MetaRow k="Year" v={<span style={{ fontFamily: "var(--font-mono)" }}>{track.metadata.year}</span>} />
              )}
            </MetaSection>

            {/* File */}
            <MetaSection title="File">
              <MetaRow k="Format" v={(track.metadata.format || "—").toUpperCase()} />
              <MetaRow
                k="Bitrate"
                v={
                  track.metadata.bitrate != null ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {track.metadata.bitrate > 10000
                        ? Math.round(track.metadata.bitrate / 1000)
                        : track.metadata.bitrate}{" "}
                      kbps
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              <MetaRow
                k="Duration"
                v={
                  track.metadata.duration != null ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {formatDuration(track.metadata.duration)}
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              <MetaRow
                k="Size"
                v={
                  analysisData?.ffprobe?.format?.size ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {formatBytes(Number(analysisData.ffprobe.format.size))}
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              <MetaRow
                k="Path"
                v={
                  <span
                    className="text-[10px] text-ink-muted"
                    style={{
                      fontFamily: "var(--font-mono)",
                      wordBreak: "break-all",
                      overflowWrap: "anywhere",
                    }}
                  >
                    {localPath || track.metadata.original_path || "—"}
                  </span>
                }
              />
            </MetaSection>

            {/* Loudness */}
            <MetaSection title="Loudness">
              <MetaRow
                k="Peak"
                v={
                  track.true_peak != null ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {formatSigned(track.true_peak, 1)} dB
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              <MetaRow
                k="LUFS-I"
                v={
                  track.lufs_i != null ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {formatSigned(track.lufs_i, 1)}
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              <MetaRow
                k="LRA"
                v={
                  track.lufs_range != null ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {track.lufs_range.toFixed(1)} LU
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              {/* Gain — fall back to "—" until the replaygain fetch per track is wired */}
              <MetaRow k="Gain" v="—" />
            </MetaSection>

            {/* Library */}
            <MetaSection title="Library">
              <MetaRow
                k="Added"
                v={
                  track.date_added ? (
                    <span style={{ fontFamily: "var(--font-mono)" }}>
                      {formatDate(track.date_added)}
                    </span>
                  ) : (
                    "—"
                  )
                }
              />
              <MetaRow k="Plays" v="—" />
              <MetaRow k="Rating" v="—" />
            </MetaSection>

            {!localPath && (
              <div className="p-4">
                <div className="bg-amber-500/10 border border-amber-500/20 rounded px-3 py-2">
                  <p className="text-xs text-amber-400">
                    Full analysis only available once this track is downloaded.
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

/* ── Atoms ───────────────────────────────────────── */

function MetaSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="px-4 py-2.5 border-b border-edge-subtle">
      <div className="text-[10px] font-semibold uppercase tracking-[0.1em] text-ink-muted mb-1.5">
        {title}
      </div>
      <div className="flex flex-col gap-[5px]">{children}</div>
    </div>
  );
}

function MetaRow({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex items-baseline gap-2.5 text-[12px]">
      <span className="text-ink-muted shrink-0" style={{ width: 72 }}>
        {k}
      </span>
      <span className="text-ink flex-1 min-w-0">{v}</span>
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

function formatSigned(value: number, digits: number): string {
  // Always include a sign so -11.4 and +0.3 read consistently in a column.
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  const abs = Math.abs(value).toFixed(digits);
  return `${sign}${abs}`;
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
  } catch {
    return iso;
  }
}
