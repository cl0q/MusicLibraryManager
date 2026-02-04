import { useEffect, useRef, useState } from "react";
import WaveSurfer from "wavesurfer.js";
import { convertFileSrc } from "@tauri-apps/api/core";

interface WaveformViewProps {
  audioUrl: string;
}

export default function WaveformView({ audioUrl }: WaveformViewProps) {
  const waveformRef = useRef<HTMLDivElement>(null);
  const wavesurferRef = useRef<WaveSurfer | null>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [isReady, setIsReady] = useState(false);

  useEffect(() => {
    if (!waveformRef.current) return;

    // Convert local file path to Tauri asset URL
    const assetUrl = convertFileSrc(audioUrl);

    // Initialize WaveSurfer
    const wavesurfer = WaveSurfer.create({
      container: waveformRef.current,
      waveColor: "#9ca3af",
      progressColor: "#3b82f6",
      height: 100,
      barWidth: 2,
      barGap: 1,
      cursorColor: "#1e40af",
    });

    wavesurferRef.current = wavesurfer;

    // Load audio file
    wavesurfer.load(assetUrl);

    wavesurfer.on("ready", () => {
      setIsReady(true);
    });

    wavesurfer.on("play", () => {
      setIsPlaying(true);
    });

    wavesurfer.on("pause", () => {
      setIsPlaying(false);
    });

    wavesurfer.on("error", (error) => {
      console.error("WaveSurfer error:", error);
      setIsReady(false);
    });

    // Cleanup on unmount
    return () => {
      wavesurfer.destroy();
    };
  }, [audioUrl]);

  const togglePlayPause = () => {
    if (wavesurferRef.current) {
      wavesurferRef.current.playPause();
    }
  };

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 p-6">
      <h2 className="text-xl font-bold mb-4 text-gray-900 dark:text-white">
        Waveform
      </h2>
      <div ref={waveformRef} className="mb-4" />
      <button
        onClick={togglePlayPause}
        disabled={!isReady}
        className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white rounded-lg font-medium transition-colors"
      >
        {isPlaying ? "Pause" : "Play"}
      </button>
      {!isReady && (
        <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
          Loading audio...
        </p>
      )}
    </div>
  );
}
