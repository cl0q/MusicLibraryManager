import Foundation

/// Audio transcoding service using ffmpeg CLI.
///
/// Handles FLAC/lossless → 248kbps AAC (m4a) conversion.
/// Preserves embedded cover art with `-c:v copy -disposition:v attached_pic`,
/// falling back to `-vn` if cover art stream causes errors.
final class TranscodeService: Sendable {

    enum TranscodeResult {
        case transcoded(URL)
        case skipped(String)
        case failed(String)
    }

    /// Target bitrate in kbps for AAC output.
    static let targetBitrate = 248

    /// Preferred AAC encoder (Fraunhofer FDK, highest quality).
    private static let preferredEncoder = "libfdk_aac"
    /// Fallback encoder (built-in FFmpeg AAC).
    private static let fallbackEncoder = "aac"

    private static let encoderLock = NSLock()
    private static var cachedEncoder: String? = nil

    private let ffmpegPath: String?

    init() {
        self.ffmpegPath = ProcessRunner.findExecutable("ffmpeg")
    }

    // MARK: - Public

    /// Transcode an audio file to AAC (.m4a) at the specified bitrate.
    ///
    /// Decision logic (matches Rust `transcode_audio`):
    /// - Lossless (FLAC, ALAC, WAV) → always transcode
    /// - Lossy < bitrateKbps → skip (preserve quality)
    /// - Lossy >= bitrateKbps → transcode to reduce size
    ///
    /// - Parameter bitrateKbps: Target AAC bitrate in kbps. Defaults to 248 for back-compat.
    func transcode(
        input: URL,
        outputDir: URL,
        outputName: String? = nil,
        bitrateKbps: Int = 248,
        sourceFormat: String? = nil,
        sourceBitrate: Int? = nil
    ) async throws -> TranscodeResult {
        guard let ffmpeg = ffmpegPath else {
            AppLogger.shared.error(
                "transcode: ffmpeg not found in PATH (~/.local/bin, /opt/homebrew/bin, /usr/local/bin, /opt/local/bin, /usr/bin)",
                source: "Transcode"
            )
            return .failed("ffmpeg not found")
        }
        AppLogger.shared.debug(
            "transcode: input=\(input.lastPathComponent) → \(bitrateKbps)k AAC (ffmpeg=\(ffmpeg))",
            source: "Transcode"
        )

        let finalOutputName = outputName ?? (input.deletingPathExtension().lastPathComponent + ".m4a")
        let outputURL = outputDir.appendingPathComponent(finalOutputName)

        // Skip if output already exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return .skipped("Output already exists")
        }

        // Detect format to decide transcode vs skip
        let formatInfo: FormatInfo
        if let sFormat = sourceFormat, let sBitrate = sourceBitrate {
            let losslessCodecs = Set(["flac", "alac", "wavpack", "pcm_s16le", "pcm_s24le", "pcm_s32le"])
            let isLossy = !losslessCodecs.contains(sFormat.lowercased())
            formatInfo = FormatInfo(isLossy: isLossy, bitrate: sBitrate * 1000, codec: sFormat.lowercased())
            AppLogger.shared.debug(
                "transcode: Using pre-loaded database metadata for \(input.lastPathComponent) (codec: \(sFormat), bitrate: \(sBitrate)kbps) - bypassed ffprobe!",
                source: "Transcode"
            )
        } else {
            formatInfo = await detectFormat(input: input, ffmpeg: ffmpeg)
        }

        if formatInfo.isLossy && formatInfo.bitrate > 0 && formatInfo.bitrate < bitrateKbps * 1000 {
            // Only skip transcode if the source format is ALREADY an AAC file!
            // E.g. codec contains "aac". If it is "mp3", we MUST transcode it so that 
            // the resulting .m4a file is a valid AAC file in an MP4 container, not an MP3 renamed to .m4a!
            let isAlreadyAAC = formatInfo.codec.contains("aac") || formatInfo.codec.contains("mp4")
            if isAlreadyAAC {
                return .skipped("Lossy source already AAC below target bitrate (\(formatInfo.bitrate / 1000)kbps < \(bitrateKbps)kbps)")
            }
        }

        // Determine which encoder to use
        let encoder = await detectEncoder(ffmpeg: ffmpeg)
        let tmpOutput = outputDir.appendingPathComponent(finalOutputName + ".tmp.m4a")

        // First attempt: preserve cover art
        let result = try await runTranscode(
            ffmpeg: ffmpeg,
            input: input,
            output: tmpOutput,
            encoder: encoder,
            stripVideo: false,
            bitrateKbps: bitrateKbps
        )

