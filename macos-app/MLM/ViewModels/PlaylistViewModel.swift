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

    /// Download health indexed by playlist ID for the card grid.
    private(set) var downloadStatusesByID: [Int64: PlaylistDownloadStatus] = [:]

    /// Sources indexed by their database identity for linked playlist labels.
    /// Loaded once per playlist snapshot to avoid one query per card.
    private(set) var sourcesByID: [Int64: Source] = [:]

    /// Whether data is loading.
    private(set) var isLoading = false

    /// Error message from the last failed operation.
    private(set) var errorMessage: String?

    /// Transient hint message for pin-limit violations (Phase 36 D-10).
    /// Auto-clears 3 seconds after `togglePin` hard-blocks the 9th pin.
    /// Read by `PlaylistsView` banner; written here and from the scheduled
    /// auto-clear `Task`. Not `private(set)` so the auto-clear closure can
    /// reset it without going through a setter method.
    var pinLimitHintMessage: String?

    /// Transient error message for rejected cover drops (UI-SPEC line 174).
    /// Auto-clears 4 seconds after `flagCoverDropRejected()` is called.
    /// Read by `PlaylistsView` banner; written from `flagCoverDropRejected()`
    /// and its scheduled auto-clear `Task`.
    var coverDropErrorMessage: String?

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
    private let sourceRepository: SourceRepository

    // MARK: - Init

    init(
        playlistRepository: PlaylistRepository,
        sourceRepository: SourceRepository
    ) {
        self.playlistRepository = playlistRepository
        self.sourceRepository = sourceRepository
    }

    // MARK: - Load

    /// Load all playlists and their track counts from the database.
    @MainActor
    func loadPlaylists() async {
        isLoading = true
        errorMessage = nil

        do {
            playlists = try await playlistRepository.fetchAll()

            // Resolve every card's source from one authoritative sources-table snapshot.
            let sources = try await sourceRepository.fetchAll()
            sourcesByID = Dictionary(
                uniqueKeysWithValues: sources.compactMap { source in
                    source.id.map { ($0, source) }
                }
            )

            // Fetch track counts for each playlist
            var counts: [Int64: Int] = [:]
            for playlist in playlists {
                if let id = playlist.id {
                    counts[id] = try await playlistRepository.trackCount(playlistId: id)
                }
            }
            trackCounts = counts

            let statuses = try await playlistRepository.fetchDownloadStatuses()
            downloadStatusesByID = Dictionary(
                uniqueKeysWithValues: statuses.map { ($0.playlistID, $0) }
            )

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

    /// Refreshes only persisted download health for an active batch. The grid
    /// uses this to publish a concrete change notification after the database
    /// transition is observable, rather than predicting a new aggregate when
    /// a download is merely requested.
    @MainActor
    func refreshDownloadHealth() async {
        do {
            let statuses = try await playlistRepository.fetchDownloadStatuses()
            let updatedStatuses = Dictionary(
                uniqueKeysWithValues: statuses.map { ($0.playlistID, $0) }
            )
            guard updatedStatuses != downloadStatusesByID else { return }
            downloadStatusesByID = updatedStatuses
            NotificationCenter.default.post(name: .downloadStateDidChange, object: nil)
        } catch {
            // The next full refresh will surface a database error. Avoid
            // replacing otherwise usable card health with a polling failure.
        }
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
    ///
    /// D-10: Soft limit of 8 pinned playlists. The 9th attempt is hard-blocked
    /// and surfaces `pinLimitHintMessage` for 3 seconds. Unpins are never
    /// blocked.
    ///
    /// On a successful pin/unpin, posts `.playlistDidChange` so the Sidebar
    /// pinned-disclosure (Plan 04) refreshes. The repo's `togglePin` itself
    /// does not emit the notification — only the higher-level mutators do.
    @MainActor
    func togglePin(id: Int64) async {
        guard let target = playlists.first(where: { $0.id == id }) else { return }
        let willPin = target.isPinned == 0

        if willPin {
            let pinnedCount = playlists.filter { $0.isPinned == 1 }.count
            if pinnedCount >= 8 {
                pinLimitHintMessage = "Pinned limit reached"
                // Schedule auto-clear after 3 seconds (UI-SPEC line 241).
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.pinLimitHintMessage = nil
                }
                return  // hard block — no repo call, no notification
            }
        }

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

            // Sidebar pinned-disclosure observer needs this signal (Plan 04).
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to toggle pin: \(error.localizedDescription)"
        }
    }

    // MARK: - Cover-Drop Rejection (UI-SPEC line 174)

    /// Surface the drop-rejected banner for 4 seconds.
    ///
    /// Called by `PlaylistCard.handleDrop` when the dropped item provider
    /// has no loadable image data (non-image file, corrupt payload, etc.).
    @MainActor
    func flagCoverDropRejected() {
        coverDropErrorMessage = "Couldn't read that image. Try a PNG or JPEG file."
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.coverDropErrorMessage = nil
        }
    }

    /// Returns the authoritative source record for a linked playlist.
    /// A missing record intentionally produces no label rather than guessing
    /// the source from playlist metadata such as its title.
    func source(for playlist: Playlist) -> Source? {
        guard let sourceID = playlist.sourceId else { return nil }
        return sourcesByID[sourceID]
    }

    func downloadStatus(for playlist: Playlist) -> PlaylistDownloadStatus? {
        guard let playlistID = playlist.id else { return nil }
        return downloadStatusesByID[playlistID]
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
