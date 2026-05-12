import SwiftUI

/// Context menu for right-clicking track rows in the library table.
///
/// Multi-select aware: labels reflect selection count when > 1 track selected.
struct TrackContextMenu: View {
    let selectedTrackIDs: Set<Int64>
    let tracks: [Track]
    let availablePlaylists: [Playlist]
    @Environment(\.container) private var container
    @State private var showRemoveConfirmation = false

    /// Resolved selected tracks.
    private var selectedTracks: [Track] {
        tracks.filter { track in
            guard let id = track.id else { return false }
            return selectedTrackIDs.contains(id)
        }
    }

    private var hasLocalTracks: Bool {
        selectedTracks.contains { $0.isLocal }
    }

    private var allRemote: Bool {
        selectedTracks.allSatisfy { $0.isRemote }
    }

    private var countSuffix: String {
        selectedTracks.count > 1 ? " (\(selectedTracks.count) tracks)" : ""
    }

    /// Label for the Download item — shows track count when batching.
    private var downloadButtonLabel: String {
        let count = selectedTracks.count
        if count <= 1 {
            return "Download"
        }
        return "Download \(count) tracks"
    }

    /// Greys out Download when there's nothing to do or a batch is already
    /// in flight.
    private var downloadDisabled: Bool {
        selectedTracks.isEmpty ||
        (container.downloadViewModel?.isDownloading ?? false)
    }

    var body: some View {
        Section {
            Button { playSelectedTrack() } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(selectedTracks.isEmpty || selectedTracks.first?.isRemote == true)
        }

        Divider()

        Section {
            Menu {
                if availablePlaylists.isEmpty {
                    Text("No playlists")
                } else {
                    ForEach(availablePlaylists) { playlist in
                        Button {
                            addToPlaylist(playlist)
                        } label: {
                            HStack {
                                if playlist.isPinned == 1 {
                                    Image(systemName: "pin.fill")
                                }
                                Text(playlist.name)
                            }
                        }
                    }
                }
            } label: {
                Label("Add to Playlist\(countSuffix)", systemImage: "text.badge.plus")
            }
            .disabled(selectedTracks.isEmpty)
        }

        Section {
            Button {
                // Placeholder — Phase 12
            } label: {
                Label("Add to Sync Profile…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(true)
        }

        Divider()

        if hasLocalTracks {
            Section {
                Button { revealInFinder() } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Button { copyPath() } label: {
                    Label("Copy File Path", systemImage: "doc.on.doc")
                }
            }
            Divider()
        }

        if allRemote {
            Section {
                Button {
                    downloadSelectedTracks()
                } label: {
                    Label(downloadButtonLabel, systemImage: "arrow.down.circle")
                }
                .disabled(downloadDisabled)
            }
            Divider()
        }

        Section {
            Button(role: .destructive) {
                if hasLocalTracks {
                    showRemoveConfirmation = true
                } else {
                    removeSelectedTracks()
                }
            } label: {
                Label("Remove from Library\(countSuffix)", systemImage: "trash")
            }
            .disabled(selectedTracks.isEmpty)
            .confirmationDialog(
                removeConfirmationTitle,
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("In Papierkorb verschieben", role: .destructive) {
                    removeSelectedTracks()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Dateien werden in den Papierkorb verschoben, DB-Einträge gelöscht. Remote-Verlinkungen werden ebenfalls entfernt.")
            }
        }
    }

    // MARK: - Removal

    private var removeConfirmationTitle: String {
        let count = selectedTracks.count
        return count > 1
            ? "\(count) Tracks aus der Library entfernen?"
            : "Track aus der Library entfernen?"
    }

    /// Trash any local files, then drop the track rows from the DB.
    ///
    /// - Local tracks → `FileManager.trashItem(at:)` so the file lands in
    ///   the user's Trash (recoverable) before the DB row is removed.
    /// - Remote tracks → DB row only.
    /// - Posts `.libraryDidDeleteTracks` so Library/Folders/Playlists views
    ///   refresh.
    private func removeSelectedTracks() {
        guard let trackRepo = container.trackRepository else { return }
        let snapshot = selectedTracks
        let ids = snapshot.compactMap(\.id)
        guard !ids.isEmpty else { return }

        Task {
            // Trash local files first; ignore failures (missing files are fine).
            for track in snapshot where track.isLocal {
                if let url = await resolveLocalURL(for: track) {
                    var trashed: NSURL? = nil
                    try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                }
            }
            do {
                try await trackRepo.delete(ids: ids)
                AppLogger.shared.log(
                    "Removed \(ids.count) track(s) from library",
                    level: .info,
                    source: "Library"
                )
                NotificationCenter.default.post(
                    name: .libraryDidDeleteTracks,
                    object: nil,
                    userInfo: ["removedIds": ids]
                )
            } catch {
                AppLogger.shared.log(
                    "Failed to remove tracks: \(error)",
                    level: .error,
                    source: "Library"
                )
            }
        }
    }

    // MARK: - Actions

    private func playSelectedTrack() {
        guard let track = selectedTracks.first(where: { $0.isLocal }),
              let playbackVM = container.playbackViewModel else { return }
        Task { await playbackVM.playTrack(track) }
    }

    /// Hand the current selection to the DownloadViewModel.
    ///
    /// The orchestrator runs sequentially in the background — this method
    /// returns immediately. Progress shows up in the ActivityPanel and the
    /// downloaded rows automatically migrate from Remote to Local once the
    /// batch completes (via the `.downloadDidComplete` notification).
    private func downloadSelectedTracks() {
        guard let downloadVM = container.downloadViewModel else { return }
        let tracksCopy = selectedTracks
        Task {
            await downloadVM.downloadTracks(tracksCopy)
        }
    }

    /// Reveal the first selected local track in Finder.
    /// Resolves `library_root + organized_path`; falls back to `original_path`
    /// when the organized location doesn't exist on disk.
    private func revealInFinder() {
        guard let track = selectedTracks.first(where: { $0.isLocal }) else { return }
        Task { @MainActor in
            if let url = await resolveLocalURL(for: track) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Copy the resolved absolute path of the first selected local track.
    /// Paths containing whitespace are wrapped in double quotes so the value
    /// can be pasted directly into a terminal.
    private func copyPath() {
        guard let track = selectedTracks.first(where: { $0.isLocal }) else { return }
        Task { @MainActor in
            guard let url = await resolveLocalURL(for: track) else { return }
            let raw = url.path
            let pasteValue = raw.rangeOfCharacter(from: .whitespaces) != nil
                ? "\"\(raw)\""
                : raw
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pasteValue, forType: .string)
        }
    }

    /// Resolve a track to an on-disk URL using library root + organized_path,
    /// with `original_path` as a filesystem fallback. Returns nil if no
    /// resolvable file exists.
    private func resolveLocalURL(for track: Track) async -> URL? {
        let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Fallback: original_path, only when it looks like a real filesystem path
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    private func addToPlaylist(_ playlist: Playlist) {
        guard let playlistId = playlist.id,
              let playlistRepo = container.playlistRepository else { return }

        let trackIds = Array(selectedTrackIDs)
        let position = String(format: "%06d", 999000)

        Task {
            try? await playlistRepo.addTracks(
                playlistId: playlistId,
                trackIds: trackIds,
                startPosition: position
            )
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        }
    }
}
