import { useState, useEffect } from 'react';
import {
  getPlaylists,
  createPlaylist,
  type Playlist,
} from '../../hooks/usePlaylists';
import { ImportModal } from '../PlaylistImport/ImportModal';

interface PlaylistListProps {
  onSelectPlaylist: (playlist: Playlist) => void;
}

export default function PlaylistList({ onSelectPlaylist }: PlaylistListProps) {
  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreateForm, setShowCreateForm] = useState(false);
  const [newPlaylistName, setNewPlaylistName] = useState('');
  const [newPlaylistDescription, setNewPlaylistDescription] = useState('');
  const [showImportModal, setShowImportModal] = useState(false);

  useEffect(() => {
    loadPlaylists();
  }, []);

  async function loadPlaylists() {
    try {
      setLoading(true);
      setError(null);
      const data = await getPlaylists();
      setPlaylists(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load playlists');
    } finally {
      setLoading(false);
    }
  }

  async function handleCreatePlaylist(e: React.FormEvent) {
    e.preventDefault();
    if (!newPlaylistName.trim()) return;

    try {
      await createPlaylist(newPlaylistName, newPlaylistDescription || undefined);
      setNewPlaylistName('');
      setNewPlaylistDescription('');
      setShowCreateForm(false);
      await loadPlaylists();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create playlist');
    }
  }

  const likedPlaylists = playlists.filter((p) => p.category === 'liked');
  const smartPlaylists = playlists.filter((p) => p.category === 'smart');
  const regularPlaylists = playlists.filter((p) => p.category === 'regular');

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <span className="text-sm text-ink-muted">Loading playlists...</span>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center justify-center h-full">
        <span className="text-sm text-rose-400">Error: {error}</span>
      </div>
    );
  }

  return (
    <div className="p-4 space-y-5">
      <div className="flex items-center justify-between">
        <h1 className="text-xs font-semibold uppercase tracking-wide text-ink-secondary">Playlists</h1>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowImportModal(true)}
            className="px-3 py-1.5 text-xs font-medium text-ink-muted hover:text-ink border border-edge rounded transition-colors"
          >
            Import
          </button>
          <button
            onClick={() => setShowCreateForm(!showCreateForm)}
            className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors"
          >
            {showCreateForm ? 'Cancel' : '+ Create'}
          </button>
        </div>
      </div>

      {showCreateForm && (
        <form onSubmit={handleCreatePlaylist} className="bg-surface border border-edge rounded-lg p-3 space-y-2">
          <input
            type="text"
            placeholder="Playlist name"
            value={newPlaylistName}
            onChange={(e) => setNewPlaylistName(e.target.value)}
            className="w-full px-3 py-1.5 text-[13px] bg-raised border border-edge rounded text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
            autoFocus
          />
          <input
            type="text"
            placeholder="Description (optional)"
            value={newPlaylistDescription}
            onChange={(e) => setNewPlaylistDescription(e.target.value)}
            className="w-full px-3 py-1.5 text-[13px] bg-raised border border-edge rounded text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
          />
          <button
            type="submit"
            className="w-full px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors"
          >
            Create
          </button>
        </form>
      )}

      {likedPlaylists.length > 0 && (
        <PlaylistSection title="Liked" playlists={likedPlaylists} onSelect={onSelectPlaylist} />
      )}
      {smartPlaylists.length > 0 && (
        <PlaylistSection title="Smart" playlists={smartPlaylists} onSelect={onSelectPlaylist} />
      )}
      {regularPlaylists.length > 0 && (
        <PlaylistSection title="Playlists" playlists={regularPlaylists} onSelect={onSelectPlaylist} />
      )}

      {playlists.length === 0 && (
        <div className="flex items-center justify-center py-12">
          <span className="text-sm text-ink-muted">No playlists yet</span>
        </div>
      )}

      {showImportModal && (
        <ImportModal
          onClose={() => setShowImportModal(false)}
          onPlaylistCreated={() => {
            setShowImportModal(false);
            loadPlaylists();
          }}
        />
      )}
    </div>
  );
}

function PlaylistSection({ title, playlists, onSelect }: { title: string; playlists: Playlist[]; onSelect: (p: Playlist) => void }) {
  return (
    <section>
      <h2 className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted mb-2">{title}</h2>
      <div className="space-y-1">
        {playlists.map((playlist) => (
          <button
            key={playlist.id}
            onClick={() => onSelect(playlist)}
            className="w-full flex items-center gap-3 px-3 py-2 bg-surface border border-edge rounded-lg hover:bg-raised transition-colors text-left"
          >
            <div className="w-10 h-10 bg-raised rounded flex items-center justify-center shrink-0">
              {playlist.cover_image_url || playlist.cover_image_path ? (
                <img
                  src={playlist.cover_image_url || playlist.cover_image_path || ''}
                  alt={playlist.name}
                  className="w-full h-full object-cover rounded"
                />
              ) : (
                <svg className="w-5 h-5 text-ink-muted" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3" />
                </svg>
              )}
            </div>
            <div className="flex-1 min-w-0">
              <span className="text-[13px] font-medium text-ink truncate block">{playlist.name}</span>
              {playlist.description && (
                <span className="text-xs text-ink-muted truncate block">{playlist.description}</span>
              )}
            </div>
          </button>
        ))}
      </div>
    </section>
  );
}
