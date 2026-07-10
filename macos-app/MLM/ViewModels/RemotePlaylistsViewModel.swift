import Foundation

/// ViewModel backing the remote-playlist browser (SoundCloud / Spotify / YouTube).
///
/// Flow:
/// 1. `loadPlaylists()` — fetch the user's playlists for browsing.
/// 2. `openPlaylist(_:)` / `importFromURL(_:)` — import into the DB and load
///    the ordered tracks for preview + selection.
/// 3. `download(selection:)` — apply the selection and hand the tracks to
///    `DownloadViewModel`, pinned to the provider's source.
@Observable
@MainActor
final class RemotePlaylistsViewModel {

    // MARK: - State

    private(set) var playlists: [RemotePlaylistSummary] = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var errorMessage: String?

    /// The playlist currently opened for preview.
    private(set) var selectedTitle: String?
    /// Ordered tracks of the opened playlist.
    private(set) var selectedTracks: [Track] = []

    // MARK: - Dependencies

    private let provider: RemotePlaylistProvider
    private let playlistRepository: PlaylistRepository
    private let downloadViewModel: DownloadViewModel

    // MARK: - Init

    init(
        provider: RemotePlaylistProvider,
        playlistRepository: PlaylistRepository,
        downloadViewModel: DownloadViewModel
    ) {
        self.provider = provider
        self.playlistRepository = playlistRepository
        self.downloadViewModel = downloadViewModel
    }

    // MARK: - Derived

    var displayName: String { provider.displayName }
    var allowsURLImport: Bool { provider.allowsURLImport }
    var downloadNote: String? { provider.downloadNote }

    /// Total duration (seconds) of the opened playlist's tracks.
    var selectedTotalDurationSeconds: Int {
        selectedTracks.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    // MARK: - Actions

    func loadPlaylists() async {
        guard !provider.allowsURLImport else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            playlists = try await provider.fetchPlaylists()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openPlaylist(_ summary: RemotePlaylistSummary) async {
        await loadTracks(title: summary.title) {
            try await self.provider.importPlaylist(summary)
        }
    }

    func importFromURL(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await loadTracks(title: "YouTube Playlist") {
            try await self.provider.importPlaylist(fromURL: trimmed)
        }
    }

    func closePlaylist() {
        selectedTitle = nil
        selectedTracks = []
    }

    func download(selection: RemotePlaylistSelection) async {
        let chosen = selection.apply(to: selectedTracks)
        guard !chosen.isEmpty else { return }
        await downloadViewModel.downloadTracks(chosen, preferredSource: provider.preferredSource)
    }

    /// Download an explicit set of tracks (the exact list previewed in the UI),
    /// pinned to the provider's source.
    func download(tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        await downloadViewModel.downloadTracks(tracks, preferredSource: provider.preferredSource)
    }

    // MARK: - Helpers

    private func loadTracks(title: String, importer: @escaping () async throws -> Int64?) async {
        isImporting = true
        errorMessage = nil
        selectedTitle = title
        selectedTracks = []
        defer { isImporting = false }
        do {
            guard let localId = try await importer() else {
                errorMessage = "Playlist konnte nicht importiert werden."
                return
            }
            // Adopt the real playlist name from the DB (e.g. the actual
            // YouTube playlist title resolved during import).
            if let playlist = try? await playlistRepository.fetch(id: localId),
               !playlist.name.isEmpty {
                selectedTitle = playlist.name
            }
            selectedTracks = try await playlistRepository.fetchTracks(playlistId: localId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
