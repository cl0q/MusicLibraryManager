/**
 * SyncPreview — Solar diff UI for sync profile dry-run.
 *
 * Mock: `screens.jsx` SyncPreviewScreen + DiffSection. Per CONTRACT §2:
 * diff rows show identity + duration only (no BPM, no Camelot key).
 *
 * Wiring is unchanged: invokes `preview_sync_cmd` (dry-run), displays
 * add/remove/unchanged sections, and `execute_sync_cmd` on Apply.
 */

import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';

export interface RockboxDevice {
  mount_point: string;
  device_name: string;
  available_space: number;
}

interface FilePreview {
  track_id: number;
  title: string;
  artist: string;
  album: string;
  size: number;
  destination_path: string;
}

interface SyncPreviewData {
  files_to_add: FilePreview[];
  files_to_remove: string[];
  total_new_size: number;
  total_remove_size: number;
  device_available_space: number | null;
  has_sufficient_space: boolean;
}

interface SyncResult {
  synced_count: number;
  failed_count: number;
  failed_tracks: [number, string][];
}

interface SyncPreviewProps {
  profileId: number;
  profileName: string;
  /** Total tracks currently in the profile (used to derive unchanged count). */
  profileTrackCount: number;
  onBack: () => void;
}

export default function SyncPreview({
  profileId,
  profileName,
  profileTrackCount,
  onBack,
}: SyncPreviewProps) {
  const [devices, setDevices] = useState<RockboxDevice[]>([]);
  const [selectedDevice, setSelectedDevice] = useState<RockboxDevice | null>(null);
  const [preview, setPreview] = useState<SyncPreviewData | null>(null);
  const [syncResult, setSyncResult] = useState<SyncResult | null>(null);
  const [loadingDevices, setLoadingDevices] = useState(true);
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    detectDevices();
  }, []);

  useEffect(() => {
    if (selectedDevice || devices.length === 0) {
      loadPreview();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedDevice, profileId]);

  async function detectDevices() {
    try {
      setLoadingDevices(true);
      setError(null);
      const detected = await invoke<RockboxDevice[]>('detect_rockbox_devices_cmd');
      setDevices(detected);
      if (detected.length === 1) setSelectedDevice(detected[0]);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to detect devices');
    } finally {
      setLoadingDevices(false);
    }
  }

  async function loadPreview() {
    try {
      setLoadingPreview(true);
      setError(null);
      setSyncResult(null);
      const deviceSpace = selectedDevice?.available_space ?? null;
      const previewData = await invoke<SyncPreviewData>('preview_sync_cmd', {
        profileId,
        deviceSpace,
      });
      setPreview(previewData);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load preview');
    } finally {
      setLoadingPreview(false);
    }
  }

  async function executeSync() {
    if (!preview) return;
    try {
      setSyncing(true);
      setError(null);
      const result = await invoke<SyncResult>('execute_sync_cmd', { profileId });
      setSyncResult(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to execute sync');
    } finally {
      setSyncing(false);
    }
  }

  // Derived counts — unchanged = profile tracks not in files_to_add (since
  // files_to_remove are paths previously synced that are no longer in the
  // profile, not among current profile tracks).
  const addCount = preview?.files_to_add.length ?? 0;
  const removeCount = preview?.files_to_remove.length ?? 0;
  const unchangedCount = Math.max(0, profileTrackCount - addCount);
  const totalPending = addCount + removeCount;
  const noChanges =
    preview !== null && addCount === 0 && removeCount === 0;

  return (
    <div className="flex flex-col h-full" style={{ fontFamily: 'var(--font-ui)' }}>
      {/* Header */}
      <div className="flex items-center gap-3 px-4 py-2.5 border-b border-edge-subtle shrink-0">
        <button
          onClick={onBack}
          className="text-ink-muted hover:text-ink transition-colors flex items-center justify-center"
          title="Back to profiles"
        >
          <svg
            className="w-[14px] h-[14px] rotate-180"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            strokeWidth={1.8}
          >
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 6l6 6-6 6" />
          </svg>
        </button>
        <span className="text-[13px] font-semibold text-ink truncate">{profileName}</span>
        <span className="text-[11px] text-ink-muted shrink-0">
          {loadingPreview
            ? 'Computing…'
            : preview
              ? `dry run · ${totalPending} change${totalPending === 1 ? '' : 's'} pending`
              : 'dry run'}
        </span>
        <div className="flex-1" />
        {preview && (
          <>
            <span
              className="text-[11px]"
              style={{ color: 'var(--color-emerald, #10b981)' }}
            >
              + {addCount} add
            </span>
            <span
              className="text-[11px]"
              style={{ color: 'var(--color-rose, #f43f5e)' }}
            >
              − {removeCount} remove
            </span>
            <span className="text-[11px] text-ink-muted">{unchangedCount} unchanged</span>
            <div className="w-px h-4 bg-edge ml-1.5" />
          </>
        )}
        <button
          onClick={executeSync}
          disabled={
            !preview ||
            syncing ||
            loadingPreview ||
            !preview.has_sufficient_space ||
            noChanges
          }
          className="h-[28px] px-3.5 rounded-[5px] bg-accent hover:bg-accent-bright text-base text-[12px] font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {syncing ? 'Syncing…' : 'Apply sync →'}
        </button>
      </div>

      {/* Device selector / warnings */}
      {(devices.length > 0 || error || (preview && !preview.has_sufficient_space)) && (
        <div className="px-4 pt-3 shrink-0 space-y-2">
          {devices.length > 0 && (
            <div className="flex items-center gap-2 text-[11px] text-ink-muted">
              <span className="uppercase tracking-[0.08em] font-semibold">Target device</span>
              <select
                value={selectedDevice?.mount_point || ''}
                onChange={(e) => {
                  const d = devices.find((x) => x.mount_point === e.target.value);
                  setSelectedDevice(d || null);
                }}
                className="bg-raised border border-edge rounded-[4px] px-2 py-0.5 text-[11px] text-ink focus:outline-none focus:border-accent/50"
              >
                {devices.map((device) => (
                  <option key={device.mount_point} value={device.mount_point}>
                    {device.device_name} ({formatSize(device.available_space)} free)
                  </option>
                ))}
              </select>
            </div>
          )}

          {error && (
            <div className="bg-rose-500/10 border border-rose-500/20 rounded-[5px] px-3 py-2 flex items-center gap-3">
              <span className="text-[11px] text-rose-400 flex-1">{error}</span>
              <button
                onClick={loadPreview}
                className="text-[11px] text-rose-300 hover:text-rose-200 underline"
              >
                Retry
              </button>
            </div>
          )}

          {preview && !preview.has_sufficient_space && (
            <div className="bg-rose-500/10 border border-rose-500/20 rounded-[5px] px-3 py-2">
              <p className="text-[11px] text-rose-400 font-semibold">Insufficient disk space</p>
              <p className="text-[11px] text-rose-300 mt-0.5">
                Need {formatSize(preview.total_new_size)} but only{' '}
                {formatSize(preview.device_available_space || 0)} available.
              </p>
            </div>
          )}
        </div>
      )}

      {/* Sync result overlay */}
      {syncResult && (
        <div className="px-4 pt-3 shrink-0">
          <div className="bg-surface border border-edge rounded-md p-3">
            <p className="text-[13px] text-ink font-semibold mb-2">Sync complete</p>
            <div
              className="flex items-center gap-4 text-[11px]"
              style={{ fontFamily: 'var(--font-mono)' }}
            >
              <span style={{ color: 'var(--color-emerald, #10b981)' }}>
                {syncResult.synced_count} synced
              </span>
              {syncResult.failed_count > 0 && (
                <span style={{ color: 'var(--color-rose, #f43f5e)' }}>
                  {syncResult.failed_count} failed
                </span>
              )}
            </div>
            {syncResult.failed_tracks.length > 0 && (
              <div className="mt-2 max-h-32 overflow-auto space-y-0.5">
                {syncResult.failed_tracks.map(([trackId, err]) => (
                  <div key={trackId} className="text-[10.5px] text-rose-300">
                    <span className="text-ink-muted">#{trackId}:</span> {err}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Diff body */}
      <div className="flex-1 overflow-auto px-4 pb-4 pt-1">
        {loadingDevices || loadingPreview ? (
          <div className="flex items-center justify-center h-full">
            <span className="text-sm text-ink-muted">
              {loadingDevices ? 'Detecting devices…' : 'Computing sync preview…'}
            </span>
          </div>
        ) : preview ? (
          <>
            {preview.files_to_add.length > 0 && (
              <DiffSection
                label="Adding to device"
                color="var(--color-emerald, #10b981)"
                sign="+"
                count={preview.files_to_add.length}
                rows={preview.files_to_add.map((f) => ({
                  key: `add-${f.track_id}`,
                  title: f.title || 'Unknown',
                  artist: f.artist || 'Unknown',
                  meta: formatSize(f.size),
                  action: 'add' as const,
                }))}
              />
            )}

            {preview.files_to_remove.length > 0 && (
              <DiffSection
                label="Removing from device"
                color="var(--color-rose, #f43f5e)"
                sign="−"
                count={preview.files_to_remove.length}
                rows={preview.files_to_remove.map((path, i) => {
                  const filename = path.split('/').pop() || path;
                  return {
                    key: `rm-${i}-${path}`,
                    title: filename,
                    artist: path.substring(0, path.lastIndexOf('/')) || '—',
                    meta: '',
                    action: 'remove' as const,
                  };
                })}
              />
            )}

            {noChanges && (
              <div className="mt-8 text-center">
                <p className="text-[12px] text-ink-muted">Already in sync — no changes needed.</p>
              </div>
            )}

            {unchangedCount > 0 && totalPending > 0 && (
              <div className="mt-4 text-[10.5px] text-ink-muted text-center">
                {unchangedCount} unchanged {unchangedCount === 1 ? 'track' : 'tracks'} not shown.
              </div>
            )}
          </>
        ) : null}
      </div>
    </div>
  );
}

/* ── Atoms ──────────────────────────────────────────── */

interface DiffRow {
  key: string;
  title: string;
  artist: string;
  meta: string;
  action: 'add' | 'remove' | 'same';
}

function DiffSection({
  label,
  color,
  sign,
  count,
  rows,
}: {
  label: string;
  color: string;
  sign: string;
  count: number;
  rows: DiffRow[];
}) {
  return (
    <div className="mt-4">
      <div
        className="text-[10px] uppercase tracking-[0.1em] font-bold flex items-center gap-1.5 mb-1.5"
        style={{ color }}
      >
        <span>{label}</span>
        <span className="opacity-60">· {count}</span>
      </div>
      <div className="border border-edge rounded-[5px] bg-surface overflow-hidden">
        {rows.map((row, i) => (
          <div
            key={row.key}
            className="grid items-center gap-2.5 px-3"
            style={{
              gridTemplateColumns: '16px 1fr 90px',
              padding: '6px 12px',
              borderTop: i > 0 ? '1px solid var(--color-edge-subtle)' : 'none',
              background:
                row.action === 'add'
                  ? 'color-mix(in oklab, var(--color-emerald, #10b981) 5%, transparent)'
                  : row.action === 'remove'
                    ? 'color-mix(in oklab, var(--color-rose, #f43f5e) 5%, transparent)'
                    : 'transparent',
            }}
          >
            <span
              className="font-semibold text-[12px]"
              style={{ color, fontFamily: 'var(--font-mono)' }}
            >
              {sign}
            </span>
            <div className="min-w-0 overflow-hidden">
              <div className="text-[12.5px] text-ink truncate">{row.title}</div>
              <div className="text-[11px] text-ink-muted truncate">{row.artist}</div>
            </div>
            <span
              className="text-[11px] text-ink-muted text-right tabular-nums"
              style={{ fontFamily: 'var(--font-mono)' }}
            >
              {row.meta}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
