import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import {
  get_playlists_command,
  add_playlist_to_profile,
  remove_playlist_from_profile,
  get_profile_playlists,
  update_sync_profile_settings,
  type Playlist,
  type ProfilePlaylist,
} from '../utils/tauri-commands';

export interface SyncProfileDto {
  id: number;
  name: string;
  output_folder: string;
  playlist_path_prefix: string;
  track_count: number;
  manual_track_count: number;
  playlist_count: number;
  rule_count: number;
  date_created: string;
  date_modified: string;
}

interface SyncProfilesProps {
  /** Trigger sync preview for a profile (opens the diff screen). */
  onPreviewSync: (profile: SyncProfileDto) => void;
  /** Clean sync — clears sync state and forces a full re-push. */
  onCleanSync: (profile: SyncProfileDto) => void;
}

/**
 * Solar-style Sync Profiles screen. Device cards with usage/file-count lines,
 * status dot, attached-playlist chips, primary "Preview sync" action. Mock:
 * `screens.jsx` SyncScreen + DeviceCard.
 */
export default function SyncProfiles({ onPreviewSync, onCleanSync }: SyncProfilesProps) {
  const [profiles, setProfiles] = useState<SyncProfileDto[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreateForm, setShowCreateForm] = useState(false);
  const [newProfileName, setNewProfileName] = useState('');
  const [newOutputFolder, setNewOutputFolder] = useState('');
  const [deleteConfirm, setDeleteConfirm] = useState<number | null>(null);
  const [expandedProfile, setExpandedProfile] = useState<number | null>(null);

  useEffect(() => {
    loadProfiles();
  }, []);

  async function loadProfiles() {
    try {
      setLoading(true);
      setError(null);
      const data = await invoke<SyncProfileDto[]>('list_sync_profiles');
      setProfiles(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load sync profiles');
    } finally {
      setLoading(false);
    }
  }

  async function handleCreateProfile(e: React.FormEvent) {
    e.preventDefault();
    if (!newProfileName.trim() || !newOutputFolder.trim()) return;

    try {
      await invoke('create_sync_profile', {
        name: newProfileName,
        outputFolder: newOutputFolder,
      });
      setNewProfileName('');
      setNewOutputFolder('');
      setShowCreateForm(false);
      await loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create sync profile');
    }
  }

  async function handleDeleteProfile(profileId: number) {
    try {
      await invoke('delete_sync_profile', { profileId });
      setDeleteConfirm(null);
      if (expandedProfile === profileId) setExpandedProfile(null);
      await loadProfiles();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete sync profile');
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full" style={{ fontFamily: 'var(--font-ui)' }}>
        <span className="text-sm text-ink-muted">Loading sync profiles...</span>
      </div>
    );
  }

  if (error) {
    return (
      <div
        className="flex flex-col items-center justify-center h-full gap-3"
        style={{ fontFamily: 'var(--font-ui)' }}
      >
        <span className="text-sm text-rose-400">Error: {error}</span>
        <button
          onClick={() => loadProfiles()}
          className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors"
        >
          Retry
        </button>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full" style={{ fontFamily: 'var(--font-ui)' }}>
      {/* Header bar — mirrors mock SyncScreen header */}
      <div className="flex items-center gap-3 px-4 py-2.5 border-b border-edge-subtle shrink-0">
        <span className="text-[13px] font-semibold text-ink">Sync profiles</span>
        <span className="text-[11px] text-ink-muted">
          {profiles.length} {profiles.length === 1 ? 'profile' : 'profiles'}
        </span>
        <div className="flex-1" />
        <button
          onClick={() => setShowCreateForm(!showCreateForm)}
          className="flex items-center gap-1.5 h-[28px] px-3 rounded-[5px] bg-accent hover:bg-accent-bright text-base text-[12px] font-semibold transition-colors"
        >
          <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14M5 12h14" />
          </svg>
          {showCreateForm ? 'Cancel' : 'New profile'}
        </button>
      </div>

      {/* Create form (inline below header, does not replace the grid) */}
      {showCreateForm && (
        <div className="px-4 pt-3 shrink-0">
          <form
            onSubmit={handleCreateProfile}
            className="bg-surface border border-edge rounded-md p-3 space-y-2"
          >
            <div>
              <label className="text-[10px] font-semibold uppercase tracking-[0.08em] text-ink-muted block mb-1">
                Name
              </label>
              <input
                type="text"
                placeholder="e.g., My iPod"
                value={newProfileName}
                onChange={(e) => setNewProfileName(e.target.value)}
                className="w-full px-2.5 py-1.5 text-[12px] bg-raised border border-edge rounded-[5px] text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
                autoFocus
              />
            </div>
            <div>
              <label className="text-[10px] font-semibold uppercase tracking-[0.08em] text-ink-muted block mb-1">
                Output folder
              </label>
              <input
                type="text"
                placeholder="e.g., /Volumes/IPOD"
                value={newOutputFolder}
                onChange={(e) => setNewOutputFolder(e.target.value)}
                className="w-full px-2.5 py-1.5 text-[12px] bg-raised border border-edge rounded-[5px] text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
                style={{ fontFamily: 'var(--font-mono)' }}
              />
              <p className="text-[10px] text-ink-muted mt-1">
                Device mount point or local folder.
              </p>
            </div>
            <button
              type="submit"
              disabled={!newProfileName.trim() || !newOutputFolder.trim()}
              className="w-full h-[28px] rounded-[5px] bg-accent hover:bg-accent-bright text-base text-[12px] font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            >
              Create profile
            </button>
          </form>
        </div>
      )}

      {/* Device cards grid */}
      <div className="flex-1 overflow-auto p-4">
        {profiles.length === 0 ? (
          <div className="flex items-center justify-center h-full">
            <span className="text-sm text-ink-muted">No sync profiles yet.</span>
          </div>
        ) : (
          <div className="grid gap-3.5" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(340px, 1fr))' }}>
            {profiles.map((profile) => (
              <DeviceCard
                key={profile.id}
                profile={profile}
                expanded={expandedProfile === profile.id}
                onToggleExpand={() =>
                  setExpandedProfile(expandedProfile === profile.id ? null : profile.id)
                }
                onPreviewSync={() => onPreviewSync(profile)}
                onCleanSync={() => onCleanSync(profile)}
                onDelete={() => setDeleteConfirm(profile.id)}
                deleteConfirming={deleteConfirm === profile.id}
                onDeleteCancel={() => setDeleteConfirm(null)}
                onDeleteConfirm={() => handleDeleteProfile(profile.id)}
                onChanged={loadProfiles}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/* ── Device card ──────────────────────────────────────── */

interface DeviceCardProps {
  profile: SyncProfileDto;
  expanded: boolean;
  onToggleExpand: () => void;
  onPreviewSync: () => void;
  onCleanSync: () => void;
  onDelete: () => void;
  deleteConfirming: boolean;
  onDeleteCancel: () => void;
  onDeleteConfirm: () => void;
  onChanged: () => void;
}

function DeviceCard({
  profile,
  expanded,
  onToggleExpand,
  onPreviewSync,
  onCleanSync,
  onDelete,
  deleteConfirming,
  onDeleteCancel,
  onDeleteConfirm,
  onChanged,
}: DeviceCardProps) {
  const [attachedPlaylists, setAttachedPlaylists] = useState<ProfilePlaylist[]>([]);
  const [loadingChips, setLoadingChips] = useState(false);

  // Load attached playlists for the chip row (always, not just when expanded).
  useEffect(() => {
    let cancelled = false;
    setLoadingChips(true);
    get_profile_playlists(profile.id)
      .then((data) => {
        if (!cancelled) setAttachedPlaylists(data);
      })
      .catch(() => {
        /* non-fatal */
      })
      .finally(() => {
        if (!cancelled) setLoadingChips(false);
      });
    return () => {
      cancelled = true;
    };
  }, [profile.id, profile.playlist_count]);

  // Best guess at device type from output folder.
  const kind = guessDeviceKind(profile.output_folder);

  return (
    <div
      className="border border-edge rounded-md bg-surface p-3.5"
      style={{ fontFamily: 'var(--font-ui)' }}
    >
      {/* Top row: icon + name + status + edit */}
      <div className="flex items-center gap-3 mb-3">
        <div
          className="w-[38px] h-[38px] rounded-[5px] bg-raised flex items-center justify-center text-ink-secondary shrink-0"
          title={kind}
        >
          <DeviceIcon kind={kind} />
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-[13px] font-semibold text-ink truncate">{profile.name}</div>
          <div className="text-[11px] text-ink-muted flex items-center gap-1.5 mt-0.5">
            <StatusDot kind="ok" />
            <span className="truncate" style={{ fontFamily: 'var(--font-mono)' }}>
              {profile.output_folder}
            </span>
          </div>
        </div>
        <button
          onClick={onToggleExpand}
          className="w-[28px] h-[28px] rounded-[5px] bg-raised border border-edge text-ink-muted hover:text-ink hover:bg-overlay transition-colors flex items-center justify-center shrink-0"
          title={expanded ? 'Hide settings' : 'Edit'}
        >
          <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.7}>
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M10.3 2.5h3.4a1 1 0 011 1l.3 2a7.3 7.3 0 012.3 1.3l1.9-.8a1 1 0 011.2.4l1.7 3a1 1 0 01-.3 1.3l-1.6 1.2a7.3 7.3 0 010 2.6l1.6 1.2a1 1 0 01.3 1.3l-1.7 3a1 1 0 01-1.2.4l-1.9-.8A7.3 7.3 0 0115 19.5l-.3 2a1 1 0 01-1 1h-3.4a1 1 0 01-1-1l-.3-2a7.3 7.3 0 01-2.3-1.3l-1.9.8a1 1 0 01-1.2-.4l-1.7-3a1 1 0 01.3-1.3l1.6-1.2a7.3 7.3 0 010-2.6L2.2 9.3a1 1 0 01-.3-1.3l1.7-3a1 1 0 011.2-.4l1.9.8A7.3 7.3 0 019 4.5l.3-2a1 1 0 011-1zM12 9a3 3 0 100 6 3 3 0 000-6z"
            />
          </svg>
        </button>
      </div>

      {/* Stats row: tracks · playlists · manual · rules */}
      <div
        className="flex items-center gap-3 text-[11px] text-ink-muted mb-3 tabular-nums"
        style={{ fontFamily: 'var(--font-mono)' }}
      >
        <span>{profile.track_count} tracks</span>
        <span className="text-edge">·</span>
        <span>
          {profile.playlist_count} {profile.playlist_count === 1 ? 'playlist' : 'playlists'}
        </span>
        {profile.manual_track_count > 0 && (
          <>
            <span className="text-edge">·</span>
            <span>{profile.manual_track_count} manual</span>
          </>
        )}
        {profile.rule_count > 0 && (
          <>
            <span className="text-edge">·</span>
            <span>
              {profile.rule_count} {profile.rule_count === 1 ? 'rule' : 'rules'}
            </span>
          </>
        )}
      </div>

      {/* Attached playlist chips */}
      {!loadingChips && attachedPlaylists.length > 0 && (
        <div className="flex flex-wrap gap-1.5 mb-3">
          {attachedPlaylists.slice(0, 6).map((pl) => (
            <span
              key={pl.id}
              className="text-[10.5px] px-[7px] py-[2px] rounded-[3px] bg-raised border border-edge text-ink-secondary"
              title={`${pl.name} · ${pl.track_count} tracks`}
            >
              {pl.name}
            </span>
          ))}
          {attachedPlaylists.length > 6 && (
            <span className="text-[10.5px] px-[7px] py-[2px] rounded-[3px] bg-raised border border-edge text-ink-muted">
              +{attachedPlaylists.length - 6} more
            </span>
          )}
        </div>
      )}

      {/* Primary actions */}
      <div className="flex gap-1.5">
        <button
          onClick={onPreviewSync}
          className="flex-1 h-[28px] rounded-[5px] bg-accent hover:bg-accent-bright text-base text-[12px] font-semibold transition-colors flex items-center justify-center gap-1.5"
        >
          <svg className="w-[12px] h-[12px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.8}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M16 9h5V4M3 20v-5h5M3 15a9 9 0 0015.4 3.4M21 9a9 9 0 00-15.4-3.4" />
          </svg>
          Preview sync
        </button>
        <button
          onClick={onCleanSync}
          className="h-[28px] px-3 rounded-[5px] bg-raised border border-edge text-ink-secondary hover:text-ink hover:bg-overlay text-[11px] font-medium transition-colors"
          title="Clear sync state and resync all tracks"
        >
          Clean
        </button>
        <button
          onClick={onDelete}
          className="w-[28px] h-[28px] rounded-[5px] bg-raised border border-edge text-ink-muted hover:text-rose-400 hover:border-rose-500/40 transition-colors flex items-center justify-center"
          title="Delete profile"
        >
          <svg className="w-[13px] h-[13px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.7}>
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
            />
          </svg>
        </button>
      </div>

      {/* Inline delete confirmation */}
      {deleteConfirming && (
        <div className="mt-2 flex items-center gap-2 bg-rose-500/10 border border-rose-500/20 rounded px-2.5 py-1.5">
          <span className="text-[11px] text-rose-400 flex-1">Delete this profile?</span>
          <button
            onClick={onDeleteConfirm}
            className="px-2 py-0.5 text-[11px] font-semibold text-rose-400 hover:bg-rose-500/20 rounded transition-colors"
          >
            Delete
          </button>
          <button
            onClick={onDeleteCancel}
            className="px-2 py-0.5 text-[11px] text-ink-muted hover:text-ink rounded transition-colors"
          >
            Cancel
          </button>
        </div>
      )}

      {/* Expanded editor */}
      {expanded && (
        <ProfileDetail
          profileId={profile.id}
          initialPathPrefix={profile.playlist_path_prefix}
          attachedPlaylists={attachedPlaylists}
          onAttachedChange={(next) => setAttachedPlaylists(next)}
          onChanged={onChanged}
        />
      )}
    </div>
  );
}

/* ── Expanded profile detail (inline editor) ──────────── */

function ProfileDetail({
  profileId,
  initialPathPrefix,
  attachedPlaylists,
  onAttachedChange,
  onChanged,
}: {
  profileId: number;
  initialPathPrefix: string;
  attachedPlaylists: ProfilePlaylist[];
  onAttachedChange: (playlists: ProfilePlaylist[]) => void;
  onChanged: () => void;
}) {
  const [allPlaylists, setAllPlaylists] = useState<Playlist[]>([]);
  const [loading, setLoading] = useState(true);
  const [pathPrefix, setPathPrefix] = useState(initialPathPrefix);
  const [prefixDirty, setPrefixDirty] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    get_playlists_command()
      .then((all) => {
        if (!cancelled) setAllPlaylists(all);
      })
      .catch((err) => console.error('Failed to load playlists:', err))
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [profileId]);

  const attachedIds = new Set(attachedPlaylists.map((p) => p.id));
  const availablePlaylists = allPlaylists.filter((p) => !attachedIds.has(Number(p.id)));

  async function reloadAttached() {
    try {
      const data = await get_profile_playlists(profileId);
      onAttachedChange(data);
    } catch {
      /* non-fatal */
    }
  }

  async function handleAddPlaylist(playlistId: number) {
    try {
      await add_playlist_to_profile(profileId, playlistId);
      await reloadAttached();
      onChanged();
    } catch (err) {
      console.error('Failed to add playlist:', err);
    }
  }

  async function handleRemovePlaylist(playlistId: number) {
    try {
      await remove_playlist_from_profile(profileId, playlistId);
      await reloadAttached();
      onChanged();
    } catch (err) {
      console.error('Failed to remove playlist:', err);
    }
  }

  async function savePrefix() {
    await update_sync_profile_settings(profileId, pathPrefix);
    setPrefixDirty(false);
    onChanged();
  }

  return (
    <div className="mt-3 pt-3 border-t border-edge-subtle space-y-3">
      {/* Playlist path prefix */}
      <div>
        <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-ink-muted mb-1.5">
          Playlist path prefix
        </p>
        <div className="flex items-center gap-1.5">
          <input
            type="text"
            value={pathPrefix}
            onChange={(e) => {
              setPathPrefix(e.target.value);
              setPrefixDirty(true);
            }}
            onKeyDown={async (e) => {
              if (e.key === 'Enter' && prefixDirty) await savePrefix();
            }}
            placeholder="e.g. HDD0/"
            className="flex-1 px-2.5 py-1.5 text-[11px] bg-raised border border-edge rounded-[5px] text-ink placeholder:text-ink-muted focus:outline-none focus:border-accent/50"
            style={{ fontFamily: 'var(--font-mono)' }}
          />
          {prefixDirty && (
            <button
              onClick={savePrefix}
              className="px-2.5 py-1.5 text-[11px] font-semibold bg-accent hover:bg-accent-bright text-base rounded-[5px] transition-colors shrink-0"
            >
              Save
            </button>
          )}
        </div>
        <p className="text-[10px] text-ink-muted mt-1">
          Prepended to paths in .m3u8 playlists (e.g. for Rockbox devices).
        </p>
      </div>

      {/* Attached playlists management */}
      <div>
        <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-ink-muted mb-1.5">
          Playlists in profile
        </p>
        {attachedPlaylists.length > 0 ? (
          <div className="space-y-1">
            {attachedPlaylists.map((pl) => (
              <div
                key={pl.id}
                className="flex items-center justify-between gap-2 bg-raised/50 rounded px-2.5 py-1.5"
              >
                <div className="flex items-center gap-2 min-w-0">
                  <span className="text-[11px] text-ink truncate">{pl.name}</span>
                  <span
                    className="text-[10px] text-ink-muted tabular-nums shrink-0"
                    style={{ fontFamily: 'var(--font-mono)' }}
                  >
                    {pl.track_count} tracks
                  </span>
                </div>
                <button
                  onClick={() => handleRemovePlaylist(pl.id)}
                  className="text-ink-muted hover:text-rose-400 shrink-0 p-0.5 rounded hover:bg-rose-500/10 transition-colors"
                  title="Remove from profile"
                >
                  <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
            ))}
          </div>
        ) : (
          <p className="text-[10.5px] text-ink-muted italic">No playlists added yet.</p>
        )}
      </div>

      {/* Available playlists to add */}
      {!loading && availablePlaylists.length > 0 && (
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-ink-muted mb-1.5">
            Add playlist
          </p>
          <div className="space-y-1">
            {availablePlaylists.map((pl) => (
              <button
                key={pl.id}
                onClick={() => handleAddPlaylist(Number(pl.id))}
                className="w-full flex items-center justify-between gap-2 bg-raised/30 hover:bg-raised/60 rounded px-2.5 py-1.5 transition-colors text-left"
              >
                <div className="flex items-center gap-2 min-w-0">
                  <span className="text-[11px] text-ink-secondary truncate">{pl.name}</span>
                  <span
                    className="text-[10px] text-ink-muted tabular-nums shrink-0"
                    style={{ fontFamily: 'var(--font-mono)' }}
                  >
                    {pl.track_count} tracks
                  </span>
                  <span className="text-[10px] text-ink-muted shrink-0 uppercase tracking-[0.08em]">
                    {pl.category}
                  </span>
                </div>
                <span className="text-[10px] text-sky-400 shrink-0">+ Add</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

/* ── Atoms ────────────────────────────────────────────── */

function StatusDot({ kind }: { kind: 'ok' | 'active' | 'err' | 'warn' | 'off' }) {
  const colors: Record<typeof kind, string> = {
    ok: 'var(--color-emerald, #10b981)',
    active: 'var(--color-sky, #38bdf8)',
    err: 'var(--color-rose, #f43f5e)',
    warn: 'var(--color-accent, #b8541e)',
    off: 'var(--color-ink-muted, #93a1a1)',
  };
  return (
    <span
      className="inline-block w-1.5 h-1.5 rounded-full shrink-0"
      style={{ background: colors[kind] }}
    />
  );
}

type DeviceKind = 'usb' | 'folder' | 'app';

function guessDeviceKind(outputFolder: string): DeviceKind {
  const lower = outputFolder.toLowerCase();
  if (lower.startsWith('/volumes/') || lower.startsWith('/media/') || /^[a-z]:\\/.test(outputFolder)) {
    return 'usb';
  }
  return 'folder';
}

function DeviceIcon({ kind }: { kind: DeviceKind }) {
  const paths: Record<DeviceKind, string> = {
    usb: 'M12 20v-8m0 0l-3 3m3-3l3 3M12 12V4m0 0a2 2 0 100 4 2 2 0 000-4z',
    folder: 'M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V7z',
    app: 'M5 3h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2zm3 4h8m-8 4h8m-8 4h5',
  };
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round">
      <path d={paths[kind]} />
    </svg>
  );
}
