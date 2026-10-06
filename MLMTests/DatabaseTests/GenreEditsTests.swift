import Foundation
import GRDB
import Testing
@testable import MLM

/// Genre queries and every genre change of the Genres place on temporary databases (W3-GEN):
/// Rename, Merge, a drop on a genre row, `Save n Changes` and Remove from ‹Genre› are each
/// **one** `TrackTagEdit` step that undo restores exactly per track, and none of them writes or
/// queues a file while `Write tags to files` is off (the default).
@Suite("Genres: queries and undoable genre edits", .serialized)
@MainActor
struct GenreEditsTests {
    struct Env {
        let db: DatabaseQueue
        let tags: TrackTagRepository
        let genres: GenreRepository
        let manager: UndoManager
        let status: StatusBarCenter
        let undo: UndoCenter
        let writer: RecordingTagWriter
        let queue: TagWriteQueue
        let edits: GenreEdits
        let root: URL
    }

    private let sleeper = ManualSleeper()

    private func makeEnv(writesTags: Bool) throws -> Env {
        let db = try DatabaseManager.inMemory()
        if writesTags {
            try db.write { try $0.execute(sql: "INSERT INTO app_config (key, value) VALUES ('write_tags_to_files', '1')") }
        }
        let tags = TrackTagRepository(database: db)
        let config = ConfigRepository(database: db)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = self.sleeper
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let folder = try TagTestFixtures.makeFolder("genres")
        let root = folder.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = RecordingTagWriter()
        let queue = TagWriteQueue(dependencies: .init(
            repository: { tags },
            libraryRoot: { root.path },
            isEnabled: { await TagWriteSetting.isEnabled(config) },
            writer: writer,
            statusBar: { status }
        ))
        let tagEdit = TrackTagEdit(dependencies: .init(
            repository: { tags },
            writesEnabled: { await TagWriteSetting.isEnabled(config) },
            // The folder is "away": queued writes stay in the table where the test can see them.
            isLibraryFolderReachable: { false },
            volumeName: { "Lexxar" },
            queue: queue,
            tracksDidChange: { _ in }
        ), undo: undo)
        let genres = GenreRepository(database: db)
        return Env(db: db, tags: tags, genres: genres, manager: manager, status: status, undo: undo,
                   writer: writer, queue: queue, edits: GenreEdits(tagEdit: tagEdit, repository: genres), root: root)
    }

