import Testing
import Foundation
import GRDB
@testable import MLM

/// A3 Wave 2: launch coordination — resolver decision → validation → registry update →
/// open, plus switching by relaunch (Step-0 decision 1). Temp directories only; opening
/// the container and relaunching are recorded, never performed.
@Suite("LibraryLaunchCoordinator (A3 Wave 2)", .serialized)
@MainActor
struct LibraryLaunchCoordinatorTests {

    private let fixedNow = Date(timeIntervalSince1970: 1_791_115_200)

    @MainActor
    private final class Fixture {
        let root: URL
        let store: LibraryRegistryStore
        let legacyURL: URL
        let adoption: LibraryAdoption
        var opened: [LibraryLocation] = []
        var failures: [String] = []
        var relaunches = 0
        var pendingPath: String?
        var openError: Error?
        /// Runs while the container is "opening" (a suspension point during launch).
        var duringOpen: (@MainActor () async -> Void)?
        var coordinator: LibraryLaunchCoordinator!

        init(now: Date) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LibraryLaunchCoordinatorTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = LibraryRegistryStore(
                fileURL: root.appendingPathComponent("libraries.json"),
                librariesDirectory: root.appendingPathComponent("libraries"))
            legacyURL = root.appendingPathComponent("music_library.db")
            adoption = LibraryAdoption(
                environment: .init(
                    legacyDatabaseURL: legacyURL,
                    registryStore: store,
                    backupsRoot: root.appendingPathComponent("backups"),
                    pathMigrationsDirectory: root.appendingPathComponent("PathMigrations")),
                now: { now })
            coordinator = LibraryLaunchCoordinator(
                store: store,
                adoption: adoption,
                now: { now },
                pendingOpen: .init(
                    take: { [unowned self] in defer { self.pendingPath = nil }; return self.pendingPath },
                    set: { [unowned self] in self.pendingPath = $0 }),
                openLibrary: { [unowned self] location in
                    if let openError = self.openError { throw openError }
                    if let duringOpen = self.duringOpen {
                        self.duringOpen = nil
                        await duringOpen()
                    }
                    self.opened.append(location)
                },
                reportFailure: { [unowned self] in self.failures.append(String(describing: $0)) },
                relaunch: { [unowned self] in self.relaunches += 1 }
            )
        }

        func registry() throws -> LibraryRegistry { try store.load().registry }

