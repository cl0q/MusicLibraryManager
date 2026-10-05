import Foundation
import GRDB
import Testing
@testable import MLM

/// W2-C: Locate File… re-points a File missing track at a file inside the library folder,
/// clears the flag, and is undoable to the exact previous columns; a file outside the library
/// folder is refused and nothing changes. Temporary database and folders only.
@Suite("LocateFileTests")
@MainActor
struct LocateFileTests {

    private struct Fixture {
        let db: DatabaseQueue
        let tracks: TrackRepository
        let store: TrackLocateRepository
        let root: URL
        let manager = UndoManager()
        let undo: UndoCenter

        @MainActor init() throws {
            db = try DatabaseManager.inMemory()
            tracks = TrackRepository(database: db)
            store = TrackLocateRepository(database: db)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-locate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Artist"), withIntermediateDirectories: true)
            undo = UndoCenter(undoManager: manager, statusBar: StatusBarCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in }),
                              log: { _ in }, reentrancyFailure: { _ in })
        }

        func missingTrack() async throws -> Track {
            var track = Track(artist: "Artist", album: "Album", title: "Glass Circuit", format: "m4a", originalPath: "soundcloud://1")
            track.organizedPath = "Old/Glass Circuit.m4a"
            track.fileMissingSince = "2026-10-01T08:00:00Z"
            let inserted = try await tracks.insert(track)
            // `Track.encode` never writes the flag (the reconciler's fact): set it like it does.
            try await db.write { db in
                try db.execute(sql: "UPDATE tracks SET file_missing_since = ? WHERE id = ?",
                               arguments: ["2026-10-01T08:00:00Z", inserted.id])
            }
            return inserted
        }

        func file(_ relative: String) -> URL {
            let url = root.appendingPathComponent(relative)
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            return url
        }

        func columns(_ id: Int64) async throws -> (String?, String?) {
            try await db.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT organized_path, file_missing_since FROM tracks WHERE id = ?", arguments: [id])!
                return (row["organized_path"], row["file_missing_since"])
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func locatingStoresTheRelativePathAndClearsTheFlagUndoably() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let id = try #require(track.id)
        var changes = 0
        let outcome = await LocateFileAction.locate(track, at: f.file("Artist/Glass Circuit.m4a"), libraryRoot: f.root.path,
                                                    repository: f.store, undo: f.undo, didChange: { changes += 1 })
        #expect(outcome == .located(relativePath: "Artist/Glass Circuit.m4a"))
        var (path, missing) = try await f.columns(id)
        #expect(path == "Artist/Glass Circuit.m4a" && missing == nil)
        #expect(try await f.tracks.fetchTrack(id: id)?.availability() == .local)
        #expect(f.manager.undoActionName == "Locate “Glass Circuit”")
        #expect(f.undo.statusBar.message?.text == "Located the file of “Glass Circuit”")

        f.manager.undo()
        await f.undo.waitUntilIdle()
        (path, missing) = try await f.columns(id)
        #expect(path == "Old/Glass Circuit.m4a" && missing == "2026-10-01T08:00:00Z", "Undo restores both columns exactly")

        f.manager.redo()
        await f.undo.waitUntilIdle()
        (path, missing) = try await f.columns(id)
        #expect(path == "Artist/Glass Circuit.m4a" && missing == nil)
        #expect(changes == 3, "every step asks the lists to re-read the row")
    }

    @Test func aFileOutsideTheLibraryFolderIsRefusedAndNothingChanges() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: outside.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: outside) }
        let outcome = await LocateFileAction.locate(track, at: outside, libraryRoot: f.root.path, repository: f.store, undo: f.undo,
                                                    didChange: {})
        #expect(outcome == .refused(message: "Couldn’t use “\(outside.lastPathComponent)” — the file must be inside the library folder"))
        let (path, missing) = try await f.columns(try #require(track.id))
        #expect(path == "Old/Glass Circuit.m4a" && missing != nil, "\(String(describing: path)) \(String(describing: missing))")
        #expect(!f.manager.canUndo)
    }

    @Test func rules() {
        let root = "/Volumes/Lexxar/Music"
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/Volumes/Lexxar/Music/A/b.m4a"), libraryRoot: root)
                == .inside(relativePath: "A/b.m4a"))
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/Volumes/Lexxar/Music2/b.m4a"), libraryRoot: root) == .outsideLibraryFolder,
                "a sibling folder with the same prefix is outside")
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/Volumes/Lexxar/Music/../x.m4a"), libraryRoot: root) == .outsideLibraryFolder)
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/tmp/x.m4a"), libraryRoot: nil) == .noLibraryFolder)
        #expect(LocateFileRule.panelMessage(title: "Glass Circuit") == "Choose the file of “Glass Circuit”. It must be inside the library folder.")
    }

    @Test func theDropOffsetFeedsTheHotSpot() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let id = try #require(track.id)
        #expect(try await f.store.dropOffset(trackID: id) == nil)
        try await f.tracks.saveTrackEmbedding(trackId: id, embedding: [0.1, 0.2], dropOffset: 84, mixCategory: nil)
        #expect(try await f.store.dropOffset(trackID: id) == 84)
    }

    @Test func locateRequestsAreOnePerWindow() {
        let request = LocateFileRequest.shared
        var track = Track(artist: "A", album: "B", title: "C", format: "m4a", originalPath: "x")
        request.begin(track)
        #expect(!request.isPresented, "a track without an id is ignored")
        track.id = 7
        request.begin(track)
        #expect(request.isPresented && request.track?.id == 7)
        request.finish()
        #expect(!request.isPresented && request.track == nil)
    }
}
