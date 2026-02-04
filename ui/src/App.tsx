import { createBrowserRouter, RouterProvider } from "react-router";
import ToastProvider from "./components/Notifications/ToastProvider";
import MainLayout from "./layouts/MainLayout";
import Dashboard from "./pages/Dashboard";
import LibraryBrowser from "./pages/LibraryBrowser";

// Placeholder components for routes (will be implemented in later plans)

function Playlists() {
  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-4">Playlists</h1>
      <p className="text-gray-600 dark:text-gray-400">
        Playlists view coming soon...
      </p>
    </div>
  );
}

function PlaylistDetail() {
  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-4">Playlist Detail</h1>
      <p className="text-gray-600 dark:text-gray-400">
        Playlist detail view coming soon...
      </p>
    </div>
  );
}

function Sync() {
  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-4">Sync</h1>
      <p className="text-gray-600 dark:text-gray-400">
        Sync controls coming soon...
      </p>
    </div>
  );
}

function Downloads() {
  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-4">Downloads</h1>
      <p className="text-gray-600 dark:text-gray-400">
        Download queue coming soon...
      </p>
    </div>
  );
}

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
        path: "playlists",
        element: <Playlists />,
      },
      {
        path: "playlists/:id",
        element: <PlaylistDetail />,
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
