import { Outlet } from "react-router";
import Sidebar from "../components/Sidebar/Sidebar";
import MiniPlayer from "../components/MiniPlayer/MiniPlayer";
import ActivityPanel from "../components/ActivityPanel/ActivityPanel";
import { LibraryMountProvider } from "../contexts/LibraryMountContext";
import { TrackSelectionProvider } from "../contexts/TrackSelectionContext";
import { PlaybackProvider } from "../contexts/PlaybackContext";

// Provider tree (outermost → innermost):
//   LibraryMountProvider     — mount/unmount of the external library drive
//   TrackSelectionProvider   — selectedTracks shared with playback (lifted from
//                              LibraryTable so PlaybackProvider can consume
//                              useTrackSelection() at MainLayout scope; D-12
//                              spacebar focus rule needs the selection here)
//   PlaybackProvider         — the locked D-04 playback API; depends on the
//                              two above
// MiniPlayer mounts inside PlaybackProvider, between <main> and <ActivityPanel>
// per D-14.
export default function MainLayout() {
  return (
    <LibraryMountProvider>
      <TrackSelectionProvider>
        <PlaybackProvider>
          <div className="flex h-screen bg-base text-ink">
            <Sidebar />
            <div className="flex flex-col flex-1 min-w-0">
              <main className="flex-1 overflow-y-auto">
                <Outlet />
              </main>
              <MiniPlayer />
              <ActivityPanel />
            </div>
          </div>
        </PlaybackProvider>
      </TrackSelectionProvider>
    </LibraryMountProvider>
  );
}
