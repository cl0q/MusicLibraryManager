import { test } from "@playwright/test";

const SCREENSHOT_DIR = "e2e/screenshots";

// Pages to capture - covers every route in the app
const pages = [
  { name: "01-library-local", path: "/" },
  { name: "02-library-remote", path: "/remote" },
  { name: "03-playlists", path: "/playlists" },
  { name: "04-sync", path: "/sync" },
  { name: "05-sources", path: "/sources" },
  { name: "06-settings", path: "/settings" },
];

test.describe("Visual Audit — full page screenshots", () => {
  for (const page of pages) {
    test(`Capture ${page.name}`, async ({ page: p }) => {
      // Mock Tauri API so pages don't crash outside the native shell
      await p.addInitScript(() => {
        // Track event listeners for mock event emission
        const eventListeners: Record<string, Array<(event: unknown) => void>> = {};

        // @ts-ignore — mock window.__TAURI_INTERNALS__
        window.__TAURI_INTERNALS__ = {
          invoke: async (cmd: string, _args?: unknown) => {
            // Handle plugin commands — return 0 (valid event ID)
            if (cmd.startsWith("plugin:")) return 0;

            // Return sensible defaults for common commands
            const mocks: Record<string, unknown> = {
              search_library: [],
              get_library_config: {
                root_path: "/Volumes/Music",
                scan_folders: ["Artists", "Albums"],
                download_destination: "00_Artists",
                library_id: "test",
                configured: true,
              },
              check_library_connection: true,
              get_review_queue_count: 3,
              get_remote_track_count: 42,
              get_retry_queue_status: { pending_count: 2, failed_count: 1 },
              get_recent_downloads: [],
              get_library_storage_size: 12_400_000_000,
              get_last_sync_time: new Date(Date.now() - 7200000).toISOString(),
              check_source_connected: true,
              get_playlists_command: [
                { id: 1, name: "Chill Vibes", description: "Lo-fi beats to relax to", category: "regular", is_liked: false, is_smart: false, is_pinned: true, cover_image_path: null, cover_image_url: null, source_id: null, external_id: null, date_created: "2025-01-01" },
                { id: 2, name: "Workout Mix", description: "High energy tracks", category: "regular", is_liked: false, is_smart: false, is_pinned: false, cover_image_path: null, cover_image_url: null, source_id: null, external_id: null, date_created: "2025-02-01" },
                { id: 3, name: "Liked Songs", description: null, category: "liked", is_liked: true, is_smart: false, is_pinned: false, cover_image_path: null, cover_image_url: null, source_id: "spotify", external_id: null, date_created: "2025-01-15" },
              ],
              list_sync_profiles: [
                { id: 1, name: "iPod Nano", output_folder: "/Volumes/IPOD", track_count: 120, manual_track_count: 50, playlist_count: 3, rule_count: 0, date_created: "2025-01-01", date_modified: "2025-03-01" },
              ],
              get_subfolders: ["Artists", "Albums", "Singles", "DJ Sets"],
            };

            // For search_library with empty query, return mock tracks
            if (cmd === "search_library" || cmd === "get_library_tracks_only" || cmd === "get_remote_tracks_only") {
              return Array.from({ length: 25 }, (_, i) => ({
                id: i + 1,
                organized_path: i < 15 ? `/Volumes/Music/Artists/Track${i + 1}.m4a` : null,
                date_added: new Date(Date.now() - i * 86400000).toISOString(),
                download_status: i < 15 ? new Date().toISOString() : null,
                metadata: {
                  title: ["Midnight Drive", "Neon Lights", "Ocean Waves", "Thunder Road", "Starlight", "Deep Blue", "City Rain", "Golden Hour", "Silver Moon", "Electric Dreams", "Velvet Sky", "Crystal Clear", "Shadow Dance", "Fire Walk", "Ice Palace", "Desert Wind", "Forest Echo", "River Song", "Mountain Peak", "Valley Low", "Storm Front", "Calm Waters", "Bright Star", "Dark Matter", "Lost Signal"][i],
                  artist: ["ODESZA", "Tycho", "Bonobo", "Four Tet", "Caribou", "Jon Hopkins", "Floating Points", "Boards of Canada", "Aphex Twin", "Burial"][i % 10],
                  album: ["Summer", "Dive", "Migration", "New Energy", "Suddenly"][i % 5],
                  duration: 180 + (i * 17) % 240,
                  format: i < 15 ? "m4a" : (i % 2 === 0 ? "soundcloud" : "spotify"),
                  bitrate: i < 15 ? 256000 : null,
                  album_artist: "",
                  original_path: i < 15 ? null : `https://soundcloud.com/track${i}`,
                },
              }));
            }

            if (cmd in mocks) return mocks[cmd];
            return null;
          },
          transformCallback: () => Math.floor(Math.random() * 100000),
          metadata: { currentWebview: { label: "main" }, currentWindow: { label: "main" } },
        };

        // Mock the EVENT plugin internals (separate from core internals)
        // @ts-ignore — Tauri v2 uses this for event listener registration/cleanup
        window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
          unregisterListener: (_event: string, _eventId: number) => {},
          registerListener: (_event: string, _eventId: number) => {},
        };

        // Mock Tauri event listener (metadata already set above)
      });

      await p.goto(page.path, { waitUntil: "networkidle" });
      await p.waitForTimeout(500); // let animations settle

      await p.screenshot({
        path: `${SCREENSHOT_DIR}/${page.name}.png`,
        fullPage: false,
      });
    });
  }
});
