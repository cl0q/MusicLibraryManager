import Foundation
import Testing
@testable import MLM

/// Imports by drop run as Activity operations in one import lane (W2-H after W3-ACT): a second
/// import is `Queued` behind the running one and doesn't overwrite its state; each caller gets
/// its own result; files are counted in the start message.
@Suite("Drop import lane", .serialized)
@MainActor
struct DropImportLaneTests {
    /// An import service whose runs end only when the test releases them, in order.
    final class GatedImportService: ImportServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [CheckedContinuation<Void, Never>] = []
        private(set) var started: [[String]] = []

        var startedCount: Int { lock.withLock { started.count } }

        func importDirectory(_ directory: URL, onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?) async throws -> ImportService.ImportResult {
            try await importFiles([directory], onProgress: onProgress)
        }

        func importFiles(_ audioFiles: [URL], onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?) async throws -> ImportService.ImportResult {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    started.append(audioFiles.map(\.lastPathComponent))
                    gates.append(continuation)
                }
            }
            return ImportService.ImportResult(succeeded: audioFiles.count, failed: 0, skipped: 0, failures: [],
                                              totalScanned: audioFiles.count, cancelled: false, committed: audioFiles.count)
        }

        func releaseNext() {
            let gate = lock.withLock { gates.isEmpty ? nil : gates.removeFirst() }
            gate?.resume()
        }
    }

    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aSecondImportQueuesBehindTheRunningOne() async throws {
        let db = try DatabaseManager.inMemory()
        let service = GatedImportService()
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let model = ImportViewModel(importService: service, configRepository: ConfigRepository(database: db), activity: center)
        let first = [URL(fileURLWithPath: "/tmp/drop/a.mp3"), URL(fileURLWithPath: "/tmp/drop/b.mp3")]
        let second = [URL(fileURLWithPath: "/tmp/other/c.mp3")]

        let firstRun = Task { await model.importFiles(first, title: "Import 2 files") }
        #expect(await eventually { service.startedCount == 1 })
        let secondRun = Task { await model.importFiles(second, title: "Import 1 file") }
        #expect(await eventually { center.allOperations.filter { $0.kind == .folderScan }.count == 2 })

        let operations = center.allOperations.filter { $0.kind == .folderScan }
        let queued = try #require(operations.first { $0.title == "Import 1 file" })
        #expect(queued.state == .queued, "the second waits for its turn")
        #expect(service.startedCount == 1, "nothing of the second runs yet")
        #expect(model.currentOperationID == operations.first { $0.title == "Import 2 files" }?.id,
                "the running import's state is not overwritten")
        let running = try #require(operations.first { $0.title == "Import 2 files" })
        #expect(ActivityPresentation.startMessage(running) == "Import started — 2 files")

        service.releaseNext()
        #expect(await firstRun.value?.succeeded == 2)
        #expect(await eventually { service.startedCount == 2 })
        service.releaseNext()
        #expect(await secondRun.value?.succeeded == 1)
        #expect(!model.isImporting)
    }

    @Test func aQueuedImportCancelledInActivityNeverRuns() async throws {
        let db = try DatabaseManager.inMemory()
        let service = GatedImportService()
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let model = ImportViewModel(importService: service, configRepository: ConfigRepository(database: db), activity: center)

        let firstRun = Task { await model.importFiles([URL(fileURLWithPath: "/tmp/a.mp3")], title: "Import 1 file") }
        #expect(await eventually { service.startedCount == 1 })
        let secondRun = Task { await model.importFiles([URL(fileURLWithPath: "/tmp/b.mp3")], title: "Import b") }
        #expect(await eventually { center.allOperations.contains { $0.title == "Import b" } })
        let queued = try #require(center.allOperations.first { $0.title == "Import b" })
        center.cancel(queued.id)
        #expect(await secondRun.value == nil)

        service.releaseNext()
        #expect(await firstRun.value?.succeeded == 1, "cancelling the queued one didn't stop the running one")
        #expect(service.startedCount == 1)
    }

    @Test func theActivitySubjectOfAFileDropIsTheirCommonFolder() {
        let files = [URL(fileURLWithPath: "/Users/o/Music/Sets/a.mp3"), URL(fileURLWithPath: "/Users/o/Music/Live/b.mp3")]
        #expect(ImportViewModel.commonFolder(of: files).path == "/Users/o/Music")
        #expect(ImportViewModel.commonFolder(of: [files[0]]).path == "/Users/o/Music/Sets")
    }
}
