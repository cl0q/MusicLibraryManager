import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-SET (DEC-036, ST-BACKUP.N01/N02): `Back up automatically` Off / Daily / Weekly / On quit
/// and `Keep` 5 / 10 / 30 / All, implemented in `BackupService`; the newest complete backup of
/// a library is never removed. Temporary databases and folders only.
@Suite("Backup schedule and retention (W3-SET)", .serialized)
struct BackupScheduleTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }

    private struct Fixture {
        let root: URL
        let destination: URL
        let manager: DatabaseManager
        let config: ConfigRepository
        let clock = Clock()

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupScheduleTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            destination = root.appendingPathComponent("backups")
            manager = try DatabaseManager(path: root.appendingPathComponent("music_library.db"))
            config = ConfigRepository(database: manager.pool)
            try await config.set(key: "backup_destination", value: destination.path)
        }

        func service() -> BackupService {
            let clock = clock
            return BackupService(
                database: manager.pool, databasePath: root.appendingPathComponent("music_library.db"),
                coversDirectory: nil, configRepository: config,
                defaultBackupsRoot: root.appendingPathComponent("default-root"),
                now: { clock.now() })
        }

        func bundles() throws -> [String] {
            guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0.hasPrefix("mlm-backup-") }.sorted()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func defaultsAreTheOldBehaviour() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        #expect(await service.schedule() == .daily)
        #expect(await service.retention() == .last10)
        #expect(BackupSchedule.allCases.map(\.title) == ["Off", "Daily", "Weekly", "On quit"])
        #expect(BackupRetention.allCases.map(\.title) == ["Last 5", "Last 10", "Last 30", "All"])
    }

    @Test func dailyBacksUpAtLaunchOncePerDay() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        #expect(try await service.createScheduledBackupIfDue() != nil)
        f.clock.advance(3_600)
        #expect(try await service.createScheduledBackupIfDue() == nil)
        f.clock.advance(86_400)
        #expect(try await service.createScheduledBackupIfDue() != nil)
    }

    @Test func weeklyWaitsSevenDays() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setSchedule(.weekly)
        #expect(try await service.createScheduledBackupIfDue() != nil)
        f.clock.advance(3 * 86_400)
        #expect(try await service.createScheduledBackupIfDue() == nil)
        f.clock.advance(5 * 86_400)
        #expect(try await service.createScheduledBackupIfDue() != nil)
    }

    @Test func offAndOnQuitMakeNoLaunchBackup() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setSchedule(.off)
        #expect(try await service.createScheduledBackupIfDue() == nil)
        #expect(service.backUpOnQuitIfScheduled() == nil, "Off makes no quit backup either")
        try await service.setSchedule(.onQuit)
        #expect(try await service.createScheduledBackupIfDue() == nil)
        #expect(try f.bundles().isEmpty)
    }

    @Test func onQuitBacksUpSynchronously() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setSchedule(.onQuit)
        let info = service.backUpOnQuitIfScheduled()
        #expect(info?.reason == .scheduled)
        #expect(try f.bundles().count == 1)
    }

    @Test func onQuitAfterTheDatabaseClosedDoesNothing() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setSchedule(.onQuit)
        try f.manager.pool.close()  // a restore closed it
        #expect(service.backUpOnQuitIfScheduled() == nil)
    }

    @Test func retentionKeepsTheChosenNumber() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setRetention(.last5)
        for _ in 0..<7 {
            _ = try await service.createBackup(reason: .manual)
            f.clock.advance(60)
        }
        #expect(try f.bundles().count == 5)
    }

    @Test func allKeepsEverything() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setRetention(.all)
        for _ in 0..<12 {
            _ = try await service.createBackup(reason: .manual)
            f.clock.advance(60)
        }
        #expect(try f.bundles().count == 12)
    }

    @Test func aSmallerNumberAppliesAtOnce() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        for _ in 0..<8 {
            _ = try await service.createBackup(reason: .manual)
            f.clock.advance(60)
        }
        let removed = try await service.setRetention(.last5)
        #expect(removed.count == 3)
        #expect(try f.bundles().count == 5)
    }

    @Test func theNewestCompleteBackupIsNeverPruned() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        let complete = try await service.createBackup(reason: .manual)
        // Newer, incomplete bundles (no manifest, no database).
        for name in ["mlm-backup-29990101-000000", "mlm-backup-29990102-000000"] {
            try FileManager.default.createDirectory(at: f.destination.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        _ = try await service.pruneBackups(keep: 1)
        #expect(FileManager.default.fileExists(atPath: complete.url.path))
        let left = try await service.listBackups()
        #expect(left.contains { BackupService.pathKey($0.url) == BackupService.pathKey(complete.url) })
    }

    @Test func preMigrationPruneFollowsTheSetting() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let service = f.service()
        try await service.setRetention(.all)
        for _ in 0..<11 {
            _ = try await service.createBackup(reason: .manual)
            f.clock.advance(60)
        }
        _ = try BackupService.createBundle(
            database: f.manager.pool, databasePath: f.root.appendingPathComponent("music_library.db"),
            coversDirectory: nil, reason: .preAdoption, backupsRoot: f.root.appendingPathComponent("default-root"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        #expect(try f.bundles().count == 12, "Keep All: the setup backup prunes nothing")
    }
}
