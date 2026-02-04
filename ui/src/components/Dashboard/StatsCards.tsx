import { useEffect, useState } from "react";
import { invokeTauriCommand } from "../../hooks/useTauriCommand";
import type { Track } from "../../types/library";
import type { RetryQueueStatus } from "../../utils/tauri-commands";

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

export default function StatsCards() {
  const [trackCount, setTrackCount] = useState<number | string>("...");
  const [pendingDownloads, setPendingDownloads] = useState<number | string>("...");

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

    fetchTrackCount();
    fetchPendingDownloads();
  }, []);

  return (
    <div className="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-5 gap-4">
      <StatCard title="Track Count" value={trackCount} />
      <StatCard
        title="Storage Size"
        value="Calculating..."
        subtitle="Coming soon"
      />
      <StatCard
        title="Sources Connected"
        value={3}
        subtitle="Spotify, SoundCloud, Local"
      />
      <StatCard title="Last Sync" value="Never" subtitle="No sync yet" />
      <StatCard title="Pending Downloads" value={pendingDownloads} />
    </div>
  );
}
