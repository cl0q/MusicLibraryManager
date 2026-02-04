import { useNavigate } from "react-router";
import PlaylistList from "../components/Playlists/PlaylistList";

export default function Playlists() {
  const navigate = useNavigate();

  return (
    <PlaylistList
      onSelectPlaylist={(playlist) => {
        navigate(`/playlists/${playlist.id}`);
      }}
    />
  );
}
