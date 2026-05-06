/**
 * Phase 29 Plan 03: MiniPlayer component tests.
 *
 * Verifies the locked design contracts (D-numbers refer to 29-CONTEXT.md):
 *
 *  - D-15 status==='idle' renders nothing (no startup chrome, returns null)
 *  - D-16 layout: title, artist, play/pause toggle, time display
 *  - D-16/D-23 status==='error' replaces title/artist with error message; progress hidden
 *  - D-17 progress bar click seeks; click position clamped to [0, 1]
 *  - D-18 NO volume slider / NO <input type="range"> anywhere
 *  - data-testid="mini-player" on root for RTL discovery
 *  - title fallback "Unknown track" when metadata.title is empty
 *  - artist fallback "Unknown artist" when metadata.artist is empty
 *  - time format m:ss with tabular-nums; fallback "-- / --" while loading
 *
 * The component subscribes to PlaybackContext via usePlayback(); we drive
 * state by mocking the context module rather than spinning a full provider —
 * this keeps tests focused on the rendering contract, not playback wiring.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import type { Track } from "../../../src/types/library";

// Mock the PlaybackContext module so MiniPlayer's usePlayback() returns
// whatever we configure per-test. This lets us drive state directly without
// instantiating real audio elements / providers.
const mockUsePlayback = vi.fn();
vi.mock("../../../src/contexts/PlaybackContext", () => ({
  usePlayback: () => mockUsePlayback(),
}));

import MiniPlayer from "../../../src/components/MiniPlayer/MiniPlayer";

function makeTrack(overrides: Partial<Track["metadata"]> = {}): Track {
  return {
    id: 1,
    metadata: {
      artist: "Test Artist",
      album_artist: "Test Artist",
      album: "Test Album",
      title: "Test Song",
      genre: null,
      year: null,
      bitrate: 320000,
      duration: 180,
      format: "mp3",
      original_path: "/x.mp3",
      ...overrides,
    },
    organized_path: "/library/track.mp3",
    is_duplicate: false,
    date_added: null,
  };
}

interface PlaybackStub {
  currentTrack: Track | null;
  status: "idle" | "loading" | "playing" | "paused" | "error";
  position: number;
  duration: number;
  error: string | null;
  play: ReturnType<typeof vi.fn>;
  pause: ReturnType<typeof vi.fn>;
  togglePlayPause: ReturnType<typeof vi.fn>;
  seek: ReturnType<typeof vi.fn>;
  stop: ReturnType<typeof vi.fn>;
}

function makeStub(overrides: Partial<PlaybackStub> = {}): PlaybackStub {
  return {
    currentTrack: makeTrack(),
    status: "playing",
    position: 0,
    duration: 180,
    error: null,
    play: vi.fn(),
    pause: vi.fn(),
    togglePlayPause: vi.fn(),
    seek: vi.fn(),
    stop: vi.fn(),
    ...overrides,
  };
}

beforeEach(() => {
  mockUsePlayback.mockReset();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("MiniPlayer — D-15 idle visibility", () => {
  it("renders nothing when status === 'idle'", () => {
    mockUsePlayback.mockReturnValue(makeStub({ status: "idle", currentTrack: null }));
    const { container } = render(<MiniPlayer />);
    expect(container.firstChild).toBeNull();
    expect(screen.queryByTestId("mini-player")).toBeNull();
  });
});

describe("MiniPlayer — D-16 layout while playing", () => {
  it("renders the mini-bar with title, artist, time display, and play/pause control", () => {
    mockUsePlayback.mockReturnValue(
      makeStub({
        status: "playing",
        currentTrack: makeTrack({ title: "Song A", artist: "Artist A" }),
        position: 83,
        duration: 296,
      })
    );
    render(<MiniPlayer />);
    const root = screen.getByTestId("mini-player");
    expect(root).toBeTruthy();
    expect(root.textContent).toContain("Song A");
    expect(root.textContent).toContain("Artist A");
    // Time format m:ss / m:ss
    expect(root.textContent).toContain("1:23");
    expect(root.textContent).toContain("4:56");
    // Pause control surfaced (since playing)
    expect(screen.getByLabelText("Pause")).toBeTruthy();
  });

  it("shows Play icon when status === 'paused'", () => {
    mockUsePlayback.mockReturnValue(makeStub({ status: "paused" }));
    render(<MiniPlayer />);
    expect(screen.getByLabelText("Play")).toBeTruthy();
  });

  it("falls back to 'Unknown track' / 'Unknown artist' when metadata fields are empty", () => {
    mockUsePlayback.mockReturnValue(
      makeStub({
        status: "playing",
        currentTrack: makeTrack({ title: "", artist: "" }),
      })
    );
    render(<MiniPlayer />);
    const root = screen.getByTestId("mini-player");
    expect(root.textContent).toContain("Unknown track");
    expect(root.textContent).toContain("Unknown artist");
  });
});

describe("MiniPlayer — loading state", () => {
  it("shows '-- / --' time placeholder during loading", () => {
    mockUsePlayback.mockReturnValue(
      makeStub({ status: "loading", position: 0, duration: 0 })
    );
    render(<MiniPlayer />);
    const root = screen.getByTestId("mini-player");
    expect(root.textContent).toContain("-- / --");
  });
});

describe("MiniPlayer — D-16 / D-23 error state", () => {
  it("replaces title/artist with the error message and hides the progress bar", () => {
    mockUsePlayback.mockReturnValue(
      makeStub({
        status: "error",
        error: "Library drive disconnected",
      })
    );
    render(<MiniPlayer />);
    const root = screen.getByTestId("mini-player");
    expect(root.textContent).toContain("Library drive disconnected");
    // No progress bar in error state
    expect(screen.queryByRole("progressbar")).toBeNull();
  });

  it("disables the play/pause button when in error state", () => {
    mockUsePlayback.mockReturnValue(
      makeStub({ status: "error", error: "Boom" })
    );
    render(<MiniPlayer />);
    const btn = screen.getByLabelText("Play") as HTMLButtonElement;
    expect(btn.disabled).toBe(true);
  });
});

describe("MiniPlayer — D-17 progress bar seek", () => {
  it("calls seek() with clamped position when progress bar is clicked", () => {
    const seek = vi.fn();
    mockUsePlayback.mockReturnValue(
      makeStub({
        status: "playing",
        position: 0,
        duration: 200,
        seek,
      })
    );
    render(<MiniPlayer />);
    const bar = screen.getByRole("progressbar");
    // Stub bounding rect so we can compute predictable percent.
    bar.getBoundingClientRect = () =>
      ({ left: 0, top: 0, right: 400, bottom: 4, width: 400, height: 4, x: 0, y: 0, toJSON: () => ({}) } as DOMRect);
    fireEvent.click(bar, { clientX: 100 }); // 25% in -> 50s of 200s duration
    expect(seek).toHaveBeenCalledTimes(1);
    expect(seek.mock.calls[0][0]).toBeCloseTo(50, 5);
  });

  it("clamps clicks left of the bar to 0", () => {
    const seek = vi.fn();
    mockUsePlayback.mockReturnValue(
      makeStub({ status: "playing", duration: 100, seek })
    );
    render(<MiniPlayer />);
    const bar = screen.getByRole("progressbar");
    bar.getBoundingClientRect = () =>
      ({ left: 50, top: 0, right: 450, bottom: 4, width: 400, height: 4, x: 50, y: 0, toJSON: () => ({}) } as DOMRect);
    fireEvent.click(bar, { clientX: 10 }); // before left edge
    expect(seek).toHaveBeenCalledWith(0);
  });

  it("clamps clicks right of the bar to duration", () => {
    const seek = vi.fn();
    mockUsePlayback.mockReturnValue(
      makeStub({ status: "playing", duration: 120, seek })
    );
    render(<MiniPlayer />);
    const bar = screen.getByRole("progressbar");
    bar.getBoundingClientRect = () =>
      ({ left: 0, top: 0, right: 400, bottom: 4, width: 400, height: 4, x: 0, y: 0, toJSON: () => ({}) } as DOMRect);
    fireEvent.click(bar, { clientX: 9999 }); // far right
    expect(seek).toHaveBeenCalledTimes(1);
    expect(seek.mock.calls[0][0]).toBeCloseTo(120, 5);
  });
});

describe("MiniPlayer — D-18 no volume control", () => {
  it("renders no <input type=\"range\"> anywhere", () => {
    mockUsePlayback.mockReturnValue(makeStub({ status: "playing" }));
    const { container } = render(<MiniPlayer />);
    const ranges = container.querySelectorAll('input[type="range"]');
    expect(ranges.length).toBe(0);
  });

  it("renders no element matching /volume/i in label or attribute", () => {
    mockUsePlayback.mockReturnValue(makeStub({ status: "playing" }));
    const { container } = render(<MiniPlayer />);
    const html = container.innerHTML;
    expect(/volume/i.test(html)).toBe(false);
  });
});

describe("MiniPlayer — play/pause button wiring", () => {
  it("calls togglePlayPause() when the play/pause button is clicked", () => {
    const togglePlayPause = vi.fn();
    mockUsePlayback.mockReturnValue(
      makeStub({ status: "paused", togglePlayPause })
    );
    render(<MiniPlayer />);
    const btn = screen.getByLabelText("Play");
    fireEvent.click(btn);
    expect(togglePlayPause).toHaveBeenCalledTimes(1);
  });
});
