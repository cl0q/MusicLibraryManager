import { invoke } from "@tauri-apps/api/core";
import type { Track, ReviewQueueItem } from "../types/library";

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
  return invoke<Playlist[]>("get_playlists_command");
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

/** Get all tracks in the library (for initial load) */
export async function get_library_tracks(): Promise<Track[]> {
  return invoke<Track[]>("get_library_tracks");
}

/** Get only tracks in the library (organized_path IS NOT NULL) */
export async function getLibraryTracksOnly(): Promise<Track[]> {
  return invoke<Track[]>("get_library_tracks_only");
}

/** Get only remote tracks (organized_path IS NULL with streaming sources) */
export async function getRemoteTracksOnly(): Promise<Track[]> {
  return invoke<Track[]>("get_remote_tracks_only");
}

/** Get count of remote tracks (undownloaded streaming tracks) */
export async function getRemoteTrackCount(): Promise<number> {
  return invoke<number>("get_remote_track_count");
}

export async function get_library_storage_size(): Promise<number> {
  return invoke<number>("get_library_storage_size");
}

export interface ImportStartedResponse {
  file_count: number;
}

export interface ImportCompleteEvent {
  succeeded: number;
  failed: number;
  skipped: number;
  total: number;
  failure_summary: string[];
}

export async function import_directory(directory: string): Promise<ImportStartedResponse> {
  return invoke<ImportStartedResponse>("import_directory", { directory });
}

// Sync profile commands
export async function list_sync_profiles(): Promise<SyncProfile[]> {
  return invoke<SyncProfile[]>("list_sync_profiles");
}

export async function get_last_sync_time(): Promise<string | null> {
  return invoke<string | null>("get_last_sync_time");
}

export interface SyncResult {
  synced_count: number;
  failed_count: number;
}

export async function execute_sync_cmd(profile_id: string): Promise<SyncResult> {
  return invoke<SyncResult>("execute_sync_cmd", { profileId: Number(profile_id) });
}

export async function clean_sync_cmd(profile_id: string): Promise<SyncResult> {
  return invoke<SyncResult>("clean_sync_cmd", { profileId: Number(profile_id) });
}

export async function update_sync_profile_settings(profileId: number, playlistPathPrefix: string): Promise<void> {
  return invoke<void>("update_sync_profile_settings", { profileId, playlistPathPrefix });
}

export async function detect_rockbox_devices_cmd(): Promise<RockboxDevice[]> {
  return invoke<RockboxDevice[]>("detect_rockbox_devices");
}

export async function add_playlist_to_profile(profileId: number, playlistId: number): Promise<void> {
  return invoke<void>("add_playlist_to_profile", { profileId, playlistId });
}

export async function remove_playlist_from_profile(profileId: number, playlistId: number): Promise<void> {
  return invoke<void>("remove_playlist_from_profile", { profileId, playlistId });
}

export async function remove_track_from_profile(profileId: number, trackId: number): Promise<void> {
  return invoke<void>("remove_track_from_profile", { profileId, trackId });
}

export interface ProfilePlaylist {
  id: number;
  name: string;
  category: string;
  track_count: number;
}

export async function get_profile_playlists(profileId: number): Promise<ProfilePlaylist[]> {
  return invoke<ProfilePlaylist[]>("get_profile_playlists", { profileId });
}

// Download commands
export interface DownloadRequest {
  track_id?: string;
  query: string;
  artist: string;
  title: string;
  soundcloud_url?: string;
  user_id?: string;
}

export interface BatchResult {
  succeeded: number;
  failed: number;
  skipped: number;
}

export async function download_tracks(
  requests: DownloadRequest[],
  downloadDir: string,
  transcodeDir: string,
  rootDir: string,
): Promise<BatchResult> {
  return invoke<BatchResult>("download_tracks", { requests, downloadDir, transcodeDir, rootDir });
}

export interface RetryQueueStatus {
  pending_count: number;
  failed_count: number;
}

export async function get_retry_queue_status(): Promise<RetryQueueStatus> {
  return invoke<RetryQueueStatus>("get_retry_queue_status");
}

export interface RecentDownload {
  id: number;
  artist: string;
  title: string;
  download_status: string;
  organized_path: string | null;
  format: string | null;
  bitrate: number | null;
}

export async function get_recent_downloads(): Promise<RecentDownload[]> {
  return invoke<RecentDownload[]>("get_recent_downloads");
}

// Enhancement commands
export interface FingerprintResult {
  processed: number;
  failed: number;
  failures?: Array<{ track_id: number; error: string }>;
}

export async function fingerprintLibrary(): Promise<FingerprintResult> {
  return invoke<FingerprintResult>("fingerprint_library_cmd");
}

