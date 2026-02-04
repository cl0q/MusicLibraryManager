import { useState } from "react";
import { toast } from "sonner";
import StatsCards from "../components/Dashboard/StatsCards";
import ActivityFeed from "../components/Dashboard/ActivityFeed";
import { invokeTauriCommand } from "../hooks/useTauriCommand";

export default function Dashboard() {
  const [isSyncing, setIsSyncing] = useState(false);

  const handleSyncNow = async () => {
    setIsSyncing(true);
    toast.info("Sync triggered");

    // TODO: This will be properly implemented when we have sync profiles
    // For now, just show a placeholder message
    const result = await invokeTauriCommand("list_sync_profiles");

    if (result.ok) {
      toast.success("Sync functionality coming soon");
    } else {
      toast.error(`Error: ${result.error}`);
    }

    setIsSyncing(false);
  };

  return (
    <div className="p-6 space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
          Dashboard
        </h1>
        <p className="text-gray-600 dark:text-gray-400">
          Overview of your music library and recent activity
        </p>
      </div>

      {/* Quick Actions */}
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
          Quick Actions
        </h2>
        <div className="flex gap-3">
          <button
            onClick={handleSyncNow}
            disabled={isSyncing}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg font-medium transition-colors disabled:cursor-not-allowed"
          >
            {isSyncing ? "Syncing..." : "Sync Now"}
          </button>
        </div>
      </div>

      {/* Stats Cards */}
      <StatsCards />

      {/* Activity Feed */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2">
          <ActivityFeed />
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
            Quick Stats
          </h2>
          <div className="space-y-4">
            <div>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                Library Health
              </p>
              <p className="text-2xl font-bold text-green-600 dark:text-green-400">
                Good
              </p>
            </div>
            <div>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                Download Queue
              </p>
              <p className="text-2xl font-bold text-gray-900 dark:text-white">
                Empty
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
