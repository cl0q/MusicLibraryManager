import { useState, useEffect, useCallback } from 'react';
import { listen } from '@tauri-apps/api/event';
import type { EnhancementProgress, ReviewQueueItem } from '../types/library';
import { getReviewQueue, resolveReviewItem } from '../utils/tauri-commands';

/**
 * Hook for tracking enhancement operation progress.
 *
 * Listens for Tauri events emitted by enhancement commands:
 * - {prefix}:started - Operation started
 * - {prefix}:progress - Progress update
 * - {prefix}:completed - Operation completed
 *
 * @param eventPrefix - Event prefix (e.g., "fingerprint", "artwork", "replaygain")
 * @returns Object with isRunning, progress, and result
 */
export function useEnhancementProgress(eventPrefix: string) {
  const [isRunning, setIsRunning] = useState(false);
  const [progress, setProgress] = useState<EnhancementProgress | null>(null);
  const [result, setResult] = useState<any>(null);
  // True from the moment the user clicks Stop until the backend emits
  // `:stopped`. Lets the button render a distinct "stopping…" state so
  // users get immediate feedback while in-flight workers drain.
  const [isStopping, setIsStopping] = useState(false);

  useEffect(() => {
    let startedUnlisten: (() => void) | null = null;
    let progressUnlisten: (() => void) | null = null;
    let completedUnlisten: (() => void) | null = null;
    let stoppedUnlisten: (() => void) | null = null;

    const setupListeners = async () => {
      startedUnlisten = await listen(`${eventPrefix}:started`, (event) => {
        setIsRunning(true);
        setIsStopping(false);
        setProgress(event.payload as EnhancementProgress);
        setResult(null);
      });

      progressUnlisten = await listen(`${eventPrefix}:progress`, (event) => {
        setProgress(event.payload as EnhancementProgress);
      });

      completedUnlisten = await listen(`${eventPrefix}:completed`, (event) => {
        setIsRunning(false);
        setIsStopping(false);
        setResult(event.payload);
      });

      // Phase 20: cancellation ack from backend. Same shape as completed
      // but the button flips straight back to its idle state.
      stoppedUnlisten = await listen(`${eventPrefix}:stopped`, (event) => {
        setIsRunning(false);
        setIsStopping(false);
        setResult(event.payload);
      });
    };

    setupListeners();

    return () => {
      if (startedUnlisten) startedUnlisten();
      if (progressUnlisten) progressUnlisten();
      if (completedUnlisten) completedUnlisten();
      if (stoppedUnlisten) stoppedUnlisten();
    };
  }, [eventPrefix]);

  return { isRunning, isStopping, progress, result, setIsStopping };
}

/**
 * Hook for managing review queue.
 *
 * Provides functions for fetching review queue items and resolving them.
 *
 * @returns Object with items, loading, refresh, and resolve functions
 */
export function useReviewQueue() {
  const [items, setItems] = useState<ReviewQueueItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async (status?: string) => {
    setLoading(true);
    setError(null);
    try {
      const result = await getReviewQueue(status);
      setItems(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load review queue');
      console.error('Failed to fetch review queue:', err);
    } finally {
      setLoading(false);
    }
  }, []);

  const resolve = useCallback(async (id: number, action: string) => {
    try {
      await resolveReviewItem(id, action);
      // Refresh the list after resolving
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to resolve review item');
      console.error('Failed to resolve review item:', err);
      throw err;
    }
  }, [refresh]);

  return { items, loading, error, refresh, resolve };
}
