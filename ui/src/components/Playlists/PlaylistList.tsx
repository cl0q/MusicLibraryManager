/**
 * PlaylistList component - displays playlists grouped by category.
 *
 * Features:
 * - Groups playlists by category (Liked, Smart, Regular)
 * - Shows playlist metadata (name, track count, cover)
 * - Create new playlist button with form
 * - Click to navigate to detail view
 */

import { useState, useEffect } from 'react';
import {
  getPlaylists,
  createPlaylist,
  type Playlist,
} from '../../hooks/usePlaylists';

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
      await createPlaylist(
        newPlaylistName,
        newPlaylistDescription || undefined
      );
      setNewPlaylistName('');
      setNewPlaylistDescription('');
      setShowCreateForm(false);
      await loadPlaylists();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : 'Failed to create playlist'
      );
    }
  }

  // Group playlists by category
  const likedPlaylists = playlists.filter((p) => p.category === 'liked');
  const smartPlaylists = playlists.filter((p) => p.category === 'smart');
  const regularPlaylists = playlists.filter((p) => p.category === 'regular');

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-gray-400">Loading playlists...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-red-400">Error: {error}</div>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-8">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold text-white">Playlists</h1>
        <button
          onClick={() => setShowCreateForm(!showCreateForm)}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition"
        >
          {showCreateForm ? 'Cancel' : '+ Create Playlist'}
        </button>
      </div>

      {/* Create Playlist Form */}
      {showCreateForm && (
        <form
          onSubmit={handleCreatePlaylist}
          className="p-4 bg-gray-800 rounded-lg space-y-3"
        >
          <input
            type="text"
            placeholder="Playlist name"
            value={newPlaylistName}
            onChange={(e) => setNewPlaylistName(e.target.value)}
            className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:outline-none focus:border-blue-500"
            autoFocus
          />
          <input
            type="text"
            placeholder="Description (optional)"
            value={newPlaylistDescription}
            onChange={(e) => setNewPlaylistDescription(e.target.value)}
            className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:outline-none focus:border-blue-500"
          />
          <button
            type="submit"
            className="w-full px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded transition"
          >
            Create
          </button>
        </form>
      )}

      {/* Liked Playlists */}
      {likedPlaylists.length > 0 && (
        <section>
          <h2 className="text-xl font-semibold text-gray-300 mb-3">
            Liked Playlists
          </h2>
          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
            {likedPlaylists.map((playlist) => (
              <PlaylistCard
                key={playlist.id}
                playlist={playlist}
                onClick={() => onSelectPlaylist(playlist)}
              />
            ))}
          </div>
        </section>
      )}

      {/* Smart Playlists */}
      {smartPlaylists.length > 0 && (
        <section>
          <h2 className="text-xl font-semibold text-gray-300 mb-3">
            Smart Playlists
          </h2>
          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
            {smartPlaylists.map((playlist) => (
              <PlaylistCard
                key={playlist.id}
                playlist={playlist}
                onClick={() => onSelectPlaylist(playlist)}
              />
            ))}
          </div>
        </section>
      )}

      {/* Regular Playlists */}
      {regularPlaylists.length > 0 && (
        <section>
          <h2 className="text-xl font-semibold text-gray-300 mb-3">
            My Playlists
          </h2>
          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
            {regularPlaylists.map((playlist) => (
              <PlaylistCard
                key={playlist.id}
                playlist={playlist}
                onClick={() => onSelectPlaylist(playlist)}
              />
            ))}
          </div>
        </section>
      )}

      {playlists.length === 0 && (
        <div className="text-center text-gray-400 py-12">
          No playlists yet. Create your first playlist to get started!
        </div>
      )}
    </div>
  );
}

interface PlaylistCardProps {
  playlist: Playlist;
  onClick: () => void;
}

function PlaylistCard({ playlist, onClick }: PlaylistCardProps) {
  return (
    <div
      onClick={onClick}
      className="group cursor-pointer bg-gray-800 hover:bg-gray-750 rounded-lg p-4 transition"
    >
      {/* Cover Image */}
      <div className="aspect-square bg-gray-700 rounded-lg mb-3 flex items-center justify-center overflow-hidden">
        {playlist.cover_image_url || playlist.cover_image_path ? (
          <img
            src={playlist.cover_image_url || playlist.cover_image_path || ''}
            alt={playlist.name}
            className="w-full h-full object-cover"
          />
        ) : (
          <svg
            className="w-12 h-12 text-gray-500"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3"
            />
          </svg>
        )}
      </div>

      {/* Playlist Info */}
      <h3 className="font-semibold text-white truncate group-hover:text-blue-400 transition">
        {playlist.name}
      </h3>
      {playlist.description && (
        <p className="text-sm text-gray-400 truncate mt-1">
          {playlist.description}
        </p>
      )}
    </div>
  );
}
