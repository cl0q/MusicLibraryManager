import { useParams, useNavigate } from "react-router";
import { useState, useEffect } from "react";
import PlaylistDetail from "../components/Playlists/PlaylistDetail";
import { getPlaylists, type Playlist } from "../hooks/usePlaylists";
import { toast } from "sonner";

export default function PlaylistDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [playlist, setPlaylist] = useState<Playlist | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const loadPlaylist = async () => {
      if (!id) {
        toast.error("No playlist ID provided");
        navigate("/playlists");
        return;
      }

      try {
        const playlists = await getPlaylists();
        const foundPlaylist = playlists.find((p) => p.id === Number(id));

        if (!foundPlaylist) {
          toast.error("Playlist not found");
          navigate("/playlists");
          return;
        }

        setPlaylist(foundPlaylist);
      } catch (error) {
        toast.error(`Failed to load playlist: ${error}`);
        navigate("/playlists");
      } finally {
        setLoading(false);
      }
    };

    loadPlaylist();
  }, [id, navigate]);

  if (loading) {
    return (
      <div className="p-6">
        <p className="text-ink-muted">Loading playlist...</p>
      </div>
    );
  }

  if (!playlist) {
    return (
      <div className="p-6">
        <p className="text-ink-muted">Playlist not found</p>
      </div>
    );
  }

  return (
    <PlaylistDetail
      playlist={playlist}
      onBack={() => navigate("/playlists")}
    />
  );
}
