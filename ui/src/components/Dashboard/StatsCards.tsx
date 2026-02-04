import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invokeTauriCommand } from "../../hooks/useTauriCommand";
import type { Track } from "../../types/library";
import type { RetryQueueStatus } from "../../utils/tauri-commands";
import { get_library_storage_size, get_last_sync_time } from "../../utils/tauri-commands";

interface StatCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
}

function StatCard({ title, value, subtitle }: StatCardProps) {
  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
      <h3 className="text-sm font-medium text-gray-600 dark:text-gray-400 mb-2">
        {title}
      </h3>
      <div className="text-3xl font-bold text-gray-900 dark:text-white mb-1">
        {value}
      </div>
      {subtitle && (
        <p className="text-xs text-gray-500 dark:text-gray-500">{subtitle}</p>
      )}
    </div>
  );
}

// Utility functions
const formatBytes = (bytes: number): string => {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(2)} ${sizes[i]}`;
};

const formatRelativeTime = (isoTimestamp: string): string => {
  const date = new Date(isoTimestamp);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMins / 60);
  const diffDays = Math.floor(diffHours / 24);

  if (diffMins < 1) return "just now";
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 30) return `${diffDays}d ago`;
  return date.toLocaleDateString();
};

export default function StatsCards() {
  const [trackCount, setTrackCount] = useState<number | string>("...");
  const [pendingDownloads, setPendingDownloads] = useState<number | string>("...");
  const [storageSize, setStorageSize] = useState<number | null>(null);
  const [lastSyncTime, setLastSyncTime] = useState<string | null>(null);

  useEffect(() => {
    // Fetch track count
    const fetchTrackCount = async () => {
      const result = await invokeTauriCommand<Track[]>("search_library", {
        query: "",
      });
      if (result.ok && result.data) {
        setTrackCount(result.data.length);
      } else {
        setTrackCount("Error");
      }
    };

    // Fetch pending downloads
    const fetchPendingDownloads = async () => {
      const result = await invokeTauriCommand<RetryQueueStatus>(
        "get_retry_queue_status"
      );
      if (result.ok && result.data) {
        setPendingDownloads(result.data.pending_count);
      } else {
        setPendingDownloads("Error");
      }
    };

    // Fetch storage size
    const fetchStorageSize = async () => {
      try {
        const size = await get_library_storage_size();
        setStorageSize(size);
      } catch (err) {
        console.error("Failed to fetch storage size:", err);
        setStorageSize(null);
      }
    };

    // Fetch last sync time
    const fetchLastSyncTime = async () => {
      try {
        const time = await get_last_sync_time();
        setLastSyncTime(time);
      } catch (err) {
        console.error("Failed to fetch last sync time:", err);
        setLastSyncTime(null);
      }
    };

    fetchTrackCount();
    fetchPendingDownloads();
    fetchStorageSize();
    fetchLastSyncTime();

    // Listen for sync:completed events to refresh last sync time
    const unlisten = listen("sync:completed", () => {
      fetchLastSyncTime();
    });

    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  return (
    <div className="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-5 gap-4">
      <StatCard title="Track Count" value={trackCount} />
      <StatCard
        title="Storage Size"
        value={storageSize !== null ? formatBytes(storageSize) : "Calculating..."}
        subtitle={storageSize !== null ? "Library total" : "Loading..."}
      />
      <StatCard
        title="Sources Connected"
        value={3}
        subtitle="Spotify, SoundCloud, Local"
      />
      <StatCard
        title="Last Sync"
        value={lastSyncTime ? formatRelativeTime(lastSyncTime) : "Never"}
        subtitle={lastSyncTime ? "Last device sync" : "No sync yet"}
      />
      <StatCard title="Pending Downloads" value={pendingDownloads} />
    </div>
  );
}
