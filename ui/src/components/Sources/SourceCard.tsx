import type { ReactNode } from "react";

export type SourceStatus = "connected" | "disconnected" | "syncing" | "error";

/**
 * SourceCard — Solar mock (screens.jsx::SourceCard).
 *
 * Layout: 36px brand-tinted icon · name + account/scope · status dot · edit
 * action. When connected, exposes a 3-column stat grid (Playlists, Tracks,
 * Last sync) and a row of secondary actions + subtle Disconnect.
 * When disconnected, a single full-width Connect button replaces the body.
 */

interface SourceCardProps {
  name: string;
  icon: ReactNode;
  status: SourceStatus;
  description: string;
  trackCount?: number;
  playlistCount?: number;
  lastSyncTime?: string;
  errorMessage?: string;
  onConnect?: () => void;
  onDisconnect?: () => void;
  onSync?: () => void;
  connectLabel?: string;
  isConnecting?: boolean;
  /** Optional tint for the icon well background — use a CSS color or var. */
  brandColor?: string;
  /** Extra secondary actions rendered inline below the stats. */
  extraActions?: ReactNode;
}

function formatRelativeTime(isoTimestamp: string): string {
  const date = new Date(isoTimestamp);
  const diffMs = Date.now() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMins / 60);
  const diffDays = Math.floor(diffHours / 24);
  if (diffMins < 1) return "just now";
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 30) return `${diffDays}d ago`;
  return date.toLocaleDateString();
}

const statusDotColors: Record<SourceStatus, string> = {
  connected: "bg-emerald-400",
  disconnected: "bg-ink-muted",
  syncing: "bg-sky-400 animate-pulse",
  error: "bg-rose-400",
};

export default function SourceCard({
  name,
  icon,
  status,
  description,
  trackCount,
  playlistCount,
  lastSyncTime,
  errorMessage,
  onConnect,
  onDisconnect,
  onSync,
  connectLabel = `Connect ${name}`,
  isConnecting = false,
  brandColor,
  extraActions,
}: SourceCardProps) {
  const isConnected = status === "connected" || status === "syncing" || status === "error";
  const wellBg = brandColor
    ? `color-mix(in oklab, ${brandColor} 14%, transparent)`
    : "var(--color-raised)";

  return (
    <div
      className="bg-surface border border-edge rounded-md p-3.5"
      style={{
        fontFamily: "var(--font-ui)",
        opacity: isConnected ? 1 : 0.85,
      }}
    >
      {/* Header row */}
      <div className="flex items-center gap-3 mb-3">
        <div
          className="w-9 h-9 rounded-[5px] flex items-center justify-center shrink-0"
          style={{ background: wellBg, color: brandColor || "var(--color-ink-secondary)" }}
        >
          {icon}
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-[13px] font-semibold text-ink truncate">{name}</div>
          <div className="text-[11px] text-ink-muted mt-0.5 truncate">
            {isConnected ? description : description || "Not connected"}
          </div>
        </div>
        <span
          className={`w-1.5 h-1.5 rounded-full shrink-0 ${statusDotColors[status]}`}
          title={status}
        />
      </div>

      {isConnected ? (
        <>
          <div className="grid grid-cols-3 gap-2.5 mb-3">
            {playlistCount !== undefined && (
              <Stat label="Playlists" value={playlistCount.toLocaleString()} />
            )}
            {trackCount !== undefined && (
              <Stat label="Tracks" value={trackCount.toLocaleString()} />
            )}
            {lastSyncTime && (
              <Stat label="Last sync" value={formatRelativeTime(lastSyncTime)} />
            )}
          </div>

          <div className="flex items-center gap-1.5">
            <SecondaryBtn onClick={onSync} disabled={status === "syncing"}>
              <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" strokeWidth={1.7} viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" d="M16 9h5V4M3 20v-5h5M3 15a9 9 0 0015.4 3.4M21 9a9 9 0 00-15.4-3.4" />
              </svg>
              {status === "syncing" ? "Syncing…" : "Re-sync"}
            </SecondaryBtn>
            <div className="flex-1" />
            <button
              onClick={onDisconnect}
              disabled={status === "syncing"}
              className="h-7 px-2.5 rounded-[5px] bg-transparent border border-edge text-[11px] text-ink-muted hover:text-rose-400 hover:border-rose-400/50 transition-colors disabled:opacity-50"
            >
              Disconnect
            </button>
          </div>

          {extraActions && <div className="mt-2">{extraActions}</div>}

          {status === "error" && errorMessage && (
            <div className="mt-2 bg-rose-500/10 border border-rose-500/20 rounded px-2.5 py-1.5 text-xs text-rose-400">
              {errorMessage}
            </div>
          )}
        </>
      ) : (
        <button
          onClick={onConnect}
          disabled={isConnecting}
          className="w-full h-[30px] rounded-[5px] bg-raised border border-edge text-[12px] font-medium text-ink hover:bg-overlay transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isConnecting ? "Connecting…" : connectLabel}
        </button>
      )}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[10px] text-ink-muted uppercase tracking-[0.08em] mb-0.5">
        {label}
      </div>
      <div
        className="text-[14px] text-ink font-semibold tabular-nums"
        style={{ fontFamily: "var(--font-mono)" }}
      >
        {value}
      </div>
    </div>
  );
}

function SecondaryBtn({
  onClick,
  disabled,
  children,
}: {
  onClick?: () => void;
  disabled?: boolean;
  children: ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="flex items-center gap-1.5 h-7 px-3 rounded-[5px] bg-raised border border-edge text-[12px] text-ink-secondary hover:text-ink hover:bg-overlay transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
    >
      {children}
    </button>
  );
}
