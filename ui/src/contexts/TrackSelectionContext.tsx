import { createContext, useContext, useState } from "react";
import type { ReactNode } from "react";
import type { Track } from "../types/library";

interface TrackSelectionContextValue {
  selectedTracks: Track[];
  setSelectedTracks: (tracks: Track[]) => void;
  isSelected: (trackId: number | null) => boolean;
  clearSelection: () => void;
}

const TrackSelectionContext = createContext<TrackSelectionContextValue | null>(null);

interface TrackSelectionProviderProps {
  children: ReactNode;
}

export function TrackSelectionProvider({ children }: TrackSelectionProviderProps) {
  const [selectedTracks, setSelectedTracks] = useState<Track[]>([]);

  const isSelected = (trackId: number | null): boolean => {
    if (trackId === null) return false;
    return selectedTracks.some((track) => track.id === trackId);
  };

  const clearSelection = () => {
    setSelectedTracks([]);
  };

  return (
    <TrackSelectionContext.Provider
      value={{ selectedTracks, setSelectedTracks, isSelected, clearSelection }}
    >
      {children}
    </TrackSelectionContext.Provider>
  );
}

export function useTrackSelection() {
  const context = useContext(TrackSelectionContext);
  if (!context) {
    throw new Error("useTrackSelection must be used within TrackSelectionProvider");
  }
  return context;
}
