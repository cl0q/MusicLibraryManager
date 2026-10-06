import Foundation
import GRDB
import Testing
@testable import MLM

/// W5-F1 step 1: every writer of a library file takes `LibraryFileLock` on the file's path for
/// the duration of its write and gives it back on every exit. Each adopter is proven the same
/// way, with its own lock instance and no sleeping:
///
/// 1. the test holds the lock on the file's path,
/// 2. starts the writer and waits (bounded, failing on timeout) until it queues on the lock,
/// 3. checks that the writer has not touched the file nor finished,
/// 4. releases the lock, lets the writer run, and checks the file was written and the lock is
///    free again (`isHeld == false`).
///
/// The error path of each adopter that can fail is checked the same way: the lock is free after.
private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private struct LockedWriteHarness {
    let lock = LibraryFileLock()
    let url: URL

    /// Runs `operation` while the test holds the lock; `untouched` is checked while it waits.
    func run<T: Sendable>(
        untouched: () -> Bool,
        _ operation: @escaping @Sendable (LibraryFileLock) async -> T
    ) async -> T {
        let key = LibraryFileLock.key(for: url)
        await lock.acquire(key)
        let done = DoneFlag()
        let lock = self.lock
        let task = Task { () -> T in
            let result = await operation(lock)
            done.set()
            return result
        }
        var queued = false
        for _ in 0..<5000 {
            if await lock.waiterCount(key) == 1 { queued = true; break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(queued, "the writer never queued on the lock")
        #expect(!done.isSet, "the writer finished while the lock was held elsewhere")
        #expect(untouched(), "the writer touched the file while the lock was held elsewhere")
        await lock.release(key)
        let result = await task.value
        #expect(await lock.isHeld(key) == false, "the lock must be free after the write")
        return result
    }
}

@Suite("LibraryFileLockAdoptionTests")
struct LibraryFileLockAdoptionTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lock-adoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: holding

    @Test func holdingTakesTheLockForTheBodyAndFreesItAfterwards() async throws {
        let lock = LibraryFileLock()
        let url = URL(fileURLWithPath: "/lib/holding-ok.mp3")
        let key = LibraryFileLock.key(for: url)
        let during = await LibraryFileLock.holding(url, in: lock) { await lock.isHeld(key) }
        #expect(during)
        #expect(await lock.isHeld(key) == false)
    }

    @Test func holdingFreesTheLockWhenTheBodyThrows() async {
        let lock = LibraryFileLock()
        let url = URL(fileURLWithPath: "/lib/holding-throws.mp3")
        do {
            try await LibraryFileLock.holding(url, in: lock) { throw CocoaError(.fileWriteUnknown) }
            Issue.record("expected a throw")
        } catch {}
        #expect(await lock.isHeld(LibraryFileLock.key(for: url)) == false)
    }

    @Test func twoSpellingsOfOnePathShareOneKey() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.mp3")
        try Data("x".utf8).write(to: file)
        let indirect = folder.appendingPathComponent("sub/../a.mp3")
        #expect(LibraryFileLock.key(for: file) == LibraryFileLock.key(for: indirect))
    }

    // MARK: DownloadOrchestrator.placeFinal

    @Test func placeFinalWaitsForTheDestinationAndMovesAfterwards() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let orchestrator = DownloadOrchestrator(libraryRoot: folder.path, tokenStorage: TokenStorage())
        let finalDir = folder.appendingPathComponent("final")
        let produced = folder.appendingPathComponent("produced.m4a")
        try Data("new".utf8).write(to: produced)
        let dest = finalDir.appendingPathComponent("track.m4a")
        let harness = LockedWriteHarness(url: dest)
        let result = await harness.run(untouched: {
            FileManager.default.fileExists(atPath: produced.path) && !FileManager.default.fileExists(atPath: dest.path)
        }) { lock in
            try? await orchestrator.placeFinal(produced, into: finalDir, fileName: "track.m4a", lock: lock)
        }
        #expect(result != nil)
        #expect(try Data(contentsOf: dest) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: produced.path))
    }

    @Test func placeFinalFreesTheLockWhenTheMoveFails() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let orchestrator = DownloadOrchestrator(libraryRoot: folder.path, tokenStorage: TokenStorage())
        let lock = LibraryFileLock()
        let dest = folder.appendingPathComponent("final/track.m4a")
        do {
            _ = try await orchestrator.placeFinal(folder.appendingPathComponent("missing.m4a"),
                                                  into: folder.appendingPathComponent("final"),
                                                  fileName: "track.m4a", lock: lock)
            Issue.record("expected a throw")
        } catch {}
        #expect(await lock.isHeld(LibraryFileLock.key(for: dest)) == false)
    }

    // MARK: ArtworkService.embedCover (the body of embedArtwork)

    private func fakeFFmpeg(in folder: URL, succeeds: Bool, marker: URL) throws -> String {
        let script = folder.appendingPathComponent(succeeds ? "ffmpeg-ok" : "ffmpeg-fails")
        let body = succeeds
            ? "#!/bin/sh\ntouch '\(marker.path)'\nfor a in \"$@\"; do out=\"$a\"; done\necho embedded > \"$out\"\n"
            : "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test func embedCoverWaitsForTheAudioFileAndSwapsAfterwards() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("song.m4a")
        try Data("original".utf8).write(to: audio)
        let cover = folder.appendingPathComponent("cover.jpg")
        try Data("jpg".utf8).write(to: cover)
        let work = folder.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("ffmpeg-ran")
        let ffmpeg = try fakeFFmpeg(in: folder, succeeds: true, marker: marker)
        let harness = LockedWriteHarness(url: audio)
        let embedded = await harness.run(untouched: {
            !FileManager.default.fileExists(atPath: marker.path)
                && (try? Data(contentsOf: audio)) == Data("original".utf8)
        }) { lock in
            await ArtworkService.embedCover(cover, into: audio, ffmpeg: ffmpeg, workDir: work, lock: lock)
        }
        #expect(embedded)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try String(contentsOf: audio, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "embedded")
    }

    @Test func embedCoverFreesTheLockWhenFFmpegFailsAndKeepsTheOriginal() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("song.m4a")
        try Data("original".utf8).write(to: audio)
        let cover = folder.appendingPathComponent("cover.jpg")
        try Data("jpg".utf8).write(to: cover)
        let marker = folder.appendingPathComponent("ffmpeg-ran")
        let ffmpeg = try fakeFFmpeg(in: folder, succeeds: false, marker: marker)
        let lock = LibraryFileLock()
        let embedded = await ArtworkService.embedCover(cover, into: audio, ffmpeg: ffmpeg, workDir: folder, lock: lock)
        #expect(!embedded)
        #expect(await lock.isHeld(LibraryFileLock.key(for: audio)) == false)
        #expect(try Data(contentsOf: audio) == Data("original".utf8))
    }

    @Test func embedCoverFreesTheLockWhenTheSwapFails() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("song.m4a")
        try Data("original".utf8).write(to: audio)
        let cover = folder.appendingPathComponent("cover.jpg")
        try Data("jpg".utf8).write(to: cover)
        let marker = folder.appendingPathComponent("ffmpeg-ran")
        let ffmpeg = try fakeFFmpeg(in: folder, succeeds: true, marker: marker)
        let lock = LibraryFileLock()
        let embedded = await ArtworkService.embedCover(
            cover, into: audio, ffmpeg: ffmpeg, workDir: folder, lock: lock,
            replaceItem: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(!embedded)
        #expect(await lock.isHeld(LibraryFileLock.key(for: audio)) == false)
        #expect(try Data(contentsOf: audio) == Data("original".utf8))
    }

    // MARK: TranscodeService.transcode

    @Test func transcodeWaitsForItsOutputPathAndFreesItAfterwards() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("in.flac")
        try Data("not audio".utf8).write(to: input)
        let output = folder.appendingPathComponent("in.m4a")
        let harness = LockedWriteHarness(url: output)
        _ = await harness.run(untouched: { !FileManager.default.fileExists(atPath: output.path) }) { lock in
            try? await TranscodeService().transcode(input: input, outputDir: folder, lock: lock)
        }
    }

    // MARK: Remove from Library (Trash move)

    @Test func removeFromLibraryTrashesOnlyWhenTheFileIsFree() async throws {
        let url = URL(fileURLWithPath: "/lib/removal.mp3")
        let harness = LockedWriteHarness(url: url)
        let calls = DoneFlag()
        let trashed = await harness.run(untouched: { !calls.isSet }) { lock in
            try? await TrackLibraryRemoval.trashLocked(url, lock: lock, trash: { _ in
                calls.set()
                return URL(fileURLWithPath: "/Trash/removal.mp3")
            })
        }
        #expect(trashed == URL(fileURLWithPath: "/Trash/removal.mp3"))
        #expect(calls.isSet)
    }

    @Test func removeFromLibraryFreesTheLockWhenTheTrashFails() async {
        let lock = LibraryFileLock()
        let url = URL(fileURLWithPath: "/lib/removal-fails.mp3")
        do {
            _ = try await TrackLibraryRemoval.trashLocked(url, lock: lock, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
            Issue.record("expected a throw")
        } catch {}
        #expect(await lock.isHeld(LibraryFileLock.key(for: url)) == false)
    }

    // MARK: Review's Trash mode and put back

    private static let guards = ReviewConsequences.TrashGuards(keptURL: URL(fileURLWithPath: "/lib/kept.flac"),
                                                               libraryRoot: URL(fileURLWithPath: "/lib"))

    @Test func reviewTrashWaitsForTheFileAndFreesItAfterwards() async {
        let files = FakeReviewFiles(existing: ["/lib/a.mp3"])
        let url = URL(fileURLWithPath: "/lib/a.mp3")
        let harness = LockedWriteHarness(url: url)
        let report = await harness.run(untouched: { files.trashed.isEmpty }) { lock in
            var consequences = ReviewConsequences(files: files)
            consequences.lock = lock
            return await consequences.trash([.init(id: 1, url: url)], guards: Self.guards)
        }
        #expect(report.trashed.map(\.trackId) == [1])
        #expect(files.trashed == ["/lib/a.mp3"])
    }

    @Test func reviewTrashFreesTheLockWhenTheMoveFails() async {
        let files = FakeReviewFiles(existing: ["/lib/b.mp3"])
        files.failing = ["/lib/b.mp3"]
        let lock = LibraryFileLock()
        var consequences = ReviewConsequences(files: files)
        consequences.lock = lock
        let url = URL(fileURLWithPath: "/lib/b.mp3")
        let report = await consequences.trash([.init(id: 2, url: url)], guards: Self.guards)
        #expect(report.failures == 1)
        #expect(await lock.isHeld(LibraryFileLock.key(for: url)) == false)
    }

    @Test func reviewPutBackWaitsForTheOriginalPlaceAndFreesItAfterwards() async {
        let files = FakeReviewFiles(existing: ["/lib/c.mp3"])
        let url = URL(fileURLWithPath: "/lib/c.mp3")
        let report = await ReviewConsequences(files: files).trash([.init(id: 3, url: url)], guards: Self.guards)
        #expect(files.fileExists(atPath: "/Trash/c.mp3"))
        let harness = LockedWriteHarness(url: url)
        let back = await harness.run(untouched: { !files.fileExists(atPath: "/lib/c.mp3") }) { lock in
            var consequences = ReviewConsequences(files: files)
            consequences.lock = lock
            return await consequences.putBack(report.trashed)
        }
        #expect(back.restored == 1)
        #expect(files.fileExists(atPath: "/lib/c.mp3"))
    }

    // MARK: Discover / Similar delete

}
