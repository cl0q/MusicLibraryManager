import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import { mockIPC } from '@tauri-apps/api/mocks';
import MoreInfoPanel from '../../src/components/MoreInfo/MoreInfoPanel';
import type { Track } from '../../src/types/library';

const mockTrack: Track = {
  id: 1,
  metadata: {
    title: 'More Info Test Song',
    artist: 'More Info Artist',
    album_artist: 'More Info Artist',
    album: 'More Info Album',
    genre: 'Electronic',
    year: 2024,
    bitrate: 248000,
    duration: 300,
    format: 'aac',
    original_path: '/original/more_info_test.m4a',
  },
  organized_path: '/library/M/More Info Artist/More Info Album/More Info Test Song.m4a',
  is_duplicate: false,
  date_added: '2024-01-01T00:00:00Z',
};

describe('MoreInfoPanel', () => {
  beforeEach(() => {
    mockIPC((cmd) => {
      if (cmd === 'get_track_analysis') {
        return {
          ffprobe: {
            format: { format_name: 'mov,mp4,m4a,3gp,3g2,mj2', duration: '300.0', bit_rate: '248000' },
            streams: [{ codec_name: 'aac', channels: 2, sample_rate: '44100' }],
          },
        };
      }
      return null;
    });
  });

  it('does not render when isOpen is false', () => {
    render(
      <MoreInfoPanel track={mockTrack} isOpen={false} onClose={vi.fn()} />
    );
    // Panel is hidden when closed — track title should not appear
    expect(screen.queryByText('More Info Test Song')).not.toBeInTheDocument();
  });

  it('renders the panel when isOpen is true', () => {
    render(<MoreInfoPanel track={mockTrack} isOpen={true} onClose={vi.fn()} />);
    // Panel must render when open — track title is shown in the header section
    expect(screen.getByText('More Info Test Song')).toBeInTheDocument();
  });

  it('renders nothing when track is null', () => {
    const { container } = render(
      <MoreInfoPanel track={null} isOpen={true} onClose={vi.fn()} />
    );
    expect(container.firstChild).toBeNull();
  });
});
