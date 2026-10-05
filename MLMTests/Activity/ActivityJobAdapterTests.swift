import Foundation
import Testing
@testable import MLM

/// The thin registrations of other areas' jobs (W3-ACT): transcode-cache move with its own
/// Cancel (PP-ACTIVITY-02), Maintenance result lines, tag-write reports, notifications.
@Suite("ActivityJobAdapterTests")
@MainActor
struct ActivityJobAdapterTests {
    // MARK: Transcode-cache move (PP-ACTIVITY-02)

    private func cacheFolders(files: Int) throws -> (root: URL, old: URL, new: URL) {
        let root = try makeActivityTempDirectory()
        let old = root.appendingPathComponent("old")
        let new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data("audio \(index)".utf8).write(to: old.appendingPathComponent("\(index).m4a"))
        }
        return (root, old, new)
    }

    private func m4aCount(_ url: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".m4a") }.count
    }

    @Test func cacheMoveMovesEveryFile() async throws {
        let folders = try cacheFolders(files: 4)
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let outcome = await TranscodeCacheMove.run(from: folders.old, to: folders.new, isCancelled: { false }, progress: { _, _, _ in })
        #expect(outcome == .moved(4))
        #expect(m4aCount(folders.new) == 4)
        #expect(m4aCount(folders.old) == 0)
    }

    @Test func cacheMoveCancelStopsAndMovesBack() async throws {
        let folders = try cacheFolders(files: 5)
        defer { try? FileManager.default.removeItem(at: folders.root) }
        var steps = 0
        let outcome = await TranscodeCacheMove.run(from: folders.old, to: folders.new,
                                                   isCancelled: { steps >= 2 },
                                                   progress: { _, _, _ in steps += 1 })
        #expect(outcome == .cancelled(movedBack: 2))
        #expect(m4aCount(folders.old) == 5, "the cache stays whole in its folder")
        #expect(m4aCount(folders.new) == 0)
    }

    @Test func cacheMoveCancelIsItsOwnNotASyncCancel() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MLM/App/DependencyContainer.swift"),
                                encoding: .utf8)
        #expect(source.contains(".transcodeCacheMove, title: \"Move transcode cache to"))
        #expect(source.contains("cancel: { stop.cancel() }"))
        #expect(!source.contains("type: .sync,\n                title: \"Cache migration"))
    }

    // MARK: Maintenance

    @Test func maintenanceResultLines() {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        func run(_ action: String, _ message: String?, cancelled: Bool = false) -> ActivityOperation? {
            let job = MaintenanceJob(action: action)
            let handle = center.begin(job.kind, title: job.title)
            job.end(handle, message: message, cancelled: cancelled)
            return center.operation(id: handle.id)
        }
        let analysed = try! #require(run("replaygain", "ReplayGain: 9,412 analyzed, 31 failed"))
        #expect(analysed.state == .completed)
        #expect(ActivityPresentation.resultText(analysed) == "\(9_412.formatted(.number)) analysed · 31 failed")
        #expect(analysed.needsAttention)
        let tool = try! #require(run("fingerprint", "fpcalc not found. Install via: brew install chromaprint"))
        #expect(tool.state == .failed)
        #expect(tool.result?.failureGroups.first?.fix == .openSettings("sources"))
        #expect(run("danceability", nil, cancelled: true)?.state == .cancelled)
        #expect(MaintenanceJob(action: "fingerprint").isCancellable)
        #expect(!MaintenanceJob(action: "path-apply").isCancellable, "a path migration can't stop half-way")
        #expect(!MaintenanceJob(action: "rescan").isCancellable)
        #expect(MaintenanceJob(action: "artwork-musicbrainz").kind == .artwork)
    }

    // MARK: Tag writes

    @Test func tagWriteReports() {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0, graceInterval: 0)
        func end(_ report: TagFlushReport) -> ActivityOperation? {
            let handle = center.begin(.tagWrite, title: "Write tags to files", automatic: true)
            TagWriteActivity.end(handle, with: report)
            return center.operation(id: handle.id)
        }
        var done = TagFlushReport()
        done.written = 27
        #expect(end(done).map(ActivityPresentation.resultText) == "27 updated")
        var lost = TagFlushReport(outcome: .rootLost)
        lost.written = 3
        #expect(end(lost)?.state == .cancelled, "the rest waits for the drive — never a failure")
        #expect(end(TagFlushReport(outcome: .unreachable)) == nil, "nothing ran: no trace")
        #expect(end(TagFlushReport(outcome: .toolMissing))?.state == .failed)
    }

    // MARK: Notifications (UC-JOB-12)

    @Test func notificationsAreOptInBackgroundOnlyAndForTheRightKinds() {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let sync = center.begin(.sync, title: "Sync “iPod”")
        sync.finish()
        let op = try! #require(center.operation(id: sync.id))
        #expect(!ActivitySystemNotifier.shouldNotify(op, enabled: false, appIsActive: false), "off by default")
        #expect(!ActivitySystemNotifier.shouldNotify(op, enabled: true, appIsActive: true), "never while frontmost")
        #expect(ActivitySystemNotifier.shouldNotify(op, enabled: true, appIsActive: false))
        let scan = center.begin(.duplicateScan, title: "Scan for duplicates")
        scan.finish()
        #expect(!ActivitySystemNotifier.shouldNotify(try! #require(center.operation(id: scan.id)), enabled: true, appIsActive: false))
        let backup = center.begin(.backup, title: "Backup (scheduled)", automatic: true)
        backup.finish()
        #expect(!ActivitySystemNotifier.shouldNotify(try! #require(center.operation(id: backup.id)), enabled: true, appIsActive: false))
    }
}
