import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { setVariantPreference } from "../../utils/tauri-commands";

interface UfoToggleProps {
  baseAlbumId: number;
  variantAlbumId: number;
  variantKind: string | null;
  selectedAlbumId: number;
  onSelect: (newSelectedAlbumId: number) => void;
}

/**
 * Map a `variant_kind` DB value to its display label (UI-SPEC §Typography).
 * The "u" variant renders as "[U]" — the bracket is part of the spec.
 */
const VARIANT_LABELS: Record<string, string> = {
  "u": "[U]",
  "0.5": "0.5",
  "v1": "V1",
  "v2": "V2",
  "v4": "V4",
};

function displayVariantLabel(kind: string | null): string {
  if (kind == null) return "?";
  return VARIANT_LABELS[kind] ?? "?";
}

/**
 * Two-state variant selector for Yeat albums with exactly one sibling.
 *
 * Geometry (21-UI-SPEC.md §Geometry — LOCKED):
 * - 180×44px outer pill, 22px radius, 1px #8a97b5 border
 * - two 89px hemispheres separated by a 1px center seam at 50% (#2c3650 @ 0.8)
 *
 * Animation (21-UI-SPEC.md §UFO Opening Animation — LOCKED, 500ms total):
 * - 0→250ms hemispheres slide ±15px (ease-out-quart) + beam opacity 0→1, width 0→30px
 * - 250→300ms peak dwell
 * - 300→450ms hemispheres close ±15px→0 (ease-in-out) + beam fades
 * - 450→500ms glow settles on new active side
 * - `prefers-reduced-motion: reduce` suppresses all CSS animation/transition,
 *   but React state + aria-pressed still update at t=0 (instant swap).
 *
 * Accessibility (21-UI-SPEC.md §Accessibility — LOCKED):
 * - `role="group"` wrapper + two `<button aria-pressed>` children (NOT radiogroup).
 * - Arrow keys move focus within the group; Enter/Space commits via native button.
 * - Focus-visible outline is a 2px solid #4c7fe8 ring with 2px offset (see index.css).
 *
 * Persistence: each commit optimistically updates local state via `onSelect`,
 * then calls `setVariantPreference(base, target)` against the DB. Failure
 * surfaces as a non-blocking sonner toast — the UI does NOT roll back
 * (Phase 21 accepts eventual consistency; the next page load re-reads DB).
 */
export function UfoToggle({
  baseAlbumId,
  variantAlbumId,
  variantKind,
  selectedAlbumId,
  onSelect,
}: UfoToggleProps) {
  const [animating, setAnimating] = useState(false);
  // Ref mirrors `animating` for synchronous re-entrancy checks inside the
  // click handler (state updates are batched, so a quick double-click could
  // otherwise bypass the guard).
  const animatingRef = useRef(false);
  const variantDisplay = displayVariantLabel(variantKind);
  const selectedIsBase = selectedAlbumId === baseAlbumId;

  const leftBtnRef = useRef<HTMLButtonElement>(null);
  const rightBtnRef = useRef<HTMLButtonElement>(null);
  // Track the pending timeout so we can cancel on unmount and not leak
  // a late setAnimating(false) into a stale render tree.
  const timerRef = useRef<number | null>(null);

  const commit = useCallback(
    async (targetAlbumId: number) => {
      // Re-entrant clicks during animation are swallowed (UI-SPEC §Rapid Toggle).
      if (animatingRef.current) return;
      // Clicking the already-active side is a no-op.
      if (targetAlbumId === selectedAlbumId) return;

      animatingRef.current = true;
      setAnimating(true);

      // Optimistic UI update — parent swaps the tracklist immediately.
      onSelect(targetAlbumId);

      // Persist preference; surface failure as a non-blocking toast.
      try {
        await setVariantPreference(baseAlbumId, targetAlbumId);
      } catch {
        toast.error("Couldn't save variant preference.");
      }

      // Release animation lock after the 500ms keyframe completes.
      if (timerRef.current != null) {
        window.clearTimeout(timerRef.current);
      }
      timerRef.current = window.setTimeout(() => {
        animatingRef.current = false;
        setAnimating(false);
        timerRef.current = null;
      }, 500);
    },
    [selectedAlbumId, baseAlbumId, onSelect],
  );

  // Unmount cleanup — cancel the pending timeout and clear the ref so a
  // lingering timer cannot write to a disposed component's state.
  useEffect(() => {
    return () => {
      if (timerRef.current != null) {
        window.clearTimeout(timerRef.current);
        timerRef.current = null;
      }
      animatingRef.current = false;
    };
  }, []);

  // Arrow keys move focus within the group without activating (a11y spec:
  // Tab enters, Arrow cycles focus, Enter/Space commits via native button).
  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.key === "ArrowLeft") {
      e.preventDefault();
      leftBtnRef.current?.focus();
    } else if (e.key === "ArrowRight") {
      e.preventDefault();
      rightBtnRef.current?.focus();
    }
  };

  return (
    <div
      role="group"
      aria-label="Album variant selector"
      className="ufo-pill"
      data-animating={animating ? "true" : "false"}
      onKeyDown={onKeyDown}
    >
      <button
        ref={leftBtnRef}
        type="button"
        aria-pressed={selectedIsBase}
        aria-label="Show base album"
        className="ufo-side ufo-side--left"
        data-active={selectedIsBase ? "true" : "false"}
        onClick={() => commit(baseAlbumId)}
      >
        BASE
      </button>
      <button
        ref={rightBtnRef}
        type="button"
        aria-pressed={!selectedIsBase}
        aria-label={`Show variant ${variantDisplay}`}
        className="ufo-side ufo-side--right"
        data-active={!selectedIsBase ? "true" : "false"}
        onClick={() => commit(variantAlbumId)}
      >
        {variantDisplay}
      </button>
    </div>
  );
}
