import Foundation

/// ViewModel for browsing a remote source, staging a playlist preview, and
/// committing only the references the user explicitly selected.
@Observable
@MainActor
final class RemotePlaylistsViewModel {

    // MARK: - State

    private(set) var playlists: [RemotePlaylistSummary] = []
    private(set) var isLoading = false
    private(set) var isPreviewLoading = false
    private(set) var isPersisting = false
    private(set) var errorMessage: String?
    private(set) var preview: RemotePlaylistPreview?
    private(set) var importResult: RemotePlaylistImportResult?

    // MARK: - Dependencies

    private let provider: RemotePlaylistProvider
    private let downloadViewModel: DownloadViewModel

    // MARK: - Init

    init(
        provider: RemotePlaylistProvider,
        downloadViewModel: DownloadViewModel
    ) {
        self.provider = provider
        self.downloadViewModel = downloadViewModel
    }

    // MARK: - Derived

    var displayName: String { provider.displayName }
    var browseMode: RemotePlaylistBrowseMode { provider.browseMode }
    var showsURLField: Bool { provider.browseMode != .accountPlaylists }
    var showsPlaylistList: Bool { provider.browseMode != .urlOnly }
    /// Transitional shim — Module 5 removes this once the view migrates to `browseMode`.
    var allowsURLImport: Bool { provider.browseMode == .urlOnly }
    var downloadNote: String? { provider.downloadNote }
    var selectedTitle: String? { preview?.title }
    var selectedTracks: [RemotePlaylistTrack] { preview?.tracks ?? [] }
    var isDownloading: Bool { downloadViewModel.isDownloading }
    var downloadCompletedCount: Int { downloadViewModel.completedCount }
    var downloadTotalCount: Int { downloadViewModel.totalCount }
    var downloadProgress: Double { downloadViewModel.progress }
    var failedDownloadItems: [DownloadItem] {
        downloadViewModel.queueItems.filter { $0.status == .failed }
    }
    var shouldOfferSettings: Bool {
        errorMessage == "yt-dlp not installed — open Settings"
    }

    // MARK: - Actions

    func loadPlaylists() async {
        guard provider.browseMode != .urlOnly else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            playlists = try await provider.fetchPlaylists()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func openPlaylist(_ summary: RemotePlaylistSummary) async {
        await loadPreview {
            try await self.provider.fetchPreview(for: summary)
        }
    }

    func importFromURL(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await loadPreview {
            try await self.provider.fetchPreview(fromURL: trimmed)
        }
    }

    func closePlaylist() {
        preview = nil
        importResult = nil
        errorMessage = nil
    }

    /// Save only the exact rows currently shown in the review list.
    func save(tracks: [RemotePlaylistTrack]) async {
        guard let persistence = await persist(tracks: tracks) else { return }
        importResult = RemotePlaylistImportResult(
            playlistID: persistence.playlistID,
            selectedTrackCount: tracks.count,
            downloadedCount: 0,
            failedCount: 0,
            didDownload: false
        )
    }

    /// Persist the exact reviewed rows before handing those durable records to
    /// the existing download pipeline.
    ///
    /// Incremental sync: only tracks with `organizedPath == nil` (not yet
    /// downloaded) are sent to the download pipeline. Already-downloaded
    /// tracks are skipped — this is how re-importing a grown playlist
    /// (e.g. 3 → 5 tracks) only downloads the 2 new ones.
    func download(tracks: [RemotePlaylistTrack]) async {
        guard let persistence = await persist(tracks: tracks) else { return }

        // Filter to only tracks that haven't been downloaded yet
        let newTracks = persistence.tracks.filter { $0.organizedPath == nil }

        if newTracks.isEmpty {
            // All tracks already downloaded — just update the import result
            importResult = RemotePlaylistImportResult(
                playlistID: persistence.playlistID,
                selectedTrackCount: tracks.count,
                downloadedCount: 0,
                failedCount: 0,
                didDownload: false
            )
            return
        }

        await downloadViewModel.downloadTracks(
            newTracks,
            preferredSource: provider.preferredSource
        )
        let result = downloadViewModel.lastResult
        importResult = RemotePlaylistImportResult(
            playlistID: persistence.playlistID,
            selectedTrackCount: tracks.count,
            downloadedCount: result?.succeeded ?? 0,
            failedCount: result?.failed ?? 0,
            didDownload: true
        )
    }

    /// One-tap "Download All" over the whole staged preview.
    func downloadAll() async {
        await download(tracks: selectedTracks)
    }

    func cancelDownload() {
        downloadViewModel.cancel()
    }

    func userFacingDownloadFailure(for item: DownloadItem) -> String {
        let error = NSError(
            domain: "RemotePlaylistImport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: item.error ?? "Video unavailable"]
        )
        return DownloadOrchestrator.DownloadFailureReason
            .failureReason(for: error)
            .userFacingText
    }

    // MARK: - Helpers

    private func loadPreview(
        fetcher: @escaping () async throws -> RemotePlaylistPreview
    ) async {
        isPreviewLoading = true
        errorMessage = nil
        preview = nil
        importResult = nil
        defer { isPreviewLoading = false }
        do {
            preview = try await fetcher()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    private func persist(
        tracks: [RemotePlaylistTrack]
    ) async -> RemotePlaylistPersistence? {
        guard let preview,
              !tracks.isEmpty,
              Set(tracks).isSubset(of: Set(preview.tracks)) else {
            return nil
        }
        isPersisting = true
        errorMessage = nil
        defer { isPersisting = false }
        do {
            return try await provider.persist(preview: preview, selectedTracks: tracks)
        } catch {
            errorMessage = userFacingMessage(for: error)
            return nil
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let providerError = error as? RemotePlaylistProviderError,
           let message = providerError.errorDescription {
            return message
        }
        return DownloadOrchestrator.DownloadFailureReason
            .failureReason(for: error)
            .userFacingText
    }
}
