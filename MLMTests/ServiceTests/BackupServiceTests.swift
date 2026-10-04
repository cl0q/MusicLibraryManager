import Testing
import Foundation
import GRDB
@testable import MLM

/// Wave 1 tests for `BackupService`.
///
/// Each test uses a per-test temp directory and a file-based `DatabaseManager(path:)`
/// with WAL explicitly enabled (since `init(path:)` does not enable it).
@Suite("BackupService (Wave 1)", .serialized)
struct BackupServiceTests {

    // MARK: - Fixture

    /// Per-test fixture: temp dirs, DB with WAL, covers dir, and a fake clock.
    private struct Fixture {
        let root: URL
        let dbPath: URL
        let coversDir: URL
        let destination: URL
        let manager: DatabaseManager
        let configRepo: ConfigRepository
        let clockBox: ClockBox
        let now: @Sendable () -> Date

        init(coversPresent: Bool = true) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupServiceTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            self.root = root
            self.dbPath = root.appendingPathComponent("music_library.db")
            self.coversDir = root.appendingPathComponent("covers")
            self.destination = root.appendingPathComponent("backups")

            self.manager = try DatabaseManager(path: dbPath)

            // Enable WAL explicitly (init(path:) does not).
            try await manager.pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }

            self.configRepo = ConfigRepository(database: manager.pool)

            // Set the backup destination to the test temp directory.
            try await configRepo.set(key: "backup_destination", value: destination.path)

            if coversPresent {
                try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
                let dummy1 = coversDir.appendingPathComponent("cover1.png")
                let dummy2 = coversDir.appendingPathComponent("cover2.jpg")
                try Data("PNG".utf8).write(to: dummy1)
                try Data("JPG".utf8).write(to: dummy2)
            }

            let startDate = Date(timeIntervalSince1970: 1_700_000_000) // fixed epoch
            let lock = NSLock()
            let box = ClockBox(date: startDate, lock: lock)
            self.clockBox = box
            self.now = { box.current() }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func advance(by seconds: TimeInterval) {
            clockBox.advance(by: seconds)
        }

        func makeService() -> BackupService {
            BackupService(
                database: manager.pool,
                databasePath: dbPath,
                coversDirectory: coversDir,
                configRepository: configRepo,
                now: now
            )
        }

