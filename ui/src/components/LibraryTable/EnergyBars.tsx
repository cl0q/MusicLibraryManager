/**
 * EnergyBars — 5 stepped vertical bars with the first N in accent colour.
 *
 * Mock reference: `components.jsx` EnergyBars (which uses 10 bars — CONTRACT
 * §3 item 5 specifies a 1..=5 bucket, so we use 5 bars here instead).
 *
 * Passing `null`/`undefined` renders a muted "—" placeholder so the column
 * cell has something to show for unanalyzed tracks.
 */
interface EnergyBarsProps {
  value: number | null | undefined;
  /** Optional tone override for the lit bars (defaults to --color-accent). */
  color?: string;
}

export default function EnergyBars({ value, color }: EnergyBarsProps) {
  if (value == null) {
    return <span className="text-ink-muted text-[11px]">—</span>;
  }
  const clamped = Math.max(1, Math.min(5, Math.round(value)));
  const on = color || "var(--color-accent)";
  const off = "var(--color-edge)";
  return (
    <span
      className="inline-flex items-end gap-[2px]"
      style={{ height: 14 }}
      title={`Energy ${clamped}/5`}
      aria-label={`Energy ${clamped} of 5`}
    >
      {[1, 2, 3, 4, 5].map((i) => {
        const lit = i <= clamped;
        const h = 3 + (i - 1) * 2;
        return (
          <span
            key={i}
            className="w-[2px] rounded-[0.5px]"
            style={{
              height: `${h}px`,
              background: lit ? on : off,
            }}
          />
        );
      })}
    </span>
  );
}
