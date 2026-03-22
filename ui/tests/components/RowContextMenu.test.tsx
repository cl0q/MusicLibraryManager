import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render } from '@testing-library/react';
import { mockIPC } from '@tauri-apps/api/mocks';
import RowContextMenu from '../../src/components/LibraryTable/RowContextMenu';
import { TrackSelectionProvider } from '../../src/contexts/TrackSelectionContext';
import type { Track } from '../../src/types/library';

const mockTrack: Track = {
  id: 1,
  metadata: {
    title: 'Context Menu Song',
    artist: 'Context Menu Artist',
    album_artist: 'Context Menu Artist',
    album: 'Context Menu Album',
    genre: null,
    year: null,
    bitrate: 248000,
    duration: 180,
    format: 'aac',
    original_path: '/original/ctx.m4a',
  },
  organized_path: '/library/C/Context Menu Artist/Context Menu Song.m4a',
  is_duplicate: false,
  date_added: null,
};

// RowContextMenu calls useTrackSelection, which requires TrackSelectionProvider
function renderWithProvider(ui: React.ReactElement) {
  return render(<TrackSelectionProvider>{ui}</TrackSelectionProvider>);
}

describe('RowContextMenu', () => {
  beforeEach(() => {
    mockIPC((cmd) => {
      if (cmd === 'get_playlists_command') return [];
      if (cmd === 'list_sync_profiles') return [];
      if (cmd === 'get_library_config') return { root_path: '/library', download_destination: '.mlm_staging', scan_folders: [], library_id: null, configured: true };
      return null;
    });
  });

  it('renders without crashing when given a track', () => {
    const { container } = renderWithProvider(
      <RowContextMenu
        track={mockTrack}
        onConfirm={vi.fn()}
        onOpenMoreInfo={vi.fn()}
      />
    );
    expect(container).toBeTruthy();
  });

  it('renders without crashing when track is null', () => {
    const { container } = renderWithProvider(
      <RowContextMenu
        track={null}
        onConfirm={vi.fn()}
      />
    );
    // Component returns null when track is null — container wrapper is still truthy
    expect(container).toBeTruthy();
  });

  it('renders without crashing for a remote track (no organized_path)', () => {
    const remoteTrack: Track = { ...mockTrack, organized_path: null };
    const { container } = renderWithProvider(
      <RowContextMenu
        track={remoteTrack}
        onConfirm={vi.fn()}
      />
    );
    expect(container).toBeTruthy();
  });
});
