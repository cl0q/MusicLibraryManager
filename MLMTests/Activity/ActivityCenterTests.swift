import Foundation
import Testing
@testable import MLM

/// `ActivityCenter` (W3-ACT): lifecycle, coalescing, lanes, drive waits, grouped failures,
/// honest controls, status-bar messages, echo, grace period. A hand-driven scheduler; no sleeps.
@MainActor
@Suite("ActivityCenterTests")
struct ActivityCenterTests {
    private func makeCenter(interval: TimeInterval = 1, grace: TimeInterval = 2) -> (ActivityCenter, ManualActivityScheduler) {
        let scheduler = ManualActivityScheduler()
        return (ActivityCenter(scheduler: scheduler, progressInterval: interval, graceInterval: grace), scheduler)
    }

    // MARK: Lifecycle

    @Test func beginUpdateFinish() {
        let (center, scheduler) = makeCenter()
        let job = center.begin(.download, title: "Download 3 tracks", subject: .tracks([1, 2, 3]),
                               progress: ActivityProgress(total: 3), itemNoun: .track)
        let running = try! #require(center.operation(id: job.id))
        #expect(running.state == .running)
        #expect(running.state.word == "Running")
        #expect(center.activeOperations.count == 1)

        scheduler.advance(by: 2)
        job.update(completed: 1, total: 3, currentItem: "Bicep — Glue")
        #expect(center.operation(id: job.id)?.progress.position == 2)

        job.finish(ActivityResult(counts: [.init(.done, 3, "downloaded"), .init(.failed, 0, "failed")]))
        let done = try! #require(center.operation(id: job.id))
        #expect(done.state == .completed)
        #expect(done.endedAt != nil)
        #expect(done.result?.sentence == "3 downloaded")
        #expect(!done.needsAttention)
        #expect(center.finishedCount == 1)
        #expect(center.activeOperations.isEmpty)

        // A second end is ignored.
        job.fail(cause: "late")
        #expect(center.operation(id: job.id)?.state == .completed)
        #expect(center.finishedCount == 1)
    }

    @Test func stateWordsAreExactlyTheSix() {
        #expect(ActivityState.allCases.map(\.word) == ["Queued", "Running", "Paused", "Completed", "Failed", "Cancelled"])
    }

    // MARK: Coalescing

