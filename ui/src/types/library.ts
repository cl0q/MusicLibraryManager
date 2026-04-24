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

// Phase 21 v16 albums. Mirrors the Rust `Album` struct in
// src-tauri/src/database/albums.rs. Note: replaces the pre-Phase-21 stub
// that used id: string — v16 uses i64 (serialized as number).
export interface Album {
  id: number;
  artist: string;
  album_artist: string;
  title: string;
  title_normalized: string;
  year: number | null;
  cover_path: string | null;
  variant_of: number | null;
  variant_kind: "u" | "0.5" | "v1" | "v2" | "v4" | null;
}

// Phase 21: full payload from `get_album_detail_cmd`. Includes the album's
// tracks + its sibling albums (each with their own track list) + the user's
// current variant selection for this base_album_id.
//
// `siblings` contains albums where variant_of == this album's id (i.e. this
// is the base). The UFO toggle renders when siblings.length === 1 AND the
// is_yeat flag is true. Phase 22 Winamp cycler renders when siblings.length >= 2.
export interface AlbumDetail {
  album: Album;
  tracks: Track[];
  siblings: { album: Album; tracks: Track[] }[];
  selected_album_id: number;   // either album.id (base) or a sibling's id
  is_yeat: boolean;            // true when any track on this album or siblings has tag_key='artist' AND tag_value='yeat'
}

// Phase 21: UPSERT into user_album_variant_pref. Matches the Rust command
// parameters for `set_variant_preference_cmd`.
export interface VariantPreference {
  base_album_id: number;
  selected_album_id: number;
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