        /// Insert a track via raw SQL (simpler than building a full Track model).
        func insertTrack(id: Int = 1, artist: String = "Test Artist") async throws {
            try await manager.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        Int64(id), artist, artist, "Test Album", "Test Title",
                        "mp3", "/tmp/test/\(id).mp3"
                    ]
                )
            }
        }
    }

    /// Sendable wrapper for the mutable clock.
    private final class ClockBox: @unchecked Sendable {
        private var date: Date
        private let lock: NSLock
        init(date: Date, lock: NSLock) {
            self.date = date
            self.lock = lock
        }
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

    @Test func createBackupProducesCompleteBundle() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        let expectedDate = fixture.now()
        let info = try await service.createBackup(reason: .manual)

        #expect(info.isComplete)
        #expect(info.trackCount == 1)
        #expect(info.reason == .manual)
        #expect(info.createdAt == expectedDate)
        #expect(FileManager.default.fileExists(atPath: info.url.path))

        // Bundle contains expected files.
        let dbFile = info.url.appendingPathComponent("music_library.db")
        let manifestFile = info.url.appendingPathComponent("backup.json")
        #expect(FileManager.default.fileExists(atPath: dbFile.path))
        #expect(FileManager.default.fileExists(atPath: manifestFile.path))

        // Manifest is valid JSON.
        let data = try Data(contentsOf: manifestFile)
        #expect(data.count > 0)

        // No .tmp-* dirs left.
        let contents = try FileManager.default.contentsOfDirectory(
            at: fixture.destination,
            includingPropertiesForKeys: nil,
            options: []
        )
        let tmpLeft = contents.filter { $0.lastPathComponent.hasPrefix(".tmp-") }
        #expect(tmpLeft.isEmpty)
    }

    @Test func snapshotContainsWALResidentData() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        // Write a track; do NOT checkpoint.
        try await fixture.insertTrack(id: 42, artist: "WAL Artist")
        let service = fixture.makeService()

        let info = try await service.createBackup(reason: .manual)
        let snapshotURL = info.url.appendingPathComponent("music_library.db")

        // Open snapshot separately and verify the row is present.
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: snapshotURL.path, configuration: config)
        let artist = try await queue.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT artist FROM tracks WHERE id = 42"
            )
        }
        #expect(artist == "WAL Artist")
    }

    @Test func snapshotPassesIntegrityCheck() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        let info = try await service.createBackup(reason: .manual)
        let snapshotURL = info.url.appendingPathComponent("music_library.db")

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: snapshotURL.path, configuration: config)
        let result = try await queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check")
        }
        #expect(result == "ok")
    }

    @Test func coversAreCopiedWhenPresent() async throws {
        let fixture = try await Fixture(coversPresent: true)
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        let info = try await service.createBackup(reason: .manual)
        let coversInBundle = info.url.appendingPathComponent("playlist-covers")
        #expect(FileManager.default.fileExists(atPath: coversInBundle.path))

        let cover1 = coversInBundle.appendingPathComponent("cover1.png")
        let cover2 = coversInBundle.appendingPathComponent("cover2.jpg")
        #expect(FileManager.default.fileExists(atPath: cover1.path))
        #expect(FileManager.default.fileExists(atPath: cover2.path))
    }

    @Test func coversOmittedWhenAbsent() async throws {
        let fixture = try await Fixture(coversPresent: false)
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        let info = try await service.createBackup(reason: .manual)
        let coversInBundle = info.url.appendingPathComponent("playlist-covers")
        #expect(!FileManager.default.fileExists(atPath: coversInBundle.path))
    }

    @Test func listBackupsNewestFirstAndIgnoresTempDirs() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        // Create 3 backups with distinct timestamps.
        let _ = try await service.createBackup(reason: .manual)
        fixture.advance(by: 60)
        let _ = try await service.createBackup(reason: .scheduled)
        fixture.advance(by: 60)
        let _ = try await service.createBackup(reason: .manual)

        // Create a stray .tmp-junk dir.
        let tmpDir = fixture.destination.appendingPathComponent(".tmp-junk")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Create an incomplete bundle (missing backup.json).
        let incompleteDir = fixture.destination.appendingPathComponent("mlm-backup-20260101-120000")
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        // No backup.json → isComplete == false.

        let list = try await service.listBackups()

        // 3 complete + 1 incomplete = 4; tmp dir ignored.
        #expect(list.count == 4)
        // Newest first.
        for i in 0..<(list.count - 1) {
            #expect(list[i].createdAt >= list[i + 1].createdAt)
        }
        // The incomplete one is present and flagged.
        let incomplete = list.first { !$0.isComplete }
        #expect(incomplete != nil)
        #expect(incomplete?.url.lastPathComponent == "mlm-backup-20260101-120000")
    }

    @Test func pruneKeepsNewestN() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        // Create 12 backups (each 60s apart).
        // Note: createBackup internally prunes to 10, so after 12 creations we have 10 complete.
        for _ in 0..<12 {
            let _ = try await service.createBackup(reason: .manual)
            fixture.advance(by: 60)
        }

        // Add an incomplete bundle (older than all complete ones).
        let incompleteDir = fixture.destination.appendingPathComponent("mlm-backup-19700101-000000")
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)

        let before = try await service.listBackups()
        #expect(before.count == 11) // 10 complete (internal prune) + 1 incomplete

        let removed = try await service.pruneBackups(keep: 10)

        // Should remove 1: the incomplete bundle.
        #expect(removed.count == 1)

        let after = try await service.listBackups()
        #expect(after.count == 10)
        // All remaining should be complete.
        #expect(after.allSatisfy { $0.isComplete })
    }

    @Test func createBackupIfDueThrottles() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        // No backups → creates one.
        let first = try await service.createBackupIfDue(minimumAge: 86_400)
        #expect(first != nil)

        // Immediately again → throttled.
        let second = try await service.createBackupIfDue(minimumAge: 86_400)
        #expect(second == nil)

        // Advance 25 hours → creates one.
        fixture.advance(by: 25 * 3600)
        let third = try await service.createBackupIfDue(minimumAge: 86_400)
        #expect(third != nil)
    }

    @Test func customDestinationFromConfig() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let otherDir = fixture.root.appendingPathComponent("other-backups")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        try await fixture.configRepo.set(key: "backup_destination", value: otherDir.path)
        try await fixture.insertTrack()

        let service = fixture.makeService()
        let info = try await service.createBackup(reason: .manual)

        // Bundle is under the custom destination.
        #expect(info.url.path.hasPrefix(otherDir.path))
    }

    @Test func createBackupFailsCleanlyWhenDestinationNotWritable() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        // Create a read-only destination.
        let roDir = fixture.root.appendingPathComponent("readonly-backups")
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)

        // Set the custom destination to the read-only dir.
        try await fixture.configRepo.set(key: "backup_destination", value: roDir.path)
        try await fixture.insertTrack()

        let service = fixture.makeService()

        // Make the directory read-only.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: roDir.path
        )
        defer {
            // Restore permissions so cleanup can remove it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: roDir.path
            )
        }

        // Running as root (e.g. CI) may bypass POSIX permissions; skip if so.
        if geteuid() == 0 {
            return
        }

        do {
            let _ = try await service.createBackup(reason: .manual)
            Issue.record("Expected destinationNotWritable error")
        } catch let error as BackupError {
            #expect(error == .destinationNotWritable)
        }

        // No .tmp-* left behind.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: roDir,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        let tmpLeft = contents.filter { $0.lastPathComponent.hasPrefix(".tmp-") }
        #expect(tmpLeft.isEmpty)
    }

    @Test func bundleNamingHonorsConventionAndCollisions() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack()
        let service = fixture.makeService()

        // Two backups within the same injected second.
        let first = try await service.createBackup(reason: .manual)
        // Do NOT advance the clock — same timestamp.
        let second = try await service.createBackup(reason: .manual)

        // Distinct names.
        #expect(first.url.lastPathComponent != second.url.lastPathComponent)
        // Both start with the expected prefix.
        #expect(first.url.lastPathComponent.hasPrefix("mlm-backup-"))
        #expect(second.url.lastPathComponent.hasPrefix("mlm-backup-"))
        // The second has a collision suffix.
        #expect(second.url.lastPathComponent.hasSuffix("-1"))
    }
}
