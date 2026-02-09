import { useState, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";

interface ProgressUpdate {
  current: number;
  total: number;
  track_title: string;
}

interface DownloadProgressProps {
  isDownloading: boolean;
}

export function DownloadProgress({ isDownloading }: DownloadProgressProps) {
  const [progress, setProgress] = useState<ProgressUpdate | null>(null);

  useEffect(() => {
    if (!isDownloading) return;

    const unlisten = listen<ProgressUpdate>("download-progress", (event) => {
      setProgress(event.payload);
    });

    return () => {
      unlisten.then(fn => fn());
    };
  }, [isDownloading]);

  if (!isDownloading || !progress) return null;

  const percent = Math.round((progress.current / progress.total) * 100);

  return (
    <div className="fixed bottom-4 right-4 bg-white dark:bg-gray-800 rounded-lg shadow-lg p-4 w-80">
      <div className="text-sm font-medium mb-2">
        Downloading ({progress.current}/{progress.total})
      </div>
      <div className="text-xs text-gray-600 dark:text-gray-400 mb-2 truncate">
        {progress.track_title}
      </div>
      <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
        <div
          className="bg-blue-600 h-2 rounded-full transition-all duration-300"
          style={{ width: `${percent}%` }}
        />
      </div>
      <div className="text-xs text-gray-500 mt-1 text-right">{percent}%</div>
    </div>
  );
}
