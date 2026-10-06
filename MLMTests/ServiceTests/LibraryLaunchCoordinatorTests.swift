import Testing
import Foundation
import GRDB
@testable import MLM

/// Launch coordination — resolver decision → validation → registry update → open, switching
/// by relaunch (Step-0 decision 1) — and the W3-LAUNCH states around it: picker rows, loading
/// phases, failure states, the setup, adoption with `Not Now` back to the picker, remove from
/// list with undo, locate, restore options. Temp directories only (registry, libraries,
/// backups and the "legacy" database all live under one temporary root); opening the
/// container and relaunching are recorded, never performed.
@Suite("LibraryLaunchCoordinator (A3, W3-LAUNCH)", .serialized)
@MainActor
struct LibraryLaunchCoordinatorTests {

    private let fixedNow = Date(timeIntervalSince1970: 1_791_115_200)

    @MainActor
    private final class Fixture {
        let root: URL
        let store: LibraryRegistryStore
        let legacyURL: URL
        let backupsRoot: URL
        let adoption: LibraryAdoption
        var opened: [LibraryLocation] = []
        var failures: [String] = []
        var relaunches = 0
        var pendingPath: String?
        var openError: Error?
        /// Phases the fake open reports before it finishes (or throws).
        var phasesDuringOpen: [LibraryOpenPhase] = []
        var needsSetup = false
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
            backupsRoot = root.appendingPathComponent("backups")
            adoption = LibraryAdoption(
                environment: .init(
                    legacyDatabaseURL: legacyURL,
                    registryStore: store,
                    backupsRoot: backupsRoot,
                    pathMigrationsDirectory: root.appendingPathComponent("PathMigrations")),
                now: { now })
            coordinator = LibraryLaunchCoordinator(
                store: store,
                adoption: adoption,
                now: { now },
                pendingOpen: .init(
                    take: { [unowned self] in defer { self.pendingPath = nil }; return self.pendingPath },
                    set: { [unowned self] in self.pendingPath = $0 }),
                openLibrary: { [unowned self] location, progress in
                    for phase in await self.phasesDuringOpen { progress(phase) }
                    if let openError = await self.openError { throw openError }
                    if let duringOpen = await self.takeDuringOpen() { await duringOpen() }
                    await self.record(location)
                },
                reportFailure: { [unowned self] in self.failures.append(String(describing: $0)) },
                relaunch: { [unowned self] in self.relaunches += 1 },
                needsSetup: { [unowned self] in await self.needsSetup },
                setupServices: .init(makeImporter: { nil }, activity: nil)
            )
        }

        func takeDuringOpen() -> (@MainActor () async -> Void)? {
            defer { duringOpen = nil }
            return duringOpen
        }

        func record(_ location: LibraryLocation) { opened.append(location) }

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

