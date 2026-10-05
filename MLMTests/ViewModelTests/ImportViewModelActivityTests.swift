import Foundation
import Testing
import GRDB
@testable import MLM

/// ImportViewModel ↔ Activity (UI-006, ported to `ActivityCenter` in W3-ACT): every folder
/// import is a `Scan “‹folder›”` operation that always ends; its Cancel really stops it.
@Suite("ImportViewModelActivityTests")
@MainActor
struct ImportViewModelActivityTests {

    // MARK: - Helpers

    private struct Fixture {
        let importService: ImportService
        let configRepo: ConfigRepository
        let center: ActivityCenter
        let importVM: ImportViewModel

        init() throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-vm-test-\(UUID().uuidString)")
            let dbManager = try DatabaseManager(path: tempDir.appendingPathComponent("db.sqlite"))
            let db = dbManager.pool
            let trackRepo = TrackRepository(database: db)
            let importService = ImportService(database: db, trackRepository: trackRepo)
            let configRepo = ConfigRepository(database: db)
            let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
            self.importService = importService
            self.configRepo = configRepo
            self.center = center
            self.importVM = ImportViewModel(importService: importService, configRepository: configRepo, activity: center)
        }
    }

    private func makeTempDir(fileCount: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("track\(i).mp3").path, contents: Data())
        }
        return dir
    }

    private func scans(_ center: ActivityCenter) -> [ActivityOperation] {
        center.allOperations.filter { $0.kind == .folderScan }
    }

    // MARK: - Tests

    @Test func importFromDirectory_registersAScanOperation() async throws {
        let fx = try Fixture()
        let dir = try makeTempDir(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: dir) }

        await fx.importVM.importFromDirectory(dir)

        let ops = scans(fx.center)
        #expect(ops.count == 1)
        #expect(ops.first?.title == "Scan “\(dir.lastPathComponent)”")
        #expect(ops.first?.subject.kind == .folder)
        #expect(ops.first?.controls.canCancel == false, "a finished scan offers no Cancel")
    }

    @Test func importFromDirectory_completes() async throws {
        let fx = try Fixture()
        let dir = try makeTempDir(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        await fx.importVM.importFromDirectory(dir)

        #expect(scans(fx.center).first?.state == .completed)
        #expect(fx.importVM.isImporting == false)
    }

    @Test func importFromDirectory_emptyDirectory_completesWithoutCrash() async throws {
        let fx = try Fixture()
        let dir = try makeTempDir(fileCount: 0)
        defer { try? FileManager.default.removeItem(at: dir) }

        await fx.importVM.importFromDirectory(dir)
        #expect(scans(fx.center).first?.state == .completed)
    }

    @Test func importFromDirectory_nonexistentDirectory_neverLeaksARunningOperation() async throws {
        let fx = try Fixture()
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")

        await fx.importVM.importFromDirectory(bogus)

        #expect(fx.center.activeOperations.isEmpty)
        if let op = scans(fx.center).first, op.state == .failed {
            #expect(ActivityPresentation.resultText(op) == "“\(bogus.lastPathComponent)” isn’t reachable")
        }
    }

    @Test func cancelFromActivity_marksCancelled() async throws {
        // A blocking fake so cancellation is the only exit.
        struct BlockingImportService: ImportServicing {
            func importDirectory(
                _ directory: URL,
                onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?
            ) async throws -> ImportService.ImportResult {
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-vm-cancel-test-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(path: tempDir.appendingPathComponent("db.sqlite"))
        let configRepo = ConfigRepository(database: dbManager.pool)
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let importVM = ImportViewModel(importService: BlockingImportService(), configRepository: configRepo, activity: center)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dir = try makeTempDir(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let importTask = Task { await importVM.importFromDirectory(dir) }
        // The operation registers synchronously on the main actor before the work starts.
        while importVM.currentOperationID == nil { await Task.yield() }
        let opID = try #require(importVM.currentOperationID)
        #expect(center.operation(id: opID)?.controls.cancelStyle.title == "Cancel After This File")

        center.cancel(opID)
        await importTask.value

        #expect(center.operation(id: opID)?.state == .cancelled)
        #expect(importVM.errorMessage == nil)
        #expect(importVM.isImporting == false)
    }
}
