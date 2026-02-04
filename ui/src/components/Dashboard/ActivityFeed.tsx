import { useActivityFeed } from "../../hooks/useTauriEvents";

export default function ActivityFeed() {
  const activities = useActivityFeed();

  const formatTimestamp = (timestamp: number): string => {
    const now = Date.now();
    const diff = now - timestamp;
    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (seconds < 60) return "just now";
    if (minutes < 60) return `${minutes}m ago`;
    if (hours < 24) return `${hours}h ago`;
    return `${days}d ago`;
  };

  const getActivityColor = (type: string): string => {
    switch (type) {
      case "track_added":
        return "text-green-600 dark:text-green-400";
      case "sync_completed":
        return "text-blue-600 dark:text-blue-400";
      case "download_completed":
        return "text-purple-600 dark:text-purple-400";
      case "error":
        return "text-red-600 dark:text-red-400";
      default:
        return "text-gray-600 dark:text-gray-400";
    }
  };

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
      <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
        Recent Activity
      </h2>
      <div className="max-h-96 overflow-y-auto space-y-3">
        {activities.length === 0 ? (
          <p className="text-gray-500 dark:text-gray-500 text-sm">
            No recent activity
          </p>
        ) : (
          activities.map((activity, index) => (
            <div
              key={`${activity.timestamp}-${index}`}
              className="flex items-start justify-between py-2 border-b border-gray-100 dark:border-gray-700 last:border-b-0"
            >
              <div className="flex-1">
                <p className={`text-sm font-medium ${getActivityColor(activity.type)}`}>
                  {activity.message}
                </p>
              </div>
              <span className="text-xs text-gray-500 dark:text-gray-500 ml-4">
                {formatTimestamp(activity.timestamp)}
              </span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
