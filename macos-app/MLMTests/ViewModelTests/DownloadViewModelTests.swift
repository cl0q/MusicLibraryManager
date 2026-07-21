import Testing
import Foundation
@testable import MLM

/// Coverage for SCDL-06/07: `DownloadViewModel` must only count a track as
/// succeeded once BOTH the file downloaded AND the DB write persisted, and
/// every queued item must reach a rendered terminal state — including the
/// LAST item in a batch, which the pre-fix `onProgress` callback never
/// terminalized on its own.
///
/// `DownloadOrchestrator` and `TrackRepository` are both `final class`
/// (VERIFIED) and cannot be subclassed, so these tests drive
/// `DownloadViewModel` through the narrow `DownloadBatchRunning` /
/// `DownloadTrackPersisting` protocol seams instead.
@Suite("DownloadViewModelTests")
@MainActor
struct DownloadViewModelTests {

    // MARK: - Fakes

    /// Scripted stand-in for `DownloadOrchestrator.downloadBatch`. Mirrors
    /// the real (pre-fix) `onProgress` contract — it marks the item BEFORE
    /// the current index `.downloading`→`.completed` transition but never
    /// emits a terminal callback for the very last item — so a passing test
    /// proves `DownloadViewModel` itself (not the fake) terminalizes every
    /// item after the batch returns.
    private struct FakeBatchRunner: DownloadBatchRunning {
        let result: DownloadOrchestrator.BatchResult

        func downloadBatch(
            _ requests: [DownloadOrchestrator.DownloadRequest],
            onProgress: ((Int, Int, String) -> Void)?,
            onTrackProgress: ((Double) -> Void)?
        ) async -> DownloadOrchestrator.BatchResult {
            for (index, request) in requests.enumerated() {
                onProgress?(index, requests.count, request.title)
            }
            return result
        }
    }

    private struct PersistFailure: Error {}

    /// Scripted stand-in for `TrackRepository.markAsDownloaded` — throws for
    /// a configured set of track IDs so tests can prove a DB-write failure
    /// demotes a track from succeeded to failed before the tally is final.
    private struct FakeThrowingPersister: DownloadTrackPersisting {
        let failingTrackIds: Set<Int64>

        func markAsDownloaded(
            trackId: Int64,
            organizedPath: String,
            format: String,
            bitrate: Int?,
            downloadStatus: String?
        ) async throws {
            if failingTrackIds.contains(trackId) {
                throw PersistFailure()
            }
        }
    }

    private final class FakeRetryRunner: DownloadRetryRunning {
        let requests: [DownloadOrchestrator.DownloadRequest]
        let result: DownloadOrchestrator.BatchResult
        private(set) var dequeuedTrackIds: Set<Int64> = []

        init(
            requests: [DownloadOrchestrator.DownloadRequest],
            result: DownloadOrchestrator.BatchResult
        ) {
            self.requests = requests
            self.result = result
        }

        func pendingRetryRequests() -> [DownloadOrchestrator.DownloadRequest] {
            requests
        }

        func retryFailed(
            onProgress: ((Int, Int, String) -> Void)?,
            onTrackProgress: ((Double) -> Void)?
        ) async -> DownloadOrchestrator.BatchResult {
            for (index, request) in requests.enumerated() {
                onProgress?(
                    index,
                    requests.count,
                    "\(request.artist) - \(request.title)"
                )
            }
            return result
        }

        func dequeuePersistedRetries(trackIds: Set<Int64>) {
            dequeuedTrackIds.formUnion(trackIds)
        }
    }

    // MARK: - Helpers

    /// A remote (no local file) track with an explicit, distinct `id` and a
    /// SoundCloud `originalPath` so `downloadTracks` resolves its permalink
    /// without needing a `SourceRepository`.
    private func makeRemoteTrack(id: Int64, title: String = "Title") -> Track {
        var track = Track(
            artist: "Artist",
            album: "Album",
            title: title,
            format: "mp3",
            originalPath: "https://soundcloud.com/artist/\(title)"
        )
        track.id = id
        return track
    }

    // MARK: - Tests

    @Test func persistFailureDemotesTrackFromSucceededToFailed() async throws {
        let vm = DownloadViewModel(trackPersister: FakeThrowingPersister(failingTrackIds: [2]))
        vm.batchRunnerOverride = FakeBatchRunner(
            result: DownloadOrchestrator.BatchResult(
                succeeded: 2,
                failed: 0,
                skipped: 0,
                downloadedPaths: [1: "/lib/1.mp3", 2: "/lib/2.mp3"],
                downloadedMetadata: [:]
            )
        )

        let tracks = [makeRemoteTrack(id: 1), makeRemoteTrack(id: 2)]
        await vm.downloadTracks(tracks)

        // The file-level BatchResult said both succeeded — the DB write
        // for track 2 failed, so the FINAL tally must demote it.
        #expect(vm.completedCount == 1)
        #expect(vm.failedCount == 1)

        let failedItem = vm.queueItems.first { $0.trackId == 2 }
        #expect(failedItem?.status == .failed)
        #expect(failedItem?.error == "downloaded but not saved to library")

        let succeededItem = vm.queueItems.first { $0.trackId == 1 }
        #expect(succeededItem?.status == .completed)
        #expect(succeededItem?.error == nil)
    }

