import SwiftUI

/// Context menu for right-clicking track rows in the library table.
///
/// Actions are grouped into categories matching the Tauri app:
/// - Playback (Phase 5 — placeholder)
/// - Playlists (Phase 6 — placeholder)
/// - Sync (Phase 12 — placeholder)
/// - File operations (local tracks only)
/// - Destructive actions (remove/delete)
///
/// Multi-select aware: labels reflect selection count when > 1 track selected.
struct TrackContextMenu: View {
    let selectedTrackIDs: Set<Int64>
    let tracks: [Track]
    @Environment(\.container) private var container

    /// Resolved selected tracks.
    private var selectedTracks: [Track] {
        tracks.filter { track in
            guard let id = track.id else { return false }
            return selectedTrackIDs.contains(id)
        }
    }

    /// Whether the selection includes any local tracks.
    private var hasLocalTracks: Bool {
        selectedTracks.contains { $0.isLocal }
    }

    /// Whether all selected tracks are remote (no local file).
    private var allRemote: Bool {
        selectedTracks.allSatisfy { $0.isRemote }
    }

    /// Label suffix for multi-select (e.g., " (3 tracks)").
    private var countSuffix: String {
        selectedTracks.count > 1 ? " (\(selectedTracks.count) tracks)" : ""
    }

    var body: some View {
        // MARK: - Playback (Phase 5)
        Section {
            Button {
                playSelectedTrack()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(selectedTracks.isEmpty || selectedTracks.first?.isRemote == true)
        }

        Divider()

        // MARK: - Playlists (Phase 6)
        Section {
            Button {
                // Placeholder — Phase 6
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
        }

        // MARK: - Sync (Phase 12)
        Section {
            Button {
                // Placeholder — Phase 12
            } label: {
                Label("Add to Sync Profile…", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        // MARK: - File operations (local tracks only)
        if hasLocalTracks {
            Section {
                Button {
                    revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Button {
                    copyPath()
                } label: {
                    Label("Copy File Path", systemImage: "doc.on.doc")
                }
            }

            Divider()
        }

        // MARK: - Download (remote tracks only)
        if allRemote {
            Section {
                Button {
                    // Placeholder — Phase 11
                } label: {
                    Label("Download\(countSuffix)", systemImage: "arrow.down.circle")
                }
            }

            Divider()
        }

        // MARK: - Info
        Section {
            Button {
                // Placeholder — Phase 5 (More Info panel)
            } label: {
                Label("More Info", systemImage: "info.circle")
            }
        }

        Divider()

        // MARK: - Destructive
        Section {
            Button(role: .destructive) {
                // Placeholder — remove from library (DB only)
            } label: {
                Label("Remove from Library\(countSuffix)", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    /// Play the first selected local track.
    private func playSelectedTrack() {
        guard let track = selectedTracks.first(where: { $0.isLocal }),
              let playbackVM = container.playbackViewModel else { return }
        Task {
            await playbackVM.playTrack(track)
        }
    }

    /// Reveal the first selected local track in Finder.
    private func revealInFinder() {
        guard let track = selectedTracks.first(where: { $0.isLocal }),
              let path = track.organizedPath else { return }
        // Will use library root + organized_path resolution in future phases
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copy the file path of the first selected local track.
    private func copyPath() {
        guard let track = selectedTracks.first(where: { $0.isLocal }),
              let path = track.organizedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
