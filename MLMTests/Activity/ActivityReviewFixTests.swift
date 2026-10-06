import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-ACT review round for the registry: one count per failing track across causes and the
/// `Earlier downloads` group (S4), fixes only where they can run (S5), `Show` without the toolbar
/// item (S6), interrupted rows closed once (S8), lenient history (S9), echo by track set (N8),
/// the stall watchdog, and the Folders import's Run Again (S5/S7).
@Suite("ActivityReviewFixTests")
@MainActor
struct ActivityReviewFixTests {
    private func center(_ scheduler: ManualActivityScheduler = ManualActivityScheduler(), stall: TimeInterval = 600) -> ActivityCenter {
        ActivityCenter(scheduler: scheduler, progressInterval: 0, stallInterval: stall)
    }

    private func failedBatch(_ center: ActivityCenter, _ ids: [Int64], reason: String, title: String) -> ActivityOperationHandle {
        let job = center.begin(.download, title: title)
        job.finish(ActivityResult(counts: [.init(.failed, ids.count, "failed")],
                                  failureGroups: ActivityFailureGrouping.groupDownloads(ids.map { .init(trackID: $0, reason: reason) })))
        return job
    }

    // MARK: S4

    @Test func aTrackFailingAgainWithAnotherCauseCountsOnce() async {
        let scheduler = ManualActivityScheduler()
        let center = center(scheduler)
        await center.attachLibrary(id: "lib", store: InMemoryHistoryStore(), failureSource: FixedFailureSource(failing: Set(1...9)))
        _ = failedBatch(center, Array(1...9), reason: "Authentication expired — re-authorize and retry", title: "Import")
        scheduler.advance(by: 60)  // reconnect → retry: 9 fail again, another cause
        let retry = failedBatch(center, Array(1...9), reason: "No match", title: "Retry 9 tracks")
        await center.refreshFailing()
        #expect(ActivityPresentation.failedCount(center) == 9, "not 18")
        let groups = ActivityPresentation.attentionGroups(center)
        #expect(groups.count == 1)
        #expect(groups.first?.headline == "9 downloads failed — no match found on any source")
        #expect(groups.first?.tracksByOperation.keys.sorted() == [retry.id], "the newest operation owns them; Retry All retries once")
    }

    @Test func failuresWithoutAnOperationShowAsEarlierDownloads() async {
        let center = center()
        center.retryHandler = { _, _ in }
        await center.attachLibrary(id: "lib", store: InMemoryHistoryStore(), failureSource: FixedFailureSource(failing: Set(1...12)))
        _ = failedBatch(center, Array(1...9), reason: "No match", title: "Import")
        await center.refreshFailing()
        let groups = ActivityPresentation.attentionGroups(center)
        let earlier = groups.first { $0.isEarlier }
        #expect(earlier?.count == 3)
        #expect(earlier?.fix == .retry)
        #expect(ActivityPresentation.failedCount(center) == 12, "item count == Download failed scope count")
        // Dismissing them leaves the toolbar count, the tracks stay failed.
        ActivitySubjectNavigator.dismiss(groups.filter { $0.isEarlier }, center: center)
        #expect(ActivityPresentation.failedCount(center) == 9)
    }

