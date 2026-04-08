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
  onSelectProfile: (profile: SyncProfileDto) => void;
  onCleanSync: (profile: SyncProfileDto) => void;
}

export default function SyncProfiles({ onSelectProfile, onCleanSync }: SyncProfilesProps) {
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
      <div className="flex items-center justify-center h-full">
        <span className="text-sm text-ink-muted">Loading sync profiles...</span>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full gap-3">
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
    <div className="p-4 space-y-4 max-w-2xl">
      <div className="flex items-center justify-between">
        <h1 className="text-xs font-semibold uppercase tracking-wide text-ink-secondary">Sync Profiles</h1>
        <button
          onClick={() => setShowCreateForm(!showCreateForm)}
          className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors"
        >
          {showCreateForm ? 'Cancel' : '+ Create'}
        </button>
      </div>

      {showCreateForm && (
        <form onSubmit={handleCreateProfile} className="bg-surface border border-edge rounded-lg p-3 space-y-2">
          <div>
            <label className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted block mb-1">Name</label>
            <input
              type="text"
              placeholder="e.g., My iPod"
              value={newProfileName}
              onChange={(e) => setNewProfileName(e.target.value)}
              className="w-full px-3 py-1.5 text-[13px] bg-raised border border-edge rounded text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
              autoFocus
            />
          </div>
          <div>
            <label className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted block mb-1">Output Folder</label>
            <input
              type="text"
              placeholder="e.g., /Volumes/IPOD"
              value={newOutputFolder}
              onChange={(e) => setNewOutputFolder(e.target.value)}
              className="w-full px-3 py-1.5 text-[13px] bg-raised border border-edge rounded text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
            />
            <p className="text-[11px] text-ink-muted mt-1">Path to device or local folder</p>
          </div>
          <button
            type="submit"
            disabled={!newProfileName.trim() || !newOutputFolder.trim()}
            className="w-full px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Create Profile
          </button>
        </form>
      )}

      {profiles.length > 0 ? (
        <div className="space-y-2">
          {profiles.map((profile) => (
            <div key={profile.id} className="bg-surface border border-edge rounded-lg">
              <div className="p-3">
                <div className="flex items-start justify-between gap-3">
                  <button
                    className="flex-1 min-w-0 text-left"
                    onClick={() => setExpandedProfile(expandedProfile === profile.id ? null : profile.id)}
                  >
                    <span className="text-sm font-medium text-ink">{profile.name}</span>
                    <p className="text-xs text-ink-muted truncate mt-0.5">{profile.output_folder}</p>
                  </button>
                  <div className="flex items-center gap-1.5 shrink-0">
                    <button
                      onClick={() => onCleanSync(profile)}
                      className="px-2.5 py-1 text-xs font-medium text-ink-muted hover:text-ink hover:bg-raised border border-edge rounded transition-colors"
                      title="Clear sync state and resync all tracks"
                    >
                      Clean
                    </button>
                    <button
                      onClick={() => onSelectProfile(profile)}
                      className="px-2.5 py-1 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors"
                    >
                      Sync
                    </button>
                    <button
                      onClick={() => setDeleteConfirm(profile.id)}
                      className="p-1 text-ink-muted hover:text-rose-400 hover:bg-rose-500/10 rounded transition-colors"
                      title="Delete"
                    >
                      <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                      </svg>
                    </button>
                  </div>
                </div>

                <div className="flex items-center gap-3 mt-2 text-[11px] text-ink-muted">
                  <span className="tabular-nums">{profile.track_count} tracks</span>
                  <span className="tabular-nums">{profile.playlist_count} playlists</span>
                  {profile.manual_track_count > 0 && <span className="tabular-nums">{profile.manual_track_count} manual</span>}
                  {profile.rule_count > 0 && <span className="tabular-nums">{profile.rule_count} rules</span>}
                  <button
                    onClick={() => setExpandedProfile(expandedProfile === profile.id ? null : profile.id)}
                    className="ml-auto text-sky-400 hover:text-sky-300"
                  >
                    {expandedProfile === profile.id ? 'Collapse' : 'Edit'}
                  </button>
                </div>

                {deleteConfirm === profile.id && (
                  <div className="mt-2 flex items-center gap-2 bg-rose-500/10 border border-rose-500/20 rounded px-3 py-2">
                    <span className="text-xs text-rose-400 flex-1">Delete this profile?</span>
                    <button onClick={() => handleDeleteProfile(profile.id)} className="px-2 py-0.5 text-xs font-medium text-rose-400 hover:bg-rose-500/20 rounded transition-colors">Delete</button>
                    <button onClick={() => setDeleteConfirm(null)} className="px-2 py-0.5 text-xs text-ink-muted hover:text-ink rounded transition-colors">Cancel</button>
                  </div>
                )}
              </div>

              {expandedProfile === profile.id && (
                <ProfileDetail profileId={profile.id} initialPathPrefix={profile.playlist_path_prefix} onChanged={loadProfiles} />
              )}
            </div>
          ))}
        </div>
      ) : (
        <div className="flex items-center justify-center py-12">
          <span className="text-sm text-ink-muted">No sync profiles yet</span>
        </div>
      )}
    </div>
  );
}

