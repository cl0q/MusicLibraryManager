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
                        Label("Show in Finder", systemImage: "folder")
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

    /// Remove from Library…: the shared confirmation and Trash flow (`TrackLibraryRemoval`,
    /// also used by Track ▸ Remove from Library…). The selection is captured now — the
    /// context menu is rebuilt on every right-click.
    private func handleRemoveTapped() {
        TrackLibraryRemoval.request(selectedTracks, container: container)
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

    /// The track's file, if it can be found (`TrackFileLocator`).
    private func resolveLocalURL(for track: Track) async -> URL? {
        await TrackFileLocator.localURL(for: track, container: container)
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
