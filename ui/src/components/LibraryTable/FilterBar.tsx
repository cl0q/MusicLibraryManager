interface FilterBarProps {
  value: string;
  onChange: (value: string) => void;
  trackCount: number;
  loading?: boolean;
}

export default function FilterBar({
  value,
  onChange,
  trackCount,
  loading = false,
}: FilterBarProps) {
  return (
    <div className="flex items-center gap-3">
      <div className="flex-1 relative">
        <input
          type="text"
          placeholder="Search tracks..."
          value={value}
          onChange={(e) => onChange(e.target.value)}
          disabled={loading}
          className="w-full h-8 px-3 pl-8 text-[13px] bg-raised border border-edge rounded
                     text-ink placeholder-ink-muted
                     focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/20
                     disabled:opacity-50 disabled:cursor-not-allowed
                     transition-colors"
        />
        <svg
          className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-ink-muted"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
          />
        </svg>
      </div>
      <span className="text-xs text-ink-muted tabular-nums whitespace-nowrap">
        {loading ? "..." : `${trackCount.toLocaleString()} tracks`}
      </span>
    </div>
  );
}
