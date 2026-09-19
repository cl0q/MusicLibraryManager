import Foundation
import Testing
@testable import MLM

@Suite("RemotePlaylistsViewModelTests")
@MainActor
struct RemotePlaylistsViewModelTests {

    private final class FakeProvider: RemotePlaylistProvider {
        let displayName = "YouTube"
        let preferredSource: DownloadOrchestrator.PreferredSource = .youtube
        let browseMode: RemotePlaylistBrowseMode
        let preview: RemotePlaylistPreview
        let summaries: [RemotePlaylistSummary]

        private(set) var fetchedURLs: [String] = []
        private(set) var persistedSelections: [[RemotePlaylistTrack]] = []
        private(set) var fetchPlaylistsCallCount = 0

        init(
            preview: RemotePlaylistPreview,
            browseMode: RemotePlaylistBrowseMode = .urlOnly,
            summaries: [RemotePlaylistSummary] = []
        ) {
            self.preview = preview
            self.browseMode = browseMode
            self.summaries = summaries
        }

        func fetchPlaylists() async throws -> [RemotePlaylistSummary] {
            fetchPlaylistsCallCount += 1
            return summaries
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

    // MARK: - Browse mode tests

    @Test func soundCloudModeShowsBothURLFieldAndPlaylistList() async {
        let provider = FakeProvider(preview: makePreview(), browseMode: .accountPlaylistsAndURL)
        let viewModel = RemotePlaylistsViewModel(provider: provider, downloadViewModel: DownloadViewModel())

        #expect(viewModel.showsURLField == true)
        #expect(viewModel.showsPlaylistList == true)
    }

    @Test func accountPlaylistsModeHidesURLField() async {
        let provider = FakeProvider(preview: makePreview(), browseMode: .accountPlaylists)
        let viewModel = RemotePlaylistsViewModel(provider: provider, downloadViewModel: DownloadViewModel())

        #expect(viewModel.showsURLField == false)
        #expect(viewModel.showsPlaylistList == true)
    }

    @Test func urlOnlyModeHidesPlaylistList() async {
        let provider = FakeProvider(preview: makePreview(), browseMode: .urlOnly)
        let viewModel = RemotePlaylistsViewModel(provider: provider, downloadViewModel: DownloadViewModel())

        #expect(viewModel.showsURLField == true)
        #expect(viewModel.showsPlaylistList == false)
    }

    @Test func loadPlaylistsIsSkippedInURLOnlyMode() async {
        let provider = FakeProvider(preview: makePreview(), browseMode: .urlOnly)
        let viewModel = RemotePlaylistsViewModel(provider: provider, downloadViewModel: DownloadViewModel())

        await viewModel.loadPlaylists()

        #expect(provider.fetchPlaylistsCallCount == 0)
    }

    @Test func loadPlaylistsRunsInAccountPlaylistsAndURLMode() async {
        let summaries = [
            RemotePlaylistSummary(id: "1", title: "Alpha", trackCount: 5),
            RemotePlaylistSummary(id: "2", title: "Beta", trackCount: 10),
        ]
        let provider = FakeProvider(
            preview: makePreview(),
            browseMode: .accountPlaylistsAndURL,
            summaries: summaries
        )
        let viewModel = RemotePlaylistsViewModel(provider: provider, downloadViewModel: DownloadViewModel())

        await viewModel.loadPlaylists()

        #expect(provider.fetchPlaylistsCallCount == 1)
        #expect(viewModel.playlists.count == 2)
    }

    @Test func downloadAllPersistsAndDownloadsEveryStagedTrack() async {
        let provider = FakeProvider(preview: makePreview())
        let batchRunner = RecordingBatchRunner()
        let downloadViewModel = DownloadViewModel(trackPersister: SuccessfulPersister())
        downloadViewModel.batchRunnerOverride = batchRunner
        let viewModel = RemotePlaylistsViewModel(
            provider: provider,
            downloadViewModel: downloadViewModel
        )
        await viewModel.importFromURL("https://youtube.example/playlist")

        await viewModel.downloadAll()

        #expect(provider.persistedSelections.count == 1)
        #expect(provider.persistedSelections[0].count == 3)
        #expect(provider.persistedSelections[0].map(\.externalID) == ["video-1", "video-2", "video-3"])
        #expect(batchRunner.receivedRequests.count == 3)
        #expect(viewModel.importResult?.didDownload == true)
        #expect(viewModel.importResult?.selectedTrackCount == 3)
    }

    @Test func allowsURLImportShimIsTrueOnlyForURLOnlyMode() async {
        let urlOnly = FakeProvider(preview: makePreview(), browseMode: .urlOnly)
        #expect(RemotePlaylistsViewModel(provider: urlOnly, downloadViewModel: DownloadViewModel()).allowsURLImport == true)

        let accountOnly = FakeProvider(preview: makePreview(), browseMode: .accountPlaylists)
        #expect(RemotePlaylistsViewModel(provider: accountOnly, downloadViewModel: DownloadViewModel()).allowsURLImport == false)

        let both = FakeProvider(preview: makePreview(), browseMode: .accountPlaylistsAndURL)
        #expect(RemotePlaylistsViewModel(provider: both, downloadViewModel: DownloadViewModel()).allowsURLImport == false)
    }

    @Test func playlistSummariesExposePrivacy() async {
        let summaries = [
            RemotePlaylistSummary(id: "1", title: "Public", trackCount: 5, isPrivate: false),
            RemotePlaylistSummary(id: "2", title: "Private", trackCount: 3, isPrivate: true),
        ]
        let provider = FakeProvider(
            preview: makePreview(),
            browseMode: .accountPlaylistsAndURL,
            summaries: summaries
        )
        let viewModel = RemotePlaylistsViewModel(provider: provider, downloadViewModel: DownloadViewModel())

        await viewModel.loadPlaylists()

        #expect(viewModel.playlists.count == 2)
        #expect(viewModel.playlists[0].isPrivate == false)
        #expect(viewModel.playlists[1].isPrivate == true)
    }
}