    @Test func progressIsCoalescedAndTheLastValueLands() {
        let (center, scheduler) = makeCenter(interval: 1)
        let job = center.begin(.folderScan, title: "Scan “Music”", progress: ActivityProgress(total: 100))
        // Within the interval after begin: held back.
        job.update(completed: 1, total: 100)
        job.update(completed: 2, total: 100)
        job.update(completed: 3, total: 100)
        #expect(center.operation(id: job.id)?.progress.completed == 0)
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: 1)
        #expect(center.operation(id: job.id)?.progress.completed == 3)
        // After the interval an update lands at once.
        scheduler.advance(by: 1.5)
        job.update(completed: 10, total: 100)
        #expect(center.operation(id: job.id)?.progress.completed == 10)
    }

    @Test func endDropsPendingProgressAndCompletesTheCount() {
        let (center, scheduler) = makeCenter(interval: 1)
        let job = center.begin(.folderScan, title: "Scan", progress: ActivityProgress(total: 10))
        job.update(completed: 4, total: 10)
        job.finish()
        scheduler.advance(by: 5)
        #expect(center.operation(id: job.id)?.progress.completed == 10)
    }

    // MARK: Lanes (PP-ACTIVITY-05)

    @Test func secondJobOfALaneQueuesInsteadOfBeingRejected() async {
        let (center, _) = makeCenter()
        let first = center.begin(.download, title: "Import “Liked on SoundCloud”",
                                 subject: .playlist(1, name: "Liked on SoundCloud"), lane: .downloads)
        let second = center.begin(.download, title: "Download 3 tracks", lane: .downloads)
        #expect(await first.waitForTurn())
        let queued = try! #require(center.operation(id: second.id))
        #expect(queued.state == .queued)
        #expect(queued.wait == .turn(after: "“Liked on SoundCloud”"))
        #expect(ActivityPresentation.activeLine(queued) == "Starts after “Liked on SoundCloud”")

        let turn = Task { await second.waitForTurn() }
        await Task.yield()
        first.finish()
        #expect(await turn.value)
        #expect(center.operation(id: second.id)?.state == .running)
    }

    @Test func cancellingAQueuedJobEndsItWithoutRunningIt() async {
        let (center, _) = makeCenter()
        let first = center.begin(.download, title: "A", lane: .downloads)
        let second = center.begin(.download, title: "B", lane: .downloads)
        let third = center.begin(.download, title: "C", lane: .downloads)
        let turn = Task { await second.waitForTurn() }
        await Task.yield()
        center.cancel(second.id)
        #expect(await turn.value == false)
        #expect(center.operation(id: second.id)?.state == .cancelled)
        #expect(center.operation(id: first.id)?.state == .running)
        // C now waits for A only.
        #expect(center.operation(id: third.id)?.wait == .turn(after: "A"))
        first.finish()
        #expect(await third.waitForTurn())
    }

    // MARK: Drive waits (UC-JOB-10)

    @Test func driveWaitIsAWaitNotAFailure() {
        let (center, _) = makeCenter()
        let job = center.begin(.download, title: "Download 14 tracks", progress: ActivityProgress(completed: 0, total: 14),
                               itemNoun: .track)
        job.setWaiting(.drive(volumeName: "Lexxar"))
        let op = try! #require(center.operation(id: job.id))
        #expect(op.state == .queued)
        #expect(op.wait?.sentence == "Waiting for “Lexxar”")
        let summary = ActivityPresentation.toolbarSummary(center)
        #expect(summary.waitingText == "14 waiting for “Lexxar”")
        #expect(summary.failedText == nil)
        let groups = ActivityPresentation.attentionGroups(center)
        #expect(groups.first?.headline == "“Lexxar” not connected · 14 waiting")
        #expect(groups.first?.isWaiting == true)
        #expect(groups.first?.note == "14 tracks resume when the drive is connected.")
        job.setWaiting(nil)
        #expect(center.operation(id: job.id)?.state == .running)
    }

    // MARK: Grouped failures (UC-JOB-11, IMP-029)

    @Test func downloadFailuresAreGroupedByPlainCauseWithTheFix() {
        let failures: [ActivityFailureGrouping.DownloadFailure] =
            (1...9).map { .init(trackID: Int64($0), reason: "Authentication expired — re-authorize and retry", sourceHint: "SoundCloud") }
            + [.init(trackID: 20, reason: "yt-dlp not installed"), .init(trackID: 21, reason: "Private video")]
        let groups = ActivityFailureGrouping.groupDownloads(failures)
        #expect(groups.map(\.cause) == ["Sign-in expired (SoundCloud)", "yt-dlp not found", "Private or no longer available"])
        #expect(groups[0].count == 9)
        #expect(groups[0].fix == .reconnect(source: nil))
        #expect(groups[1].fix == .openSettings("sources"))
        #expect(groups[1].fix?.buttonTitle == "Open Settings ▸ Sources")
        #expect(groups[2].isRetryable == false)
        #expect(ActivityFailureGrouping.headline(for: groups[0]) == "9 downloads failed — sign-in expired (SoundCloud)")
        #expect(ActivityFailureGrouping.headline(for: groups[1]) == "1 download failed — yt-dlp not found")
    }

    @Test func failuresGroupAcrossOperationsAndCountEachTrackOnce() async {
        let (center, scheduler) = makeCenter()
        await center.attachLibrary(id: "lib", store: InMemoryHistoryStore(), failureSource: FixedFailureSource(failing: [1, 2, 3]))
        let groups = ActivityFailureGrouping.groupDownloads([1, 2].map { .init(trackID: $0, reason: "No match") })
        let a = center.begin(.download, title: "A")
        a.finish(ActivityResult(counts: [.init(.done, 1, "downloaded"), .init(.failed, 2, "failed")], failureGroups: groups))
        scheduler.advance(by: 5)
        let b = center.begin(.download, title: "B")
        b.finish(ActivityResult(counts: [.init(.failed, 2, "failed")],
                                failureGroups: ActivityFailureGrouping.groupDownloads([2, 3].map { .init(trackID: $0, reason: "No match") })))
        await center.refreshFailing()
        let attention = ActivityPresentation.attentionGroups(center)
        #expect(attention.count == 1)
        #expect(attention[0].count == 3)
        #expect(ActivityPresentation.toolbarSummary(center).failedText == "3 failed")

        center.dismiss([a.id, b.id])
        #expect(ActivityPresentation.toolbarSummary(center).failedText == nil)
    }

    @Test func fixedTracksLeaveNeedsAttention() async {
        let (center, _) = makeCenter()
        let store = InMemoryHistoryStore()
        await center.attachLibrary(id: "lib", store: store, failureSource: FixedFailureSource(failing: []))
        let job = center.begin(.download, title: "A")
        job.finish(ActivityResult(counts: [.init(.failed, 1, "failed")],
                                  failureGroups: ActivityFailureGrouping.groupDownloads([.init(trackID: 7, reason: "No match")])))
        await center.refreshFailing()
        #expect(center.operation(id: job.id)?.needsAttention == false)
        #expect(ActivityPresentation.failedCount(center) == 0)
    }

    @Test func aFailedOperationCountsOnceWithItsCause() {
        let (center, _) = makeCenter()
        let job = center.begin(.backup, title: "Back Up Now")
        job.fail(cause: "Destination “Lexxar” was not connected", fix: .runAgain)
        let op = try! #require(center.operation(id: job.id))
        #expect(op.state == .failed)
        #expect(op.needsAttention)
        #expect(ActivityPresentation.resultText(op) == "Destination “Lexxar” was not connected")
        #expect(ActivityPresentation.toolbarSummary(center).failedText == "1 failed")
        #expect(ActivityPresentation.attentionGroups(center).first?.headline
                == "Back Up Now failed — Destination “Lexxar” was not connected")
    }

    // MARK: Honest controls (UC-JOB-03)

    @Test func noCancelWithoutAJobCancel() {
        let (center, _) = makeCenter()
        let job = center.begin(.backup, title: "Backup")
        center.cancel(job.id)
        #expect(center.operation(id: job.id)?.state == .running)
        #expect(center.operation(id: job.id)?.controls.canCancel == false)
    }

    @Test func cancelCallsTheJobAndTheJobReportsTheEnd() {
        let (center, _) = makeCenter()
        let flag = CancelFlag()
        let job = center.begin(.download, title: "Download", controls: ActivityControls(cancelStyle: .afterThisTrack, cancel: { flag.set() }))
        #expect(center.operation(id: job.id)?.controls.cancelStyle.title == "Cancel After This Track")
        center.cancel(job.id)
        #expect(flag.value)
        // The row ends only when the job says so (it stops after the track).
        #expect(center.operation(id: job.id)?.state == .running)
        job.cancelled(ActivityResult(counts: [.init(.done, 12, "downloaded")]))
        #expect(center.operation(id: job.id)?.state == .cancelled)
    }

    @Test func pauseNeedsBothClosures() {
        let (center, _) = makeCenter()
        let half = center.begin(.sync, title: "Sync", controls: ActivityControls(pause: {}))
        center.pause(half.id)
        #expect(center.operation(id: half.id)?.state == .running)
        let full = center.begin(.sync, title: "Sync 2", controls: ActivityControls(pause: {}, resume: {}))
        center.pause(full.id)
        #expect(center.operation(id: full.id)?.state == .paused)
        center.resume(full.id)
        #expect(center.operation(id: full.id)?.state == .running)
    }

    // MARK: Status bar (UC-JOB-08)

    @Test func startAndEndMessages() {
        let (center, _) = makeCenter()
        var messages: [ActivityStatusMessage] = []
        center.messageSink = { messages.append($0) }
        let job = center.begin(.download, title: "Import “Dekmantel 2024”", subject: .playlist(1, name: "Dekmantel 2024"),
                               progress: ActivityProgress(total: 44), itemNoun: .track, messageName: "Import")
        job.finish(ActivityResult(counts: [.init(.done, 35, "downloaded"), .init(.failed, 9, "failed")]))
        #expect(messages.map(\.text) == ["Import started — 44 tracks", "Import finished — 35 downloaded, 9 failed"])
        #expect(messages.map(\.actionTitle) == ["Show in Activity", "Show"])

        messages.removeAll()
        let auto = center.begin(.artwork, title: "Artwork for 14 new tracks", automatic: true)
        auto.finish()
        let quiet = center.begin(.backup, title: "Backup (scheduled)", quiet: true)
        quiet.finish()
        #expect(messages.isEmpty)
    }

    @Test func failedAndCancelledMessages() {
        let op = ActivityOperation(id: UUID(), kind: .backup, title: "Back Up Now", subject: .none, state: .failed, wait: nil,
                                   progress: .indeterminate, result: ActivityResult(failureCause: "the folder isn’t writable"),
                                   startedAt: Date(), endedAt: Date(), isAutomatic: false, libraryID: nil, needsAttention: true,
                                   dismissedAt: nil, itemNoun: .item, messageName: "Backup", controls: .none, isFromHistory: false)
        #expect(ActivityPresentation.endMessage(op) == "Backup failed — the folder isn’t writable")
        var cancelled = op
        cancelled.state = .cancelled
        cancelled.messageName = "Download"
        cancelled.result = ActivityResult(counts: [.init(.done, 12, "downloaded")])
        #expect(ActivityPresentation.endMessage(cancelled) == "Download cancelled — 12 downloaded")
    }

    // MARK: Echo (UC-JOB-07)

    @Test func echoUsesTheSameWordsAndNumbers() {
        let (center, scheduler) = makeCenter(interval: 0)
        let subject = ActivitySubject.playlist(5, name: "Warm-up")
        #expect(center.echo(for: subject) == nil)
        let job = center.begin(.download, title: "Import “Warm-up”", subject: subject, progress: ActivityProgress(total: 44))
        scheduler.advance(by: 1)
        job.update(completed: 11, total: 44)
        let echo = try! #require(center.echo(for: subject))
        #expect(echo.playlistText == "Importing · 12 of 44")
        #expect(echo.toolbarText == "Importing 12 of 44")
        #expect(ActivityPresentation.toolbarSummary(center).runningText == echo.toolbarText)
        // Another playlist has no echo.
        #expect(center.echo(for: .playlist(6, name: "Other")) == nil)

        let sync = center.begin(.sync, title: "Sync “iPod Classic”", subject: .syncProfile(2, name: "iPod Classic"),
                                progress: ActivityProgress(completed: 85, total: 214))
        #expect(center.echo(for: .syncProfile(2, name: "iPod Classic"))?.toolbarText == "Syncing 86 of 214")
        sync.finish()
        job.finish(ActivityResult(counts: [.init(.done, 44, "downloaded")]))
        #expect(center.echo(for: subject)?.resultText == "44 downloaded")
    }

    // MARK: Toolbar item (UC-JOB-04, §23 C14)

    @Test func toolbarShowsTheOldestRunningOperationPlusTheOthers() {
        let (center, scheduler) = makeCenter()
        #expect(ActivityPresentation.toolbarSummary(center).isIdle)
        #expect(ActivityPresentation.toolbarSummary(center).sentence == "No activity")
        let first = center.begin(.download, title: "Import", progress: ActivityProgress(completed: 11, total: 44))
        scheduler.advance(by: 1)
        _ = center.begin(.sync, title: "Sync", progress: ActivityProgress(completed: 3, total: 10))
        _ = center.begin(.analysisQueue, title: "Analyse new tracks", progress: ActivityProgress(waiting: 212), automatic: true)
        let summary = ActivityPresentation.toolbarSummary(center)
        #expect(summary.runningText == "Downloading 12 of 44 +2")
        #expect(summary.fraction == 11.0 / 44.0)
        first.fail(cause: "x")
        #expect(ActivityPresentation.toolbarSummary(center).sentence == "Syncing 4 of 10 +1, 1 failed")
    }

    // MARK: Grace period (UC-JOB-01)

    @Test func shortJobsAppearOnlyAfterTheGracePeriod() {
        let (center, scheduler) = makeCenter(grace: 2)
        let quick = center.begin(.fileCheck, title: "Check files", automatic: true, graceful: true)
        #expect(center.isHidden(quick.id))
        #expect(center.activeOperations.isEmpty)
        quick.finish()
        scheduler.advance(by: 3)
        #expect(center.operation(id: quick.id) == nil)  // no trace

        let slow = center.begin(.fileCheck, title: "Check files", automatic: true, graceful: true)
        scheduler.advance(by: 2)
        #expect(!center.isHidden(slow.id))
        #expect(center.activeOperations.count == 1)
        slow.finish()
        #expect(center.operation(id: slow.id)?.state == .completed)

        let failing = center.begin(.tagWrite, title: "Write tags", automatic: true, graceful: true)
        failing.fail(cause: "ffmpeg not found")
        #expect(center.operation(id: failing.id)?.state == .failed)
    }

    // MARK: Off-main calls keep their order

    @Test func callsFromAnotherThreadApplyInOrder() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let handle = await Task.detached { () -> ActivityOperationHandle in
            let job = center.begin(.sync, title: "Sync", progress: ActivityProgress(total: 3))
            job.update(completed: 2, total: 3)
            job.finish(ActivityResult(counts: [.init(.done, 3, "synced")]))
            return job
        }.value
        // Let the main queue drain.
        for _ in 0..<50 where center.operation(id: handle.id)?.state != .completed { await Task.yield() }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(center.operation(id: handle.id)?.state == .completed)
        #expect(center.operation(id: handle.id)?.result?.sentence == "3 synced")
    }
}

