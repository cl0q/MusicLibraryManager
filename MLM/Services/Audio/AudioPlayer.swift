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

    /// Incremented on every seek/stop so stale completion callbacks are ignored.
    private var scheduleGeneration: Int = 0

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
            // Two known reasons Apple's ExtAudioFile rejects something
            // ffmpeg / VLC happily play:
            //
            // 1. Wrong extension — WAV PCM saved as `.mp3` (SoundCloud /
            //    leak rip pattern). Fix: symlink with correct extension.
            //
            // 2. ID3v2 prefix wrapping a different container — many Yeat
            //    unreleased MP3s are actually WAV files prefixed with a
            //    huge ID3v2.4 tag (artwork + metadata). Apple sees `ID3`
            //    + `.mp3` extension, expects MPEG frames after the tag,
            //    finds `RIFF` instead, bails. Fix: copy the bytes
            //    *after* the ID3 tag into a temp file with the correct
            //    extension and load that.
            if let cleanedURL = try? Self.rewriteIfFormatMismatch(for: url),
               cleanedURL != url,
               let file = try? AVAudioFile(forReading: cleanedURL) {
                self.audioFile = file
                self.audioFormat = file.processingFormat
                self.sampleRate = file.processingFormat.sampleRate
                self.totalFrames = file.length
                self.duration = Double(file.length) / file.processingFormat.sampleRate
                self.seekFrameOffset = 0
                return
            }
            throw AudioPlayerError.cannotOpenFile(url.path, error.localizedDescription)
        }
    }

    /// Sniff `url`. If we detect a known container at a non-zero offset
    /// (i.e. an ID3v2 tag wraps a WAV/FLAC), copy the post-tag bytes to
    /// a temp file with the correct extension and return its URL. If the
    /// container is at offset 0 but the extension is wrong, symlink it.
    /// Returns the original URL when no remediation is needed or possible.
    private static func rewriteIfFormatMismatch(for url: URL) throws -> URL {
        guard let detected = sniffContainer(at: url) else { return url }
        let actualExt = url.pathExtension.lowercased()

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlm-format-fix", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let base = url.deletingPathExtension().lastPathComponent
        let hash = String(url.path.hashValue, radix: 16)
        let outURL = tempDir.appendingPathComponent("\(base)-\(hash).\(detected.extension)")

        if FileManager.default.fileExists(atPath: outURL.path) {
            return outURL
        }

        if detected.offset == 0 {
            // No prefix to strip — just hand AVAudioFile the same bytes
            // under a name it understands.
            if detected.extension == actualExt { return url }
            try FileManager.default.createSymbolicLink(at: outURL, withDestinationURL: url)
            return outURL
        }

        // Strip the prefix. Stream the source from `detected.offset` to a
        // fresh file in 1 MiB chunks so we don't pull a 40 MiB rip into
        // memory all at once.
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(detected.offset))

        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL)
        defer { try? output.close() }

        while true {
            let chunk = input.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            output.write(chunk)
        }
        return outURL
    }

    /// Detect the real audio container, accounting for ID3v2 prefixes that
    /// can wrap an entirely different format underneath. Returns the
    /// canonical extension and the byte offset where the real container
    /// starts (0 when the file is unprefixed).
    private static func sniffContainer(at url: URL) -> (extension: String, offset: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = handle.readData(ofLength: 10)
        guard data.count >= 4 else { return nil }
        let head = [UInt8](data)

        var payloadOffset = 0

        // ID3v2 header at byte 0 — compute synchsafe size and skip past it.
        if data.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
            let size = (Int(head[6] & 0x7F) << 21) |
                       (Int(head[7] & 0x7F) << 14) |
                       (Int(head[8] & 0x7F) << 7) |
                        Int(head[9] & 0x7F)
            let hasFooter = (head[5] & 0x10) != 0
            payloadOffset = 10 + size + (hasFooter ? 10 : 0)

            try? handle.seek(toOffset: UInt64(payloadOffset))
            data = handle.readData(ofLength: 12)
            // If nothing follows or we can't sniff, treat as plain mp3 —
            // the ID3 tag belongs to an MP3 file with normal frames that
            // simply don't start at byte 0 from our 12-byte window's POV.
            guard data.count >= 4 else { return ("mp3", 0) }
        }

        let b = [UInt8](data)

        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return ("wav", payloadOffset) }
        if b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { return ("flac", payloadOffset) }
        if b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 { return ("ogg", payloadOffset) }
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return ("mp3", 0) }  // raw MP3 frame sync
        if b.count >= 8,
           b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            return ("m4a", payloadOffset)
        }
        // If we got here after stripping an ID3 tag, assume MP3 (the tag
        // implies it). Without a tag we can't claim anything.
        if payloadOffset > 0 { return ("mp3", 0) }
        return nil
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
        scheduleGeneration += 1
        playerNode.stop()
        seekFrameOffset = 0
        state = .stopped
    }

    /// Set the playback node volume (0.0–1.0).
    func setVolume(_ volume: Float) {
        playerNode.volume = min(max(volume, 0), 1)
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
        guard let file = audioFile, binCount > 0 else { return [] }

        let totalFrames = file.length
        guard totalFrames > 0 else { return [] }

        // Process in 64K-frame chunks so a 2-hour stereo float32 file caps
        // at ~512 KB of RAM instead of the ~2.5 GB single-buffer alloc the
        // naïve implementation produced (which caused a SIGABRT in
        // LaunchServices via memory pressure during slider scrubbing).
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkFrames
        ) else {
            return []
        }

        let framesPerBin = max(Int(totalFrames) / binCount, 1)
        var peaks = [Float](repeating: 0, count: binCount)

        file.framePosition = 0
        var sourceFrameIndex = 0

        while sourceFrameIndex < Int(totalFrames) {
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
        scheduleGeneration += 1
        let generation = scheduleGeneration

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
            // Only handle natural end-of-track; ignore callbacks from stopped/seeked segments.
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.state = .stopped
                self.seekFrameOffset = 0
            }
        }
    }
}
