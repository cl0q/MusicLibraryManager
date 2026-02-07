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

export default function RowContextMenu({ track, onOpenMoreInfo }: RowContextMenuProps) {
  const navigate = useNavigate();

  if (!track) return null;

  const handleViewDetails = () => {
    navigate(`/library/${track.id}`);
  };

  const handleAddToPlaylist = () => {
    toast.info("Select playlist from Playlists page");
  };

  const handleDownload = async () => {
    try {
      await invoke("download_tracks", {
        request: { track_ids: [track.id] },
      });
      toast.success("Download started");
    } catch (error) {
      toast.error(`Download failed: ${error}`);
    }
  };

  const handleSyncToDevice = () => {
    toast.info("Select device from Sync page");
  };

  const handleAddToLibrary = async () => {
    try {
      // Fetch sync profiles and add track to first available profile
      const profiles = await invoke<SyncProfile[]>("list_sync_profiles");

      if (profiles.length === 0) {
        toast.info("Create a sync profile from Sync page first");
        return;
      }

      // Add to first profile
      await invoke("add_track_to_profile", {
        profileId: profiles[0].id,
        trackId: track.id,
      });
      toast.success(`Added to ${profiles[0].name}`);
    } catch (error) {
      toast.error(`Failed to add track: ${error}`);
    }
  };

  const localPath = track.organized_path || track.metadata.original_path;

  const handleRevealInFileManager = async () => {
    if (!localPath) {
      toast.error("Track has no local file");
      return;
    }

    try {
      // Use the opener plugin to reveal file
      await invoke("reveal_in_file_manager", {
        path: localPath,
      });
    } catch (error) {
      toast.error(`Failed to open file manager: ${error}`);
    }
  };

  const handleMoreInfo = () => {
    if (onOpenMoreInfo) {
      onOpenMoreInfo(track);
    }
  };

  return (
    <Menu id={MENU_ID}>
      <Item onClick={handleViewDetails}>View Details</Item>
      <Separator />
      <Item onClick={handleAddToPlaylist}>Add to Playlist</Item>
      <Item onClick={handleDownload}>Download</Item>
      <Item onClick={handleSyncToDevice}>Sync to Device</Item>
      <Item onClick={handleAddToLibrary}>Add to Library</Item>
      <Separator />
      <Item onClick={handleRevealInFileManager} disabled={!localPath}>
        Reveal in File Manager
      </Item>
      <Item onClick={handleMoreInfo}>More Info</Item>
    </Menu>
  );
}
