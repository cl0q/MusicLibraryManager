import Foundation

/// Rhythmic analysis engine for computing danceability scores.
///
/// Danceability is measured by decoding audio via ffmpeg to raw 11025Hz mono 16-bit PCM,
/// computing frame-level RMS energy, identifying onset energy peaks, and evaluating the
/// Coefficient of Variation (CV) of beat intervals.
final class DanceabilityAnalyzer: Sendable {
    private let ffmpegPath: String?

    init() {
        self.ffmpegPath = ProcessRunner.findExecutable("ffmpeg")
    }

    /// Whether ffmpeg is available for analysis.
    var isAvailable: Bool { ffmpegPath != nil }

    /// Analyze danceability of a single track.
    ///
    /// Slices audio into 256-sample frames (~23.2ms), extracts energy, finds local onset maxima,
    /// and calculates the standard deviation vs. mean of intervals.
    /// Highly regular intervals (low CV) yield a high danceability score.
    func analyzeTrack(path: String) async throws -> Double? {
        guard let ffmpeg = ffmpegPath else { return nil }

        // Decode audio to 11025Hz, mono, 16-bit signed PCM, streaming raw output to stdout
        let pcmData = try await ProcessRunner.runBinary(
            ffmpeg,
            arguments: [
                "-i", path,
                "-ar", "11025",
                "-ac", "1",
                "-f", "s16le",
                "-"
            ]
        )

        guard !pcmData.isEmpty else { return nil }

        // Safe conversion from little-endian s16le bytes to Int16 samples
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return nil }

        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { bytes in
            pcmData.copyBytes(to: bytes)
        }

        // Step 1: RMS energy per frame of 256 samples (~23.2ms duration)
        let frameSize = 256
        let frameCount = sampleCount / frameSize
        guard frameCount > 10 else { return 0.0 } // Too short for analysis

        var frameEnergies = [Double](repeating: 0.0, count: frameCount)
        for f in 0..<frameCount {
            var sumSquare: Double = 0.0
            let offset = f * frameSize
            for i in 0..<frameSize {
                let sampleValue = Double(samples[offset + i]) / 32768.0 // map to [-1.0, 1.0]
                sumSquare += sampleValue * sampleValue
            }
            frameEnergies[f] = sqrt(sumSquare / Double(frameSize))
        }

        // Step 2: First-order half-wave rectified difference (Onset Strength)
        var onsetStrength = [Double](repeating: 0.0, count: frameCount)
        for f in 1..<frameCount {
            let diff = frameEnergies[f] - frameEnergies[f - 1]
            onsetStrength[f] = max(0.0, diff)
        }

        // Step 3: Peak picking in the onset strength envelope
        let sumOnset = onsetStrength.reduce(0.0, +)
        let meanOnset = sumOnset / Double(frameCount)
        let peakThreshold = meanOnset * 1.5 // Dynamic threshold relative to global activity

        var peakIndices: [Int] = []
        // Enforce 200ms spacing between peaks (corresponds to max 300 BPM)
        let minFramesBetweenPeaks = Int(0.200 * 11025.0 / Double(frameSize))

        for f in 1..<(frameCount - 1) {
            let val = onsetStrength[f]
            if val > peakThreshold && val > onsetStrength[f - 1] && val > onsetStrength[f + 1] {
                if let lastPeak = peakIndices.last {
                    if f - lastPeak >= minFramesBetweenPeaks {
                        peakIndices.append(f)
                    }
                } else {
                    peakIndices.append(f)
                }
            }
        }

        guard peakIndices.count >= 5 else {
            return 0.0 // Insufficient beats
        }

        // Convert frames to seconds
        let frameDuration = Double(frameSize) / 11025.0
        let peakTimes = peakIndices.map { Double($0) * frameDuration }

        // Step 4: Calculate interval statistics for normal musical tempos (40 - 300 BPM)
        var intervals: [Double] = []
        for i in 0..<(peakTimes.count - 1) {
            let diff = peakTimes[i + 1] - peakTimes[i]
            if diff >= 0.2 && diff <= 1.5 {
                intervals.append(diff)
            }
        }

        guard intervals.count >= 4 else { return 0.0 }