export interface ArtworkResult {
  fetched: number;
  already_cached: number;
  not_found: number;
  failed: number;
  failures?: Array<{ track_id: number; error: string }>;
}

export async function fetchArtwork(): Promise<ArtworkResult> {
  return invoke<ArtworkResult>("fetch_artwork_cmd");
}

export interface ReplayGainResult {
  analyzed: number;
  failed: number;
  failures?: Array<{ track_id: number; error: string }>;
}

export async function analyzeReplayGain(): Promise<ReplayGainResult> {
  return invoke<ReplayGainResult>("analyze_replaygain_cmd");
}

// Phase 18 — full loudness analysis (LUFS-I, LRA, true peak, energy bucket)
// over every local track where `lufs_i IS NULL`.
export interface LoudnessAnalysisResult {
  analyzed: number;
  failed: number;
  failures?: Array<{ track_id: number; error: string }>;
}

export async function analyzeLoudnessAll(): Promise<LoudnessAnalysisResult> {
  return invoke<LoudnessAnalysisResult>("analyze_loudness_all");
}

export interface DeepScanResult {
  pairs_compared: number;
  duplicates_found: number;
  conflicts_flagged: number;
}

export async function deepScan(): Promise<DeepScanResult> {
  return invoke<DeepScanResult>("deep_scan_cmd");
}

export async function getReviewQueue(status?: string): Promise<ReviewQueueItem[]> {
  return invoke<ReviewQueueItem[]>("get_review_queue_cmd", { status });
}

export async function resolveReviewItem(reviewId: number, action: string): Promise<void> {
  return invoke<void>("resolve_review_item_cmd", { reviewId, action });
}

export async function getReviewQueueCount(): Promise<number> {
  return invoke<number>("get_review_queue_count_cmd");
}

// ============================================================================
// Source Connection Commands
// ============================================================================

export interface SyncResponse {
  added: number;
  source: string;
}

/** Generate Spotify OAuth authorization URL */
export async function spotify_auth_url(): Promise<string> {
  return invoke<string>("spotify_auth_url");
}

/** Exchange Spotify authorization code for tokens */
export async function spotify_exchange_code(code: string, userId: string): Promise<void> {
  return invoke<void>("spotify_exchange_code", { code, userId });
}

/** Sync liked songs from Spotify */
export async function sync_spotify(userId: string): Promise<SyncResponse> {
  return invoke<SyncResponse>("sync_spotify", { userId });
}

/** Generate SoundCloud OAuth authorization URL */
export async function soundcloud_auth_url(): Promise<string> {
  return invoke<string>("soundcloud_auth_url");
}

/** Exchange SoundCloud authorization code for tokens */
export async function soundcloud_exchange_code(code: string, userId: string): Promise<void> {
  return invoke<void>("soundcloud_exchange_code", { code, userId });
}

/** Sync liked tracks from SoundCloud */
export async function sync_soundcloud(userId: string): Promise<SyncResponse> {
  return invoke<SyncResponse>("sync_soundcloud", { userId });
}

/** Check if a source is connected (has stored refresh token) */
export async function check_source_connected(source: string): Promise<boolean> {
  return invoke<boolean>("check_source_connected", { source });
}

/** Disconnect a source by removing its stored refresh token */
export async function disconnect_source(source: string): Promise<void> {
  return invoke<void>("disconnect_source", { source });
}

/** Complete Spotify OAuth flow with local callback server */
export async function connect_spotify_with_server(): Promise<void> {
  return invoke<void>("connect_spotify_with_server");
}

/** Complete SoundCloud OAuth flow with local callback server */
export async function connect_soundcloud_with_server(): Promise<void> {
  return invoke<void>("connect_soundcloud_with_server");
}

// ============================================================================
// Apple Music Commands
// ============================================================================

/** Scrape Apple Music developer token from web player */
export async function apple_music_get_dev_token(): Promise<string> {
  return invoke<string>("apple_music_get_dev_token");
}

/** Store Apple Music user token after MusicKit JS authorization */
export async function apple_music_store_user_token(userToken: string, userId: string): Promise<void> {
  return invoke<void>("apple_music_store_user_token", { userToken, userId });
}

/** Check if Apple Music is connected and token is valid */
export async function apple_music_check_connected(userId: string): Promise<boolean> {
  return invoke<boolean>("apple_music_check_connected", { userId });
}

/** Sync library songs from Apple Music */
export async function sync_apple_music(userId: string): Promise<SyncResponse> {
  return invoke<SyncResponse>("sync_apple_music", { userId });
}

