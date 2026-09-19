import Testing
import Foundation
@testable import MLM

/// Tests for the MLM UUID tag-embedding command construction and roundtrip.
@Suite("MlmUuidEmbeddingTests")
struct MlmUuidEmbeddingTests {

    // MARK: - Command construction (pure logic)

    @Test func mp3UsesTxxxFrame() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "ABCD-1234",
            inputPath: "/tmp/in.mp3",
            outputPath: "/tmp/out.mp3",
            fileExtension: "mp3"
        )
        #expect(args != nil, "mp3 should produce args")
        #expect(args?.contains("TXXX:MLM_UUID=ABCD-1234") == true)
        #expect(args?.contains("-metadata") == true)
    }

    @Test func m4aUsesCommentField() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "ABCD-1234",
            inputPath: "/tmp/in.m4a",
            outputPath: "/tmp/out.m4a",
            fileExtension: "m4a"
        )
        #expect(args != nil, "m4a should produce args")
        #expect(args?.contains("comment=MLM_UUID:ABCD-1234") == true)
    }

    @Test func aacExtensionAlsoSupported() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "X",
            inputPath: "/tmp/in.aac",
            outputPath: "/tmp/out.aac",
            fileExtension: "aac"
        )
        #expect(args != nil, "aac extension should be supported")
        #expect(args?.contains("comment=MLM_UUID:X") == true)
    }

    @Test func unsupportedFormatReturnsNil() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "X",
            inputPath: "/tmp/in.flac",
            outputPath: "/tmp/out.flac",
            fileExtension: "flac"
        )
        #expect(args == nil, "flac should not be supported for embedding")
    }

    @Test func argsIncludeCopyCodecAndMaps() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "UUID",
            inputPath: "/in.mp3",
            outputPath: "/out.mp3",
            fileExtension: "mp3"
        )!
        #expect(args.contains("-c"))
        #expect(args.contains("copy"))
        #expect(args.contains("-map"))
        #expect(args.contains("0:a"))
        // -y for overwrite
        #expect(args.contains("-y"))
    }

    // MARK: - Comment preservation logic

    @Test func emptyCommentProducesPlainPrefix() {
        let result = SyncService.buildMlmComment(uuid: "UUID-1", existingComment: nil)
        #expect(result == "MLM_UUID:UUID-1")

        let result2 = SyncService.buildMlmComment(uuid: "UUID-1", existingComment: "")
        #expect(result2 == "MLM_UUID:UUID-1")
    }

    @Test func existingCommentIsPreserved() {
        let result = SyncService.buildMlmComment(uuid: "UUID-1", existingComment: "My personal note")
        #expect(result == "MLM_UUID:UUID-1|||My personal note")
    }

    @Test func alreadyEmbeddedIsIdempotent() {
        let result = SyncService.buildMlmComment(
            uuid: "UUID-NEW",
            existingComment: "MLM_UUID:UUID-OLD"
        )
        #expect(result == "MLM_UUID:UUID-NEW")
    }

    @Test func alreadyEmbeddedPreservesUserComment() {
        let result = SyncService.buildMlmComment(
            uuid: "UUID-NEW",
            existingComment: "MLM_UUID:UUID-OLD|||My note"
        )
        #expect(result == "MLM_UUID:UUID-NEW|||My note")
    }

    @Test func parseMlmUuidExtractsSimple() {
        #expect(SyncService.parseMlmUuid(fromComment: "MLM_UUID:ABC-123") == "ABC-123")
    }

    @Test func parseMlmUuidStripsUserComment() {
        #expect(SyncService.parseMlmUuid(fromComment: "MLM_UUID:ABC-123|||hello") == "ABC-123")
    }

    @Test func parseMlmUuidReturnsNilForNonMatching() {
        #expect(SyncService.parseMlmUuid(fromComment: "just a regular comment") == nil)
        #expect(SyncService.parseMlmUuid(fromComment: "") == nil)
    }

    @Test func m4aArgsWithExistingComment() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "UUID-1",
            inputPath: "/tmp/in.m4a",
            outputPath: "/tmp/out.m4a",
            fileExtension: "m4a",
            existingComment: "My note"
        )
        #expect(args?.contains("comment=MLM_UUID:UUID-1|||My note") == true)
    }

    // MARK: - embedMlmUuid guard: no UUID → no-op

    @Test func embedSkipsWhenTrackHasNoUuid() async throws {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("embed_test_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        var track = Track(artist: "A", album: "B", title: "T", format: "mp3", originalPath: "/x.mp3")
        #expect(track.mlmUuid == nil)

        let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent.mp3")
        await service.embedMlmUuid(track: track, destinationURL: dummyURL)
        // If we got here without throwing, the guard worked.
    }

    // MARK: - Empirical roundtrip (requires ffmpeg)

    @Test func m4aRoundtrip() async throws {
        try await roundtripTest(ext: "m4a")
    }

    @Test func mp3Roundtrip() async throws {
        try await roundtripTest(ext: "mp3")
    }

    @Test func m4aPreservesExistingComment() async throws {
        try await commentPreservationRoundtrip(ext: "m4a")
    }

    // MARK: - Roundtrip helpers

    private func roundtripTest(ext: String) async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil,
              ProcessRunner.findExecutable("ffprobe") != nil else {
            // Graceful skip: ffmpeg not available on this machine
            return
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_roundtrip_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Generate a tiny audio file via ffmpeg (lavfi sine, 0.5s)
        let sourceURL = tmpDir.appendingPathComponent("source.\(ext)")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genArgs = [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            sourceURL.path,
        ]
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: genArgs)
        guard genResult.isSuccess else {
            // ffmpeg could not generate test file — skip gracefully
            return
        }

        // Embed UUID through the real code path
        let testUUID = "TEST-UUID-\(UUID().uuidString.prefix(8))"
        var track = Track(artist: "A", album: "B", title: "T", format: ext, originalPath: sourceURL.path)
        track.mlmUuid = testUUID

        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = tmpDir.appendingPathComponent("cache")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        await service.embedMlmUuid(track: track, destinationURL: sourceURL)

        // Read back via UuidTagIO
        let readBack = await UuidTagIO.readMlmUuid(from: sourceURL)
        #expect(readBack == testUUID, "UUID should survive embed → readback for \(ext)")

        // Also verify via ffprobe directly for evidence
        let ffprobe = ProcessRunner.findExecutable("ffprobe")!
        let probeArgs: [String]
        if ext == "mp3" {
            probeArgs = ["-v", "quiet", "-show_entries", "format_tags", "-of", "json", sourceURL.path]
        } else {
            probeArgs = ["-v", "quiet", "-show_entries", "format_tags=comment", "-of", "csv=p=0", sourceURL.path]
        }
        let probeResult = try await ProcessRunner.run(ffprobe, arguments: probeArgs)
        print("ffprobe output for \(ext): \(probeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(probeResult.isSuccess)
        if ext == "mp3" {
            #expect(probeResult.stdout.contains("TXXX:MLM_UUID"))
            #expect(probeResult.stdout.contains(testUUID))
        } else {
            #expect(probeResult.stdout.contains(testUUID))
        }
    }

    private func commentPreservationRoundtrip(ext: String) async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil,
              ProcessRunner.findExecutable("ffprobe") != nil else {
            // Graceful skip: ffmpeg not available on this machine
            return
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_comment_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Generate audio with a pre-seeded comment
        let sourceURL = tmpDir.appendingPathComponent("seeded.\(ext)")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genArgs = [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            "-metadata", "comment=Hello from test",
            sourceURL.path,
        ]
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: genArgs)
        guard genResult.isSuccess else {
            // ffmpeg could not generate seeded file — skip gracefully
            return
        }

        // Embed UUID — should preserve the existing comment
        let testUUID = "UUID-PRESERVE-\(UUID().uuidString.prefix(8))"
        var track = Track(artist: "A", album: "B", title: "T", format: ext, originalPath: sourceURL.path)
        track.mlmUuid = testUUID

        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = tmpDir.appendingPathComponent("cache")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        await service.embedMlmUuid(track: track, destinationURL: sourceURL)

        // Read back UUID
        let readBack = await UuidTagIO.readMlmUuid(from: sourceURL)
        #expect(readBack == testUUID, "UUID should survive embed with preserved comment")

        // Verify the user comment survives via ffprobe
        let ffprobe = ProcessRunner.findExecutable("ffprobe")!
        let probeArgs = ["-v", "quiet", "-show_entries", "format_tags=comment", "-of", "csv=p=0", sourceURL.path]
        let probeResult = try await ProcessRunner.run(ffprobe, arguments: probeArgs)
        let comment = probeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        print("ffprobe comment for \(ext) after embed: \(comment)")
        #expect(comment.contains("Hello from test"), "User comment should survive embed")
        #expect(comment.contains("MLM_UUID:\(testUUID)"), "UUID should be in comment")
    }

    // MARK: - faststart flag in args

    @Test func m4aArgsIncludeFaststart() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "UUID",
            inputPath: "/in.m4a",
            outputPath: "/out.m4a",
            fileExtension: "m4a"
        )!
        #expect(args.contains("-movflags"))
        #expect(args.contains("+faststart"))
    }

    @Test func mp3ArgsIncludeFaststart() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "UUID",
            inputPath: "/in.mp3",
            outputPath: "/out.mp3",
            fileExtension: "mp3"
        )!
        #expect(args.contains("-movflags"))
        #expect(args.contains("+faststart"))
    }

    @Test func faststartFlagBeforeOutputPath() {
        let args = SyncService.embedMlmUuidArguments(
            uuid: "UUID",
            inputPath: "/in.m4a",
            outputPath: "/out.m4a",
            fileExtension: "m4a"
        )!
        guard let movflagsIdx = args.firstIndex(of: "-movflags"),
              let outputIdx = args.firstIndex(of: "/out.m4a") else {
            Issue.record("expected -movflags and output path in args")
            return
        }
        #expect(movflagsIdx < outputIdx, "-movflags must appear before the output path")
    }

    // MARK: - Empirical faststart + cover preservation

    @Test func m4aFaststartMoovBeforeMdat() async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_faststart_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("source.m4a")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            sourceURL.path,
        ])
        guard genResult.isSuccess else { return }

        let testUUID = "FASTSTART-\(UUID().uuidString.prefix(8))"
        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: sourceURL.path)
        track.mlmUuid = testUUID

        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cache = TranscodeCache(cacheDir: tmpDir.appendingPathComponent("cache"))
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        await service.embedMlmUuid(track: track, destinationURL: sourceURL)

        // Byte-level check: moov must appear before mdat in the file.
        // moov can be >1KB so read the whole file (it's tiny for a 0.5s test clip).
        let fileData = try Data(contentsOf: sourceURL)

        guard let moovRange = fileData.range(of: "moov".data(using: .ascii)!),
              let mdatRange = fileData.range(of: "mdat".data(using: .ascii)!) else {
            Issue.record("could not find moov/mdat in file")
            return
        }
        #expect(moovRange.lowerBound < mdatRange.lowerBound,
                "moov (offset \(moovRange.lowerBound)) must appear before mdat (offset \(mdatRange.lowerBound)) — faststart regression")
    }

    @Test func m4aPreservesCoverArt() async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil,
              ProcessRunner.findExecutable("ffprobe") != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_cover_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a tiny PNG for the cover
        let coverPath = tmpDir.appendingPathComponent("cover.png").path
        let genCoverResult = try await ProcessRunner.run(
            ProcessRunner.findExecutable("ffmpeg")!,
            arguments: [
                "-y", "-f", "lavfi", "-i", "color=c=blue:s=64x64:d=0.1",
                "-frames:v", "1",
                coverPath,
            ]
        )
        guard genCoverResult.isSuccess else { return }

        // Generate m4a with attached_pic cover
        let sourceURL = tmpDir.appendingPathComponent("with_cover.m4a")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            "-i", coverPath,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "aac", "-c:v", "png",
            "-disposition:v:0", "attached_pic",
            sourceURL.path,
        ])
        guard genResult.isSuccess else { return }

        // Embed UUID
        let testUUID = "COVER-\(UUID().uuidString.prefix(8))"
        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: sourceURL.path)
        track.mlmUuid = testUUID

        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cache = TranscodeCache(cacheDir: tmpDir.appendingPathComponent("cache"))
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        await service.embedMlmUuid(track: track, destinationURL: sourceURL)

        // Verify UUID
        let readBack = await UuidTagIO.readMlmUuid(from: sourceURL)
        #expect(readBack == testUUID)

        // Verify cover stream still exists
        let ffprobe = ProcessRunner.findExecutable("ffprobe")!
        let probeResult = try await ProcessRunner.run(ffprobe, arguments: [
            "-v", "quiet",
            "-show_entries", "stream=codec_type,codec_name",
            "-of", "csv=p=0",
            sourceURL.path,
        ])
        #expect(probeResult.isSuccess)
        #expect(probeResult.stdout.contains("png") || probeResult.stdout.contains("mjpeg"),
                "cover art stream should survive embed")
    }

    // MARK: - ensureCached mlmUuid tagging

    @Test func ensureCacheTagsUntaggedCacheFile() async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_enscache_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Generate a source .m4a
        let sourceURL = tmpDir.appendingPathComponent("source.m4a")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            sourceURL.path,
        ])
        guard genResult.isSuccess else { return }

        let cacheDir = tmpDir.appendingPathComponent("cache")
        let cache = TranscodeCache(cacheDir: cacheDir)

        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: sourceURL.path)
        track.id = 99999
        track.organizedPath = sourceURL.path
        track.mlmUuid = "CACHE-UUID-TEST"

        // First call: transcode + tag
        let cachedURL = try await cache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: nil, mlmUuid: "CACHE-UUID-TEST")
        guard let cachedURL else {
            Issue.record("ensureCached returned nil")
            return
        }

        let uuid = await UuidTagIO.readMlmUuid(from: cachedURL)
        #expect(uuid == "CACHE-UUID-TEST", "cache file should be tagged after ensureCached")

        // Second call with same UUID: should NOT re-mux (file stays identical)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: cachedURL.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100)) // ensure mtime would differ if re-written
        let cachedURL2 = try await cache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: nil, mlmUuid: "CACHE-UUID-TEST")
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: cachedURL2!.path)[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter, "cache file should not be re-muxed when UUID already matches")
    }

    // MARK: - P1: device swap safety

    @Test func embedLeavesNoStraySwapTempAfterSuccess() async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_noswap_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer {
            // Restore permissions in case the read-only test ran first in this dir.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let sourceURL = tmpDir.appendingPathComponent("source.m4a")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            sourceURL.path,
        ])
        guard genResult.isSuccess else { return }

        let testUUID = "NOSWAP-\(UUID().uuidString.prefix(8))"
        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: sourceURL.path)
        track.mlmUuid = testUUID

        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cache = TranscodeCache(cacheDir: tmpDir.appendingPathComponent("cache"))
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        await service.embedMlmUuid(track: track, destinationURL: sourceURL)

        // No dot-prefixed .mlm_swap_ temp should remain in the destination directory.
        let contents = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let straySwapFiles = contents.filter { $0.lastPathComponent.contains(".mlm_swap_") }
        #expect(straySwapFiles.isEmpty, "no .mlm_swap_ temp should remain after successful embed, found: \(straySwapFiles.map(\.lastPathComponent))")

        // Destination should still have moov before mdat (faststart preserved through the swap).
        let fileData = try Data(contentsOf: sourceURL)
        guard let moovRange = fileData.range(of: "moov".data(using: .ascii)!),
              let mdatRange = fileData.range(of: "mdat".data(using: .ascii)!) else {
            Issue.record("could not find moov/mdat in file after embed")
            return
        }
        #expect(moovRange.lowerBound < mdatRange.lowerBound,
                "moov must appear before mdat after swap — faststart regression")
    }

    @Test func embedPreservesDestinationWhenSiblingCopyFails() async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_rdonly_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer {
            // Always restore permissions so cleanup succeeds.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
            try? FileManager.default.removeItem(at: tmpDir)
        }

        // Generate a valid source file first (in a writable location).
        let genDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_rdonly_gen_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: genDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: genDir) }

        let genURL = genDir.appendingPathComponent("source.m4a")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            genURL.path,
        ])
        guard genResult.isSuccess else { return }

        // Copy into the soon-to-be-read-only directory.
        let destURL = tmpDir.appendingPathComponent("dest.m4a")
        try FileManager.default.copyItem(at: genURL, to: destURL)

        // Snapshot the original bytes.
        let originalData = try Data(contentsOf: destURL)

        // Make the parent directory read-only so the sibling copy cannot be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmpDir.path)

        let testUUID = "RDONLY-\(UUID().uuidString.prefix(8))"
        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: destURL.path)
        track.mlmUuid = testUUID

        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cache = TranscodeCache(cacheDir: genDir.appendingPathComponent("cache"))
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )

        await service.embedMlmUuid(track: track, destinationURL: destURL)

        // Destination must be byte-identical to the original — untouched.
        let afterData = try Data(contentsOf: destURL)
        #expect(originalData == afterData, "destination file must be untouched when sibling copy fails")
    }

    // MARK: - P2: cache swap safety

    @Test func ensureCacheLeavesNoStrayTempAfterTagging() async throws {
        guard ProcessRunner.findExecutable("ffmpeg") != nil else { return }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_cachelean_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("source.m4a")
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")!
        let genResult = try await ProcessRunner.run(ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            sourceURL.path,
        ])
        guard genResult.isSuccess else { return }

        let cacheDir = tmpDir.appendingPathComponent("cache")
        let cache = TranscodeCache(cacheDir: cacheDir)

        var track = Track(artist: "A", album: "B", title: "T", format: "m4a", originalPath: sourceURL.path)
        track.id = 77777
        track.organizedPath = sourceURL.path
        track.mlmUuid = "CLEAN-UUID-TEST"

        // First call: transcode + tag
        let cachedURL = try await cache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: nil, mlmUuid: "CLEAN-UUID-TEST")
        guard let cachedURL else {
            Issue.record("ensureCached returned nil")
            return
        }

        // Second call: already cached + already tagged → should be a no-op.
        _ = try await cache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: nil, mlmUuid: "CLEAN-UUID-TEST")

        // Cache dir should contain exactly the expected entry, no stray temps.
        let cacheContents = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
        let expectedName = "77777_248.m4a"
        let strayFiles = cacheContents.filter { $0.lastPathComponent != expectedName }
        #expect(strayFiles.isEmpty, "no stray temp files should remain in cache dir, found: \(strayFiles.map(\.lastPathComponent))")

        // Cache file must still exist and be tagged.
        #expect(FileManager.default.fileExists(atPath: cachedURL.path), "cache file should still exist")
        let uuid = await UuidTagIO.readMlmUuid(from: cachedURL)
        #expect(uuid == "CLEAN-UUID-TEST", "cache file should still be tagged after second call")
    }
}
