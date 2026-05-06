/**
 * PlaybackContext — Phase 29 inline preview / spacebar playback.
 *
 * Single source of truth for "what's playing right now". Owns:
 *   - exactly ONE hidden <audio> element (D-05)
 *   - the spacebar window-keydown listener (D-09/D-10/D-11/D-12)
 *   - LUFS gain calc (D-19/D-20)
 *   - drive-disconnect handling (D-22)
 *   - visibilitychange pause-on-hide (D-26)
 *
 * Constraints (LOCKED — see plan frontmatter):
 *   D-01 HTML5 <audio> only via convertFileSrc — no Rust audio engine
 *   D-02 Format whitelist (mp3, m4a, flac, wav) routes via convertFileSrc;
 *        anything else hits the error path via the <audio> error event
 *   D-04 Public shape: { currentTrack, status, position, duration, error,
 *        play, pause, togglePlayPause, seek, stop }
 *   D-07 Position state throttled to ~250ms
 *   D-08 NO localStorage of currentTrack/position
 *   D-13 NO new focusedTrackId on TrackSelectionContext —
 *        derive focus from selectedTracks[length-1]
 *   D-18 NO volume slider/control in API
 *   D-24 No auto-resume on remount
 *   D-25 No AVAudioSession or AirPods route-change handling
 *   D-27 ZERO reads of track_tags / albums / variant_of in this file
 *   D-28 Every useEffect with addEventListener returns cleanup
 *   U-1  play(track) sets status='loading' SYNCHRONOUSLY before any await
 */

import {
  createContext,
  useContext,
  useState,
  useEffect,
  useRef,
  useCallback,
} from "react";
import type { ReactNode } from "react";
import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { toast } from "sonner";

import type { Track } from "../types/library";
import { useTrackSelection } from "./TrackSelectionContext";
import { useLibraryMount } from "./LibraryMountContext";

// ---------- types ----------

type PlaybackStatus = "idle" | "loading" | "playing" | "paused" | "error";

interface PlaybackContextValue {
  currentTrack: Track | null;
  status: PlaybackStatus;
  position: number;
  duration: number;
  error: string | null;
  play(track: Track): Promise<void>;
  pause(): void;
  togglePlayPause(): void;
  seek(seconds: number): void;
  stop(): void;
}

// What `resolve_track_audio_path` (29-01) returns. Mirrors
// src-tauri/src/commands/library_config.rs::TrackPlaybackInfo.
interface TrackPlaybackInfo {
  absolute_path: string;
  lufs_i: number | null;
  format: string;
  duration: number | null;
}

const PlaybackContext = createContext<PlaybackContextValue | null>(null);

// ---------- provider ----------

interface PlaybackProviderProps {
  children: ReactNode;
}

