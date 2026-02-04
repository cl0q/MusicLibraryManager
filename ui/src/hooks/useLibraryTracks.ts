import { useState, useEffect, useMemo } from "react";
import { search_library } from "../utils/tauri-commands";
import type { Track } from "../types/library";

/**
 * Hook to fetch and filter library tracks
 * @returns Object containing filtered tracks, loading state, and filter controls
 */
export function useLibraryTracks() {
  const [allTracks, setAllTracks] = useState<Track[]>([]);
  const [loading, setLoading] = useState(true);
  const [filterQuery, setFilterQuery] = useState("");

  // Fetch all tracks on mount
  useEffect(() => {
    async function fetchTracks() {
      try {
        setLoading(true);
        // Empty query returns all tracks
        const tracks = await search_library("");
        setAllTracks(tracks);
      } catch (error) {
        console.error("Failed to fetch library tracks:", error);
        setAllTracks([]);
      } finally {
        setLoading(false);
      }
    }

    fetchTracks();
  }, []);

  // Client-side filtering based on filterQuery
  const filteredTracks = useMemo(() => {
    if (!filterQuery.trim()) {
      return allTracks;
    }

    const query = filterQuery.toLowerCase();
    return allTracks.filter(
      (track) =>
        track.title.toLowerCase().includes(query) ||
        track.artist.toLowerCase().includes(query) ||
        track.album.toLowerCase().includes(query) ||
        track.album_artist.toLowerCase().includes(query)
    );
  }, [allTracks, filterQuery]);

  return {
    tracks: filteredTracks,
    loading,
    filterQuery,
    setFilterQuery,
  };
}
