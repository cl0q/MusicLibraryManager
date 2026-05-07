import AVFoundation
import Foundation

/// Audio playback engine using AVAudioEngine.
///
/// Provides play, pause, stop, seek, and LUFS-based gain compensation.
/// Uses AVAudioEngine for low-latency playback with real-time gain control.
///
/// ## Architecture
/// ```
/// AVAudioFile → AVAudioPlayerNode → Gain (AVAudioUnitEQ) → mainMixerNode → output
/// ```
///
/// Phase 5 implementation. Matches the Tauri app's HTML5 `<audio>` element
/// but with native gain control for ReplayGain/LUFS compensation.
final class AudioPlayer: @unchecked Sendable {

    // MARK: - Playback State

    enum PlaybackState: Equatable {
        case stopped
        case playing
        case paused
    }

    // MARK: - Errors

    enum AudioPlayerError: Error, LocalizedError {
        case fileNotFound(String)
        case cannotOpenFile(String, String)
        case engineStartFailed(String)
        case seekOutOfRange

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                return "Audio file not found: \(path)"
            case .cannotOpenFile(let path, let reason):
                return "Cannot open audio file \(path): \(reason)"
            case .engineStartFailed(let reason):
                return "Audio engine failed to start: \(reason)"
            case .seekOutOfRange:
                return "Seek position out of range"
            }
        }
    }

    // MARK: - Engine components

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let gainNode = AVAudioUnitEQ(numberOfBands: 0) // Used only for globalGain

    // MARK: - File state

    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?

    /// Duration of the currently loaded file in seconds.
    private(set) var duration: TimeInterval = 0

    /// Sample rate of the currently loaded file.
    private(set) var sampleRate: Double = 44100

    /// Total frame count of the loaded file.
    private(set) var totalFrames: AVAudioFramePosition = 0

    /// The frame position where the most recent schedule started from.
    /// Used to calculate accurate currentPosition.
    private var seekFrameOffset: AVAudioFramePosition = 0

    /// Current playback state.
    private(set) var state: PlaybackState = .stopped

    // MARK: - Init

    init() {
        setupEngine()
    }

    deinit {
        stop()
        engine.stop()
    }

    // MARK: - Engine Setup

    /// Connect the audio graph: playerNode → gainNode → mainMixer → output.
    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(gainNode)

        // Initial gain: 0 dB (unity)
        gainNode.globalGain = 0

        // Connect: player → gain → mixer
        // Format will be set when a file is loaded
        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: gainNode, format: nil)
        engine.connect(gainNode, to: mainMixer, format: nil)

        // Prepare the engine
        engine.prepare()
    }

    // MARK: - File Loading

    /// Load an audio file for playback.
    ///
    /// - Parameter url: File URL to the audio file
    /// - Throws: `AudioPlayerError` if the file cannot be opened
    func loadFile(at url: URL) throws {
        // Stop any current playback
        stop()

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlayerError.fileNotFound(url.path)
        }

        do {
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file
            self.audioFormat = file.processingFormat
            self.sampleRate = file.processingFormat.sampleRate
            self.totalFrames = file.length
            self.duration = Double(file.length) / file.processingFormat.sampleRate
            self.seekFrameOffset = 0
        } catch {
            throw AudioPlayerError.cannotOpenFile(url.path, error.localizedDescription)
        }
    }

    // MARK: - Playback Controls

    /// Start or resume playback.
    ///
    /// If paused, resumes from the pause position.
    /// If stopped, plays from the beginning.
    func play() throws {
        guard let file = audioFile else { return }

        switch state {
        case .paused:
            // Resume — just start the engine and player
            try startEngineIfNeeded()
            playerNode.play()
            state = .playing

        case .stopped:
            // Start from the beginning (or from seekFrameOffset)
            try startEngineIfNeeded()
            scheduleFile(file, from: seekFrameOffset)
            playerNode.play()
            state = .playing

        case .playing:
            // Already playing
            break
        }
    }

    /// Pause playback. Preserves position for resume.
    func pause() {
        guard state == .playing else { return }
        playerNode.pause()
        state = .paused
    }

    /// Toggle play/pause.
    func togglePlayPause() throws {
        switch state {
        case .playing:
            pause()
        case .paused, .stopped:
            try play()
        }
    }

    /// Stop playback and reset to beginning.
    func stop() {
        playerNode.stop()
        seekFrameOffset = 0
        state = .stopped
    }

    // MARK: - Seek

    /// Seek to a position in seconds.
    ///
    /// - Parameter position: Target position in seconds (0 to duration)
    func seek(to position: TimeInterval) throws {
        guard let file = audioFile else { return }

        let targetFrame = AVAudioFramePosition(position * sampleRate)
        guard targetFrame >= 0 && targetFrame < totalFrames else {
            throw AudioPlayerError.seekOutOfRange
        }

        let wasPlaying = state == .playing

        // Stop current scheduling
        playerNode.stop()
        seekFrameOffset = targetFrame

        if wasPlaying {
            // Re-schedule from new position and play
            scheduleFile(file, from: targetFrame)
            playerNode.play()
            state = .playing
        } else {
            // Just update the offset — will play from here on next play()
            state = .stopped
        }
    }

    // MARK: - Position

    /// Current playback position in seconds.
    var currentPosition: TimeInterval {
        guard state != .stopped else {
            return Double(seekFrameOffset) / sampleRate
        }

        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return Double(seekFrameOffset) / sampleRate
        }

        let currentFrame = seekFrameOffset + playerTime.sampleTime
        let position = Double(currentFrame) / sampleRate

        // Clamp to valid range
        return min(max(position, 0), duration)
    }

    /// Current playback progress as a fraction (0.0 to 1.0).
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentPosition / duration
    }

    // MARK: - Gain / LUFS Compensation

    /// Set the playback gain in decibels.
    ///
    /// Used for LUFS-based ReplayGain compensation.
    /// Target loudness: -14 LUFS (standard streaming normalization).
    ///
    /// - Parameter dB: Gain adjustment in decibels (-96 to +24)
    func setGain(dB: Float) {
        // Clamp to safe range
        let clampedDB = min(max(dB, -96), 24)
        gainNode.globalGain = clampedDB
    }

    /// Calculate and apply LUFS-based gain compensation.
    ///
    /// Adjusts playback volume so all tracks sound equally loud.
    /// Target: -14 LUFS (matches Spotify/YouTube normalization).
    ///
    /// - Parameter lufsI: The track's integrated LUFS value (from analysis)
    func applyLUFSCompensation(lufsI: Double?) {
        guard let lufs = lufsI else {
            // No LUFS data — unity gain
            setGain(dB: 0)
            return
        }

        let targetLUFS: Double = -14.0
        let gainAdjustment = Float(targetLUFS - lufs)

        // Clamp to prevent clipping (max +6 dB boost, unlimited cut)
        let clampedGain = min(gainAdjustment, 6.0)
        setGain(dB: clampedGain)
    }

    // MARK: - Waveform Data Extraction

    /// Extract waveform peak data from the loaded audio file.
    ///
    /// Reads PCM samples and downsamples to the requested number of bins,
    /// taking the peak amplitude in each bin. Used by `WaveformView`.
    ///
    /// - Parameter binCount: Number of output bins (default: 200)
    /// - Returns: Array of normalized peak values (0.0 to 1.0)
    func extractWaveformData(binCount: Int = 200) throws -> [Float] {
        guard let file = audioFile else { return [] }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        // Read all frames into a buffer
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            return []
        }

        file.framePosition = 0
        try file.read(into: buffer)

        // Get float channel data (use first channel for mono waveform)
        guard let channelData = buffer.floatChannelData else { return [] }
        let samples = channelData[0]
        let sampleCount = Int(buffer.frameLength)

        guard sampleCount > 0 else { return [] }

        // Downsample into bins — take peak of each bin
        let samplesPerBin = max(sampleCount / binCount, 1)
        var peaks = [Float](repeating: 0, count: binCount)

        for bin in 0..<binCount {
            let start = bin * samplesPerBin
            let end = min(start + samplesPerBin, sampleCount)
            var peak: Float = 0

            for i in start..<end {
                let absSample = abs(samples[i])
                if absSample > peak {
                    peak = absSample
                }
            }

            peaks[bin] = peak
        }

        // Normalize to 0–1 range
        let maxPeak = peaks.max() ?? 1.0
        if maxPeak > 0 {
            for i in 0..<peaks.count {
                peaks[i] /= maxPeak
            }
        }

        // Reset file position
        file.framePosition = 0

        return peaks
    }

    // MARK: - Private Helpers

    /// Start the audio engine if it's not already running.
    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw AudioPlayerError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Schedule the audio file for playback starting from a specific frame.
    private func scheduleFile(_ file: AVAudioFile, from startFrame: AVAudioFramePosition) {
        // Set the file read position
        file.framePosition = startFrame

        let remainingFrames = AVAudioFrameCount(totalFrames - startFrame)
        guard remainingFrames > 0 else {
            state = .stopped
            return
        }

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: remainingFrames,
            at: nil
        ) { [weak self] in
            // Playback completed naturally
            DispatchQueue.main.async {
                self?.state = .stopped
                self?.seekFrameOffset = 0
            }
        }
    }
}
