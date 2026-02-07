import { useEffect, useState } from "react";
import { createBrowserRouter, RouterProvider } from "react-router";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { toast } from "sonner";
import ToastProvider from "./components/Notifications/ToastProvider";
import MainLayout from "./layouts/MainLayout";
import Dashboard from "./pages/Dashboard";
import LibraryBrowser from "./pages/LibraryBrowser";
import TrackDetail from "./pages/TrackDetail";
import Downloads from "./pages/Downloads";
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
      {
        index: true,
        element: <Dashboard />,
      },
      {
        path: "sources",
        element: <Sources />,
      },
      {
        path: "callback",
        element: <OAuthCallback />,
      },
      {
        path: "library",
        element: <LibraryBrowser />,
      },
      {
        path: "library/:trackId",
        element: <TrackDetail />,
      },
      {
        path: "playlists",
        element: <Playlists />,
      },
      {
        path: "playlists/:id",
        element: <PlaylistDetailPage />,
      },
      {
        path: "sync",
        element: <Sync />,
      },
      {
        path: "downloads",
        element: <Downloads />,
      },
      {
        path: "settings",
        element: <Settings />,
      },
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
    console.log("[DeepLink] Setting up deep link handler");

    const unsubscribe = onOpenUrl(async (urls) => {
      console.log("[DeepLink] Received URLs:", urls);

      for (const urlString of urls) {
        try {
          console.log("[DeepLink] Processing URL:", urlString);
          const url = new URL(urlString);

          // Only handle callback URLs
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

          // Determine source from state prefix
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

          // Exchange the code for tokens
          if (source === "spotify") {
            await spotify_exchange_code(code, userId);
            toast.success("Spotify connected successfully!");
          } else if (source === "soundcloud") {
            await soundcloud_exchange_code(code, userId);
            toast.success("SoundCloud connected successfully!");
          }

          console.log("[DeepLink] Exchange successful!");
          // Emit event so Sources page can refresh connection status
          window.dispatchEvent(new CustomEvent("oauth-complete", { detail: { source } }));
        } catch (err) {
          console.error("[DeepLink] Error:", err);
          const message = err instanceof Error ? err.message : String(err);
          toast.error(`Connection failed: ${message}`);
        }
      }
    });

    return () => {
      unsubscribe.then((fn) => fn());
    };
  }, []);

  return (
    <>
      <ToastProvider />
      <RouterProvider router={router} />
      {showWizard && (
        <FirstRunWizard
          onComplete={() => setShowWizard(false)}
          onSkip={() => setShowWizard(false)}
        />
      )}
    </>
  );
}

export default App;
