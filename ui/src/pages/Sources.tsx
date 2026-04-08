import { useEffect, useState, useCallback } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { listen } from "@tauri-apps/api/event";
import SourceCard, { type SourceStatus } from "../components/Sources/SourceCard";
import {
  connect_spotify_with_server,
  connect_soundcloud_with_server,
  sync_spotify,
  sync_soundcloud,
  check_source_connected,
  disconnect_source,
  import_directory,
  get_library_config,
  syncSourceLikesPlaylist,
} from "../utils/tauri-commands";

interface SourceState {
  status: SourceStatus;
  trackCount?: number;
  lastSyncTime?: string;
  errorMessage?: string;
}

function SpotifyIcon() {
  return (
    <svg className="w-5 h-5 text-emerald-400" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z" />
    </svg>
  );
}

function SoundCloudIcon() {
  return (
    <svg className="w-5 h-5 text-orange-400" viewBox="0 0 24 24" fill="currentColor">
      <path d="M1.175 12.225c-.051 0-.094.046-.101.1l-.233 2.154.233 2.105c.007.058.05.098.101.098.05 0 .09-.04.099-.098l.255-2.105-.27-2.154c-.009-.06-.052-.1-.084-.1zm-.899 1.665c-.057 0-.1.039-.109.1l-.135 1.29.135 1.235c.009.055.052.092.109.092.058 0 .096-.037.109-.092l.154-1.235-.154-1.29c-.01-.061-.054-.1-.109-.1zm1.786-1.385c-.064 0-.113.043-.117.1l-.212 2.545.212 2.435c.004.057.053.1.117.1.064 0 .112-.043.117-.1l.234-2.435-.234-2.545c-.005-.057-.053-.1-.117-.1zm.909-.26c-.067 0-.122.05-.127.111l-.2 2.694.2 2.615c.005.057.06.109.127.109.065 0 .117-.052.122-.109l.227-2.615-.227-2.694c-.005-.061-.057-.111-.122-.111zm.963-.089c-.072 0-.131.053-.135.118l-.182 2.894.182 2.782c.004.063.063.116.135.116.07 0 .126-.053.131-.116l.204-2.782-.204-2.894c-.005-.065-.061-.118-.131-.118zm.974-.107c-.079 0-.142.06-.148.13l-.167 3.104.167 2.947c.006.068.069.122.148.122.077 0 .137-.054.143-.122l.187-2.947-.187-3.104c-.006-.07-.066-.13-.143-.13zm1.004-.134c-.084 0-.15.064-.156.14l-.152 3.351.152 3.093c.006.073.072.126.156.126.082 0 .145-.053.151-.126l.171-3.093-.171-3.351c-.006-.076-.069-.14-.151-.14zm.979-.032c-.089 0-.162.068-.168.15l-.137 3.383.137 3.226c.006.078.079.135.168.135.087 0 .157-.057.163-.135l.152-3.226-.152-3.383c-.006-.082-.076-.15-.163-.15zm1.968.383c-.093 0-.172.072-.178.162l-.116 2.87.116 3.338c.006.086.085.146.178.146.091 0 .167-.06.173-.146l.128-3.338-.128-2.87c-.006-.09-.082-.162-.173-.162zm-.949-.395c-.096 0-.174.075-.181.168l-.12 3.265.12 3.395c.007.089.085.152.181.152.094 0 .17-.063.176-.152l.133-3.395-.133-3.265c-.006-.093-.082-.168-.176-.168zm1.93.023c-.098 0-.181.079-.186.177l-.107 3.625.107 3.485c.005.093.088.16.186.16.096 0 .176-.067.182-.16l.118-3.485-.118-3.625c-.006-.098-.086-.177-.182-.177zm.97-.091c-.104 0-.188.083-.193.187l-.093 3.716.093 3.545c.005.098.089.17.193.17.101 0 .183-.072.188-.17l.104-3.545-.104-3.716c-.005-.104-.087-.187-.188-.187zm1.966.296c-.108 0-.195.086-.2.195l-.076 3.329.076 3.594c.005.103.092.18.2.18.106 0 .19-.077.195-.18l.085-3.594-.085-3.329c-.005-.109-.089-.195-.195-.195zm-.95-.219c-.108 0-.197.088-.202.199l-.081 3.548.081 3.606c.005.104.094.183.202.183.106 0 .193-.079.198-.183l.09-3.606-.09-3.548c-.005-.111-.092-.199-.198-.199zm3.763.095c-.023-.003-.047-.003-.07-.003-.233 0-.448.07-.626.19-.078-.82-.735-1.46-1.545-1.46-.196 0-.384.04-.553.107-.078.03-.099.063-.1.124v7.1c.001.06.044.112.104.123.007.001.015.001.022.001h2.768c.962 0 1.742-.79 1.742-1.767 0-.976-.78-1.767-1.742-1.767z" />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg className="w-5 h-5 text-sky-400" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z" />
    </svg>
  );
}

