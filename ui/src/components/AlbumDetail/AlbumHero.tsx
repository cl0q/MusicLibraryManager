import type { Album } from "../../types/library";

interface AlbumHeroProps {
  album: Album;
  trackCount: number;
  totalDurationSec: number;
  onBack: () => void;
}

/**
 * Format a running total of seconds as `m:ss` or `h:mm:ss`. Used by the hero
 * meta line (matches PlaylistDetail pattern).
 */
function formatTotalDuration(totalSec: number): string {
  const safe = Math.max(0, Math.floor(totalSec));
  if (safe >= 3600) {
    const h = Math.floor(safe / 3600);
    const m = Math.floor((safe % 3600) / 60);
    const s = safe % 60;
    return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  }
  const m = Math.floor(safe / 60);
  const s = safe % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

/**
 * Hero row for the Album Detail page.
 *
 * Layout (UI-SPEC §Page Layout — Hero row):
 *   ←  [104×104 cover]   ALBUM
 *                        Title (26px display serif)
 *                        Artist (13px body)
 *                        {N} tracks · {m:ss} · {year}   (12px mono)
 *
 * The `Play` button is a disabled stub (Phase 21 has no playback) —
 * included to match PlaylistDetail layout visually.
 */
export function AlbumHero({
  album,
  trackCount,
  totalDurationSec,
  onBack,
}: AlbumHeroProps) {
  const metaParts: string[] = [
    `${trackCount} tracks`,
    formatTotalDuration(totalDurationSec),
  ];
  if (album.year != null) metaParts.push(String(album.year));
  const metaLine = metaParts.join(" · ");

  return (
    <div className="flex items-end gap-4 px-5 pt-5 pb-3.5 border-b border-edge-subtle shrink-0">
      <button
        type="button"
        onClick={onBack}
        aria-label="Back"
        className="text-ink-muted hover:text-ink transition-colors"
      >
        <svg
          className="w-4 h-4"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <polyline points="15 18 9 12 15 6" />
        </svg>
      </button>

      <div
        className="w-[104px] h-[104px] rounded-md overflow-hidden bg-raised shrink-0"
        style={{
          background:
            "linear-gradient(135deg, var(--color-accent), var(--color-base))",
        }}
      >
        {album.cover_path && (
          <img
            src={album.cover_path}
            alt={album.title ? `${album.title} cover` : "Album cover"}
            className="w-full h-full object-cover"
            onError={(e) => {
              (e.currentTarget as HTMLImageElement).style.display = "none";
            }}
          />
        )}
      </div>

      <div className="min-w-0 flex-1">
        <div className="text-[10px] text-ink-muted uppercase tracking-[0.1em] mb-1">
          ALBUM
        </div>
        <h1
          className="text-[26px] text-ink mb-1 truncate"
          title={album.title}
          style={{
            fontFamily: "var(--font-display)",
            fontWeight: 700,
            letterSpacing: "-0.5px",
            lineHeight: 1.1,
          }}
        >
          {album.title}
        </h1>
        <div
          className="text-[13px] text-ink-secondary truncate"
          title={album.album_artist}
        >
          {album.album_artist}
        </div>
        <div
          className="text-[12px] text-ink-muted tabular-nums truncate"
          style={{ fontFamily: "var(--font-mono)" }}
        >
          {metaLine}
        </div>
      </div>

      <button
        type="button"
        disabled
        title="Playback coming soon"
        className="text-ink-muted opacity-50 cursor-not-allowed"
        aria-label="Play album"
      >
        <svg
          className="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          aria-hidden="true"
        >
          <polygon points="8 5 19 12 8 19" />
        </svg>
      </button>
    </div>
  );
}
