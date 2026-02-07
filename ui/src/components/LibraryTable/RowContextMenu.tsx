import { useState, useEffect } from "react";
import { Menu, Item, Separator, Submenu, useContextMenu } from "react-contexify";
import "react-contexify/ReactContexify.css";
import { toast } from "sonner";
import { invoke } from "@tauri-apps/api/core";
import type { Track } from "../../types/library";
import { useTrackSelection } from "../../contexts/TrackSelectionContext";

interface Playlist {
  id: number;
  name: string;
  description: string | null;
  category: string;
  is_liked: boolean;
  is_smart: boolean;
  is_pinned: boolean;
  cover_image_path: string | null;
  cover_image_url: string | null;
  source_id: string | null;
  external_id: string | null;
  date_created: string;
}

interface SyncProfile {
  id: number;
  name: string;
  target_folder: string;
  manual_track_count: number;
  playlist_count: number;
  rule_count: number;
  total_track_count: number;
  created_at: string;
  updated_at: string;
}

interface RowContextMenuProps {
  track: Track | null;
  onConfirm: (trackIds: number[]) => void;
  onOpenMoreInfo?: (track: Track) => void;
}

const MENU_ID = "library-row-menu";

export function useRowContextMenu() {
  const { show } = useContextMenu({ id: MENU_ID });

  const displayMenu = (event: React.MouseEvent, track: Track) => {
    show({
      event,
      props: { track },
    });
  };

  return { displayMenu };
}

export default function RowContextMenu({ track, onConfirm, onOpenMoreInfo }: RowContextMenuProps) {
  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [syncProfiles, setSyncProfiles] = useState<SyncProfile[]>([]);
  const { selectedTracks } = useTrackSelection();

  // Load playlists and sync profiles
  useEffect(() => {
    const loadData = async () => {
      try {
        const playlistsData = await invoke<Playlist[]>("get_playlists_command");
        setPlaylists(playlistsData);
      } catch (error) {
        console.error("Failed to load playlists:", error);
      }

      try {
        const profilesData = await invoke<SyncProfile[]>("list_sync_profiles");
        setSyncProfiles(profilesData);
      } catch (error) {
        console.error("Failed to load sync profiles:", error);
      }
    };

    loadData();
  }, []);

  if (!track) return null;

  // Determine which tracks to operate on (selected or single)
  const getTargetTracks = (): Track[] => {
    if (selectedTracks.length > 0) {
      return selectedTracks;
    }
    return [track];
  };

  const handleAddToPlaylist = async (playlistId: number) => {
    const targetTracks = getTargetTracks();
    const trackIds = targetTracks.map((t) => t.id).filter((id): id is number => id !== null);

    try {
      await Promise.all(
        trackIds.map((trackId) =>
          invoke("add_track_to_playlist_command", {
            playlistId,
            trackId,
          })
        )
      );

      // Show inline confirmation
      onConfirm(trackIds);
    } catch (error) {
      toast.error(`Failed to add track(s) to playlist: ${error}`);
    }
  };

  const handleAddToSyncProfile = async (profileId: number) => {
    const targetTracks = getTargetTracks();
    const trackIds = targetTracks.map((t) => t.id).filter((id): id is number => id !== null);

    try {
      await Promise.all(
        trackIds.map((trackId) =>
          invoke("add_track_to_profile", {
            profileId,
            trackId,
          })
        )
      );

      // Show inline confirmation
      onConfirm(trackIds);
    } catch (error) {
      toast.error(`Failed to add track(s) to sync profile: ${error}`);
    }
  };

  const handleRevealInFileManager = async () => {
    const localPath = track.organized_path;
    if (!localPath) {
      toast.error("Track has no local file");
      return;
    }

    try {
      await invoke("reveal_in_file_manager", {
        path: localPath,
      });
    } catch (error) {
      toast.error(`Failed to open file manager: ${error}`);
    }
  };

  const handleCopyFilePath = async () => {
    const localPath = track.organized_path;
    if (!localPath) {
      toast.error("Track has no local file");
      return;
    }

    try {
      await navigator.clipboard.writeText(localPath);
      toast.success("File path copied to clipboard");
    } catch (error) {
      toast.error(`Failed to copy path: ${error}`);
    }
  };

  const handleMoreInfo = () => {
    if (onOpenMoreInfo) {
      onOpenMoreInfo(track);
    }
  };

  // Track is local if it has organized_path
  const isLocalTrack = track.organized_path !== null;

  return (
    <Menu id={MENU_ID}>
      <Submenu label="Add to Playlist">
        {playlists.length === 0 ? (
          <Item disabled>No playlists available</Item>
        ) : (
          playlists.map((playlist) => (
            <Item key={playlist.id} onClick={() => handleAddToPlaylist(playlist.id)}>
              {playlist.name}
            </Item>
          ))
        )}
      </Submenu>

      <Submenu label="Add to Sync Profile">
        {syncProfiles.length === 0 ? (
          <Item disabled>No sync profiles available</Item>
        ) : (
          syncProfiles.map((profile) => (
            <Item key={profile.id} onClick={() => handleAddToSyncProfile(profile.id)}>
              {profile.name}
            </Item>
          ))
        )}
      </Submenu>

      {isLocalTrack && (
        <>
          <Separator />
          <Item onClick={handleRevealInFileManager}>Reveal in File Manager</Item>
          <Item onClick={handleCopyFilePath}>Copy File Path</Item>
        </>
      )}

      <Separator />
      <Item onClick={handleMoreInfo}>More Info</Item>
    </Menu>
  );
}
