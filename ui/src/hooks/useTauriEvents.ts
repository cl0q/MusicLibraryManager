import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import type { ActivityEvent, DownloadProgressEvent } from "../types/events";

/**
 * Hook for listening to library activity events
 * @returns Array of recent activity events (max 50 items)
 */
export function useActivityFeed() {
  const [activities, setActivities] = useState<ActivityEvent[]>([]);

  useEffect(() => {
    let unlisten: (() => void) | undefined;

    const setupListener = async () => {
      unlisten = await listen<ActivityEvent>("library:activity", (event) => {
        setActivities((prev) => {
          // Prepend new event and keep only last 50 items
          const updated = [event.payload, ...prev];
          return updated.slice(0, 50);
        });
      });
    };

    setupListener();

    // Cleanup function to prevent memory leaks
    return () => {
      if (unlisten) {
        unlisten();
      }
    };
  }, []);

  return activities;
}

/**
 * Hook for listening to download progress events
 * @returns Map of download progress keyed by track_id
 */
export function useDownloadProgress() {
  const [downloads, setDownloads] = useState<Map<string, DownloadProgressEvent>>(
    new Map()
  );

  useEffect(() => {
    let unlisten: (() => void) | undefined;

    const setupListener = async () => {
      unlisten = await listen<DownloadProgressEvent>(
        "download:progress",
        (event) => {
          setDownloads((prev) => {
            const updated = new Map(prev);
            updated.set(event.payload.track_id, event.payload);
            return updated;
          });
        }
      );
    };

    setupListener();

    // Cleanup function to prevent memory leaks
    return () => {
      if (unlisten) {
        unlisten();
      }
    };
  }, []);

  return downloads;
}
