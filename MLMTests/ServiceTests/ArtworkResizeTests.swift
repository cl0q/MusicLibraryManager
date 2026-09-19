import Testing
import Foundation
import GRDB
@testable import MLM

// MARK: - Arg-builder tests (pure, no ffmpeg)

@Suite("ArtworkResizeArgBuilderTests")
struct ArtworkResizeArgBuilderTests {

    @Test func resizeModeContainsVfAndScaleString() {
        let args = TranscodeService.transcodeArguments(
            input: "/in.flac",
            output: "/out.m4a",
            encoder: "libfdk_aac",
            bitrateKbps: 248,
            stripVideo: false,
            normalizationGainDB: nil,
            artworkMaxPx: 250
        )
        #expect(args.contains("-vf"))
        #expect(args.contains("scale=250:250:force_original_aspect_ratio=decrease:force_divisible_by=2"))
        #expect(args.contains("-c:v"))
        let cvIdx = args.firstIndex(of: "-c:v")!
        #expect(args[cvIdx + 1] == "mjpeg")
    }

    @Test func resizeModeDoesNotContainCopyCodec() {
        let args = TranscodeService.transcodeArguments(
            input: "/in.flac",
            output: "/out.m4a",
            encoder: "libfdk_aac",
            bitrateKbps: 248,
            stripVideo: false,
            normalizationGainDB: nil,
            artworkMaxPx: 250
        )
        // -c:v copy must NOT appear in resize mode
        let cvIdx = args.firstIndex(of: "-c:v")!
        #expect(args[cvIdx + 1] != "copy")
    }

    @Test func keepOriginalModeContainsCopyCodecAndNoVf() {
        let args = TranscodeService.transcodeArguments(
            input: "/in.flac",
            output: "/out.m4a",
            encoder: "libfdk_aac",
            bitrateKbps: 248,
            stripVideo: false,
            normalizationGainDB: nil,
            artworkMaxPx: nil
        )
        #expect(args.contains("-c:v"))
        let cvIdx = args.firstIndex(of: "-c:v")!
        #expect(args[cvIdx + 1] == "copy")
        #expect(!args.contains("-vf"))
    }

    @Test func stripVideoModeContainsVnAndNoVfOrCV() {
        let args = TranscodeService.transcodeArguments(
            input: "/in.flac",
            output: "/out.m4a",
            encoder: "libfdk_aac",
            bitrateKbps: 248,
            stripVideo: true,
            normalizationGainDB: nil,
            artworkMaxPx: 250  // should be ignored when stripVideo is true
        )
        #expect(args.contains("-vn"))
        #expect(!args.contains("-vf"))
        #expect(!args.contains("-c:v"))
    }

    @Test func faststartPresentBeforeOutputInAllNonStripVariants() {
        for artworkPx in [nil, 250] {
            let args = TranscodeService.transcodeArguments(
                input: "/in.flac",
                output: "/out.m4a",
                encoder: "libfdk_aac",
                bitrateKbps: 248,
                stripVideo: false,
                normalizationGainDB: nil,
                artworkMaxPx: artworkPx
            )
            #expect(args.contains("-movflags"))
            #expect(args.contains("+faststart"))
            guard let movIdx = args.firstIndex(of: "-movflags"),
                  let outIdx = args.firstIndex(of: "/out.m4a") else {
                Issue.record("missing -movflags or output in args")
                continue
            }
            #expect(movIdx < outIdx, "-movflags must appear before the output path (artworkMaxPx=\(String(describing: artworkPx)))")
        }
    }

    @Test func audioStreamCopyEmitsCopyCodecAndNoBitrate() {
        let args = TranscodeService.transcodeArguments(
            input: "/in.m4a",
            output: "/out.m4a",
            encoder: "",
            bitrateKbps: 0,
            stripVideo: false,
            normalizationGainDB: nil,
            artworkMaxPx: 250,
            audioStreamCopy: true
        )
        #expect(args.contains("-c:a"))
        let caIdx = args.firstIndex(of: "-c:a")!
        #expect(args[caIdx + 1] == "copy")
        #expect(!args.contains("-b:a"))
    }
}

// MARK: - Model tests

@Suite("ArtworkModeModelTests")
struct ArtworkModeModelTests {

    @Test func artworkModeEnumRoundTrips() {
        var profile = SyncProfile(name: "Test", outputFolder: "/tmp")
        profile.artworkMode = "keep_original"
        #expect(profile.artworkModeEnum == .keepOriginal)

        profile.artworkMode = "resize_250"
        #expect(profile.artworkModeEnum == .resize250)
    }

