import { useState } from "react";

interface Operation {
  id: string;
  name: string;
  status: string;
  progress: number;
  eta?: string;
}

export default function StatusBar() {
  const [isExpanded, setIsExpanded] = useState(false);

  // Placeholder operations (will be connected to Tauri events in later plans)
  const [operations] = useState<Operation[]>([
    {
      id: "1",
      name: "Example operation",
      status: "completed",
      progress: 100,
    },
  ]);

  // Current operation summary for collapsed view
  const activeOperation = operations.find((op) => op.progress < 100);
  const statusText = activeOperation
    ? `${activeOperation.name} - ${activeOperation.progress}%`
    : "Ready";
  const progressPercentage = activeOperation ? activeOperation.progress : 0;

  return (
    <div
      className={`fixed bottom-0 left-0 right-0 bg-gray-50 dark:bg-gray-900 border-t border-gray-200 dark:border-gray-800 transition-all duration-300 ease-in-out ${
        isExpanded ? "h-60" : "h-10"
      }`}
    >
      {/* Clickable header bar */}
      <div
        className="h-10 px-4 flex items-center justify-between cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
        onClick={() => setIsExpanded(!isExpanded)}
      >
        {/* Left side: operation text */}
        <div className="flex items-center gap-2">
          <span className="text-sm text-gray-700 dark:text-gray-300">
            {statusText}
          </span>
        </div>

        {/* Right side: progress indicator and expand icon */}
        <div className="flex items-center gap-3">
          {activeOperation && (
            <span className="text-sm text-gray-600 dark:text-gray-400">
              {progressPercentage}%
            </span>
          )}

          {/* Chevron icon */}
          <svg
            className={`w-4 h-4 text-gray-500 transition-transform ${
              isExpanded ? "rotate-180" : ""
            }`}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M19 9l-7 7-7-7"
            />
          </svg>
        </div>
      </div>

      {/* Expanded panel */}
      {isExpanded && (
        <div className="h-50 overflow-y-auto p-4 space-y-3">
          <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100 mb-2">
            Operations
          </h3>

          {operations.length === 0 ? (
            <div className="text-sm text-gray-500 dark:text-gray-400 text-center py-8">
              No active operations
            </div>
          ) : (
            <div className="space-y-2">
              {operations.map((operation) => (
                <div
                  key={operation.id}
                  className="bg-white dark:bg-gray-800 rounded-lg p-3 border border-gray-200 dark:border-gray-700"
                >
                  {/* Operation header */}
                  <div className="flex items-start justify-between mb-2">
                    <div className="flex-1 min-w-0">
                      <div className="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">
                        {operation.name}
                      </div>
                      <div className="text-xs text-gray-500 dark:text-gray-400">
                        {operation.status}
                        {operation.eta && ` • ETA: ${operation.eta}`}
                      </div>
                    </div>
                    <div className="text-sm font-semibold text-gray-700 dark:text-gray-300 ml-2">
                      {operation.progress}%
                    </div>
                  </div>

                  {/* Progress bar */}
                  <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
                    <div
                      className="bg-blue-600 dark:bg-blue-500 h-2 rounded-full transition-all duration-300"
                      style={{ width: `${operation.progress}%` }}
                    />
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
