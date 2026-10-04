import Testing
import Foundation
import GRDB
@testable import MLM

/// Wave 2 tests for `BackupService` restore mechanics (`validateForRestore` / `prepareRestore`).
///
/// File-based temp fixtures only — `VACUUM INTO` and the file swap need a real DB on disk.
/// The live install under Application Support is never touched.
@Suite("BackupService restore (Wave 2)", .serialized)
struct BackupRestoreTests {

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let dbPath: URL
        let coversDir: URL
        let destination: URL
        let manager: DatabaseManager
        let configRepo: ConfigRepository
        let clockBox: ClockBox

        init() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupRestoreTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            self.root = root
            self.dbPath = root.appendingPathComponent("music_library.db")
            self.coversDir = root.appendingPathComponent("playlist-covers")
            self.destination = root.appendingPathComponent("backups")

            self.manager = try DatabaseManager(path: dbPath)
            try await manager.pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }

            self.configRepo = ConfigRepository(database: manager.pool)
            try await configRepo.setBackupDestination(destination.path)

            try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
            try Data("PNG".utf8).write(to: coversDir.appendingPathComponent("cover1.png"))

            self.clockBox = ClockBox(date: Date(timeIntervalSince1970: 1_700_000_000))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func makeService(poolCloser: (@Sendable () throws -> Void)? = nil) -> BackupService {
            let box = clockBox
            return BackupService(
                database: manager.pool,
                databasePath: dbPath,
                coversDirectory: coversDir,
                configRepository: configRepo,
                now: { box.current() },
                poolCloser: poolCloser
            )
        }

        /// Closes the live pool, then leaves junk `-wal` / `-shm` files behind to simulate
        /// sidecars that a restore must clear before swapping the snapshot in.
        func closingPoolLeavingStaleSidecars() -> @Sendable () throws -> Void {
            let pool = manager.pool
            let path = dbPath.path
            return {
                try pool.close()
                try Data("junk".utf8).write(to: URL(fileURLWithPath: path + "-wal"))
                try Data("junk".utf8).write(to: URL(fileURLWithPath: path + "-shm"))
            }
        }

        func insertTrack(id: Int) async throws {
            try await manager.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        Int64(id), "Artist", "Artist", "Album", "Title \(id)",
                        "mp3", "/tmp/test/\(id).mp3"
                    ]
                )
            }
        }

        func deleteTrack(id: Int) async throws {
            try await manager.pool.write { db in
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [Int64(id)])
            }
        }

        /// Track ids in the database file at `dbPath`, read through a fresh connection.
        func trackIdsOnDisk() throws -> [Int] {
            let queue = try DatabaseQueue(path: dbPath.path)
            defer { try? queue.close() }
            return try queue.read { db in
                try Int.fetchAll(db, sql: "SELECT id FROM tracks ORDER BY id")
            }
        }

        /// Backups as seen after a restore. The service's own pool is closed by then, so
        /// list through a fresh connection to the restored DB (which carries the
        /// `backup_destination` row) — never let resolution fall back to the live default.
        func listBackupsAfterRestore() async throws -> [BackupInfo] {
            let queue = try DatabaseQueue(path: dbPath.path)
            defer { try? queue.close() }
            let service = BackupService(
                database: queue,
                databasePath: dbPath,
                coversDirectory: nil,
                configRepository: ConfigRepository(database: queue)
            )
            #expect(await service.destinationDirectory().standardizedFileURL == destination.standardizedFileURL)
            return try await service.listBackups()
        }

        func coverText(_ name: String) throws -> String {
            String(decoding: try Data(contentsOf: coversDir.appendingPathComponent(name)), as: UTF8.self)
        }

        func stagedLeftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix(".restore-") }
        }
    }

    private final class ClockBox: @unchecked Sendable {
        private var date: Date
        private let lock = NSLock()
        init(date: Date) { self.date = date }
        func current() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }
        func advance(by seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            date = date.addingTimeInterval(seconds)
        }
    }

    // MARK: - Tests

    @Test func prepareRestoreSwapsDatabase() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService(poolCloser: fixture.closingPoolLeavingStaleSidecars())
        let backup = try await service.createBackup(reason: .manual)

        // Mutate live state after the backup.
        fixture.clockBox.advance(by: 60)
        try await fixture.deleteTrack(id: 1)
        try await fixture.insertTrack(id: 2)
        try Data("CHANGED".utf8).write(to: fixture.coversDir.appendingPathComponent("cover1.png"))
        try Data("NEW".utf8).write(to: fixture.coversDir.appendingPathComponent("cover2.png"))

        try await service.prepareRestore(from: backup)

        // Live DB now holds the backed-up state.
        #expect(try fixture.trackIdsOnDisk() == [1])
        #expect(!FileManager.default.fileExists(atPath: fixture.dbPath.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.dbPath.path + "-shm"))

        // Covers restored verbatim.
        #expect(try fixture.coverText("cover1.png") == "PNG")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.coversDir.appendingPathComponent("cover2.png").path
        ))

        // A safety backup of the mutated state exists, and the source bundle was not consumed.
        let backups = try await fixture.listBackupsAfterRestore()
        let safety = try #require(backups.first { $0.reason == .preRestore })
        #expect(safety.isComplete)
        #expect(safety.trackCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: backup.url.appendingPathComponent("music_library.db").path
        ))
        #expect(backups.first { $0.url.lastPathComponent == backup.url.lastPathComponent }?.isComplete == true)

        #expect(try fixture.stagedLeftovers().isEmpty)
    }

    @Test func prepareRestoreRejectsIncompleteBundle() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService(poolCloser: { Issue.record("pool must not be closed") })
        let backup = try await service.createBackup(reason: .manual)
        try await fixture.insertTrack(id: 2)

        // `backup.isComplete` is now stale: validation must re-check the disk.
        try FileManager.default.removeItem(at: backup.url.appendingPathComponent("music_library.db"))

        await #expect(throws: BackupError.bundleIncomplete(backup.url)) {
            try await service.prepareRestore(from: backup)
        }

        // Live DB untouched and still usable; no safety backup was taken.
        let ids = try await fixture.manager.pool.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM tracks ORDER BY id")
        }
        #expect(ids == [1, 2])
        let backups = try await service.listBackups()
        #expect(!backups.contains { $0.reason == .preRestore })
    }

    /// Regression: the `.preRestore` safety backup must not trigger retention pruning,
    /// which would delete the oldest bundle — the one being restored — mid-restore.
    @Test func prepareRestoreFromOldestBundleWhenRetentionIsFull() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService(poolCloser: fixture.closingPoolLeavingStaleSidecars())

        let oldest = try await service.createBackup(reason: .manual)
        try await fixture.insertTrack(id: 2)
        for _ in 0..<9 {
            fixture.clockBox.advance(by: 60)
            _ = try await service.createBackup(reason: .manual)
        }
        #expect(try await service.listBackups().count == 10)

        fixture.clockBox.advance(by: 60)
        try await service.prepareRestore(from: oldest)

        #expect(try fixture.trackIdsOnDisk() == [1])
        #expect(FileManager.default.fileExists(
            atPath: oldest.url.appendingPathComponent("music_library.db").path
        ))
        #expect(try await fixture.listBackupsAfterRestore().count == 11)
    }

    @Test func prepareRestoreLeavesLiveStateWhenPoolCloseFails() async throws {
        struct CloseFailed: Error {}

        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService(poolCloser: { throw CloseFailed() })
        let backup = try await service.createBackup(reason: .manual)
        try await fixture.insertTrack(id: 2)

        await #expect(throws: CloseFailed.self) {
            try await service.prepareRestore(from: backup)
        }

        let ids = try await fixture.manager.pool.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM tracks ORDER BY id")
        }
        #expect(ids == [1, 2])
        #expect(try fixture.coverText("cover1.png") == "PNG")
        #expect(try fixture.stagedLeftovers().isEmpty)
    }

    /// Once the pool is closed, a failed file swap must be reported as `.restoreSwapFailed`
    /// (relaunch required), not as a raw Foundation error.
    @Test func prepareRestoreReportsSwapFailureAfterPoolClosed() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let pool = fixture.manager.pool
        let directory = fixture.dbPath.deletingLastPathComponent().path
        let service = fixture.makeService(poolCloser: {
            try pool.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        })
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        let backup = try await service.createBackup(reason: .manual)

        let error = await #expect(throws: BackupError.self) {
            try await service.prepareRestore(from: backup)
        }
        guard case .restoreSwapFailed? = error else {
            Issue.record("expected .restoreSwapFailed, got \(String(describing: error))")
            return
        }
    }
}
