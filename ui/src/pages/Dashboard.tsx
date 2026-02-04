import { useState } from "react";
import { toast } from "sonner";
import StatsCards from "../components/Dashboard/StatsCards";
import ActivityFeed from "../components/Dashboard/ActivityFeed";
import { execute_sync_cmd, list_sync_profiles } from "../utils/tauri-commands";

export default function Dashboard() {
  const [isSyncing, setIsSyncing] = useState(false);

  const handleSyncNow = async () => {
    setIsSyncing(true);

    try {
      const profiles = await list_sync_profiles();
      if (profiles.length === 0) {
        toast.error("No sync profiles configured. Create one in the Sync tab.");
        setIsSyncing(false);
        return;
      }

      const profile = profiles[0];
      toast.info(`Starting sync for ${profile.name}...`);

      const result = await execute_sync_cmd(profile.id);

      toast.success(
        `Sync complete! Added: ${result.files_added}, Updated: ${result.files_updated}, Removed: ${result.files_removed}`
      );
    } catch (error) {
      console.error("Sync failed:", error);
      toast.error(`Sync failed: ${error}`);
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
