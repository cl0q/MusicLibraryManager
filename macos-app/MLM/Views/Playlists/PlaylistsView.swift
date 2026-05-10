import SwiftUI

/// Playlists grid view — shows all playlists as cards with create/search.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │  Playlists                       🔍 Search    [+ New]       │  Header
/// ├──────────────────────────────────────────────────────────────┤
/// │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │
/// │  │  📌 Fav  │ │  Chill   │ │  Workout │ │  New     │       │  Grid
/// │  │  42 trks │ │  18 trks │ │  31 trks │ │  0 trks  │       │
/// │  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │
/// │                                                              │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// Navigates to `PlaylistDetailView` when a card is tapped.
struct PlaylistsView: View {
    @Environment(\.container) private var container
    @State private var viewModel: PlaylistViewModel?
    @State private var selectedPlaylist: Playlist?
    @State private var showNewPlaylistPopover = false

    /// Callback when a track is double-clicked in the detail view.
    var onTrackDoubleClick: ((Track) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)
    ]

    var body: some View {
        Group {
            if let selectedPlaylist, let viewModel {
                PlaylistDetailView(
                    playlist: selectedPlaylist,
                    onBack: { self.selectedPlaylist = nil },
                    onTrackDoubleClick: onTrackDoubleClick
                )
            } else if let viewModel {
                gridContent(viewModel)
            } else {
                ProgressView("Loading playlists…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            await viewModel?.loadPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
    }

    // MARK: - Grid Content

    private func gridContent(_ viewModel: PlaylistViewModel) -> some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar(viewModel)

            Divider()
                .background(Color.mlmEdge)

            // Grid or empty state
            if viewModel.displayedPlaylists.isEmpty && !viewModel.isLoading {
                emptyState(viewModel)
            } else {
                scrollableGrid(viewModel)
            }
        }
        .background(Color.mlmBase)
    }

    // MARK: - Header

    private func headerBar(_ viewModel: PlaylistViewModel) -> some View {
        HStack(spacing: 8) {
            Text("Playlists")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)

            // Count badge
            Text("\(viewModel.playlists.count)")
                .font(MLMFont.badge)
                .foregroundColor(.mlmInkMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.mlmRaised)
                .clipShape(Capsule())

            Spacer()

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.mlmInkMuted)
                TextField("Search playlists…", text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .frame(width: 160)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.mlmInkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // New playlist button
            Button {
                viewModel.newPlaylistName = ""
                showNewPlaylistPopover = true
            } label: {
                Label("New Playlist", systemImage: "plus")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmBase)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.mlmAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .popover(isPresented: $showNewPlaylistPopover, arrowEdge: .bottom) {
                newPlaylistPopover(viewModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - New Playlist Popover

    private func newPlaylistPopover(_ viewModel: PlaylistViewModel) -> some View {
        VStack(spacing: 8) {
            Text("New Playlist")
                .font(MLMFont.sectionHeader)
                .foregroundColor(.mlmInk)

            TextField("Playlist name", text: Binding(
                get: { viewModel.newPlaylistName },
                set: { viewModel.newPlaylistName = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(MLMFont.body)
            .onSubmit {
                Task {
                    await viewModel.createPlaylist(name: viewModel.newPlaylistName)
                    showNewPlaylistPopover = false
                }
            }

            HStack {
                Button("Cancel") {
                    showNewPlaylistPopover = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    Task {
                        await viewModel.createPlaylist(name: viewModel.newPlaylistName)
                        showNewPlaylistPopover = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    // MARK: - Scrollable Grid

    private func scrollableGrid(_ viewModel: PlaylistViewModel) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.displayedPlaylists) { playlist in
                    PlaylistCard(
                        playlist: playlist,
                        trackCount: viewModel.trackCounts[playlist.id ?? 0] ?? 0,
                        isRenaming: viewModel.renamingPlaylistID == playlist.id,
                        renameText: Binding(
                            get: { viewModel.renameText },
                            set: { viewModel.renameText = $0 }
                        ),
                        onTap: {
                            selectedPlaylist = playlist
                        },
                        onRename: {
                            viewModel.startRename(playlist: playlist)
                        },
                        onConfirmRename: {
                            Task { await viewModel.confirmRename() }
                        },
                        onCancelRename: {
                            viewModel.cancelRename()
                        },
                        onTogglePin: {
                            Task { await viewModel.togglePin(id: playlist.id!) }
                        },
                        onDelete: {
                            Task { await viewModel.deletePlaylist(id: playlist.id!) }
                        }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Empty State

    private func emptyState(_ viewModel: PlaylistViewModel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 48))
                .foregroundColor(.mlmInkMuted)

            if viewModel.searchQuery.isEmpty {
                Text("No Playlists Yet")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Create your first playlist with ⌘N or the + button above.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            } else {
                Text("No matching playlists")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Try a different search term.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Initialization

    private func initializeViewModel() {
        guard viewModel == nil,
              let playlistRepo = container.playlistRepository else { return }
        viewModel = PlaylistViewModel(playlistRepository: playlistRepo)
    }
}
