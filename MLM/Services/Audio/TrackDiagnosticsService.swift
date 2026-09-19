import Foundation

/// Lazy ffmpeg/ffprobe diagnostics for a single local audio file.
///
/// Runs two passes on demand:
/// 1. **ffprobe** — JSON metadata (container, codec, sample rate, channels, bitrate, duration).
/// 2. **ffmpeg** — full decode to `/dev/null` (`-f null -`) to surface corrupt frames,
///    decode errors, and warnings that a metadata probe would miss.
///
/// All work is best-effort: `diagnose` never throws. When ffmpeg is absent the
/// caller receives `nil`; when ffprobe is absent the probe fields stay `nil`
/// but the decode pass still runs.
enum TrackDiagnosticsService {

    // MARK: - Models

    /// Aggregated result of probing and decoding one audio file.
    struct TrackDiagnostics: Equatable, Sendable {
        var containerFormat: String?
        var codecName: String?
        var sampleRateHz: Int?
        var channels: Int?
        var channelLayout: String?
        var bitrateKbps: Int?
        var durationSeconds: Double?

        var decodeExitCode: Int32
        var errorCount: Int
        var warningCount: Int
        var brokenFrameCount: Int

        var errorLines: [String]
        var warningLines: [String]
        var probeErrorLines: [String]

        var ffmpegPath: String
        var ranAt: Date
    }

    /// Intermediate parse of ffmpeg's stderr during the decode pass.
    struct DecodeSummary: Equatable, Sendable {
        var errorLines: [String]
        var warningLines: [String]
        var brokenFrameCount: Int
    }

    // MARK: - Pure parser (unit-tested)

    /// Split ffmpeg stderr into error / warning buckets and count broken frames.
    ///
    /// Rules:
    /// - Lines are trimmed; empty lines are dropped.
    /// - A line containing "warning" (case-insensitive) is a warning; everything else is an error.
    /// - `brokenFrameCount` counts lines matching the corrupt/incomplete-frame regex.
    /// - Both `errorLines` and `warningLines` are capped at 250 entries.
    static func parseDecodeOutput(_ stderr: String) -> DecodeSummary {
        let brokenFramePattern = #"(?i)(incomplete frame|invalid frame|corrupt(ed)? (input )?(frame|packet|block)|error while decoding|invalid data found)"#
        let brokenFrameRegex = try? NSRegularExpression(pattern: brokenFramePattern)

        var errorLines: [String] = []
        var warningLines: [String] = []
        var brokenFrameCount = 0

        let rawLines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let lower = trimmed.lowercased()
            let isWarning = lower.contains("warning")

            if brokenFrameRegex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                brokenFrameCount += 1
            }

