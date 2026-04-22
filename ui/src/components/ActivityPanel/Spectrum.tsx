import { useEffect, useRef, useState } from "react";

interface SpectrumProps {
  bars?: number;
  width?: number;
  height?: number;
  animated?: boolean;
}

/**
 * Cosmetic spectrum analyzer — bass-heavy envelope, deterministic seeded
 * pseudo-randomness animated via requestAnimationFrame while `animated` is
 * true, frozen otherwise. No audio engine.
 */
export default function Spectrum({
  bars = 32,
  width = 120,
  height = 16,
  animated = true,
}: SpectrumProps) {
  const [tick, setTick] = useState(0);
  const rafRef = useRef<number | null>(null);
  const lastRef = useRef<number>(0);

  useEffect(() => {
    if (!animated) return;
    const loop = (t: number) => {
      // Throttle to ~12 fps so bars have visible step motion
      if (t - lastRef.current > 80) {
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

  const bw = width / bars;

  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="block">
      {Array.from({ length: bars }).map((_, i) => {
        const freq = i / bars;
        // Bass-heavy envelope
        const env = Math.exp(-freq * 2.5) * 0.7 + 0.3;
        const n = (Math.sin(tick * 0.4 + i * 0.7) + Math.sin(tick * 0.2 + i * 0.3)) / 2;
        const level = Math.max(0.05, env * (animated ? 0.6 + n * 0.4 : 0.35));
        const h = level * height;
        return (
          <rect
            key={i}
            x={i * bw + 0.5}
            y={height - h}
            width={Math.max(1, bw - 1)}
            height={h}
            fill="var(--color-accent)"
            opacity={0.45 + level * 0.5}
          />
        );
      })}
    </svg>
  );
}
