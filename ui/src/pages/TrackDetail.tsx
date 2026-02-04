import { useEffect, useState } from "react";
import { useParams, useNavigate } from "react-router";
import { search_library } from "../utils/tauri-commands";
import type { Track } from "../types/library";
import MetadataPanel from "../components/TrackDetail/MetadataPanel";
import WaveformView from "../components/TrackDetail/WaveformView";
import { toast } from "sonner";

export default function TrackDetail() {
  const { trackId } = useParams<{ trackId: string }>();
  const navigate = useNavigate();
  const [track, setTrack] = useState<Track | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const loadTrack = async () => {
      if (!trackId) {
        toast.error("No track ID provided");
        navigate("/library");
        return;
      }

      try {
        // Search for track by ID using search_library
        const tracks = await search_library(trackId);
        const foundTrack = tracks.find((t) => t.id === trackId);

        if (!foundTrack) {
          toast.error("Track not found");
          navigate("/library");
          return;
        }

        setTrack(foundTrack);
      } catch (error) {
        toast.error(`Failed to load track: ${error}`);
        navigate("/library");
      } finally {
        setLoading(false);
      }
    };

    loadTrack();
  }, [trackId, navigate]);

  if (loading) {
    return (
      <div className="p-6">
        <p className="text-gray-600 dark:text-gray-400">Loading track...</p>
      </div>
    );
  }

  if (!track) {
    return (
      <div className="p-6">
        <p className="text-gray-600 dark:text-gray-400">Track not found</p>
      </div>
    );
  }

  return (
    <div className="p-6">
      <div className="mb-6">
        <button
          onClick={() => navigate("/library")}
          className="text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300 font-medium"
        >
          ← Back to Library
        </button>
      </div>

      <h1 className="text-3xl font-bold mb-6 text-gray-900 dark:text-white">
        {track.title}
      </h1>

      <div className="space-y-6">
        <MetadataPanel track={track} />
        {track.local_path && <WaveformView audioUrl={track.local_path} />}
        {!track.local_path && (
          <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-4">
            <p className="text-yellow-800 dark:text-yellow-200">
              This track has not been downloaded yet. Waveform visualization is
              only available for downloaded tracks.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
