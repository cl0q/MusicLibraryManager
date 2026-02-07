/**
 * Sources page - manage connections to music sources.
 *
 * Displays cards for:
 * - Spotify (OAuth connection)
 * - SoundCloud (OAuth connection)
 * - Local Library (folder import)
 *
 * Each card shows connection status and provides connect/disconnect/sync actions.
 */

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
} from "../utils/tauri-commands";

interface SourceState {
  status: SourceStatus;
  trackCount?: number;
  lastSyncTime?: string;
  errorMessage?: string;
}

// Icons for each source
function SpotifyIcon() {
  return (
    <svg className="w-6 h-6 text-green-500" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z" />
    </svg>
  );
}

function SoundCloudIcon() {
  return (
    <svg className="w-6 h-6 text-orange-500" viewBox="0 0 24 24" fill="currentColor">
      <path d="M1.175 12.225c-.051 0-.094.046-.101.1l-.233 2.154.233 2.105c.007.058.05.098.101.098.05 0 .09-.04.099-.098l.255-2.105-.27-2.154c-.009-.06-.052-.1-.084-.1zm-.899 1.665c-.057 0-.1.039-.109.1l-.135 1.29.135 1.235c.009.055.052.092.109.092.058 0 .096-.037.109-.092l.154-1.235-.154-1.29c-.01-.061-.054-.1-.109-.1zm1.786-1.385c-.064 0-.113.043-.117.1l-.212 2.545.212 2.435c.004.057.053.1.117.1.064 0 .112-.043.117-.1l.234-2.435-.234-2.545c-.005-.057-.053-.1-.117-.1zm.909-.26c-.067 0-.122.05-.127.111l-.2 2.694.2 2.615c.005.057.06.109.127.109.065 0 .117-.052.122-.109l.227-2.615-.227-2.694c-.005-.061-.057-.111-.122-.111zm.963-.089c-.072 0-.131.053-.135.118l-.182 2.894.182 2.782c.004.063.063.116.135.116.07 0 .126-.053.131-.116l.204-2.782-.204-2.894c-.005-.065-.061-.118-.131-.118zm.974-.107c-.079 0-.142.06-.148.13l-.167 3.104.167 2.947c.006.068.069.122.148.122.077 0 .137-.054.143-.122l.187-2.947-.187-3.104c-.006-.07-.066-.13-.143-.13zm1.004-.134c-.084 0-.15.064-.156.14l-.152 3.351.152 3.093c.006.073.072.126.156.126.082 0 .145-.053.151-.126l.171-3.093-.171-3.351c-.006-.076-.069-.14-.151-.14zm.979-.032c-.089 0-.162.068-.168.15l-.137 3.383.137 3.226c.006.078.079.135.168.135.087 0 .157-.057.163-.135l.152-3.226-.152-3.383c-.006-.082-.076-.15-.163-.15zm1.968.383c-.093 0-.172.072-.178.162l-.116 2.87.116 3.338c.006.086.085.146.178.146.091 0 .167-.06.173-.146l.128-3.338-.128-2.87c-.006-.09-.082-.162-.173-.162zm-.949-.395c-.096 0-.174.075-.181.168l-.12 3.265.12 3.395c.007.089.085.152.181.152.094 0 .17-.063.176-.152l.133-3.395-.133-3.265c-.006-.093-.082-.168-.176-.168zm1.93.023c-.098 0-.181.079-.186.177l-.107 3.625.107 3.485c.005.093.088.16.186.16.096 0 .176-.067.182-.16l.118-3.485-.118-3.625c-.006-.098-.086-.177-.182-.177zm.97-.091c-.104 0-.188.083-.193.187l-.093 3.716.093 3.545c.005.098.089.17.193.17.101 0 .183-.072.188-.17l.104-3.545-.104-3.716c-.005-.104-.087-.187-.188-.187zm1.966.296c-.108 0-.195.086-.2.195l-.076 3.329.076 3.594c.005.103.092.18.2.18.106 0 .19-.077.195-.18l.085-3.594-.085-3.329c-.005-.109-.089-.195-.195-.195zm-.95-.219c-.108 0-.197.088-.202.199l-.081 3.548.081 3.606c.005.104.094.183.202.183.106 0 .193-.079.198-.183l.09-3.606-.09-3.548c-.005-.111-.092-.199-.198-.199zm3.763.095c-.023-.003-.047-.003-.07-.003-.233 0-.448.07-.626.19-.078-.82-.735-1.46-1.545-1.46-.196 0-.384.04-.553.107-.078.03-.099.063-.1.124v7.1c.001.06.044.112.104.123.007.001.015.001.022.001h2.768c.962 0 1.742-.79 1.742-1.767 0-.976-.78-1.767-1.742-1.767z" />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg
      className="w-6 h-6 text-blue-500"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
      />
    </svg>
  );
}