    /// Tracks with the given genres (nil = none), each with a file in the library folder.
    @discardableResult
    private func seed(_ db: DatabaseQueue, _ genres: [String?], bpm: Int? = nil) throws -> [Int64] {
        try db.write { db in
            try genres.enumerated().map { index, genre in
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, genre, bpm, duration, format, original_path, organized_path, is_duplicate)
                    VALUES (?, ?, 'Album', ?, ?, ?, 300, 'm4a', ?, ?, 0)
                    """, arguments: ["Artist", "Artist", "Title \(index)", genre, bpm, "/orig/\(UUID().uuidString).m4a", "Artist/\(index).m4a"])
                return db.lastInsertedRowID
            }
        }
    }

    private func storedGenres(_ env: Env, _ ids: [Int64]) async throws -> [String?] {
        try await env.tags.fetchTracks(ids: ids).map(\.genre)
    }

    private func undo(_ env: Env) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    private func redo(_ env: Env) async {
        env.manager.redo()
        await env.undo.waitUntilIdle()
    }

    private func fileWork(_ env: Env) throws -> (pending: Int, intents: Int) {
        try env.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_tag_writes") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_write_fields") ?? 0)
        }
    }

    // MARK: Queries

    @Test func overviewGroupsBySQLAndFoldsCase() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        try seed(env.db, ["house", "house", "House", "Techno", nil, "", "  "])
        let overview = try await env.genres.overview()
        #expect(overview.genres.map(\.name) == ["House", "Techno"])
        #expect(overview.genres.map(\.trackCount) == [3, 1])
        #expect(overview.genres.first?.duration == 900)
        #expect(overview.tracksWithoutGenre == 3)
    }

    @Test func tracksOfAGenreAreFoundByKeyWhateverTheSpelling() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["house", "House ", "HOUSE", "Deep House", nil])
        #expect(try await env.genres.trackIDs(genreKeys: ["house"]) == Array(ids[0...2]))
        #expect(try await env.genres.tracks(genreKeys: ["house", "deep house"]).compactMap(\.id) == Array(ids[0...3]))
        #expect(try await env.genres.trackIDs(genreKeys: []) == [])
    }

    @Test func similarityFactsAndTypicalTrack() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["Techno", "Techno", "Techno", "Techno"])
        let vectors: [[Float]] = [[1, 0, 0], [0.9, 0.1, 0], [0.8, 0.2, 0], [0, 0, 1]]
        try await env.db.write { db in
            for (id, vector) in zip(ids.prefix(4), vectors) {
                try db.execute(sql: "INSERT INTO track_embeddings (track_id, master_embedding, drop_offset) VALUES (?, ?, 0)",
                               arguments: [id, vector.toData])
            }
        }
        #expect(try await env.genres.hasSimilarityAnalysis(trackID: ids[0]))
        #expect(try await !env.genres.hasSimilarityAnalysis(trackID: 999))
        let coverage = try await env.genres.similarityCoverage()
        #expect(coverage.analysed == 4 && coverage.total == 4)
        // Centroid (0.675, 0.075, 0.25): the second track is the most typical.
        #expect(try await env.genres.typicalTrackID(among: ids) == ids[1])
        #expect(try await env.genres.typicalTrackID(among: [999]) == nil)
    }

    // MARK: Rename (one step, exact restore)

    @Test func renameIsOneStepThatRestoresEveryTracksOwnSpelling() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["house", "House", "HOUSE", "Techno"])
        let before = try await storedGenres(env, ids)
        let house = try #require(try await env.genres.overview().genres.first { $0.key == "house" })
        try await env.edits.rename(house, to: "  Deep  House ")
        #expect(try await storedGenres(env, ids) == ["Deep House", "Deep House", "Deep House", "Techno"])
        #expect(env.undo.stepCount == 1)
        #expect(env.manager.undoActionName == "Rename Genre")
        #expect(env.status.message?.text == "Renamed “\(house.name)” to “Deep House”")
        #expect(env.status.message?.actions.map(\.title) == ["Undo"])
        await undo(env)
        #expect(try await storedGenres(env, ids) == before, "each track gets its own spelling back")
        await redo(env)
        #expect(try await storedGenres(env, ids) == ["Deep House", "Deep House", "Deep House", "Techno"])
    }

    // MARK: Merge (s-merge)

    @Test func mergeIsOneStepOverEveryTrackOfTheMergedGenres() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["Hip-Hop", "Hip Hop", "hip hop", "HipHop", "Techno", nil])
        let before = try await storedGenres(env, ids)
        let all = try await env.genres.overview().genres
        let merged = all.filter { ["hip-hop", "hip hop", "hiphop"].contains($0.key) }
        #expect(merged.count == 3)
        try await env.edits.merge(merged, into: "Hip-Hop")
        #expect(try await storedGenres(env, ids) == ["Hip-Hop", "Hip-Hop", "Hip-Hop", "Hip-Hop", "Techno", nil])
        #expect(env.undo.stepCount == 1)
        #expect(env.manager.undoActionName == "Merge Genres")
        #expect(env.status.message?.text == "Merged 3 genres into “Hip-Hop” — 3 tracks changed",
                "the track already spelled `Hip-Hop` doesn't change")
        #expect(try await env.genres.overview().genres.map(\.name) == ["Hip-Hop", "Techno"])
        await undo(env)
        #expect(try await storedGenres(env, ids) == before)
        #expect(try await env.genres.overview().genres.count == 4)
    }

    @Test func mergeNeedsTwoGenresAndAName() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        try seed(env.db, ["A", "B"])
        let all = try await env.genres.overview().genres
        #expect(try await env.edits.merge(all, into: "   ") == nil)
        #expect(try await env.edits.merge(Array(all.prefix(1)), into: "C") == nil)
        #expect(env.undo.stepCount == 0)
    }

    // MARK: Drop on a genre row, Save n Changes, Remove from ‹Genre›

    @Test func dropOnAGenreRowSetsTheGenreAsOneStep() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, [nil, "Ambient", "techno", "Techno"])
        try await env.edits.setGenre(of: ids, to: "Techno")
        #expect(try await storedGenres(env, ids) == ["Techno", "Techno", "Techno", "Techno"])
        #expect(env.status.message?.text == "Set genre of 3 tracks to “Techno”")
        #expect(env.manager.undoActionName == "Set Genre")
        await undo(env)
        #expect(try await storedGenres(env, ids) == [nil, "Ambient", "techno", "Techno"])
    }

    @Test func savingStagedTracksIsOneStep() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, [nil, nil, "Ambient"])
        try await env.edits.saveStaged(ids, genreName: "Techno")
        #expect(env.undo.stepCount == 1)
        #expect(env.status.message?.text == "Saved — 3 tracks are now “Techno”")
        #expect(env.manager.undoActionName == "Add to “Techno”")
        await undo(env)
        #expect(try await storedGenres(env, ids) == [nil, nil, "Ambient"])
        // Nothing changes: no step, no message.
        let unchanged = try seed(env.db, ["Techno"])
        #expect(try await env.edits.saveStaged(unchanged, genreName: "Techno") == nil)
    }

    @Test func removeFromGenreClearsItUndoably() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["Techno", "techno"])
        try await env.edits.remove(ids, fromGenre: "Techno")
        #expect(try await storedGenres(env, ids) == [nil, nil])
        #expect(env.status.message?.text == "Removed 2 tracks from “Techno”")
        #expect(env.manager.undoActionName == "Remove from “Techno”")
        await undo(env)
        #expect(try await storedGenres(env, ids) == ["Techno", "techno"])
    }

    // MARK: Files (Write tags to files)

    @Test func noFileIsWrittenOrQueuedWhileWritingIsOff() async throws {
        let env = try makeEnv(writesTags: false)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["house", "Hip Hop", "HipHop", nil])
        let all = try await env.genres.overview().genres
        try await env.edits.rename(try #require(all.first { $0.key == "house" }), to: "House")
        try await env.edits.merge(all.filter { $0.key.hasPrefix("hip") }, into: "Hip-Hop")
        try await env.edits.setGenre(of: [ids[3]], to: "Ambient")
        try await env.edits.remove([ids[3]], fromGenre: "Ambient")
        await undo(env)
        _ = await env.queue.flushNow()
        #expect(try fileWork(env) == (0, 0), "nothing marked for the files")
        #expect(env.writer.requests.isEmpty, "no file was written")
    }

    @Test func withWritingOnTheTypedNameIsQueuedForTheFiles() async throws {
        let env = try makeEnv(writesTags: true)
        defer { TagTestFixtures.remove(env.root.deletingLastPathComponent()) }
        let ids = try seed(env.db, ["house", "house"])
        let house = try #require(try await env.genres.overview().genres.first)
        try await env.edits.rename(house, to: "House")
        #expect(try fileWork(env).pending == 2)
        #expect(env.status.message?.text == "Renamed “House” to “House” · 2 tag changes waiting for “Lexxar”")
        #expect(env.writer.requests.isEmpty, "the folder is away: nothing written yet")
        _ = ids
    }
}