export function PlaybackProvider({ children }: PlaybackProviderProps) {
  // ---- state ----
  const [currentTrack, setCurrentTrack] = useState<Track | null>(null);
  const [status, setStatus] = useState<PlaybackStatus>("idle");
  const [position, setPosition] = useState<number>(0);
  const [duration, setDuration] = useState<number>(0);
  const [error, setError] = useState<string | null>(null);

  // ---- refs (kept in sync with state to avoid stale closures in zero-dep
  // useEffects — the spacebar handler must read live status/selection
  // without re-subscribing on every state tick) ----
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const statusRef = useRef<PlaybackStatus>("idle");
  const currentTrackRef = useRef<Track | null>(null);
  const selectedTracksRef = useRef<Track[]>([]);
  const lastDispatchAtRef = useRef<number>(0); // D-11 spacebar debounce
  const positionThrottleRef = useRef<number>(0); // D-07 ~250ms throttle
  const prevMountStateRef = useRef<string>(""); // D-22 connected→disconnected detection

  const { selectedTracks } = useTrackSelection();
  const { mountState } = useLibraryMount();

  // Keep refs in sync (sync useEffects, no listeners → no cleanup needed).
  useEffect(() => {
    statusRef.current = status;
  }, [status]);
  useEffect(() => {
    selectedTracksRef.current = selectedTracks;
  }, [selectedTracks]);

  // -----------------------------------------------------------------------
  // useEffect #1a: audio element creation + element teardown.
  // D-05: exactly one <audio> per provider. The element is appended to
  // document.body so it has a stable lifetime (and tests can query it).
  // It has no visible UI — playback is driven entirely by .src/.play()/.pause().
  // D-28: cleanup destroys the element on unmount.
  // -----------------------------------------------------------------------
  useEffect(() => {
    const audio = document.createElement("audio");
    audio.preload = "metadata";
    audio.style.display = "none";
    document.body.appendChild(audio);
    audioRef.current = audio;

    return () => {
      audio.pause();
      audio.src = "";
      audio.load();
      if (audio.parentNode) audio.parentNode.removeChild(audio);
      audioRef.current = null;
    };
  }, []);

  // -----------------------------------------------------------------------
  // useEffect #1b: audio event listeners (depend on the element from #1a).
  // D-28: cleanup removes every listener.
  // -----------------------------------------------------------------------
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const handlePlaying = () => {
      setStatus("playing");
    };
    const handlePause = () => {
      // Native 'pause' fires both for user-pause AND when src is cleared / on
      // ended (some implementations). Only flip to 'paused' if we're playing
      // — otherwise leave stop()/error()/etc. to drive state.
      if (statusRef.current === "playing") setStatus("paused");
    };
    const handleEnded = () => {
      setStatus("paused");
      // Pitfall 3 fix: snap position to duration so the progress bar reads "done".
      setPosition(audio.duration || 0);
    };
    const handleTimeupdate = () => {
      // D-07: throttle to ~250ms to avoid render thrash on the virtualized
      // LibraryTable.
      const now = Date.now();
      if (now - positionThrottleRef.current >= 250) {
        positionThrottleRef.current = now;
        setPosition(audio.currentTime);
      }
    };
    const handleLoadedmetadata = () => {
      if (Number.isFinite(audio.duration)) setDuration(audio.duration);
    };
    const handleError = () => {
      const err = audio.error;
      if (err && err.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED) {
        // D-03: hardcoded copy. Do NOT use err.message — WKWebView may not
        // populate it consistently (Pitfall 2 in plan). Pull format from
        // the track ref to avoid stale closure on currentTrack state.
        const fmt = currentTrackRef.current?.metadata?.format ?? "unknown";
        toast.error(
          `Preview not supported: ${fmt}. The track is in your library and syncs to your iPod.`,
        );
        setStatus("error");
        setError(`Preview not supported: ${fmt}`);
      } else {
        // D-23: inline mini-bar error, no toast spam.
        setStatus("error");
        setError("Playback error");
      }
    };

    audio.addEventListener("playing", handlePlaying);
    audio.addEventListener("pause", handlePause);
    audio.addEventListener("ended", handleEnded);
    audio.addEventListener("timeupdate", handleTimeupdate);
    audio.addEventListener("loadedmetadata", handleLoadedmetadata);
    audio.addEventListener("error", handleError);

    return () => {
      audio.removeEventListener("playing", handlePlaying);
      audio.removeEventListener("pause", handlePause);
      audio.removeEventListener("ended", handleEnded);
      audio.removeEventListener("timeupdate", handleTimeupdate);
      audio.removeEventListener("loadedmetadata", handleLoadedmetadata);
      audio.removeEventListener("error", handleError);
    };
  }, []);

  // -----------------------------------------------------------------------
  // play() — U-1: status='loading' synchronously before any await.
  // D-19/D-20 LUFS gain. D-27: reads only Track.id / Track.organized_path /
  // Track.metadata.format (no track_tags / albums / variant_of).
  // -----------------------------------------------------------------------
  const play = useCallback(async (track: Track) => {
    // Guard: Remote track or missing id → error immediately, don't even invoke.
    if (!track.id || !track.organized_path) {
      setStatus("error");
      setError("Track has no playable file");
      return;
    }

    // U-1: synchronous prefix — set loading + currentTrack BEFORE await.
    setStatus("loading");
    setCurrentTrack(track);
    currentTrackRef.current = track;
    setError(null);

    try {
      const info = await invoke<TrackPlaybackInfo>("resolve_track_audio_path", {
        trackId: track.id,
      });

      const audio = audioRef.current;
      if (!audio) return;

      // D-19/D-20 LUFS gain. Target -18 LUFS-I, clamp gain to [-12, +6] dB,
      // null lufs_i → volume=1.0 unmodified.
      if (info.lufs_i !== null) {
        const gainDb = -18 - info.lufs_i;
        const clipped = Math.max(-12, Math.min(6, gainDb));
        audio.volume = Math.pow(10, clipped / 20);
      } else {
        // D-20: no loudness data → no gain applied. The user gets WKWebView
        // default volume. Do NOT silence — the track is still playable.
        audio.volume = 1.0;
      }

      if (info.duration !== null) setDuration(info.duration);

      // D-01/D-02: route the absolute path through the Tauri asset protocol.
      // The format whitelist gate is enforced implicitly: non-whitelist
      // formats produce MEDIA_ERR_SRC_NOT_SUPPORTED at the <audio> error
      // event, which our handleError above maps to the D-03 toast.
      audio.src = convertFileSrc(info.absolute_path);
      await audio.play();
    } catch (err) {
      setStatus("error");
      const msg = err instanceof Error ? err.message : String(err);
      setError(msg);
      toast.error(`Playback error: ${msg}`);
    }
  }, []);

  // -----------------------------------------------------------------------
  // pause / togglePlayPause / seek / stop
  // -----------------------------------------------------------------------
  const pause = useCallback(() => {
    audioRef.current?.pause();
  }, []);

  const togglePlayPause = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    if (statusRef.current === "playing") {
      audio.pause();
    } else if (statusRef.current === "paused") {
      audio.play().catch(() => {
        // Swallow — the audio 'error' event will surface the failure.
      });
    }
  }, []);

  const seek = useCallback((seconds: number) => {
    const audio = audioRef.current;
    if (!audio) return;
    // T-29-03: clamp to [0, duration]. Seeking past end wouldn't fire 'ended'.
    const max = Number.isFinite(audio.duration) ? audio.duration : 0;
    const clamped = Math.max(0, Math.min(max, seconds));
    audio.currentTime = clamped;
  }, []);

  const stop = useCallback(() => {
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
      audio.src = "";
      audio.load();
    }
    setStatus("idle");
    setCurrentTrack(null);
    currentTrackRef.current = null;
    setPosition(0);
    setDuration(0);
    setError(null);
  }, []);

  // -----------------------------------------------------------------------
  // useEffect #2: spacebar window-keydown listener.
  // D-09 window scope (mirrors LibraryTable.tsx Esc pattern).
  // D-10 focus guards. D-11 100ms debounce. D-12 focus-track rule.
  // D-28 cleanup required. Empty deps — refs carry live state.
  // -----------------------------------------------------------------------
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // D-10 guards: bail BEFORE preventDefault so typing/buttons keep working.
      const target = e.target as HTMLElement | null;
      if (target) {
        const tag = target.tagName;
        if (
          tag === "INPUT" ||
          tag === "TEXTAREA" ||
          tag === "BUTTON" ||
          target.isContentEditable === true ||
          target.getAttribute?.("contenteditable") === "true"
        ) {
          return;
        }
      }
      if (e.defaultPrevented) return;

      // Only the Space key. Some browsers report key=' ', others key='Spacebar'
      // — code='Space' is the stable identifier.
      if (e.code !== "Space") return;

      // D-11 debounce: drop second-press within 100ms BEFORE preventDefault,
      // so the test that asserts e2.defaultPrevented===false passes.
      const now = Date.now();
      if (now - lastDispatchAtRef.current < 100) return;
      lastDispatchAtRef.current = now;

      e.preventDefault();

      // D-12 focus-track rule:
      //   playing|paused → toggle
      //   idle + 1 selected → play it
      //   idle + >1 selected → play last (selectedTracks[length-1])
      //   idle + 0 selected → no-op
      const s = statusRef.current;
      if (s === "playing" || s === "paused") {
        togglePlayPause();
        return;
      }
      // status is idle | loading | error → treat like idle for selection routing
      const sel = selectedTracksRef.current;
      if (sel.length === 0) return;
      const target_track = sel[sel.length - 1];
      // play() is async but we don't await — the listener returns synchronously
      // so the browser's default Space behavior stays preventDefault-canceled.
      void play(target_track);
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [play, togglePlayPause]);

  // -----------------------------------------------------------------------
  // useEffect #3: LibraryMountContext drive-disconnect watch (D-22).
  // connected → disconnected during playback: pause + status='error' inline.
  // No toast — sidebar/ActivityPanel already surface the disconnect.
  // -----------------------------------------------------------------------
  useEffect(() => {
    if (
      prevMountStateRef.current === "connected" &&
      mountState === "disconnected"
    ) {
      const s = statusRef.current;
      if (s === "loading" || s === "playing" || s === "paused") {
        const audio = audioRef.current;
        if (audio) {
          audio.pause();
          audio.src = "";
        }
        setStatus("error");
        setError("Library drive disconnected");
        // D-22: explicitly NO toast.
      }
    }
    prevMountStateRef.current = mountState;
  }, [mountState]);

  // -----------------------------------------------------------------------
  // useEffect #4: visibilitychange pause-on-hide (D-26).
  // D-28 cleanup required. No auto-resume when visible again.
  // -----------------------------------------------------------------------
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.hidden && statusRef.current === "playing") {
        // The audio 'pause' event will fire and flip status → 'paused'.
        audioRef.current?.pause();
      }
      // D-26: NO auto-resume on visible.
    };
    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () =>
      document.removeEventListener("visibilitychange", handleVisibilityChange);
  }, []);

  // -----------------------------------------------------------------------
  // Provider value — D-04 LOCKED shape. No volume / setVolume (D-18).
  // -----------------------------------------------------------------------
  const value: PlaybackContextValue = {
    currentTrack,
    status,
    position,
    duration,
    error,
    play,
    pause,
    togglePlayPause,
    seek,
    stop,
  };

  return (
    <PlaybackContext.Provider value={value}>{children}</PlaybackContext.Provider>
  );
}

// ---------- hook ----------

export function usePlayback(): PlaybackContextValue {
  const ctx = useContext(PlaybackContext);
  if (!ctx) {
    throw new Error("usePlayback must be used within PlaybackProvider");
  }
  return ctx;
}