    @Test func itemCountEqualsTheScopeCountWithTheDatabase() async throws {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        var ids: [Int64] = []
        for index in 0..<12 {
            let track = try await tracks.insert(Track(artist: "A", album: "", title: "T\(index)", format: "m4a",
                                                      originalPath: "https://soundcloud.com/a/t\(index)"))
            ids.append(try #require(track.id))
            _ = try await tracks.persistDownloadFailure(trackId: ids.last!, reason: "No match")  // all 12 fail; 3 from before
        }
        let repo = ActivityOperationRepository(database: db)
        let center = center()
        await center.attachLibrary(id: "lib", store: repo, failureSource: repo)
        _ = failedBatch(center, Array(ids.prefix(9)), reason: "Authentication expired", title: "Import")
        _ = failedBatch(center, Array(ids.prefix(9)), reason: "No match", title: "Retry")
        await center.refreshFailing()
        let scope = try await TrackScopeQueries(database: db).scopeSummary().counts.count(for: .downloadFailed)
        #expect(scope == 12)
        #expect(ActivityPresentation.failedCount(center) == scope)
    }

    // MARK: S5

    @Test func noFixIsOfferedWithoutAnAction() async {
        let center = center()
        await center.attachLibrary(id: "lib", store: InMemoryHistoryStore(), failureSource: FixedFailureSource(failing: [1]))
        // A sync failure restored from history: `Run Again` has no closure.
        let sync = center.begin(.sync, title: "Sync “iPod”")
        sync.finish(ActivityResult(counts: [.init(.failed, 1, "failed")],
                                   failureGroups: [ActivityFailureGroup(cause: "Disk full", count: 1, fix: .runAgain)]))
        // A download failure without any retry closure or handler.
        let download = failedBatch(center, [1], reason: "No match", title: "Import")
        _ = download
        await center.refreshFailing()
        let groups = ActivityPresentation.attentionGroups(center)
        for group in groups {
            switch group.fix {
            case .runAgain?: Issue.record("Run Again without a closure: \(group.headline)")
            case .retry?: #expect(group.isRetryable, "Retry offered only when it can run")
            default: break
            }
        }
        #expect(groups.first { $0.headline.contains("Disk full") }?.fix == nil)
        #expect(groups.first { $0.trackIDs == [1] }?.fix == .showTracks)
        center.retryHandler = { _, _ in }
        #expect(ActivityPresentation.attentionGroups(center).first { $0.trackIDs == [1] }?.fix == .retry)
    }

    // MARK: S6

    @Test func showOpensTheWindowWhenTheItemIsNotOnScreen() {
        let router = ActivityRouter()
        router.isToolbarItemVisible = false
        let before = router.windowRequest
        router.showPopover()
        #expect(!router.isPopoverPresented)
        #expect(router.windowRequest == before + 1)
        router.isToolbarItemVisible = true
        router.showPopover()
        #expect(router.isPopoverPresented)
    }

    // MARK: S8

    @Test func interruptedRowsAreClosedOnceNotOnEveryReload() async {
        let store = InMemoryHistoryStore()
        let center = center()
        await center.attachLibrary(id: "lib", store: store, failureSource: nil)
        let running = center.begin(.sync, title: "Sync “iPod”")
        await center.flushPersistence()
        await center.reloadHistory()
        await center.flushPersistence()
        let record = await store.all().first { $0.id == running.id }
        #expect(record?.state == .running, "this session's running row is not 'Stopped when MLM quit'")
    }

    @Test func writesDuringAttachLandAfterTheClose() async {
        let inner = InMemoryHistoryStore()
        let gate = AsyncGate()
        let store = GatedCloseStore(inner: inner, gate: gate)
        let center = center()
        let attach = Task { await center.attachLibrary(id: "lib", store: store, failureSource: nil) }
        while !(await store.closeStarted) { await Task.yield() }
        let job = center.begin(.sync, title: "Sync")  // starts while interrupted rows are being closed
        await gate.open()
        await attach.value
        await center.flushPersistence()
        #expect(await inner.all().first { $0.id == job.id }?.state == .running, "held, then written after the close")
    }

    // MARK: S9

    @Test func appLevelHistoryIsReadLenientlyAndNeverOverwritten() async throws {
        let dir = try makeActivityTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("activity.json")
        let good = ActivityOperationRecord(id: UUID(), kind: .backup, title: "Backup", subject: .none, state: .completed,
                                           isAutomatic: false, startedAt: Date(), endedAt: Date(), result: nil,
                                           needsAttention: false, dismissedAt: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodJSON = String(decoding: try encoder.encode(good), as: UTF8.self)
        try Data("[\(goodJSON), {\"broken\": true}]".utf8).write(to: file)
        let store = ActivityAppLevelStore(fileURL: file)
        #expect(try await store.load(now: Date()).map(\.id) == [good.id], "the readable element survives")

        try Data("not json".utf8).write(to: file)
        #expect(try await store.load(now: Date()).isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("activity.json.unreadable-") }
        #expect(aside.count == 1, "the unreadable file is kept")
        let kept = try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8)
        #expect(kept == "not json")
    }

    @Test func anUnknownFixInsideAResultKeepsTheFailedTracks() throws {
        let json = """
        {"counts":[{"outcome":"done","count":3,"word":"downloaded"},{"outcome":"weird","count":1,"word":"x"}],
         "failureGroups":[{"cause":"No match","count":2,"fix":{"teleport":{}},"trackIDs":[4,5],"isRetryable":true}],
         "items":[]}
        """
        let result = try JSONDecoder().decode(ActivityResult.self, from: Data(json.utf8))
        #expect(result.failedTrackIDs == [4, 5])
        #expect(result.failureGroups.first?.fix == nil)
        #expect(result.counts.count == 2)
        #expect(try JSONDecoder().decode(ActivityKind.self, from: Data("\"fromTheFuture\"".utf8)) == .other)
    }

    // MARK: N8

    @Test func echoForTracksMatchesOnlyTheSameTrackSet() {
        let center = center()
        _ = center.begin(.download, title: "Download 2 tracks", subject: .tracks([1, 2]), progress: ActivityProgress(total: 2))
        #expect(center.echo(for: .tracks([2, 1])) != nil)
        #expect(center.echo(for: .tracks([3])) == nil)
    }

    // MARK: Stall watchdog

    @Test func aRunningOperationWithoutProgressIsFlagged() {
        let scheduler = ManualActivityScheduler()
        let center = center(scheduler, stall: 600)
        let job = center.begin(.sync, title: "Sync", progress: ActivityProgress(total: 10))
        let waiting = center.begin(.download, title: "Download")
        waiting.setWaiting(.drive(volumeName: "Lexxar"))
        scheduler.advance(by: 599)
        #expect(center.stalledMinutes(center.operation(id: job.id)!) == nil)
        scheduler.advance(by: 121)
        let op = center.operation(id: job.id)!
        #expect(ActivityPresentation.stallText(op, center: center) == "No progress for 12 min")
        #expect(op.state == .running, "the state stays Running")
        #expect(center.stalledMinutes(center.operation(id: waiting.id)!) == nil, "a drive wait is not a stall")
        job.update(completed: 1, total: 10)
        #expect(center.stalledMinutes(center.operation(id: job.id)!) == nil)
    }

    // MARK: Folders import (S5, S7)

    @Test func aThrowawayImporterCanStillRunAgain() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("folders-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbManager = try DatabaseManager(path: tempDir.appendingPathComponent("db.sqlite"))
        let folder = tempDir.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let center = center()
        // As FoldersView does: an importer that nobody keeps.
        do {
            let importer = ImportViewModel(importService: ImportService(database: dbManager.pool, trackRepository: TrackRepository(database: dbManager.pool)),
                                           configRepository: ConfigRepository(database: dbManager.pool), activity: center)
            await importer.importFromDirectory(folder)
        }
        let first = try #require(center.finishedOperations.first)
        #expect(first.controls.runAgain != nil)
        first.controls.runAgain?()
        for _ in 0..<5_000 where center.allOperations.filter({ $0.kind == .folderScan }).count < 2 { await Task.yield() }
        #expect(center.allOperations.filter { $0.kind == .folderScan }.count == 2, "Run Again ran")
    }

    @Test func foldersImportPostsTheNotificationsAfterACancelOrAnError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MLM/Views/Folders/FoldersView.swift"), encoding: .utf8)
        #expect(text.contains("if importer.lastResult == nil || importer.lastResult?.cancelled == true {"))
    }
}

/// A store whose `closeInterrupted` waits for a gate (attach in progress).
actor GatedCloseStore: ActivityHistoryStore {
    let inner: InMemoryHistoryStore
    let gate: AsyncGate
    private(set) var closeStarted = false
    init(inner: InMemoryHistoryStore, gate: AsyncGate) { self.inner = inner; self.gate = gate }
    func save(_ record: ActivityOperationRecord) async throws { try await inner.save(record) }
    func load(now: Date) async throws -> [ActivityOperationRecord] { try await inner.load(now: now) }
    func closeInterrupted(at date: Date) async throws -> Int {
        closeStarted = true
        await gate.wait()
        return try await inner.closeInterrupted(at: date)
    }
    func prune(now: Date) async throws { try await inner.prune(now: now) }
    func delete(id: UUID) async throws { try await inner.delete(id: id) }
    func markDismissed(ids: [UUID], at date: Date) async throws { try await inner.markDismissed(ids: ids, at: date) }
    func clearAttention(id: UUID) async throws { try await inner.clearAttention(id: id) }
    func markMissingSubjects() async throws -> Int { 0 }
    func items(for id: UUID) async throws -> [ActivityItemOutcome] { [] }
}
