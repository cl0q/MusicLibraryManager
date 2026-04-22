import { useState, useEffect } from 'react';
import {
  getPlaylists,
  getPlaylistTracks,
  createPlaylist,
  type Playlist,
  type Track as PlaylistTrack,
} from '../../hooks/usePlaylists';
import { ImportModal } from '../PlaylistImport/ImportModal';

/**
 * Playlist grid — Solar mock (screens.jsx::PlaylistsScreen):
 * - Sticky header with title, totals, Import + New playlist buttons.
 * - Pinned section first, then All playlists section.
 * - Cards: square cover art (~164px) with source badge overlay, name,
 *   count · duration · updated in monospace.
 */

interface PlaylistListProps {
  onSelectPlaylist: (playlist: Playlist) => void;
}

// Cache of lightweight playlist stats so cards can show totals without
// rerunning queries for every re-render.
type PlaylistStats = { tracks: number; durationSec: number };

export default function PlaylistList({ onSelectPlaylist }: PlaylistListProps) {
  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [stats, setStats] = useState<Map<number, PlaylistStats>>(new Map());
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
      // Fire stats loads in parallel; they're decorative so we swallow errors.
      const entries = await Promise.all(
        data.map(async (p) => {
          try {
            const tracks = await getPlaylistTracks(p.id);
            const durationSec = tracks.reduce(
              (sum: number, t: PlaylistTrack) => sum + (t.metadata.duration ?? 0),
              0,
            );
            return [p.id, { tracks: tracks.length, durationSec }] as const;
          } catch {
            return [p.id, { tracks: 0, durationSec: 0 }] as const;
          }
        }),
      );
      setStats(new Map(entries));
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

  const pinned = playlists.filter((p) => p.is_pinned);
  const rest = playlists.filter((p) => !p.is_pinned);
  const totalTracks = Array.from(stats.values()).reduce((s, v) => s + v.tracks, 0);
  const totalDuration = Array.from(stats.values()).reduce((s, v) => s + v.durationSec, 0);

  return (
    <div className="flex flex-col h-full overflow-hidden" style={{ fontFamily: 'var(--font-ui)' }}>
      {/* Header */}
      <div className="flex items-center gap-3 px-4 py-3 border-b border-edge-subtle shrink-0">
        <span className="text-[13px] font-semibold text-ink">Playlists</span>
        <span className="text-[11px] text-ink-muted">
          {playlists.length} · {totalTracks} tracks · {formatDurationLong(totalDuration)}
        </span>
        <div className="flex-1" />
        <button
          onClick={() => setShowImportModal(true)}
          className="flex items-center gap-1.5 h-7 px-3 rounded-[5px] bg-raised border border-edge text-[12px] text-ink-secondary hover:text-ink hover:bg-overlay transition-colors"
        >
          <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" strokeWidth={1.7} viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v8m0 0l-3-3m3 3l3-3M4 14v4a2 2 0 002 2h12a2 2 0 002-2v-4" />
          </svg>
          <span>Import</span>
        </button>
        <button
          onClick={() => setShowCreateForm((v) => !v)}
          className="flex items-center gap-1.5 h-7 px-3 rounded-[5px] bg-accent text-base text-[12px] font-semibold hover:bg-accent-bright transition-colors"
          style={{ color: 'var(--color-base)' }}
        >
          <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14M5 12h14" />
          </svg>
          <span>{showCreateForm ? 'Cancel' : 'New playlist'}</span>
        </button>
      </div>

      <div className="flex-1 overflow-auto px-4 py-4 min-h-0">
        {showCreateForm && (
          <form
            onSubmit={handleCreatePlaylist}
            className="bg-surface border border-edge rounded-md p-3 space-y-2 mb-4 max-w-sm"
          >
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
              className="w-full px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright rounded transition-colors"
              style={{ color: 'var(--color-base)' }}
            >
              Create
            </button>
          </form>
        )}

        {pinned.length > 0 && (
          <section className="mb-6">
            <SectionLabel>Pinned</SectionLabel>
            <PlaylistGrid items={pinned} stats={stats} onSelect={onSelectPlaylist} />
          </section>
        )}
        <section>
          <SectionLabel>All playlists</SectionLabel>
          {rest.length === 0 ? (
            <p className="text-[12px] text-ink-muted">No playlists yet.</p>
          ) : (
            <PlaylistGrid items={rest} stats={stats} onSelect={onSelectPlaylist} />
          )}
        </section>
      </div>

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

/* ── Atoms ─────────────────────────────────────────────── */

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <div
      className="text-[10px] text-ink-muted uppercase tracking-[0.1em] font-semibold mb-2.5"
    >
      {children}
    </div>
  );
}

