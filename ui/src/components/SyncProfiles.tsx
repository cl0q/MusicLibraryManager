/**
 * SyncProfiles component - manages sync profiles for device synchronization.
 *
 * Features:
 * - List sync profiles with metadata (name, output folder, track count)
 * - Create new profile form with name and output folder fields
 * - Delete profile with confirmation
 * - Sync button per profile (navigates to preview or triggers callback)
 * - Card-based layout consistent with PlaylistList component
 */

import React, { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/tauri';

export interface SyncProfileDto {
  id: number;
  name: string;
  output_folder: string;
  track_count: number;
  manual_track_count: number;
  playlist_count: number;
  rule_count: number;
  date_created: string;
  date_modified: string;
}

interface SyncProfilesProps {
  onSelectProfile: (profile: SyncProfileDto) => void;
}

export default function SyncProfiles({ onSelectProfile }: SyncProfilesProps) {
  const [profiles, setProfiles] = useState<SyncProfileDto[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreateForm, setShowCreateForm] = useState(false);
  const [newProfileName, setNewProfileName] = useState('');
  const [newOutputFolder, setNewOutputFolder] = useState('');
  const [deleteConfirm, setDeleteConfirm] = useState<number | null>(null);

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
      setError(
        err instanceof Error ? err.message : 'Failed to create sync profile'
      );
    }
  }

  async function handleDeleteProfile(profileId: number) {
    try {
      await invoke('delete_sync_profile', { profileId });
      setDeleteConfirm(null);
      await loadProfiles();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : 'Failed to delete sync profile'
      );
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="text-gray-400">Loading sync profiles...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full space-y-4">
        <div className="text-red-400">Error: {error}</div>
        <button
          onClick={() => loadProfiles()}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition"
        >
          Retry
        </button>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold text-white">Sync Profiles</h1>
        <button
          onClick={() => setShowCreateForm(!showCreateForm)}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition"
        >
          {showCreateForm ? 'Cancel' : '+ Create Profile'}
        </button>
      </div>

      {/* Create Profile Form */}
      {showCreateForm && (
        <form
          onSubmit={handleCreateProfile}
          className="p-4 bg-gray-800 rounded-lg space-y-3"
        >
          <div>
            <label className="block text-sm font-medium text-gray-300 mb-1">
              Profile Name
            </label>
            <input
              type="text"
              placeholder="e.g., My iPod"
              value={newProfileName}
              onChange={(e) => setNewProfileName(e.target.value)}
              className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:outline-none focus:border-blue-500"
              autoFocus
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-300 mb-1">
              Output Folder
            </label>
            <input
              type="text"
              placeholder="e.g., /Volumes/IPOD"
              value={newOutputFolder}
              onChange={(e) => setNewOutputFolder(e.target.value)}
              className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:outline-none focus:border-blue-500"
            />
            <p className="text-xs text-gray-400 mt-1">
              Path to device mount point or local folder
            </p>
          </div>
          <button
            type="submit"
            disabled={!newProfileName.trim() || !newOutputFolder.trim()}
            className="w-full px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded transition disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Create Profile
          </button>
        </form>
      )}

      {/* Profile List */}
      {profiles.length > 0 ? (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {profiles.map((profile) => (
            <ProfileCard
              key={profile.id}
              profile={profile}
              onSync={() => onSelectProfile(profile)}
              onDelete={() => setDeleteConfirm(profile.id)}
              showDeleteConfirm={deleteConfirm === profile.id}
              onConfirmDelete={() => handleDeleteProfile(profile.id)}
              onCancelDelete={() => setDeleteConfirm(null)}
            />
          ))}
        </div>
      ) : (
        <div className="text-center text-gray-400 py-12">
          No sync profiles yet. Create your first profile to get started!
        </div>
      )}
    </div>
  );
}

interface ProfileCardProps {
  profile: SyncProfileDto;
  onSync: () => void;
  onDelete: () => void;
  showDeleteConfirm: boolean;
  onConfirmDelete: () => void;
  onCancelDelete: () => void;
}

function ProfileCard({
  profile,
  onSync,
  onDelete,
  showDeleteConfirm,
  onConfirmDelete,
  onCancelDelete,
}: ProfileCardProps) {
  return (
    <div className="bg-gray-800 rounded-lg p-4 space-y-3">
      {/* Profile Header */}
      <div className="flex items-start justify-between">
        <div className="flex-1 min-w-0">
          <h3 className="font-semibold text-white text-lg truncate">
            {profile.name}
          </h3>
          <p className="text-sm text-gray-400 truncate mt-1">
            {profile.output_folder}
          </p>
        </div>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 gap-2 text-sm">
        <div className="bg-gray-700 rounded px-2 py-1">
          <div className="text-gray-400">Tracks</div>
          <div className="text-white font-semibold">{profile.track_count}</div>
        </div>
        <div className="bg-gray-700 rounded px-2 py-1">
          <div className="text-gray-400">Playlists</div>
          <div className="text-white font-semibold">
            {profile.playlist_count}
          </div>
        </div>
      </div>

      {/* Content Sources */}
      <div className="text-xs text-gray-400 space-y-1">
        {profile.manual_track_count > 0 && (
          <div>• {profile.manual_track_count} manual tracks</div>
        )}
        {profile.rule_count > 0 && (
          <div>• {profile.rule_count} filter rules</div>
        )}
        {profile.manual_track_count === 0 &&
          profile.playlist_count === 0 &&
          profile.rule_count === 0 && <div className="text-gray-500">Empty profile</div>}
      </div>

      {/* Actions */}
      {showDeleteConfirm ? (
        <div className="space-y-2">
          <p className="text-sm text-yellow-400">
            Delete this profile? This cannot be undone.
          </p>
          <div className="flex space-x-2">
            <button
              onClick={onConfirmDelete}
              className="flex-1 px-3 py-2 bg-red-600 hover:bg-red-700 text-white text-sm rounded transition"
            >
              Delete
            </button>
            <button
              onClick={onCancelDelete}
              className="flex-1 px-3 py-2 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <div className="flex space-x-2">
          <button
            onClick={onSync}
            className="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded transition"
          >
            Sync
          </button>
          <button
            onClick={onDelete}
            className="px-4 py-2 bg-gray-700 hover:bg-red-600 text-white rounded transition"
            title="Delete profile"
          >
            <svg
              className="w-5 h-5"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
          </button>
        </div>
      )}
    </div>
  );
}
