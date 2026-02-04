import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import type { DownloadProgressEvent } from "../types/events";
import type { RetryQueueStatus } from "../utils/tauri-commands";
import { get_retry_queue_status } from "../utils/tauri-commands";

export function useDownloadQueue() {
  const [downloads, setDownloads] = useState<Map<string, DownloadProgressEvent>>(
    new Map()
  );
  const [queueStatus, setQueueStatus] = useState<RetryQueueStatus>({
    pending_count: 0,
    failed_count: 0,
  });

  // Load initial queue status
  useEffect(() => {
    get_retry_queue_status()
      .then(setQueueStatus)
      .catch((error) => {
        console.error("Failed to load queue status:", error);
      });
  }, []);

  // Listen for download progress events
  useEffect(() => {
    let unlisten: (() => void) | undefined;

    listen<DownloadProgressEvent>("download:progress", (event) => {
      const progress = event.payload;
      setDownloads((prev) => {
        const next = new Map(prev);
        next.set(progress.track_id, progress);
        return next;
      });

      // Update queue status when downloads complete or fail
      if (progress.status === "completed" || progress.status === "failed") {
        get_retry_queue_status()
          .then(setQueueStatus)
          .catch((error) => {
            console.error("Failed to update queue status:", error);
          });
      }
    }).then((fn) => {
      unlisten = fn;
    });

    return () => {
      if (unlisten) {
        unlisten();
      }
    };
  }, []);

  const handleRetryFailed = async () => {
    // TODO: Call retry_failed_downloads Tauri command when available
    console.log("Retry failed downloads not yet implemented");
  };

  return {
    downloads,
    queueStatus,
    handleRetryFailed,
  };
}
