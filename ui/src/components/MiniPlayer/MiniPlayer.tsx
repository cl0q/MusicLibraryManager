/**
 * MiniPlayer — Phase 29 Plan 03 persistent now-playing chrome.
 *
 * Surfaces what's playing across all routes. Subscribes to PlaybackContext
 * (D-04 locked shape); renders nothing when status === 'idle' (D-15).
 *
 * Locked decisions enforced inline:
 *   D-04 read-only consumer of the locked PlaybackContext API
 *   D-14 mounted between <main> and <ActivityPanel> in MainLayout (caller's job)
 *   D-15 status === 'idle' → render null (no startup chrome)
 *   D-16 layout: title + artist (left), play/pause (center), time (right),
 *        progress bar full-width below
 *   D-16/D-23 status === 'error' → error message replaces title/artist;
 *             progress bar hidden; play button disabled
 *   D-17 progress bar click seeks; click position clamped to [0, 1]
 *        BEFORE multiplying by duration (T-29-03 double-clamp w/ context)
 *   D-18 NO volume slider, NO <input type="range"> anywhere
 *
 * Solar tokens used (verified against ActivityPanel.tsx):
 *   bg-surface, border-edge, text-ink, text-ink-muted, bg-raised, bg-accent
 *   --row-h: 36px → Tailwind `h-9`
 *   --font-ui (UI labels), --font-mono with tabular-nums (time display)
 */

import type { MouseEvent } from "react";

import { usePlayback } from "../../contexts/PlaybackContext";

// Inline SVG play/pause icons. The codebase has no lucide-react dep
// (ActivityPanel ships its own inline chevrons); matching the existing
// pattern keeps the bundle and dependency surface stable.
function PlayIcon({ size = 16 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M8 5v14l11-7z" />
    </svg>
  );
}

function PauseIcon({ size = 16 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M6 5h4v14H6zM14 5h4v14h-4z" />
    </svg>
  );
}

// Inline helper — formats seconds as m:ss. Returns "--:--" for non-finite or
// negative values so the time display stays width-stable while loading.
function formatTime(seconds: number): string {
  if (!isFinite(seconds) || seconds < 0) return "--:--";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export default function MiniPlayer() {
  const {
    currentTrack,
    status,
    position,
    duration,
    error,
    togglePlayPause,
    seek,
  } = usePlayback();

  // D-15: hidden when idle — no startup chrome.
  if (status === "idle") return null;

  // Empty-string metadata is treated the same as null per the UI-SPEC fallback
  // contract (Track.metadata.{title,artist} is `string` in the type, but DB
  // rows can be empty in practice — guard both).
  const rawTitle = currentTrack?.metadata?.title;
  const rawArtist = currentTrack?.metadata?.artist;
  const title = rawTitle && rawTitle.length > 0 ? rawTitle : "Unknown track";
  const artist = rawArtist && rawArtist.length > 0 ? rawArtist : "Unknown artist";

  const isError = status === "error";
  const isLoading = status === "loading";
  const progressPercent = duration > 0 ? (position / duration) * 100 : 0;

  // D-17 + T-29-03: clamp click percent to [0, 1] before multiplying by
  // duration. PlaybackContext.seek() also clamps to [0, audio.duration]
  // — we double-clamp here so a NaN duration or zero-width bar can never
  // produce NaN seconds.
  const handleProgressClick = (e: MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    if (rect.width <= 0 || !isFinite(duration) || duration <= 0) return;
    const percent = (e.clientX - rect.left) / rect.width;
    const clamped = Math.max(0, Math.min(1, percent));
    seek(clamped * duration);
  };

  return (
    <div
      data-testid="mini-player"
      className="border-t border-edge bg-surface flex flex-col shrink-0"
      style={{ fontFamily: "var(--font-ui)" }}
    >
      {/* Main content row: 36px (--row-h, matches ActivityPanel collapsed bar) */}
      <div className="h-9 px-4 flex items-center gap-3 text-xs">
        {/* Left: title + artist (or inline error per D-16/D-23) */}
        <div className="flex flex-col min-w-0 flex-1 gap-0.5 leading-tight">
          {isError ? (
            <span className="text-ink-muted truncate text-[12px]">
              {error ?? "Playback error"}
            </span>
          ) : (
            <>
              <span
                className="text-ink truncate text-[13px]"
                title={title}
              >
                {title}
              </span>
              <span
                className="text-ink-muted truncate text-[11px]"
                title={artist}
              >
                {artist}
              </span>
            </>
          )}
        </div>

        {/* Center: play/pause toggle. Plain <button> — this codebase has no
            shadcn Button component (would be ../ui/button). Mirrors the
            chrome-button pattern in ActivityPanel.tsx. */}
        <button
          type="button"
          onClick={() => togglePlayPause()}
          disabled={isError || isLoading}
          aria-label={status === "playing" ? "Pause" : "Play"}
          className="flex-shrink-0 p-1 hover:bg-raised/30 transition-colors rounded text-ink disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {status === "playing" ? <PauseIcon size={16} /> : <PlayIcon size={16} />}
        </button>

        {/* Right: time display (Plex Mono, tabular-nums). Fixed width so
            the row layout doesn't jump as digits change. */}
        <div
          className="shrink-0 w-20 text-right text-ink-muted tabular-nums text-[11px]"
          style={{ fontFamily: "var(--font-mono)" }}
        >
          {isError || isLoading
            ? "-- / --"
            : `${formatTime(position)} / ${formatTime(duration)}`}
        </div>
      </div>

      {/* Progress bar — full width, 4px tall, clickable seek (D-17).
          Custom <div role="progressbar"> — NOT <input type="range"> (D-18). */}
      {!isError && (
        <div
          className="h-1 bg-raised cursor-pointer"
          onClick={handleProgressClick}
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={isFinite(duration) && duration > 0 ? duration : 0}
          aria-valuenow={isFinite(position) ? position : 0}
          aria-label="Playback progress"
        >
          <div
            className="h-full bg-accent"
            style={{ width: `${progressPercent}%` }}
          />
        </div>
      )}
    </div>
  );
}
