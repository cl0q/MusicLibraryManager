import LibrarySetup from "./LibrarySetup";

interface FirstRunWizardProps {
  onComplete: () => void;
  onSkip: () => void;
}

export default function FirstRunWizard({ onComplete, onSkip }: FirstRunWizardProps) {
  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-lg shadow-2xl max-w-2xl w-full max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="p-6 border-b border-gray-200 dark:border-gray-700">
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
            Welcome to Music Library Manager
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Set up your music library location to get started. Your library lives on an external drive and contains your owned music files.
          </p>
        </div>

        {/* Content */}
        <div className="p-6">
          <LibrarySetup onConfigured={onComplete} />
        </div>

        {/* Footer */}
        <div className="p-6 border-t border-gray-200 dark:border-gray-700 flex justify-between items-center">
          <button
            onClick={onSkip}
            className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-200 transition-colors"
          >
            Skip for now
          </button>
          <p className="text-xs text-gray-500 dark:text-gray-500 max-w-md">
            You can set this up later in Settings. Library features will be disabled until configured.
          </p>
        </div>
      </div>
    </div>
  );
}
