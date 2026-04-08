import type { ReactNode } from "react";

export type SourceStatus = "connected" | "disconnected" | "syncing" | "error";

interface SourceCardProps {
  name: string;
  icon: ReactNode;
  status: SourceStatus;
  description: string;
  trackCount?: number;
  lastSyncTime?: string;
  errorMessage?: string;
  onConnect?: () => void;
  onDisconnect?: () => void;
  onSync?: () => void;
  connectLabel?: string;
  isConnecting?: boolean;
  extraActions?: ReactNode;
}

function formatRelativeTime(isoTimestamp: string): string {
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
}

const statusColors: Record<SourceStatus, string> = {
  connected: "bg-emerald-400",
  disconnected: "bg-ink-muted",
  syncing: "bg-sky-400 animate-pulse",
  error: "bg-rose-400",
};

const statusLabels: Record<SourceStatus, string> = {
  connected: "Connected",
  disconnected: "Not connected",
  syncing: "Syncing...",
  error: "Error",
};

const statusTextColors: Record<SourceStatus, string> = {
  connected: "text-emerald-400",
  disconnected: "text-ink-muted",
  syncing: "text-sky-400",
  error: "text-rose-400",
};

export default function SourceCard({
  name,
  icon,
  status,
  description,
  trackCount,
  lastSyncTime,
  errorMessage,
  onConnect,
  onDisconnect,
  onSync,
  connectLabel = `Connect ${name}`,
  isConnecting = false,
  extraActions,
}: SourceCardProps) {
  const isConnected = status === "connected" || status === "syncing" || status === "error";

  return (
    <div className="bg-surface border border-edge rounded-lg overflow-hidden">
      <div className="p-3 flex items-center gap-3">
        <div className="shrink-0">{icon}</div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="text-sm font-medium text-ink">{name}</span>
            <span className={`w-1.5 h-1.5 rounded-full ${statusColors[status]}`} />
            <span className={`text-xs ${statusTextColors[status]}`}>{statusLabels[status]}</span>
          </div>
          {isConnected ? (
            <div className="flex items-center gap-3 text-xs text-ink-muted mt-0.5">
              {trackCount !== undefined && (
                <span className="tabular-nums">{trackCount.toLocaleString()} tracks</span>
              )}
              {lastSyncTime && <span>synced {formatRelativeTime(lastSyncTime)}</span>}
            </div>
          ) : (
            <p className="text-xs text-ink-muted mt-0.5">{description}</p>
          )}
        </div>

        {/* Actions */}
        <div className="flex items-center gap-1.5 shrink-0">
          {isConnected ? (
            <>
              <button
                onClick={onSync}
                disabled={status === "syncing"}
                className="px-2.5 py-1 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {status === "syncing" ? "Syncing..." : "Sync"}
              </button>
              <button
                onClick={onDisconnect}
                disabled={status === "syncing"}
                className="px-2.5 py-1 text-xs text-ink-muted hover:text-rose-400 hover:bg-rose-500/10 rounded transition-colors disabled:opacity-50"
              >
                Disconnect
              </button>
            </>
          ) : (
            <button
              onClick={onConnect}
              disabled={isConnecting}
              className="px-2.5 py-1 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isConnecting ? "Connecting..." : connectLabel}
            </button>
          )}
        </div>
      </div>

      {/* Extra actions */}
      {isConnected && extraActions && (
        <div className="px-3 pb-3 -mt-1">{extraActions}</div>
      )}

      {/* Error message */}
      {status === "error" && errorMessage && (
        <div className="px-3 pb-3">
          <div className="bg-rose-500/10 border border-rose-500/20 rounded px-2.5 py-1.5 text-xs text-rose-400">
            {errorMessage}
          </div>
        </div>
      )}
    </div>
  );
}
