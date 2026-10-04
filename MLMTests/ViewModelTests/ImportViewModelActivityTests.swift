import Foundation
import Testing
import GRDB
@testable import MLM

/// Tests for ImportViewModel <-> ActivityViewModel integration (UI-006).
@Suite("ImportViewModelActivityTests")
@MainActor
struct ImportViewModelActivityTests {

    // MARK: - Helpers

    private struct Fixture {
        let db: DatabasePool
        let importService: ImportService
        let configRepo: ConfigRepository
        let activityVM: ActivityViewModel
        let importVM: ImportViewModel

        init() throws {
            // ImportService needs a DatabasePool; use DatabaseManager(path:) for a migrated pool.
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-vm-test-\(UUID().uuidString)")
            let dbManager = try DatabaseManager(path: tempDir.appendingPathComponent("db.sqlite"))
            let db = dbManager.pool
            let trackRepo = TrackRepository(database: db)
            let importService = ImportService(database: db, trackRepository: trackRepo)
            let configRepo = ConfigRepository(database: db)
            let activityVM = ActivityViewModel()
            let importVM = ImportViewModel(
                importService: importService,
                configRepository: configRepo,
                activityViewModel: activityVM
            )
            self.db = db
            self.importService = importService
            self.configRepo = configRepo
            self.activityVM = activityVM
            self.importVM = importVM
        }
    }

    /// Create a temp directory with N empty .mp3 files.
    private func makeTempDir(fileCount: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            let file = dir.appendingPathComponent("track\(i).mp3")
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        return dir
    }

    /// Wait for `isImporting` to become false, with a timeout.
    private func waitForImportDone(_ vm: ImportViewModel, timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.isImporting && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Tests

    @Test func importFromDirectory_registersImportOperation() async throws {
        let fx = try Fixture()
        let dir = try makeTempDir(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: dir) }

        await fx.importVM.importFromDirectory(dir)
        await waitForImportDone(fx.importVM)

        // Operation should exist in recents with type .import
        let importOps = fx.activityVM.recentOperations.filter { $0.type == .import }
        #expect(importOps.count == 1)
        #expect(importOps.first?.title.hasPrefix("Import:") == true)
    }

    @Test func importFromDirectory_completesSuccessfully() async throws {
        let fx = try Fixture()
        let dir = try makeTempDir(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        await fx.importVM.importFromDirectory(dir)
        await waitForImportDone(fx.importVM)

        // Operation should reach a terminal state (completed even if individual files fail metadata)
        let op = fx.activityVM.recentOperations.first { $0.type == .import }
        #expect(op?.status == .completed)
        // The import ran to completion (isImporting is false)
        #expect(fx.importVM.isImporting == false)
    }

    @Test func importFromDirectory_emptyDirectory_completesWithoutCrash() async throws {
        let fx = try Fixture()
        let dir = try makeTempDir(fileCount: 0)
        defer { try? FileManager.default.removeItem(at: dir) }

        await fx.importVM.importFromDirectory(dir)
        await waitForImportDone(fx.importVM)

        // Empty dir: operation should complete (0 files processed)
        let op = fx.activityVM.recentOperations.first { $0.type == .import }
        #expect(op?.status == .completed)
    }

    @Test func importFromDirectory_nonexistentDirectory_fails() async throws {
        let fx = try Fixture()
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")

        await fx.importVM.importFromDirectory(bogus)
        await waitForImportDone(fx.importVM)

        let op = fx.activityVM.recentOperations.first { $0.type == .import }
        // Either failed or no operation leaked as running
        if let op {
            #expect(op.status == .failed)
        }
        #expect(!fx.activityVM.operations.contains { $0.isActive && $0.type == .import })
    }

    @Test func cancelImport_viaActivityPanel_marksCancelled() async throws {
        // Use a blocking fake so cancellation is the ONLY exit — no race with real import completion.
        struct BlockingImportService: ImportServicing {
            func importDirectory(
                _ directory: URL,
                onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?
            ) async throws -> ImportService.ImportResult {
                // Suspend until cancelled (Task.sleep throws CancellationError on cancel)
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-vm-cancel-test-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(path: tempDir.appendingPathComponent("db.sqlite"))
        let db = dbManager.pool
        let configRepo = ConfigRepository(database: db)
        let activityVM = ActivityViewModel()
        let importVM = ImportViewModel(
            importService: BlockingImportService(),
            configRepository: configRepo,
            activityViewModel: activityVM
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dir = try makeTempDir(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let importTask = Task {
            await importVM.importFromDirectory(dir)
        }

        // Poll until the operation registers (generous timeout for main-actor hop under load)
        var opID: UUID?
        let deadline = Date().addingTimeInterval(10.0)
        while opID == nil && Date() < deadline {
            opID = importVM.currentOperationID
            if opID == nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(opID != nil, "Operation should have registered")

        if let opID {
            activityVM.cancelOperation(id: opID, detail: "User cancelled")
        }

        await importTask.value

        // Poll briefly for the activity VM to process cancellation
        let cancelDeadline = Date().addingTimeInterval(10.0)
        while Date() < cancelDeadline {
            let op = activityVM.recentOperations.first { $0.type == .import }
            if op?.status == .cancelled { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let op = activityVM.recentOperations.first { $0.type == .import }
        #expect(op?.status == .cancelled)
        #expect(importVM.errorMessage == nil)
        #expect(importVM.isImporting == false)
    }
}
