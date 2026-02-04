/**
 * React hooks for playlist operations using Tauri commands.
 *
 * Provides typed wrappers around Tauri invoke calls for:
 * - Creating playlists
 * - Fetching playlists and tracks
 * - Searching within playlists
 * - Adding/removing tracks
 * - Reordering tracks via drag-drop
 */

import { invoke } from '@tauri-apps/api/tauri';

/**
 * Playlist category enum matching Rust model.
 */
export type PlaylistCategory = 'liked' | 'smart' | 'regular';

/**
 * Playlist model matching Rust Playlist struct.
 */
export interface Playlist {
  id: number;
  name: string;
  description: string | null;
  category: PlaylistCategory;
  is_liked: boolean;
  is_smart: boolean;
  is_pinned: boolean;
  cover_image_path: string | null;
  cover_image_url: string | null;
  source_id: number | null;
  external_id: string | null;
  date_created: string;
}

/**
 * Track model matching Rust Track struct.
 */
export interface Track {
  id: number;
  metadata: {
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
  };
  organized_path: string;
  is_duplicate: boolean;
  date_added: string | null;
}

/**
 * Get all playlists ordered by pinned status, category, then name.
 */
export async function getPlaylists(): Promise<Playlist[]> {
  return invoke<Playlist[]>('get_playlists_command');
}

/**
 * Get all tracks in a playlist, ordered by position.
 */
export async function getPlaylistTracks(playlistId: number): Promise<Track[]> {
  return invoke<Track[]>('get_playlist_tracks_command', { playlistId });
}

/**
 * Search for tracks within a playlist using case-insensitive matching.
 */
export async function searchPlaylistTracks(
  playlistId: number,
  query: string
): Promise<Track[]> {
  return invoke<Track[]>('search_playlist_tracks_command', {
    playlistId,
    query,
  });
}

/**
 * Create a new playlist with optional description and tags.
 * Returns the ID of the created playlist.
 */
export async function createPlaylist(
  name: string,
  description?: string,
  tags?: string[]
): Promise<number> {
  return invoke<number>('create_playlist_command', {
    name,
    description: description || null,
    tags: tags || [],
  });
}

/**
 * Add a track to a playlist (appends to end).
 */
export async function addTrackToPlaylist(
  playlistId: number,
  trackId: number
): Promise<void> {
  return invoke('add_track_to_playlist_command', {
    playlistId,
    trackId,
  });
}

/**
 * Remove a track from a playlist.
 */
export async function removeTrackFromPlaylist(
  playlistId: number,
  trackId: number
): Promise<void> {
  return invoke('remove_track_from_playlist_command', {
    playlistId,
    trackId,
  });
}

/**
 * Reorder a track within a playlist via drag-drop.
 * Computes new position between after_track and before_track.
 */
export async function reorderPlaylistTrack(
  playlistId: number,
  trackId: number,
  afterTrackId?: number,
  beforeTrackId?: number
): Promise<void> {
  return invoke('reorder_playlist_track_command', {
    playlistId,
    trackId,
    afterTrackId: afterTrackId || null,
    beforeTrackId: beforeTrackId || null,
  });
}
