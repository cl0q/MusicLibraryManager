import { invoke } from "@tauri-apps/api/core";
import type { Track } from "../types/library";

// Playlist types
export interface Playlist {
  id: string;
  name: string;
  category: "liked" | "smart" | "regular";
  track_count: number;
  source_id?: string;
  external_id?: string;
  created_at: string;
  updated_at: string;
}

export interface PlaylistTrack {
  track: Track;
  position: string;
  added_at: string;
}

// Sync types
export interface SyncProfile {
  id: string;
  name: string;
  target_folder: string;
  manual_track_count: number;
  playlist_count: number;
  rule_count: number;
  total_track_count: number;
  created_at: string;
  updated_at: string;
}

export interface RockboxDevice {
  name: string;
  mount_path: string;
  capacity_mb: number;
  available_mb: number;
}

export interface SyncPreview {
  files_to_add: string[];
  files_to_update: string[];
  files_to_remove: string[];
  playlists_to_create: string[];
  total_size_bytes: number;
  device_space_available_bytes: number;
}

// Playlist commands
export async function get_playlists_command(): Promise<Playlist[]> {
  return invoke<Playlist[]>("get_playlists");
}

export async function get_playlist_tracks_command(
  playlist_id: string
): Promise<PlaylistTrack[]> {
  return invoke<PlaylistTrack[]>("get_playlist_tracks", { playlistId: playlist_id });
}

// Search and import commands
export async function search_library(query: string): Promise<Track[]> {
  return invoke<Track[]>("search_library", { query });
}

export async function get_library_storage_size(): Promise<number> {
  return invoke<number>("get_library_storage_size");
}

export async function import_directory(path: string): Promise<number> {
  return invoke<number>("import_directory", { path });
}

// Sync profile commands
export async function list_sync_profiles(): Promise<SyncProfile[]> {
  return invoke<SyncProfile[]>("list_sync_profiles");
}

export async function get_last_sync_time(): Promise<string | null> {
  return invoke<string | null>("get_last_sync_time");
}

export interface SyncResult {
  files_added: number;
  files_updated: number;
  files_removed: number;
  playlists_created: number;
}

export async function execute_sync_cmd(profile_id: string): Promise<SyncResult> {
  return invoke<SyncResult>("execute_sync_cmd", { profileId: Number(profile_id) });
}

export async function detect_rockbox_devices_cmd(): Promise<RockboxDevice[]> {
  return invoke<RockboxDevice[]>("detect_rockbox_devices");
}

// Download commands
export interface DownloadRequest {
  track_ids: string[];
}

export async function download_tracks(request: DownloadRequest): Promise<void> {
  return invoke<void>("download_tracks", { request });
}

export interface RetryQueueStatus {
  pending_count: number;
  failed_count: number;
}

export async function get_retry_queue_status(): Promise<RetryQueueStatus> {
  return invoke<RetryQueueStatus>("get_retry_queue_status");
}
