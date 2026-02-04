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
