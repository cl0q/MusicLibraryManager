import Foundation
import SwiftUI
import AVFoundation

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

    /// Track that can be retried after playback could not resolve its file.
    private(set) var unavailableTrack: Track?

    /// Waveform peak data for the current track (0.0–1.0 per bin).
    private(set) var waveformData: [Float] = []

    /// Whether waveform data is being extracted.
    private(set) var isLoadingWaveform = false

    /// Cancellable handle for the active waveform extraction task.
    private var waveformTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let audioPlayer: any AudioPlayerControlling
    private let configRepository: ConfigRepository?

    /// Timer for polling playback position.
    private var positionTimer: Timer?

    /// The playback queue — priority lanes (playNext + context).
    private var queue = PlaybackQueue()

    /// History of played tracks (most recent last). Capped by UserDefaults.
    private(set) var history: [Track] = []

    /// Upcoming tracks: playNext items first, then context items.
    var upcoming: [Track] { queue.upcoming }

    // MARK: - Init

    init(audioPlayer: any AudioPlayerControlling = AudioPlayer(), configRepository: ConfigRepository? = nil) {
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
        var proposedQueue = queue
        proposedQueue.replaceContext([], cap: 0)
        if await loadAndPlay(track) {
            queue = proposedQueue
        }
    }

    /// Play a track with the visible table order as its queue.
    ///
    /// Stores the queue starting at the clicked track so auto-advance,
    /// back/forward, and play-next all work against the user's context.
    @MainActor
    func playTrack(_ track: Track, queue tracks: [Track]) async {
        let startIndex = tracks.firstIndex(of: track) ?? 0
        let afterClicked = Array(tracks.dropFirst(startIndex + 1))
        let cap = Self.contextCap()
        var proposedQueue = queue
        proposedQueue.replaceContext(afterClicked, cap: cap)
        if await loadAndPlay(track) {
            queue = proposedQueue
        }
    }

    /// Play the given tracks in random order.
    @MainActor
    func playShuffled(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        let shuffled = tracks.shuffled()
        await playTrack(shuffled[0], queue: shuffled)
    }

    /// Internal: resolve the track's file and start playback without
    /// touching the queue. Used by playTrack variants and queue navigation.
    @MainActor
    private func loadAndPlay(_ track: Track) async -> Bool {
        errorMessage = nil
        unavailableTrack = nil

        let root = (try? await configRepository?.getLibraryRoot()) ?? nil

        // Try organized_path first (relative to library_root). Many rows
        // in this DB carry a stale organized_path because the Tauri side
        // wrote where the file *should* live after the organize step
        // even when that step never ran — so fall back to original_path
        // (absolute) whenever organized doesn't actually exist on disk.
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) {
                return await playFile(at: url, track: track)
            }
        }

        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return await playFile(at: URL(fileURLWithPath: expanded), track: track)
            }
        }

        errorMessage = "Playback unavailable: \(track.title) — file could not be found on disk."
        unavailableTrack = track
        AppLogger.shared.log(
            "Playback failed: no resolvable file for track id=\(track.id ?? -1) — organized='\(track.organizedPath ?? "")' original='\(track.originalPath)'",
            level: .warning,
            source: "Playback"
        )
        return false
    }

    /// Load a file URL and start playback.
    ///
    /// - Parameters:
    ///   - url: File URL to the audio file
    ///   - track: Optional Track metadata to associate
    @MainActor
    @discardableResult
    func playFile(at url: URL, track: Track? = nil) async -> Bool {
        errorMessage = nil
        unavailableTrack = nil

        do {
            // Load the file
            try audioPlayer.loadFile(at: url)

            // Apply LUFS gain compensation
            audioPlayer.applyLUFSCompensation(lufsI: track?.lufsI)

            // Start playback
            try audioPlayer.play()
            currentTrack = track
            duration = audioPlayer.duration
            currentPosition = 0
            playbackState = .playing
            if let track {
                recordSuccessfulPlayback(track)
            }

            // Notify observers
            postTrackDidChange()
            postStateDidChange()

            // Start position polling
            startPositionTimer()

            // Extract waveform data in background
            extractWaveform(for: url, trackID: track?.id)
            return true
        } catch {
            let ext = url.pathExtension.lowercased()
            let unsupportedHint = Self.unsupportedFormatHints[ext]
            let trackName = track?.title ?? url.lastPathComponent
            errorMessage = unsupportedHint ?? "Playback unavailable: \(trackName) — \(error.localizedDescription)"
            unavailableTrack = track
            // `AudioPlayer.loadFile` stops and clears its prior file before it
            // can throw. Do not leave controls presenting a stale track.
            clearStoppedPlaybackState()
            AppLogger.shared.log(
                "Playback failed for \(url.lastPathComponent) (.\(ext)): \(error.localizedDescription)",
                level: .warning,
                source: "Playback"
            )
            postStateDidChange()
            return false
        }
    }

    @MainActor
    func retryUnavailableTrack() async {
        guard let unavailableTrack else { return }
        _ = await loadAndPlay(unavailableTrack)
    }

    /// Format-specific error blurbs when AVAudioFile rejects a file.
    /// AVAudioEngine talks to Apple Core Audio, which cannot decode opus,
    /// webm, or some exotic mp3 frame setups even though ffmpeg / yt-dlp
    /// can produce them. Surface that explicitly so the user knows it's
    /// not a missing file, it's a codec mismatch.
    private static let unsupportedFormatHints: [String: String] = [
        "opus": "Opus is not supported by macOS audio. Download an AAC version or transcode it to M4A.",
        "ogg": "Vorbis/Ogg is not supported by macOS audio. Transcode it to M4A.",
        "webm": "WebM is not supported by macOS audio. Transcode it to M4A."
    ]

    /// Commit history only after the file loaded and playback really started.
    private func recordSuccessfulPlayback(_ track: Track) {
        history.append(track)
        let historyCap = Self.historySize()
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
    }

    /// A throwing load has already stopped AudioPlayer. Mirror that cleared
    /// state instead of retaining stale metadata and transport controls.
    private func clearStoppedPlaybackState() {
        currentTrack = nil
        playbackState = .stopped
        currentPosition = 0
        duration = 0
        waveformData = []
        stopPositionTimer()
        postTrackDidChange()
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

    /// Seek relative to the current position by `delta` seconds.
    ///
    /// Clamps the result to `0...duration`. No-op when no track is loaded
    /// or the duration is unknown.
    @MainActor
    func seekBy(_ delta: TimeInterval) {
        guard hasTrack, duration > 0 else { return }
        let target = min(max(0, currentPosition + delta), duration)
        do {
            try audioPlayer.seek(to: target)
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

    // MARK: - Queue Controls

    /// Called when the current track finishes playing naturally.
    ///
    /// Advances the queue and auto-plays the next track. When the queue
    /// is exhausted, stops playback and clears the current track.
    @MainActor
    func trackDidEnd() {
        var proposedQueue = queue
        guard let nextTrack = proposedQueue.advance() else {
            // Queue exhausted — stop.
            stop()
            return
        }
        Task {
            if await loadAndPlay(nextTrack) {
                queue = proposedQueue
            }
        }
    }

    /// Skip to the next track in the queue.
    ///
    /// At the end of the queue, stops playback.
    @MainActor
    func next() async {
        var proposedQueue = queue
        guard let nextTrack = proposedQueue.advance() else {
            stop()
            return
        }
        if await loadAndPlay(nextTrack) {
            queue = proposedQueue
        }
    }

    /// Go back to the previous track, or restart the current one if
    /// the playback position is past the restart threshold.
    /// Uses history to find the previous track; pushes the old current
    /// to the front of the context lane.
    @MainActor
    func back() async {
        let position = audioPlayer.currentPosition
        if position > PlaybackQueue.backRestartThreshold {
            do {
                try audioPlayer.seek(to: 0)
                currentPosition = 0
                if playbackState != .playing {
                    try audioPlayer.play()
                    playbackState = .playing
                    startPositionTimer()
                    postStateDidChange()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        var proposedHistory = history
        if let current = currentTrack, let idx = proposedHistory.lastIndex(where: { $0.id == current.id }) {
            proposedHistory.remove(at: idx)
        }

        guard let previousTrack = proposedHistory.popLast() else {
            // No previous track — restart current
            do {
                try audioPlayer.seek(to: 0)
                currentPosition = 0
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        var proposedQueue = queue
        if let current = currentTrack {
            proposedQueue.pushToFront(current)
        }

        if await loadAndPlay(previousTrack) {
            history = proposedHistory
            queue = proposedQueue
        }
    }

    /// Play a specific track from the upcoming queue.
    /// Discards everything before it; keeps everything after.
    @MainActor
    func playFromQueue(track: Track) async {
        var proposedQueue = queue
        guard proposedQueue.playFromUpcoming(track) != nil else { return }
        if await loadAndPlay(track) {
            queue = proposedQueue
        }
    }

    /// Insert tracks directly after the current track so they play next.
    ///
    /// Tracks already in the queue are moved, not duplicated.
    func insertPlayNext(_ tracks: [Track]) {
        queue.insertPlayNext(tracks)
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
            trackDidEnd()
        }
    }

    // MARK: - Waveform

    /// Helper to get the local binary cache URL for the track's waveform data.
    private func getWaveformCacheURL(for trackID: Int64?, or url: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let base = caches.appendingPathComponent("com.musiclibrary.app/waveforms")
        if let id = trackID {
            return base.appendingPathComponent("\(id).bin")
        } else {
            let hash = abs(url.path.hash)
            return base.appendingPathComponent("hash_\(hash).bin")
        }
    }

    /// Extract waveform data from the current file completely in the background
    /// using a separate AVAudioFile instance, with local disk caching support.
    private func extractWaveform(for url: URL, trackID: Int64?) {
        waveformTask?.cancel()
        isLoadingWaveform = true

        let duration = audioPlayer.duration
        let binCount = WaveformHelpers.adaptiveBinCount(duration: duration)
        let cacheURL = getWaveformCacheURL(for: trackID, or: url)

        waveformTask = Task.detached(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled else { return }

            // 1. Try disk cache first
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                if let data = try? Data(contentsOf: cacheURL) {
                    let count = data.count / MemoryLayout<Float>.size
                    if count == binCount {
                        var loadedPeaks = [Float](repeating: 0, count: count)
                        _ = loadedPeaks.withUnsafeMutableBytes { bytes in
                            data.copyBytes(to: bytes)
                        }
                        let capturedPeaks = loadedPeaks
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.waveformData = capturedPeaks
                            self.isLoadingWaveform = false
                        }
                        AppLogger.shared.debug(
                            "Waveform: Loaded \(count) peaks from binary cache for \(url.lastPathComponent) - bypassed file decoding!",
                            source: "Playback"
                        )
                        return
                    }
                }
            }

            // 2. Not cached: extract in background using a separate AVAudioFile
            do {
                let file = try AVAudioFile(forReading: url)
                let totalFrames = file.length
                guard totalFrames > 0 else { throw NSError(domain: "Waveform", code: -1) }

                let chunkFrames: AVAudioFrameCount = 65_536
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                    throw NSError(domain: "Waveform", code: -1)
                }

                let framesPerBin = max(Int(totalFrames) / binCount, 1)
                var peaks = [Float](repeating: 0, count: binCount)

                file.framePosition = 0
                var sourceFrameIndex = 0

                while sourceFrameIndex < Int(totalFrames) {
                    guard !Task.isCancelled else { return }
                    try file.read(into: buffer, frameCount: chunkFrames)
                    let chunkSampleCount = Int(buffer.frameLength)
                    if chunkSampleCount == 0 { break }

                    guard let channelData = buffer.floatChannelData else { break }
                    let samples = channelData[0]

                    for i in 0..<chunkSampleCount {
                        let bin = min((sourceFrameIndex + i) / framesPerBin, binCount - 1)
                        let absSample = abs(samples[i])
                        if absSample > peaks[bin] {
                            peaks[bin] = absSample
                        }
                    }
                    sourceFrameIndex += chunkSampleCount
                }

                // Normalize to 0–1
                let maxPeak = peaks.max() ?? 1.0
                if maxPeak > 0 {
                    for i in 0..<peaks.count {
                        peaks[i] /= maxPeak
                    }
                }

                guard !Task.isCancelled else { return }

                // 3. Write cache to disk
                let cacheDir = cacheURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let bytesData = peaks.withUnsafeBytes { Data($0) }
                try? bytesData.write(to: cacheURL)
                let finalPeaks = peaks

                await MainActor.run {
                    self.waveformData = finalPeaks
                    self.isLoadingWaveform = false
                }
                AppLogger.shared.debug(
                    "Waveform: Decoded \(binCount) peaks in background for \(url.lastPathComponent) & cached to disk",
                    source: "Playback"
                )
            } catch {
                AppLogger.shared.log(
                    "Waveform extraction failed for \(url.lastPathComponent): \(error.localizedDescription)",
                    level: .warning,
                    source: "Playback"
                )
                await MainActor.run {
                    self.waveformData = []
                    self.isLoadingWaveform = false
                }
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

    // MARK: - UserDefaults Helpers

    private static func historySize() -> Int {
        let val = UserDefaults.standard.integer(forKey: "playback_history_size")
        return val > 0 ? val : 50
    }

    private static func contextCap() -> Int {
        let val = UserDefaults.standard.integer(forKey: "playback_context_cap")
        return val > 0 ? val : 100
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
