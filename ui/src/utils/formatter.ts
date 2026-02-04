// Utility functions for formatting data in the UI

/**
 * Format duration in seconds to M:SS format
 * @param seconds Duration in seconds
 * @returns Formatted string like "3:45"
 */
export function formatDuration(seconds: number): string {
  if (!seconds || seconds < 0) return "0:00";

  const minutes = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${minutes}:${secs.toString().padStart(2, "0")}`;
}

/**
 * Format bytes to human-readable size
 * @param bytes File size in bytes
 * @returns Formatted string like "3.5 MB"
 */
export function formatBytes(bytes: number): string {
  if (!bytes || bytes === 0) return "0 B";

  const units = ["B", "KB", "MB", "GB", "TB"];
  const k = 1024;
  const i = Math.floor(Math.log(bytes) / Math.log(k));

  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${units[i]}`;
}

/**
 * Format Unix timestamp to locale date string
 * @param timestamp Unix timestamp (seconds since epoch)
 * @returns Formatted date string like "Jan 15, 2026"
 */
export function formatDate(timestamp: number): string {
  if (!timestamp || timestamp < 0) return "Unknown";

  const date = new Date(timestamp * 1000);
  return date.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

/**
 * Format quality string for display
 * @param quality Quality descriptor like "320kbps MP3" or "FLAC"
 * @returns Cleaned quality string
 */
export function formatQuality(quality: string): string {
  if (!quality) return "Unknown";

  // Clean up common patterns
  return quality
    .replace(/kbps/gi, " kbps")
    .replace(/\s+/g, " ")
    .trim();
}
