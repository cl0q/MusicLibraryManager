import Foundation

/// ReplayGain loudness normalization analyzer using ffmpeg.
///
/// Measures EBU R128 loudness (LUFS, true peak) per track and per album.
/// Reference level: -18 LUFS (ReplayGain 2.0 standard).
/// Mirrors the Rust `ReplayGainAnalyzer`.
final class ReplayGainAnalyzer: Sendable {

    /// ReplayGain 2.0 reference level (NOT -23 LUFS from EBU R128 broadcast).
    static let referenceLevel: Double = -18.0

    /// Minimum loudness before clamping (silence threshold).
    private static let silenceThreshold: Double = -70.0

    /// Maximum gain to apply (for near-silent tracks).
    private static let maxGain: Double = 20.0

    private let ffmpegPath: String?

    init() {
        self.ffmpegPath = ProcessRunner.findExecutable("ffmpeg")
    }

    /// Whether ffmpeg is available for analysis.
    var isAvailable: Bool { ffmpegPath != nil }

    // MARK: - Track Analysis

    struct GainResult {
        let trackGain: Double   // dB to apply
        let trackPeak: Double   // true peak (linear)
        let loudness: Double    // measured LUFS
    }

    /// Analyze loudness of a single track using ffmpeg's ebur128 filter.
    func analyzeTrack(path: String) async throws -> GainResult? {
        guard let ffmpeg = ffmpegPath else { return nil }

        let result = try await ProcessRunner.run(
            ffmpeg,
            arguments: [
                "-i", path,
                "-af", "ebur128=peak=true",
                "-f", "null",
                "-"
            ]
        )

        // ebur128 outputs to stderr
        return parseEBUR128Output(result.stderr)
    }

    /// Batch-analyze multiple tracks for ReplayGain.
    ///
    /// - Parameters:
    ///   - tracks: Tracks to analyze
    ///   - repository: Analysis repository for saving results
    ///   - trackRepository: Track repository for updating energy buckets
    ///   - onProgress: Progress callback (index, total)
    /// - Returns: Count of analyzed and failed tracks
    func batchAnalyze(
        tracks: [Track],
        repository: AnalysisRepository,
        trackRepository: TrackRepository,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> (analyzed: Int, failed: Int) {
        var analyzed = 0
        var failed = 0

        for (index, track) in tracks.enumerated() {
            onProgress?(index, tracks.count)

            guard let trackId = track.id,
                  let filePath = track.organizedPath ?? (track.isLocal ? track.originalPath : nil) else {
                failed += 1
                continue
            }

            do {
                if let gain = try await analyzeTrack(path: filePath) {
                    // Save ReplayGain data
                    let rg = ReplayGain(
                        trackId: trackId,
                        trackGain: gain.trackGain,
                        trackPeak: gain.trackPeak,
                        albumGain: nil,
                        albumPeak: nil,
                        analyzedAt: ISO8601DateFormatter().string(from: Date())
                    )
                    try await repository.saveReplayGain(rg)

                    // Compute and save energy bucket
                    let bucket = EnergyBucketer.bucket(lufs: gain.loudness)
                    try await trackRepository.updateEnergyBucket(
                        trackId: trackId,
                        energyBucket: bucket,
                        lufsI: gain.loudness
                    )

                    analyzed += 1
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
                AppLogger.shared.log("ReplayGain failed for \(track.title): \(error)", level: .warning, source: "Analysis")
            }
        }

        return (analyzed, failed)
    }

    // MARK: - Parsing

    /// Parse ffmpeg's ebur128 filter output for integrated loudness and true peak.
    private func parseEBUR128Output(_ output: String) -> GainResult? {
        // Look for "Integrated loudness:" section
        // Format: "I:         -14.0 LUFS"
        // Format: "Peak:        -1.2 dBFS" or "True peak: X dBFS"

        var loudness: Double?
        var truePeak: Double?

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Integrated loudness
            if trimmed.contains("I:") && trimmed.contains("LUFS") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let idx = parts.firstIndex(of: "LUFS"), idx > 0 {
                    loudness = Double(parts[idx - 1])
                }
            }

            // True peak
            if trimmed.contains("Peak:") && trimmed.contains("dBFS") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let idx = parts.firstIndex(of: "dBFS"), idx > 0 {
                    if let peakDB = Double(parts[idx - 1]) {
                        // Convert dBFS to linear
                        truePeak = pow(10.0, peakDB / 20.0)
                    }
                }
            }
        }

        guard let lufs = loudness else { return nil }

        // Handle silence
        if lufs < Self.silenceThreshold || lufs.isInfinite || lufs.isNaN {
            return GainResult(trackGain: Self.maxGain, trackPeak: 0.0, loudness: lufs)
        }

        let gain = Self.referenceLevel - lufs
        let peak = truePeak ?? 0.0

        return GainResult(trackGain: gain, trackPeak: peak, loudness: lufs)
    }
}

// MARK: - Energy Bucketer

/// Converts LUFS loudness to a 1-5 energy scale.
///
/// Mirrors the Rust `EnergyBucketer`. Maps integrated LUFS to
/// perceptual energy levels for the library table's energy column.
enum EnergyBucketer {
    /// Map integrated loudness (LUFS) to an energy bucket (1-5).
    ///
    /// Thresholds (from Rust implementation):
    /// - 1 (quiet): LUFS < -20
    /// - 2 (calm):  -20 ≤ LUFS < -16
    /// - 3 (moderate): -16 ≤ LUFS < -12
    /// - 4 (loud):  -12 ≤ LUFS < -8
    /// - 5 (intense): LUFS ≥ -8
    static func bucket(lufs: Double) -> Int {
        if lufs.isNaN || lufs.isInfinite || lufs < -20.0 {
            return 1
        } else if lufs < -16.0 {
            return 2
        } else if lufs < -12.0 {
            return 3
        } else if lufs < -8.0 {
            return 4
        } else {
            return 5
        }
    }
}
