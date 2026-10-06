import Foundation
import Testing
@testable import MLM

/// W3-SET (S-SET-RENAMELIB, A0 D1): renaming the library file, its manifest and its list entry
/// together — checked, verified, rolled back on failure. Temporary folders only.
@Suite("Library rename (W3-SET)", .serialized)
@MainActor
struct LibraryRenameTests {

    private struct Fixture {
        let root: URL
        let libraries: URL
        let migrations: URL
        let store: LibraryRegistryStore
        let package: URL
        let libraryId = "lib-rename"

        init(name: String = "Main Library") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRenameTests-\(UUID().uuidString)")
            libraries = root.appendingPathComponent("libraries")
            migrations = root.appendingPathComponent("PathMigrations")
            try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
            store = LibraryRegistryStore(fileURL: root.appendingPathComponent("libraries.json"), librariesDirectory: libraries)
            package = try LibraryPackage.createEmpty(named: name, libraryId: libraryId, in: libraries, now: Date())
            var registry = LibraryRegistry()
            registry.upsert(libraryId: libraryId, url: package, name: name)
            try store.save(registry)
        }

        func manifestName(at package: URL) throws -> String {
            try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package)).name
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func renamesFileManifestAndListEntryTogether() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let renamed = try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                               store: f.store, pathMigrationsDirectory: f.migrations)
        #expect(renamed.lastPathComponent == "Club Sets.mlibm")
        #expect(renamed.deletingLastPathComponent().path == f.package.deletingLastPathComponent().path,
                "its location doesn’t change")
        #expect(!FileManager.default.fileExists(atPath: f.package.path))
        #expect(try f.manifestName(at: renamed) == "Club Sets")
        let entry = try #require(try f.store.load().registry.entry(withId: f.libraryId))
        #expect(entry.name == "Club Sets")
        #expect(entry.url.standardizedFileURL.path == renamed.standardizedFileURL.path)
    }

    @Test func refusesATakenNameAndChangesNothing() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try LibraryPackage.createEmpty(named: "Other", libraryId: "other", in: f.libraries, now: Date())
        #expect(throws: LibraryRename.Problem.nameTaken(fileName: "Other.mlibm")) {
            try LibraryRename.rename(package: f.package, to: "Other", libraryId: f.libraryId,
                                     store: f.store, pathMigrationsDirectory: f.migrations)
        }
        #expect(try f.manifestName(at: f.package) == "Main Library")
        #expect(try f.store.load().registry.entry(withId: f.libraryId)?.name == "Main Library")
    }

    @Test func emptyAndSameNamesAreProblems() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(LibraryRename.problem(newName: "  ", currentName: "Main Library", package: f.package) == .emptyName)
        #expect(LibraryRename.problem(newName: "Main Library", currentName: "Main Library", package: f.package) == .sameName)
        #expect(LibraryRename.problem(newName: "New", currentName: "Main Library", package: f.package) == nil)
        #expect(LibraryRename.Problem.nameTaken(fileName: "X.mlibm").message
                == "A library file named “X.mlibm” already exists in that folder. Choose another name.")
    }

    @Test func aChangeOfLetterCaseRenamesTheFile() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let renamed = try LibraryRename.rename(package: f.package, to: "main library", libraryId: f.libraryId,
                                               store: f.store, pathMigrationsDirectory: f.migrations)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.libraries.path)
        #expect(names.contains("main library.mlibm"))
        #expect(try f.manifestName(at: renamed) == "main library")
    }

    @Test func aFailedListSaveRollsEverythingBack() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // The list can't be written: its file is replaced by a directory the writer can't replace.
        try FileManager.default.removeItem(at: f.store.fileURL)
        let blocked = LibraryRegistryStore(fileURL: f.root.appendingPathComponent("locked/libraries.json"),
                                           librariesDirectory: f.libraries)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("locked"), withIntermediateDirectories: true)
        var registry = LibraryRegistry()
        registry.upsert(libraryId: f.libraryId, url: f.package, name: "Main Library")
        try blocked.save(registry)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.appendingPathComponent("locked").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.appendingPathComponent("locked").path) }

        #expect(throws: LibraryRename.Problem.self) {
            try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                     store: blocked, pathMigrationsDirectory: f.migrations)
        }
        #expect(FileManager.default.fileExists(atPath: f.package.path), "the file is back at its old name")
        #expect(!FileManager.default.fileExists(atPath: f.libraries.appendingPathComponent("Club Sets.mlibm").path))
        #expect(try f.manifestName(at: f.package) == "Main Library")
    }

    @Test func pathMigrationRecordsFollowTheDatabase() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.migrations, withIntermediateDirectories: true)
        let record = f.migrations.appendingPathComponent("organized-path-migration-x.json")
        let json: [String: Any] = ["databasePath": LibraryPackage.databaseURL(in: f.package).path]
        try JSONSerialization.data(withJSONObject: json).write(to: record)
        let renamed = try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                               store: f.store, pathMigrationsDirectory: f.migrations)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
        #expect((updated?["databasePath"] as? String) == LibraryPackage.databaseURL(in: renamed).path,
                "Roll Back Last Migration… stays available")
    }

    @Test func theOpenLibraryIsRenamedOnlyWithoutRunningWork() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var closed = 0
        var relaunched = 0
        var pending: String?
        let store = LibraryLaunchCoordinator.PendingOpenStore(take: { pending }, set: { pending = $0 })
        let running = ActivityOperation(
            id: UUID(), kind: .sync, title: "Sync “iPod”", subject: .none, state: .running, wait: nil,
            progress: .indeterminate, result: nil, startedAt: Date(), endedAt: nil, isAutomatic: false,
            libraryID: nil, needsAttention: false, dismissedAt: nil, itemNoun: .track, messageName: "Sync",
            controls: .none, isFromHistory: false)

        let refused = LibraryRename.renameOpenLibrary(
            package: f.package, currentName: "Main Library", to: "Club Sets", libraryId: f.libraryId, store: f.store,
            activeOperations: [running], closeDatabase: { closed += 1 }, pendingOpen: store,
            relaunch: { relaunched += 1 }, pathMigrationsDirectory: f.migrations)
        guard case .refused(.workRunning(let text)) = refused else {
            Issue.record("expected a refusal, got \(refused)")
            return
        }
        #expect(text.hasPrefix("MLM can’t rename the library while 1 sync is running."))
        #expect(closed == 0 && relaunched == 0)

        let outcome = LibraryRename.renameOpenLibrary(
            package: f.package, currentName: "Main Library", to: "Club Sets", libraryId: f.libraryId, store: f.store,
            activeOperations: [], closeDatabase: { closed += 1 }, pendingOpen: store,
            relaunch: { relaunched += 1 }, pathMigrationsDirectory: f.migrations)
        guard case .relaunching(let renamed) = outcome else {
            Issue.record("expected the rename, got \(outcome)")
            return
        }
        #expect(renamed.lastPathComponent == "Club Sets.mlibm")
        #expect(closed == 1 && relaunched == 1)
        #expect(pending?.hasSuffix("Club Sets.mlibm") == true, "the renamed library opens after the relaunch")
    }

    // MARK: Review S4 / S6 / nits

    @Test func aFailedMoveRestoresTheManifest() throws {
        let f = try Fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.libraries.path)
            f.cleanup()
        }
        // The folder can't take a new name; the package itself (and its manifest) stays writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.libraries.path)
        #expect(throws: LibraryRename.Problem.self) {
            try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                     store: f.store, pathMigrationsDirectory: f.migrations)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.libraries.path)
        #expect(FileManager.default.fileExists(atPath: f.package.path))
        #expect(try f.manifestName(at: f.package) == "Main Library")
        #expect(try f.store.load().registry.entry(withId: f.libraryId)?.name == "Main Library")
    }

    @Test func aFailedVerificationMovesTheFileBack() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try FileManager.default.removeItem(at: LibraryPackage.databaseURL(in: f.package))
        #expect(throws: LibraryRename.Problem.self) {
            try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                     store: f.store, pathMigrationsDirectory: f.migrations)
        }
        #expect(FileManager.default.fileExists(atPath: f.package.path))
        #expect(!FileManager.default.fileExists(atPath: f.libraries.appendingPathComponent("Club Sets.mlibm").path))
        #expect(try f.manifestName(at: f.package) == "Main Library")
    }

    @Test func aPartialRepointIsRolledBack() throws {
        let f = try Fixture()
        let locked = f.migrations.appendingPathComponent("organized-path-migration-b.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            f.cleanup()
        }
        try FileManager.default.createDirectory(at: f.migrations, withIntermediateDirectories: true)
        let old = LibraryPackage.databaseURL(in: f.package).path
        for name in ["organized-path-migration-a.json", "organized-path-migration-b.json", "organized-path-migration-c.json"] {
            try JSONSerialization.data(withJSONObject: ["databasePath": old]).write(to: f.migrations.appendingPathComponent(name))
        }
        // One record can't be replaced: the re-point stops part-way.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        #expect(throws: LibraryRename.Problem.self) {
            try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                     store: f.store, pathMigrationsDirectory: f.migrations)
        }
        for name in ["organized-path-migration-a.json", "organized-path-migration-b.json", "organized-path-migration-c.json"] {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.migrations.appendingPathComponent(name))) as? [String: Any]
            #expect(json?["databasePath"] as? String == old, "\(name) points at the old database again")
        }
        #expect(FileManager.default.fileExists(atPath: f.package.path))
        #expect(try f.store.load().registry.entry(withId: f.libraryId)?.name == "Main Library")
    }

    @Test func aPoolThatFailsToCloseRequiresARelaunch() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var pending: String?
        var relaunched = 0
        let outcome = LibraryRename.renameOpenLibrary(
            package: f.package, currentName: "Main Library", to: "Club Sets", libraryId: f.libraryId, store: f.store,
            activeOperations: [], closeDatabase: { throw CocoaError(.fileWriteUnknown) },
            pendingOpen: LibraryLaunchCoordinator.PendingOpenStore(take: { pending }, set: { pending = $0 }),
            relaunch: { relaunched += 1 }, pathMigrationsDirectory: f.migrations)
        #expect(outcome == .relaunchRequired, "never “nothing changed, try again” after the writer may have closed")
        #expect(pending == f.package.path, "MLM reopens the library under its old name")
        #expect(relaunched == 0, "the alert relaunches")
        #expect(FileManager.default.fileExists(atPath: f.package.path))
    }

    @Test func anotherLibrarysListEntryIsNeverDropped() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var registry = try f.store.load().registry
        registry.upsert(libraryId: "other", url: f.libraries.appendingPathComponent("Club Sets.mlibm"), name: "Club Sets")
        try f.store.save(registry)
        #expect(throws: LibraryRename.Problem.listedElsewhere(fileName: "Club Sets.mlibm")) {
            try LibraryRename.rename(package: f.package, to: "Club Sets", libraryId: f.libraryId,
                                     store: f.store, pathMigrationsDirectory: f.migrations)
        }
        #expect(try f.store.load().registry.entry(withId: "other") != nil)
    }

    @Test func aUnicodeNormalisationOnlyRenameRenamesTheFile() throws {
        let f = try Fixture(name: "cafe\u{301}")   // NFD, lower case
        defer { f.cleanup() }
        // Only the normalisation differs: the same name (Swift compares canonically), not "taken".
        #expect(LibraryRename.problem(newName: "caf\u{E9}", currentName: "cafe\u{301}", package: f.package) == .sameName)
        // Normalisation and letter case: renamed through a temporary name.
        let renamed = try LibraryRename.rename(package: f.package, to: "Caf\u{E9}", libraryId: f.libraryId,   // NFC
                                               store: f.store, pathMigrationsDirectory: f.migrations)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(try f.manifestName(at: renamed) == "Caf\u{E9}")
    }
}
