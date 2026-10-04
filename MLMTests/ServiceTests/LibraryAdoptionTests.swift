import Testing
import Foundation
import GRDB
@testable import MLM

/// A3 Wave 3: adoption of the pre-A3 install into a library file (A0 D7, Step-0 decision 6).
///
/// Every test builds a fake legacy install in a temp directory. The core invariant is
/// checked after a simulated crash at every step: either the legacy layout is intact and
/// usable, or a complete library file plus its registry entry exists — never a split.
@Suite("LibraryAdoption (A3 Wave 3)", .serialized)
struct LibraryAdoptionTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_791_115_200) // 2026-10-04T12:00:00Z

    private struct FakeInstall {
        let root: URL
        let appSupport: URL
        let legacyDB: URL
        let legacyCovers: URL
        let pathMigrations: URL
        let backupsRoot: URL
        let store: LibraryRegistryStore
        let adoption: LibraryAdoption

        init(libraryId: String? = "legacy-id", trackCount: Int = 3, covers: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LibraryAdoptionTests-\(UUID().uuidString)")
            appSupport = root.appendingPathComponent("com.musiclibrary.app")
            legacyDB = appSupport.appendingPathComponent("music_library.db")
            legacyCovers = appSupport.appendingPathComponent("playlist-covers")
            pathMigrations = appSupport.appendingPathComponent("PathMigrations")
            backupsRoot = appSupport.appendingPathComponent("backups")
            store = LibraryRegistryStore(
                fileURL: appSupport.appendingPathComponent("libraries.json"),
                librariesDirectory: appSupport.appendingPathComponent("libraries"))
            adoption = LibraryAdoption(
                environment: .init(
                    legacyDatabaseURL: legacyDB,
                    registryStore: store,
                    backupsRoot: backupsRoot,
                    pathMigrationsDirectory: pathMigrations),
                now: { LibraryAdoptionTests.fixedNow })

            let manager = try DatabaseManager(path: legacyDB)
            try manager.pool.write { db in
                if let libraryId {
                    try db.execute(sql: "INSERT INTO app_config (key, value) VALUES ('library_id', ?)", arguments: [libraryId])
                }
                for id in 0..<trackCount {
                    try db.execute(
                        sql: """
                        INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path)
                        VALUES (?, 'Artist', 'Artist', 'Album', ?, 'mp3', ?)
                        """,
                        arguments: [Int64(id + 1), "Title \(id)", "/tmp/\(id).mp3"])
                }
            }
            try manager.pool.close()
            if covers {
                try FileManager.default.createDirectory(at: legacyCovers, withIntermediateDirectories: true)
                try Data("PNG".utf8).write(to: legacyCovers.appendingPathComponent("1.png"))
            }
        }

        var packageURL: URL { store.librariesDirectory.appendingPathComponent("Main Library.mlibm") }
        var partialURL: URL { LibraryPackage.stagingURL(for: packageURL) }

        func trackCount(at database: URL) throws -> Int {
            let queue = try DatabaseQueue(path: database.path)
            defer { try? queue.close() }
            return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? -1 }
        }

        func libraryId(at database: URL) throws -> String? {
            try LibraryPackage.readDatabaseLibraryId(at: database)
        }

        var retiredDirectories: [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("legacy-adopted-") }
        }

        /// Legacy layout intact and usable: database with all tracks and covers in place.
        var legacyIntact: Bool {
            guard FileManager.default.fileExists(atPath: legacyDB.path),
                  (try? trackCount(at: legacyDB)) == 3 else { return false }
            return FileManager.default.fileExists(atPath: legacyCovers.appendingPathComponent("1.png").path)
        }

        /// Complete library file with matching identity and a registry entry pointing at it.
        var packageComplete: Bool {
            guard let validated = try? LibraryPackage.validate(at: packageURL, expectedLibraryId: nil, now: Date()),
                  (try? trackCount(at: LibraryPackage.databaseURL(in: packageURL))) == 3,
                  FileManager.default.fileExists(atPath: LibraryPackage.coversDirectory(in: packageURL).appendingPathComponent("1.png").path),
                  let entry = (try? store.load())?.registry.entry(withId: validated.manifest.libraryId)
            else { return false }
            return entry.url.path == packageURL.path
        }
    }

    // MARK: - Happy path

    @Test func adoptionBuildsAVerifiedLibraryFile() throws {
        let f = try FakeInstall()
        var phases: [LibraryAdoption.Phase] = []
        let result = try f.adoption.adopt(named: "Main Library") { phases.append($0) }

        #expect(result.packageURL.path == f.packageURL.path)
        #expect(result.libraryId == "legacy-id")
        #expect(phases == [.backingUp, .creatingLibraryFile, .checking])
        #expect(f.packageComplete)
        let manifest = try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: f.packageURL))
        #expect(manifest.name == "Main Library")
        #expect(manifest.libraryId == "legacy-id")
        #expect(manifest.createdAt == Self.fixedNow)
        #expect(manifest.schemaVersion == DatabaseManager.buildMigrator().migrations.last)
        let registry = try f.store.load().registry
        #expect(registry.lastActiveLibraryId == "legacy-id")
        #expect(!f.adoption.isInProgress)
    }

    @Test func legacyFilesAreRetiredNeverDeleted() throws {
        let f = try FakeInstall()
        let result = try f.adoption.adopt(named: "Main Library") { _ in }
        #expect(!FileManager.default.fileExists(atPath: f.legacyDB.path))
        #expect(!FileManager.default.fileExists(atPath: f.legacyCovers.path))
        let retired = try #require(f.retiredDirectories.first)
        #expect(f.retiredDirectories.count == 1)
        #expect(retired.lastPathComponent == result.retiredDirectory.lastPathComponent)
        #expect(retired.lastPathComponent == "legacy-adopted-20261004T120000Z")
        #expect(try f.trackCount(at: retired.appendingPathComponent("music_library.db")) == 3)
        #expect(FileManager.default.fileExists(atPath: retired.appendingPathComponent("playlist-covers/1.png").path))
    }

    @Test func backsUpBeforeAnythingElse() throws {
        let f = try FakeInstall()
        _ = try f.adoption.adopt(named: "Main Library") { _ in }
        let folder = f.backupsRoot.appendingPathComponent("legacy-id")
        let bundles = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("mlm-backup-") }
        #expect(bundles.count == 1)
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(bundles[0]).appendingPathComponent("backup.json"))) as? [String: Any]
        #expect(manifest?["reason"] as? String == BackupReason.preAdoption.rawValue)
        #expect(manifest?["track_count"] as? Int == 3)
    }

    @Test func walResidentDataSurvives() throws {
        let f = try FakeInstall()
        // A connection that keeps uncheckpointed rows in the WAL during adoption.
        var config = Configuration()
        config.foreignKeysEnabled = false
        let pool = try DatabasePool(path: f.legacyDB.path, configuration: config)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path)
                VALUES (99, 'WAL Artist', 'WAL Artist', 'Album', 'WAL', 'mp3', '/tmp/wal.mp3')
                """)
        }
        let walSize = (try? FileManager.default.attributesOfItem(atPath: f.legacyDB.path + "-wal")[.size] as? Int) ?? 0
        #expect(walSize > 0)

        let result = try f.adoption.adopt(named: "Main Library") { _ in }
        try pool.close()
        let queue = try DatabaseQueue(path: LibraryPackage.databaseURL(in: result.packageURL).path)
        let artist = try queue.read { db in try String.fetchOne(db, sql: "SELECT artist FROM tracks WHERE id = 99") }
        #expect(artist == "WAL Artist")
    }

    @Test func nameCollisionPicksTheNextFreeName() throws {
        let f = try FakeInstall()
        try FileManager.default.createDirectory(at: f.packageURL, withIntermediateDirectories: true)
        let result = try f.adoption.adopt(named: "Main Library") { _ in }
        #expect(result.packageURL.lastPathComponent == "Main Library 2.mlibm")
    }

    @Test func libraryWithoutIdGetsOneInTheLibraryFileOnly() throws {
        let f = try FakeInstall(libraryId: nil)
        // A backup made before adoption carries no library id.
        let manager = try DatabaseManager(path: f.legacyDB)
        let configRepo = ConfigRepository(database: manager.pool)
        let service = BackupService(
            database: manager.pool, databasePath: f.legacyDB, coversDirectory: nil,
            configRepository: configRepo, defaultBackupsRoot: f.backupsRoot)
        let early = try awaitResult { try await service.createBackup(reason: .manual) }
        try manager.pool.close()

        let result = try f.adoption.adopt(named: "Main Library") { _ in }
        #expect(UUID(uuidString: result.libraryId) != nil)
        #expect(try f.libraryId(at: LibraryPackage.databaseURL(in: result.packageURL)) == result.libraryId)
        let retired = try #require(f.retiredDirectories.first)
        #expect(try f.libraryId(at: retired.appendingPathComponent("music_library.db")) == nil)
        // Backups of the old layout are claimed by the adopted library, so they stay restorable.
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: early.url.appendingPathComponent("backup.json"))) as? [String: Any]
        #expect(manifest?["library_id"] as? String == result.libraryId)
    }

    @Test func pathMigrationManifestsFollowTheDatabase() throws {
        let f = try FakeInstall()
        try FileManager.default.createDirectory(at: f.pathMigrations, withIntermediateDirectories: true)
        let mine = f.pathMigrations.appendingPathComponent("organized-path-migration-1.json")
        let other = f.pathMigrations.appendingPathComponent("organized-path-migration-2.json")
        try Data(#"{"databasePath": "\#(f.legacyDB.path)", "status": "applied", "libraryRoot": "/Volumes/X"}"#.utf8).write(to: mine)
        try Data(#"{"databasePath": "/elsewhere/music_library.db", "status": "applied"}"#.utf8).write(to: other)
        let otherBefore = try Data(contentsOf: other)

        let result = try f.adoption.adopt(named: "Main Library") { _ in }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: mine)) as? [String: Any]
        #expect(json?["databasePath"] as? String == LibraryPackage.databaseURL(in: result.packageURL).path)
        #expect(json?["status"] as? String == "applied")
        #expect(json?["libraryRoot"] as? String == "/Volumes/X")
        #expect(try Data(contentsOf: other) == otherBefore)
    }

    @Test func missingLegacyDatabaseIsRefused() throws {
        let f = try FakeInstall()
        try FileManager.default.removeItem(at: f.legacyDB)
        #expect(throws: LibraryAdoption.AdoptionError.legacyDatabaseMissing) {
            try f.adoption.adopt(named: "Main Library") { _ in }
        }
        #expect(!f.adoption.isInProgress)
    }

    // MARK: - Crash at every step

    @Test(arguments: LibraryAdoption.Step.allCases)
    func crashAfterEachStepKeepsTheInvariantAndResumes(step: LibraryAdoption.Step) throws {
        let f = try FakeInstall()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: step)
        // "Crash": the process stops here. On disk, never a split.
        #expect(f.adoption.isInProgress)
        #expect(f.legacyIntact || f.packageComplete, "split state after \(step)")

        let outcome = try f.adoption.resume()
        #expect(!f.adoption.isInProgress)
        #expect(!FileManager.default.fileExists(atPath: f.partialURL.path))
        if step < .installed {
            #expect(outcome == .rolledBack)
            #expect(f.legacyIntact)
            #expect(!FileManager.default.fileExists(atPath: f.packageURL.path))
            #expect(try f.store.load().registry.libraries.isEmpty)
            #expect(f.retiredDirectories.isEmpty)
        } else {
            guard case .completed(let result) = outcome else {
                Issue.record("expected completed after \(step), got \(outcome)")
                return
            }
            #expect(result.packageURL.path == f.packageURL.path)
            #expect(f.packageComplete)
            #expect(!FileManager.default.fileExists(atPath: f.legacyDB.path))
            #expect(f.retiredDirectories.count == 1)
        }
    }

    @Test func crashDuringStagingLeavesOnlyRemovableLeftovers() throws {
        let f = try FakeInstall()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .backedUp)
        // Half-written staging directory, as a crash during VACUUM INTO would leave it.
        try FileManager.default.createDirectory(at: f.partialURL, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: f.partialURL.appendingPathComponent("music_library.db"))

        #expect(try f.adoption.resume() == .rolledBack)
        #expect(f.legacyIntact)
        #expect(!FileManager.default.fileExists(atPath: f.partialURL.path))
    }

    @Test func crashBetweenRenameAndJournalRollsForward() throws {
        let f = try FakeInstall()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .verified)
        // The rename happened, the journal didn't record it.
        try FileManager.default.moveItem(at: f.partialURL, to: f.packageURL)

        guard case .completed = try f.adoption.resume() else {
            Issue.record("expected completed")
            return
        }
        #expect(f.packageComplete)
        #expect(f.retiredDirectories.count == 1)
    }

    @Test func crashHalfwayThroughRetiringFinishesTheMove() throws {
        let f = try FakeInstall()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .repointed)
        // Database moved, covers not yet.
        let retired = f.appSupport.appendingPathComponent("legacy-adopted-partial")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.legacyDB, to: retired.appendingPathComponent("music_library.db"))
        #expect(f.packageComplete)

        guard case .completed = try f.adoption.resume() else {
            Issue.record("expected completed")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: f.legacyCovers.path))
    }

    @Test func verificationFailureRollsBackAndLegacyStays() throws {
        let f = try FakeInstall()
        try f.adoption.begin(named: "Main Library")
        try f.adoption.advance(through: .staged)
        // Damage the staged copy: a track goes missing.
        let queue = try DatabaseQueue(path: LibraryPackage.databaseURL(in: f.partialURL).path)
        try queue.write { db in try db.execute(sql: "DELETE FROM tracks WHERE id = 1") }
        try queue.close()

        #expect(throws: LibraryAdoption.AdoptionError.self) {
            try f.adoption.advance(through: .retired)
        }
        #expect(try f.adoption.resume() == .rolledBack)
        #expect(f.legacyIntact)
        #expect(!FileManager.default.fileExists(atPath: f.packageURL.path))
    }

    @Test func failedAdoptionRollsBackAndCanBeRetried() throws {
        let f = try FakeInstall()
        // Make the libraries folder unwritable so staging fails.
        try FileManager.default.createDirectory(at: f.store.librariesDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.store.librariesDirectory.path)
        #expect(throws: (any Error).self) {
            try f.adoption.adopt(named: "Main Library") { _ in }
        }
        #expect(!f.adoption.isInProgress)
        #expect(f.legacyIntact)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.store.librariesDirectory.path)
        _ = try f.adoption.adopt(named: "Main Library") { _ in }
        #expect(f.packageComplete)
    }

    @Test func resumeWithoutJournalIsANoOp() throws {
        let f = try FakeInstall()
        #expect(try f.adoption.resume() == .rolledBack)
        #expect(f.legacyIntact)
    }

    // MARK: - Helpers

    /// Runs an async throwing call to completion from a synchronous test.
    private func awaitResult<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}