        func row(_ id: String) -> LibraryPickerRow? { coordinator.pickerRows.first { $0.id == id } }
    }

    // MARK: - Adoption at launch (A0 D7, ROADMAP A3 note 13)

    @Test func legacyInstallIsOfferedAdoptionOverThePickerAndNothingOpens() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.adoptionOffer)
        #expect(f.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.store.fileURL.path))
    }

    @Test func notNowReturnsToThePickerWithTheOldInstallListed() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        await f.coordinator.declineAdoption()
        #expect(f.opened.isEmpty, "Not Now never opens anything by itself")
        #expect(f.coordinator.screen == .picker)
        #expect(!f.coordinator.adoptionOffer)
        let legacy = try #require(f.row("legacy"))
        #expect(legacy.listedName == "Main Library (needs setup)")
        #expect(legacy.state == .needsSetup)
        #expect(legacy.canOpen)

        // Opening that row opens the old database exactly as `Not Now` used to.
        await f.coordinator.openRow(legacy)
        #expect(f.opened == [.legacy(f.legacyURL)])
        #expect(f.coordinator.screen == .opened)
        #expect(FileManager.default.fileExists(atPath: f.legacyURL.path))
    }

    @Test func notNowWithOtherLibrariesNeverOpensTheOldInstall() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        let other = try f.makePackage("Laptop Subset", id: "lib-a")
        try f.register(other, id: "lib-a", name: "Laptop Subset")
        await f.coordinator.start()
        #expect(f.coordinator.adoptionOffer)
        await f.coordinator.declineAdoption()
        #expect(f.opened.isEmpty)
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.pickerRows.map(\.id) == ["lib-a", "legacy"])
    }

    @Test func setUpOnTheOldInstallsRowOffersTheSheetAgain() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        await f.coordinator.declineAdoption()
        f.coordinator.offerAdoption()
        #expect(f.coordinator.adoptionOffer)
        #expect(f.coordinator.adoptionState == .idle)
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
        #expect(!f.coordinator.adoptionOffer)
    }

    @Test func failedAdoptionKeepsTheLegacyLayoutAndNotNowStaysOnThePicker() async throws {
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
        #expect(f.opened.isEmpty)
        #expect(f.coordinator.screen == .picker)
    }

    @Test func libraryFileOpenedDuringTheAdoptionSheetIsQueuedNotDropped() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        let b = try LibraryPackage.createEmpty(
            named: "B", libraryId: "lib-b", in: f.root.appendingPathComponent("disk"), now: Date())
        await f.coordinator.start()
        await f.coordinator.handleOpen(b)
        #expect(f.opened.isEmpty)
        await f.coordinator.declineAdoption()
        #expect(f.opened == [.package(f.canonical(b))])
    }

    @Test func interruptedAdoptionPastTheRenameIsFinishedAtLaunchWithItsPhase() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .registered)

        await f.coordinator.start()
        let package = f.store.librariesDirectory.appendingPathComponent("Main Library.mlibm")
        #expect(f.opened == [.package(f.canonical(package))])
        #expect(f.coordinator.openPhases.first == .finishingSetup)
        #expect(!f.adoption.isInProgress)
        #expect(!FileManager.default.fileExists(atPath: f.legacyURL.path))
    }

    @Test func interruptedAdoptionBeforeTheRenameIsUndoneAndOfferedAgain() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .staged)

        await f.coordinator.start()
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.adoptionOffer)
        #expect(f.opened.isEmpty)
        #expect(!f.adoption.isInProgress)
        #expect(FileManager.default.fileExists(atPath: f.legacyURL.path))
    }

    // MARK: - First run and setup (V-SETUP)

    @Test func nothingAnywhereStartsTheInWindowSetup() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()
        #expect(f.coordinator.screen == .firstRunSetup)
        #expect(f.coordinator.newLibraryRequest == nil, "no sheet on the first run")
        #expect(f.opened.isEmpty)
    }

    @Test func creatingTheFirstLibraryRegistersOpensAndContinuesWithTheFolder() async throws {
        let f = try Fixture(now: fixedNow)
        f.needsSetup = true
        await f.coordinator.start()
        let error = await f.coordinator.createLibrary(named: "Main Library")
        #expect(error == nil)

        let package = f.store.librariesDirectory.appendingPathComponent("Main Library.mlibm")
        #expect(f.opened == [.package(f.canonical(package))])
        let registry = try f.registry()
        let entry = try #require(registry.lastActiveEntry)
        #expect(entry.name == "Main Library")
        #expect(entry.url == f.canonical(package))
        #expect(entry.lastOpenedAt == fixedNow)
        #expect(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: package)) == entry.libraryId)
        #expect(f.coordinator.setup?.libraryName == "Main Library")
        #expect(f.coordinator.setup?.stage == .folder)
        f.coordinator.endSetup()
        #expect(f.coordinator.setup == nil)
    }

    @Test func aLibraryThatDoesntNeedSetupOpensStraightIntoTheShell() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        await f.coordinator.start()
        #expect(f.coordinator.setup == nil)
    }

    @Test func createInAChosenLocation() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()
        let elsewhere = f.root.appendingPathComponent("External")
        #expect(await f.coordinator.createLibrary(named: "Archive", in: elsewhere) == nil)
        #expect(f.opened == [.package(f.canonical(elsewhere.appendingPathComponent("Archive.mlibm")))])
    }

    @Test func newLibraryNameTakenAndUnwritableLocationAreSaidBeforeCreating() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makePackage("Main Library", id: "lib-a")
        #expect(f.coordinator.newLibraryProblem(named: "Main Library") == .nameTaken("Main Library"))
        #expect(f.coordinator.newLibraryProblem(named: "  ") == .emptyName)
        #expect(f.coordinator.newLibraryProblem(named: "Other") == nil)

        let locked = f.root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(f.coordinator.newLibraryProblem(named: "Other", in: locked) == .notWritable(folder: "locked"))
        let before = try FileManager.default.contentsOfDirectory(atPath: f.store.librariesDirectory.path)
        #expect(await f.coordinator.createLibrary(named: "Main Library") == .nameTaken("Main Library"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.librariesDirectory.path) == before)
        #expect(NewLibraryError.nameTaken("New Library").message
                == "A library named “New Library” already exists there. Choose another name.")
    }

    // MARK: - Launch

    @Test func lastActiveLibraryIsOpenedAndTimestamped() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(package))])
        #expect(try f.registry().entry(withId: "lib-a")?.lastOpenedAt == fixedNow)
        #expect(f.coordinator.activeLibraryName == "Main Library")
    }

    @Test func missingLastLibraryIsAPickerRowNotAScreen() async throws {
        let f = try Fixture(now: fixedNow)
        let gone = f.store.librariesDirectory.appendingPathComponent("Gone.mlibm")
        try f.register(gone, id: "lib-a", name: "Gone")
        await f.coordinator.start()
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.pickerFocus?.name == "Gone")
        let row = try #require(f.row("lib-a"))
        #expect(row.state == .notFound)
        #expect(row.stateText == "Not found")
        #expect(row.openRefusal == "Can’t open — not found")
        #expect(f.opened.isEmpty)
    }

    @Test func notConnectedRowNamesTheDiskAndTryAgainSaysItWasChecked() async throws {
        let f = try Fixture(now: fixedNow)
        let volume = "MLMTestNoSuchVolume-\(UUID().uuidString.prefix(8))"
        let away = URL(fileURLWithPath: "/Volumes/\(volume)/Archive 2019.mlibm")
        try f.register(away, id: "lib-a", name: "Archive 2019")
        await f.coordinator.start()
        let row = try #require(f.row("lib-a"))
        #expect(row.state == .notConnected(volume: volume))
        #expect(row.stateText == "Not connected — on “\(volume)”")
        await f.coordinator.tryAgain(row)
        #expect(f.coordinator.rowNotes["lib-a"] == "Checked just now — “\(volume)” is still not connected.")
        #expect(f.opened.isEmpty)
    }

    @Test func rememberOffShowsThePicker() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library", remember: false)
        await f.coordinator.start()
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.pickerFocus == nil)
        #expect(f.coordinator.pickerRows.map(\.id) == ["lib-a"])
        #expect(f.opened.isEmpty)
    }

    @Test func corruptRegistryIsRebuiltAndTheOnlyLibraryOpens() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try Data("{ broken".utf8).write(to: f.store.fileURL)
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(package))])
    }

    @Test func newerRegistryIsAFailureWithItsOwnWords() async throws {
        let f = try Fixture(now: fixedNow)
        try Data(#"{"registry_version": 9, "libraries": [], "remember_last_library": true}"#.utf8)
            .write(to: f.store.fileURL)
        await f.coordinator.start()
        #expect(f.opened.isEmpty)
        #expect(f.failures.count == 1)
        guard case .failed(let failure) = f.coordinator.screen else {
            Issue.record("expected failed, got \(f.coordinator.screen)")
            return
        }
        #expect(failure.cause == .libraryList(newerVersion: true))
        #expect(!failure.offersChooseAnother)
        #expect(!failure.mayOfferRestore)
    }

    // MARK: - Loading phases and failures (V-LAUNCH-LOADING / -FAILED)

    @Test func openingReportsItsPhasesInOrder() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        f.phasesDuringOpen = [.backingUp(bytes: 1_000), .updating(step: 1, total: 2), .updating(step: 2, total: 2)]
        await f.coordinator.start()
        #expect(f.coordinator.openPhases == [
            .checking, .reading, .backingUp(bytes: 1_000), .updating(step: 1, total: 2), .updating(step: 2, total: 2),
        ])
        #expect(f.coordinator.screen == .opened, "late phases never pull an opened library back to loading")
    }

    @Test func aReadFailureIsTheFailedStateNotARawError() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        f.openError = CocoaError(.fileReadCorruptFile)
        await f.coordinator.start()
        #expect(f.failures.count == 1)
        guard case .failed(let failure) = f.coordinator.screen else {
            Issue.record("expected failed, got \(f.coordinator.screen)")
            return
        }
        #expect(failure.name == "Main Library")
        #expect(failure.cause == .unreadable)
        #expect(failure.title == "“Main Library” couldn’t be opened")
        #expect(failure.message == "The library database couldn’t be read. Your music files are not affected, and MLM didn’t change the library file.")
        #expect(failure.details.contains("music_library.db"))
        #expect(failure.location == .package(f.canonical(package)))
        #expect(failure.offersChooseAnother && failure.mayOfferRestore)
    }

    @Test func theFailurePhaseDecidesWhatIsSafeToSay() async throws {
        for (phases, cause) in [
            ([LibraryOpenPhase.backingUp(bytes: nil)], LaunchFailure.Cause.backupBeforeUpdate),
            ([.backingUp(bytes: nil), .updating(step: 2, total: 3)], .update),
        ] {
            let f = try Fixture(now: fixedNow)
            let package = try f.makePackage("Main Library", id: "lib-a")
            try f.register(package, id: "lib-a", name: "Main Library")
            f.phasesDuringOpen = phases
            f.openError = CocoaError(.fileWriteUnknown)
            await f.coordinator.start()
            guard case .failed(let failure) = f.coordinator.screen else {
                Issue.record("expected failed, got \(f.coordinator.screen)")
                continue
            }
            #expect(failure.cause == cause)
        }
    }

    @Test func tryAgainAfterAFailureOpensTheSameLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        f.openError = CocoaError(.fileReadCorruptFile)
        await f.coordinator.start()
        f.openError = nil
        await f.coordinator.retryFailedOpen()
        #expect(f.opened == [.package(f.canonical(package))])
        #expect(f.coordinator.screen == .opened)
    }

    @Test func chooseAnotherLibraryLeadsToThePicker() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        f.openError = CocoaError(.fileReadCorruptFile)
        await f.coordinator.start()
        f.coordinator.chooseAnotherLibrary()
        #expect(f.coordinator.screen == .picker)
    }

    // MARK: - Restore at launch (S-LAUNCH-RESTORE)

    @Test func restoreIsOfferedOnlyWithThisLibrarysBackups() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        f.openError = CocoaError(.fileReadCorruptFile)
        await f.coordinator.start()

        // No backups yet: nothing to offer.
        await f.coordinator.loadRestoreOptions()
        #expect(f.coordinator.restore == nil)

        // One backup of this library (written into the temporary backups root).
        let queue = try DatabaseQueue(path: LibraryPackage.databaseURL(in: package).path)
        _ = try BackupService.createBundle(
            database: queue, databasePath: LibraryPackage.databaseURL(in: package), coversDirectory: nil,
            reason: .manual, backupsRoot: f.backupsRoot)
        try queue.close()

        await f.coordinator.loadRestoreOptions()
        let restore = try #require(f.coordinator.restore)
        #expect(restore.restorable.count == 1)
        #expect(restore.libraryName == "Main Library")
        #expect(restore.detailText(restore.restorable[0]).hasPrefix("Manual"))
        f.coordinator.chooseAnotherLibrary()
        #expect(f.coordinator.restore == nil, "the database is released when the screen moves on")
    }

    @Test func restoreIsNotOfferedForADatabaseOfAnotherLibrary() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "lib-a")
        try f.register(package, id: "lib-a", name: "Main Library")
        let queue = try DatabaseQueue(path: LibraryPackage.databaseURL(in: package).path)
        _ = try BackupService.createBundle(
            database: queue, databasePath: LibraryPackage.databaseURL(in: package), coversDirectory: nil,
            reason: .manual, backupsRoot: f.backupsRoot)
        // The database now claims another identity (as after replacing files inside the package).
        try await queue.write { db in try db.execute(sql: "UPDATE app_config SET value = 'other' WHERE key = 'library_id'") }
        try queue.close()
        let model = await LaunchRestoreModel.make(
            databaseURL: LibraryPackage.databaseURL(in: package), expectedLibraryId: "lib-a",
            libraryName: "Main Library", backupsRoot: f.backupsRoot, relaunch: {})
        #expect(model == nil)
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

    @Test func idMismatchIsAPickerRowAndNothingChanges() async throws {
        let f = try Fixture(now: fixedNow)
        let package = try f.makePackage("Main Library", id: "real-id")
        try f.register(package, id: "registry-id", name: "Main Library")
        let registryBefore = try Data(contentsOf: f.store.fileURL)

        await f.coordinator.open(packageAt: package)
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.pickerFocus == .init(name: "Main Library", url: f.canonical(package)))
        guard case .mismatch(let details)? = f.row("registry-id")?.state else {
            Issue.record("expected a mismatch row, got \(f.coordinator.pickerRows)")
            return
        }
        #expect(details.contains("registry-id") && details.contains("real-id"))
        #expect(f.opened.isEmpty)
        #expect(try Data(contentsOf: f.store.fileURL) == registryBefore)
    }

    @Test func finderCopyAsksOverThePickerAndIsNotSilentlyRepointed() async throws {
        let f = try Fixture(now: fixedNow)
        let original = try f.makePackage("Main Library", id: "lib-a")
        try f.register(original, id: "lib-a", name: "Main Library")
        let copy = f.root.appendingPathComponent("Main Library copy.mlibm")
        try FileManager.default.copyItem(at: original, to: copy)

        await f.coordinator.open(packageAt: copy)
        #expect(f.coordinator.screen == .picker)
        #expect(f.coordinator.switchProblem == .duplicateCopy(
            name: "Main Library copy", originalName: "Main Library", url: f.canonical(copy)))
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

    @Test func copyWithALibraryOpenContinuesToTheSwitchConfirmation() async throws {
        let f = try Fixture(now: fixedNow)
        let original = try f.makePackage("Main Library", id: "lib-a")
        try f.register(original, id: "lib-a", name: "Main Library")
        await f.coordinator.start()
        let copy = f.root.appendingPathComponent("Main Library copy.mlibm")
        try FileManager.default.copyItem(at: original, to: copy)

        await f.coordinator.handleOpen(copy)
        f.coordinator.confirmSwitch()
        #expect(f.relaunches == 0)
        #expect(f.coordinator.switchProblem == .duplicateCopy(
            name: "Main Library copy", originalName: "Main Library", url: f.canonical(copy)))
        await f.coordinator.openAsSeparateLibrary(f.canonical(copy))
        #expect(f.relaunches == 0, "today it relaunched without asking")
        #expect(f.coordinator.pendingSwitch?.url == f.canonical(copy))
    }

    @Test func invalidCausesHaveTheirOwnWords() async throws {
        let f = try Fixture(now: fixedNow)
        let empty = f.root.appendingPathComponent("Empty.mlibm")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await f.coordinator.open(packageAt: empty)
        guard case .invalid(let file) = f.coordinator.screen else {
            Issue.record("expected invalid, got \(f.coordinator.screen)")
            return
        }
        #expect(file.cause == .noDatabase)
        #expect(file.title == "“Empty.mlibm” isn’t a valid library file")
        #expect(file.message == "It doesn’t contain a library database. The file may be incomplete or damaged. MLM didn’t change it.")
        #expect(f.opened.isEmpty)
        #expect(try f.registry().libraries.isEmpty, "never added to the list")

        let newer = try f.makePackage("Newer", id: "lib-n")
        try Data(#"{"manifest_version": 9, "library_id": "lib-n", "name": "Newer", "created_at": "2026-10-04T12:00:00Z"}"#.utf8)
            .write(to: LibraryPackage.manifestURL(in: newer))
        await f.coordinator.open(packageAt: newer)
        guard case .invalid(let newerFile) = f.coordinator.screen else {
            Issue.record("expected invalid, got \(f.coordinator.screen)")
            return
        }
        #expect(newerFile.cause == .newerVersion)
        #expect(newerFile.message == "It was made by a newer version of MLM. Update MLM to open it. MLM didn’t change the file.")
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

    // MARK: - Picker actions

    @Test func removeFromListTouchesOnlyTheListAndIsUndoable() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A", remember: false)
        try f.register(b, id: "lib-b", name: "B", remember: false)
        await f.coordinator.start()
        let before = try f.registry()

        let row = try #require(f.row("lib-b"))
        #expect(f.coordinator.removeFromList(row))
        #expect(try f.registry().entry(withId: "lib-b") == nil)
        #expect(try f.registry().lastActiveLibraryId == nil)
        #expect(FileManager.default.fileExists(atPath: LibraryPackage.databaseURL(in: b).path), "the file stays")
        #expect(f.coordinator.removalMessage == "Removed “B” from the list — the library file is unchanged.")
        #expect(f.coordinator.pickerRows.map(\.id) == ["lib-a"])

        f.coordinator.undoRemoval()
        #expect(try f.registry() == before)
        #expect(f.coordinator.removalMessage == nil)
        #expect(Set(f.coordinator.pickerRows.map(\.id)) == ["lib-a", "lib-b"])
    }

    @Test func theOldInstallCantBeRemovedFromTheList() async throws {
        let f = try Fixture(now: fixedNow)
        try f.makeLegacy()
        await f.coordinator.start()
        let legacy = try #require(f.row("legacy"))
        #expect(!f.coordinator.removeFromList(legacy))
        #expect(FileManager.default.fileExists(atPath: f.legacyURL.path))
    }

    @Test func locateRepointsTheSameLibraryAndRefusesAnother() async throws {
        let f = try Fixture(now: fixedNow)
        let oldPath = f.root.appendingPathComponent("old/Main Library.mlibm")
        try f.register(oldPath, id: "lib-a", name: "Main Library")
        await f.coordinator.start()
        let row = try #require(f.row("lib-a"))
        #expect(row.state == .notFound)

        let stranger = try LibraryPackage.createEmpty(
            named: "Stranger", libraryId: "lib-z", in: f.root.appendingPathComponent("other"), now: Date())
        await f.coordinator.locate(row, at: stranger)
        #expect(f.opened.isEmpty)
        #expect(f.coordinator.rowNotes["lib-a"]?.contains("is a different library") == true)
        #expect(try f.registry().entry(withId: "lib-a")?.url == f.canonical(oldPath))

        let moved = try LibraryPackage.createEmpty(
            named: "Main Library", libraryId: "lib-a", in: f.root.appendingPathComponent("disk"), now: Date())
        await f.coordinator.locate(row, at: moved)
        #expect(f.opened == [.package(f.canonical(moved))])
        #expect(try f.registry().entry(withId: "lib-a")?.url == f.canonical(moved))
    }

    @Test func openOtherGoesThroughThePanelRequest() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()
        f.coordinator.chooseLibraryFile()
        #expect(f.coordinator.libraryFileRequest?.purpose == .open)
        let b = try LibraryPackage.createEmpty(
            named: "B", libraryId: "lib-b", in: f.root.appendingPathComponent("disk"), now: Date())
        await f.coordinator.libraryFileChosen(b)
        #expect(f.coordinator.libraryFileRequest == nil)
        #expect(f.opened == [.package(f.canonical(b))])
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

    @Test func fileOpenedWhileLaunchIsLoadingIsHandledAfterwards() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        let b = try f.makePackage("B", id: "lib-b")
        try f.register(a, id: "lib-a", name: "A")
        let coordinator = f.coordinator!
        f.duringOpen = { await coordinator.handleOpen(b) }
        await f.coordinator.start()
        #expect(f.opened == [.package(f.canonical(a))])
        #expect(f.coordinator.pendingSwitch == .open(f.canonical(b), name: "B"))
    }

    @Test func fileOpenedOnALaunchScreenOpensDirectly() async throws {
        let f = try Fixture(now: fixedNow)
        await f.coordinator.start()   // nothing anywhere → setup step 1
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
        #expect(f.coordinator.pendingSwitch == .open(f.canonical(b), name: "B"))
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
        guard case .invalid(let file)? = f.coordinator.switchProblem else {
            Issue.record("expected an invalid-file alert, got \(String(describing: f.coordinator.switchProblem))")
            return
        }
        #expect(file.cause == .noDatabase)
        f.coordinator.dismissProblem()
        #expect(f.coordinator.switchProblem == nil)
        #expect(f.coordinator.screen == .opened)
    }

    @Test func newLibraryWhileOpenIsCreatedOnlyOnceTheSwitchIsConfirmed() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        let second = f.store.librariesDirectory.appendingPathComponent("Second.mlibm")

        f.coordinator.requestNewLibrary()
        #expect(f.coordinator.newLibraryRequest?.defaultName == "New Library")
        #expect(await f.coordinator.createLibrary(named: "Second") == nil)
        #expect(f.coordinator.newLibraryRequest == nil)
        #expect(f.coordinator.pendingSwitch?.name == "Second")
        #expect(!FileManager.default.fileExists(atPath: second.path), "nothing is created before the switch")

        f.coordinator.cancelSwitch()
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try f.registry().libraries.count == 1, "a cancelled switch leaves nothing registered")

        #expect(await f.coordinator.createLibrary(named: "Second") == nil)
        f.coordinator.confirmSwitch()
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(f.relaunches == 1)
        #expect(f.pendingPath == f.canonical(second).path)
        #expect(f.opened.count == 1)
    }

    @Test func newLibraryCreationFailingAfterTheSheetIsItsOwnAlert() async throws {
        let f = try Fixture(now: fixedNow)
        let a = try f.makePackage("A", id: "lib-a")
        try f.register(a, id: "lib-a", name: "A")
        await f.coordinator.start()
        let target = f.root.appendingPathComponent("Removable")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(await f.coordinator.createLibrary(named: "Festival Set 2025", in: target) == nil)
        // The disk becomes read-only between the sheet and the confirmation.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        f.coordinator.confirmSwitch()
        #expect(f.relaunches == 0)
        guard case .creationFailed(let name, let message)? = f.coordinator.switchProblem else {
            Issue.record("expected creationFailed, got \(String(describing: f.coordinator.switchProblem))")
            return
        }
        #expect(name == "Festival Set 2025")
        #expect(message.hasSuffix("Nothing was added to your libraries."))
        #expect(try f.registry().libraries.count == 1)
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
        guard case .failed(.invalid(let file)) = outcome else {
            Issue.record("expected invalid, got \(outcome)")
            return
        }
        #expect(file.cause == .noDatabase)
        #expect(f.relaunches == 0)
        #expect(f.pendingPath == nil)
    }
}
