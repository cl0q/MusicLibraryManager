import { useState, useEffect, useMemo } from "react";
import { get_library_tracks } from "../utils/tauri-commands";
import type { Track } from "../types/library";

/**
 * Hook to fetch and filter library tracks
 * @param refreshKey Optional key to trigger re-fetch when changed
 * @returns Object containing filtered tracks, loading state, and filter controls
 */
export function useLibraryTracks(refreshKey?: number) {
  const [allTracks, setAllTracks] = useState<Track[]>([]);
  const [loading, setLoading] = useState(true);
  const [filterQuery, setFilterQuery] = useState("");

  // Fetch all tracks on mount and when refreshKey changes
  useEffect(() => {
    async function fetchTracks() {
      try {
        setLoading(true);
        const tracks = await get_library_tracks();
        setAllTracks(tracks);
      } catch (error) {
        console.error("Failed to fetch library tracks:", error);
        setAllTracks([]);
      } finally {
        setLoading(false);
      }
    }

    fetchTracks();
  }, [refreshKey]);

  // Client-side filtering based on filterQuery
  const filteredTracks = useMemo(() => {
    if (!filterQuery.trim()) {
      return allTracks;
    }

    const query = filterQuery.toLowerCase();
    return allTracks.filter(
      (track) =>
        track.metadata.title.toLowerCase().includes(query) ||
        track.metadata.artist.toLowerCase().includes(query) ||
        track.metadata.album.toLowerCase().includes(query) ||
        track.metadata.album_artist.toLowerCase().includes(query)
    );
  }, [allTracks, filterQuery]);

  return {
    tracks: filteredTracks,
    loading,
    filterQuery,
    setFilterQuery,
  };
}
