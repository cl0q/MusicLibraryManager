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

    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []

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
            await loadPlaylistsAndProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onAppear {
            // Revalidate the detail playlist's cover when the view becomes visible.
            // Handles the case where backfill ran while navigated away.
            guard let pid = playlist.id else { return }
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": pid]
            )
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
                // Playlist cover / icon
                ZStack {
                    if let coverImage = loadCoverImage() {
                        Image(nsImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: categoryGradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)

                        Image(systemName: categoryIcon)
                            .font(.system(size: 24))
                            .foregroundColor(playlist.isLiked == 1 || playlist.isSmart == 1 || playlist.sourceId != nil ? .white.opacity(0.9) : .mlmAccent)
                    }
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

            if let error = viewModel.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.mlmError)
                        .font(MLMFont.muted)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Action Buttons

    private func actionButtons(_ viewModel: PlaylistDetailViewModel) -> some View {
        HStack(spacing: 8) {
            // Sync button
            if viewModel.canSync {
                Button {
                    Task { await viewModel.syncSource() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(viewModel.isSyncingSource ? 360 : 0))
                            .animation(viewModel.isSyncingSource ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isSyncingSource)
                        Text(viewModel.isSyncingSource ? "Syncing…" : "Sync")
                    }
                    .font(MLMFont.body)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSyncingSource)
            }

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

            // Import M3U8
            Button {
                showM3UImporter = true
            } label: {
                Label("Import M3U8", systemImage: "doc.badge.plus")
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
        PlaylistTable(
            playlist: playlist,
            viewModel: viewModel,
            availablePlaylists: availablePlaylists,
            availableSyncProfiles: availableSyncProfiles,
            onTrackDoubleClick: onTrackDoubleClick,
            onRemoveTracks: { ids in
                for id in ids {
                    await viewModel.removeTrack(id)
                }
            }
        )
        .background(Color.mlmBase)
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
                    Label("Import M3U8 Datei…", systemImage: "doc.badge.plus")
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

    private func loadPlaylistsAndProfiles() async {
        if let repo = container.playlistRepository {
            availablePlaylists = (try? await repo.fetchAll()) ?? []
        }
        if let syncVM = container.syncViewModel {
            if syncVM.profiles.isEmpty {
                await syncVM.loadProfiles()
            }
            availableSyncProfiles = syncVM.profiles
        }
    }

    // MARK: - Header Artwork & Fallbacks

    private func loadCoverImage() -> NSImage? {
        guard let relPath = playlist.coverImagePath else { return nil }
        let fileName = (relPath as NSString).lastPathComponent
        let url = coversDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private var coversDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.musiclibrary.app")
            .appendingPathComponent("playlist-covers")
    }

    private var categoryIcon: String {
        if playlist.isLiked == 1 {
            return "heart.fill"
        }
        if playlist.isSmart == 1 {
            return "wand.and.stars"
        }
        switch playlist.category {
        case "regular": return "music.note.list"
        case "liked": return "heart.fill"
        case "album": return "opticaldisc"
        default: return "music.note.list"
        }
    }

    private var categoryGradient: [Color] {
        if playlist.isLiked == 1 {
            return [Color.mlmError.opacity(0.6), Color.mlmError.opacity(0.3)]
        }
        if playlist.isSmart == 1 {
            return [Color.mlmActive.opacity(0.6), Color.mlmActive.opacity(0.3)]
        }
        if playlist.sourceId != nil {
            return [Color.mlmAccent.opacity(0.4), Color.mlmAccent.opacity(0.2)]
        }
        return [Color.mlmRaised, Color.mlmSurface]
    }
}
