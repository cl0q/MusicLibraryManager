import Testing
import Foundation
import GRDB
@testable import MLM

/// Tests for the Settings → Backup view model.
///
/// File-based temp fixtures only (pattern copied from `BackupRestoreTests`). The backup
/// destination is pinned to a temp dir before any service call; the live install under
/// Application Support is never read or written, and the real relaunch is never invoked.
@Suite("BackupSettingsViewModel (Wave 3)", .serialized)
@MainActor
struct BackupSettingsViewModelTests {

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
                .appendingPathComponent("BackupSettingsViewModelTests-\(UUID().uuidString)")
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

        @MainActor
        func makeViewModel(
            service: BackupService,
            configRepository: ConfigRepository? = nil,
            spy: RelaunchSpy
        ) -> BackupSettingsViewModel {
            BackupSettingsViewModel(
                service: service,
                configRepository: configRepository ?? configRepo,
                relaunch: { spy.count += 1 },
                activeOperations: { [] }
            )
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

        func storedDestination() async throws -> String? {
            try await configRepo.getBackupDestination()
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

    @MainActor
    private final class RelaunchSpy {
        var count = 0
    }

    // MARK: - Refresh

    @Test func refreshPopulatesDestinationBackupsAndTotals() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService()
        _ = try await service.createBackup(reason: .scheduled)
        fixture.clockBox.advance(by: 60)
        let newest = try await service.createBackup(reason: .manual)

        // A newer but incomplete bundle must not count as the last backup.
        let incomplete = fixture.destination.appendingPathComponent("mlm-backup-29991231-235959")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)

        let spy = RelaunchSpy()
        let vm = fixture.makeViewModel(service: service, spy: spy)
        await vm.refresh()

        #expect(vm.destination?.standardizedFileURL == fixture.destination.standardizedFileURL)
        #expect(!vm.isDefaultDestination)
        #expect(vm.backups.count == 3)
        #expect(vm.backups.filter(\.isComplete).count == 2)
        #expect(vm.lastBackupDate == newest.createdAt)
        #expect(vm.lastBackupText == BackupSettingsViewModel.formatDate(newest.createdAt))
        #expect(vm.bundleSizes.count == 3)
        #expect(vm.totalSizeBytes > 0)
        #expect(vm.totalSizeBytes == vm.bundleSizes.values.reduce(0, +))
        #expect(vm.errorMessage == nil)
        #expect(spy.count == 0)
    }

    @Test func refreshWithoutBackupsShowsNever() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let vm = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        await vm.refresh()

