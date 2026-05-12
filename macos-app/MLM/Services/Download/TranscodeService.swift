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

    private let ffmpegPath: String?

    init() {
        self.ffmpegPath = ProcessRunner.findExecutable("ffmpeg")
    }

    // MARK: - Public

    /// Transcode an audio file to 248kbps AAC (.m4a).
    ///
    /// Decision logic (matches Rust `transcode_audio`):
    /// - Lossless (FLAC, ALAC, WAV) → always transcode
    /// - Lossy < 248kbps → skip (preserve quality)
    /// - Lossy >= 248kbps → transcode to reduce size
    func transcode(input: URL, outputDir: URL) async throws -> TranscodeResult {
        guard let ffmpeg = ffmpegPath else {
            return .failed("ffmpeg not found")
        }

        let outputName = input.deletingPathExtension().lastPathComponent + ".m4a"
        let outputURL = outputDir.appendingPathComponent(outputName)

        // Skip if output already exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return .skipped("Output already exists")
        }

        // Detect format to decide transcode vs skip
        let formatInfo = await detectFormat(input: input, ffmpeg: ffmpeg)

        if formatInfo.isLossy && formatInfo.bitrate > 0 && formatInfo.bitrate < Self.targetBitrate * 1000 {
            // Lossy and lower quality than target — preserve original
            return .skipped("Lossy source below target bitrate (\(formatInfo.bitrate / 1000)kbps < \(Self.targetBitrate)kbps)")
        }

        // Determine which encoder to use
        let encoder = await detectEncoder(ffmpeg: ffmpeg)
        let tmpOutput = outputDir.appendingPathComponent(outputName + ".tmp.m4a")

        // First attempt: preserve cover art
        let result = try await runTranscode(
            ffmpeg: ffmpeg,
            input: input,
            output: tmpOutput,
            encoder: encoder,
            stripVideo: false
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
                stripVideo: true
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
    }

    /// Detect audio format using ffprobe.
    private func detectFormat(input: URL, ffmpeg: String) async -> FormatInfo {
        let ffprobe = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            return FormatInfo(isLossy: false, bitrate: 0)
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

                    return FormatInfo(isLossy: isLossy, bitrate: bitrate)
                }
            }
        } catch {}

        // Default: treat as lossless (always transcode)
        return FormatInfo(isLossy: false, bitrate: 0)
    }

    /// Check if libfdk_aac encoder is available.
    private func detectEncoder(ffmpeg: String) async -> String {
        do {
            let result = try await ProcessRunner.run(
                ffmpeg,
                arguments: ["-encoders"]
            )
            if result.stdout.contains("libfdk_aac") {
                return Self.preferredEncoder
            }
        } catch {}
        return Self.fallbackEncoder
    }

    /// Run ffmpeg transcode.
    private func runTranscode(
        ffmpeg: String,
        input: URL,
        output: URL,
        encoder: String,
        stripVideo: Bool
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
            "-b:a", "\(Self.targetBitrate)k",
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
                source: "Download"
            )
            return .coverArtFailure
        }

        return .failure("ffmpeg exited with code \(result.exitCode): \(result.stderr.prefix(500))")
    }
}