/** Disconnect Apple Music by removing stored user token */
export async function disconnect_apple_music(userId: string): Promise<void> {
  return invoke<void>("disconnect_apple_music", { userId });
}

// ============================================================================
// Library Configuration Commands
// ============================================================================

export interface LibraryConfig {
  root_path: string | null;
  scan_folders: string[];
  download_destination: string;
  library_id: string | null;
  configured: boolean;
}

/** Open native OS folder picker and return selected path */
export async function select_library_folder(): Promise<string | null> {
  return invoke<string | null>("select_library_folder");
}

/** List immediate subdirectories of a path */
export async function get_subfolders(rootPath: string): Promise<string[]> {
  return invoke<string[]>("get_subfolders", { rootPath });
}

/** Configure library with root path, scan folders, and download destination */
export async function configure_library(
  rootPath: string,
  scanFolders: string[],
  downloadDestination: string
): Promise<void> {
  return invoke<void>("configure_library", { rootPath, scanFolders, downloadDestination });
}

/** Get current library configuration */
export async function get_library_config(): Promise<LibraryConfig> {
  return invoke<LibraryConfig>("get_library_config");
}

/** Check if library drive is currently connected */
export async function check_library_connection(): Promise<boolean> {
  return invoke<boolean>("check_library_connection");
}

/** Get current mount state */
export async function get_library_mount_state(): Promise<string> {
  return invoke<string>("get_library_mount_state");
}

// ============================================================================
// App Settings Commands
// ============================================================================

/** Get an app setting by key */
export async function getAppSetting(key: string): Promise<string | null> {
  return invoke<string | null>("get_app_setting", { key });
}

/** Set an app setting */
export async function setAppSetting(key: string, value: string): Promise<void> {
  return invoke<void>("set_app_setting", { key, value });
}

// ============================================================================
// Track Analysis Commands (Plan 10-03 backend)
// ============================================================================

export interface TrackAnalysisData {
  ffprobe?: {
    format?: {
      filename?: string;
      format_name?: string;
      format_long_name?: string;
      duration?: string;
      size?: string;
      bit_rate?: string;
    };
    streams?: Array<{
      codec_name?: string;
      codec_long_name?: string;
      sample_rate?: string;
      channels?: number;
      bit_rate?: string;
      duration?: string;
    }>;
  };
  fingerprint?: string;
  waveform_path?: string;
  spectrogram_path?: string;
}

/** Get track analysis data (ffprobe, fingerprint, waveform, spectrogram) */
export async function getTrackAnalysis(trackId: number): Promise<TrackAnalysisData> {
  const raw = await invoke<{ ffprobe_output?: string; fingerprint?: string; spectrogram_path?: string }>("get_track_analysis", { trackId });
  return {
    ffprobe: raw.ffprobe_output ? JSON.parse(raw.ffprobe_output) : undefined,
    fingerprint: raw.fingerprint ?? undefined,
    spectrogram_path: raw.spectrogram_path ?? undefined,
  };
}

/** Get album artwork for a track as base64 data URI */
export async function getTrackArtwork(trackId: number): Promise<string | null> {
  return invoke<string | null>("get_track_artwork", { trackId });
}

/** Generate fingerprint for a single track */
export async function generateTrackFingerprint(trackId: number): Promise<string> {
  return invoke<string>("generate_track_fingerprint", { trackId });
}

/** Generate waveform visualization for a track (returns base64 PNG data URI) */
export async function generateTrackWaveform(trackId: number): Promise<string> {
  return invoke<string>("generate_track_waveform", { trackId });
}

/** Generate spectrogram for a track (returns base64 PNG data URI) */
export async function generateTrackSpectrogram(trackId: number): Promise<string> {
  return invoke<string>("generate_track_spectrogram", { trackId });
}

// Source likes playlist sync
export interface SyncLikesPlaylistResult {
  playlist_id: number;
  added: number;
  total: number;
}

export async function syncSourceLikesPlaylist(sourceName: string): Promise<SyncLikesPlaylistResult> {
  return invoke<SyncLikesPlaylistResult>("sync_source_likes_playlist", { sourceName });
}

// Playlist import
export interface ImportPlaylistResult {
  playlist_id: number;
  playlist_name: string;
  total_tracks: number;
  matched_tracks: number;
  unmatched_tracks: number;
  unmatched_details: string[];
}

/**
 * Import a playlist from an M3U, M3U8, or Spotify JSON file.
 * Fuzzy-matches tracks against library, creates playlist with matched tracks.
 */
export async function importPlaylistFromFile(
  playlistName: string,
  filePath: string
): Promise<ImportPlaylistResult> {
  return invoke<ImportPlaylistResult>("import_playlist_command", {
    playlistName,
    filePath,
  });
}
