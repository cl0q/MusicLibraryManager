import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import type { DownloadProgressEvent } from "../types/events";
import type { RetryQueueStatus } from "../utils/tauri-commands";
import { get_retry_queue_status, get_recent_downloads } from "../utils/tauri-commands";

export function useDownloadQueue() {
  const [downloads, setDownloads] = useState<Map<string, DownloadProgressEvent>>(
    new Map()
  );
  const [queueStatus, setQueueStatus] = useState<RetryQueueStatus>({
    pending_count: 0,
    failed_count: 0,
  });

  // Load initial queue status and download history
  useEffect(() => {
    get_retry_queue_status()
      .then(setQueueStatus)
      .catch((error) => {
        console.error("Failed to load queue status:", error);
      });

    // Load recent download history from database
    get_recent_downloads()
      .then((history) => {
        setDownloads((prev) => {
          const next = new Map(prev);
          for (const dl of history) {
            // Only add if not already tracked by a live event
            const key = dl.id.toString();
            if (!next.has(key)) {
              next.set(key, {
                track_id: key,
                track_name: `${dl.artist} - ${dl.title}`,
                status: "completed",
                progress: 100,
                error: null,
                source: null,
                current_step: null,
                speed: null,
                eta: null,
                file_size: null,
              });
            }
          }
          return next;
        });
      })
      .catch((error) => {
        console.error("Failed to load download history:", error);
      });
  }, []);

  // Listen for download progress events
  useEffect(() => {
    let cancelled = false;
    let unlistenFn: (() => void) | undefined;

    listen<DownloadProgressEvent>("download:progress", (event) => {
      if (cancelled) return;
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
      if (cancelled) {
        fn(); // Already unmounted, clean up immediately
      } else {
        unlistenFn = fn;
      }
    });

    return () => {
      cancelled = true;
      unlistenFn?.();
    };
  }, []);

  const handleRetryFailed = async () => {
    // TODO: Call retry_failed_downloads Tauri command when available
    console.log("Retry failed downloads not yet implemented");
  };

  const clearDownloads = () => setDownloads(new Map());

  return {
    downloads,
    queueStatus,
    handleRetryFailed,
    clearDownloads,
  };
}