            if isWarning {
                if warningLines.count < 250 { warningLines.append(trimmed) }
            } else {
                if errorLines.count < 250 { errorLines.append(trimmed) }
            }
        }

        return DecodeSummary(
            errorLines: errorLines,
            warningLines: warningLines,
            brokenFrameCount: brokenFrameCount
        )
    }

    // MARK: - Diagnose

    /// Probe and decode `fileURL`, returning aggregated diagnostics.
    ///
    /// Returns `nil` when ffmpeg is not installed (the decode pass is the
    /// whole point; a probe-only result would be misleading).
    static func diagnose(fileURL: URL) async -> TrackDiagnostics? {
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else { return nil }
        let ffprobe = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let hasFFprobe = FileManager.default.isExecutableFile(atPath: ffprobe)

        // --- ffprobe pass ---
        var containerFormat: String?
        var codecName: String?
        var sampleRateHz: Int?
        var channels: Int?
        var channelLayout: String?
        var bitrateKbps: Int?
        var durationSeconds: Double?
        var probeErrorLines: [String] = []

        if hasFFprobe {
            do {
                let probeResult = try await ProcessRunner.run(ffprobe, arguments: [
                    "-v", "error",
                    "-show_format",
                    "-show_streams",
                    "-print_format", "json",
                    fileURL.path
                ])
                if let data = probeResult.stdout.data(using: .utf8),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let streams = json["streams"] as? [[String: Any]] ?? []
                    let audioStream = streams.first { ($0["codec_type"] as? String) == "audio" }
                        ?? streams.first
                    if let s = audioStream {
                        codecName = s["codec_name"] as? String
                        if let sr = s["sample_rate"] as? String { sampleRateHz = Int(sr) }
                        else if let sr = s["sample_rate"] as? Int { sampleRateHz = sr }
                        if let ch = s["channels"] as? Int { channels = ch }
                        channelLayout = s["channel_layout"] as? String
                        if let br = s["bit_rate"] as? String { bitrateKbps = Int(br).map { $0 / 1000 } }
                        else if let br = s["bit_rate"] as? Int { bitrateKbps = br / 1000 }
                    }
                    if let fmt = json["format"] as? [String: Any] {
                        containerFormat = fmt["format_name"] as? String
                        if durationSeconds == nil, let d = fmt["duration"] as? String {
                            durationSeconds = Double(d)
                        }
                        if bitrateKbps == nil, let br = fmt["bit_rate"] as? String {
                            bitrateKbps = Int(br).map { $0 / 1000 }
                        }
                        else if bitrateKbps == nil, let br = fmt["bit_rate"] as? Int {
                            bitrateKbps = br / 1000
                        }
                    }
                }
                // Capture probe stderr as informational lines.
                let stderrLines = probeResult.stderr
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                probeErrorLines = stderrLines
                AppLogger.shared.log(
                    "Diagnostics ffprobe pass completed for \(fileURL.lastPathComponent) (exit \(probeResult.exitCode))",
                    source: "Diagnostics"
                )
            } catch {
                probeErrorLines = [error.localizedDescription]
                AppLogger.shared.log(
                    "Diagnostics ffprobe pass failed for \(fileURL.lastPathComponent): \(error.localizedDescription)",
                    level: .error,
                    source: "Diagnostics"
                )
            }
        }

        // --- decode pass ---
        var decodeExitCode: Int32 = -1
        var summary = DecodeSummary(errorLines: [], warningLines: [], brokenFrameCount: 0)

        do {
            let decodeResult = try await ProcessRunner.run(ffmpeg, arguments: [
                "-v", "warning",
                "-i", fileURL.path,
                "-f", "null",
                "-"
            ])
            decodeExitCode = decodeResult.exitCode
            summary = parseDecodeOutput(decodeResult.stderr)
            AppLogger.shared.log(
                "Diagnostics decode pass completed for \(fileURL.lastPathComponent) (exit \(decodeExitCode), errors \(summary.errorLines.count), warnings \(summary.warningLines.count), broken frames \(summary.brokenFrameCount))",
                source: "Diagnostics"
            )
        } catch {
            decodeExitCode = -1
            summary.errorLines = [error.localizedDescription]
            AppLogger.shared.log(
                "Diagnostics decode pass failed for \(fileURL.lastPathComponent): \(error.localizedDescription)",
                level: .error,
                source: "Diagnostics"
            )
        }

        return TrackDiagnostics(
            containerFormat: containerFormat,
            codecName: codecName,
            sampleRateHz: sampleRateHz,
            channels: channels,
            channelLayout: channelLayout,
            bitrateKbps: bitrateKbps,
            durationSeconds: durationSeconds,
            decodeExitCode: decodeExitCode,
            errorCount: summary.errorLines.count,
            warningCount: summary.warningLines.count,
            brokenFrameCount: summary.brokenFrameCount,
            errorLines: summary.errorLines,
            warningLines: summary.warningLines,
            probeErrorLines: probeErrorLines,
            ffmpegPath: ffmpeg,
            ranAt: Date()
        )
    }
}
