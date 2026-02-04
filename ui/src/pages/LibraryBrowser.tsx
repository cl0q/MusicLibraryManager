import { useLibraryTracks } from "../hooks/useLibraryTracks";
import LibraryTable from "../components/LibraryTable/LibraryTable";
import FilterBar from "../components/LibraryTable/FilterBar";

export default function LibraryBrowser() {
  const { tracks, loading, filterQuery, setFilterQuery } = useLibraryTracks();

  return (
    <div className="flex flex-col h-full p-6">
      <h1 className="text-2xl font-bold mb-4 text-gray-900 dark:text-white">
        Library
      </h1>

      <FilterBar
        value={filterQuery}
        onChange={setFilterQuery}
        trackCount={tracks.length}
        loading={loading}
      />

      <div className="flex-1 min-h-0">
        {loading ? (
          <div className="flex items-center justify-center h-full">
            <div className="text-gray-600 dark:text-gray-400">
              Loading library...
            </div>
          </div>
        ) : tracks.length === 0 ? (
          <div className="flex items-center justify-center h-full">
            <div className="text-gray-600 dark:text-gray-400">
              {filterQuery
                ? "No tracks match your search"
                : "No tracks in library"}
            </div>
          </div>
        ) : (
          <LibraryTable tracks={tracks} />
        )}
      </div>
    </div>
  );
}
