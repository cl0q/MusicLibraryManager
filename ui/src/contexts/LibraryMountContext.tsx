import { createContext, useContext, useState, useEffect } from "react";
import type { ReactNode } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  get_library_config,
  check_library_connection,
} from "../utils/tauri-commands";

type MountState = "connected" | "disconnected" | "not_configured" | "loading";

interface LibraryMountContextValue {
  mountState: MountState;
  isLibraryAvailable: boolean;
  refreshMountState: () => Promise<void>;
}

const LibraryMountContext = createContext<LibraryMountContextValue | null>(null);

interface LibraryMountProviderProps {
  children: ReactNode;
}

export function LibraryMountProvider({ children }: LibraryMountProviderProps) {
  const [mountState, setMountState] = useState<MountState>("loading");

  // Helper to map backend state strings to frontend state
  const mapBackendState = (backendState: string): MountState => {
    switch (backendState) {
      case "Connected":
        return "connected";
      case "Disconnected":
        return "disconnected";
      case "NotConfigured":
        return "not_configured";
      default:
        console.warn("Unknown backend state:", backendState);
        return "disconnected";
    }
  };

  // Check mount state from backend
  const checkMountState = async (): Promise<MountState> => {
    try {
      const config = await get_library_config();
      if (!config.configured) {
        return "not_configured";
      }
      const isConnected = await check_library_connection();
      return isConnected ? "connected" : "disconnected";
    } catch (error) {
      console.error("Failed to check mount state:", error);
      return "not_configured";
    }
  };

  // Refresh mount state (called after settings changes)
  const refreshMountState = async () => {
    const newState = await checkMountState();
    setMountState(newState);
  };

  // Initialize mount state and subscribe to events
  useEffect(() => {
    let unlisten: (() => void) | null = null;

    const initialize = async () => {
      // Load initial state
      const initialState = await checkMountState();
      setMountState(initialState);

      // Subscribe to mount change events from backend
      try {
        const unlistenFn = await listen<string>("library-mount-changed", (event) => {
          const backendState = event.payload;
          const newState = mapBackendState(backendState);

          setMountState((prevState) => {
            // If transitioning from disconnected/not_configured to connected, dispatch reconnection event
            if (
              (prevState === "disconnected" || prevState === "not_configured") &&
              newState === "connected"
            ) {
              // Dispatch custom event for library reconnection
              window.dispatchEvent(new CustomEvent("library-reconnected"));
            }
            return newState;
          });
        });
        unlisten = unlistenFn;
      } catch (error) {
        console.error("Failed to subscribe to library-mount-changed events:", error);
      }
    };

    initialize();

    // Cleanup listener on unmount
    return () => {
      if (unlisten) {
        unlisten();
      }
    };
  }, []);

  const isLibraryAvailable = mountState === "connected";

  return (
    <LibraryMountContext.Provider
      value={{ mountState, isLibraryAvailable, refreshMountState }}
    >
      {children}
    </LibraryMountContext.Provider>
  );
}

export function useLibraryMount() {
  const context = useContext(LibraryMountContext);
  if (!context) {
    throw new Error("useLibraryMount must be used within LibraryMountProvider");
  }
  return context;
}
