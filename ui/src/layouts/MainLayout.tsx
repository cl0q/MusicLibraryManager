import { Outlet } from "react-router";
import Sidebar from "../components/Sidebar/Sidebar";
import StatusBar from "../components/StatusBar/StatusBar";
import { LibraryMountProvider } from "../contexts/LibraryMountContext";

export default function MainLayout() {
  return (
    <LibraryMountProvider>
      <div className="flex h-screen bg-white dark:bg-gray-950 text-gray-900 dark:text-gray-50">
        {/* Sidebar - fixed width on left */}
        <Sidebar />

        {/* Main content area - flex-grow */}
        <div className="flex flex-col flex-1 overflow-hidden">
          {/* Content area - scrollable */}
          <main className="flex-1 overflow-y-auto">
            <Outlet />
          </main>

          {/* Status bar - fixed at bottom */}
          <StatusBar />
        </div>
      </div>
    </LibraryMountProvider>
  );
}