        #expect(vm.backups.isEmpty)
        #expect(vm.lastBackupDate == nil)
        #expect(vm.lastBackupText == "Never")
        #expect(vm.totalSizeBytes == 0)
    }

    // MARK: - Back up now

    @Test func backUpNowAddsBundleAndTogglesPhase() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let vm = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        await vm.refresh()
        #expect(vm.phase == .idle)

        let task = Task { await vm.backUpNow() }
        await Task.yield()
        #expect(vm.phase == .backingUp)
        #expect(vm.isBusy)
        await task.value

        #expect(vm.phase == .idle)
        #expect(vm.backups.count == 1)
        #expect(vm.backups.first?.reason == .manual)
        #expect(vm.lastResult == "Backup created")
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Destination

    @Test func changeDestinationPersistsWritableFolder() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let other = fixture.root.appendingPathComponent("other-backups")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let vm = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        await vm.changeDestination(to: other)

        #expect(try await fixture.storedDestination() == other.path)
        #expect(vm.destination?.standardizedFileURL == other.standardizedFileURL)
        #expect(!vm.isDefaultDestination)
        #expect(vm.errorMessage == nil)

        await vm.backUpNow()
        let bundles = try FileManager.default.contentsOfDirectory(atPath: other.path)
            .filter { $0.hasPrefix("mlm-backup-") }
        #expect(bundles.count == 1)
        #expect(vm.backups.count == 1)
    }

    @Test func changeDestinationRejectsReadOnlyFolder() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let readOnly = fixture.root.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
        }

        let vm = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        await vm.refresh()
        await vm.changeDestination(to: readOnly)

        #expect(vm.errorMessage == "MLM can't write to the backup folder. Choose another folder.")
        #expect(try await fixture.storedDestination() == fixture.destination.path)
        #expect(vm.destination?.standardizedFileURL == fixture.destination.standardizedFileURL)
    }

    /// The view model gets its own config store here so that the service keeps resolving
    /// to the temp destination: the real default destination must never be listed.
    @Test func resetDestinationToDefaultPersistsEmptyValue() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let paneConfig = ConfigRepository(database: try DatabaseManager.inMemory())
        try await paneConfig.setBackupDestination("/custom/backups")

        let vm = fixture.makeViewModel(
            service: fixture.makeService(),
            configRepository: paneConfig,
            spy: RelaunchSpy()
        )
        await vm.refresh()
        #expect(!vm.isDefaultDestination)

        await vm.resetDestinationToDefault()

        #expect(try await paneConfig.getBackupDestination() == "")
        #expect(vm.isDefaultDestination)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Restore

    @Test func restoreRelaunchesExactlyOnceOnSuccess() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let pool = fixture.manager.pool
        let service = fixture.makeService(poolCloser: { try pool.close() })
        let backup = try await service.createBackup(reason: .manual)

        let spy = RelaunchSpy()
        let vm = fixture.makeViewModel(service: service, spy: spy)
        await vm.refresh()
        let listed = vm.backups

        fixture.clockBox.advance(by: 60)
        await vm.restore(backup)

        #expect(spy.count == 1)
        #expect(vm.phase == .relaunching)
        #expect(vm.errorMessage == nil)
        #expect(!vm.isRelaunchRequired)

        // The pool is closed now: refresh must not touch the service again.
        await vm.refresh()
        #expect(vm.backups == listed)
        #expect(spy.count == 1)
    }

    @Test func restoreNeverRelaunchesForIncompleteBundle() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService(poolCloser: { Issue.record("pool must not be closed") })
        let backup = try await service.createBackup(reason: .manual)

        let spy = RelaunchSpy()
        let vm = fixture.makeViewModel(service: service, spy: spy)
        await vm.refresh()

        // Listed as incomplete: rejected before the service is asked.
        let listedIncomplete = BackupInfo(
            url: backup.url, createdAt: backup.createdAt, reason: backup.reason,
            schemaVersion: backup.schemaVersion, trackCount: backup.trackCount,
            databaseSizeBytes: backup.databaseSizeBytes, isComplete: false
        )
        await vm.restore(listedIncomplete)
        #expect(vm.errorMessage == "This backup is incomplete and can't be restored. Choose another backup.")
        #expect(vm.phase == .idle)

        // Listed as complete but broken on disk since: the service rejects it.
        try FileManager.default.removeItem(at: backup.url.appendingPathComponent("music_library.db"))
        await vm.restore(backup)
        #expect(vm.errorMessage == "This backup is incomplete and can't be restored. Choose another backup.")
        #expect(vm.errorDetails == backup.url.path)
        #expect(vm.phase == .idle)
        #expect(!vm.isBusy)

        #expect(spy.count == 0)
    }

    @Test func restoreSwapFailureAsksForRelaunch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        try await fixture.insertTrack(id: 1)
        let pool = fixture.manager.pool
        let directory = fixture.root.path
        let service = fixture.makeService(poolCloser: {
            try pool.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        })
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        let backup = try await service.createBackup(reason: .manual)

        let spy = RelaunchSpy()
        let vm = fixture.makeViewModel(service: service, spy: spy)
        await vm.restore(backup)

        #expect(vm.isRelaunchRequired)
        #expect(vm.phase == .relaunching)
        #expect(vm.isBusy)
        #expect(vm.errorDetails != nil)
        #expect(spy.count == 0)

        vm.acknowledgeRelaunchRequired()
        #expect(spy.count == 1)
        #expect(!vm.isRelaunchRequired)

        vm.acknowledgeRelaunchRequired()
        #expect(spy.count == 1)
    }

    // MARK: - Labels

    @Test func reasonLabelsMatchApprovedCopy() {
        #expect(BackupSettingsViewModel.reasonLabel(.scheduled) == "Automatic")
        #expect(BackupSettingsViewModel.reasonLabel(.preMigration) == "Before update")
        #expect(BackupSettingsViewModel.reasonLabel(.manual) == "Manual")
        #expect(BackupSettingsViewModel.reasonLabel(.preRestore) == "Before restore")
        #expect(BackupSettingsViewModel.reasonLabel(nil) == "Unknown")
    }

    @Test func errorMessagesArePlainLanguage() {
        typealias VM = BackupSettingsViewModel
        let url = URL(fileURLWithPath: "/tmp/mlm-backup-x")

        #expect(VM.message(for: BackupError.destinationNotWritable, context: .backup)
            == "MLM can't write to the backup folder. Choose another folder.")
        #expect(VM.message(for: BackupError.vacuumFailed("disk I/O error"), context: .backup)
            == "The backup couldn't be created. Try again.")
        #expect(VM.message(for: BackupError.integrityCheckFailed("bad page"), context: .backup)
            == "The backup copy failed its integrity check and was discarded. Try again.")
        #expect(VM.message(for: BackupError.integrityCheckFailed("bad page"), context: .restore)
            == "This backup is damaged and can't be restored. Choose another backup.")
        #expect(VM.message(for: BackupError.bundleIncomplete(url), context: .restore)
            == "This backup is incomplete and can't be restored. Choose another backup.")
        #expect(VM.message(for: BackupError.restoreSafetyBackupFailed, context: .restore)
            == "MLM couldn't save a copy of your current library, so nothing was restored. Check the backup folder and try again.")
        #expect(VM.message(for: BackupError.restoreSwapFailed("EPERM"), context: .restore)
            == "MLM couldn't replace the library files and needs to relaunch. If your library looks wrong afterwards, restore the \"Before restore\" backup.")
        #expect(VM.message(for: CocoaError(.fileWriteUnknown), context: .backup)
            == "Something went wrong. Try again.")

        // Raw technical text only ever goes to the Details string.
        #expect(VM.details(for: BackupError.vacuumFailed("disk I/O error")) == "disk I/O error")
        #expect(VM.details(for: BackupError.destinationNotWritable) == nil)
        for error: BackupError in [.vacuumFailed("disk I/O error"), .integrityCheckFailed("bad page"), .restoreSwapFailed("EPERM")] {
            #expect(!VM.message(for: error, context: .backup).contains("disk I/O"))
            #expect(!VM.message(for: error, context: .backup).contains("bad page"))
            #expect(!VM.message(for: error, context: .backup).contains("EPERM"))
        }
    }

    @Test func detailLineJoinsReasonTracksAndSize() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let vm = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        let info = BackupInfo(
            url: URL(fileURLWithPath: "/tmp/mlm-backup-y"), createdAt: Date(), reason: .manual,
            schemaVersion: "v1", trackCount: 1, databaseSizeBytes: 2_048, isComplete: true
        )
        #expect(vm.detailLine(for: info)
            == "Manual · 1 track · \(BackupSettingsViewModel.formatBytes(2_048))")

        let foreign = BackupInfo(
            url: URL(fileURLWithPath: "/tmp/mlm-backup-z"), createdAt: Date(), reason: nil,
            schemaVersion: nil, trackCount: nil, databaseSizeBytes: nil, isComplete: false
        )
        #expect(vm.detailLine(for: foreign) == "Unknown")
    }

    // MARK: - W3-SET: schedule, retention, restore guard, reopen

    @Test func scheduleAndRetentionAreStoredPerLibrary() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let vm = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        await vm.refresh()
        #expect(vm.schedule == .daily)
        #expect(vm.retention == .last10)
        await vm.setSchedule(.weekly)
        await vm.setRetention(.last30)
        let again = fixture.makeViewModel(service: fixture.makeService(), spy: RelaunchSpy())
        await again.refresh()
        #expect(again.schedule == .weekly)
        #expect(again.retention == .last30)
    }

    @Test func restoreIsRefusedWhileWorkRuns() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        try await fixture.insertTrack(id: 1)
        let service = fixture.makeService(poolCloser: { Issue.record("pool must not be closed") })
        let backup = try await service.createBackup(reason: .manual)
        let running = ActivityOperation(
            id: UUID(), kind: .download, title: "Import “Warm-up”", subject: .none, state: .running, wait: nil,
            progress: ActivityProgress(completed: 3, total: 10, currentItem: nil), result: nil, startedAt: Date(),
            endedAt: nil, isAutomatic: false, libraryID: nil, needsAttention: false, dismissedAt: nil,
            itemNoun: .track, messageName: "Download", controls: .none, isFromHistory: false)
        let spy = RelaunchSpy()
        let vm = BackupSettingsViewModel(service: service, configRepository: fixture.configRepo,
                                         relaunch: { spy.count += 1 }, activeOperations: { [running] })
        let blockers = try #require(vm.restoreBlockers())
        let refusal = BackupSettingsViewModel.restoreRefusal(blockers)
        #expect(refusal.hasPrefix("MLM can’t restore while 1 download is running."))
        #expect(refusal.contains("• Import “Warm-up” — 4 of 10") || refusal.contains("• Import “Warm-up”"))
        await vm.restore(backup)
        #expect(spy.count == 0)
        #expect(vm.phase == .idle)
        #expect(vm.errorMessage == refusal)
    }

    @Test func restoreRelaunchReopensTheRestoredLibrary() {
        var stored: String?
        var relaunched = 0
        let store = LibraryLaunchCoordinator.PendingOpenStore(take: { stored }, set: { stored = $0 })
        let package = URL(fileURLWithPath: "/tmp/Main Library.mlibm")
        let relaunch = BackupSettingsViewModel.relaunchIntoLibrary(package: package, pendingOpen: store,
                                                                   relaunch: { relaunched += 1 })
        relaunch()
        #expect(stored == package.path, "PP-SETTINGS-16: the restored library opens after the relaunch")
        #expect(relaunched == 1)
    }

    @Test func restoreMessageStatesTheConsequenceInNumbers() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let vm = BackupSettingsViewModel(service: fixture.makeService(), configRepository: fixture.configRepo,
                                         relaunch: {}, activeOperations: { [] }, countTracks: { 12_935 })
        await vm.refresh()
        let info = BackupInfo(url: URL(fileURLWithPath: "/tmp/mlm-backup-a"), createdAt: Date(), reason: .scheduled,
                              schemaVersion: "v1", trackCount: 12_921, databaseSizeBytes: 1, isComplete: true)
        let message = vm.restoreMessage(for: info, libraryName: "Main Library")
        #expect(message.contains("MLM quits and reopens in the restored “Main Library”."))
        #expect(message.contains("14 tracks added since this backup leave the library; their files stay in the library folder."))
        #expect(message.hasSuffix("To undo, restore the “Before restore” backup."))
        #expect(BackupSettingsViewModel.restoreTitle(info).hasPrefix("Restore the backup from "))
    }

    @Test func destinationReachabilityIsSaidInWords() {
        let tresor = URL(fileURLWithPath: "/Volumes/Tresor/MLM Backups")
        #expect(LocationReach.of(tresor, isVolumeMounted: { _ in false }, exists: { _ in false }) == .notConnected(volume: "Tresor"))
        #expect(LocationReach.of(tresor, isVolumeMounted: { _ in true }, exists: { _ in true }).text == "Connected · on “Tresor”")
        #expect(LocationReach.of(tresor, isVolumeMounted: { _ in true }, exists: { _ in false }) == .notFound)
        #expect(LocationReach.of(URL(fileURLWithPath: "/Users/x/b"), isVolumeMounted: { _ in true }, exists: { _ in true }) == .onThisMac)
        #expect(LocationReach.notConnected(volume: "Lexxar").text == "Not connected — on “Lexxar”")
    }
}
