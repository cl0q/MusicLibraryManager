import { useState, useEffect } from "react";
import { Menu, Item, Separator, Submenu, useContextMenu } from "react-contexify";
import "react-contexify/ReactContexify.css";
import { toast } from "sonner";
import { invoke } from "@tauri-apps/api/core";
import type { Track } from "../../types/library";
import { useTrackSelection } from "../../contexts/TrackSelectionContext";
import { DownloadProgress } from "../Downloads/DownloadProgress";

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
  const [isDownloading, setIsDownloading] = useState(false);

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

  // Determine which tracks to operate on (selected or single)
  const getTargetTracks = (): Track[] => {
    if (selectedTracks.length > 0) {
      return selectedTracks;
    }
    if (!track) return [];
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
    if (!track) return;
    const localPath = track.organized_path;
    if (!localPath) {
      toast.error("Track has no local file");
      return;
    }

    try {
      await invoke("reveal_in_file_manager", {
        path: localPath,
        fallbackPath: track.metadata.original_path,
      });
    } catch (error) {
      toast.error(`Failed to open file manager: ${error}`);
    }
  };

  const handleCopyFilePath = async () => {
    if (!track) return;
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
    if (onOpenMoreInfo && track) {
      onOpenMoreInfo(track);
    }
  };

  const handleDownloadTracks = async () => {
    const targetTracks = getTargetTracks();

    // Get library config for download destination
    // First fetch config since context doesn't expose it
    let config;
    try {
      config = await invoke<{
        root_path: string | null;
        scan_folders: string[];
        download_destination: string;
        library_id: string | null;
        configured: boolean;
      }>("get_library_config");
    } catch (error) {
      toast.error(`Failed to get library config: ${error}`);
      return;
    }

    if (!config.download_destination || !config.root_path) {
      toast.error("Download destination or library root not configured");
      return;
    }

    // Map tracks to DownloadRequest format
    // track_id from Track.id, soundcloud_url from original_path when format is "soundcloud"
    const requests = targetTracks.map((t) => ({
      track_id: t.id?.toString() ?? undefined,
      query: `${t.metadata.artist} ${t.metadata.title}`,
      artist: t.metadata.artist,
      title: t.metadata.title,
      soundcloud_url:
        t.metadata.format === "soundcloud"
          ? t.metadata.original_path
          : undefined,
      user_id: "default",
    }));

    try {
      // Start download progress UI
      setIsDownloading(true);

      // Build staging paths under hidden .mlm_staging/ directory
      const downloadDir = `${config.root_path}/.mlm_staging/downloads`;
      const transcodeDir = `${config.root_path}/.mlm_staging/transcoded`;
      const rootDir = config.root_path;

      const result = await invoke<{
        succeeded: number;
        failed: number;
        skipped: number;
      }>("download_tracks", {
        requests,
        downloadDir,
        transcodeDir,
        rootDir,
      });

      // Stop download progress UI
      setIsDownloading(false);

      // Show success toast
      const totalRequests = requests.length;
      toast.success(`Downloaded ${result.succeeded}/${totalRequests} tracks`);

      // Show error toast if any failed
      if (result.failed > 0) {
        toast.error(`${result.failed} tracks failed. Check Downloads page.`);
      }
    } catch (error) {
      setIsDownloading(false);
      toast.error(`Download failed: ${error}`);
    }
  };

  // Track is local if it has organized_path
  const isLocalTrack = track ? track.organized_path !== null : false;
  const isRemoteTrack = track ? track.organized_path === null : false;

  return (
    <>
      <Menu id={MENU_ID}>
        {isRemoteTrack && (
          <>
            <Item onClick={handleDownloadTracks}>Download</Item>
            <Separator />
          </>
        )}

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

    <DownloadProgress isDownloading={isDownloading} />
    </>
  );
}
