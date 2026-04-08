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
    if (searchDebounceTimer) clearTimeout(searchDebounceTimer);

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

      const newTracks = Array.from(displayedTracks);
      const [movedTrack] = newTracks.splice(sourceIndex, 1);
      newTracks.splice(destIndex, 0, movedTrack);
      setDisplayedTracks(newTracks);
      setTracks(newTracks);

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
        <span className="text-sm text-ink-muted">Loading tracks...</span>
      </div>
    );
  }

  return (
    <div className="p-4 space-y-4 max-w-3xl">
      {/* Header */}
      <div className="flex items-center gap-3">
        <button
          onClick={onBack}
          className="text-ink-muted hover:text-ink transition-colors"
        >
          <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M15 19l-7-7 7-7" />
          </svg>
        </button>
        <div>
          <h1 className="text-sm font-semibold text-ink">{playlist.name}</h1>
          <p className="text-[11px] text-ink-muted">
            {tracks.length} {tracks.length === 1 ? 'track' : 'tracks'}
          </p>
        </div>
      </div>

      {/* Search */}
      <div className="relative">
        <svg
          className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-ink-muted"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          strokeWidth={2}
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
        </svg>
        <input
          type="text"
          placeholder="Search tracks..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="w-full pl-8 pr-3 py-1.5 text-xs bg-surface border border-edge rounded text-ink placeholder:text-ink-muted focus:outline-none focus:border-accent/50"
        />
      </div>

      {/* Error */}
      {error && (
        <div className="px-3 py-2 bg-rose-500/10 border border-rose-500/20 rounded text-xs text-rose-400">
          {error}
        </div>
      )}

      {/* Track List */}
      {displayedTracks.length === 0 ? (
        <div className="text-center text-ink-muted text-xs py-12">
          {isSearchActive ? 'No tracks match your search.' : 'This playlist is empty.'}
        </div>
      ) : (
        <DragDropContext onDragEnd={handleDragEnd}>
          <Droppable droppableId="playlist-tracks" isDropDisabled={isSearchActive}>
            {(provided) => (
              <div
                ref={provided.innerRef}
                {...provided.droppableProps}
              >
                {/* Column header */}
                <div className="flex items-center gap-3 px-2 py-1 text-[11px] text-ink-muted border-b border-edge-subtle mb-0.5">
                  <span className="w-5" />
                  <span className="w-6 text-right tabular-nums">#</span>
                  <span className="flex-1">Title</span>
                  <span className="w-12 text-right">Time</span>
                </div>

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
                        className={`group flex items-center gap-3 px-2 py-1.5 rounded transition-colors ${
                          snapshot.isDragging
                            ? 'bg-accent/10 shadow-lg'
                            : 'hover:bg-raised/60'
                        }`}
                      >
                        {/* Drag handle */}
                        <div
                          {...provided.dragHandleProps}
                          className={`w-5 shrink-0 flex items-center justify-center ${
                            isSearchActive
                              ? 'opacity-0'
                              : 'opacity-0 group-hover:opacity-100 text-ink-muted'
                          } transition-opacity`}
                        >
                          <svg className="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 16 16">
                            <circle cx="5" cy="4" r="1.2" />
                            <circle cx="5" cy="8" r="1.2" />
                            <circle cx="5" cy="12" r="1.2" />
                            <circle cx="11" cy="4" r="1.2" />
                            <circle cx="11" cy="8" r="1.2" />
                            <circle cx="11" cy="12" r="1.2" />
                          </svg>
                        </div>

                        {/* Index */}
                        <span className="w-6 text-right text-[11px] text-ink-muted tabular-nums shrink-0">
                          {index + 1}
                        </span>

                        {/* Track info */}
                        <div className="flex-1 min-w-0">
                          <p className="text-xs text-ink truncate">
                            {track.metadata.title}
                          </p>
                          <p className="text-[11px] text-ink-muted truncate">
                            {track.metadata.artist}
                            {track.metadata.album && ` \u2022 ${track.metadata.album}`}
                          </p>
                        </div>

                        {/* Duration */}
                        {track.metadata.duration && (
                          <span className="w-12 text-right text-[11px] text-ink-muted tabular-nums shrink-0">
                            {formatDuration(track.metadata.duration)}
                          </span>
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
    </div>
  );
}

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}
