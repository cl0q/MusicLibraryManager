import Foundation
import Testing
@testable import MLM

/// Tests for the audio transcode service.
///
/// Requires `ffmpeg` and `ffprobe` on PATH. Tests that need either are
/// disabled at runtime when the binaries aren't present, so CI without
/// ffmpeg installed still passes the rest of the suite.
struct TranscodeServiceTests {

    // MARK: - Helpers

    private static let ffmpegAvailable: Bool = {
        ProcessRunner.findExecutable("ffmpeg") != nil
            && ProcessRunner.findExecutable("ffprobe") != nil
    }()

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_transcode_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Generate a 1-second silent FLAC file (lossless source). Used as
    /// the transcode input for tests — guarantees the "always transcode"
    /// branch (lossless source).
    private func makeSilentFlac(at url: URL) async throws {
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else { return }
        _ = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y",
            "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
            "-t", "1",
            "-c:a", "flac",
            url.path
        ])
    }

    /// Read the container format and audio codec of a file via ffprobe.
    private func probe(_ url: URL) async throws -> (format: String, codec: String)? {
        guard let ffprobe = ProcessRunner.findExecutable("ffprobe") else { return nil }
        let result = try await ProcessRunner.run(ffprobe, arguments: [
            "-v", "quiet",
            "-show_entries", "format=format_name : stream=codec_name,codec_type",
            "-of", "json",
            url.path
        ])
        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let formatName = (json["format"] as? [String: Any])?["format_name"] as? String ?? ""
        let streams = json["streams"] as? [[String: Any]] ?? []
        let audioStream = streams.first { ($0["codec_type"] as? String) == "audio" }
        let codec = (audioStream?["codec_name"] as? String) ?? ""
        return (formatName, codec)
    }

    // MARK: - Tests

    /// FLAC -> M4A transcode produces an output file with AAC audio in
    /// the MP4/M4A container. We assert codec and container, not bitrate,
    /// because the encoder undershoots heavily on silent input.
    @Test
    func transcodesLosslessFlacToAac() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required for transcode test")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let flacInput = tmp.appendingPathComponent("silent.flac")
        try await makeSilentFlac(at: flacInput)
        try #require(FileManager.default.fileExists(atPath: flacInput.path),
                     "ffmpeg failed to generate the FLAC fixture")

        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let result = try await service.transcode(input: flacInput, outputDir: outputDir)

        switch result {
        case .transcoded(let outputURL):
            #expect(FileManager.default.fileExists(atPath: outputURL.path))
            #expect(outputURL.pathExtension == "m4a")

            if let info = try await probe(outputURL) {
                // m4a wraps AAC in MP4 container — format string is
                // usually "mov,mp4,m4a,3gp,3g2,mj2".
                #expect(info.format.contains("m4a") || info.format.contains("mp4"),
                        "Expected MP4/M4A container, got '\(info.format)'")
                // Codec must be some AAC variant (libfdk_aac, aac).
                #expect(info.codec.contains("aac"),
                        "Expected AAC codec, got '\(info.codec)'")
            }

        case .skipped(let reason):
            Issue.record("Lossless FLAC should be transcoded, not skipped: \(reason)")

        case .failed(let error):
            Issue.record("Transcode failed: \(error)")
        }
    }

    /// Output file should land in the requested output directory using
    /// the input's base name with an .m4a extension.
    @Test
    func transcodeOutputFollowsNamingConvention() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required for transcode test")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = tmp.appendingPathComponent("My - Song.flac")
        try await makeSilentFlac(at: input)

        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let result = try await service.transcode(input: input, outputDir: outputDir)
        if case .transcoded(let outputURL) = result {
            #expect(outputURL.lastPathComponent == "My - Song.m4a")
            #expect(outputURL.deletingLastPathComponent().path == outputDir.path)
        } else {
            Issue.record("Expected transcoded result")
        }
    }

    /// Second run with an existing output file should report `.skipped`,
    /// not overwrite, and the file on disk should be unchanged.
    @Test
    func skipsWhenOutputAlreadyExists() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required for transcode test")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = tmp.appendingPathComponent("silent.flac")
        try await makeSilentFlac(at: input)

        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let first = try await service.transcode(input: input, outputDir: outputDir)
        guard case .transcoded(let outputURL) = first else {
            Issue.record("First transcode should succeed")
            return
        }
        let firstMtime = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.modificationDate] as? Date

        let second = try await service.transcode(input: input, outputDir: outputDir)
        switch second {
        case .skipped:
            let secondMtime = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.modificationDate] as? Date
            #expect(firstMtime == secondMtime, "File should not be re-written")
        case .transcoded:
            Issue.record("Expected skipped on second transcode of same input")
        case .failed(let error):
            Issue.record("Second transcode failed: \(error)")
        }
    }

    /// Output file should land in the requested output directory using
    /// the custom outputName parameter if specified.
    @Test
    func transcodeOutputRespectsCustomOutputName() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required for transcode test")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = tmp.appendingPathComponent("silent.flac")
        try await makeSilentFlac(at: input)

        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let customName = "12345_248.m4a"
        let result = try await service.transcode(input: input, outputDir: outputDir, outputName: customName)
        if case .transcoded(let outputURL) = result {
            #expect(outputURL.lastPathComponent == customName)
            #expect(outputURL.deletingLastPathComponent().path == outputDir.path)
        } else {
            Issue.record("Expected transcoded result with custom name")
        }
    }
}
