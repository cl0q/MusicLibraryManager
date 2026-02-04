import type { DownloadProgressEvent } from "../../types/events";

interface DownloadQueueProps {
  downloads: Map<string, DownloadProgressEvent>;
  onRetryFailed: () => void;
}

function getStatusColor(status: DownloadProgressEvent["status"]): string {
  switch (status) {
    case "completed":
      return "text-green-600 dark:text-green-400";
    case "failed":
      return "text-red-600 dark:text-red-400";
    case "downloading":
    case "transcoding":
      return "text-blue-600 dark:text-blue-400";
    case "queued":
      return "text-gray-600 dark:text-gray-400";
  }
}

function formatFileSize(bytes?: number): string {
  if (!bytes) return "";
  const mb = bytes / (1024 * 1024);
  if (mb < 1) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${mb.toFixed(1)} MB`;
}

export default function DownloadQueue({
  downloads,
  onRetryFailed,
}: DownloadQueueProps) {
  // Convert Map to Array and sort by priority
  const sortedDownloads = Array.from(downloads.values()).sort((a, b) => {
    const statusOrder: Record<DownloadProgressEvent["status"], number> = {
      downloading: 1,
      transcoding: 1,
      failed: 2,
      completed: 3,
      queued: 4,
    };
    return statusOrder[a.status] - statusOrder[b.status];
  });

  const failedCount = sortedDownloads.filter((d) => d.status === "failed").length;

  if (sortedDownloads.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 dark:text-gray-400">
        No downloads in queue
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {failedCount > 0 && (
        <div className="flex justify-between items-center bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4">
          <div className="text-red-700 dark:text-red-300">
            {failedCount} download{failedCount !== 1 ? "s" : ""} failed
          </div>
          <button
            onClick={onRetryFailed}
            className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors"
          >
            Retry All Failed Downloads
          </button>
        </div>
      )}

      <div className="space-y-3">
        {sortedDownloads.map((download) => (
          <div
            key={download.track_id}
            className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-4"
          >
            <div className="flex justify-between items-start mb-2">
              <div className="flex-1">
                <h3 className="font-medium text-gray-900 dark:text-gray-100">
                  {download.track_name}
                </h3>
                <div className="flex items-center gap-2 mt-1 text-sm text-gray-600 dark:text-gray-400">
                  {download.source && (
                    <span className="px-2 py-0.5 bg-gray-100 dark:bg-gray-700 rounded text-xs">
                      {download.source}
                    </span>
                  )}
                  {download.current_step && (
                    <span className="text-xs">{download.current_step}</span>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <span
                  className={`text-sm font-medium ${getStatusColor(download.status)}`}
                >
                  {download.status}
                </span>
              </div>
            </div>

            {/* Progress bar */}
            {download.status !== "failed" && download.status !== "queued" && (
              <div className="relative h-2 bg-gray-200 dark:bg-gray-700 rounded-full overflow-hidden mb-2">
                <div
                  className="absolute top-0 left-0 h-full bg-blue-600 dark:bg-blue-500 transition-all duration-300"
                  style={{ width: `${download.progress}%` }}
                />
              </div>
            )}

            {/* Additional info */}
            <div className="flex items-center gap-4 text-xs text-gray-500 dark:text-gray-400">
              {download.progress > 0 && download.progress < 100 && (
                <span>{download.progress.toFixed(0)}%</span>
              )}
              {download.speed && <span>{download.speed}</span>}
              {download.eta && <span>ETA: {download.eta}</span>}
              {download.file_size && (
                <span>{formatFileSize(download.file_size)}</span>
              )}
            </div>

            {/* Error message */}
            {download.error && (
              <div className="mt-2 p-2 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded text-sm text-red-700 dark:text-red-300">
                {download.error}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
