import { toast } from "sonner";
import SyncProfiles, { type SyncProfileDto } from "../components/SyncProfiles";
import { execute_sync_cmd, clean_sync_cmd } from "../utils/tauri-commands";
import { useSyncProgress } from "../hooks/useSyncProgress";

export default function Sync() {
  const progress = useSyncProgress();

  const handleSelectProfile = async (profile: SyncProfileDto) => {
    try {
      const result = await execute_sync_cmd(String(profile.id));
      toast.success(
        `Sync complete! ${result.synced_count} synced, ${result.failed_count} failed`
      );
    } catch (error) {
      console.error("Sync failed:", error);
      toast.error(`Sync failed: ${error}`);
    }
  };

  const handleCleanSync = async (profile: SyncProfileDto) => {
    try {
      const result = await clean_sync_cmd(String(profile.id));
      toast.success(
        `Clean sync complete! ${result.synced_count} synced, ${result.failed_count} failed`
      );
    } catch (error) {
      console.error("Clean sync failed:", error);
      toast.error(`Clean sync failed: ${error}`);
    }
  };

  return (
    <div className="relative h-full">
      <SyncProfiles onSelectProfile={handleSelectProfile} onCleanSync={handleCleanSync} />

      {progress.isActive && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 w-[400px] bg-surface border border-edge rounded-lg shadow-lg p-3">
          {progress.phase === 'transcoding' && progress.transcode && (
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
                  Transcoding
                </span>
                <span className="text-[11px] text-ink-muted tabular-nums">
                  {progress.transcode.current}/{progress.transcode.total}
                </span>
              </div>
              <div className="w-full h-1.5 bg-raised rounded-full overflow-hidden">
                <div
                  className="h-full bg-accent rounded-full transition-all duration-300"
                  style={{
                    width: `${(progress.transcode.current / progress.transcode.total) * 100}%`,
                  }}
                />
              </div>
              {progress.transcode.artist && (
                <p className="text-xs text-ink-secondary truncate">
                  {progress.transcode.artist} - {progress.transcode.title}
                </p>
              )}
            </div>
          )}

          {progress.phase === 'syncing' && (
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
                  Syncing files
                </span>
                {progress.totalFiles > 0 && (
                  <span className="text-[11px] text-ink-muted tabular-nums">
                    {progress.syncedFiles}/{progress.totalFiles}
                  </span>
                )}
              </div>
              <div className="w-full h-1.5 bg-raised rounded-full overflow-hidden">
                <div
                  className="h-full bg-emerald-500 rounded-full transition-all duration-300 animate-pulse"
                  style={{
                    width: progress.totalFiles > 0
                      ? `${(progress.syncedFiles / progress.totalFiles) * 100}%`
                      : '100%',
                  }}
                />
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
