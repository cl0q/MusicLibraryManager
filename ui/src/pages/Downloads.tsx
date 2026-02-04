import { useDownloadQueue } from "../hooks/useDownloadQueue";
import DownloadQueue from "../components/Downloads/DownloadQueue";

export default function Downloads() {
  const { downloads, queueStatus, handleRetryFailed } = useDownloadQueue();

  return (
    <div className="p-6">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">
          Downloads
        </h1>
        <div className="mt-2 flex gap-4 text-sm text-gray-600 dark:text-gray-400">
          <span>
            Pending: <strong>{queueStatus.pending_count}</strong>
          </span>
          <span>
            Failed: <strong>{queueStatus.failed_count}</strong>
          </span>
          <span>
            Active: <strong>{downloads.size}</strong>
          </span>
        </div>
      </div>

      <DownloadQueue downloads={downloads} onRetryFailed={handleRetryFailed} />
    </div>
  );
}
