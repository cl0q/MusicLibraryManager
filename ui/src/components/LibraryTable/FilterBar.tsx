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
    <div className="flex items-center gap-4 mb-4">
      <div className="flex-1 relative">
        <input
          type="text"
          placeholder="Search library..."
          value={value}
          onChange={(e) => onChange(e.target.value)}
          disabled={loading}
          className="w-full px-4 py-2 pl-10 border border-gray-300 dark:border-gray-600 rounded-lg
                     bg-white dark:bg-gray-800
                     text-gray-900 dark:text-white
                     placeholder-gray-500 dark:placeholder-gray-400
                     focus:outline-none focus:ring-2 focus:ring-blue-500 dark:focus:ring-blue-400
                     disabled:opacity-50 disabled:cursor-not-allowed"
        />
        <svg
          className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400"
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
      <div className="text-sm text-gray-600 dark:text-gray-400 whitespace-nowrap">
        {loading ? (
          "Loading..."
        ) : (
          <>
            {trackCount} {trackCount === 1 ? "track" : "tracks"}
          </>
        )}
      </div>
    </div>
  );
}