        /// A pre-A3 install: loose database with a library id and one track.
        func makeLegacy() throws {
            let manager = try DatabaseManager(path: legacyURL)
            try manager.pool.write { db in
                try db.execute(sql: "INSERT INTO app_config (key, value) VALUES ('library_id', 'legacy-id')")
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path)
                    VALUES (1, 'A', 'A', 'B', 'T', 'mp3', '/tmp/1.mp3')
                    """)
            }
            try manager.pool.close()
        }

        /// File URLs of existing directories carry a trailing slash; the app's don't.
        func canonical(_ url: URL) -> URL {
            URL(filePath: url.standardizedFileURL.path, directoryHint: .notDirectory)
        }

        @discardableResult
        func makePackage(_ name: String, id: String) throws -> URL {
            try LibraryPackage.createEmpty(named: name, libraryId: id, in: store.librariesDirectory, now: Date())
        }

        func register(_ url: URL, id: String, name: String, active: Bool = true, remember: Bool = true) throws {
            var registry = (try? store.load().registry) ?? LibraryRegistry()
            registry.upsert(libraryId: id, url: url, name: name)
            if active { registry.lastActiveLibraryId = id }
            registry.rememberLastLibrary = remember
            try store.save(registry)
        }
    }

    // MARK: - Launch

    @Test func legacyInstallIsOfferedAdoptionAndNothingOpens() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        #expect(f.coordinator.screen == .offerAdoption)
        #expect(f.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.store.fileURL.path))
    }

    @Test func notNowOpensTheLegacyDatabase() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        await f.coordinator.declineAdoption()
        #expect(f.opened == [.legacy(f.legacyURL)])
        #expect(f.coordinator.screen == .opened)
    }

    @Test func adoptionSucceedsThenOpensTheLibraryFileOnDone() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        await f.coordinator.adoptLegacyLibrary(named: "Main Library")

        guard case .succeeded(let result) = f.coordinator.adoptionState else {
            Issue.record("expected succeeded, got \(f.coordinator.adoptionState)")
            return
        }
        #expect(f.opened.isEmpty) // the success message is shown first
        #expect(try f.registry().lastActiveLibraryId == "legacy-id")
        await f.coordinator.finishAdoption()
        #expect(f.opened == [.package(f.canonical(result.packageURL))])
        #expect(f.coordinator.screen == .opened)
    }

    @Test func failedAdoptionKeepsTheLegacyLayout() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        try FileManager.default.createDirectory(at: f.store.librariesDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.store.librariesDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.store.librariesDirectory.path) }

        await f.coordinator.start()
        await f.coordinator.adoptLegacyLibrary(named: "Main Library")
        guard case .failed = f.coordinator.adoptionState else {
            Issue.record("expected failed, got \(f.coordinator.adoptionState)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: f.legacyURL.path))
        #expect(!f.adoption.isInProgress)
        await f.coordinator.declineAdoption()
        #expect(f.opened == [.legacy(f.legacyURL)])
    }

    @Test func interruptedAdoptionPastTheRenameIsFinishedAtLaunch() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .registered)

        await f.coordinator.start()
        let package = f.store.librariesDirectory.appendingPathComponent("Main Library.mlibm")
        #expect(f.opened == [.package(f.canonical(package))])
        #expect(!f.adoption.isInProgress)
        #expect(!FileManager.default.fileExists(atPath: f.legacyURL.path))
    }

    @Test func interruptedAdoptionBeforeTheRenameIsUndoneAndOfferedAgain() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .staged)

        await f.coordinator.start()
        #expect(f.coordinator.screen == .offerAdoption)
        #expect(f.opened.isEmpty)
        #expect(!f.adoption.isInProgress)
        #expect(FileManager.default.fileExists(atPath: f.legacyURL.path))
    }

    @Test func nothingAnywhereAsksForTheFirstLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()
        #expect(f.coordinator.screen == .createFirstLibrary)
        #expect(f.opened.isEmpty)
    }

    @Test func creatingTheFirstLibraryRegistersAndOpensIt() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()
        await f.coordinator.createLibrary(named: "Main Library")

        let package = f.store.librariesDirectory.appendingPathComponent("Main Library.mlibm")
        #expect(f.opened == [.package(f.canonical(package))])
        let registry = try f.registry()
        let entry = try #require(registry.lastActiveEntry)
        #expect(entry.name == "Main Library")
        #expect(entry.url == f.canonical(package))
        #expect(entry.lastOpenedAt == fixedNow)
        #expect(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: package)) == entry.libraryId)
    }

    @Test func lastActiveLibraryIsOpenedAndTimestamped() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(package))])
        #expect(try f.registry().entry(withId: "lib-a")?.lastOpenedAt == fixedNow)
    }

    @Test func missingLastLibraryIsReportedNotOpened() async throws {
        let f = try Fixture(now: fixedNow)
        let gone = f.store.librariesDirectory.appendingPathComponent("Gone.mlibm")
        try f.register(gone, id: "lib-a", name: "Gone")
        await f.coordinator.start()
        guard case .unavailable(let entry, .notFound) = f.coordinator.screen else {
            Issue.record("expected unavailable, got \(f.coordinator.screen)")
            return
        }
        #expect(entry.libraryId == "lib-a")
        #expect(f.opened.isEmpty)
    }

    @Test func rememberOffShowsNoLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library", remember: false)
        await f.coordinator.start()
        #expect(f.coordinator.screen == .noLibrary)
        #expect(f.opened.isEmpty)
    }

    @Test func corruptRegistryIsRebuiltAndTheOnlyLibraryOpens() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try Data("{ broken".utf8).write(to: f.store.fileURL)
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(package))])
    }

    @Test func newerRegistryIsAFailureAndOpensNothing() async throws {
        let f = try Fixture(now: fixedNow)
        try Data(#"{"registry_version": 9, "libraries": [], "remember_last_library": true}"#.utf8)
            .write(to: f.store.fileURL)
        await f.coordinator.start()
        #expect(f.opened.isEmpty)
        #expect(f.failures.count == 1)
    }

    @Test func openFailureIsReported() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        f.openError = CocoaError(.fileReadCorruptFile)
        await f.coordinator.start()
        #expect(f.failures.count == 1)
    }

    // MARK: - Opening a library file

    @Test func openingAnUnregisteredLibraryFileRegistersIt() async throws {
        let f = try Fixture(now: fixedNow)
        let elsewhere = f.root.appendingPathComponent("elsewhere")
        let package = try LibraryPackage.createEmpty(named: "Found", libraryId: "lib-x", in: elsewhere, now: Date())
        await f.coordinator.open(packageAt: package)
        #expect(f.opened == [.package(f.canonical(package))])
        #expect(try f.registry().lastActiveEntry?.libraryId == "lib-x")
    }

    @Test func openingAMovedLibraryFileRepointsItsEntry() async throws {
        let f = try Fixture(now: fixedNow)
        let oldPath = f.root.appendingPathComponent("old/Main Library.mlibm")
        try f.register(oldPath, id: "lib-a", name: "Main Library")
        let moved = try LibraryPackage.createEmpty(
            named: "Main Library", libraryId: "lib-a", in: f.root.appendingPathComponent("disk"), now: Date())
        await f.coordinator.open(packageAt: moved)

        let registry = try f.registry()
        #expect(registry.libraries.count == 1)
        #expect(registry.entry(withId: "lib-a")?.url == f.canonical(moved))
        #expect(f.opened == [.package(f.canonical(moved))])
    }

    @Test func idMismatchIsShownAndNothingChanges() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "real-id")
        try f.register(package, id: "registry-id", name: "Main Library")
        let registryBefore = try Data(contentsOf: f.store.fileURL)

        await f.coordinator.open(packageAt: package)
        #expect(f.coordinator.screen == .mismatch(name: "Main Library", packageURL: f.canonical(package)))
        #expect(f.opened.isEmpty)
        #expect(try Data(contentsOf: f.store.fileURL) == registryBefore)
    }

    @Test func finderCopyIsNotSilentlyRepointed() async throws {
        // A copy whose id is registered at another existing file asks first (decision 12).
        let f = try Fixture(now: fixedNow)
        let original = try f.makePackage("Main Library", id: "lib-a")
        try f.register(original, id: "lib-a", name: "Main Library")
        let copy = f.root.appendingPathComponent("Main Library copy.mlibm")
        try FileManager.default.copyItem(at: original, to: copy)

        await f.coordinator.open(packageAt: copy)
        #expect(f.coordinator.screen == .duplicateCopy(
            name: "Main Library copy", originalName: "Main Library", packageURL: f.canonical(copy)))
        #expect(f.opened.isEmpty)
        #expect(try f.registry().entry(withId: "lib-a")?.url == f.canonical(original))
    }

    @Test func copyOpensAsASeparateLibraryWithANewIdentity() async throws {
        let f = try Fixture(now: fixedNow)
        let original = try f.makePackage("Main Library", id: "lib-a")
        try f.register(original, id: "lib-a", name: "Main Library")
        let copy = f.root.appendingPathComponent("Main Library copy.mlibm")
        try FileManager.default.copyItem(at: original, to: copy)
        await f.coordinator.open(packageAt: copy)

        await f.coordinator.openAsSeparateLibrary(f.canonical(copy))
        let newId = try #require(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: copy)))
        #expect(newId != "lib-a")
        #expect(try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: copy)).libraryId == newId)
        #expect(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: original)) == "lib-a")
        let registry = try f.registry()
        #expect(registry.libraries.count == 2)
        #expect(registry.entry(withId: "lib-a")?.url == f.canonical(original))
        #expect(f.opened == [.package(f.canonical(copy))])
    }

    // MARK: - Opening files (double-click, Open Library…, Open Recent)

    @Test func fileOpenedBeforeLaunchIsTheLaunchLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.handleOpen(b)
        #expect(f.opened.isEmpty)
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(b))])
    }

    @Test func fileOpenedWhileLaunchIsResolvingIsHandledAfterwards() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        let coordinator = f.coordinator!
        f.duringOpen = { await coordinator.handleOpen(b) }
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(a))])
        #expect(f.coordinator.pendingSwitch == .init(url: f.canonical(b), name: "B"))
    }

    @Test func fileOpenedOnALaunchScreenOpensDirectly() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()   // nothing anywhere → first-library screen
        let b = try LibraryPackage.createEmpty(
            named: "B", libraryId: "lib-b", in: f.root.appendingPathComponent("disk"), now: Date())
        await f.coordinator.handleOpen(b)
        #expect(f.opened == [.package(f.canonical(b))])
    }

    @Test func fileOpenedWhileALibraryIsOpenAsksToSwitch() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()

        await f.coordinator.handleOpen(b)
        #expect(f.coordinator.pendingSwitch == .init(url: f.canonical(b), name: "B"))
        #expect(f.relaunches == 0)

        f.coordinator.confirmSwitch()
        #expect(f.relaunches == 1)
        #expect(f.coordinator.pendingSwitch == nil)
        #expect(try f.registry().lastActiveLibraryId == "lib-b")
    }

    @Test func cancellingTheSwitchChangesNothing() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        await f.coordinator.handleOpen(b)
        f.coordinator.cancelSwitch()
        #expect(f.coordinator.pendingSwitch == nil)
        #expect(f.relaunches == 0)
        #expect(try f.registry().lastActiveLibraryId == "lib-a")
    }

    @Test func openingTheOpenLibraryAgainDoesNothing() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        await f.coordinator.handleOpen(a)
        #expect(f.coordinator.pendingSwitch == nil)
        #expect(f.opened.count == 1)
    }

    @Test func switchProblemIsReportedWithoutRelaunch() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        let empty = f.root.appendingPathComponent("Empty.mlibm")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        await f.coordinator.handleOpen(empty)
        f.coordinator.confirmSwitch()
        #expect(f.relaunches == 0)
        #expect(f.coordinator.switchProblem == .invalid(name: "Empty"))
        f.coordinator.dismissProblem()
        #expect(f.coordinator.switchProblem == nil)
        #expect(f.coordinator.screen == .opened)
    }

    @Test func newLibraryWhileOpenIsCreatedThenOfferedAsSwitch() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()

        await f.coordinator.createLibrary(named: "Second")
        let second = f.store.librariesDirectory.appendingPathComponent("Second.mlibm")
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(f.coordinator.pendingSwitch == .init(url: f.canonical(second), name: "Second"))
        #expect(f.opened.count == 1)
    }

    @Test func firstRunAsksForMainLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()
        #expect(f.coordinator.newLibraryRequest?.defaultName == "Main Library")
    }

    @Test func newLibraryFromTheMenuSuggestsNewLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        #expect(f.coordinator.newLibraryRequest == nil)
        f.coordinator.requestNewLibrary()
        #expect(f.coordinator.newLibraryRequest?.defaultName == "New Library")
        f.coordinator.cancelNewLibrary()
        #expect(f.coordinator.newLibraryRequest == nil)
    }

    // MARK: - Settings and menu state

    @Test func rememberLastLibraryIsReadAndWritten() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        #expect(f.coordinator.rememberLastLibrary)
        f.coordinator.setRememberLastLibrary(false)
        #expect(!f.coordinator.rememberLastLibrary)
        #expect(try f.registry().rememberLastLibrary == false)
    }

    @Test func recentLibrariesExcludeTheOpenOneAndCarryTheirState() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        try f.register(b, id: "lib-b", name: "B", active: false)
        try f.register(f.root.appendingPathComponent("Gone.mlibm"), id: "lib-c", name: "Gone", active: false)
        var registry = try f.registry()
        registry.markOpened(libraryId: "lib-c", at: fixedNow.addingTimeInterval(-60))
        registry.markOpened(libraryId: "lib-b", at: fixedNow.addingTimeInterval(-30))
        registry.lastActiveLibraryId = "lib-a"
        try f.store.save(registry)
        await f.coordinator.start()

        let recent = f.coordinator.recentLibraries
        #expect(recent.map(\.entry.libraryId) == ["lib-b", "lib-c"])
        #expect(recent.map(\.availability) == [.available, .notFound])
        #expect(f.coordinator.activeLibraryName == "A")
    }

    @Test func invalidLibraryFileIsReported() async throws {
        let f = try Fixture(now: fixedNow)
        let empty = f.root.appendingPathComponent("Empty.mlibm")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await f.coordinator.open(packageAt: empty)
        #expect(f.coordinator.screen == .invalid(name: "Empty"))
        #expect(f.opened.isEmpty)
    }

    @Test func databaseWithoutLibraryIdGetsOneOnOpen() async throws {
        let f = try Fixture(now: fixedNow)
        let package = f.root.appendingPathComponent("Manual.mlibm")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        _ = try DatabaseManager(path: LibraryPackage.databaseURL(in: package))

        await f.coordinator.open(packageAt: package)
        let id = try #require(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: package)))
        #expect(UUID(uuidString: id) != nil)
        #expect(try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package)).libraryId == id)
        #expect(try f.registry().entry(withId: id) != nil)
        #expect(f.opened == [.package(f.canonical(package))])
    }

    // MARK: - Switching

    @Test func switchingWritesRegistryAndRelaunchesIntoTheTarget() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        try f.register(b, id: "lib-b", name: "B", active: false)

        let outcome = f.coordinator.switchLibrary(to: b)
        #expect(outcome == .relaunching)
        #expect(f.relaunches == 1)
        #expect(try f.registry().lastActiveLibraryId == "lib-b")
        #expect(f.pendingPath == f.canonical(b).path)

        // The relaunched process opens the target even with "remember" off.
        var registry = try f.registry()
        registry.rememberLastLibrary = false
        try f.store.save(registry)
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(b))])
        #expect(f.pendingPath == nil)
    }

    @Test func switchingToAnUnusableFileNeverRelaunches() async throws {
        let f = try Fixture(now: fixedNow)
        let empty = f.root.appendingPathComponent("Empty.mlibm")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let outcome = f.coordinator.switchLibrary(to: empty)
        #expect(outcome == .failed(.invalid(name: "Empty")))
        #expect(f.relaunches == 0)
        #expect(f.pendingPath == nil)
    }
}
