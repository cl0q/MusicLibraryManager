import { useState, useEffect } from 'react';
import { listen } from '@tauri-apps/api/event';

interface TranscodeProgress {
  current: number;
  total: number;
  artist: string;
  title: string;
}

export interface SyncProgressState {
  isActive: boolean;
  phase: 'idle' | 'transcoding' | 'syncing' | 'done';
  transcode: TranscodeProgress | null;
  syncedFiles: number;
  totalFiles: number;
}

export function useSyncProgress(): SyncProgressState {
  const [state, setState] = useState<SyncProgressState>({
    isActive: false,
    phase: 'idle',
    transcode: null,
    syncedFiles: 0,
    totalFiles: 0,
  });

  useEffect(() => {
    const unlisteners: (() => void)[] = [];

    listen<{ profile_id: number; total: number }>('sync:transcode_started', (e) => {
      setState({
        isActive: true,
        phase: 'transcoding',
        transcode: { current: 0, total: e.payload.total, artist: '', title: '' },
        syncedFiles: 0,
        totalFiles: 0,
      });
    }).then((u) => unlisteners.push(u));

    listen<TranscodeProgress>('sync:transcode_progress', (e) => {
      setState((prev) => ({
        ...prev,
        transcode: e.payload,
      }));
    }).then((u) => unlisteners.push(u));

    listen('sync:transcode_completed', () => {
      setState((prev) => ({
        ...prev,
        phase: 'syncing',
        transcode: null,
      }));
    }).then((u) => unlisteners.push(u));

    listen('sync:started', () => {
      setState((prev) => ({
        ...prev,
        isActive: true,
        phase: prev.phase === 'idle' ? 'syncing' : prev.phase,
      }));
    }).then((u) => unlisteners.push(u));

    listen<{ files_synced: number; total_files: number }>('sync:progress', (e) => {
      setState((prev) => ({
        ...prev,
        phase: 'syncing',
        syncedFiles: e.payload.files_synced,
        totalFiles: e.payload.total_files,
      }));
    }).then((u) => unlisteners.push(u));

    listen('sync:completed', () => {
      setState({
        isActive: false,
        phase: 'idle',
        transcode: null,
        syncedFiles: 0,
        totalFiles: 0,
      });
    }).then((u) => unlisteners.push(u));

    return () => {
      unlisteners.forEach((u) => u());
    };
  }, []);

  return state;
}
