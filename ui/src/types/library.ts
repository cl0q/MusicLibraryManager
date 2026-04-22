// Track metadata (nested in Track)
export interface TrackMetadata {
  artist: string;
  album_artist: string;
  album: string;
  title: string;
  genre: string | null;
  year: number | null;
  bitrate: number | null;
  duration: number | null;
  format: string;
  original_path: string;
}

// Track type definition (matches backend Rust struct)
export interface Track {
  id: number | null;
  metadata: TrackMetadata;
  organized_path: string | null;
  is_duplicate: boolean;
  date_added: string | null;
  // Phase 18: loudness columns on tracks (nullable). Populated by the
  // replaygain / loudness analysis passes; NULL means "not analyzed yet".
  lufs_i?: number | null;
  lufs_range?: number | null;
  true_peak?: number | null;
  energy_bucket?: number | null;
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
