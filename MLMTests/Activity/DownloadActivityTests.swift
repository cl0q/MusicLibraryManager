import Foundation
import Testing
@testable import MLM

/// Download batches in Activity (W3-ACT): one operation per batch, a second batch queues
/// (PP-ACTIVITY-05), honest Cancel wording, failures grouped by plain cause (PP-ACTIVITY-06),
/// drive losses are waits, not failures (UC-JOB-10). Fake runner and persister; no network.
@Suite("DownloadActivityTests")
@MainActor
struct DownloadActivityTests {
    /// Runs one batch and then suspends the next call until released.
    private final class GatedRunner: DownloadBatchRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[Int64]] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var holdFirst: Bool
        let result: (_ ids: [Int64]) -> DownloadOrchestrator.BatchResult

        init(holdFirst: Bool, result: @escaping ([Int64]) -> DownloadOrchestrator.BatchResult) {
            self.holdFirst = holdFirst
            self.result = result
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }

        func release() {
            lock.lock()
            let gate = gate
            self.gate = nil
            lock.unlock()
            gate?.resume()
        }

        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return gate != nil }

        func downloadBatch(_ requests: [DownloadOrchestrator.DownloadRequest],
                           onProgress: ((Int, Int, String) -> Void)?,
                           onTrackProgress: ((Double) -> Void)?) async -> DownloadOrchestrator.BatchResult {
            lock.lock()
            calls.append(requests.map(\.trackId))
            let hold = holdFirst
            holdFirst = false
            lock.unlock()
            if hold {
                await withCheckedContinuation { continuation in
                    lock.lock(); gate = continuation; lock.unlock()
                }
            }
            return result(requests.map(\.trackId))
        }
    }

    private struct QuietPersister: DownloadTrackPersisting {
        func markAsDownloaded(trackId: Int64, organizedPath: String, format: String, bitrate: Int?,
                              downloadStatus: String?) async throws {}
        func persistDownloadFailure(trackId: Int64, reason: String, date: Date, minimumAttempts: Int) async throws -> TrackDownloadFailure {
            TrackDownloadFailure(reason: reason, date: date, attempts: minimumAttempts)
        }
    }

    private func track(_ id: Int64) -> Track {
        var track = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "mp3",
                          originalPath: "https://soundcloud.com/artist/t\(id)")
        track.id = id
        return track
    }

    private func allDownloaded(_ ids: [Int64]) -> DownloadOrchestrator.BatchResult {
        DownloadOrchestrator.BatchResult(succeeded: ids.count,
                                         downloadedPaths: Dictionary(uniqueKeysWithValues: ids.map { ($0, "/lib/\($0).mp3") }))
    }

    @Test func aSecondBatchQueuesBehindTheFirstInsteadOfBeingRejected() async throws {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = GatedRunner(holdFirst: true, result: allDownloaded)
        let vm = DownloadViewModel(trackPersister: QuietPersister(), activity: center)
        vm.batchRunnerOverride = runner

        let first = Task { await vm.downloadTracks([track(1), track(2)], context: .playlist(9, name: "Liked on SoundCloud")) }
        while !runner.isHeld { await Task.yield() }
        let second = Task { await vm.downloadTracks([track(3)]) }
        while center.activeOperations.count < 2 { await Task.yield() }

        let queued = try #require(center.activeOperations.last)
        #expect(queued.state == .queued)
        #expect(ActivityPresentation.activeLine(queued) == "Starts after “Liked on SoundCloud” · 1 track")
        #expect(runner.callCount == 1, "the second batch must wait, not run alongside")
        let running = try #require(center.activeOperations.first)
        #expect(running.controls.cancelStyle.title == "Cancel After This Track")
        #expect(running.title == "Import “Liked on SoundCloud”")

        runner.release()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult?.succeeded == 2)
        #expect(secondResult?.succeeded == 1, "each caller reads its own batch's numbers")
        #expect(runner.callCount == 2)
        #expect(center.activeOperations.isEmpty)
        #expect(center.finishedOperations.map(\.state) == [.completed, .completed])
    }

    @Test func cancellingTheQueuedBatchNeverRunsIt() async throws {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = GatedRunner(holdFirst: true, result: allDownloaded)
        let vm = DownloadViewModel(trackPersister: QuietPersister(), activity: center)
        vm.batchRunnerOverride = runner

        let first = Task { await vm.downloadTracks([track(1)]) }
        while !runner.isHeld { await Task.yield() }
        let second = Task { await vm.downloadTracks([track(2)]) }
        while center.activeOperations.count < 2 { await Task.yield() }
        let queuedID = try #require(center.activeOperations.last?.id)
        center.cancel(queuedID)
        #expect(await second.value == nil)
        runner.release()
        _ = await first.value
        #expect(runner.callCount == 1)
        #expect(center.operation(id: queuedID)?.state == .cancelled)
    }

    @Test func failuresAreGroupedByPlainCause() async throws {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let vm = DownloadViewModel(trackPersister: QuietPersister(), activity: center)
        vm.batchRunnerOverride = GatedRunner(holdFirst: false) { _ in
            DownloadOrchestrator.BatchResult(
                succeeded: 1, failed: 3, downloadedPaths: [1: "/lib/1.mp3"], failedTrackIds: [2, 3, 4],
                failureReasons: [2: "Authentication expired — re-authorize and retry",
                                 3: "Authentication expired — re-authorize and retry",
                                 4: "Video unavailable"])
        }
        await vm.downloadTracks([1, 2, 3, 4].map(track))
        let op = try #require(center.finishedOperations.first)
        #expect(op.state == .completed)
        #expect(op.needsAttention)
        #expect(ActivityPresentation.resultText(op) == "1 downloaded · 3 failed")
        // Never `Video unavailable` for a SoundCloud track (PP-ACTIVITY-06, IMP-029).
        #expect(op.result?.failureGroups.map(\.cause) == ["Sign-in expired (SoundCloud)", "No match found on any source"])
        #expect(op.result?.items.count == 4)
    }

    @Test func driveLossIsAWaitNotAFailure() {
        let result = DownloadOrchestrator.BatchResult(
            succeeded: 1, failed: 3, downloadedPaths: [1: "/x"], failedTrackIds: [2, 3, 4],
            failureReasons: [2: "“Lexxar” not connected", 3: "“Lexxar” not connected", 4: "Library folder not reachable"])
        let (cleaned, waiting) = DownloadViewModel.separatingDriveWaits(result)
        #expect(waiting == [2, 3])
        #expect(cleaned.failedTrackIds == [4], "a folder that isn't writable on a present disk still fails")
        #expect(cleaned.failed == 1)
        #expect(cleaned.failureReasons[2] == nil)
    }
}
