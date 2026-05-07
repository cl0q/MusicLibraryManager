import Foundation
import GRDB

/// ViewModel for the Playlists grid — owns the list of playlists,
/// create/delete/pin operations, and search state.
///
/// Phase 6 implementation. Playlists are shown as a grid of cards
/// (pinned first, then alphabetical). The user can create new playlists
/// via ⌘N or the "+" button, rename inline, and delete.
@Observable
final class PlaylistViewModel {

    // MARK: - Published State

    /// All playlists, pinned first, then alphabetical.
    private(set) var playlists: [Playlist] = []

    /// Filtered playlists based on search query.
    private(set) var displayedPlaylists: [Playlist] = []

    /// Search query for filtering playlists.
    var searchQuery: String = "" {
        didSet { applyFilter() }
    }

    /// Track counts per playlist, keyed by playlist ID.
    private(set) var trackCounts: [Int64: Int] = [:]

    /// Whether data is loading.
    private(set) var isLoading = false

    /// Error message from the last failed operation.
    private(set) var errorMessage: String?

    /// Playlist currently being renamed (for inline editing).
    var renamingPlaylistID: Int64?

    /// Text for the rename field.
    var renameText: String = ""

    /// Whether the "New Playlist" sheet/popover is showing.
    var isShowingNewPlaylist = false

    /// Text for the new playlist name.
    var newPlaylistName: String = ""

    // MARK: - Dependencies

    private let playlistRepository: PlaylistRepository

    // MARK: - Init

    init(playlistRepository: PlaylistRepository) {
        self.playlistRepository = playlistRepository
    }

    // MARK: - Load

    /// Load all playlists and their track counts from the database.
    @MainActor
    func loadPlaylists() async {
        isLoading = true
        errorMessage = nil

        do {
            playlists = try await playlistRepository.fetchAll()

            // Fetch track counts for each playlist
            var counts: [Int64: Int] = [:]
            for playlist in playlists {
                if let id = playlist.id {
                    counts[id] = try await playlistRepository.trackCount(playlistId: id)
                }
            }
            trackCounts = counts

            applyFilter()
        } catch {
            errorMessage = "Failed to load playlists: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Refresh playlists from database (after external changes).
    @MainActor
    func refresh() async {
        await loadPlaylists()
    }

    // MARK: - Create

    /// Create a new playlist with the given name.
    ///
    /// - Parameter name: Playlist name (trimmed, must not be empty)
    @MainActor
    func createPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Playlist name cannot be empty"
            return
        }

        do {
            let playlist = try await playlistRepository.create(name: trimmed)
            playlists.insert(playlist, at: insertionIndex(for: playlist))
            trackCounts[playlist.id!] = 0
            applyFilter()

            // Notify other views
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to create playlist: \(error.localizedDescription)"
        }

        isShowingNewPlaylist = false
        newPlaylistName = ""
    }

    // MARK: - Delete

    /// Delete a playlist by ID.
    @MainActor
    func deletePlaylist(id: Int64) async {
        do {
            try await playlistRepository.delete(id: id)
            playlists.removeAll { $0.id == id }
            trackCounts.removeValue(forKey: id)
            applyFilter()

            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to delete playlist: \(error.localizedDescription)"
        }
    }

    // MARK: - Rename

    /// Start renaming a playlist — enters inline-edit mode.
    @MainActor
    func startRename(playlist: Playlist) {
        renamingPlaylistID = playlist.id
        renameText = playlist.name
    }

    /// Confirm the rename operation.
    @MainActor
    func confirmRename() async {
        guard let id = renamingPlaylistID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            renamingPlaylistID = nil
            return
        }

        do {
            try await playlistRepository.rename(id: id, name: trimmed)

            if let idx = playlists.firstIndex(where: { $0.id == id }) {
                playlists[idx].name = trimmed
            }
            applyFilter()

            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to rename playlist: \(error.localizedDescription)"
        }

        renamingPlaylistID = nil
    }

    /// Cancel rename without saving.
    @MainActor
    func cancelRename() {
        renamingPlaylistID = nil
        renameText = ""
    }

    // MARK: - Pin/Unpin

    /// Toggle the pin status of a playlist.
    @MainActor
    func togglePin(id: Int64) async {
        do {
            try await playlistRepository.togglePin(id: id)

            if let idx = playlists.firstIndex(where: { $0.id == id }) {
                playlists[idx].isPinned = playlists[idx].isPinned == 1 ? 0 : 1
            }

            // Re-sort: pinned first
            playlists.sort { a, b in
                if a.isPinned != b.isPinned {
                    return a.isPinned > b.isPinned
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            applyFilter()
        } catch {
            errorMessage = "Failed to toggle pin: \(error.localizedDescription)"
        }
    }

    // MARK: - Filtering

    /// Apply the search filter to the playlist list.
    private func applyFilter() {
        if searchQuery.isEmpty {
            displayedPlaylists = playlists
        } else {
            let query = searchQuery.lowercased()
            displayedPlaylists = playlists.filter {
                $0.name.lowercased().contains(query)
            }
        }
    }

    // MARK: - Helpers

    /// Find the correct insertion index for a new playlist (pinned first, then alphabetical).
    private func insertionIndex(for playlist: Playlist) -> Int {
        let pinnedEnd = playlists.firstIndex(where: { $0.isPinned == 0 }) ?? playlists.count

        if playlist.isPinned == 1 {
            // Insert among pinned, alphabetically
            return playlists[0..<pinnedEnd]
                .firstIndex { playlist.name.localizedCaseInsensitiveCompare($0.name) == .orderedAscending }
                ?? pinnedEnd
        } else {
            // Insert among unpinned, alphabetically
            return playlists[pinnedEnd...]
                .firstIndex { playlist.name.localizedCaseInsensitiveCompare($0.name) == .orderedAscending }
                ?? playlists.count
        }
    }
}
