import type { ReactNode } from "react";

interface FilterBarProps {
  value: string;
  onChange: (value: string) => void;
  loading?: boolean;
  /**
   * Slot for trailing action buttons (Analyze, Match, Filters, etc.).
   * The shell wraps these as <IconBtn> entries — see LibraryBrowser header.
   */
  trailing?: ReactNode;
}

/**
 * Search field for the library view. Solar mock (table.jsx):
 * - 30px height, search icon left, monospace ⌘F kbd hint right.
 * - Trailing action buttons optional.
 * - Track count is NOT rendered here; it lives in the Local/Remote
 *   segmented pills in the LibraryBrowser header.
 */
export default function FilterBar({ value, onChange, loading = false, trailing }: FilterBarProps) {
  return (
    <div className="flex items-center gap-2" style={{ fontFamily: "var(--font-ui)" }}>
      <div className="flex-1 relative">
        <svg
          className="absolute left-2.5 top-1/2 -translate-y-1/2 w-[13px] h-[13px] text-ink-muted pointer-events-none"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          strokeWidth={1.8}
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-5.2-5.2M17 10a7 7 0 11-14 0 7 7 0 0114 0z" />
        </svg>
        <input
          type="text"
          placeholder="Filter by title, artist, album…"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          disabled={loading}
          className="w-full h-[30px] pl-[30px] pr-10 text-[12px] bg-base border border-edge rounded-[5px]
                     text-ink placeholder:text-ink-muted
                     focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/20
                     disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        />
        <span
          className="absolute right-2 top-1/2 -translate-y-1/2 inline-flex items-center justify-center min-w-4 h-4 px-1 rounded-[3px] border border-edge bg-raised text-ink-muted"
          style={{ fontFamily: "var(--font-mono)", fontSize: 10, fontWeight: 500 }}
        >
          ⌘F
        </span>
      </div>
      {trailing}
    </div>
  );
}