export default function Sources() {
  const navigate = useNavigate();
  const [spotify, setSpotify] = useState<SourceState>({ status: "disconnected" });
  const [soundcloud, setSoundcloud] = useState<SourceState>({ status: "disconnected" });
  const [localLibrary, setLocalLibrary] = useState<SourceState>({ status: "disconnected" });
  const [isConnecting, setIsConnecting] = useState<string | null>(null);
  const [likesSync, setLikesSync] = useState<string | null>(null);

  const checkConnections = useCallback(async () => {
    try {
      const [spotifyConnected, soundcloudConnected, libraryConfig] = await Promise.all([
        check_source_connected("spotify"),
        check_source_connected("soundcloud"),
        get_library_config(),
      ]);
      setSpotify((prev) => ({ ...prev, status: spotifyConnected ? "connected" : "disconnected" }));
      setSoundcloud((prev) => ({ ...prev, status: soundcloudConnected ? "connected" : "disconnected" }));
      setLocalLibrary({ status: libraryConfig.configured ? "connected" : "disconnected" });
    } catch (err) {
      console.error("Failed to check connections:", err);
    }
  }, []);

  useEffect(() => {
    checkConnections();
    const unlisten = listen("oauth-complete", () => checkConnections());
    return () => { unlisten.then((fn) => fn()); };
  }, [checkConnections]);

  const handleConnectSpotify = useCallback(async () => {
    setIsConnecting("spotify");
    try {
      toast.info("Opening Spotify authorization...");
      await connect_spotify_with_server();
      toast.success("Spotify connected!");
      setSpotify((prev) => ({ ...prev, status: "connected" }));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`Spotify connection failed: ${message}`);
    } finally {
      setIsConnecting(null);
    }
  }, []);

  const handleDisconnectSpotify = useCallback(async () => {
    try {
      await disconnect_source("spotify");
      setSpotify({ status: "disconnected" });
      toast.success("Spotify disconnected");
    } catch (err) {
      toast.error(`Failed to disconnect: ${err instanceof Error ? err.message : String(err)}`);
    }
  }, []);

  const handleSyncSpotify = useCallback(async () => {
    setSpotify((prev) => ({ ...prev, status: "syncing" }));
    try {
      const result = await sync_spotify("default");
      setSpotify((prev) => ({
        ...prev,
        status: "connected",
        trackCount: (prev.trackCount || 0) + result.added,
        lastSyncTime: new Date().toISOString(),
      }));
      toast.success(`Spotify: ${result.added} new tracks`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setSpotify((prev) => ({ ...prev, status: "error", errorMessage: message }));
      toast.error(`Spotify sync failed: ${message}`);
    }
  }, []);

  const handleConnectSoundCloud = useCallback(async () => {
    setIsConnecting("soundcloud");
    try {
      toast.info("Opening SoundCloud authorization...");
      await connect_soundcloud_with_server();
      toast.success("SoundCloud connected!");
      setSoundcloud((prev) => ({ ...prev, status: "connected" }));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`SoundCloud connection failed: ${message}`);
    } finally {
      setIsConnecting(null);
    }
  }, []);

  const handleDisconnectSoundCloud = useCallback(async () => {
    try {
      await disconnect_source("soundcloud");
      setSoundcloud({ status: "disconnected" });
      toast.success("SoundCloud disconnected");
    } catch (err) {
      toast.error(`Failed to disconnect: ${err instanceof Error ? err.message : String(err)}`);
    }
  }, []);

  const handleSyncSoundCloud = useCallback(async () => {
    setSoundcloud((prev) => ({ ...prev, status: "syncing" }));
    try {
      const result = await sync_soundcloud("default");
      setSoundcloud((prev) => ({
        ...prev,
        status: "connected",
        trackCount: (prev.trackCount || 0) + result.added,
        lastSyncTime: new Date().toISOString(),
      }));
      toast.success(`SoundCloud: ${result.added} new tracks`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setSoundcloud((prev) => ({ ...prev, status: "error", errorMessage: message }));
      toast.error(`SoundCloud sync failed: ${message}`);
    }
  }, []);

  const handleSyncLikesPlaylist = useCallback(async (source: string) => {
    setLikesSync(source);
    try {
      const result = await syncSourceLikesPlaylist(source);
      if (result.added === 0) {
        toast.success(`${source === "soundcloud" ? "SoundCloud" : "Spotify"} Likes playlist is up to date (${result.total} tracks)`);
      } else {
        toast.success(`Added ${result.added} tracks to likes playlist (${result.total} total)`);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`Failed to sync likes playlist: ${message}`);
    }
    setLikesSync(null);
  }, []);

  useEffect(() => {
    const unlisten = listen<{
      succeeded: number;
      failed: number;
      skipped: number;
      total: number;
      failure_summary: string[];
    }>("import-complete", (event) => {
      const { succeeded, failed, skipped, total } = event.payload;
      setLocalLibrary((prev) => ({
        ...prev,
        status: "connected",
        trackCount: (prev.trackCount || 0) + succeeded,
        lastSyncTime: new Date().toISOString(),
      }));
      if (succeeded > 0 || failed > 0) {
        toast.success(`Import: ${succeeded} new, ${skipped} skipped, ${failed} failed (${total} total)`);
      } else {
        toast.info("No new tracks to import");
      }
    });
    return () => { unlisten.then((fn) => fn()); };
  }, []);

  const handleImportFolder = useCallback(async () => {
    try {
      const config = await get_library_config();
      if (!config.configured || !config.root_path) {
        toast.error("Library not configured. Set it up in Settings.");
        navigate("/settings");
        return;
      }
      setLocalLibrary((prev) => ({ ...prev, status: "syncing" }));
      const result = await import_directory(config.root_path);
      toast.info(`Scanning ${result.file_count.toLocaleString()} files...`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setLocalLibrary((prev) => ({ ...prev, status: "error", errorMessage: message }));
      toast.error(`Import failed: ${message}`);
    }
  }, [navigate]);

  return (
    <div className="p-4 space-y-4 max-w-2xl">
      <h1 className="text-xs font-semibold uppercase tracking-wide text-ink-secondary">Sources</h1>

      <div className="space-y-3">
        <SourceCard
          name="Spotify"
          icon={<SpotifyIcon />}
          status={spotify.status}
          description="Sync liked songs and playlists from Spotify."
          trackCount={spotify.trackCount}
          lastSyncTime={spotify.lastSyncTime}
          errorMessage={spotify.errorMessage}
          onConnect={handleConnectSpotify}
          onDisconnect={handleDisconnectSpotify}
          onSync={handleSyncSpotify}
          isConnecting={isConnecting === "spotify"}
          extraActions={
            <button
              onClick={() => handleSyncLikesPlaylist("spotify")}
              disabled={likesSync !== null}
              className="text-[11px] text-ink-muted hover:text-ink transition-colors disabled:opacity-40"
            >
              {likesSync === "spotify" ? "Syncing playlist..." : "Update Likes Playlist"}
            </button>
          }
        />

        <SourceCard
          name="SoundCloud"
          icon={<SoundCloudIcon />}
          status={soundcloud.status}
          description="Sync liked tracks from SoundCloud."
          trackCount={soundcloud.trackCount}
          lastSyncTime={soundcloud.lastSyncTime}
          errorMessage={soundcloud.errorMessage}
          onConnect={handleConnectSoundCloud}
          onDisconnect={handleDisconnectSoundCloud}
          onSync={handleSyncSoundCloud}
          isConnecting={isConnecting === "soundcloud"}
          extraActions={
            <button
              onClick={() => handleSyncLikesPlaylist("soundcloud")}
              disabled={likesSync !== null}
              className="text-[11px] text-ink-muted hover:text-ink transition-colors disabled:opacity-40"
            >
              {likesSync === "soundcloud" ? "Syncing playlist..." : "Update Likes Playlist"}
            </button>
          }
        />

        <SourceCard
          name="Local Library"
          icon={<FolderIcon />}
          status={localLibrary.status}
          description="Import music from your configured library folder."
          trackCount={localLibrary.trackCount}
          lastSyncTime={localLibrary.lastSyncTime}
          errorMessage={localLibrary.errorMessage}
          onConnect={() => navigate("/settings")}
          onSync={handleImportFolder}
          connectLabel="Configure in Settings"
        />
      </div>
    </div>
  );
}