    @Test func artworkModeEnumFallsBackOnGarbage() {
        var profile = SyncProfile(name: "Test", outputFolder: "/tmp")
        profile.artworkMode = "nonsense_value"
        #expect(profile.artworkModeEnum == .keepOriginal)
    }

    @Test func defaultProfileIsKeepOriginal() {
        let profile = SyncProfile(name: "Test", outputFolder: "/tmp")
        #expect(profile.artworkMode == "keep_original")
        #expect(profile.artworkModeEnum == .keepOriginal)
    }
}

// MARK: - Cache-key tests

@Suite("ArtworkCacheKeyTests")
struct ArtworkCacheKeyTests {

    @Test func cachePathDistinctForNilVs250() {
        let cache = TranscodeCache(cacheDir: URL(fileURLWithPath: "/tmp/test_cache"))
        let plain = cache.cachePath(trackId: 42, bitrateKbps: 248, normalized: false, artworkMaxPx: nil)
        let resized = cache.cachePath(trackId: 42, bitrateKbps: 248, normalized: false, artworkMaxPx: 250)
        #expect(plain.lastPathComponent != resized.lastPathComponent)
    }

    @Test func cachePathNilFormIsBackCompat() {
        let cache = TranscodeCache(cacheDir: URL(fileURLWithPath: "/tmp/test_cache"))
        let withNil = cache.cachePath(trackId: 42, bitrateKbps: 248, normalized: false, artworkMaxPx: nil)
        // Should be byte-identical to the old naming: 42_248.m4a
        #expect(withNil.lastPathComponent == "42_248.m4a")
    }

    @Test func cachePathArtSuffixIsCorrect() {
        let cache = TranscodeCache(cacheDir: URL(fileURLWithPath: "/tmp/test_cache"))
        let path = cache.cachePath(trackId: 123, bitrateKbps: 320, normalized: true, artworkMaxPx: 250)
        #expect(path.lastPathComponent == "123_320_norm_art250.m4a")
    }
}

// MARK: - Migration test

@Suite("ArtworkModeMigrationTests")
struct ArtworkModeMigrationTests {

    @Test func artworkModeColumnExistsAfterMigration() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "sync_profiles").map(\.name)
            #expect(columns.contains("artwork_mode"))
        }
    }

    @Test func artworkModeDefaultIsKeepOriginal() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix)
                VALUES ('ArtTest', '/tmp/art', '')
            """)
        }
        try await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_profiles WHERE name = 'ArtTest'")!
            #expect(row["artwork_mode"] == "keep_original")
        }
    }

    @Test func preExistingProfileNotClobbered() async throws {
        let db = try DatabaseManager.inMemory()
        // Insert a row, then update artwork_mode to resize_250
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix)
                VALUES ('PreExisting', '/tmp/pre', '')
            """)
            try db.execute(sql: """
                UPDATE sync_profiles SET artwork_mode = 'resize_250' WHERE name = 'PreExisting'
            """)
        }
        try await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_profiles WHERE name = 'PreExisting'")!
            #expect(row["artwork_mode"] == "resize_250")
        }
    }
}

// MARK: - Empirical transcode tests (graceful skip without ffmpeg)

@Suite("ArtworkResizeEmpiricalTests")
struct ArtworkResizeEmpiricalTests {