function ProfileDetail({ profileId, initialPathPrefix, onChanged }: { profileId: number; initialPathPrefix: string; onChanged: () => void }) {
  const [attachedPlaylists, setAttachedPlaylists] = useState<ProfilePlaylist[]>([]);
  const [allPlaylists, setAllPlaylists] = useState<Playlist[]>([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);
  const [pathPrefix, setPathPrefix] = useState(initialPathPrefix);
  const [prefixDirty, setPrefixDirty] = useState(false);

  useEffect(() => {
    loadData();
  }, [profileId]);

  async function loadData() {
    setLoading(true);
    try {
      const [attached, all] = await Promise.all([
        get_profile_playlists(profileId),
        get_playlists_command(),
      ]);
      setAttachedPlaylists(attached);
      setAllPlaylists(all);
    } catch (err) {
      console.error("Failed to load profile detail:", err);
    } finally {
      setLoading(false);
    }
  }

  const attachedIds = new Set(attachedPlaylists.map((p) => p.id));
  const availablePlaylists = allPlaylists.filter((p) => !attachedIds.has(Number(p.id)));

  async function handleAddPlaylist(playlistId: number) {
    setAdding(true);
    try {
      await add_playlist_to_profile(profileId, playlistId);
      await loadData();
      onChanged();
    } catch (err) {
      console.error("Failed to add playlist:", err);
    } finally {
      setAdding(false);
    }
  }

  async function handleRemovePlaylist(playlistId: number) {
    try {
      await remove_playlist_from_profile(profileId, playlistId);
      await loadData();
      onChanged();
    } catch (err) {
      console.error("Failed to remove playlist:", err);
    }
  }

  if (loading) {
    return (
      <div className="px-3 pb-3 pt-0">
        <div className="border-t border-edge-subtle pt-3">
          <span className="text-[11px] text-ink-muted">Loading...</span>
        </div>
      </div>
    );
  }

  return (
    <div className="px-3 pb-3 pt-0">
      <div className="border-t border-edge-subtle pt-3 space-y-3">
        {/* Playlist path prefix */}
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-wide text-ink-muted mb-1.5">
            Playlist Path Prefix
          </p>
          <div className="flex items-center gap-2">
            <input
              type="text"
              value={pathPrefix}
              onChange={(e) => { setPathPrefix(e.target.value); setPrefixDirty(true); }}
              onKeyDown={async (e) => {
                if (e.key === "Enter" && prefixDirty) {
                  await update_sync_profile_settings(profileId, pathPrefix);
                  setPrefixDirty(false);
                  onChanged();
                }
              }}
              placeholder="e.g. HDD0/"
              className="flex-1 px-2.5 py-1.5 text-xs bg-raised border border-edge rounded text-ink placeholder:text-ink-muted focus:outline-none focus:border-accent/50 font-mono"
            />
            {prefixDirty && (
              <button
                onClick={async () => {
                  await update_sync_profile_settings(profileId, pathPrefix);
                  setPrefixDirty(false);
                  onChanged();
                }}
                className="px-2.5 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded transition-colors shrink-0"
              >
                Save
              </button>
            )}
          </div>
          <p className="text-[10px] text-ink-muted mt-1">
            Prepended to all paths in .m3u8 playlists (e.g. for Rockbox devices)
          </p>
        </div>

        {/* Attached playlists */}
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-wide text-ink-muted mb-1.5">
            Playlists in Profile
          </p>
          {attachedPlaylists.length > 0 ? (
            <div className="space-y-1">
              {attachedPlaylists.map((pl) => (
                <div key={pl.id} className="flex items-center justify-between gap-2 bg-raised/50 rounded px-2.5 py-1.5">
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="text-xs text-ink truncate">{pl.name}</span>
                    <span className="text-[10px] text-ink-muted tabular-nums shrink-0">{pl.track_count} tracks</span>
                  </div>
                  <button
                    onClick={() => handleRemovePlaylist(pl.id)}
                    className="text-ink-muted hover:text-rose-400 shrink-0 p-0.5 rounded hover:bg-rose-500/10 transition-colors"
                    title="Remove from profile"
                  >
                    <svg className="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-[11px] text-ink-muted italic">No playlists added yet</p>
          )}
        </div>

        {/* Add playlist */}
        {availablePlaylists.length > 0 && (
          <div>
            <p className="text-[10px] font-semibold uppercase tracking-wide text-ink-muted mb-1.5">
              Add Playlist
            </p>
            <div className="space-y-1">
              {availablePlaylists.map((pl) => (
                <button
                  key={pl.id}
                  onClick={() => handleAddPlaylist(Number(pl.id))}
                  disabled={adding}
                  className="w-full flex items-center justify-between gap-2 bg-raised/30 hover:bg-raised/60 rounded px-2.5 py-1.5 transition-colors disabled:opacity-50 text-left"
                >
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="text-xs text-ink-secondary truncate">{pl.name}</span>
                    <span className="text-[10px] text-ink-muted tabular-nums shrink-0">{pl.track_count} tracks</span>
                    <span className="text-[10px] text-ink-muted shrink-0">{pl.category}</span>
                  </div>
                  <span className="text-[10px] text-sky-400 shrink-0">+ Add</span>
                </button>
              ))}
            </div>
          </div>
        )}

        {availablePlaylists.length === 0 && allPlaylists.length === 0 && (
          <p className="text-[11px] text-ink-muted">
            No playlists found. Sync from Spotify/SoundCloud or create a playlist first.
          </p>
        )}
      </div>
    </div>
  );
}
