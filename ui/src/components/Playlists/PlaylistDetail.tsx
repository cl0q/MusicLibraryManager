/**
 * PlaylistDetail component - shows playlist tracks with search and drag-drop reordering.
 *
 * Features:
 * - Search input with 300ms debounce
 * - Drag-and-drop track reordering using hello-pangea/dnd
 * - Optimistic local state updates
 * - Disable drag when search is active
 * - Track list with drag handles
 */

import { useState, useEffect, useCallback } from 'react';
import {
  DragDropContext,
  Droppable,
  Draggable,
  type DropResult,
} from '@hello-pangea/dnd';
import {
  getPlaylistTracks,
  searchPlaylistTracks,
  reorderPlaylistTrack,
  type Playlist,
  type Track,
} from '../../hooks/usePlaylists';

interface PlaylistDetailProps {
  playlist: Playlist;
  onBack: () => void;
}

export default function PlaylistDetail({
  playlist,
  onBack,
}: PlaylistDetailProps) {
  const [tracks, setTracks] = useState<Track[]>([]);
  const [displayedTracks, setDisplayedTracks] = useState<Track[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [searchDebounceTimer, setSearchDebounceTimer] = useState<
    ReturnType<typeof setTimeout> | undefined
  >();

  useEffect(() => {
    loadTracks();
  }, [playlist.id]);

  useEffect(() => {
    // Debounce search
    if (searchDebounceTimer) {
      clearTimeout(searchDebounceTimer);
    }

    if (searchQuery.trim() === '') {
      setDisplayedTracks(tracks);
      return;
    }

    const timer = setTimeout(() => {
      performSearch(searchQuery);
    }, 300);

    setSearchDebounceTimer(timer);

    return () => {
      if (timer) clearTimeout(timer);
    };
  }, [searchQuery, tracks]);

  async function loadTracks() {
    try {
      setLoading(true);
      setError(null);
      const data = await getPlaylistTracks(playlist.id);
      setTracks(data);
      setDisplayedTracks(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load tracks');
    } finally {
      setLoading(false);
    }
  }

  async function performSearch(query: string) {
    try {
      const results = await searchPlaylistTracks(playlist.id, query);
      setDisplayedTracks(results);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Search failed');
    }
  }

  const handleDragEnd = useCallback(
    async (result: DropResult) => {
      if (!result.destination) return;

      const sourceIndex = result.source.index;
      const destIndex = result.destination.index;

      if (sourceIndex === destIndex) return;

      // Optimistic update
      const newTracks = Array.from(displayedTracks);
      const [movedTrack] = newTracks.splice(sourceIndex, 1);
      newTracks.splice(destIndex, 0, movedTrack);
      setDisplayedTracks(newTracks);
      setTracks(newTracks);

      // Compute after_track_id and before_track_id
      const afterTrackId = destIndex > 0 ? newTracks[destIndex - 1].id : null;
      const beforeTrackId =
        destIndex < newTracks.length - 1 ? newTracks[destIndex + 1].id : null;

      try {
        await reorderPlaylistTrack(
          playlist.id,
          movedTrack.id,
          afterTrackId || undefined,
          beforeTrackId || undefined
        );
      } catch (err) {
        // Revert on error
        setError(
          err instanceof Error ? err.message : 'Failed to reorder track'
        );
        await loadTracks();
      }
    },
    [displayedTracks, playlist.id]
  );

  const isSearchActive = searchQuery.trim() !== '';

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-gray-400">Loading tracks...</div>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-start gap-4">
        <button
          onClick={onBack}
          className="mt-2 text-gray-400 hover:text-white transition"
        >
          <svg
            className="w-6 h-6"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M15 19l-7-7 7-7"
            />
          </svg>
        </button>

        <div className="flex-1">
          <h1 className="text-3xl font-bold text-white">{playlist.name}</h1>
          {playlist.description && (
            <p className="text-gray-400 mt-2">{playlist.description}</p>
          )}
          <p className="text-sm text-gray-500 mt-2">
            {tracks.length} {tracks.length === 1 ? 'track' : 'tracks'}
          </p>
        </div>
      </div>

      {/* Search Input */}
      <div className="relative">
        <input
          type="text"
          placeholder="Search tracks..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="w-full px-4 py-3 pl-10 bg-gray-800 text-white rounded-lg border border-gray-700 focus:outline-none focus:border-blue-500"
        />
        <svg
          className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
          />
        </svg>
      </div>

      {/* Error Display */}
      {error && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-lg text-red-400">
          {error}
        </div>
      )}

      {/* Track List with Drag-Drop */}
      {displayedTracks.length === 0 ? (
        <div className="text-center text-gray-400 py-12">
          {isSearchActive
            ? 'No tracks match your search.'
            : 'This playlist is empty.'}
        </div>
      ) : (
        <DragDropContext onDragEnd={handleDragEnd}>
          <Droppable droppableId="playlist-tracks" isDropDisabled={isSearchActive}>
            {(provided, snapshot) => (
              <div
                ref={provided.innerRef}
                {...provided.droppableProps}
                className={`space-y-1 ${
                  snapshot.isDraggingOver ? 'bg-gray-800/50' : ''
                }`}
              >
                {displayedTracks.map((track, index) => (
                  <Draggable
                    key={track.id}
                    draggableId={String(track.id)}
                    index={index}
                    isDragDisabled={isSearchActive}
                  >
                    {(provided, snapshot) => (
                      <div
                        ref={provided.innerRef}
                        {...provided.draggableProps}
                        className={`flex items-center gap-3 p-3 rounded-lg transition ${
                          snapshot.isDragging
                            ? 'bg-blue-600/20 shadow-lg'
                            : 'bg-gray-800 hover:bg-gray-750'
                        } ${isSearchActive ? 'cursor-default' : 'cursor-move'}`}
                      >
                        {/* Drag Handle */}
                        <div
                          {...provided.dragHandleProps}
                          className={`flex-shrink-0 text-gray-500 ${
                            isSearchActive ? 'opacity-30' : 'hover:text-gray-300'
                          }`}
                        >
                          <svg
                            className="w-5 h-5"
                            fill="currentColor"
                            viewBox="0 0 16 16"
                          >
                            <circle cx="4" cy="3" r="1.5" />
                            <circle cx="4" cy="8" r="1.5" />
                            <circle cx="4" cy="13" r="1.5" />
                            <circle cx="12" cy="3" r="1.5" />
                            <circle cx="12" cy="8" r="1.5" />
                            <circle cx="12" cy="13" r="1.5" />
                          </svg>
                        </div>

                        {/* Track Info */}
                        <div className="flex-1 min-w-0">
                          <h3 className="text-white font-medium truncate">
                            {track.metadata.title}
                          </h3>
                          <p className="text-sm text-gray-400 truncate">
                            {track.metadata.artist}
                            {track.metadata.album &&
                              ` • ${track.metadata.album}`}
                          </p>
                        </div>

                        {/* Duration */}
                        {track.metadata.duration && (
                          <div className="text-sm text-gray-500">
                            {formatDuration(track.metadata.duration)}
                          </div>
                        )}
                      </div>
                    )}
                  </Draggable>
                ))}
                {provided.placeholder}
              </div>
            )}
          </Droppable>
        </DragDropContext>
      )}

      {isSearchActive && (
        <div className="text-sm text-yellow-400 text-center">
          Drag-and-drop disabled while searching
        </div>
      )}
    </div>
  );
}

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}
