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

/**
 * Playlist detail — Solar mock (screens.jsx::PlaylistDetailScreen).
 *
 * Header: cover art (104px), "PLAYLIST" uppercase label, IBM Plex Serif
 * title (via var(--font-display)), monospace subtitle showing
 * tracks · duration · updated. BPM range deliberately dropped per
 * CONTRACT.md §2.
 *
 * Body: searchable, drag-reorderable track list. Drag handle fades in on
 * row hover; drag is disabled while a filter query is active (it would
 * reorder the filtered subset, not the underlying playlist).
 */

interface PlaylistDetailProps {
  playlist: Playlist;
  onBack: () => void;
}

export default function PlaylistDetail({ playlist, onBack }: PlaylistDetailProps) {
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playlist.id]);

  useEffect(() => {
    if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
    if (searchQuery.trim() === '') {
      setDisplayedTracks(tracks);
      return;
    }
    const timer = setTimeout(() => performSearch(searchQuery), 300);
    setSearchDebounceTimer(timer);
    return () => { if (timer) clearTimeout(timer); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
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
          beforeTrackId || undefined,
        );
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to reorder track');
        await loadTracks();
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [displayedTracks, playlist.id],
  );

  const isSearchActive = searchQuery.trim() !== '';
  const totalDuration = tracks.reduce((sum, t) => sum + (t.metadata.duration ?? 0), 0);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <span className="text-sm text-ink-muted">Loading tracks...</span>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full overflow-hidden" style={{ fontFamily: 'var(--font-ui)' }}>
      {/* Hero header */}
      <div className="flex items-end gap-4 px-5 pt-5 pb-3.5 border-b border-edge-subtle shrink-0">
        <button
          onClick={onBack}
          className="self-start text-ink-muted hover:text-ink transition-colors shrink-0 mt-1"
          aria-label="Back"
        >
          <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M15 19l-7-7 7-7" />
          </svg>
        </button>

        <div className="w-[104px] h-[104px] rounded-md overflow-hidden shrink-0 bg-raised">
          {playlist.cover_image_url || playlist.cover_image_path ? (
            <img
              src={playlist.cover_image_url || playlist.cover_image_path || ''}
              alt={playlist.name}
              className="w-full h-full object-cover"
            />
          ) : (
            <div
              className="w-full h-full"
              style={{ background: `linear-gradient(135deg, var(--color-accent), var(--color-base))` }}
            />
          )}
        </div>

        <div className="flex-1 min-w-0 pb-0.5">
          <div className="text-[10px] text-ink-muted uppercase tracking-[0.1em] mb-1">Playlist</div>
          <h1
            className="text-[26px] text-ink mb-1"
            style={{
              fontFamily: 'var(--font-display)',
              fontWeight: 700,
              letterSpacing: '-0.5px',
              lineHeight: 1.1,
            }}
            title={playlist.name}
          >
            {playlist.name}
          </h1>
          <div
            className="text-[12px] text-ink-muted tabular-nums truncate"
            style={{ fontFamily: 'var(--font-mono)' }}
          >
            {tracks.length} {tracks.length === 1 ? 'track' : 'tracks'} · {formatDurationLong(totalDuration)} · updated {relativeUpdated(playlist.date_created)}
          </div>
        </div>

        <div className="flex gap-1.5 self-end pb-0.5 shrink-0">
          <button
            className="flex items-center gap-1.5 h-[30px] px-3.5 rounded-[5px] bg-accent text-[12px] font-semibold hover:bg-accent-bright transition-colors"
            style={{ color: 'var(--color-base)' }}
            disabled
            title="Playback coming soon"
          >
            <svg className="w-[13px] h-[13px]" fill="currentColor" viewBox="0 0 24 24">
              <path d="M7 5v14l12-7z" />
            </svg>
            Play
          </button>
        </div>
      </div>

      {/* Search */}
      <div className="px-5 py-2.5 shrink-0">
        <div className="relative max-w-md">
          <svg
            className="absolute left-2.5 top-1/2 -translate-y-1/2 w-[13px] h-[13px] text-ink-muted pointer-events-none"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            strokeWidth={1.8}
          >
            <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-5.2-5.2M17 10a7 7 0 11-14 0 7 7 0 0114 0z" />
          </svg>
          <input
            type="text"
            placeholder="Search tracks…"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full h-[30px] pl-[30px] pr-3 text-[12px] bg-base border border-edge rounded-[5px] text-ink placeholder:text-ink-muted focus:outline-none focus:border-accent/50"
          />
        </div>
      </div>

      {error && (
        <div className="mx-5 mb-2 px-3 py-2 bg-rose-500/10 border border-rose-500/20 rounded text-xs text-rose-400">
          {error}
        </div>
      )}

      {/* Track listing */}
      <div className="flex-1 overflow-auto px-5 pb-5 min-h-0">
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
                  className="border border-edge rounded-md bg-surface overflow-hidden"
                >
                  <div className="grid grid-cols-[30px_30px_1fr_60px] items-center gap-3 px-3 py-2 text-[10px] text-ink-muted uppercase tracking-[0.08em] font-semibold border-b border-edge">
                    <span />
                    <span className="text-right">#</span>
                    <span>Title</span>
                    <span className="text-right">Time</span>
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
                          className={`group grid grid-cols-[30px_30px_1fr_60px] items-center gap-3 px-3 border-t border-edge-subtle transition-colors ${
                            snapshot.isDragging
                              ? 'bg-accent/10 shadow-lg'
                              : 'hover:bg-raised/60'
                          }`}
                          style={{
                            height: 'var(--row-h, 36px)',
                            ...provided.draggableProps.style,
                          }}
                        >
                          <div
                            {...provided.dragHandleProps}
                            className={`shrink-0 flex items-center justify-center ${
                              isSearchActive
                                ? 'opacity-0'
                                : 'opacity-0 group-hover:opacity-100 text-ink-muted'
                            } transition-opacity cursor-grab`}
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
                          <span
                            className="text-right text-[11px] text-ink-muted tabular-nums shrink-0"
                            style={{ fontFamily: 'var(--font-mono)' }}
                          >
                            {index + 1}
                          </span>
                          <div className="min-w-0">
                            <div className="text-[12.5px] text-ink truncate">{track.metadata.title}</div>
                            <div className="text-[11px] text-ink-muted truncate">
                              {track.metadata.artist}
                              {track.metadata.album && ` · ${track.metadata.album}`}
                            </div>
                          </div>
                          <span
                            className="text-right text-[11px] text-ink-muted tabular-nums shrink-0"
                            style={{ fontFamily: 'var(--font-mono)' }}
                          >
                            {track.metadata.duration ? formatDuration(track.metadata.duration) : '—'}
                          </span>
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
    </div>
  );
}

/* ── Helpers ───────────────────────────────────────────── */

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

function formatDurationLong(secs: number): string {
  if (!secs || secs <= 0) return '0m';
  const hours = Math.floor(secs / 3600);
  const minutes = Math.floor((secs % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, '0')}m`;
  return `${minutes}m`;
}

function relativeUpdated(iso: string): string {
  const d = new Date(iso);
  const diffMs = Date.now() - d.getTime();
  const mins = Math.floor(diffMs / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return d.toLocaleDateString();
}
