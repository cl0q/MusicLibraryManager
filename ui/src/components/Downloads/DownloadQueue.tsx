import type { DownloadProgressEvent } from "../../types/events";

interface DownloadQueueProps {
  downloads: Map<string, DownloadProgressEvent>;
  onRetryFailed: () => void;
}

function getStatusColor(status: DownloadProgressEvent["status"]): string {
  switch (status) {
    case "completed":
      return "text-emerald-400";
    case "failed":
      return "text-rose-400";
    case "downloading":
    case "transcoding":
      return "text-sky-400";
    case "queued":
      return "text-ink-muted";
  }
}

function formatFileSize(bytes?: number): string {
  if (!bytes) return "";
  const mb = bytes / (1024 * 1024);
  if (mb < 1) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${mb.toFixed(1)} MB`;
}

export default function DownloadQueue({ downloads, onRetryFailed }: DownloadQueueProps) {
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
      <div className="text-center py-8 text-xs text-ink-muted">
        No downloads in queue
      </div>
    );
  }

  return (
    <div className="space-y-2">
      {failedCount > 0 && (
        <div className="flex justify-between items-center bg-rose-500/10 border border-rose-500/20 rounded px-3 py-2">
          <span className="text-xs text-rose-400">
            {failedCount} download{failedCount !== 1 ? "s" : ""} failed
          </span>
          <button
            onClick={onRetryFailed}
            className="text-xs text-rose-400 hover:text-rose-300 font-medium transition-colors"
          >
            Retry All
          </button>
        </div>
      )}

      {sortedDownloads.map((download) => (
        <div
          key={download.track_id}
          className="bg-surface border border-edge rounded px-3 py-2"
        >
          <div className="flex justify-between items-start gap-3 mb-1">
            <div className="flex-1 min-w-0">
              <span className="text-[13px] font-medium text-ink truncate block">
                {download.track_name}
              </span>
              <div className="flex items-center gap-2 mt-0.5">
                {download.source && (
                  <span className="text-[10px] text-ink-muted bg-raised px-1.5 py-0.5 rounded">
                    {download.source}
                  </span>
                )}
                {download.current_step && (
                  <span className="text-[10px] text-ink-muted">{download.current_step}</span>
                )}
              </div>
            </div>
            <span className={`text-xs font-medium shrink-0 ${getStatusColor(download.status)}`}>
              {download.status}
            </span>
          </div>

          {download.status !== "failed" && download.status !== "queued" && (
            <div className="h-1 bg-edge rounded-full overflow-hidden mb-1">
              <div
                className={`h-full rounded-full transition-all duration-300 ${
                  download.status === "completed" ? "bg-emerald-500" : "bg-sky-500"
                }`}
                style={{ width: `${download.progress}%` }}
              />
            </div>
          )}

          <div className="flex items-center gap-3 text-[10px] text-ink-muted tabular-nums">
            {download.progress > 0 && download.progress < 100 && (
              <span>{download.progress.toFixed(0)}%</span>
            )}
            {download.speed && <span>{download.speed}</span>}
            {download.eta && <span>ETA: {download.eta}</span>}
            {download.file_size && <span>{formatFileSize(download.file_size)}</span>}
          </div>

          {download.error && (
            <div className="mt-1.5 bg-rose-500/10 border border-rose-500/20 rounded px-2 py-1">
              <span className="text-[11px] text-rose-400">{download.error}</span>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
