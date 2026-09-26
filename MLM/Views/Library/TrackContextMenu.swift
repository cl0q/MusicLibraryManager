import SwiftUI
import AppKit

/// Context menu for right-clicking track rows in the library table.
///
/// Multi-select aware: labels reflect selection count when > 1 track selected.
struct TrackContextMenu: View {
    let selectedTrackIDs: Set<Int64>
    let tracks: [Track]
    let availablePlaylists: [Playlist]
    let availableSyncProfiles: [SyncProfile]
    let addToSyncProfile: (SyncProfile) -> Void
    var playlist: Playlist? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var allowsLibraryActions: Bool = true
    @Environment(\.container) private var container

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

    private var missingTracks: [Track] {
        selectedTracks.filter(\.isRemote)
    }

    private var countSuffix: String {
        selectedTracks.count > 1 ? " (\(selectedTracks.count) tracks)" : ""
    }

    /// Label for the Download item — shows track count when batching.
    private var downloadButtonLabel: String {
        let count = missingTracks.count
        return "Download \(count) missing track\(count == 1 ? "" : "s")"
    }

    /// Greys out Download when there's nothing to do or a batch is already
    /// in flight.
    private var downloadDisabled: Bool {
        missingTracks.isEmpty ||
        (container.downloadViewModel?.isDownloading ?? false)
    }

    var body: some View {
        let selected = selectedTracks
        let missing = selected.filter(\.isRemote)
        let suffix = selected.count > 1 ? " (\(selected.count) tracks)" : ""
        let hasLocal = selected.contains { $0.isLocal }
        let dlLabel = "Download \(missing.count) missing track\(missing.count == 1 ? "" : "s")"
        let dlDisabled = missing.isEmpty || (container.downloadViewModel?.isDownloading ?? false)

        if playlist != nil {
            Section {
                Button(role: .destructive) {
                    onRemoveFromPlaylist?()
                } label: {
                    Label("Remove from Playlist\(suffix)", systemImage: "minus.circle")
                }
            }
            Divider()
        }

        Section {
            Button { playSelectedTrack() } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(selected.isEmpty || selected.first?.isRemote == true)

            Button { playNextSelectedTracks() } label: {
                Label("Play Next", systemImage: "forward.end.fill")
            }
            .disabled(selected.isEmpty)
        }


        if allowsLibraryActions {
            Divider()

            Section {
                Menu {
                    Button {
                        NotificationCenter.default.post(
                            name: .triggerNewPlaylistFromSelection,
                            object: nil,
                            userInfo: ["trackIds": Array(selectedTrackIDs)]
                        )
                    } label: {
                        Label("New Playlist…", systemImage: "plus.square.on.square")
                    }

                    Divider()

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
                    Label("Add to Playlist\(suffix)", systemImage: "text.badge.plus")
                }
                .disabled(selected.isEmpty)
            }

            Section {
                Menu {
                    Button {
                        NotificationCenter.default.post(
                            name: .triggerNewSyncProfileFromSelection,
                            object: nil,
                            userInfo: ["trackIds": Array(selectedTrackIDs)]
                        )
                    } label: {
                        Label("Create new profile…", systemImage: "plus.circle")
                    }

                    Divider()

                    if availableSyncProfiles.isEmpty {
                        Text("No sync profiles — create one first")
                    } else {
                        ForEach(availableSyncProfiles) { profile in
                            Button {
                                addToSyncProfile(profile)
                            } label: {
                                Text(profile.name)
                            }
                        }
                        Divider()
                    }
                    Button {
                        NotificationCenter.default.post(name: .navigateToCreateSyncProfile, object: nil)
                    } label: {
                        Label("Create new profile… (Settings)", systemImage: "plus.circle")
                    }
                } label: {
                    Label("Sync to \u{25B8}", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(selected.isEmpty)
            }

            Divider()

            if hasLocal {
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

            if !missing.isEmpty {
                Section {
                    Button {
                        downloadSelectedTracks()
                    } label: {
                        Label(dlLabel, systemImage: "arrow.down.circle")
                    }
                    .disabled(dlDisabled)
                }
                Divider()
            }

            Section {
                Button(role: .destructive) {
                    handleRemoveTapped()
                } label: {
                    Label("Remove from Library\(suffix)", systemImage: "trash")
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    // MARK: - Removal

    /// Capture the selection (the context menu is rebuilt every right-
    /// click so `selectedTracks` is only valid synchronously) and decide
    /// whether to prompt before proceeding.
    private func handleRemoveTapped() {
        let snapshot = selectedTracks
        let ids = snapshot.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let needsConfirm = snapshot.contains { $0.isLocal }
        if needsConfirm {
            // Defer to the next runloop tick so the context menu has
            // finished dismissing before the alert tries to attach itself
            // to the key window — otherwise the modal can land behind the
            // menu's dimmed layer and feel like nothing happened.
            DispatchQueue.main.async {
                if confirmRemovalAlert(count: snapshot.count) {
                    performRemoval(snapshot: snapshot, ids: ids)
                }
            }
        } else {
            performRemoval(snapshot: snapshot, ids: ids)
        }
    }

    /// Native NSAlert is synchronous and survives the context menu
    /// teardown that breaks SwiftUI's `.confirmationDialog` here.
    private func confirmRemovalAlert(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count > 1
            ? "Remove \(count) tracks from Library?"
            : "Remove track from Library?"
        alert.informativeText = "This moves local files to the Trash. You can restore them from there. Remote links are removed from the Library."
        alert.alertStyle = .warning
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performRemoval(snapshot: [Track], ids: [Int64]) {
        removeSelectedTracks(snapshot: snapshot, ids: ids)
    }

    /// Trash any local files, then drop the track rows from the DB.
    ///
    /// - Local tracks → `FileManager.trashItem(at:)` so the file lands in
    ///   the user's Trash (recoverable) before the DB row is removed.
    /// - Remote tracks → DB row only.
    /// - Posts `.libraryDidDeleteTracks` so Library/Folders/Playlists views
    ///   refresh.
    private func removeSelectedTracks(snapshot: [Track], ids: [Int64]) {
        guard let trackRepo = container.trackRepository else { return }
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
        Task { await playbackVM.playTrack(track, queue: selectedTracks) }
    }

    /// Insert the selected tracks (in displayed order) directly after the
    /// current track in the playback queue.
    private func playNextSelectedTracks() {
        guard let playbackVM = container.playbackViewModel else { return }
        let ordered = selectedTracks
        guard !ordered.isEmpty else { return }
        playbackVM.insertPlayNext(ordered)
    }

    /// Hand the current selection to the DownloadViewModel.
    ///
    /// The orchestrator runs sequentially in the background — this method
    /// returns immediately. Progress shows up in the ActivityPanel and the
    /// downloaded rows automatically migrate from Remote to Local once the
    /// batch completes (via the `.downloadDidComplete` notification).
    private func downloadSelectedTracks() {
        guard let downloadVM = container.downloadViewModel else { return }
        let tracksCopy = missingTracks
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

        let trackIds = selectedTracks.compactMap(\.id)

        Task {
            do {
                try await playlistRepo.appendTracks(playlistId: playlistId, trackIds: trackIds)
            } catch {
                AppLogger.shared.log(
                    "Failed to add tracks to playlist: \(error)",
                    level: .error,
                    source: "Library"
                )
                return
            }
            // D-04: userInfo lets PlaylistCoverService regenerate this playlist's cover.
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
        }
    }
}
