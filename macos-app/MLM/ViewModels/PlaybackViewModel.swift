import Foundation
import SwiftUI

/// ViewModel for audio playback — owns the AudioPlayer and exposes
/// reactive state for PlayerBar, TrackDetailView, and keyboard shortcuts.
///
/// ## Responsibilities
/// - Load and play tracks (by Track model or file URL)
/// - Expose currentPosition, duration, progress for UI binding
/// - Apply LUFS gain compensation per-track
/// - Provide play/pause/stop/seek controls
/// - Poll position on a timer for smooth progress bar updates
///
/// Designed as a singleton injected via `DependencyContainer`.
@Observable
final class PlaybackViewModel {

    // MARK: - Published State

    /// The currently loaded track (nil when nothing is loaded).
    private(set) var currentTrack: Track?

    /// Current playback state.
    private(set) var playbackState: AudioPlayer.PlaybackState = .stopped

    /// Current position in seconds.
    private(set) var currentPosition: TimeInterval = 0

    /// Total duration in seconds.
    private(set) var duration: TimeInterval = 0

    /// Progress fraction (0.0 – 1.0).
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentPosition / duration
    }

    /// Formatted current position (e.g., "1:42").
    var formattedPosition: String {
        formatTime(currentPosition)
    }

    /// Formatted duration (e.g., "3:24").
    var formattedDuration: String {
        formatTime(duration)
    }

    /// Whether a track is currently playing.
    var isPlaying: Bool {
        playbackState == .playing
    }

    /// Whether a track is loaded (playing or paused).
    var hasTrack: Bool {
        currentTrack != nil
    }

    /// Error message from the last failed operation.
    private(set) var errorMessage: String?

    /// Waveform peak data for the current track (0.0–1.0 per bin).
    private(set) var waveformData: [Float] = []

    /// Whether waveform data is being extracted.
    private(set) var isLoadingWaveform = false

    // MARK: - Preview State (Spacebar Quick Preview)

    /// Whether we are currently in preview mode (spacebar preview).
    ///
    /// Preview mode is separate from the main "currentTrack" concept:
    /// - Pressing spacebar on a *selected-but-not-playing* track starts a preview.
    /// - Pressing spacebar again stops the preview.
    /// - Double-clicking a track still does a full "Play" which clears preview state.
    private(set) var isPreviewMode = false

    /// The track being previewed (may differ from currentTrack).
    private(set) var previewTrack: Track?

    // MARK: - Dependencies

    private let audioPlayer: AudioPlayer
    private let configRepository: ConfigRepository?

    /// Timer for polling playback position.
    private var positionTimer: Timer?

    // MARK: - Init

    init(audioPlayer: AudioPlayer = AudioPlayer(), configRepository: ConfigRepository? = nil) {
        self.audioPlayer = audioPlayer
        self.configRepository = configRepository
    }

    deinit {
        positionTimer?.invalidate()
    }

    // MARK: - Load & Play Track

    /// Load a track and start playback.
    ///
    /// Resolves the track's file path against the library root, loads the
    /// audio file, applies LUFS gain, extracts waveform data, and plays.
    ///
    /// - Parameter track: The track to play
    @MainActor
    func playTrack(_ track: Track) async {
        errorMessage = nil

        let root = (try? await configRepository?.getLibraryRoot()) ?? nil

        // Try organized_path first (relative to library_root). Many rows
        // in this DB carry a stale organized_path because the Tauri side
        // wrote where the file *should* live after the organize step
        // even when that step never ran — so fall back to original_path
        // (absolute) whenever organized doesn't actually exist on disk.
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) {
                await playFile(at: url, track: track)
                return
            }
        }

        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                await playFile(at: URL(fileURLWithPath: expanded), track: track)
                return
            }
        }

        errorMessage = "Audio-Datei nicht gefunden — weder organized_path noch original_path existieren auf der Disk."
        AppLogger.shared.log(
            "Playback failed: no resolvable file for track id=\(track.id ?? -1) — organized='\(track.organizedPath ?? "")' original='\(track.originalPath)'",
            level: .warning,
            source: "Playback"
        )
    }

    /// Load a file URL and start playback.
    ///
    /// - Parameters:
    ///   - url: File URL to the audio file
    ///   - track: Optional Track metadata to associate
    @MainActor
    func playFile(at url: URL, track: Track? = nil) async {
        errorMessage = nil

        do {
            // Load the file
            try audioPlayer.loadFile(at: url)

            // Update state
            currentTrack = track
            duration = audioPlayer.duration
            currentPosition = 0

            // Apply LUFS gain compensation
            audioPlayer.applyLUFSCompensation(lufsI: track?.lufsI)

            // Start playback
            try audioPlayer.play()
            playbackState = .playing

            // Notify observers
            postTrackDidChange()
            postStateDidChange()

            // Start position polling
            startPositionTimer()

            // Extract waveform data in background
            extractWaveform()
        } catch {
            let ext = url.pathExtension.lowercased()
            let unsupportedHint = Self.unsupportedFormatHints[ext]
            errorMessage = unsupportedHint ?? "Wiedergabe fehlgeschlagen: \(error.localizedDescription)"
            playbackState = .stopped
            AppLogger.shared.log(
                "Playback failed for \(url.lastPathComponent) (.\(ext)): \(error.localizedDescription)",
                level: .warning,
                source: "Playback"
            )
            postStateDidChange()
        }
    }

    /// Format-specific error blurbs when AVAudioFile rejects a file.
    /// AVAudioEngine talks to Apple Core Audio, which cannot decode opus,
    /// webm, or some exotic mp3 frame setups even though ffmpeg / yt-dlp
    /// can produce them. Surface that explicitly so the user knows it's
    /// not a missing file, it's a codec mismatch.
    private static let unsupportedFormatHints: [String: String] = [
        "opus": "Opus-Format wird vom macOS-Audio-Engine nicht unterstützt — neu downloaden mit AAC oder per Hand zu m4a transkodieren.",
        "ogg": "Vorbis/Ogg wird vom macOS-Audio-Engine nicht unterstützt — bitte zu m4a transkodieren.",
        "webm": "WebM-Container wird vom macOS-Audio-Engine nicht unterstützt — bitte zu m4a transkodieren."
    ]

    // MARK: - Playback Controls

    /// Toggle play/pause.
    @MainActor
    func togglePlayPause() {
        do {
            try audioPlayer.togglePlayPause()
            playbackState = audioPlayer.state

            if playbackState == .playing {
                startPositionTimer()
            } else {
                stopPositionTimer()
                updatePosition()
            }

            postStateDidChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Play (resume or start).
    @MainActor
    func play() {
        do {
            try audioPlayer.play()
            playbackState = .playing
            startPositionTimer()
            postStateDidChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pause playback.
    @MainActor
    func pause() {
        audioPlayer.pause()
        playbackState = .paused
        stopPositionTimer()
        updatePosition()
        postStateDidChange()
    }

    /// Stop playback and unload track.
    @MainActor
    func stop() {
        audioPlayer.stop()
        playbackState = .stopped
        currentPosition = 0
        currentTrack = nil
        isPreviewMode = false
        previewTrack = nil
        waveformData = []
        stopPositionTimer()
        postTrackDidChange()
        postStateDidChange()
    }

    // MARK: - Spacebar Preview

    /// Toggle spacebar preview for a track.
    ///
    /// Behavior:
    /// - If nothing is playing → start preview of the given track.
    /// - If previewing the same track → stop preview.
    /// - If previewing a different track → switch preview to new track.
    /// - If a main track is playing (not preview) → pause/resume it.
    ///
    /// - Parameter track: The track to preview (from the current selection).
    @MainActor
    func togglePreview(for track: Track?) {
        // If no track provided, just toggle play/pause on whatever is loaded
        guard let track else {
            if hasTrack { togglePlayPause() }
            return
        }

        // If we're previewing the same track → stop preview
        if isPreviewMode, let previewTrack, previewTrack.id == track.id {
            stopPreview()
            return
        }

        // If the main track is playing and it's the same track → just toggle
        if !isPreviewMode, let currentTrack, currentTrack.id == track.id {
            togglePlayPause()
            return
        }

        // Start a new preview
        startPreview(track)
    }

    /// Start preview playback for a track.
    @MainActor
    private func startPreview(_ track: Track) {
        isPreviewMode = true
        previewTrack = track

        Task {
            await playTrack(track)
        }
    }

    /// Stop the current preview and restore previous state.
    @MainActor
    func stopPreview() {
        guard isPreviewMode else { return }

        audioPlayer.stop()
        playbackState = .stopped
        currentPosition = 0
        currentTrack = nil
        isPreviewMode = false
        previewTrack = nil
        waveformData = []
        stopPositionTimer()
        postTrackDidChange()
        postStateDidChange()
    }

    /// Seek to a position in seconds.
    @MainActor
    func seek(to position: TimeInterval) {
        do {
            try audioPlayer.seek(to: position)
            playbackState = audioPlayer.state
            updatePosition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Seek to a progress fraction (0.0 – 1.0).
    @MainActor
    func seekToProgress(_ fraction: Double) {
        let position = fraction * duration
        seek(to: position)
    }

    /// Set the playback node volume (0.0 – 1.0).
    @MainActor
    func setVolume(_ volume: Double) {
        audioPlayer.setVolume(Float(volume))
    }

    // MARK: - Position Timer

    /// Start polling the player position for smooth UI updates.
    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePosition()
            }
        }
    }

    /// Stop the position polling timer.
    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// Read current position from the audio player.
    @MainActor
    private func updatePosition() {
        currentPosition = audioPlayer.currentPosition

        // Detect natural end of playback
        if audioPlayer.state == .stopped && playbackState == .playing {
            playbackState = .stopped
            currentPosition = 0
            stopPositionTimer()
            postStateDidChange()
        }
    }

    // MARK: - Waveform

    /// Extract waveform data from the current file.
    private func extractWaveform() {
        Task { @MainActor in
            isLoadingWaveform = true
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let data = (try? self.audioPlayer.extractWaveformData(binCount: 200)) ?? []
            await MainActor.run {
                self.waveformData = data
                self.isLoadingWaveform = false
            }
        }
    }

    // MARK: - Helpers

    /// Format seconds into "m:ss" display string.
    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "—:——" }
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Notifications

    /// Post notification when the current track changes.
    private func postTrackDidChange() {
        NotificationCenter.default.post(
            name: .playbackTrackDidChange,
            object: nil,
            userInfo: currentTrack.flatMap { track in
                track.id.map { ["trackId": $0] }
            }
        )
    }

    /// Post notification when playback state changes.
    private func postStateDidChange() {
        NotificationCenter.default.post(
            name: .playbackStateDidChange,
            object: nil,
            userInfo: ["state": playbackState]
        )
    }
}
