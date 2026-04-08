import { useState, useEffect, useRef, useCallback } from "react";
import { useDownloadQueue } from "../../hooks/useDownloadQueue";
import { useSyncProgress } from "../../hooks/useTauriEvents";
import { invokeTauriCommand } from "../../hooks/useTauriCommand";
import type { Track } from "../../types/library";
import { get_library_storage_size, get_last_sync_time } from "../../utils/tauri-commands";
import { listen } from "@tauri-apps/api/event";

function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
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

// Strip ANSI escape codes from log messages
function stripAnsi(str: string): string {
  return str.replace(/\x1b\[[0-9;]*m/g, "");
}

// Log level number -> label and color class
// tauri-plugin-log: Trace=1, Debug=2, Info=3, Warn=4, Error=5
function levelStyle(level: number): { label: string; color: string } {
  switch (level) {
    case 5: return { label: "ERR", color: "text-[#dc322f]" };  // solarized red
    case 4: return { label: "WRN", color: "text-[#cb4b16]" };  // solarized orange
    case 3: return { label: "INF", color: "text-[#268bd2]" };  // solarized blue
    case 2: return { label: "DBG", color: "text-[#2aa198]" };  // solarized cyan
    default: return { label: "TRC", color: "text-[#6c71c4]" }; // solarized violet
  }
}

interface LogEntry {
  id: number;
  message: string;
  level: number;
  timestamp: string;
}

const MAX_LOG_ENTRIES = 500;

export default function ActivityPanel() {
  const [isExpanded, setIsExpanded] = useState(false);
  const [activeTab, setActiveTab] = useState<"ops" | "logs">("ops");
  const { downloads, queueStatus, handleRetryFailed, clearDownloads } = useDownloadQueue();
  const syncs = useSyncProgress();

  // Library stats
  const [trackCount, setTrackCount] = useState<number | null>(null);
  const [storageSize, setStorageSize] = useState<number | null>(null);
  const [lastSync, setLastSync] = useState<string | null>(null);

  // Log entries
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const logIdRef = useRef(0);
  const logContainerRef = useRef<HTMLDivElement>(null);
  const [autoScroll, setAutoScroll] = useState(true);

  // Enhancement operation progress
  interface EnhancementOp {
    type: string;
    current: number;
    total: number;
    artist?: string;
    title?: string;
    percent?: number;
    status: "running" | "completed";
  }
  const [enhancementOps, setEnhancementOps] = useState<Map<string, EnhancementOp>>(new Map());

  useEffect(() => {
    const loadStats = async () => {
      try {
        const result = await invokeTauriCommand<Track[]>("search_library", { query: "" });
        if (result.ok && result.data) setTrackCount(result.data.length);
      } catch { /* ignore */ }
      try {
        const size = await get_library_storage_size();
        setStorageSize(size);
      } catch { /* ignore */ }
      try {
        const time = await get_last_sync_time();
        setLastSync(time);
      } catch { /* ignore */ }
    };
    loadStats();
    const interval = setInterval(loadStats, 60000);
    return () => clearInterval(interval);
  }, []);

  // Listen for log events from Rust backend
  useEffect(() => {
    const unlisten = listen<{ message: string; level: number }>("log://log", (event) => {
      const entry: LogEntry = {
        id: logIdRef.current++,
        message: stripAnsi(event.payload.message),
        level: event.payload.level,
        timestamp: new Date().toLocaleTimeString("en-US", { hour12: false }),
      };
      setLogs((prev) => {
        const next = [...prev, entry];
        return next.length > MAX_LOG_ENTRIES ? next.slice(-MAX_LOG_ENTRIES) : next;
      });
    });

    return () => { unlisten.then((fn) => fn()); };
  }, []);

  // Listen for enhancement operation events
  useEffect(() => {
    const eventTypes = ["fingerprint", "artwork", "replaygain", "deepscan"];
    const unlisteners: Promise<() => void>[] = [];

    for (const type of eventTypes) {
      unlisteners.push(
        listen<{ total: number }>(`${type}:started`, () => {
          setEnhancementOps((prev) => {
            const next = new Map(prev);
            next.set(type, { type, current: 0, total: 0, status: "running" });
            return next;
          });
        })
      );
      unlisteners.push(
        listen<{ current: number; total: number; artist?: string; title?: string; percent?: number }>(
          `${type}:progress`,
          (event) => {
            setEnhancementOps((prev) => {
              const next = new Map(prev);
              next.set(type, {
                type,
                current: event.payload.current,
                total: event.payload.total,
                artist: event.payload.artist,
                title: event.payload.title,
                percent: event.payload.percent,
                status: "running",
              });
              return next;
            });
          }
        )
      );
      unlisteners.push(
        listen(`${type}:completed`, () => {
          setEnhancementOps((prev) => {
            const next = new Map(prev);
            const existing = next.get(type);
            if (existing) {
              next.set(type, { ...existing, status: "completed" });
            }
            return next;
          });
          // Remove after 5s
          setTimeout(() => {
            setEnhancementOps((prev) => {
              const next = new Map(prev);
              next.delete(type);
              return next;
            });
          }, 5000);
        })
      );
    }

    return () => {
      unlisteners.forEach((u) => u.then((fn) => fn()));
    };
  }, []);

  // Auto-scroll log container (defer to next frame so DOM has updated)
  useEffect(() => {
    if (autoScroll && logContainerRef.current) {
      const el = logContainerRef.current;
      requestAnimationFrame(() => {
        el.scrollTop = el.scrollHeight;
      });
    }
  }, [logs, autoScroll]);

  const handleLogScroll = useCallback(() => {
    const el = logContainerRef.current;
    if (!el) return;
    // Lock auto-scroll when user scrolls up, unlock when at bottom
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    setAutoScroll(atBottom);
  }, []);

  const clearLogs = useCallback(() => setLogs([]), []);

  const downloadArray = Array.from(downloads.values());
  const activeDownloads = downloadArray.filter(d => d.status === "downloading" || d.status === "transcoding");
  const completedDownloads = downloadArray.filter(d => d.status === "completed");
  const failedDownloads = downloadArray.filter(d => d.status === "failed");
  const queuedDownloads = downloadArray.filter(d => d.status === "queued");
  const activeSyncs = Array.from(syncs.values()).filter(s => s.status === "syncing");

  const activeEnhancements = Array.from(enhancementOps.values()).filter(op => op.status === "running");
  const hasActiveOps = activeDownloads.length > 0 || activeSyncs.length > 0 || activeEnhancements.length > 0;
  const totalActive = activeDownloads.length + activeSyncs.length + activeEnhancements.length;
  const totalCompleted = completedDownloads.length;
  const totalFailed = failedDownloads.length;
  const totalQueued = queuedDownloads.length;

  const allOperations = [...activeDownloads, ...queuedDownloads, ...failedDownloads, ...completedDownloads];

  return (
    <div className={`border-t border-edge bg-surface transition-all duration-200 shrink-0 ${isExpanded ? "h-80" : "h-9"}`}>
      {/* Collapsed summary bar */}
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full h-9 px-4 flex items-center justify-between text-xs cursor-pointer hover:bg-raised/30 transition-colors"
      >
        <div className="flex items-center gap-4">
          {/* Pulse indicator */}
          {hasActiveOps && (
            <span className="relative flex h-1.5 w-1.5">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-sky-400 opacity-75" />
              <span className="relative inline-flex rounded-full h-1.5 w-1.5 bg-sky-400" />
            </span>
          )}

          {/* Operation counts */}
          <div className="flex items-center gap-3 text-ink-muted">
            {totalActive > 0 && (
              <span className="text-sky-400 font-medium">{totalActive} active</span>
            )}
            {totalQueued > 0 && (
              <span>{totalQueued} queued</span>
            )}
            {totalCompleted > 0 && (
              <span className="text-emerald-400">{totalCompleted} done</span>
            )}
            {totalFailed > 0 && (
              <span className="text-rose-400">{totalFailed} failed</span>
            )}
            {allOperations.length === 0 && syncs.size === 0 && (
              <span>No operations</span>
            )}
          </div>

          {/* Separator + library stats */}
          <span className="text-edge">|</span>
          <div className="flex items-center gap-3 text-ink-muted">
            {trackCount !== null && (
              <span className="tabular-nums">{trackCount.toLocaleString()} tracks</span>
            )}
            {storageSize !== null && (
              <span className="tabular-nums">{formatBytes(storageSize)}</span>
            )}
            {lastSync && (
              <span>synced {formatRelativeTime(lastSync)}</span>
            )}
          </div>
        </div>

        {/* Expand chevron */}
        <svg
          className={`w-3 h-3 text-ink-muted transition-transform ${isExpanded ? "rotate-180" : ""}`}
          fill="none" stroke="currentColor" viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 15l7-7 7 7" />
        </svg>
      </button>

      {/* Expanded panel */}
      {isExpanded && (
        <div className="h-[calc(100%-36px)] flex flex-col">
          {/* Tab bar */}
          <div className="flex items-center gap-0 border-b border-edge-subtle px-4 shrink-0">
            <button
              onClick={(e) => { e.stopPropagation(); setActiveTab("ops"); }}
              className={`px-3 py-1.5 text-[11px] font-medium border-b-2 transition-colors ${
                activeTab === "ops"
                  ? "border-sky-400 text-sky-400"
                  : "border-transparent text-ink-muted hover:text-ink"
              }`}
            >
              Operations
            </button>
            <button
              onClick={(e) => { e.stopPropagation(); setActiveTab("logs"); }}
              className={`px-3 py-1.5 text-[11px] font-medium border-b-2 transition-colors ${
                activeTab === "logs"
                  ? "border-sky-400 text-sky-400"
                  : "border-transparent text-ink-muted hover:text-ink"
              }`}
            >
              Logs
              {logs.length > 0 && (
                <span className="ml-1.5 text-[9px] bg-edge/60 px-1 py-0.5 rounded tabular-nums">
                  {logs.length}
                </span>
              )}
            </button>
          </div>

          {/* Tab content */}
          {activeTab === "ops" && (
            <div className="flex-1 overflow-y-auto px-4 pb-3 space-y-2">
              {/* Clear button */}
              {allOperations.length > 0 && (
                <div className="flex justify-end pt-1">
                  <button
                    onClick={(e) => { e.stopPropagation(); clearDownloads(); }}
                    className="text-[10px] text-ink-muted hover:text-ink transition-colors"
                  >
                    Clear
                  </button>
                </div>
              )}

              {/* Failed banner */}
              {totalFailed > 0 && (
                <div className="flex items-center justify-between bg-rose-500/10 border border-rose-500/20 rounded px-3 py-1.5 mt-1">
                  <span className="text-xs text-rose-400">{totalFailed} download{totalFailed !== 1 ? "s" : ""} failed</span>
                  <button
                    onClick={(e) => { e.stopPropagation(); handleRetryFailed(); }}
                    className="text-xs text-rose-400 hover:text-rose-300 font-medium"
                  >
                    Retry all
                  </button>
                </div>
              )}

              {/* Downloads */}
              {allOperations.map((download) => (
                <div key={download.track_id} className="bg-raised/50 rounded px-3 py-2">
                  <div className="flex items-center justify-between gap-3 mb-1">
                    <span className="text-[13px] text-ink truncate flex-1">{download.track_name}</span>
                    <div className="flex items-center gap-2 shrink-0">
                      {download.source && (
                        <span className="text-[10px] text-ink-muted bg-edge/50 px-1.5 py-0.5 rounded">{download.source}</span>
                      )}
                      <span className={`text-xs font-medium ${
                        download.status === "downloading" || download.status === "transcoding" ? "text-sky-400" :
                        download.status === "completed" ? "text-emerald-400" :
                        download.status === "failed" ? "text-rose-400" :
                        "text-ink-muted"
                      }`}>
                        {download.status}
                      </span>
                    </div>
                  </div>

                  {(download.status === "downloading" || download.status === "transcoding" || download.status === "completed") && (
                    <div className="flex items-center gap-2">
                      <div className="flex-1 h-1 bg-edge rounded-full overflow-hidden">
                        <div
                          className={`h-full rounded-full transition-all duration-300 ${
                            download.status === "completed" ? "bg-emerald-500" : "bg-sky-500"
                          }`}
                          style={{ width: `${download.progress}%` }}
                        />
                      </div>
                      <div className="flex items-center gap-2 text-[10px] text-ink-muted tabular-nums shrink-0">
                        {download.progress > 0 && download.progress < 100 && (
                          <span>{download.progress.toFixed(0)}%</span>
                        )}
                        {download.speed && <span>{download.speed}</span>}
                        {download.eta && <span>{download.eta}</span>}
                        {download.file_size && <span>{formatBytes(download.file_size)}</span>}
                      </div>
                    </div>
                  )}

                  {download.error && (
                    <p className="text-[11px] text-rose-400/80 mt-1 truncate">{download.error}</p>
                  )}
                </div>
              ))}

              {/* Syncs */}
              {Array.from(syncs.values()).map((sync) => (
                <div key={sync.profile_id} className="bg-raised/50 rounded px-3 py-2">
                  <div className="flex items-center justify-between mb-1">
                    <span className="text-[13px] text-ink">Syncing profile {sync.profile_id}</span>
                    <span className={`text-xs font-medium ${
                      sync.status === "syncing" ? "text-sky-400" :
                      sync.status === "completed" ? "text-emerald-400" :
                      "text-rose-400"
                    }`}>
                      {sync.status}
                    </span>
                  </div>
                  {sync.status === "syncing" && sync.total_files > 0 && (
                    <div className="flex items-center gap-2">
                      <div className="flex-1 h-1 bg-edge rounded-full overflow-hidden">
                        <div
                          className="h-full bg-sky-500 rounded-full transition-all"
                          style={{ width: `${(sync.files_synced / sync.total_files) * 100}%` }}
                        />
                      </div>
                      <span className="text-[10px] text-ink-muted tabular-nums">
                        {sync.files_synced}/{sync.total_files}
                      </span>
                    </div>
                  )}
                </div>
              ))}

              {/* Enhancement operations */}
              {Array.from(enhancementOps.values()).map((op) => {
                const label = op.type === "fingerprint" ? "Fingerprinting"
                  : op.type === "artwork" ? "Fetching Artwork"
                  : op.type === "replaygain" ? "ReplayGain Analysis"
                  : "Deep Scan";
                const trackName = op.artist && op.title
                  ? `${op.artist} - ${op.title}`
                  : undefined;
                return (
                  <div key={op.type} className="bg-raised/50 rounded px-3 py-2">
                    <div className="flex items-center justify-between gap-3 mb-1">
                      <span className="text-[13px] text-ink truncate flex-1">{label}</span>
                      <span className={`text-xs font-medium ${
                        op.status === "running" ? "text-sky-400" : "text-emerald-400"
                      }`}>
                        {op.status === "running" ? `${op.current}/${op.total}` : "done"}
                      </span>
                    </div>
                    {op.status === "running" && op.total > 0 && (
                      <>
                        <div className="flex items-center gap-2">
                          <div className="flex-1 h-1 bg-edge rounded-full overflow-hidden">
                            <div
                              className="h-full bg-sky-500 rounded-full transition-all duration-300"
                              style={{ width: `${op.percent ?? (op.current / op.total) * 100}%` }}
                            />
                          </div>
                          <span className="text-[10px] text-ink-muted tabular-nums shrink-0">
                            {op.percent ?? Math.round((op.current / op.total) * 100)}%
                          </span>
                        </div>
                        {trackName && (
                          <p className="text-[11px] text-ink-muted truncate mt-1">{trackName}</p>
                        )}
                      </>
                    )}
                  </div>
                );
              })}

              {allOperations.length === 0 && syncs.size === 0 && enhancementOps.size === 0 && (
                <div className="flex items-center justify-center py-8">
                  <span className="text-xs text-ink-muted">No operations to show</span>
                </div>
              )}
            </div>
          )}

          {activeTab === "logs" && (
            <div className="flex-1 flex flex-col min-h-0">
              {/* Log toolbar */}
              <div className="flex items-center justify-between px-4 py-1 shrink-0">
                <div className="flex items-center gap-2 text-[10px] text-ink-muted">
                  <span className="tabular-nums">{logs.length} entries</span>
                  {!autoScroll && (
                    <button
                      onClick={() => setAutoScroll(true)}
                      className="text-sky-400 hover:text-sky-300"
                    >
                      Resume scroll
                    </button>
                  )}
                </div>
                <button
                  onClick={clearLogs}
                  className="text-[10px] text-ink-muted hover:text-ink transition-colors"
                >
                  Clear
                </button>
              </div>
              {/* Log terminal */}
              <div
                ref={logContainerRef}
                onScroll={handleLogScroll}
                className="flex-1 overflow-y-auto px-4 pb-2 font-mono text-[11px] leading-[1.4] bg-[#002b36]"
              >
                {logs.length === 0 && (
                  <div className="flex items-center justify-center py-8">
                    <span className="text-[#586e75]">Waiting for log output...</span>
                  </div>
                )}
                {logs.map((entry) => {
                  const style = levelStyle(entry.level);
                  return (
                    <div key={entry.id} className="flex gap-2 hover:bg-[#073642]/50">
                      <span className="text-[#586e75] shrink-0 tabular-nums">{entry.timestamp}</span>
                      <span className={`shrink-0 font-bold ${style.color}`}>{style.label}</span>
                      <span className="text-[#839496] break-all">{entry.message}</span>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
