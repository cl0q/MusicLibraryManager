import Foundation
import GRDB
import Testing
@testable import MLM

/// A writer that records what it was asked to write and answers per track (by file name).
final class RecordingTagWriter: TagWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [TagWriteRequest] = []
    /// Answer per file name; default `.written`.
    var answers: [String: TagWriteOutcome] = [:]
    /// Runs before answering (e.g. take the library folder away).
    var onWrite: @Sendable (TagWriteRequest) -> Void = { _ in }

    var requests: [TagWriteRequest] { lock.withLock { _requests } }

    func write(_ request: TagWriteRequest, captureOriginals: @escaping TagOriginalsCapture) async -> TagWriteOutcome {
        onWrite(request)
        lock.withLock { _requests.append(request) }
        return answers[request.fileURL.lastPathComponent] ?? .written
    }
}

/// `TrackTagEdit` (one undoable step per commit, exact restore per track) and `TagWriteQueue`
/// (offline queue, flush safety) on temporary databases and folders.
@Suite("TrackTagEdit and TagWriteQueue", .serialized)
@MainActor
struct TrackTagEditTests {
    struct Env {
        let db: DatabaseQueue
        let repository: TrackTagRepository
        let config: ConfigRepository
        let manager: UndoManager
        let status: StatusBarCenter
        let undo: UndoCenter
        let queue: TagWriteQueue
        let writer: RecordingTagWriter
        let root: URL
        let edit: TrackTagEdit
        let reachable: Reachability
    }

    final class Reachability: @unchecked Sendable {
        var value = true
    }

    private let sleeper = ManualSleeper()

    private func makeEnv(rootExists: Bool = true, writer: (any TagWriting)? = nil) throws -> Env {
        let db = try DatabaseManager.inMemory()
        // Writing is off unless turned on (fails closed); these tests are about writing.
        try db.write { try $0.execute(sql: "INSERT INTO app_config (key, value) VALUES ('write_tags_to_files', '1')") }
        let repository = TrackTagRepository(database: db)
        let config = ConfigRepository(database: db)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = self.sleeper
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let folder = try TagTestFixtures.makeFolder("queue")
        let root = folder.appendingPathComponent("Music", isDirectory: true)
        if rootExists { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let recording = RecordingTagWriter()
        let queue = TagWriteQueue(dependencies: .init(
            repository: { repository },
            libraryRoot: { root.path },
            isEnabled: { await TagWriteSetting.isEnabled(config) },
            writer: writer ?? recording,
            fileMissing: { _ in },
            statusBar: { status }
        ))
        let reachable = Reachability()
        reachable.value = rootExists
        let edit = TrackTagEdit(dependencies: .init(
            repository: { repository },
            writesEnabled: { await TagWriteSetting.isEnabled(config) },
            isLibraryFolderReachable: { reachable.value },
            volumeName: { "Lexxar" },
            queue: queue,
            tracksDidChange: { _ in }
        ), undo: undo)
        return Env(db: db, repository: repository, config: config, manager: manager, status: status, undo: undo,
                   queue: queue, writer: recording, root: root, edit: edit, reachable: reachable)
    }

    private func undo(_ env: Env) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    private func redo(_ env: Env) async {
        env.manager.redo()
        await env.undo.waitUntilIdle()
    }

    private func genres(_ env: Env, _ ids: [Int64]) async throws -> [String?] {
        try await env.repository.fetchTracks(ids: ids).map(\.genre)
    }

    // MARK: Undo (DEC-041, UC-UNDO-02/07/08)

    @Test func aSingleEditIsOneStepAndUndoRedoAreExact() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        let before = try await genres(env, ids)
        env.reachable.value = false // keep the queue out of it
        let step = try await env.edit.perform(.text("Techno"), field: .genre, trackIDs: ids, singleTitle: "Title 0")
        #expect(step != nil)
        #expect(env.undo.stepCount == 1)
        #expect(env.manager.undoActionName == "Edit Genre")
        #expect(env.status.message?.text == "Changed genre of “Title 0” · 1 tag change waiting for “Lexxar”")
        #expect(env.status.message?.actions.map(\.title) == ["Undo"])
        #expect(try await genres(env, ids) == ["Techno"])
        await undo(env)
        #expect(try await genres(env, ids) == before)
        await redo(env)
        #expect(try await genres(env, ids) == ["Techno"])
    }

