import Foundation
import GRDB

/// ViewModel for a single playlist's detail view — track list,
/// drag-and-drop reorder, add/remove tracks, import from M3U.
///
/// Phase 6 implementation. Uses fractional positioning (string-based)
/// for O(1) reorder without renumbering the entire list — matching the
/// Tauri app's `commands/playlist.rs` approach.
@Observable
final class PlaylistDetailViewModel {

    // MARK: - Published State

    /// The playlist being viewed.
    private(set) var playlist: Playlist

    /// Tracks in the playlist, ordered by position.
    private(set) var tracks: [Track] = []

    /// Whether tracks are loading.
    private(set) var isLoading = false

    /// Error message from the last failed operation.
    private(set) var errorMessage: String?

    /// Search query for filtering tracks within the playlist.
    var searchQuery: String = "" {
        didSet { applyFilter() }
    }

    /// Filtered tracks based on search query.
    private(set) var displayedTracks: [Track] = []

    /// Selected track IDs for multi-select operations.
    var selectedTrackIDs: Set<Int64> = []

    // MARK: - Dependencies

    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository

    // MARK: - Init

    init(playlist: Playlist, playlistRepository: PlaylistRepository, trackRepository: TrackRepository) {
        self.playlist = playlist
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
    }

    // MARK: - Load

