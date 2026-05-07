import Foundation
import SwiftUI

/// ViewModel for audio playback — owns the AudioPlayer and exposes
/// reactive state for MiniPlayer, TrackDetailView, and keyboard shortcuts.
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

        guard let organizedPath = track.organizedPath else {
            errorMessage = "Track has no local file"
            return
        }

        // Resolve full path using library root
        guard let libraryRoot = try? await configRepository?.getLibraryRoot(),
              let root = libraryRoot else {
            errorMessage = "No library root configured"
            return
        }

        let fileURL = URL(fileURLWithPath: root).appendingPathComponent(organizedPath)
        await playFile(at: fileURL, track: track)
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
            errorMessage = error.localizedDescription
            playbackState = .stopped
            postStateDidChange()
        }
    }

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
