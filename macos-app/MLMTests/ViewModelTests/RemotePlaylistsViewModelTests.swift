import Foundation
import Testing
@testable import MLM

@Suite("RemotePlaylistsViewModelTests")
@MainActor
struct RemotePlaylistsViewModelTests {

    private final class FakeProvider: RemotePlaylistProvider {
        let displayName = "YouTube"
        let preferredSource: DownloadOrchestrator.PreferredSource = .youtube
        let allowsURLImport = true
        let preview: RemotePlaylistPreview

        private(set) var fetchedURLs: [String] = []
        private(set) var persistedSelections: [[RemotePlaylistTrack]] = []

        init(preview: RemotePlaylistPreview) {
            self.preview = preview
        }

        func fetchPreview(for summary: RemotePlaylistSummary) async throws -> RemotePlaylistPreview {
            preview
        }

        func fetchPreview(fromURL url: String) async throws -> RemotePlaylistPreview {
            fetchedURLs.append(url)
            return preview
        }

        func persist(
            preview: RemotePlaylistPreview,
            selectedTracks: [RemotePlaylistTrack]
        ) async throws -> RemotePlaylistPersistence {
            persistedSelections.append(selectedTracks)
            let tracks = selectedTracks.enumerated().map { index, remoteTrack in
                var track = remoteTrack.unresolvedTrack()
                // The test handoff asserts these IDs reach DownloadViewModel.
                track.id = Int64(101 + index)
                return track
            }
            return RemotePlaylistPersistence(playlistID: 77, tracks: tracks)
        }
    }

    private struct SuccessfulPersister: DownloadTrackPersisting {
        func markAsDownloaded(
            trackId: Int64,
            organizedPath: String,
            format: String,
            bitrate: Int?,
            downloadStatus: String?
        ) async throws {}

        func persistDownloadFailure(
            trackId: Int64,
            reason: String,
            date: Date,
            minimumAttempts: Int
        ) async throws -> TrackDownloadFailure {
            TrackDownloadFailure(reason: reason, date: date, attempts: minimumAttempts)
        }
    }

    private final class RecordingBatchRunner: DownloadBatchRunning {
        private(set) var receivedRequests: [DownloadOrchestrator.DownloadRequest] = []

        func downloadBatch(
            _ requests: [DownloadOrchestrator.DownloadRequest],
            onProgress: ((Int, Int, String) -> Void)?,
            onTrackProgress: ((Double) -> Void)?
        ) async -> DownloadOrchestrator.BatchResult {
            receivedRequests = requests
            for (index, request) in requests.enumerated() {
                onProgress?(index, requests.count, request.title)
            }
            return DownloadOrchestrator.BatchResult(
                succeeded: requests.count,
                downloadedPaths: Dictionary(
                    uniqueKeysWithValues: requests.map { request in
                        (request.trackId, "/library/\(request.trackId).m4a")
                    }
                )
            )
        }
    }

    private func makePreview() -> RemotePlaylistPreview {
        RemotePlaylistPreview(
            sourceName: "YouTube",
            externalID: "playlist-1",
            title: "Review Mix",
            tracks: [
                RemotePlaylistTrack(
                    externalID: "video-1",
                    title: "First track",
                    artist: "Artist",
                    album: "YouTube",
                    durationSeconds: 180,
                    format: "youtube",
                    originalPath: "https://youtube.example/video-1"
                ),
                RemotePlaylistTrack(
                    externalID: "video-2",
                    title: "Second track",
                    artist: "Artist",
                    album: "YouTube",
                    durationSeconds: 210,
                    format: "youtube",
                    originalPath: "https://youtube.example/video-2"
                ),
                RemotePlaylistTrack(
                    externalID: "video-3",
                    title: "Third track",
                    artist: "Artist",
                    album: "YouTube",
                    durationSeconds: 240,
                    format: "youtube",
                    originalPath: "https://youtube.example/video-3"
                ),
            ]
        )
    }

    @Test func loadingURLStagesPreviewWithoutPersistence() async {
        let provider = FakeProvider(preview: makePreview())
        let viewModel = RemotePlaylistsViewModel(
            provider: provider,
            downloadViewModel: DownloadViewModel()
        )

        await viewModel.importFromURL(" https://youtube.example/playlist ")

        #expect(provider.fetchedURLs == ["https://youtube.example/playlist"])
        #expect(provider.persistedSelections.isEmpty)
        #expect(viewModel.selectedTitle == "Review Mix")
        #expect(viewModel.selectedTracks.map(\.externalID) == ["video-1", "video-2", "video-3"])
    }

    @Test func saveOnlyPersistsOnlyTheReviewedSelection() async {
        let provider = FakeProvider(preview: makePreview())
        let downloadViewModel = DownloadViewModel()
        let viewModel = RemotePlaylistsViewModel(
            provider: provider,
            downloadViewModel: downloadViewModel
        )
        await viewModel.importFromURL("https://youtube.example/playlist")

        let selected = [viewModel.selectedTracks[1]]
        await viewModel.save(tracks: selected)

        #expect(provider.persistedSelections == [selected])
        #expect(viewModel.importResult?.playlistID == 77)
        #expect(viewModel.importResult?.didDownload == false)
        #expect(viewModel.importResult?.selectedTrackCount == 1)
        #expect(downloadViewModel.queueItems.isEmpty)
        #expect(downloadViewModel.lastResult == nil)
    }

    @Test func downloadPersistsReviewedSelectionBeforeDownloadHandoff() async {
        let provider = FakeProvider(preview: makePreview())
        let batchRunner = RecordingBatchRunner()
        let downloadViewModel = DownloadViewModel(trackPersister: SuccessfulPersister())
        downloadViewModel.batchRunnerOverride = batchRunner
        let viewModel = RemotePlaylistsViewModel(
            provider: provider,
            downloadViewModel: downloadViewModel
        )
        await viewModel.importFromURL("https://youtube.example/playlist")

        let selected = [viewModel.selectedTracks[0], viewModel.selectedTracks[2]]
        await viewModel.download(tracks: selected)

        #expect(provider.persistedSelections == [selected])
        #expect(batchRunner.receivedRequests.map(\.trackId) == [101, 102])
        #expect(batchRunner.receivedRequests.map(\.title) == ["First track", "Third track"])
        #expect(viewModel.importResult?.didDownload == true)
        #expect(viewModel.importResult?.downloadedCount == 2)
        #expect(viewModel.importResult?.failedCount == 0)
    }
}