        switch result {
        case .success:
            try FileManager.default.moveItem(at: tmpOutput, to: outputURL)
            return .transcoded(outputURL)

        case .coverArtFailure:
            // Retry without video streams
            try? FileManager.default.removeItem(at: tmpOutput)
            let retry = try await runTranscode(
                ffmpeg: ffmpeg,
                input: input,
                output: tmpOutput,
                encoder: encoder,
                stripVideo: true,
                bitrateKbps: bitrateKbps
            )
            switch retry {
            case .success:
                try FileManager.default.moveItem(at: tmpOutput, to: outputURL)
                return .transcoded(outputURL)
            case .coverArtFailure:
                try? FileManager.default.removeItem(at: tmpOutput)
                return .failed("Transcode failed: cover art issue persists after retry")
            case .failure(let msg):
                try? FileManager.default.removeItem(at: tmpOutput)
                return .failed(msg)
            }

        case .failure(let msg):
            try? FileManager.default.removeItem(at: tmpOutput)
            return .failed(msg)
        }
    }

    /// Read the actual bitrate of a file in kbps via ffprobe. Returns nil
    /// when ffprobe is unavailable or the file has no decodable audio
    /// stream. Used by the orchestrator to populate the `bitrate` column
    /// after a `.skipped` transcode (lossy source preserved as-is, so the
    /// final bitrate equals the source bitrate, not the 248k target).
    func detectBitrateKbps(_ file: URL) async -> Int? {
        guard let ffmpeg = ffmpegPath else { return nil }
        let info = await detectFormat(input: file, ffmpeg: ffmpeg)
        guard info.bitrate > 0 else { return nil }
        return info.bitrate / 1000
    }

    // MARK: - Private

    private enum FFmpegResult {
        case success
        case coverArtFailure
        case failure(String)
    }

    private struct FormatInfo {
        var isLossy: Bool
        var bitrate: Int  // bits per second
        var codec: String // e.g. "mp3", "aac", "flac"
    }

    /// Detect audio format using ffprobe.
    private func detectFormat(input: URL, ffmpeg: String) async -> FormatInfo {
        let ffprobe = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            return FormatInfo(isLossy: false, bitrate: 0, codec: "")
        }

        do {
            let result = try await ProcessRunner.run(
                ffprobe,
                arguments: [
                    "-v", "quiet",
                    "-show_entries", "stream=codec_name,bit_rate",
                    "-of", "json",
                    input.path
                ]
            )

            if result.isSuccess, let data = result.stdout.data(using: .utf8) {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let streams = json?["streams"] as? [[String: Any]],
                   let stream = streams.first {
                    let codec = stream["codec_name"] as? String ?? ""
                    let bitrateStr = stream["bit_rate"] as? String ?? "0"
                    let bitrate = Int(bitrateStr) ?? 0

                    let losslessCodecs = Set(["flac", "alac", "wavpack", "pcm_s16le", "pcm_s24le", "pcm_s32le"])
                    let isLossy = !losslessCodecs.contains(codec.lowercased())

                    return FormatInfo(isLossy: isLossy, bitrate: bitrate, codec: codec.lowercased())
                }
            }
        } catch {}

        // Default: treat as lossless (always transcode)
        return FormatInfo(isLossy: false, bitrate: 0, codec: "")
    }

    /// Check if libfdk_aac encoder is available.
    private func detectEncoder(ffmpeg: String) async -> String {
        if let cached = Self.encoderLock.withLock({ Self.cachedEncoder }) {
            return cached
        }

        do {
            let result = try await ProcessRunner.run(
                ffmpeg,
                arguments: ["-encoders"]
            )
            let encoder = result.stdout.contains("libfdk_aac") ? Self.preferredEncoder : Self.fallbackEncoder
            
            Self.encoderLock.withLock {
                Self.cachedEncoder = encoder
            }
            
            return encoder
        } catch {
            return Self.fallbackEncoder
        }
    }

    /// Run ffmpeg transcode.
    private func runTranscode(
        ffmpeg: String,
        input: URL,
        output: URL,
        encoder: String,
        stripVideo: Bool,
        bitrateKbps: Int = 248
    ) async throws -> FFmpegResult {
        // Explicitly map the audio stream (mandatory) and the video stream
        // when present (optional `?` modifier — ffmpeg won't fail if the
        // input has no embedded artwork). Without explicit mapping, ffmpeg
        // sometimes picks the wrong stream when both are present.
        var args = [
            "-i", input.path,
            "-map", "0:a",
        ]

        if stripVideo {
            // Strip any embedded image stream. -vn is the documented way;
            // it overrides the `-map 0:v?` we'd otherwise add.
            args += ["-vn"]
        } else {
            // Preserve cover art: copy the video stream untouched and tag
            // it as attached_pic so iTunes/Music.app picks it up.
            args += [
                "-map", "0:v?",
                "-c:v", "copy",
                "-disposition:v", "attached_pic",
            ]
        }

        args += [
            "-c:a", encoder,
            "-b:a", "\(bitrateKbps)k",
            "-movflags", "+faststart",
            "-y", output.path,
        ]

        let result = try await ProcessRunner.run(ffmpeg, arguments: args)

        if result.isSuccess {
            return .success
        }

        // Check for cover art / video stream related failures. PNG covers
        // are the canonical exit-234 case but ffmpeg surfaces several
        // wordings depending on version, so check for all of them.
        let stderr = result.stderr.lowercased()
        let isCoverArtIssue = !stripVideo && (
            result.exitCode == 234 ||
            stderr.contains("attached_pic") ||
            stderr.contains("video stream") ||
            stderr.contains("could not find tag for codec") ||
            stderr.contains("could not write header") ||
            stderr.contains("png") && stderr.contains("video")
        )

        if isCoverArtIssue {
            AppLogger.shared.log(
                "ffmpeg cover-art mux failed (exit \(result.exitCode)); retrying with -vn",
                level: .warning,
                source: "Transcode"
            )
            return .coverArtFailure
        }

        let stderrTail = result.stderr.suffix(800)
        AppLogger.shared.error(
            "ffmpeg failed exit=\(result.exitCode) input=\(input.lastPathComponent) encoder=\(encoder) bitrate=\(bitrateKbps)k stripVideo=\(stripVideo) stderr=\(stderrTail)",
            source: "Transcode"
        )
        return .failure("ffmpeg exited with code \(result.exitCode): \(stderrTail)")
    }
}
