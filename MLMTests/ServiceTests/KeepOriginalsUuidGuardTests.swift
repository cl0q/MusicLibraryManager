import Testing
import Foundation
@testable import MLM

/// F15 — properties of the `embedMlmUuid` read-first guard that are reachable
/// without ffmpeg or real tagged audio.
///
/// Covered:
/// - `UuidTagIO.readMlmUuid` returns `nil` (never throws/crashes) for missing
///   files, non-audio content, and zero-byte files. This is the invariant the
///   guard depends on: `nil != uuid` so control falls through to embed.
/// - `embedMlmUuid(track:destinationURL:)` is a no-op when the track's `mlmUuid`
///   is nil or empty — file bytes are unchanged and no temp litter is created.
///
/// NOT covered: the guard's remux-skip happy path (UUID already matches) because
/// it requires a real tagged audio file and ffmpeg.
@Suite("KeepOriginalsUuidGuardTests")
struct KeepOriginalsUuidGuardTests {

    // MARK: - readMlmUuid degrades to nil

    @Test func readMlmUuidReturnsNilForMissingFile() async {
        let missing = URL(fileURLWithPath: "/tmp/mlm_test_nonexistent_\(UUID().uuidString).mp3")
        let result = await UuidTagIO.readMlmUuid(from: missing)
        #expect(result == nil)
    }

    @Test func readMlmUuidReturnsNilForNonAudioContent() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlm_guard_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let textFile = dir.appendingPathComponent("not_audio.m4a")
        try? "this is not audio data".data(using: .utf8)?.write(to: textFile)

        let result = await UuidTagIO.readMlmUuid(from: textFile)
        #expect(result == nil)
    }

    @Test func readMlmUuidReturnsNilForZeroByteFile() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlm_guard_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let emptyFile = dir.appendingPathComponent("empty.mp3")
        FileManager.default.createFile(atPath: emptyFile.path, contents: nil)

        let result = await UuidTagIO.readMlmUuid(from: emptyFile)
        #expect(result == nil)
    }

    // MARK: - embedMlmUuid no-op when track has no UUID

    @Test func embedMlmUuidIsNoOpWhenMlmUuidIsNil() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlm_noop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("track.mp3")
        let originalBytes = Data([0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02, 0x03])
        try originalBytes.write(to: fileURL)

        let childrenBefore = try FileManager.default.contentsOfDirectory(atPath: dir.path)

        var track = Track(artist: "A", album: "B", title: "C", format: "mp3", originalPath: "/tmp/x.mp3")
        track.mlmUuid = nil

        let service = try makeService()
        await service.embedMlmUuid(track: track, destinationURL: fileURL)

        let bytesAfter = try Data(contentsOf: fileURL)
        #expect(bytesAfter == originalBytes)

        let childrenAfter = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(childrenAfter == childrenBefore)
    }

    @Test func embedMlmUuidIsNoOpWhenMlmUuidIsEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlm_noop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("track.m4a")
        let originalBytes = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70])
        try originalBytes.write(to: fileURL)

        let childrenBefore = try FileManager.default.contentsOfDirectory(atPath: dir.path)

        var track = Track(artist: "A", album: "B", title: "C", format: "m4a", originalPath: "/tmp/x.m4a")
        track.mlmUuid = ""

        let service = try makeService()
        await service.embedMlmUuid(track: track, destinationURL: fileURL)

        let bytesAfter = try Data(contentsOf: fileURL)
        #expect(bytesAfter == originalBytes)

        let childrenAfter = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(childrenAfter == childrenBefore)
    }

    // MARK: - Helpers

    private func makeService() throws -> SyncService {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard_svc_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        return SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
    }
}