/// Thread-safe flag for control closures.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// In-memory `ActivityHistoryStore`.
actor InMemoryHistoryStore: ActivityHistoryStore {
    var records: [UUID: ActivityOperationRecord] = [:]

    func save(_ record: ActivityOperationRecord) async throws { records[record.id] = record }
    func load(now: Date) async throws -> [ActivityOperationRecord] {
        ActivityRetentionRule.apply(Array(records.values), now: now)
    }
    func closeInterrupted(at date: Date) async throws -> Int {
        var count = 0
        for (id, var record) in records where record.state.isActive {
            record.state = .cancelled
            record.endedAt = date
            var result = record.result ?? .empty
            result.summary = ActivityInterruption.summary
            record.result = result
            records[id] = record
            count += 1
        }
        return count
    }
    func prune(now: Date) async throws {
        let kept = Set(ActivityRetentionRule.apply(Array(records.values), now: now).map(\.id))
        records = records.filter { kept.contains($0.key) }
    }
    func delete(id: UUID) async throws { records[id] = nil }
    func markDismissed(ids: [UUID], at date: Date) async throws { for id in ids { records[id]?.dismissedAt = date } }
    func clearAttention(id: UUID) async throws { records[id]?.needsAttention = false }
    func markMissingSubjects() async throws -> Int { 0 }
    func all() -> [ActivityOperationRecord] { Array(records.values) }
}
