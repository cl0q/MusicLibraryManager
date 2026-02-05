// Track type definition
export interface Track {
  id: string;
  title: string;
  artist: string;
  album: string;
  album_artist: string;
  duration: number;
  source: string;
  quality: string;
  date_added: string;
  local_path?: string;
}

// Album type (basic stub for future use)
export interface Album {
  id: string;
  title: string;
  artist: string;
  year?: number;
  track_count: number;
}

// Artist type (basic stub for future use)
export interface Artist {
  id: string;
  name: string;
  track_count: number;
}

// Review queue types
export interface ReviewQueueItem {
  id: number;
  action_type: string;
  track_id: number;
  related_track_id: number | null;
  details: string; // JSON string
  auto_action: string | null;
  status: string;
  created_at: string;
  resolved_at: string | null;
}

// Enhancement progress types
export interface EnhancementProgress {
  current: number;
  total: number;
  track_id?: number;
}
