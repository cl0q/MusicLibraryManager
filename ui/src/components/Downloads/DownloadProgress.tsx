import { useState, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import type { DownloadProgressEvent } from "../../types/events";

interface DownloadProgressProps {
  isDownloading: boolean;
}

export function DownloadProgress({ isDownloading }: DownloadProgressProps) {
  const [progress, setProgress] = useState<DownloadProgressEvent | null>(null);

  useEffect(() => {
    if (!isDownloading) return;

    let cancelled = false;
    let unlistenFn: (() => void) | undefined;

    listen<DownloadProgressEvent>("download:progress", (event) => {
      if (cancelled) return;
      setProgress(event.payload);
    }).then((fn) => {
      if (cancelled) {
        fn();
      } else {
        unlistenFn = fn;
      }
    });

    return () => {
      cancelled = true;
      unlistenFn?.();
    };
  }, [isDownloading]);

  if (!isDownloading || !progress) return null;

  return (
    <div className="fixed bottom-12 right-4 bg-surface border border-edge rounded-lg shadow-2xl p-3 w-72 z-30">
      <div className="text-xs font-medium text-ink mb-1">
        {progress.status === "completed" ? "Download Complete" : "Downloading"}
      </div>
      <div className="text-[11px] text-ink-secondary mb-2 truncate">
        {progress.track_name}
      </div>
      <div className="h-1 bg-edge rounded-full overflow-hidden">
        <div
          className="h-full bg-sky-500 rounded-full transition-all duration-300"
          style={{ width: `${progress.progress}%` }}
        />
      </div>
      <div className="text-[10px] text-ink-muted mt-1 text-right tabular-nums">
        {progress.progress}%
      </div>
    </div>
  );
}