export default function Sources() {
  const navigate = useNavigate();
  const [spotify, setSpotify] = useState<SourceState>({ status: "disconnected" });
  const [soundcloud, setSoundcloud] = useState<SourceState>({ status: "disconnected" });
  const [localLibrary, setLocalLibrary] = useState<SourceState>({ status: "disconnected" });
  const [isConnecting, setIsConnecting] = useState<string | null>(null);

  // Check connection status
  const checkConnections = useCallback(async () => {
    try {
      const [spotifyConnected, soundcloudConnected, libraryConfig] = await Promise.all([
        check_source_connected("spotify"),
        check_source_connected("soundcloud"),
        get_library_config(),
      ]);

      console.log("[Sources] Connection check:", { spotifyConnected, soundcloudConnected, libraryConfig });

      setSpotify((prev) => ({
        ...prev,
        status: spotifyConnected ? "connected" : "disconnected",
      }));
      setSoundcloud((prev) => ({
        ...prev,
        status: soundcloudConnected ? "connected" : "disconnected",
      }));
      setLocalLibrary({
        status: libraryConfig.configured ? "connected" : "disconnected",
      });
    } catch (err) {
      console.error("Failed to check connections:", err);
    }
  }, []);

  // Check connection status on mount and OAuth completion (NOT on every focus)
  useEffect(() => {
    checkConnections();

    // Listen for OAuth complete events from backend
    const unlisten = listen("oauth-complete", () => {
      checkConnections();
    });

    return () => {
      unlisten.then((fn) => fn());
    };
  }, [checkConnections]);

  // Spotify handlers
  const handleConnectSpotify = useCallback(async () => {
    console.log("[Sources] Starting Spotify connection...");
    setIsConnecting("spotify");
    try {
      toast.info("Opening Spotify authorization in your browser...");
      await connect_spotify_with_server();
      console.log("[Sources] Spotify connected, updating UI...");
      toast.success("Spotify connected successfully!");
      // Directly update state to show connected
      setSpotify((prev) => {
        console.log("[Sources] Setting spotify status to connected, prev:", prev);
        return { ...prev, status: "connected" };
      });
    } catch (err) {
      console.error("[Sources] Spotify connection failed:", err);
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`Failed to connect Spotify: ${message}`);
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
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`Failed to disconnect: ${message}`);
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
      toast.success(`Spotify sync complete: ${result.added} new tracks`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setSpotify((prev) => ({
        ...prev,
        status: "error",
        errorMessage: message,
      }));
      toast.error(`Spotify sync failed: ${message}`);
    }
  }, []);

  // SoundCloud handlers
  const handleConnectSoundCloud = useCallback(async () => {
    setIsConnecting("soundcloud");
    try {
      toast.info("Opening SoundCloud authorization in your browser...");
      await connect_soundcloud_with_server();
      toast.success("SoundCloud connected successfully!");
      // Directly update state to show connected
      setSoundcloud((prev) => ({ ...prev, status: "connected" }));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`Failed to connect SoundCloud: ${message}`);
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
      const message = err instanceof Error ? err.message : String(err);
      toast.error(`Failed to disconnect: ${message}`);
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
      toast.success(`SoundCloud sync complete: ${result.added} new tracks`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setSoundcloud((prev) => ({
        ...prev,
        status: "error",
        errorMessage: message,
      }));
      toast.error(`SoundCloud sync failed: ${message}`);
    }
  }, []);

  // Listen for background import completion
  useEffect(() => {
    const unlisten = listen<{
      succeeded: number;
      failed: number;
      skipped: number;
      total: number;
      failure_summary: string[];
    }>("import-complete", (event) => {
      const { succeeded, failed, skipped, total } = event.payload;
      console.log("[Sources] Import complete:", event.payload);

      setLocalLibrary((prev) => ({
        ...prev,
        status: "connected",
        trackCount: (prev.trackCount || 0) + succeeded,
        lastSyncTime: new Date().toISOString(),
      }));

      if (succeeded > 0 || failed > 0) {
        toast.success(
          `Import complete: ${succeeded} new, ${skipped} already imported, ${failed} failed (${total} total files)`
        );
      } else {
        toast.info("No new tracks to import");
      }
    });

    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  // Local library handlers
  const handleImportFolder = useCallback(async () => {
    try {
      // Get configured library path
      const config = await get_library_config();
      if (!config.configured || !config.root_path) {
        toast.error("Library not configured. Go to Settings to set up your library.");
        navigate("/settings");
        return;
      }

      setLocalLibrary((prev) => ({ ...prev, status: "syncing" }));

      const result = await import_directory(config.root_path);
      toast.info(`Scanning ${result.file_count.toLocaleString()} audio files in background...`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setLocalLibrary((prev) => ({
        ...prev,
        status: "error",
        errorMessage: message,
      }));
      toast.error(`Import failed: ${message}`);
    }
  }, [navigate]);

  return (
    <div className="p-6 space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
          Sources
        </h1>
        <p className="text-gray-600 dark:text-gray-400">
          Connect your streaming accounts and import local music files
        </p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <SourceCard
          name="Spotify"
          icon={<SpotifyIcon />}
          status={spotify.status}
          description="Connect your Spotify account to sync your liked songs and playlists."
          trackCount={spotify.trackCount}
          lastSyncTime={spotify.lastSyncTime}
          errorMessage={spotify.errorMessage}
          onConnect={handleConnectSpotify}
          onDisconnect={handleDisconnectSpotify}
          onSync={handleSyncSpotify}
          isConnecting={isConnecting === "spotify"}
        />

        <SourceCard
          name="SoundCloud"
          icon={<SoundCloudIcon />}
          status={soundcloud.status}
          description="Connect your SoundCloud account to sync your liked tracks."
          trackCount={soundcloud.trackCount}
          lastSyncTime={soundcloud.lastSyncTime}
          errorMessage={soundcloud.errorMessage}
          onConnect={handleConnectSoundCloud}
          onDisconnect={handleDisconnectSoundCloud}
          onSync={handleSyncSoundCloud}
          isConnecting={isConnecting === "soundcloud"}
        />

        <SourceCard
          name="Local Library"
          icon={<FolderIcon />}
          status={localLibrary.status}
          description="Configure your music library location in Settings."
          trackCount={localLibrary.trackCount}
          lastSyncTime={localLibrary.lastSyncTime}
          errorMessage={localLibrary.errorMessage}
          onConnect={() => navigate("/settings")}
          onSync={handleImportFolder}
          connectLabel="Configure in Settings"
        />
      </div>

      {/* Setup instructions */}
      <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
        <h3 className="font-semibold text-blue-900 dark:text-blue-100 mb-2">
          Setup Required
        </h3>
        <p className="text-sm text-blue-800 dark:text-blue-200 mb-2">
          To connect Spotify or SoundCloud, you need to configure API credentials in your{" "}
          <code className="bg-blue-100 dark:bg-blue-800 px-1 rounded">.env</code> file:
        </p>
        <pre className="text-xs bg-blue-100 dark:bg-blue-800 p-2 rounded overflow-x-auto">
{`SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
SOUNDCLOUD_CLIENT_ID=your_client_id
SOUNDCLOUD_CLIENT_SECRET=your_client_secret`}
        </pre>
        <p className="text-xs text-blue-700 dark:text-blue-300 mt-2">
          Also set the redirect URI to <code className="bg-blue-100 dark:bg-blue-800 px-1 rounded">http://127.0.0.1:1420/callback</code> in your developer dashboard.
        </p>
      </div>
    </div>
  );
}
