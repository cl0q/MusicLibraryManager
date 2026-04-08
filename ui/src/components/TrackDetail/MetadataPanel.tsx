import type { Track } from "../../types/library";
import { formatDuration, formatDate } from "../../utils/formatter";

interface MetadataPanelProps {
  track: Track;
}

export default function MetadataPanel({ track }: MetadataPanelProps) {
  const { metadata: m } = track;
  const metadataItems = [
    { label: "Title", value: m.title },
    { label: "Artist", value: m.artist },
    { label: "Album", value: m.album },
    { label: "Album Artist", value: m.album_artist },
    { label: "Duration", value: formatDuration(m.duration ?? 0) },
    { label: "Format", value: m.format?.toUpperCase() || "Unknown" },
    { label: "Bitrate", value: m.bitrate ? `${Math.round(m.bitrate / 1000)} kbps` : "-" },
    { label: "Year", value: m.year?.toString() || "-" },
    { label: "Genre", value: m.genre || "-" },
    { label: "Date Added", value: track.date_added ? formatDate(new Date(track.date_added).getTime() / 1000) : "-" },
    { label: "File Path", value: m.original_path || "Not downloaded" },
  ];

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 p-6">
      <h2 className="text-xl font-bold mb-4 text-gray-900 dark:text-white">
        Track Information
      </h2>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {metadataItems.map((item) => (
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
