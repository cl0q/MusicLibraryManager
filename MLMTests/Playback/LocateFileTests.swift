import Foundation
import GRDB
import Testing
@testable import MLM

/// W2-C: Locate File… re-points a File missing / Download failed track at a file inside the
/// library folder as one undo step that restores every changed column exactly; it refuses a
/// file outside the folder or one another track uses, and asks when length or format differ.
/// Temporary database and folders only; no app-wide singleton is touched.
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

        func insert(title: String, organized: String?, missingSince: String? = nil, failure: String? = nil,
                    status: String? = nil, format: String = "m4a", duration: Int? = 300) async throws -> Track {
            var track = Track(artist: "Artist", album: "Album", title: title, format: format, originalPath: "soundcloud://\(title)")
            track.organizedPath = organized
            track.duration = duration
            track.bitrate = 256
            track.downloadStatus = status
            track.downloadFailure = failure
            let inserted = try await tracks.insert(track)
            // `Track.encode` never writes the flag (the reconciler's fact): set it like it does.
            try await db.write { db in
                try db.execute(sql: "UPDATE tracks SET file_missing_since = ? WHERE id = ?", arguments: [missingSince, inserted.id])
            }
            return inserted
        }

        func missingTrack() async throws -> Track {
            try await insert(title: "Glass Circuit", organized: "Old/Glass Circuit.m4a", missingSince: "2026-10-01T08:00:00Z")
        }

        func file(_ relative: String) -> URL {
            let url = root.appendingPathComponent(relative)
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            return url
        }

        func row(_ id: Int64) async throws -> Row {
            try await db.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT organized_path, file_missing_since, format, bitrate, duration, download_status, download_failure
                    FROM tracks WHERE id = ?
                    """, arguments: [id])!
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static func facts(format: String = "m4a", duration: Int? = 301, bitrate: Int? = 190) -> (URL) async -> TrackLocateRepository.FileFacts? {
        { _ in TrackLocateRepository.FileFacts(format: format, bitrate: bitrate, duration: duration) }
    }

    @Test func locatingIsOneUndoStepThatRestoresEveryColumn() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let failure = "{\"attempts\":2,\"date\":\"2026-10-01T08:00:00.000Z\",\"reason\":\"Not found\"}"
        let track = try await f.insert(title: "Glass Circuit", organized: "Old/Glass Circuit.m4a",
                                       missingSince: "2026-10-01T08:00:00Z", failure: failure, status: "failed")
        let id = try #require(track.id)
        let before = try await f.row(id)
        var changes = 0
        let prepared = await LocateFileAction.prepare(track, at: f.file("Artist/Glass Circuit.m4a"), libraryRoot: f.root.path,
                                                      facts: Self.facts())
        guard case .ready(let plan) = prepared else { Issue.record("\(prepared)"); return }
        #expect(plan.mismatch == nil, "301 s vs 300 s is within ± 2 s")
        let outcome = await LocateFileAction.apply(plan, repository: f.store, undo: f.undo, didChange: { changes += 1 })
        #expect(outcome == .located(relativePath: "Artist/Glass Circuit.m4a"))
        let after = try await f.row(id)
        #expect(after["organized_path"] as String? == "Artist/Glass Circuit.m4a")
        #expect(after["file_missing_since"] as String? == nil)
        #expect(after["download_failure"] as String? == nil && after["download_status"] as String? == nil,
                "a later retry can't overwrite the located path")
        #expect(after["duration"] as Int? == 301 && after["bitrate"] as Int? == 190)
        #expect(try await f.tracks.fetchTrack(id: id)?.availability() == .local)
        #expect(f.manager.undoActionName == "Locate “Glass Circuit”")
        #expect(f.undo.statusBar.message?.text == "Located the file of “Glass Circuit”")

        f.manager.undo()
        await f.undo.waitUntilIdle()
        #expect(try await f.row(id) == before, "Undo restores every column exactly")

        f.manager.redo()
        await f.undo.waitUntilIdle()
        #expect(try await f.row(id) == after)
        #expect(changes == 3, "every step asks the lists to re-read the row")
    }

    @Test func aFileOutsideTheLibraryFolderIsRefusedAndNothingChanges() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: outside.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: outside) }
        let prepared = await LocateFileAction.prepare(track, at: outside, libraryRoot: f.root.path, facts: Self.facts())
        #expect(prepared == .refused(message: "Couldn’t use “\(outside.lastPathComponent)” — the file must be inside the library folder"))
        #expect(!f.manager.canUndo)
    }

    /// Review S7: a file another track uses is refused (removing one track would trash the
    /// other's file) — relative or absolute form, any letter case — and nothing changes.
    @Test func aFileAnotherTrackUsesIsRefused() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let id = try #require(track.id)
        let before = try await f.row(id)
        for stored in ["Artist/Shared.m4a", "artist/shared.M4A", f.root.appendingPathComponent("Artist/Shared.m4a").path] {
            let other = try await f.insert(title: "Other \(stored.count)", organized: stored)
            let prepared = await LocateFileAction.prepare(track, at: f.file("Artist/Shared.m4a"), libraryRoot: f.root.path,
                                                          facts: Self.facts())
            guard case .ready(let plan) = prepared else { Issue.record("\(prepared)"); return }
            let outcome = await LocateFileAction.apply(plan, repository: f.store, undo: f.undo, didChange: {})
            #expect(outcome == .refused(message: "Couldn’t use “Shared.m4a” — it is the file of “\(other.title)”"), "\(stored)")
            #expect(try await f.row(id) == before)
            try await f.db.write { db in try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [other.id]) }
        }
        #expect(!f.manager.canUndo)
    }

    @Test func aDifferentLengthOrFormatAsksFirst() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let url = f.file("Artist/Other Edit.mp3")
        let prepared = await LocateFileAction.prepare(track, at: url, libraryRoot: f.root.path,
                                                      facts: Self.facts(format: "mp3", duration: 192))
        guard case .ready(let plan) = prepared else { Issue.record("\(prepared)"); return }
        #expect(plan.mismatch?.title == "Use “Other Edit.mp3” for “Glass Circuit”?")
        #expect(plan.mismatch?.message.contains("The file is 3:12 long, the track 5:00.") == true)
        #expect(plan.mismatch?.message.contains("The file is MP3, the track was M4A.") == true)
    }

    @Test func aFileThatCantBeReadIsRefused() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let track = try await f.missingTrack()
        let prepared = await LocateFileAction.prepare(track, at: f.file("Artist/notes.m4a"), libraryRoot: f.root.path,
                                                      facts: { _ in nil })
        #expect(prepared == .refused(message: "Couldn’t use “notes.m4a” — the file can’t be read"))
    }

    @Test func insideIsJudgedByIdentityNotBySpelling() {
        let root = "/Volumes/Lexxar/Music"
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/Volumes/Lexxar/Music/A/b.m4a"), libraryRoot: root)
                == .inside(relativePath: "A/b.m4a"))
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/Volumes/Lexxar/Music2/b.m4a"), libraryRoot: root) == .outsideLibraryFolder,
                "a sibling folder with the same prefix is outside")
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/Volumes/Lexxar/Music/../x.m4a"), libraryRoot: root) == .outsideLibraryFolder)
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/tmp/x.m4a"), libraryRoot: nil) == .noLibraryFolder)
        // A case-insensitive volume: `/volumes/lexxar/MUSIC` is the same folder.
        let caseInsensitive: LocateFileRule.Identity = { AnyHashable($0.path.lowercased()) }
        #expect(LocateFileRule.verdict(for: URL(fileURLWithPath: "/volumes/lexxar/MUSIC/A/b.m4a"), libraryRoot: root,
                                       identity: caseInsensitive) == .inside(relativePath: "A/b.m4a"))
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

    @Test func aLocateRequestIsForATrackWithAnID() {
        let request = LocateFileRequest()  // a fresh one, never the app's
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