        let sumIntervals = intervals.reduce(0.0, +)
        let meanInterval = sumIntervals / Double(intervals.count)

        var varianceSum = 0.0
        for interval in intervals {
            let diff = interval - meanInterval
            varianceSum += diff * diff
        }
        let stdDev = sqrt(varianceSum / Double(intervals.count))

        // Step 5: Coefficient of Variation -> Danceability mapping
        let cv = stdDev / meanInterval
        let score = 1.0 - (cv / 0.5) // regular beats have extremely low CV (~0.0)
        return max(0.0, min(1.0, score))
    }

    /// Batch-analyze multiple tracks for Danceability with multi-threaded worker limit.
    func batchAnalyze(
        tracks: [Track],
        trackRepository: TrackRepository,
        libraryRoot: String? = nil,
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async -> (analyzed: Int, failed: Int, cancelled: Bool) {
        let tracker = MaintenanceProgressTracker(total: tracks.count, turboMode: turboMode, progressHandler: progressHandler)
        let workerCount = BatchControl.workerCount(turboMode: turboMode)
        let limiter = BatchControl.limiter(turboMode: turboMode)

        AppLogger.shared.info("Starting Danceability batch: \(tracks.count) tracks, \(workerCount) workers (turbo: \(turboMode))", source: "Danceability")

        let results: [Result<Void, Error>] = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for track in tracks {
                group.addTask {
                    guard !tracker.isCancelled else {
                        return .failure(CancellationError())
                    }
                    return await limiter.run {
                        await self.processSingleAnalysis(
                            track: track,
                            trackRepository: trackRepository,
                            libraryRoot: libraryRoot,
                            tracker: tracker
                        )
                    }
                }
            }

            var collected: [Result<Void, Error>] = []
            collected.reserveCapacity(tracks.count)
            for await result in group {
                collected.append(result)
                if tracker.isCancelled { break }
            }
            return collected
        }

        var analyzed = 0
        var failed = 0
        for result in results {
            switch result {
            case .success: analyzed += 1
            case .failure: failed += 1
            }
        }

        AppLogger.shared.info("Danceability batch complete: \(analyzed) analyzed, \(failed) failed", source: "Danceability")
        return (analyzed, failed, tracker.isCancelled)
    }

    private func processSingleAnalysis(
        track: Track,
        trackRepository: TrackRepository,
        libraryRoot: String?,
        tracker: MaintenanceProgressTracker
    ) async -> Result<Void, Error> {
        guard let trackId = track.id else {
            tracker.updateProgress(
                trackId: 0,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return .failure(NSError(domain: "Danceability", code: -1, userInfo: [NSLocalizedDescriptionKey: "No track ID"]))
        }

        let filePath: String?
        if let organized = track.organizedPath {
            let path: String
            if let root = libraryRoot, !root.isEmpty {
                path = URL(fileURLWithPath: root).appendingPathComponent(organized).path
            } else {
                path = organized
            }
            if FileManager.default.fileExists(atPath: path) {
                filePath = path
            } else if FileManager.default.fileExists(atPath: track.originalPath) {
                filePath = track.originalPath
            } else {
                filePath = nil
            }
        } else {
            filePath = track.isLocal && FileManager.default.fileExists(atPath: track.originalPath) ? track.originalPath : nil
        }

        guard let resolvedPath = filePath else {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return .failure(NSError(domain: "Danceability", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file path"]))
        }

        do {
            if let danceability = try await analyzeTrack(path: resolvedPath) {
                try await trackRepository.updateDanceability(trackId: trackId, danceability: danceability)

                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )

                AppLogger.shared.debug(
                    "Danceability [\(tracker.currentState.current)/\(tracker.currentState.total)] \(track.artist) - \(track.title) → \(Int(danceability * 100))%, saved to DB",
                    source: "Danceability"
                )
                return .success(())
            } else {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
                return .failure(NSError(domain: "Danceability", code: -1, userInfo: [NSLocalizedDescriptionKey: "Analysis failed"]))
            }
        } catch {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            AppLogger.shared.log("Danceability failed for \(track.title): \(error)", level: .warning, source: "Analysis")
            return .failure(error)
        }
    }
}
