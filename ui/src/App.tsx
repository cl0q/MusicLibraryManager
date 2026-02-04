import { createBrowserRouter, RouterProvider } from "react-router";
import ToastProvider from "./components/Notifications/ToastProvider";
import MainLayout from "./layouts/MainLayout";
import Dashboard from "./pages/Dashboard";
import LibraryBrowser from "./pages/LibraryBrowser";
import TrackDetail from "./pages/TrackDetail";
import Downloads from "./pages/Downloads";
import Playlists from "./pages/Playlists";
import PlaylistDetailPage from "./pages/PlaylistDetailPage";
import Sync from "./pages/Sync";

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
    ],
  },
]);

function App() {
  return (
    <>
      <ToastProvider />
      <RouterProvider router={router} />
    </>
  );
}

export default App;
