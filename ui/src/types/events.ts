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
}