function PlaylistGrid({
  items,
  stats,
  onSelect,
}: {
  items: Playlist[];
  stats: Map<number, { tracks: number; durationSec: number }>;
  onSelect: (p: Playlist) => void;
}) {
  return (
    <div
      className="grid gap-3.5"
      style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))' }}
    >
      {items.map((p) => (
        <PlaylistCard key={p.id} pl={p} stat={stats.get(p.id)} onSelect={onSelect} />
      ))}
    </div>
  );
}

function PlaylistCard({
  pl,
  stat,
  onSelect,
}: {
  pl: Playlist;
  stat: { tracks: number; durationSec: number } | undefined;
  onSelect: (p: Playlist) => void;
}) {
  const source = sourceFromPlaylist(pl);
  const updated = relativeUpdated(pl.date_created);

  return (
    <button
      onClick={() => onSelect(pl)}
      className="group text-left bg-surface border border-edge rounded-md p-2 hover:border-accent/40 transition-colors"
    >
      <div className="relative aspect-square rounded overflow-hidden mb-2 bg-raised">
        {pl.cover_image_url || pl.cover_image_path ? (
          <img
            src={pl.cover_image_url || pl.cover_image_path || ''}
            alt={pl.name}
            className="w-full h-full object-cover"
            loading="lazy"
          />
        ) : (
          <SeededCover seed={pl.id} />
        )}
        {source && (
          <span
            className="absolute top-1.5 left-1.5 px-1.5 py-[2px] rounded-[3px] text-[9px] uppercase tracking-[0.06em] font-semibold"
            style={{
              background: 'rgba(0,0,0,0.55)',
              color: source.color,
            }}
          >
            {source.label}
          </span>
        )}
        <span
          className="absolute bottom-1.5 right-1.5 w-7 h-7 rounded-full flex items-center justify-center text-accent opacity-0 group-hover:opacity-100 transition-opacity"
          style={{ background: 'rgba(0,0,0,0.6)' }}
        >
          <svg className="w-[13px] h-[13px]" fill="currentColor" viewBox="0 0 24 24">
            <path d="M7 5v14l12-7z" />
          </svg>
        </span>
      </div>
      <div className="text-[12.5px] font-medium text-ink truncate">{pl.name}</div>
      <div
        className="text-[10.5px] text-ink-muted tabular-nums"
        style={{ fontFamily: 'var(--font-mono)' }}
      >
        {stat ? `${stat.tracks} · ${formatDurationLong(stat.durationSec)}` : '— tracks'} · {updated}
      </div>
    </button>
  );
}

/* ── Helpers ───────────────────────────────────────────── */

function sourceFromPlaylist(p: Playlist): { label: string; color: string } | null {
  if (!p.source_id && !p.external_id) return null;
  // We don't have a denormalized source name field; lean on external_id prefix
  // or conservative defaults. 'spotify' maps to emerald, everything else orange.
  const hint = (p.external_id || '').toLowerCase();
  if (hint.includes('spotify') || p.source_id === 1) {
    return { label: 'Spotify', color: 'var(--color-emerald, #34d399)' };
  }
  if (hint.includes('soundcloud') || p.source_id === 2) {
    return { label: 'SoundCloud', color: '#ff9d4a' };
  }
  return null;
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

function formatDurationLong(secs: number): string {
  if (!secs || secs <= 0) return '0m';
  const hours = Math.floor(secs / 3600);
  const minutes = Math.floor((secs % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, '0')}m`;
  return `${minutes}m`;
}

/**
 * Deterministic gradient cover based on a seed — mirrors the Art atom from
 * the Solar components mock so playlists without custom artwork still get
 * palette-appropriate placeholders.
 */
function SeededCover({ seed }: { seed: number }) {
  const palettes: [string, string][] = [
    ['#d4940c', '#6a4200'],
    ['#2a6f9e', '#0d2a3f'],
    ['#b8541e', '#4a1e08'],
    ['#4a5d7e', '#1a1f2e'],
    ['#8a6d3b', '#2a2018'],
    ['#3d5a4a', '#0f1a14'],
    ['#6b4d8a', '#25182f'],
    ['#c84a4a', '#3a1414'],
    ['#5a8a7d', '#142622'],
  ];
  const [a, b] = palettes[Math.abs(seed) % palettes.length];
  const pattern = Math.abs(seed) % 4;
  const bg =
    pattern === 0
      ? `linear-gradient(135deg, ${a}, ${b})`
      : pattern === 1
        ? `radial-gradient(circle at 30% 30%, ${a}, ${b})`
        : pattern === 2
          ? `linear-gradient(180deg, ${a} 40%, ${b} 40%)`
          : `conic-gradient(from 45deg, ${a}, ${b}, ${a})`;
  return <div className="w-full h-full" style={{ background: bg }} />;
}
