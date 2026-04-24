import type { Track } from "../../types/library";

interface AlbumTracklistProps {
  tracks: Track[];
  /** When true, apply the `.ufo-crossfade` class so the container fades through
   *  the 500ms UFO-opening animation window. Defaults to false so initial
   *  page mounts stay static. */
  animating?: boolean;
}

/**
 * Format a duration in seconds as `m:ss`. Null/undefined renders as `—`.
 */
function formatDuration(sec: number | null | undefined): string {
  if (sec == null) return "—";
  const safe = Math.max(0, Math.floor(sec));
  const m = Math.floor(safe / 60);
  const s = safe % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

/**
 * Tracklist table for the Album Detail page.
 *
 * Grid columns (per UI-SPEC §Tracklist): `#` (40px) · Title (1fr) · Time (60)
 * · Fmt (60) · Kbps (70), each row at `var(--row-h, 36px)`.
 *
 * Empty-tracks copy is verbatim per UI-SPEC §Copywriting Contract —
 * "This album has no tracks."
 *
 * The parent forces remount via a `key={selectedAlbumId}` prop so the new
 * variant's track data is instantly swapped in at the 50% keyframe of the
 * UFO animation. The `animating` prop toggles `.ufo-crossfade` on the
 * container for the 500ms animation window so the swap reads as a fade-dip
 * rather than an instant replace.
 */
export function AlbumTracklist({ tracks, animating = false }: AlbumTracklistProps) {
  const crossfadeClass = animating ? " ufo-crossfade" : "";

  if (tracks.length === 0) {
    return (
      <div className={`border border-edge rounded-md bg-surface p-6${crossfadeClass}`}>
        <p className="text-ink-muted text-[13px]">
          This album has no tracks.
        </p>
      </div>
    );
  }

  return (
    <div className={`border border-edge rounded-md bg-surface overflow-hidden${crossfadeClass}`}>
      <div
        className="grid items-center gap-3 px-3 py-2 text-[10px] text-ink-muted uppercase border-b border-edge"
        style={{
          gridTemplateColumns: "40px 1fr 60px 60px 70px",
          letterSpacing: "0.08em",
          fontWeight: 600,
        }}
      >
        <span className="text-right">#</span>
        <span>Title</span>
        <span className="text-right">Time</span>
        <span className="text-right">Fmt</span>
        <span className="text-right">Kbps</span>
      </div>
      {tracks.map((track, idx) => {
        const fmtRaw = track.metadata.format || "—";
        const fmt = fmtRaw === "—" ? "—" : fmtRaw.toUpperCase();
        const bitrateRaw = track.metadata.bitrate;
        const bitrateDisplay =
          bitrateRaw == null
            ? "—"
            : bitrateRaw > 10000
              ? Math.round(bitrateRaw / 1000)
              : bitrateRaw;
        return (
          <div
            key={track.id ?? `idx-${idx}`}
            className="grid items-center gap-3 px-3 border-t border-edge-subtle hover:bg-raised/60 transition-colors"
            style={{
              gridTemplateColumns: "40px 1fr 60px 60px 70px",
              height: "var(--row-h, 36px)",
            }}
          >
            <span
              className="text-[12px] text-ink-muted text-right tabular-nums"
              style={{ fontFamily: "var(--font-mono)" }}
            >
              {idx + 1}
            </span>
            <span
              className="text-[13px] text-ink truncate"
              title={track.metadata.title}
            >
              {track.metadata.title}
            </span>
            <span
              className="text-[12px] text-ink-muted text-right tabular-nums"
              style={{ fontFamily: "var(--font-mono)" }}
            >
              {formatDuration(track.metadata.duration)}
            </span>
            <span
              className="text-[10px] text-ink-muted text-right uppercase"
              style={{
                fontFamily: "var(--font-mono)",
                letterSpacing: "0.06em",
              }}
            >
              {fmt}
            </span>
            <span
              className="text-[12px] text-ink-muted text-right tabular-nums"
              style={{ fontFamily: "var(--font-mono)" }}
            >
              {bitrateDisplay}
            </span>
          </div>
        );
      })}
    </div>
  );
}
