import Foundation
import GRDB
import Testing
@testable import MLM

/// W2-E review B1 on generated files: a file only ever receives a value the user typed in MLM,
/// or — on undo — the exact value it had before MLM's first write. Never an import-normalised
/// database value (lower-cased tags, `unknown album`).
@Suite("Tag write rules (typed values and originals)", .serialized)
@MainActor
struct TagWriteRulesTests {
    private typealias F = TagTestFixtures

    struct Env {
        let db: DatabaseQueue
        let repository: TrackTagRepository
        let config: ConfigRepository
        let manager: UndoManager
        let undo: UndoCenter
        let queue: TagWriteQueue
        let edit: TrackTagEdit
        let folder: URL
        let file: URL
        let trackID: Int64
    }

    private let sleeper = ManualSleeper()

    /// One FLAC (or MP3) at `Artist/0.‹ext›` with `tags`, and its track row with `columns`
    /// (as an import would have stored them).
    private func makeEnv(_ kind: F.Kind = .flac, tags: [String: String], columns: [String: DatabaseValueConvertible?], writing: Bool = true) async throws -> Env {
        let folder = try F.makeFolder("rules")
        let root = folder.appendingPathComponent("Music", isDirectory: true)
        let artistFolder = root.appendingPathComponent("Artist", isDirectory: true)
        try FileManager.default.createDirectory(at: artistFolder, withIntermediateDirectories: true)
        let file = try await F.audio(kind, in: artistFolder, name: "0", tags: tags)
        let db = try DatabaseManager.inMemory()
        if writing {
            try await db.write { try $0.execute(sql: "INSERT INTO app_config (key, value) VALUES ('write_tags_to_files', '1')") }
        }
        let ids = try TrackTagRepositoryTests.seed(db, count: 1) { _ in "Artist/0.\(kind.fileExtension)" }
        // The row describes this file (format, duration) — the writer checks it is the track's (S2).
        var columns = columns
        columns["format"] = columns["format"] ?? kind.fileExtension
        columns["duration"] = columns["duration"] ?? 2
        for (column, value) in columns {
            try await db.write { try $0.execute(sql: "UPDATE tracks SET \(column) = ? WHERE id = ?", arguments: [value, ids[0]]) }
        }
        let repository = TrackTagRepository(database: db)
        let config = ConfigRepository(database: db)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = self.sleeper
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let queue = TagWriteQueue(dependencies: .init(
            repository: { repository },
            libraryRoot: { root.path },
            isEnabled: { await TagWriteSetting.isEnabled(config) },
            writer: TrackTagWriter(),
            statusBar: { status }
        ))
        let edit = TrackTagEdit(dependencies: .init(
            repository: { repository },
            writesEnabled: { await TagWriteSetting.isEnabled(config) },
            isLibraryFolderReachable: { false }, // flushes are explicit here
            volumeName: { "Lexxar" },
            queue: queue,
            tracksDidChange: { _ in }
        ), undo: undo)
        return Env(db: db, repository: repository, config: config, manager: manager, undo: undo, queue: queue,
                   edit: edit, folder: folder, file: file, trackID: ids[0])
    }

    private func undo(_ env: Env) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    private func redo(_ env: Env) async {
        env.manager.redo()
        await env.undo.waitUntilIdle()
    }

    private func flush(_ env: Env) async throws {
        let report = await env.queue.flushNow()
        #expect(report.failures.isEmpty && report.missing == 0, "flush failed: \(report)")
    }

