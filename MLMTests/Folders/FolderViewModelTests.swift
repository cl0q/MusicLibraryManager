import Foundation
import GRDB
import Testing
@testable import MLM

/// The Folders model against a temporary library folder and an in-memory database (W3-FOLD):
/// counts from SQL, lazily read folders, files not in the library, the filter, the root, the
/// drive going away, reveal (⌘L), errors that say so, a folder as its tracks.
@Suite("Folders model (W3-FOLD)", .serialized)
@MainActor
struct FolderViewModelTests {
    final class Box: @unchecked Sendable {
        var offline = false
        var listCalls: [String] = []
        var walks = 0
        let lock = NSLock()
    }

    struct Fixture {
        let model: FolderViewModel
        let database: DatabaseQueue
        let root: URL
        let box: Box
        let defaults: UserDefaults
        let suite: String

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// A library folder on disk:
    /// `2026/Jam/a.flac` (library) · `2026/new.wav` (not in library) · `Sets/b.flac` (library)
    /// · `loose.mp3` (library, root level) · `_Inbox/` (no library tracks) · track 4 not downloaded.
    private func makeFixture(libraryRoot: Bool = true, createDisk: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlm_folders_vm_\(UUID().uuidString)")
            .standardizedFileURL
        if createDisk {
            for folder in ["2026/Jam", "Sets", "_Inbox"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for file in ["2026/Jam/a.flac", "2026/new.wav", "Sets/b.flac", "loose.mp3", "_Inbox/x.mp3"] {
                FileManager.default.createFile(atPath: root.appendingPathComponent(file).path, contents: Data([1]))
            }
        }
        let database = try DatabaseManager.inMemory()
        let repository = TrackRepository(database: database)
        func add(_ title: String, artist: String, organized: String?, original: String) async throws {
            var track = Track(artist: artist, album: "Album", title: title, format: "flac", originalPath: original)
            track.organizedPath = organized
            track.duration = 120
            try await repository.insert(track)
        }
        // Imported where it lies (organised suggestion differs) / a download / a root file.
        try await add("Alpha", artist: "Aphex Twin", organized: "Aphex Twin/Album/Alpha.flac", original: root.appendingPathComponent("2026/Jam/a.flac").path)
        try await add("Beta", artist: "Burial", organized: "Sets/b.flac", original: "soundcloud://2")
        try await add("Loose", artist: "Four Tet", organized: "loose.mp3", original: "youtube://3")
        try await add("Remote", artist: "Skee Mask", organized: nil, original: "soundcloud://4")

        let suite = "mlm.tests.folders.vm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let box = Box()
        let rootPath = root.path
        var environment = FolderViewModel.Environment(
            queries: { FolderQueries(database: database) },
            libraryRoot: { libraryRoot ? rootPath : nil },
            libraryID: { "lib" },
            isDriveOffline: { box.offline },
            defaults: defaults
        )
        environment.listDirectory = { url in
            box.lock.lock(); box.listCalls.append(url.path); box.lock.unlock()
            return FolderDiskReader.list(url)
        }
        environment.walkDirectory = { url in
            box.lock.lock(); box.walks += 1; box.lock.unlock()
            return FolderDiskReader.walk(url, isCancelled: { false })
        }
        return Fixture(model: FolderViewModel(environment: environment), database: database, root: root, box: box,
                       defaults: defaults, suite: suite)
    }

    /// Waits (bounded) for `condition`; fails the test on timeout.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func names(_ rows: [FolderOutlineRow]) -> [String] {
        rows.map { $0.folder?.name ?? $0.track?.title ?? $0.file?.name ?? "…" }
    }

    // MARK: Load

    @Test func noLibraryFolderIsSaid() async throws {
        let fixture = try await makeFixture(libraryRoot: false)
        defer { fixture.cleanUp() }
        await fixture.model.load()
        #expect(fixture.model.phase == .noLibraryFolder)
    }

    @Test func theOutlineShowsFoldersWithSQLCountsAndRootFiles() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        #expect(model.phase == .ready)
        await waitUntil("root track rows") { model.outline.trackRows.count == 1 }
        // Folders (database and disk) by name, then the root-level track (reachable now).
        #expect(names(model.outline.rows) == ["_Inbox", "2026", "Sets", "Loose"])
        let year = try #require(model.outline.rows.first { $0.folder?.name == "2026" }?.folder)
        #expect(year.trackCount == 1, "Alpha lies in 2026/Jam where its file is")
        #expect(model.rootTrackCount == 3)
        #expect(model.statusText == "4 folders · 3 tracks")
    }

