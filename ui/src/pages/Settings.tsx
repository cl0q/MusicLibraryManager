import LibrarySetup from "../components/Settings/LibrarySetup";

export default function Settings() {
  return (
    <div className="flex flex-col h-full p-6 space-y-6">
      <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Settings</h1>
      <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Library Location</h2>
        <LibrarySetup />
      </div>
    </div>
  );
}