    @Test func lastItemInBatchReachesTerminalState() async throws {
        let vm = DownloadViewModel(trackPersister: FakeThrowingPersister(failingTrackIds: []))
        vm.batchRunnerOverride = FakeBatchRunner(
            result: DownloadOrchestrator.BatchResult(
                succeeded: 3,
                failed: 0,
                skipped: 0,
                downloadedPaths: [1: "/lib/1.mp3", 2: "/lib/2.mp3", 3: "/lib/3.mp3"],
                downloadedMetadata: [:]
            )
        )

        let tracks = [makeRemoteTrack(id: 1), makeRemoteTrack(id: 2), makeRemoteTrack(id: 3)]
        await vm.downloadTracks(tracks)

        #expect(vm.queueItems.count == 3)
        #expect(vm.queueItems.last?.status == .completed)
        #expect(vm.queueItems.last?.status != .downloading)
    }

    @Test func everyItemReachesATerminalStateAfterABatch() async throws {
        let vm = DownloadViewModel(trackPersister: FakeThrowingPersister(failingTrackIds: [2]))
        vm.batchRunnerOverride = FakeBatchRunner(
            result: DownloadOrchestrator.BatchResult(
                succeeded: 2,
                failed: 1,
                skipped: 0,
                // Tracks 1 and 2 reached the persistence step (2 is later
                // demoted by the throwing persister); track 3's download
                // stage itself failed, so it never appears here at all.
                downloadedPaths: [1: "/lib/1.mp3", 2: "/lib/2.mp3"],
                downloadedMetadata: [:]
            )
        )

        let tracks = [makeRemoteTrack(id: 1), makeRemoteTrack(id: 2), makeRemoteTrack(id: 3)]
        await vm.downloadTracks(tracks)

        #expect(vm.queueItems.count == 3)
        for item in vm.queueItems {
            #expect(item.status == .completed || item.status == .failed)
        }

        let downloadFailedItem = vm.queueItems.first { $0.trackId == 3 }
        #expect(downloadFailedItem?.status == .failed)
        #expect(downloadFailedItem?.error == "download failed")

        #expect(vm.completedCount == 1)
        #expect(vm.failedCount == 2)
    }

    @Test func skippedAndCancelledItemsKeepDistinctTerminalStates() async throws {
        let vm = DownloadViewModel(trackPersister: FakeThrowingPersister(failingTrackIds: []))
        vm.batchRunnerOverride = FakeBatchRunner(
            result: DownloadOrchestrator.BatchResult(
                succeeded: 0,
                failed: 0,
                skipped: 1,
                downloadedPaths: [:],
                failedTrackIds: [],
                skippedTrackIds: [1],
                cancelledTrackIds: [2],
                downloadedMetadata: [:]
            )
        )

        await vm.downloadTracks([
            makeRemoteTrack(id: 1),
            makeRemoteTrack(id: 2),
        ])

        #expect(vm.queueItems.first { $0.trackId == 1 }?.status == .skipped)
        #expect(vm.queueItems.first { $0.trackId == 2 }?.status == .cancelled)
        #expect(vm.queueItems.first { $0.trackId == 2 }?.error == "download cancelled")
    }

    @Test func successfulRetryPersistsBeforeDequeuing() async {
        let vm = DownloadViewModel(
            trackPersister: FakeThrowingPersister(failingTrackIds: [])
        )
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 7,
            artist: "Artist",
            title: "Retry",
            query: "Artist - Retry",
            soundcloudURL: "https://soundcloud.com/artist/retry",
            userId: nil,
            preferredSource: .soundcloud
        )
        let runner = FakeRetryRunner(
            requests: [request],
            result: DownloadOrchestrator.BatchResult(
                succeeded: 1,
                downloadedPaths: [7: "/library/retry.m4a"],
                downloadedMetadata: [:]
            )
        )
        vm.retryRunnerOverride = runner

        await vm.retryFailed()

        #expect(runner.dequeuedTrackIds == [7])
        #expect(vm.completedCount == 1)
        #expect(vm.failedCount == 0)
        #expect(vm.queueItems.first?.status == .completed)
    }

    @Test func retryPersistenceFailureRemainsQueuedAndReportsFailure() async {
        let vm = DownloadViewModel(
            trackPersister: FakeThrowingPersister(failingTrackIds: [8])
        )
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: 8,
            artist: "Artist",
            title: "Retry Failure",
            query: "Artist - Retry Failure",
            soundcloudURL: "https://soundcloud.com/artist/retry-failure",
            userId: nil,
            preferredSource: .soundcloud
        )
        let runner = FakeRetryRunner(
            requests: [request],
            result: DownloadOrchestrator.BatchResult(
                succeeded: 1,
                downloadedPaths: [8: "/library/retry-failure.m4a"],
                downloadedMetadata: [:]
            )
        )
        vm.retryRunnerOverride = runner

        await vm.retryFailed()

        #expect(runner.dequeuedTrackIds.isEmpty)
        #expect(vm.completedCount == 0)
        #expect(vm.failedCount == 1)
        #expect(vm.queueItems.first?.status == .failed)
        #expect(
            vm.queueItems.first?.error
                == "downloaded but not saved to library"
        )
    }
}