    @Test func notInLibraryFilesAreCountedOnceTheFolderWasRead() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        await waitUntil("the walk") { model.isWalkComplete }
        #expect(Set(model.notInLibraryFiles(under: "") ?? []) == ["_Inbox/x.mp3", "2026/new.wav"])
        #expect(model.notInLibraryFiles(under: "2026") == ["2026/new.wav"])
        let year = try #require(model.outline.rows.first { $0.folder?.name == "2026" }?.folder)
        #expect(year.notInLibraryCount == 1)
    }

    @Test func openingAFolderReadsItAndLoadsItsTracksAndIsRemembered() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        await waitUntil("the walk") { model.isWalkComplete }
        model.setExpanded("2026", true)
        model.setExpanded("2026/Jam", true)
        await waitUntil("Alpha") { model.outline.trackRows.contains { $0.title == "Alpha" } }
        let year = try #require(model.outline.rows.first { $0.folder?.name == "2026" })
        #expect(names(year.children ?? []) == ["Jam", "new.wav"])
        #expect(year.children?.last?.file != nil, "the file that isn't in the library, inline")
        // Remembered per library.
        let stored = FolderUIState.load(libraryID: "lib", libraryRoot: fixture.root.path, defaults: fixture.defaults)
        #expect(stored.expanded == ["2026", "2026/Jam"])
    }

    @Test func aLibraryFolderThatCantBeReadIsAnErrorNotAnEmptyFolder() async throws {
        let fixture = try await makeFixture(createDisk: false)
        defer { fixture.cleanUp() }
        await fixture.model.load()
        guard case .failed(.libraryFolderUnreadable, _) = fixture.model.phase else {
            Issue.record("expected the unreadable-folder error, got \(fixture.model.phase)")
            return
        }
    }

    @Test func withTheDriveAwayTheDatabaseRowsStayAndNothingIsRead() async throws {
        let fixture = try await makeFixture(createDisk: false)
        defer { fixture.cleanUp() }
        fixture.box.offline = true
        let model = fixture.model
        await model.load()
        #expect(model.phase == .ready, "offline is normal (P6)")
        #expect(names(model.outline.rows).prefix(2) == ["2026", "Sets"])
        #expect(model.notInLibraryFiles(under: "") == nil, "unknown while the drive is away")
        model.setExpanded("Sets", true)
        await waitUntil("Beta") { model.outline.trackRows.contains { $0.title == "Beta" } }
        #expect(fixture.box.listCalls.isEmpty && fixture.box.walks == 0, "never a disk access for a drive that isn't there")
    }

    // MARK: Root, reveal

    @Test func openAsRootGoUpAndJump() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        model.openAsRoot("2026")
        #expect(model.root == "2026" && model.rootName == "2026")
        #expect(names(model.outline.rows).first == "Jam")
        #expect(model.pathSegments.map(\.name) == [fixture.root.lastPathComponent, "2026"])
        #expect(model.goUp())
        #expect(model.root == "")
        #expect(model.trackList.selection == [model.ids.folder("2026")], "the folder that was the root is selected")
        #expect(!model.goUp(), "nothing above the library folder")
        model.openAsRoot("Sets")
        model.jump(to: "")
        #expect(model.root == "" && model.trackList.selection.isEmpty)
    }

    @Test func revealOpensTheFoldersAboveATrackAndSelectsIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        model.openAsRoot("Sets")
        let alpha = try #require(try await fixture.database.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'Alpha'") })
        #expect(model.reveal(trackID: alpha))
        #expect(model.root == "", "outside the root: back to the library folder")
        #expect(model.isExpanded("2026") && model.isExpanded("2026/Jam"))
        await waitUntil("the revealed row") { model.trackList.row(id: alpha) != nil }
        #expect(model.trackList.selection == [alpha])
        let remote = try #require(try await fixture.database.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'Remote'") })
        #expect(!model.reveal(trackID: remote), "a track without a file isn't in a folder")
    }

    // MARK: Filter

    @Test func theFilterFindsTracksAndFoldersByName() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        await waitUntil("the walk") { model.isWalkComplete }
        let byTrack = await model.computeMatch(SearchFilter(text: "burial"))
        #expect(byTrack.trackIDs.count == 1 && byTrack.nameMatchedFolders.isEmpty)
        let byName = await model.computeMatch(SearchFilter(text: "inbox"))
        #expect(byName.nameMatchedFolders == ["_Inbox"])
        let byFile = await model.computeMatch(SearchFilter(text: "new"))
        #expect(byFile.nameMatchedFiles == ["2026/new.wav"])
        let byToken = await model.computeMatch(SearchFilter(tokens: [.artist("Aphex Twin")]))
        #expect(byToken.trackIDs.count == 1 && byToken.nameMatchedFolders.isEmpty, "tokens describe tracks")

        model.applyFilter(SearchFilter(text: "burial"))
        await waitUntil("the filtered outline") { model.filterMatch != nil }
        #expect(model.outline.rows.compactMap(\.folder).map(\.name) == ["Sets"])
        #expect(model.filterSummary == "0 folders and 1 track match “burial”")
        model.applyFilter(SearchFilter(text: "zzzz"))
        await waitUntil("the empty filter") { model.isFilteredEmpty }
        model.applyFilter(SearchFilter())
        #expect(model.filterMatch == nil && !model.isFilteredEmpty)
    }

    // MARK: A folder as its tracks; deletions

    @Test func aFolderStandsForItsTracksInDisplayOrder() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        let tracks = await model.tracks(forRows: [model.ids.folder("2026"), model.ids.folder("Sets")])
        #expect(tracks.map(\.title) == ["Alpha", "Beta"])
        let loader = FolderTrackLoader(queries: FolderQueries(database: fixture.database), libraryRoot: fixture.root.path)
        let all = await loader.tracks(in: [""], sort: TrackSortOrder(column: .title, ascending: true))
        #expect(all.map(\.title) == ["Alpha", "Beta", "Loose"], "subfolders first, then the root's own tracks")
    }

    @Test func deletedTracksLeaveTheOutlineInPlace() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        await waitUntil("root rows") { model.outline.trackRows.count == 1 }
        let loose = try #require(model.outline.trackRows.first?.id)
        model.trackList.selection = [loose]
        _ = try await fixture.database.write { db in try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [loose]) }
        model.removeTracks(ids: [loose])
        #expect(model.outline.trackRows.isEmpty)
        #expect(model.trackList.selection.isEmpty)
        await waitUntil("the catalog") { model.rootTrackCount == 2 }
    }

    @Test func aSelectedFolderStandsForItsTracksInTheTrackMenu() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        model.trackList.selection = [model.ids.folder("Sets")]
        model.selectionDidChange()
        await waitUntil("the folder's tracks") { model.folderSelectionTracks != nil }
        #expect(model.folderSelectionTracks?.tracks.map(\.title) == ["Beta"])
        model.trackList.selection = []
        model.selectionDidChange()
        #expect(model.folderSelectionTracks == nil)
    }

    @Test func newFilesUpdateTheOutlineInPlace() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.load()
        await waitUntil("the walk") { model.isWalkComplete }
        #expect(model.catalog.trackCount(under: "_Inbox") == 0)
        var track = Track(artist: "New", album: "Album", title: "Inbox Track", format: "mp3",
                          originalPath: fixture.root.appendingPathComponent("_Inbox/x.mp3").path)
        track.organizedPath = "New/Album/Inbox Track.mp3"
        try await TrackRepository(database: fixture.database).insert(track)
        model.libraryFilesDidChange()
        model.libraryFilesDidChange()
        await waitUntil("the refreshed catalog") { model.catalog.trackCount(under: "_Inbox") == 1 }
        // The first walk's `isWalkComplete` is still true while the catalog refreshes, so wait for the second walk itself.
        await waitUntil("the new walk") {
            fixture.box.lock.lock(); defer { fixture.box.lock.unlock() }
            return fixture.box.walks >= 2 && model.isWalkComplete && model.notInLibraryFiles(under: "_Inbox")?.isEmpty == true
        }
        #expect(fixture.box.walks >= 2, "read again after the change")
    }
}
