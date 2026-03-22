import { describe, it, expect, vi } from 'vitest';
import { render } from '@testing-library/react';
import { DownloadProgress } from '../../src/components/Downloads/DownloadProgress';

// Mock @tauri-apps/api/event to prevent "transformCallback is not a function" errors.
// DownloadProgress uses listen() which requires full Tauri IPC internals that aren't
// available in happy-dom even after mockWindows.
vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
  emit: vi.fn().mockResolvedValue(undefined),
  once: vi.fn().mockResolvedValue(() => {}),
}));

describe('DownloadProgress', () => {
  it('renders nothing when isDownloading is false', () => {
    const { container } = render(<DownloadProgress isDownloading={false} />);
    // Component returns null when not downloading
    expect(container.firstChild).toBeNull();
  });

  it('renders nothing when isDownloading is true but no event received yet', () => {
    // Component returns null until a download:progress event is received.
    // Event-based components don't render until the first event fires.
    const { container } = render(<DownloadProgress isDownloading={true} />);
    // Initial state: no progress event yet, component renders null
    expect(container.firstChild).toBeNull();
  });
});