    private func tag(_ env: Env, _ key: String) async throws -> String? {
        try await F.tags(of: env.file)[key]
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func undoRestoresTheFilesOwnValueNotTheLowerCasedColumn() async throws {
        let env = try await makeEnv(tags: ["title": "One More Time", "album": "Discovery"], columns: ["album": "discovery"])
        defer { F.remove(env.folder) }
        try await env.edit.perform(.text("Discovery (Live)"), field: .album, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "album") == "Discovery (Live)")
        await undo(env)
        try await flush(env)
        #expect(try await tag(env, "album") == "Discovery", "the file's own value, not “discovery”")
        await redo(env)
        try await flush(env)
        #expect(try await tag(env, "album") == "Discovery (Live)")
        #expect(try await tag(env, "title") == "One More Time", "untouched fields are never written")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aPlaceholderAlbumInTheDatabaseNeverDeletesTheFilesAlbum() async throws {
        let env = try await makeEnv(tags: ["album": "Real Album"], columns: ["album": "unknown album"])
        defer { F.remove(env.folder) }
        try await env.edit.perform(.text("X"), field: .album, trackIDs: [env.trackID])
        try await flush(env)
        await undo(env)
        try await flush(env)
        #expect(try await tag(env, "album") == "Real Album")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aFileWithoutAnAlbumGetsNoneBack() async throws {
        let env = try await makeEnv(tags: ["title": "T"], columns: ["album": "unknown album"])
        defer { F.remove(env.folder) }
        try await env.edit.perform(.text("Typed"), field: .album, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "album") == "Typed")
        await undo(env)
        try await flush(env)
        #expect(try await tag(env, "album") == nil, "absent before MLM, absent again")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func anEditMadeWhileOffNeverReachesTheFileOnUndo() async throws {
        let env = try await makeEnv(tags: ["genre": "Techno"], columns: ["genre": "techno"], writing: false)
        defer { F.remove(env.folder) }
        let bytes = try Data(contentsOf: env.file)
        try await env.edit.perform(.text("House"), field: .genre, trackIDs: [env.trackID])
        try await TagWriteSetting.setEnabled(true, config: env.config)
        await undo(env)
        _ = await env.queue.flushNow()
        #expect(try Data(contentsOf: env.file) == bytes, "the database went back to “techno”; the file was never touched")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func anEditUndoneBeforeItWasWrittenLeavesTheFileAlone() async throws {
        let env = try await makeEnv(tags: ["genre": "Techno"], columns: ["genre": "techno"])
        defer { F.remove(env.folder) }
        let bytes = try Data(contentsOf: env.file)
        try await env.edit.perform(.text("House"), field: .genre, trackIDs: [env.trackID])
        await undo(env)
        _ = await env.queue.flushNow()
        #expect(try Data(contentsOf: env.file) == bytes)
        #expect(try await env.repository.fieldStates(trackID: env.trackID).isEmpty)
        #expect(try await env.repository.pendingCount() == 0)
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aTypedPlaceholderLiteralIsTheUsersValue() async throws {
        let env = try await makeEnv(tags: ["album": "Old"], columns: ["album": "old"])
        defer { F.remove(env.folder) }
        try await env.edit.perform(.text("Unknown"), field: .album, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "album") == "Unknown")
        try await env.edit.perform(.text(""), field: .album, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "album") == nil, "cleared by the user: no album tag")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func aYearEditKeepsAFullDateOfTheSameYear() async throws {
        let env = try await makeEnv(tags: ["date": "2019-05-03"], columns: ["year": nil])
        defer { F.remove(env.folder) }
        try await env.edit.perform(.number(2019), field: .year, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "date") == "2019-05-03")
        try await env.edit.perform(.number(2020), field: .year, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "date") == "2020")
        await undo(env) // back to the 2019 step
        try await flush(env)
        #expect(try await tag(env, "date") == "2019-05-03", "the same year keeps the file's full date")
        await undo(env) // before MLM
        try await flush(env)
        #expect(try await tag(env, "date") == "2019-05-03")
    }

    @Test(.enabled(if: F.toolsAvailable, F.skipReason))
    func stepsUndoInOrderBackToTheOriginal() async throws {
        let env = try await makeEnv(.mp3, tags: ["title": "Original Title"], columns: ["title": "original title"])
        defer { F.remove(env.folder) }
        try await env.edit.perform(.text("A"), field: .title, trackIDs: [env.trackID])
        try await flush(env)
        try await env.edit.perform(.text("B"), field: .title, trackIDs: [env.trackID])
        try await flush(env)
        #expect(try await tag(env, "title") == "B")
        await undo(env)
        try await flush(env)
        #expect(try await tag(env, "title") == "A", "a value the user typed")
        await undo(env)
        try await flush(env)
        #expect(try await tag(env, "title") == "Original Title")
    }

    /// The flush plan alone (no files): an undone, never-written field is dropped; a typed
    /// value captures the original on the first write only.
    @Test func planUsesTypedValuesAndCapturedOriginalsOnly() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { try $0.execute(sql: "INSERT INTO app_config (key, value) VALUES ('write_tags_to_files', '1')") }
        let ids = try TrackTagRepositoryTests.seed(db, count: 1)
        let repository = TrackTagRepository(database: db)
        _ = try await repository.apply(.text("Typed"), to: .album, trackIDs: ids, queueFileWrites: true)
        var pending = try #require(try await repository.pendingWrite(trackID: ids[0]))
        var plan = try await TagWriteQueue.plan(pending, repository: repository)
        #expect(plan.targets == [.album: .typed("Typed")] && plan.needOriginals == [.album])
        try await repository.recordOriginals(trackID: ids[0], values: [.album: "File Album"])
        try await repository.recordOriginals(trackID: ids[0], values: [.album: "Never Replaced"])
        plan = try await TagWriteQueue.plan(pending, repository: repository)
        #expect(plan.needOriginals.isEmpty, "captured once")
        let undone = try await repository.restore([TrackTagSnapshot(trackID: ids[0], value: .text("x"), fileIntent: .original)],
                                                  field: .album, queueFileWrites: true)
        #expect(undone.queuedForFiles == 1)
        pending = try #require(try await repository.pendingWrite(trackID: ids[0]))
        plan = try await TagWriteQueue.plan(pending, repository: repository)
        #expect(plan.targets == [.album: .restore("File Album")] && plan.restored == [.album])
    }
}