    private static let ffmpegAvailable: Bool = {
        ProcessRunner.findExecutable("ffmpeg") != nil
            && ProcessRunner.findExecutable("ffprobe") != nil
    }()

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_artwork_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Build a WAV source with a large embedded cover (600×600 blue JPEG).
    private func makeSourceWithCover(at dir: URL) async throws -> URL {
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let coverPath = dir.appendingPathComponent("cover.jpg").path

        // Generate a 600×600 blue JPEG
        let coverResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "color=c=blue:s=600x600:d=0.04",
            "-frames:v", "1", "-update", "1",
            coverPath
        ])
        guard coverResult.isSuccess else {
            throw TestError.fixtureGeneration("cover generation failed")
        }

        // Generate a source with the cover embedded as a video stream in a .mkv
        // container (we'll transcode to m4a later)
        let mkvPath = dir.appendingPathComponent("source.mkv")
        let wavResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            "-loop", "1", "-i", coverPath,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "pcm_s16le",
            "-c:v", "mjpeg",
            "-disposition:v", "attached_pic",
            "-shortest",
            mkvPath.path
        ])
        guard wavResult.isSuccess else {
            throw TestError.fixtureGeneration("source with cover generation failed")
        }
        return mkvPath
    }

    /// Probe video stream dimensions via ffprobe.
    private func probeVideoDimensions(_ url: URL) async throws -> (width: Int, height: Int, codec: String)? {
        let ffprobe = ProcessRunner.findExecutable("ffprobe")!
        let result = try await ProcessRunner.run(ffprobe, arguments: [
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,codec_name",
            "-of", "json",
            url.path
        ])
        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first else { return nil }
        let w = stream["width"] as? Int ?? 0
        let h = stream["height"] as? Int ?? 0
        let codec = stream["codec_name"] as? String ?? ""
        return (w, h, codec)
    }

    /// Probe audio codec via ffprobe.
    private func probeAudioCodec(_ url: URL) async throws -> String? {
        let ffprobe = ProcessRunner.findExecutable("ffprobe")!
        let result = try await ProcessRunner.run(ffprobe, arguments: [
            "-v", "quiet",
            "-select_streams", "a:0",
            "-show_entries", "stream=codec_name",
            "-of", "json",
            url.path
        ])
        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first else { return nil }
        return stream["codec_name"] as? String
    }

    @Test func transcodeWithArtworkResizeProducesSmallCover() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = try await makeSourceWithCover(at: tmp)
        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let result = try await service.transcode(
            input: source,
            outputDir: outputDir,
            artworkMaxPx: 250
        )

        guard case .transcoded(let outputURL) = result else {
            Issue.record("Expected transcoded result")
            return
        }

        // Audio should be AAC
        let audioCodec = try await probeAudioCodec(outputURL)
        #expect(audioCodec?.contains("aac") == true, "Expected AAC audio, got \(audioCodec ?? "nil")")

        // Video stream should be mjpeg with dimensions ≤ 250
        if let dims = try await probeVideoDimensions(outputURL) {
            #expect(dims.codec.contains("mjpeg"), "Expected mjpeg video, got \(dims.codec)")
            #expect(dims.width <= 250, "Width \(dims.width) should be ≤ 250")
            #expect(dims.height <= 250, "Height \(dims.height) should be ≤ 250")
        } else {
            Issue.record("No video stream found in output")
        }

        // moov before mdat (faststart)
        let fileData = try Data(contentsOf: outputURL)
        guard let moovRange = fileData.range(of: "moov".data(using: .ascii)!),
              let mdatRange = fileData.range(of: "mdat".data(using: .ascii)!) else {
            Issue.record("could not find moov/mdat in file")
            return
        }
        #expect(moovRange.lowerBound < mdatRange.lowerBound, "moov must appear before mdat")
    }

    @Test func transcodeKeepOriginalArtworkPreservesDimensions() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = try await makeSourceWithCover(at: tmp)
        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let result = try await service.transcode(
            input: source,
            outputDir: outputDir,
            artworkMaxPx: nil  // keep original
        )

        guard case .transcoded(let outputURL) = result else {
            Issue.record("Expected transcoded result")
            return
        }

        // Cover should be preserved at original dimensions (600×600)
        if let dims = try await probeVideoDimensions(outputURL) {
            #expect(dims.width == 600, "Width should be 600 (original), got \(dims.width)")
            #expect(dims.height == 600, "Height should be 600 (original), got \(dims.height)")
        } else {
            Issue.record("No video stream found in output")
        }
    }

    @Test func skipPathRemuxResizesCover() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!

        // Create a source that is already AAC below target bitrate with a big cover.
        // First make a cover image.
        let coverPath = tmp.appendingPathComponent("cover.jpg").path
        _ = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "color=c=red:s=600x600:d=0.04",
            "-frames:v", "1", "-update", "1", coverPath
        ])

        // Make a low-bitrate AAC file with cover
        let sourcePath = tmp.appendingPathComponent("low_aac.m4a")
        let sourceResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-loop", "1", "-i", coverPath,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "aac", "-b:a", "64k",
            "-c:v", "mjpeg",
            "-disposition:v", "attached_pic",
            "-shortest",
            sourcePath.path
        ])
        guard sourceResult.isSuccess else {
            Issue.record("Failed to create low-bitrate AAC source")
            return
        }

        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        // Target 248kbps — source is 64kbps AAC, so it would normally .skipped
        // but with artworkMaxPx it should remux instead.
        let result = try await service.transcode(
            input: sourcePath,
            outputDir: outputDir,
            bitrateKbps: 248,
            artworkMaxPx: 250
        )

        guard case .transcoded(let outputURL) = result else {
            Issue.record("Expected transcoded result from skip-path remux, got \(result)")
            return
        }

        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Audio should still be AAC
        let audioCodec = try await probeAudioCodec(outputURL)
        #expect(audioCodec?.contains("aac") == true, "Expected AAC audio, got \(audioCodec ?? "nil")")

        // Cover should be resized to ≤ 250
        if let dims = try await probeVideoDimensions(outputURL) {
            #expect(dims.width <= 250, "Width \(dims.width) should be ≤ 250")
            #expect(dims.height <= 250, "Height \(dims.height) should be ≤ 250")
        } else {
            Issue.record("No video stream found in skip-path remux output")
        }
    }

    /// Regression test: after a successful remux, no `.tmp.m4a` file should
    /// remain in the output directory — the temp must be moved (not copied)
    /// to the final location.
    @Test func remuxSuccessLeavesNoTempFile() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required")

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!

        // Create a low-bitrate AAC source with a large cover (triggers remux branch)
        let coverPath = tmp.appendingPathComponent("cover.jpg").path
        _ = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "color=c=green:s=500x500:d=0.04",
            "-frames:v", "1", "-update", "1", coverPath
        ])

        let sourcePath = tmp.appendingPathComponent("aac_source.m4a")
        let sourceResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=0.5",
            "-loop", "1", "-i", coverPath,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "aac", "-b:a", "96k",
            "-c:v", "mjpeg",
            "-disposition:v", "attached_pic",
            "-shortest",
            sourcePath.path
        ])
        guard sourceResult.isSuccess else {
            Issue.record("Failed to create AAC source")
            return
        }

        let outputDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let service = TranscodeService()
        let result = try await service.transcode(
            input: sourcePath,
            outputDir: outputDir,
            bitrateKbps: 248,
            artworkMaxPx: 250
        )

        guard case .transcoded(let outputURL) = result else {
            Issue.record("Expected .transcoded, got \(result)")
            return
        }

        // Verify output is valid
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        if let dims = try await probeVideoDimensions(outputURL) {
            #expect(dims.width <= 250, "Width \(dims.width) should be ≤ 250")
            #expect(dims.height <= 250, "Height \(dims.height) should be ≤ 250")
        }

        // Critical: no .tmp.m4a files should remain in outputDir
        let contents = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        let tempFiles = contents.filter { $0.pathExtension == "m4a" && $0.lastPathComponent.contains(".tmp.") }
        #expect(tempFiles.isEmpty, "No .tmp.m4a files should remain, found: \(tempFiles.map(\.lastPathComponent))")
    }

    /// Regression test for the poison-cache bug: when the remux fails, no
    /// partial file should be left at `outputURL`. A truncated MP4 container
    /// passes `verifyCacheCodec`, and the "output already exists" early return
    /// would then skip rebuilding it forever.
    @Test func remuxFailureLeavesNoPartialOutput() async throws {
        try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required")

        let tmp = try makeTempDir()
        defer {
            // Restore permissions before cleanup
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!

        // Create a low-bitrate AAC source with a large cover
        let coverPath = tmp.appendingPathComponent("cover.jpg").path
        _ = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "color=c=yellow:s=400x400:d=0.04",
            "-frames:v", "1", "-update", "1", coverPath
        ])

        let sourcePath = tmp.appendingPathComponent("aac_for_fail.m4a")
        let sourceResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y",
            "-f", "lavfi", "-i", "sine=frequency=220:duration=0.5",
            "-loop", "1", "-i", coverPath,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "aac", "-b:a", "64k",
            "-c:v", "mjpeg",
            "-disposition:v", "attached_pic",
            "-shortest",
            sourcePath.path
        ])
        guard sourceResult.isSuccess else {
            Issue.record("Failed to create AAC source for failure test")
            return
        }

        // Create an output directory, then make it read-only so ffmpeg cannot write
        let outputDir = tmp.appendingPathComponent("readonly_out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outputDir.path)

        let service = TranscodeService()
        let result = try await service.transcode(
            input: sourcePath,
            outputDir: outputDir,
            bitrateKbps: 248,
            artworkMaxPx: 250
        )

        // Should have failed
        guard case .failed = result else {
            Issue.record("Expected .failed result when output dir is unwritable, got \(result)")
            return
        }

        // Critical: no file should exist at the expected output path
        let expectedOutputName = sourcePath.deletingPathExtension().lastPathComponent + ".m4a"
        let expectedOutputPath = outputDir.appendingPathComponent(expectedOutputName).path
        #expect(!FileManager.default.fileExists(atPath: expectedOutputPath),
                "No output file should exist at \(expectedOutputPath) after a failed remux")

        // Also check no temp files remain
        let contents = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
        let tempFiles = contents.filter { $0.lastPathComponent.contains(".tmp.") }
        #expect(tempFiles.isEmpty, "No .tmp files should remain, found: \(tempFiles.map(\.lastPathComponent))")
    }

    private enum TestError: Error {
        case fixtureGeneration(String)
    }
}
