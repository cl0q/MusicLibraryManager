/**
 * OAuth callback handler page.
 *
 * Handles the redirect from OAuth providers (Spotify, SoundCloud) after user
 * authorizes. Parses the authorization code from URL params and exchanges it
 * for tokens via the Tauri backend.
 *
 * Flow (when opened in browser after OAuth redirect):
 * 1. OAuth provider redirects to http://127.0.0.1:1420/callback?code=...&state=...
 * 2. This page detects it's running in a browser (not Tauri webview)
 * 3. Redirects to musiclibrary://callback?code=...&state=... (deep link)
 * 4. OS opens the Tauri app with the deep link
 * 5. Tauri app handles the code exchange
 *
 * Flow (when in Tauri webview, future-proofing):
 * 1. Directly calls the exchange commands
 */

import { useEffect, useState } from "react";
import { useSearchParams } from "react-router";

type CallbackStatus = "processing" | "redirecting" | "success" | "error";

// Check if we're running inside Tauri or in a regular browser
function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export default function OAuthCallback() {
  const [searchParams] = useSearchParams();
  const [status, setStatus] = useState<CallbackStatus>("processing");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    async function handleCallback() {
      // Get OAuth params from URL
      const code = searchParams.get("code");
      const state = searchParams.get("state");
      const error = searchParams.get("error");
      const errorDescription = searchParams.get("error_description");

      // Handle OAuth error from provider
      if (error) {
        setStatus("error");
        setErrorMessage(errorDescription || error);
        return;
      }

      // No code means something went wrong
      if (!code) {
        setStatus("error");
        setErrorMessage("No authorization code received");
        return;
      }

      // If we're in a browser (not Tauri), redirect to deep link
      if (!isTauri()) {
        setStatus("redirecting");

        // Build the deep link URL with the OAuth params
        const deepLinkUrl = new URL("musiclibrary://callback");
        deepLinkUrl.searchParams.set("code", code);
        if (state) {
          deepLinkUrl.searchParams.set("state", state);
        }

        // Redirect to the deep link - this will open the Tauri app
        window.location.href = deepLinkUrl.toString();

        // Try to close the tab after a short delay
        // (browsers may block this if the tab wasn't opened by script)
        setTimeout(() => {
          window.close();
        }, 500);
        return;
      }

      // If we're inside Tauri (shouldn't normally happen, but future-proofing)
      // The deep link handler in App.tsx will handle this
      setStatus("success");
    }

    handleCallback();
  }, [searchParams]);

  return (
    <div className="flex items-center justify-center h-full min-h-screen bg-gray-100 dark:bg-gray-900">
      <div className="bg-white dark:bg-gray-800 rounded-lg p-8 border border-gray-200 dark:border-gray-700 max-w-md w-full text-center shadow-lg">
        {status === "processing" && (
          <>
            <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600 mx-auto mb-4" />
            <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              Processing...
            </h2>
            <p className="text-gray-600 dark:text-gray-400">
              Please wait while we process the authorization.
            </p>
          </>
        )}

        {status === "redirecting" && (
          <>
            <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-green-600 mx-auto mb-4" />
            <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              Opening App...
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-4">
              Redirecting you back to Music Library Manager...
            </p>
            <p className="text-sm text-gray-500 dark:text-gray-500">
              If the app doesn't open automatically, please return to it manually.
            </p>
          </>
        )}

        {status === "success" && (
          <>
            <div className="h-12 w-12 rounded-full bg-green-100 dark:bg-green-900 flex items-center justify-center mx-auto mb-4">
              <svg
                className="h-6 w-6 text-green-600 dark:text-green-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
            </div>
            <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              Authorization Received
            </h2>
            <p className="text-gray-600 dark:text-gray-400">
              You can close this tab and return to the app.
            </p>
          </>
        )}

        {status === "error" && (
          <>
            <div className="h-12 w-12 rounded-full bg-red-100 dark:bg-red-900 flex items-center justify-center mx-auto mb-4">
              <svg
                className="h-6 w-6 text-red-600 dark:text-red-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </div>
            <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              Authorization Failed
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-4">
              {errorMessage}
            </p>
            <p className="text-sm text-gray-500 dark:text-gray-500">
              Please close this tab and try again from the app.
            </p>
          </>
        )}
      </div>
    </div>
  );
}