    @Test func fiveHundredMixedTracksAreOneStepRestoredExactlyPerTrack() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 500)
        let beforeTracks = try await env.repository.fetchTracks(ids: ids)
        #expect(Set(beforeTracks.map(\.genre)).count > 3, "mixed values to start with")
        env.reachable.value = false
        try await env.edit.perform(.text("House"), field: .genre, trackIDs: ids)
        try await env.edit.perform(.number(2050), field: .year, trackIDs: ids)
        #expect(env.undo.stepCount == 2, "one step per commit")
        #expect(env.status.message?.text == "Changed year of 500 tracks · 500 tag changes waiting for “Lexxar”")
        await undo(env) // year
        let afterYearUndo = try await env.repository.fetchTracks(ids: ids)
        #expect(afterYearUndo.map(\.year) == beforeTracks.map(\.year))
        #expect(afterYearUndo.allSatisfy { $0.genre == "House" })
        #expect(env.manager.undoActionName == "Edit Genre")
        await undo(env) // genre
        let restored = try await env.repository.fetchTracks(ids: ids)
        #expect(restored.map(\.genre) == beforeTracks.map(\.genre), "every track gets its own previous value back")
        #expect(restored.map(\.searchText) == beforeTracks.map { DatabaseManager.foldedSearchText($0.rawSearchText) })
        await redo(env)
        #expect(try await genres(env, ids).allSatisfy { $0 == "House" })
    }

    @Test func noChangeRegistersNothing() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        env.reachable.value = false
        try await env.edit.perform(.text("Same"), field: .genre, trackIDs: ids)
        let messages = env.status.message?.id
        let again = try await env.edit.perform(.text("Same"), field: .genre, trackIDs: ids)
        #expect(again == nil)
        #expect(env.undo.stepCount == 1)
        #expect(env.status.message?.id == messages, "nothing posted")
    }

    @Test func undoMarksTheFilesStaleAgain() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 3)
        env.reachable.value = false
        try await env.edit.perform(.text("Ambient"), field: .genre, trackIDs: ids)
        // The files got written meanwhile.
        for pending in try await env.repository.pendingWrites(limit: 10) {
            try await env.repository.completeWrite(trackID: pending.trackID, revision: pending.revision)
        }
        #expect(try await env.repository.pendingCount() == 0)
        await undo(env)
        #expect(try await env.repository.pendingCount() == 3, "the files must follow the database back")
    }

    @Test func settingOffQueuesNothing() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        try await TagWriteSetting.setEnabled(false, config: env.config)
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 4)
        try await env.edit.perform(.text("Ambient"), field: .genre, trackIDs: ids)
        #expect(try await env.repository.pendingCount() == 0)
        #expect(env.status.message?.text == "Changed genre of 4 tracks")
        // Something queued earlier isn't written while it's off.
        try await env.repository.queueTypedValue(.text("Dub"), field: .genre, trackIDs: ids)
        #expect(await env.queue.flushNow().outcome == .disabled)
        #expect(env.writer.requests.isEmpty)
    }

    @Test func turningTheSettingOffStopsARunningFlush() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 4)
        env.reachable.value = false
        try await env.edit.perform(.text("Dub"), field: .genre, trackIDs: ids)
        let db = env.db
        env.writer.onWrite = { _ in
            try? db.write { try $0.execute(sql: "UPDATE app_config SET value = '0' WHERE key = 'write_tags_to_files'") }
        }
        let report = await env.queue.flushNow()
        #expect(report.outcome == .disabled)
        #expect(env.writer.requests.count == 1, "nothing after it was turned off")
        #expect(try await env.repository.pendingCount() == 3)
    }

    @Test func unsupportedFilesAreSaidOnce() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 3) { $0 == 0 ? "A/0.mp3" : "A/\($0).wav" }
        try await env.edit.perform(.text("Ambient"), field: .genre, trackIDs: ids)
        #expect(env.status.message?.text == "Changed genre of 3 tracks · Tags of 2 files couldn’t be written — WAV isn’t supported")
    }

    // MARK: Queue (UC-JOB-10)

    @Test func flushWritesTheCurrentValuesAndClearsTheRows() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        env.reachable.value = false
        try await env.edit.perform(.text("First"), field: .genre, trackIDs: ids)
        try await env.edit.perform(.text("Latest"), field: .genre, trackIDs: ids)
        try await env.edit.perform(.text("New Title"), field: .title, trackIDs: [ids[0]])
        let report = await env.queue.flushNow()
        #expect(report.outcome == .finished)
        #expect(report.written == 2)
        let requests = env.writer.requests
        #expect(requests.count == 2, "one write per track, however many edits")
        let first = try #require(requests.first { $0.fileURL.lastPathComponent == "0.mp3" })
        #expect(first.targets[.genre] == .typed("Latest"))
        #expect(first.targets[.title] == .typed("New Title"))
        #expect(first.fileURL.path.hasPrefix(env.root.path))
        #expect(try await env.repository.pendingCount() == 0)
    }

    @Test func nothingIsTriedWhileTheFolderIsAway() async throws {
        let env = try makeEnv(rootExists: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        try await env.edit.perform(.text("Dub"), field: .genre, trackIDs: ids)
        #expect(env.status.message?.text == "Changed genre of 2 tracks · 2 tag changes waiting for “Lexxar”")
        #expect(await env.queue.flushNow().outcome == .unreachable)
        #expect(env.writer.requests.isEmpty)
        #expect(try await env.repository.pendingCount() == 2)
        // The drive returns.
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: true)
        #expect(await env.queue.flushNow().written == 2)
        #expect(try await env.repository.pendingCount() == 0)
    }

    @Test func losingTheFolderMidRunStopsAndKeepsTheRest() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 5)
        env.reachable.value = false
        try await env.edit.perform(.text("Dub"), field: .genre, trackIDs: ids)
        let root = env.root
        env.writer.onWrite = { _ in try? FileManager.default.removeItem(at: root) } // unplugged during the first file
        let report = await env.queue.flushNow()
        #expect(report.outcome == .rootLost)
        #expect(env.writer.requests.count == 1, "nothing after the folder went away")
        #expect(try await env.repository.pendingCount() >= 4)
    }

    @Test func aMissingFileStaysQueuedAndNeverBlocksTheOthers() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 3)
        env.reachable.value = false
        try await env.edit.perform(.text("Dub"), field: .genre, trackIDs: ids)
        env.writer.answers["0.mp3"] = .failed(.fileMissing)
        let report = await env.queue.flushNow()
        #expect(report.written == 2)
        #expect(report.missing == 1)
        #expect(report.failureMessage == "Tags of 1 file couldn’t be written — file not found")
        #expect(env.status.message?.text == "Tags of 1 file couldn’t be written — file not found")
        let waiting = try #require(try await env.repository.pendingWrite(trackID: ids[0]))
        #expect(!waiting.blocked && waiting.lastError == "file not found")
        // It is tried again next time; once found, written.
        env.writer.answers["0.mp3"] = nil
        #expect(await env.queue.flushNow().written == 1)
        #expect(try await env.repository.pendingCount() == 0)
    }

    @Test func permanentFailuresAreNotRetriedUntilTheNextEdit() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        env.reachable.value = false
        try await env.edit.perform(.text("Dub"), field: .genre, trackIDs: ids)
        env.writer.answers["0.mp3"] = .failed(.verificationFailed("tag x would be lost"))
        #expect(await env.queue.flushNow().failures == ["rewriting would have changed more than the tags": 1])
        #expect(await env.queue.flushNow().failures.isEmpty, "blocked: not tried again")
        #expect(env.writer.requests.count == 1)
        try await env.edit.perform(.text("Techno"), field: .genre, trackIDs: ids)
        _ = await env.queue.flushNow()
        #expect(env.writer.requests.count == 2, "a new edit deserves a new attempt")
    }

    @Test func deletedTracksLeaveNoPendingRow() async throws {
        let env = try makeEnv()
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 2)
        env.reachable.value = false
        try await env.edit.perform(.text("Dub"), field: .genre, trackIDs: ids)
        try await TrackRepository(database: env.db).delete(ids: [ids[1]])
        _ = await env.queue.flushNow()
        #expect(env.writer.requests.map(\.fileURL.lastPathComponent) == ["0.mp3"])
        #expect(try await env.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_tag_writes") } == 0)
    }

    /// End to end with a real file: edited while the folder is away, written when it returns.
    @Test(.enabled(if: TagTestFixtures.toolsAvailable, TagTestFixtures.skipReason))
    func anOfflineEditReachesTheFileWhenTheFolderReturns() async throws {
        let env = try makeEnv(rootExists: false, writer: TrackTagWriter())
        let parent = env.root.deletingLastPathComponent()
        defer { TagTestFixtures.remove(parent) }
        let staging = parent.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Artist"), withIntermediateDirectories: true)
        _ = try await TagTestFixtures.audio(.mp3, in: staging.appendingPathComponent("Artist"), name: "0", tags: ["title": "Title 0", "genre": "Old"])
        let ids = try TrackTagRepositoryTests.seed(env.db, count: 1)
        try await env.edit.perform(.text("Techno"), field: .genre, trackIDs: ids)
        #expect(await env.queue.flushNow().outcome == .unreachable)
        try FileManager.default.moveItem(at: staging, to: env.root) // the drive is back
        let report = await env.queue.flushNow()
        #expect(report.written == 1)
        #expect(try await TagTestFixtures.tags(of: env.root.appendingPathComponent("Artist/0.mp3"))["genre"] == "Techno")
        #expect(try await env.repository.pendingCount() == 0)
    }
}
