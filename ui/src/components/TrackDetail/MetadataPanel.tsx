import type { Track } from "../../types/library";
import { formatDuration, formatQuality, formatDate } from "../../utils/formatter";

interface MetadataPanelProps {
  track: Track;
}

export default function MetadataPanel({ track }: MetadataPanelProps) {
  const metadata = [
    { label: "Title", value: track.title },
    { label: "Artist", value: track.artist },
    { label: "Album", value: track.album },
    { label: "Album Artist", value: track.album_artist },
    { label: "Duration", value: formatDuration(track.duration) },
    { label: "Quality", value: formatQuality(track.quality) },
    { label: "Source", value: track.source },
    { label: "Date Added", value: formatDate(new Date(track.date_added).getTime() / 1000) },
    { label: "Local Path", value: track.local_path || "Not downloaded" },
  ];

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 p-6">
      <h2 className="text-xl font-bold mb-4 text-gray-900 dark:text-white">
        Track Information
      </h2>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {metadata.map((item) => (
          <div key={item.label}>
            <dt className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">
              {item.label}
            </dt>
            <dd className="text-sm text-gray-900 dark:text-white break-words">
              {item.value}
            </dd>
          </div>
        ))}
      </div>
    </div>
  );
}
