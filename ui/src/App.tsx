import { useEffect, useState } from "react";
import { createBrowserRouter, RouterProvider, Navigate } from "react-router";
import { toast } from "sonner";
import ToastProvider from "./components/Notifications/ToastProvider";
import { ThemeProvider } from "./contexts/ThemeContext";
import MainLayout from "./layouts/MainLayout";
import LibraryBrowser from "./pages/LibraryBrowser";
import TrackDetail from "./pages/TrackDetail";
import Playlists from "./pages/Playlists";
import PlaylistDetailPage from "./pages/PlaylistDetailPage";
import Sync from "./pages/Sync";
import Sources from "./pages/Sources";
import Settings from "./pages/Settings";
import OAuthCallback from "./pages/OAuthCallback";
import FirstRunWizard from "./components/Settings/FirstRunWizard";
import {
  spotify_exchange_code,
  soundcloud_exchange_code,
  get_library_config,
} from "./utils/tauri-commands";

const router = createBrowserRouter([
  {
    path: "/",
    element: <MainLayout />,
    children: [
      { index: true, element: <LibraryBrowser view="library" /> },
      { path: "remote", element: <LibraryBrowser view="remote" /> },
      { path: "library/:trackId", element: <TrackDetail /> },
      { path: "playlists", element: <Playlists /> },
      { path: "playlists/:id", element: <PlaylistDetailPage /> },
      { path: "sync", element: <Sync /> },
      { path: "sources", element: <Sources /> },
      { path: "settings", element: <Settings /> },
      { path: "callback", element: <OAuthCallback /> },
      // Redirects for removed routes
      { path: "downloads", element: <Navigate to="/" replace /> },
      { path: "library", element: <Navigate to="/" replace /> },
    ],
  },
]);

function App() {
  const [showWizard, setShowWizard] = useState(false);

  // Check library configuration on mount
  useEffect(() => {
    const checkConfig = async () => {
      try {
        const config = await get_library_config();
        if (!config.configured) {
          setShowWizard(true);
        }
      } catch (err) {
        console.error("Failed to check library config:", err);
      }
    };
    checkConfig();
  }, []);

  // Handle OAuth deep links (musiclibrary://callback?code=...&state=...)
  useEffect(() => {
    let cleanup: (() => void) | null = null;

    const setup = async () => {
      try {
        const { onOpenUrl } = await import("@tauri-apps/plugin-deep-link");
        const unsubscribe = await onOpenUrl(async (urls: string[]) => {
      console.log("[DeepLink] Received URLs:", urls);

      for (const urlString of urls) {
        try {
          console.log("[DeepLink] Processing URL:", urlString);
          const url = new URL(urlString);

          if (url.host !== "callback") {
            console.log("[DeepLink] Skipping non-callback URL, host:", url.host);
            continue;
          }

          const code = url.searchParams.get("code");
          const state = url.searchParams.get("state");
          console.log("[DeepLink] Parsed - code:", code?.substring(0, 20) + "...", "state:", state);

          if (!code) {
            toast.error("No authorization code in callback");
            continue;
          }

          let source: string | null = null;
          if (state?.startsWith("spotify:")) {
            source = "spotify";
          } else if (state?.startsWith("soundcloud:")) {
            source = "soundcloud";
          }

          if (!source) {
            toast.error("Could not determine OAuth source from state: " + state);
            continue;
          }

          console.log("[DeepLink] Exchanging code for source:", source);
          const userId = "default";

          if (source === "spotify") {
            await spotify_exchange_code(code, userId);
            toast.success("Spotify connected successfully!");
          } else if (source === "soundcloud") {
            await soundcloud_exchange_code(code, userId);
            toast.success("SoundCloud connected successfully!");
          }

          console.log("[DeepLink] Exchange successful!");
          window.dispatchEvent(new CustomEvent("oauth-complete", { detail: { source } }));
        } catch (err) {
          console.error("[DeepLink] Error:", err);
          const message = err instanceof Error ? err.message : String(err);
          toast.error(`Connection failed: ${message}`);
        }
      }
        });
        cleanup = unsubscribe;
      } catch (err) {
        console.warn("[DeepLink] Plugin not available (expected outside Tauri):", err);
      }
    };

    setup();

    return () => {
      cleanup?.();
    };
  }, []);

  return (
    <ThemeProvider>
      <ToastProvider />
      <RouterProvider router={router} />
      {showWizard && (
        <FirstRunWizard
          onComplete={() => setShowWizard(false)}
          onSkip={() => setShowWizard(false)}
        />
      )}
    </ThemeProvider>
  );
}

export default App;
