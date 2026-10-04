import Testing
import Foundation
import GRDB
@testable import MLM

/// A3 Wave 2 (Step-0 decision 4): backups belong to one library. A library never lists,
/// prunes or restores another library's bundles. Temp directories only — the default
/// backups root is injected.
@Suite("Backup library scope (A3 Wave 2)", .serialized)
struct BackupLibraryScopeTests {

    /// One library: its own database with a `library_id`, sharing `root` with others.
    private struct Library {
        let dbPath: URL
        let manager: DatabaseManager
        let configRepo: ConfigRepository
        let backupsRoot: URL

        init(id: String, in root: URL, backupsRoot: URL, customDestination: URL? = nil) async throws {
            let dir = root.appendingPathComponent("lib-\(id)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dbPath = dir.appendingPathComponent("music_library.db")
            manager = try DatabaseManager(path: dbPath)
            configRepo = ConfigRepository(database: manager.pool)
            self.backupsRoot = backupsRoot
            if !id.isEmpty {
                try await configRepo.set(key: "library_id", value: id)
            }
            if let customDestination {
                try await configRepo.setBackupDestination(customDestination.path)
            }
        }

        func service(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> BackupService {
            BackupService(
                database: manager.pool,
                databasePath: dbPath,
                coversDirectory: nil,
                configRepository: configRepo,
                defaultBackupsRoot: backupsRoot,
                now: { date }
            )
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupLibraryScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    // MARK: - Destination

    @Test func defaultDestinationIsPerLibrary() async throws {
        let root = try makeRoot()
        let backups = root.appendingPathComponent("backups")
        let a = try await Library(id: "lib-a", in: root, backupsRoot: backups)
        #expect(await a.service().destinationDirectory() == backups.appendingPathComponent("lib-a"))
        #expect(BackupService.defaultDestination(forLibraryId: "x", in: backups) == backups.appendingPathComponent("x"))
        #expect(BackupService.defaultDestination(forLibraryId: "", in: backups) == backups)
    }

    @Test func libraryWithoutIdKeepsTheSharedDefault() async throws {
        let root = try makeRoot()
        let backups = root.appendingPathComponent("backups")
        let legacy = try await Library(id: "", in: root, backupsRoot: backups)
        #expect(await legacy.service().destinationDirectory() == backups)
    }

    @Test func customDestinationStaysAsSet() async throws {
        let root = try makeRoot()
        let custom = root.appendingPathComponent("custom")
        let a = try await Library(id: "lib-a", in: root, backupsRoot: root.appendingPathComponent("backups"),
                                  customDestination: custom)
        #expect(await a.service().destinationDirectory() == custom)
    }

    @Test func productionBackupsRootIsInApplicationSupport() {
        #expect(BackupService.defaultBackupsRoot.path.hasSuffix(
            "Library/Application Support/com.musiclibrary.app/backups"))
    }

    // MARK: - Listing and pruning in a shared folder

    @Test func sharedCustomFolderListsOnlyOwnBundles() async throws {
        let root = try makeRoot()
        let shared = root.appendingPathComponent("shared")
        let backups = root.appendingPathComponent("backups")
        let a = try await Library(id: "lib-a", in: root, backupsRoot: backups, customDestination: shared)
        let b = try await Library(id: "lib-b", in: root, backupsRoot: backups, customDestination: shared)

        let infoA = try await a.service(at: date(0)).createBackup(reason: .manual)
        let infoB = try await b.service(at: date(10)).createBackup(reason: .manual)

        #expect(try await a.service().listBackups().map(\.url.lastPathComponent) == [infoA.url.lastPathComponent])
        #expect(try await b.service().listBackups().map(\.url.lastPathComponent) == [infoB.url.lastPathComponent])
        #expect(try await a.service().listBackups().first?.libraryId == "lib-a")
    }

    @Test func pruneNeverRemovesAnotherLibrarysBundles() async throws {
        let root = try makeRoot()
        let shared = root.appendingPathComponent("shared")
        let backups = root.appendingPathComponent("backups")
        let a = try await Library(id: "lib-a", in: root, backupsRoot: backups, customDestination: shared)
        let b = try await Library(id: "lib-b", in: root, backupsRoot: backups, customDestination: shared)

        var bBundles: [URL] = []
        for i in 0..<3 {
            bBundles.append(try await b.service(at: date(Double(i))).createBackup(reason: .manual).url)
        }
        for i in 0..<3 {
            _ = try await a.service(at: date(Double(100 + i))).createBackup(reason: .manual)
        }

        let removed = try await a.service().pruneBackups(keep: 1)
        #expect(removed.count == 2)
        for url in bBundles {
            #expect(FileManager.default.fileExists(atPath: url.path), "pruned B's bundle \(url.lastPathComponent)")
        }
        #expect(try await a.service().listBackups().count == 1)
        #expect(try await b.service().listBackups().count == 3)
    }

    @Test func defaultFolderAlsoListsOwnBundlesFromTheSharedRoot() async throws {
        let root = try makeRoot()
        let backups = root.appendingPathComponent("backups")
        // Bundles written before A3 sit directly in the root, tagged with their library id.
        let preA3 = try await Library(id: "lib-a", in: root, backupsRoot: backups, customDestination: backups)
        let other = try await Library(id: "lib-b", in: root, backupsRoot: backups, customDestination: backups)
        let oldA = try await preA3.service(at: date(0)).createBackup(reason: .scheduled)
        _ = try await other.service(at: date(5)).createBackup(reason: .scheduled)

        let a = try await Library(id: "lib-a", in: root, backupsRoot: backups)
        let newA = try await a.service(at: date(10)).createBackup(reason: .manual)

        #expect(newA.url.deletingLastPathComponent().lastPathComponent == "lib-a")
        let listed = try await a.service().listBackups()
        #expect(listed.map(\.url.lastPathComponent) == [newA.url.lastPathComponent, oldA.url.lastPathComponent])
        #expect(listed.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["lib-a", "backups"])
    }

    // MARK: - Restore

    @Test func restoreRefusesAnotherLibrarysBundle() async throws {
        let root = try makeRoot()
        let shared = root.appendingPathComponent("shared")
        let backups = root.appendingPathComponent("backups")
        let a = try await Library(id: "lib-a", in: root, backupsRoot: backups, customDestination: shared)
        let b = try await Library(id: "lib-b", in: root, backupsRoot: backups, customDestination: shared)
        let infoB = try await b.service(at: date(0)).createBackup(reason: .manual)
        let dbBefore = try Data(contentsOf: a.dbPath)

        await #expect(throws: BackupError.wrongLibrary) {
            try await a.service(at: date(10)).prepareRestore(from: infoB)
        }
        // Nothing happened to A: no safety backup, database untouched.
        #expect(try await a.service().listBackups().isEmpty)
        #expect(try Data(contentsOf: a.dbPath) == dbBefore)
    }

    // MARK: - Pre-migration hook

    @Test func preMigrationHookWritesIntoTheLibrarysDefaultFolder() async throws {
        let root = try makeRoot()
        let backups = root.appendingPathComponent("backups")
        let a = try await Library(id: "lib-a", in: root, backupsRoot: backups)
        try await a.configRepo.set(key: "seed", value: "1")
        let newest = try #require(DatabaseManager.buildMigrator().migrations.last)
        try await a.manager.pool.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [newest])
        }

        let bundle = try #require(try BackupService.performPreMigrationBackupIfNeeded(
            pool: a.manager.pool,
            databasePath: a.dbPath,
            backupsRoot: backups
        ))
        #expect(bundle.deletingLastPathComponent() == backups.appendingPathComponent("lib-a"))
    }
}
