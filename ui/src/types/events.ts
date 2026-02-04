// Activity event type for dashboard and activity feed
export interface ActivityEvent {
  type: "track_added" | "sync_completed" | "download_completed" | "error";
  message: string;
  timestamp: number;
  details?: Record<string, unknown>;
}

// Download progress event for downloads page and status bar
export interface DownloadProgressEvent {
  track_id: string;
  track_name: string;
  status: "queued" | "downloading" | "transcoding" | "completed" | "failed";
  progress: number;
  error?: string;
  source?: string;
  current_step?: string;
  speed?: string;
  eta?: string;
  file_size?: number;
}

// Sync event types for real-time sync progress tracking
export interface SyncStartedEvent {
  profile_id: number;
}

export interface SyncProgressEvent {
  profile_id: number;
  files_synced: number;
  total_files: number;
}

export interface SyncCompletedEvent {
  profile_id: number;
  result: {
    files_added: number;
    files_updated: number;
    files_removed: number;
  };
}

export interface SyncFailedEvent {
  profile_id: number;
  error: string;
}
