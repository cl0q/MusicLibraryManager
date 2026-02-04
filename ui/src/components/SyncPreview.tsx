/**
 * SyncPreview component - preview and execute sync operations.
 *
 * Features:
 * - Detects Rockbox devices on mount
 * - Shows sync preview (files to add/remove, sizes)
 * - Space validation with warnings
 * - Execute sync button
 * - Displays sync results (success/failed counts)
 * - Loading states for preview and execution
 * - Formats file sizes as KB/MB/GB
 */

import React, { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/tauri';

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

interface SyncPreview {
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
  onBack: () => void;
}

export default function SyncPreview({
  profileId,
  profileName,
  onBack,
}: SyncPreviewProps) {
  const [devices, setDevices] = useState<RockboxDevice[]>([]);
  const [selectedDevice, setSelectedDevice] = useState<RockboxDevice | null>(
    null
  );
  const [preview, setPreview] = useState<SyncPreview | null>(null);
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
  }, [selectedDevice, profileId]);

  async function detectDevices() {
    try {
      setLoadingDevices(true);
      setError(null);
      const detected = await invoke<RockboxDevice[]>('detect_rockbox_devices_cmd');
      setDevices(detected);
      if (detected.length === 1) {
        setSelectedDevice(detected[0]);
      }
    } catch (err) {
      setError(
        err instanceof Error ? err.message : 'Failed to detect devices'
      );
    } finally {
      setLoadingDevices(false);
    }
  }

  async function loadPreview() {
    try {
      setLoadingPreview(true);
      setError(null);
      setSyncResult(null);
      const deviceSpace = selectedDevice?.available_space || null;
      const previewData = await invoke<SyncPreview>('preview_sync_cmd', {
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
      const result = await invoke<SyncResult>('execute_sync_cmd', {
        profileId,
      });
      setSyncResult(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to execute sync');
    } finally {
      setSyncing(false);
    }
  }

  function formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024)
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  if (loadingDevices) {
    return (
      <div className="p-6">
        <button onClick={onBack} className="text-blue-400 hover:text-blue-300 mb-4">
          ← Back to Profiles
        </button>
        <div className="flex items-center justify-center h-64">
          <div className="text-gray-400">Detecting devices...</div>
        </div>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div>
        <button
          onClick={onBack}
          className="text-blue-400 hover:text-blue-300 mb-2"
        >
          ← Back to Profiles
        </button>
        <h1 className="text-3xl font-bold text-white">{profileName}</h1>
        <p className="text-gray-400 mt-1">Sync Preview</p>
      </div>

      {/* Device Selection */}
      {devices.length > 0 && (
        <div className="bg-gray-800 rounded-lg p-4">
          <label className="block text-sm font-medium text-gray-300 mb-2">
            Target Device
          </label>
          <select
            value={selectedDevice?.mount_point || ''}
            onChange={(e) => {
              const device = devices.find(
                (d) => d.mount_point === e.target.value
              );
              setSelectedDevice(device || null);
            }}
            className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:outline-none focus:border-blue-500"
          >
            {devices.map((device) => (
              <option key={device.mount_point} value={device.mount_point}>
                {device.device_name} ({formatSize(device.available_space)}{' '}
                available)
              </option>
            ))}
          </select>
        </div>
      )}

      {devices.length === 0 && (
        <div className="bg-yellow-900/30 border border-yellow-700 rounded-lg p-4">
          <p className="text-yellow-400">
            No Rockbox devices detected. Sync will use local folder only.
          </p>
        </div>
      )}

      {/* Error Display */}
      {error && (
        <div className="bg-red-900/30 border border-red-700 rounded-lg p-4">
          <p className="text-red-400">{error}</p>
          <button
            onClick={() => loadPreview()}
            className="mt-2 text-sm text-red-300 hover:text-red-200 underline"
          >
            Retry
          </button>
        </div>
      )}

      {/* Loading Preview */}
      {loadingPreview && (
        <div className="bg-gray-800 rounded-lg p-8 text-center">
          <div className="text-gray-400">Computing sync preview...</div>
        </div>
      )}

      {/* Preview Display */}
      {!loadingPreview && preview && !syncResult && (
        <div className="space-y-4">
          {/* Space Warning */}
          {!preview.has_sufficient_space && (
            <div className="bg-red-900/30 border border-red-700 rounded-lg p-4">
              <p className="text-red-400 font-semibold">
                Insufficient disk space!
              </p>
              <p className="text-red-300 text-sm mt-1">
                Need {formatSize(preview.total_new_size)} but only{' '}
                {formatSize(preview.device_available_space || 0)} available.
              </p>
            </div>
          )}

          {/* Summary Stats */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-gray-800 rounded-lg p-4">
              <div className="text-gray-400 text-sm">Files to Add</div>
              <div className="text-white text-2xl font-bold">
                {preview.files_to_add.length}
              </div>
              <div className="text-gray-500 text-xs mt-1">
                {formatSize(preview.total_new_size)}
              </div>
            </div>
            <div className="bg-gray-800 rounded-lg p-4">
              <div className="text-gray-400 text-sm">Files to Remove</div>
              <div className="text-white text-2xl font-bold">
                {preview.files_to_remove.length}
              </div>
              <div className="text-gray-500 text-xs mt-1">
                {formatSize(preview.total_remove_size)}
              </div>
            </div>
            {preview.device_available_space !== null && (
              <>
                <div className="bg-gray-800 rounded-lg p-4">
                  <div className="text-gray-400 text-sm">Available Space</div>
                  <div className="text-white text-2xl font-bold">
                    {formatSize(preview.device_available_space)}
                  </div>
                </div>
                <div className="bg-gray-800 rounded-lg p-4">
                  <div className="text-gray-400 text-sm">After Sync</div>
                  <div className="text-white text-2xl font-bold">
                    {formatSize(
                      preview.device_available_space -
                        preview.total_new_size +
                        preview.total_remove_size
                    )}
                  </div>
                </div>
              </>
            )}
          </div>

          {/* Files to Add */}
          {preview.files_to_add.length > 0 && (
            <div className="bg-gray-800 rounded-lg p-4">
              <h3 className="text-lg font-semibold text-white mb-3">
                Files to Add ({preview.files_to_add.length})
              </h3>
              <div className="space-y-2 max-h-64 overflow-y-auto">
                {preview.files_to_add.slice(0, 10).map((file) => (
                  <div
                    key={file.track_id}
                    className="flex justify-between items-start text-sm bg-gray-700 rounded p-2"
                  >
                    <div className="flex-1 min-w-0">
                      <div className="text-white truncate">{file.title}</div>
                      <div className="text-gray-400 text-xs truncate">
                        {file.artist} • {file.album}
                      </div>
                    </div>
                    <div className="text-gray-300 text-xs ml-2 whitespace-nowrap">
                      {formatSize(file.size)}
                    </div>
                  </div>
                ))}
                {preview.files_to_add.length > 10 && (
                  <div className="text-gray-400 text-sm text-center pt-2">
                    ... and {preview.files_to_add.length - 10} more
                  </div>
                )}
              </div>
            </div>
          )}

          {/* Files to Remove */}
          {preview.files_to_remove.length > 0 && (
            <div className="bg-gray-800 rounded-lg p-4">
              <h3 className="text-lg font-semibold text-white mb-3">
                Files to Remove ({preview.files_to_remove.length})
              </h3>
              <div className="space-y-1 max-h-48 overflow-y-auto">
                {preview.files_to_remove.slice(0, 10).map((path, idx) => (
                  <div
                    key={idx}
                    className="text-sm text-gray-400 bg-gray-700 rounded p-2 truncate"
                  >
                    {path}
                  </div>
                ))}
                {preview.files_to_remove.length > 10 && (
                  <div className="text-gray-400 text-sm text-center pt-2">
                    ... and {preview.files_to_remove.length - 10} more
                  </div>
                )}
              </div>
            </div>
          )}

          {/* Execute Button */}
          <button
            onClick={executeSync}
            disabled={
              syncing ||
              !preview.has_sufficient_space ||
              (preview.files_to_add.length === 0 &&
                preview.files_to_remove.length === 0)
            }
            className="w-full px-6 py-3 bg-green-600 hover:bg-green-700 text-white rounded-lg transition disabled:opacity-50 disabled:cursor-not-allowed font-semibold"
          >
            {syncing ? 'Syncing...' : 'Execute Sync'}
          </button>

          {preview.files_to_add.length === 0 &&
            preview.files_to_remove.length === 0 && (
              <p className="text-center text-gray-400">
                Already in sync - no changes needed.
              </p>
            )}
        </div>
      )}

      {/* Sync Result */}
      {syncResult && (
        <div className="space-y-4">
          <div className="bg-gray-800 rounded-lg p-6">
            <h3 className="text-2xl font-bold text-white mb-4">
              Sync Complete!
            </h3>
            <div className="grid grid-cols-2 gap-4">
              <div className="bg-green-900/30 border border-green-700 rounded-lg p-4">
                <div className="text-green-400 text-sm">Synced</div>
                <div className="text-white text-3xl font-bold">
                  {syncResult.synced_count}
                </div>
              </div>
              <div className="bg-red-900/30 border border-red-700 rounded-lg p-4">
                <div className="text-red-400 text-sm">Failed</div>
                <div className="text-white text-3xl font-bold">
                  {syncResult.failed_count}
                </div>
              </div>
            </div>

            {syncResult.failed_tracks.length > 0 && (
              <div className="mt-4">
                <h4 className="text-red-400 font-semibold mb-2">
                  Failed Tracks:
                </h4>
                <div className="space-y-1 max-h-48 overflow-y-auto">
                  {syncResult.failed_tracks.map(([trackId, error]) => (
                    <div
                      key={trackId}
                      className="text-sm bg-gray-700 rounded p-2"
                    >
                      <span className="text-gray-300">Track #{trackId}:</span>{' '}
                      <span className="text-red-300">{error}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>

          <div className="flex space-x-4">
            <button
              onClick={onBack}
              className="flex-1 px-6 py-3 bg-gray-700 hover:bg-gray-600 text-white rounded-lg transition"
            >
              Back to Profiles
            </button>
            <button
              onClick={loadPreview}
              className="flex-1 px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition"
            >
              Sync Again
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
