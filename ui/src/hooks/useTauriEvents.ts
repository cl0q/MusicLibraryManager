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

/**
 * Hook for listening to sync progress events
 * @returns Map of sync operations keyed by profile_id
 */
export function useSyncProgress() {
  const [syncs, setSyncs] = useState<Map<number, {
    profile_id: number;
    status: "syncing" | "completed" | "failed";
    files_synced: number;
    total_files: number;
    error?: string;
  }>>(new Map());

  useEffect(() => {
    const listeners: (() => void)[] = [];

    listen<{ profile_id: number }>("sync:started", (event) => {
      setSyncs((prev) => {
        const next = new Map(prev);
        next.set(event.payload.profile_id, {
          profile_id: event.payload.profile_id,
          status: "syncing",
          files_synced: 0,
          total_files: 0,
        });
        return next;
      });
    }).then((unlisten) => listeners.push(unlisten));

    listen<{ profile_id: number; files_synced: number; total_files: number }>(
      "sync:progress",
      (event) => {
        setSyncs((prev) => {
          const next = new Map(prev);
          const existing = next.get(event.payload.profile_id);
          if (existing) {
            next.set(event.payload.profile_id, {
              ...existing,
              files_synced: event.payload.files_synced,
              total_files: event.payload.total_files,
            });
          }
          return next;
        });
      }
    ).then((unlisten) => listeners.push(unlisten));

    listen<{ profile_id: number }>("sync:completed", (event) => {
      setSyncs((prev) => {
        const next = new Map(prev);
        const existing = next.get(event.payload.profile_id);
        if (existing) {
          next.set(event.payload.profile_id, {
            ...existing,
            status: "completed",
          });
        }
        setTimeout(() => {
          setSyncs((current) => {
            const updated = new Map(current);
            updated.delete(event.payload.profile_id);
            return updated;
          });
        }, 3000);
        return next;
      });
    }).then((unlisten) => listeners.push(unlisten));

    listen<{ profile_id: number; error: string }>("sync:failed", (event) => {
      setSyncs((prev) => {
        const next = new Map(prev);
        next.set(event.payload.profile_id, {
          profile_id: event.payload.profile_id,
          status: "failed",
          files_synced: 0,
          total_files: 0,
          error: event.payload.error,
        });
        return next;
      });
    }).then((unlisten) => listeners.push(unlisten));

    return () => {
      listeners.forEach((unlisten) => unlisten());
    };
  }, []);

  return syncs;
}
