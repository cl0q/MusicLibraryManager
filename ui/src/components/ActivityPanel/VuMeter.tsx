import { useEffect, useRef, useState } from "react";

interface VuMeterProps {
  channels?: number;
  bars?: number;
  height?: number;
  seed?: number;
  animated?: boolean;
}

/**
 * Cosmetic VU meter — stacked segment columns per channel. Pseudo-random
 * levels biased toward mid/high, animated via requestAnimationFrame when
 * `animated` is true, otherwise frozen.
 */
export default function VuMeter({
  channels = 2,
  bars = 18,
  height = 72,
  seed = 1,
  animated = true,
}: VuMeterProps) {
  const [tick, setTick] = useState(0);
  const rafRef = useRef<number | null>(null);
  const lastRef = useRef<number>(0);

  useEffect(() => {
    if (!animated) return;
    const loop = (t: number) => {
      if (t - lastRef.current > 110) {
        lastRef.current = t;
        setTick((n) => n + 1);
      }
      rafRef.current = requestAnimationFrame(loop);
    };
    rafRef.current = requestAnimationFrame(loop);
    return () => {
      if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
    };
  }, [animated]);

  const segH = Math.max(2, (height - bars) / bars);

  return (
    <div className="flex gap-1 items-end" style={{ height }}>
      {Array.from({ length: channels }).map((_, ch) => (
        <div key={ch} className="flex flex-col-reverse gap-px">
          {Array.from({ length: bars }).map((_, i) => {
            const s = Math.sin((tick + seed * 7 + ch * 13) * 0.4 + i * 0.6);
            const n = (Math.sin(tick * 0.3 + ch + i * 1.7) + 1) / 2;
            const level = animated
              ? Math.max(0, Math.min(1, 0.6 + s * 0.3 + n * 0.2))
              : 0.35;
            const threshold = i / bars;
            const on = threshold < level;
            // Green low, amber (accent) mid, rose peak — works on both schemes
            const color =
              i > bars * 0.85
                ? "var(--color-ink-muted)"
                : i > bars * 0.7
                ? "var(--color-accent)"
                : "var(--color-accent-bright)";
            return (
              <div
                key={i}
                className="w-[10px]"
                style={{
                  height: segH,
                  background: on ? color : "var(--color-edge)",
                  opacity: on ? 0.95 : 0.4,
                }}
              />
            );
          })}
        </div>
      ))}
    </div>
  );
}