    /// Load all tracks for this playlist, ordered by position.
    @MainActor
    func loadTracks() async {
        guard let playlistId = playlist.id else { return }

        isLoading = true
        errorMessage = nil

        do {
            tracks = try await playlistRepository.fetchTracks(playlistId: playlistId)
            applyFilter()
        } catch {
            errorMessage = "Failed to load tracks: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Refresh tracks (after external changes).
    @MainActor
    func refresh() async {
        await loadTracks()
    }

    // MARK: - Add Tracks

    /// Add tracks to the playlist at the end.
    ///
    /// Generates fractional positions after the last track.
    ///
    /// - Parameter trackIds: IDs of tracks to add
    @MainActor
    func addTracks(_ trackIds: [Int64]) async {
        guard let playlistId = playlist.id else { return }

        // Generate position after the last track
        let nextPosition = generateNextPosition()

        do {
            try await playlistRepository.addTracks(
                playlistId: playlistId,
                trackIds: trackIds,
                startPosition: nextPosition
            )
            await loadTracks()

            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to add tracks: \(error.localizedDescription)"
        }
    }

    // MARK: - Remove Tracks

    /// Remove selected tracks from the playlist.
    @MainActor
    func removeSelectedTracks() async {
        guard let playlistId = playlist.id else { return }

        do {
            for trackId in selectedTrackIDs {
                try await playlistRepository.removeTrack(
                    playlistId: playlistId,
                    trackId: trackId
                )
            }

            selectedTrackIDs.removeAll()
            await loadTracks()

            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to remove tracks: \(error.localizedDescription)"
        }
    }

    /// Remove a single track from the playlist.
    @MainActor
    func removeTrack(_ trackId: Int64) async {
        guard let playlistId = playlist.id else { return }

        do {
            try await playlistRepository.removeTrack(playlistId: playlistId, trackId: trackId)
            await loadTracks()

            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to remove track: \(error.localizedDescription)"
        }
    }

    // MARK: - Reorder (Drag & Drop)

    /// Move a track to a new position via drag-and-drop.
    ///
    /// Uses fractional positioning: the new position is the midpoint between
    /// the surrounding tracks, avoiding a full renumber of the playlist.
    ///
    /// - Parameters:
    ///   - sourceIndex: Index of the track being moved (in `tracks` array)
    ///   - destinationIndex: Target index to insert before
    @MainActor
    func moveTrack(from sourceIndex: Int, to destinationIndex: Int) async {
        guard let playlistId = playlist.id else { return }
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0,
              sourceIndex < tracks.count else { return }

        let track = tracks[sourceIndex]
        guard let trackId = track.id else { return }

        // Calculate new position
        let newPosition = fractionalPosition(
            insertingAt: destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex,
            excluding: sourceIndex
        )

        do {
            try await playlistRepository.reorderTrack(
                playlistId: playlistId,
                trackId: trackId,
                newPosition: newPosition
            )
            await loadTracks()
        } catch {
            errorMessage = "Failed to reorder: \(error.localizedDescription)"
        }
    }

    // MARK: - M3U Import

    /// Import tracks from an M3U file into this playlist.
    ///
    /// Reads the M3U file, resolves each line as a relative or
    /// absolute file path, looks up matching tracks in the database,
    /// and adds them to the playlist.
    ///
    /// - Parameter url: URL of the M3U/M3U8 file
    @MainActor
    func importM3U(_ url: URL) async {
        guard let playlistId = playlist.id else { return }
        errorMessage = nil

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            guard !lines.isEmpty else {
                errorMessage = "M3U file is empty or contains no tracks"
                return
            }

            // Resolve lines to track IDs by matching original_path or organized_path
            var matchedIds: [Int64] = []
            for line in lines {
                if let track = try await findTrackByPath(line) {
                    if let id = track.id, !matchedIds.contains(id) {
                        matchedIds.append(id)
                    }
                }
            }

            guard !matchedIds.isEmpty else {
                errorMessage = "No matching tracks found in library for M3U entries"
                return
            }

            let nextPosition = generateNextPosition()
            try await playlistRepository.addTracks(
                playlistId: playlistId,
                trackIds: matchedIds,
                startPosition: nextPosition
            )

            await loadTracks()
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            errorMessage = "Failed to import M3U: \(error.localizedDescription)"
        }
    }

    // MARK: - Filtering

    private func applyFilter() {
        if searchQuery.isEmpty {
            displayedTracks = tracks
        } else {
            let query = searchQuery.lowercased()
            displayedTracks = tracks.filter { track in
                track.title.lowercased().contains(query) ||
                track.artist.lowercased().contains(query) ||
                track.album.lowercased().contains(query)
            }
        }
    }

    // MARK: - Position Helpers

    /// Generate a position string after the last track.
    ///
    /// Uses a simple incrementing scheme: the position is the count
    /// formatted as a zero-padded 6-digit string.
    private func generateNextPosition() -> String {
        let count = tracks.count
        return String(format: "%06d", count + 1)
    }

    /// Calculate a fractional position for inserting at a given index.
    ///
    /// For simplicity with string-based positions, we re-index in steps
    /// of 1000 and place the new item at the calculated slot.
    ///
    /// - Parameters:
    ///   - index: Target insertion index
    ///   - excludedIndex: Index of the track being moved (to skip)
    /// - Returns: Position string for the new location
    private func fractionalPosition(insertingAt index: Int, excluding excludedIndex: Int) -> String {
        // Build list without the moving item
        var positions: [Int] = []
        for i in 0..<tracks.count where i != excludedIndex {
            positions.append(i)
        }

        // Insert position between neighbors
        let clampedIndex = min(max(index, 0), positions.count)

        if clampedIndex == 0 {
            // Before first
            return String(format: "%06d", 0)
        } else if clampedIndex >= positions.count {
            // After last
            return String(format: "%06d", (positions.count + 1) * 1000)
        } else {
            // Between two items
            let beforeIdx = clampedIndex - 1
            let afterIdx = clampedIndex
            let midpoint = (beforeIdx + afterIdx + 1) * 500
            return String(format: "%06d", midpoint)
        }
    }

    // MARK: - Track Lookup

    /// Find a track by file path (searches by filename in original_path or organized_path).
    ///
    /// M3U lines can be relative or absolute paths. We extract the filename
    /// and search the library for a matching track.
    private func findTrackByPath(_ path: String) async throws -> Track? {
        let filename = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()

        guard !filename.isEmpty else { return nil }

        // Use search to find potential matches by filename
        let candidates = try await trackRepository.search(query: filename)
        return candidates.first { track in
            // Match by original_path ending or organized_path ending
            let originalMatch = track.originalPath.lowercased().hasSuffix(
                URL(fileURLWithPath: path).lastPathComponent.lowercased()
            )
            let organizedMatch = track.organizedPath?.lowercased().hasSuffix(
                URL(fileURLWithPath: path).lastPathComponent.lowercased()
            ) ?? false
            return originalMatch || organizedMatch
        }
    }
}
