import { Outlet } from "react-router";
import Sidebar from "../components/Sidebar/Sidebar";
import ActivityPanel from "../components/ActivityPanel/ActivityPanel";
import { LibraryMountProvider } from "../contexts/LibraryMountContext";

export default function MainLayout() {
  return (
    <LibraryMountProvider>
      <div className="flex h-screen bg-base text-ink">
        <Sidebar />
        <div className="flex flex-col flex-1 min-w-0">
          <main className="flex-1 overflow-y-auto">
            <Outlet />
          </main>
          <ActivityPanel />
        </div>
      </div>
    </LibraryMountProvider>
  );
}
