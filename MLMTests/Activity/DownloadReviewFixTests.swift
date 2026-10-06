import Foundation
import Testing
@testable import MLM

/// W3-ACT review round for downloads: no double downloads (B1), retries keep the failed batch's
/// source policy (B2), every Cancel cancels its own batch (S1, S2), drive loss mid-batch is a
/// wait of the same operation (S3). A recording fake runner; no network, no files.
@Suite("DownloadReviewFixTests")
@MainActor
struct DownloadReviewFixTests {
    /// Records every batch; each call's result comes from `script` (by call index).
    private final class RecordingRunner: DownloadBatchRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[DownloadOrchestrator.DownloadRequest]] = []
        private var gates: [CheckedContinuation<Void, Never>] = []
        private var holdCount: Int
        let script: (_ call: Int, _ ids: [Int64]) -> DownloadOrchestrator.BatchResult

        init(hold: Int = 0, script: @escaping (Int, [Int64]) -> DownloadOrchestrator.BatchResult) {
            holdCount = hold
            self.script = script
        }

        var requests: [[DownloadOrchestrator.DownloadRequest]] { lock.lock(); defer { lock.unlock() }; return calls }
        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return !gates.isEmpty }
        func release() {
            lock.lock(); let g = gates; gates = []; lock.unlock()
            g.forEach { $0.resume() }
        }

        func downloadBatch(_ requests: [DownloadOrchestrator.DownloadRequest],
                           onProgress: ((Int, Int, String) -> Void)?,
                           onTrackProgress: ((Double) -> Void)?) async -> DownloadOrchestrator.BatchResult {
            lock.lock()
            let index = calls.count
            calls.append(requests)
            let hold = holdCount > 0
            if hold { holdCount -= 1 }
            lock.unlock()
            if hold {
                await withCheckedContinuation { c in lock.lock(); gates.append(c); lock.unlock() }
            }
            return script(index, requests.map(\.trackId))
        }
    }

    private final class RecordingPersister: DownloadTrackPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [Int64] = []
        private var inProgress: Set<Int64> = []
        var failedIDs: [Int64] { lock.lock(); defer { lock.unlock() }; return failures }
        var stillMarked: Set<Int64> { lock.lock(); defer { lock.unlock() }; return inProgress }
        func markDownloadsInProgress(trackIds: [Int64]) async throws { lock.lock(); inProgress.formUnion(trackIds); lock.unlock() }
        func clearDownloadsInProgress(trackIds: [Int64]) async throws { lock.lock(); inProgress.subtract(trackIds); lock.unlock() }
        func markAsDownloaded(trackId: Int64, organizedPath: String, format: String, bitrate: Int?, downloadStatus: String?) async throws {
            lock.lock(); inProgress.remove(trackId); lock.unlock()
        }
        func persistDownloadFailure(trackId: Int64, reason: String, date: Date, minimumAttempts: Int) async throws -> TrackDownloadFailure {
            lock.lock(); failures.append(trackId); lock.unlock()
            return TrackDownloadFailure(reason: reason, date: date, attempts: minimumAttempts)
        }
    }

    /// The tracks as the database knows them now.
    private final class TrackStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tracks: [Int64: Track] = [:]
        func put(_ track: Track) { lock.lock(); tracks[track.id!] = track; lock.unlock() }
        func get(_ id: Int64) -> Track? { lock.lock(); defer { lock.unlock() }; return tracks[id] }
        func markLocal(_ id: Int64) {
            lock.lock()
            tracks[id]?.organizedPath = "A/\(id).m4a"
            lock.unlock()
        }
    }

    private func track(_ id: Int64, path: String? = nil) -> Track {
        var track = Track(artist: "Artist", album: "", title: "T\(id)", format: "mp3",
                          originalPath: path ?? "https://soundcloud.com/artist/t\(id)")
        track.id = id
        return track
    }

    private func allDownloaded(_ ids: [Int64]) -> DownloadOrchestrator.BatchResult {
        DownloadOrchestrator.BatchResult(succeeded: ids.count,
                                         downloadedPaths: Dictionary(uniqueKeysWithValues: ids.map { ($0, "/lib/\($0).mp3") }))
    }

    private func make(_ runner: RecordingRunner, store: TrackStore? = nil,
                      persister: RecordingPersister = RecordingPersister())
        -> (DownloadViewModel, ActivityCenter, [String]) {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let vm = DownloadViewModel(trackPersister: persister, activity: center)
        vm.batchRunnerOverride = runner
        if let store { vm.trackFetchOverride = { store.get($0) } }
        return (vm, center, [])
    }

    // MARK: B1

    @Test func doubleRetryAllDownloadsOnce() async throws {
        let runner = RecordingRunner(hold: 1, script: { _, ids in self.allDownloaded(ids) })
        let store = TrackStore()
        for id in 1...3 { store.put(track(Int64(id))) }
        let (vm, center, _) = make(runner, store: store)
        var notes: [String] = []
        center.messageSink = { notes.append($0.text) }

        let first = Task { await vm.retryAllFailed(trackIds: [1, 2, 3]) }
        while !runner.isHeld { await Task.yield() }
        await vm.retryAllFailed(trackIds: [1, 2, 3])  // the second click
        #expect(notes.contains("Already downloading"))
        #expect(center.activeOperations.count == 1, "the second click registers nothing")
        runner.release()
        await first.value
        #expect(runner.requests.count == 1)
    }

    @Test func overlappingBatchesDownloadEachTrackOnce() async throws {
        let store = TrackStore()
        for id in 1...4 { store.put(track(Int64(id))) }
        let runner = RecordingRunner(hold: 1, script: { _, ids in
            for id in ids { store.markLocal(id) }
            return self.allDownloaded(ids)
        })
        let (vm, center, _) = make(runner, store: store)
        let first = Task { await vm.downloadTracks([1, 2].map { track(Int64($0)) }) }
        while !runner.isHeld { await Task.yield() }
        // Header `Download missing` and a card's: 2 overlaps with the running batch.
        let second = Task { await vm.downloadTracks([2, 3, 4].map { track(Int64($0)) }) }
        while center.activeOperations.count < 2 { await Task.yield() }
        #expect(center.activeOperations.last?.progress.total == 2, "track 2 is left out")
        runner.release()
        _ = await first.value
        _ = await second.value
        #expect(runner.requests.map { $0.map(\.trackId) } == [[1, 2], [3, 4]])
    }

    @Test func aQueuedBatchWhoseTracksFinishedMeanwhileEndsQuietly() async throws {
        let store = TrackStore()
        for id in 1...2 { store.put(track(Int64(id))) }
        let runner = RecordingRunner(hold: 1, script: { _, ids in self.allDownloaded(ids) })
        let (vm, center, _) = make(runner, store: store)
        let first = Task { await vm.downloadTracks([track(1)]) }
        while !runner.isHeld { await Task.yield() }
        let second = Task { await vm.downloadTracks([track(2)]) }
        while center.activeOperations.count < 2 { await Task.yield() }
        store.markLocal(2)  // downloaded by another path meanwhile
        runner.release()
        _ = await first.value
        #expect(await second.value == nil)
        #expect(runner.requests.count == 1, "the finished track is not downloaded again")
        #expect(center.finishedOperations.count == 1, "the empty batch leaves no trace")
    }

    // MARK: B2

    @Test func retriesKeepTheFailedBatchsSourcePolicy() async throws {
        let store = TrackStore()
        store.put(track(1))
        store.put(track(2, path: "https://www.youtube.com/watch?v=x"))
        let runner = RecordingRunner(script: { _, ids in
            DownloadOrchestrator.BatchResult(failed: ids.count, failedTrackIds: Set(ids),
                                             failureReasons: Dictionary(uniqueKeysWithValues: ids.map { ($0, "No match") }))
        })
        let (vm, center, _) = make(runner, store: store)
        // An `.auto` batch fails; its retry stays `.auto` — though track 2's link is YouTube.
        await vm.downloadTracks([track(1), track(2, path: "https://www.youtube.com/watch?v=x")])
        let autoOp = try #require(center.finishedOperations.first)
        #expect(autoOp.controls.retry != nil, "a finished batch keeps its own Retry")
        center.retryFailed(autoOp.id, trackIDs: [1, 2])
        for _ in 0..<10_000 where runner.requests.count < 2 { await Task.yield() }
        try #require(runner.requests.count == 2)
        #expect(runner.requests[1].map(\.preferredSource) == [.auto, .auto])

        // A pinned batch stays pinned.
        // The retry batch has fully returned (its ledger claim released).
        while !center.activeOperations.isEmpty || vm.ledger.operation(containing: 1) != nil { await Task.yield() }
        await vm.downloadTracks([track(1)], preferredSource: .soundcloud)
        // (The test clock doesn't move: find the batch by its title, not by its end.)
        let pinned = try #require(center.finishedOperations.first { $0.title == "Download 1 track" })
        #expect(pinned.result?.failureGroups.first?.sourcePin == "soundcloud")
        center.retryFailed(pinned.id, trackIDs: [1])
        for _ in 0..<10_000 where runner.requests.count < 4 { await Task.yield() }
        try #require(runner.requests.count == 4)
        #expect(runner.requests[3].map(\.preferredSource) == [.soundcloud])
    }

    @Test func aRetryFromHistoryUsesTheStoredPinOrAuto() {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        var calls: [([Int64], String?)] = []
        center.retryHandler = { ids, pin in calls.append((ids, pin)) }
        let job = center.begin(.download, title: "Import")
        job.finish(ActivityResult(counts: [.init(.failed, 2, "failed")], failureGroups: [
            ActivityFailureGroup(cause: "No match found on any source", count: 1, fix: .retry, trackIDs: [1], sourcePin: "youtube"),
            ActivityFailureGroup(cause: "Reason unknown", count: 1, fix: .retry, trackIDs: [2]),
        ]))
        center.retryFailed(job.id, trackIDs: [1, 2])
        #expect(calls.contains { $0.0 == [1] && $0.1 == "youtube" })
        #expect(calls.contains { $0.0 == [2] && $0.1 == nil }, "no stored pin = auto")
    }

    // MARK: S1 / S2

    @Test func cancelWhileFirstInLineButNotRunningNeverStartsAndUndoesNothingLeft() async throws {
        let store = TrackStore()
        store.put(track(1))
        let runner = RecordingRunner(script: { _, ids in self.allDownloaded(ids) })
        let persister = RecordingPersister()
        let (vm, center, _) = make(runner, store: store, persister: persister)
        let gate = AsyncGate()
        vm.trackFetchOverride = { id in await gate.wait(); return store.get(id) }  // the re-read takes a moment
        let ticket = DownloadTicket()
        let run = Task { await vm.downloadTracks([track(1)], ticket: ticket) }
        while center.activeOperations.isEmpty { await Task.yield() }
        #expect(center.activeOperations.first?.state == .running, "first in line")
        ticket.cancel()
        await gate.open()
        #expect(await run.value?.succeeded ?? 0 == 0)
        #expect(runner.requests.isEmpty, "never started")
        #expect(persister.stillMarked.isEmpty, "no track left marked Downloading")
        #expect(center.finishedOperations.first?.state == .cancelled)
    }

    @Test func oldCancelPathsCancelOnlyTheirOwnBatch() async throws {
        let store = TrackStore()
        for id in 1...2 { store.put(track(Int64(id))) }
        let runner = RecordingRunner(hold: 1, script: { _, ids in self.allDownloaded(ids) })
        let (vm, center, _) = make(runner, store: store)
        // `cancel()` with nothing running does nothing — no flag survives into the next batch.
        vm.cancel()
        let firstTicket = DownloadTicket()
        let first = Task { await vm.downloadTracks([track(1)], ticket: firstTicket) }
        while !runner.isHeld { await Task.yield() }
        let secondTicket = DownloadTicket()
        let second = Task { await vm.downloadTracks([track(2)], ticket: secondTicket) }
        while center.activeOperations.count < 2 { await Task.yield() }
        // The sheet's Cancel (its ticket) and a track's Cancel hit only their own batch.
        secondTicket.cancel()
        vm.cancelDownload(containing: 2)
        while center.activeOperations.count > 1 { await Task.yield() }
        runner.release()
        #expect(await first.value?.succeeded == 1, "the running batch is untouched")
        #expect(await second.value == nil)
        #expect(runner.requests.map { $0.map(\.trackId) } == [[1]])
        _ = firstTicket
    }

    // MARK: S3

    @Test func driveLossMidBatchWaitsAndContinuesAsTheSameOperation() async throws {
        let store = TrackStore()
        for id in 1...3 { store.put(track(Int64(id))) }
        let mounted = MountFlag(true)
        let runner = RecordingRunner(script: { call, ids in
            if call == 0 {
                // Track 1 done, then the drive went away: 2 and 3 wait.
                mounted.set(false)
                var result = DownloadOrchestrator.BatchResult(succeeded: 1, downloadedPaths: [1: "/Volumes/MLMTest/1.mp3"])
                result.driveWaitingTrackIds = [2, 3]
                return result
            }
            return self.allDownloaded(ids)
        })
        let persister = RecordingPersister()
        let (vm, center, _) = make(runner, store: store, persister: persister)
        vm.libraryRoot = "/Volumes/MLMTest/Music"
        vm.isVolumeMounted = { _ in mounted.value }
        vm.driveRecheckInterval = 0.01
        let run = Task { await vm.downloadTracks([1, 2, 3].map { track(Int64($0)) }) }
        while center.activeOperations.first?.wait != .drive(volumeName: "MLMTest") { await Task.yield() }
        #expect(center.activeOperations.first?.state == .queued)
        #expect(persister.failedIDs.isEmpty, "no failure recorded because of the drive")
        mounted.set(true)
        let result = await run.value
        #expect(result?.succeeded == 3)
        #expect(runner.requests.map { $0.map(\.trackId) } == [[1, 2, 3], [2, 3]])
        #expect(center.finishedOperations.count == 1, "one operation, not two")
        #expect(center.finishedOperations.first?.state == .completed)
        #expect(persister.stillMarked.isEmpty)
    }

    // MARK: N4

    @Test func nothingRefusesWithBusy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["MLM/Views/TrackList/TrackListActions.swift", "MLM/Views/TrackList/SelectionBar.swift", "MLM/App/Commands/TrackCommands.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains("downloads.isDownloading {"), "\(path) must queue, not refuse")
            #expect(!text.contains("isDownloadBusy: container.downloadViewModel?.isDownloading")
                    && !text.contains("isDownloadBusy: DependencyContainer.shared.downloadViewModel?.isDownloading"), "\(path)")
        }
    }
}

final class MountFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool) { flag = value }
    func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
