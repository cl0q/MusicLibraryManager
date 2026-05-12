import SwiftUI
import UniformTypeIdentifiers

/// Playlist detail view — track list with drag-and-drop reorder,
/// search, add/remove tracks, and M3U import.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │  ← Back    My Playlist    18 tracks     🔍 Search   [+ Add] │  Header
/// ├──────────────────────────────────────────────────────────────┤
/// │  # │ Title        │ Artist     │ Album      │ Duration       │  Table
/// │  1 │ Track One    │ Artist A   │ Album X    │ 3:24           │
/// │  2 │ Track Two    │ Artist B   │ Album Y    │ 4:01           │
/// │  ⋮ │ (drag to reorder)                                      │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// Phase 6 implementation. Drag-and-drop uses `onMove` for SwiftUI List
/// reordering with fractional positions persisted to the database.
struct PlaylistDetailView: View {
    let playlist: Playlist
    var onBack: () -> Void
    var onTrackDoubleClick: ((Track) -> Void)?

    @Environment(\.container) private var container
    @State private var viewModel: PlaylistDetailViewModel?
    @State private var showM3UImporter = false
    @State private var showAddFromLibrary = false
    @State private var showDeleteConfirmation = false
    @State private var trackToDelete: Track?

    var body: some View {
        Group {
            if let viewModel {
                VStack(spacing: 0) {
                    headerBar(viewModel)

                    Divider()
                        .background(Color.mlmEdge)

                    if viewModel.displayedTracks.isEmpty && !viewModel.isLoading {
                        emptyState(viewModel)
                    } else {
                        trackList(viewModel)
                    }
                }
                .background(Color.mlmBase)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            await viewModel?.loadTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .fileImporter(
            isPresented: $showM3UImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "m3u") ?? .plainText,
                UTType(filenameExtension: "m3u8") ?? .plainText
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await viewModel?.importM3U(url) }
            }
        }
        .alert("Remove Track", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let track = trackToDelete, let id = track.id {
                    Task { await viewModel?.removeTrack(id) }
                }
            }
        } message: {
            if let track = trackToDelete {
                Text("Remove \"\(track.title)\" from this playlist?")
            }
        }
    }

    // MARK: - Header

    private func headerBar(_ viewModel: PlaylistDetailViewModel) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Back button
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Playlists")
                            .font(MLMFont.body)
                    }
                    .foregroundColor(.mlmAccent)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            HStack(alignment: .bottom, spacing: 12) {
                // Playlist icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [Color.mlmAccent.opacity(0.4), Color.mlmAccent.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)

                    Image(systemName: playlist.isLiked == 1 ? "heart.fill" : "music.note.list")
                        .font(.system(size: 24))
                        .foregroundColor(.mlmAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Playlist name
                    Text(playlist.name)
                        .font(MLMFont.heroTitle)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)

                    // Track count + category
                    HStack(spacing: 8) {
                        Text("\(viewModel.tracks.count) track\(viewModel.tracks.count == 1 ? "" : "s")")
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInkSecondary)

                        if playlist.isPinned == 1 {
                            Label("Pinned", systemImage: "pin.fill")
                                .font(MLMFont.badge)
                                .foregroundColor(.mlmAccent)
                        }

                        if let _ = playlist.sourceId {
                            Label("Synced", systemImage: "cloud.fill")
                                .font(MLMFont.badge)
                                .foregroundColor(.mlmActive)
                        }
                    }
                }

                Spacer()

                // Actions
                actionButtons(viewModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Action Buttons

    private func actionButtons(_ viewModel: PlaylistDetailViewModel) -> some View {
        HStack(spacing: 8) {
            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.mlmInkMuted)
                TextField("Search tracks…", text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .frame(width: 140)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Import M3U
            Button {
                showM3UImporter = true
            } label: {
                Label("Import M3U", systemImage: "doc.badge.plus")
                    .font(MLMFont.body)
            }
            .buttonStyle(.bordered)

            // Remove selected
            if !viewModel.selectedTrackIDs.isEmpty {
                Button(role: .destructive) {
                    Task { await viewModel.removeSelectedTracks() }
                } label: {
                    Label("Remove \(viewModel.selectedTrackIDs.count)", systemImage: "minus.circle")
                        .font(MLMFont.body)
                }
                .buttonStyle(.bordered)
                .tint(.mlmError)
            }
        }
    }

    // MARK: - Track List

    private func trackList(_ viewModel: PlaylistDetailViewModel) -> some View {
        List(selection: Binding(
            get: { viewModel.selectedTrackIDs },
            set: { viewModel.selectedTrackIDs = $0 }
        )) {
            ForEach(Array(viewModel.displayedTracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track, index: index + 1, viewModel: viewModel)
                    .listRowBackground(
                        viewModel.selectedTrackIDs.contains(track.id ?? -1)
                            ? Color.mlmAccent.opacity(0.15)
                            : Color.clear
                    )
                    .listRowSeparator(.hidden)
            }
            .onMove { from, to in
                guard let sourceIndex = from.first else { return }
                Task {
                    await viewModel.moveTrack(from: sourceIndex, to: to)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.mlmBase)
        // Publish the highlighted row for the global Space shortcut.
        .focusedSceneValue(\.selectedTrack,
            viewModel.selectedTrackIDs.first.flatMap { id in
                viewModel.displayedTracks.first { $0.id == id }
            })
    }

    // MARK: - Track Row

    private func trackRow(_ track: Track, index: Int, viewModel: PlaylistDetailViewModel) -> some View {
        HStack(spacing: 8) {
            // Row number
            Text("\(index)")
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkMuted)
                .frame(width: 28, alignment: .trailing)
                .monospacedDigit()

            // Title + Artist
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(MLMFont.tableCell)
                    .foregroundColor(.mlmInk)
                    .lineLimit(1)

                Text(track.artist)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Album
            Text(track.album)
                .font(MLMFont.tableCell)
                .foregroundColor(.mlmInkSecondary)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)

            // Format badge
            Text(track.format.uppercased())
                .font(MLMFont.badge)
                .foregroundColor(formatColor(track.format))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(formatColor(track.format).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Duration
            Text(track.formattedDuration)
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkMuted)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onTrackDoubleClick?(track)
        }
        .contextMenu {
            trackContextMenu(track, viewModel: viewModel)
        }
    }

    // MARK: - Track Context Menu

    @ViewBuilder
    private func trackContextMenu(_ track: Track, viewModel: PlaylistDetailViewModel) -> some View {
        if track.isLocal {
            Button {
                onTrackDoubleClick?(track)
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()
        }

        Button {
            trackToDelete = track
            showDeleteConfirmation = true
        } label: {
            Label("Remove from Playlist", systemImage: "minus.circle")
        }

        Divider()

        Button {
            if let path = track.organizedPath ?? track.originalPath as String? {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(!track.isLocal)
    }

    // MARK: - Empty State

    private func emptyState(_ viewModel: PlaylistDetailViewModel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundColor(.mlmInkMuted)

            if viewModel.searchQuery.isEmpty {
                Text("No Tracks")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Add tracks from the Library via right-click → Add to Playlist,\nor import an M3U playlist file.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                Button {
                    showM3UImporter = true
                } label: {
                    Label("Import M3U File…", systemImage: "doc.badge.plus")
                        .font(MLMFont.bodyBold)
                }
                .buttonStyle(.bordered)
            } else {
                Text("No matching tracks")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func formatColor(_ format: String) -> Color {
        switch format.lowercased() {
        case "flac", "alac": return .mlmSuccess
        case "mp3": return .mlmActive
        case "aac", "m4a": return .mlmWarning
        case "ogg": return .mlmAccent
        default: return .mlmInkMuted
        }
    }

    private func initializeViewModel() {
        guard viewModel == nil,
              let playlistRepo = container.playlistRepository,
              let trackRepo = container.trackRepository else { return }
        viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepo,
            trackRepository: trackRepo
        )
    }
}
