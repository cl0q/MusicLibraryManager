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
        navigate("/");
        return;
      }

      try {
        const tracks = await search_library(trackId);
        const foundTrack = tracks.find((t) => t.id === Number(trackId));

        if (!foundTrack) {
          toast.error("Track not found");
          navigate("/");
          return;
        }

        setTrack(foundTrack);
      } catch (error) {
        toast.error(`Failed to load track: ${error}`);
        navigate("/");
      } finally {
        setLoading(false);
      }
    };

    loadTrack();
  }, [trackId, navigate]);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <span className="text-sm text-ink-muted">Loading...</span>
      </div>
    );
  }

  if (!track) {
    return (
      <div className="flex items-center justify-center h-full">
        <span className="text-sm text-ink-muted">Track not found</span>
      </div>
    );
  }

  return (
    <div className="p-4 space-y-4">
      <button
        onClick={() => navigate("/")}
        className="text-xs text-accent hover:text-accent-bright font-medium transition-colors"
      >
        ← Back to Library
      </button>

      <div>
        <h1 className="text-lg font-semibold text-ink">{track.metadata.title}</h1>
        <p className="text-sm text-ink-secondary">{track.metadata.artist}</p>
      </div>

      <MetadataPanel track={track} />

      {track.metadata.original_path && (
        <WaveformView audioUrl={track.metadata.original_path} />
      )}

      {!track.metadata.original_path && (
        <div className="bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2">
          <p className="text-xs text-amber-400">
            Track not downloaded. Waveform is only available for local files.
          </p>
        </div>
      )}
    </div>
  );
}
