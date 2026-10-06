import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

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
/// Opening a card pushes `DetailRoute.playlist` onto the content column's navigation stack
/// (Back ⌘[ returns to the grid). Without a shell navigation model (previews, fixtures) it
/// shows the detail in place as before.
struct PlaylistsView: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @State private var viewModel: PlaylistViewModel?
    @State private var selectedPlaylist: Playlist?
    @State private var showFailedTracksWhenOpened = false
    @State private var showNewPlaylistPopover = false
    @State private var availableSyncProfiles: [SyncProfile] = []
    @State private var pendingDeletion: Playlist?

    /// Callback when a track is double-clicked in the detail view.
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)
    ]

    var body: some View {
        Group {
            if let selectedPlaylist, viewModel != nil, navigation == nil {
                PlaylistDetailView(
                    playlist: selectedPlaylist,
                    initiallyShowFailedTracks: showFailedTracksWhenOpened,
                    onBack: {
                        self.selectedPlaylist = nil
                        self.showFailedTracksWhenOpened = false
                    },
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
            await reloadSyncProfiles()
        }
        // In-place filter (W2-I): the toolbar field filters the grid by name; the grid's own
        // search field is gone (one search field, UC-SEARCH-01).
        .onChange(of: container.searchCoordinator.filter(for: .allPlaylists), initial: true) { _, filter in
            viewModel?.searchQuery = filter.parsed.freeText
        }
        .onChange(of: viewModel != nil) { _, _ in
            viewModel?.searchQuery = container.searchCoordinator.filter(for: .allPlaylists).parsed.freeText
        }
        .onChange(of: selectedPlaylist?.id) { _, id in
            guard let navigation, let id else { return }
            navigation.push(.playlist(id, showFailedTracks: showFailedTracksWhenOpened))
            selectedPlaylist = nil
            showFailedTracksWhenOpened = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadStateDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await viewModel?.refresh() }
        }
        .background {
            if let viewModel {
                PlaylistDownloadHealthObserver(viewModel: viewModel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
            Task { await reloadSyncProfiles() }
        }
        .onAppear {
            // Revalidate covers for all displayed playlists when the grid becomes visible.
            // This catches the case where artwork backfill ran while the view was not shown
            // (e.g., user was in LibraryView during Maintenance → Refresh embedded artwork).
            // Post one notification per displayed playlist so PlaylistCoverService can
            // coalesce via inFlight. Tagged coverRevalidation so PlaylistDetailView's
            // track-refresh receiver skips these noise posts.
            guard let vm = viewModel else { return }
            for playlist in vm.displayedPlaylists {
                guard let pid = playlist.id else { continue }
                NotificationCenter.default.post(
                    name: .playlistDidChange,
                    object: nil,
                    userInfo: ["playlistId": pid, "coverRevalidation": pid]
                )
            }
        }
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                guard let playlistID = pendingDeletion?.id else { return }
                pendingDeletion = nil
                Task { await viewModel?.deletePlaylist(id: playlistID) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("Delete “\(pendingDeletion?.name ?? "")”? Its music files will remain in your library.")
        }
    }

    // MARK: - Grid Content

    private func gridContent(_ viewModel: PlaylistViewModel) -> some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar(viewModel)

            // D-10: 8-pin soft-limit hint banner — appears above the divider
            // when togglePin hard-blocks the 9th attempt; auto-clears after 3s.
            if let hintMessage = viewModel.pinLimitHintMessage {
                pinLimitBanner(message: hintMessage)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

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
        .animation(.easeInOut(duration: 0.2), value: viewModel.pinLimitHintMessage)
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

            // Source filter picker
            sourceFilterPicker(viewModel)

            // Incomplete toggle
            Button {
                viewModel.incompleteOnly.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.incompleteOnly ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                    Text("Incomplete")
                        .font(MLMFont.body)
                }
                .foregroundColor(viewModel.incompleteOnly ? .mlmAccent : .mlmInkSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.mlmRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("playlist_incomplete_filter")
            .accessibilityLabel("playlist_incomplete_filter")

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
            // No ⌘N here: File ▸ New Playlist owns ⌘N (one meaning per key, UC-KEY-39).
            .accessibilityIdentifier("new_playlist_button")
            .accessibilityLabel("new_playlist_button")
            .popover(isPresented: $showNewPlaylistPopover, arrowEdge: .bottom) {
                newPlaylistPopover(viewModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Source Filter Picker

    private func sourceFilterPicker(_ viewModel: PlaylistViewModel) -> some View {
        Menu {
            Button {
                viewModel.sourceFilter = .all
            } label: {
                if case .all = viewModel.sourceFilter { Label("All", systemImage: "checkmark") } else { Text("All") }
            }
            Button {
                viewModel.sourceFilter = .local
            } label: {
                if case .local = viewModel.sourceFilter { Label("Local", systemImage: "checkmark") } else { Text("Local") }
            }
            ForEach(viewModel.availableSourceIdentities, id: \.self) { identity in
                Button {
                    viewModel.sourceFilter = .identity(identity)
                } label: {
                    if case .identity(identity) = viewModel.sourceFilter {
                        Label(identity.displayName, systemImage: "checkmark")
                    } else {
                        Text(identity.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                Text(sourceFilterLabel(viewModel))
                    .font(MLMFont.body)
            }
            .foregroundColor(.mlmInkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("playlist_source_filter")
        .accessibilityLabel("playlist_source_filter")
    }

    private func sourceFilterLabel(_ viewModel: PlaylistViewModel) -> String {
        switch viewModel.sourceFilter {
        case .all: return "All"
        case .local: return "Local"
        case .identity(let id): return id.displayName
        }
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
            .accessibilityIdentifier("new_playlist_name_field")
            .accessibilityLabel("new_playlist_name_field")

            HStack {
                Button("Cancel") {
                    showNewPlaylistPopover = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("new_playlist_cancel_button")
                .accessibilityLabel("new_playlist_cancel_button")

                Spacer()

                Button("Create") {
                    Task {
                        await viewModel.createPlaylist(name: viewModel.newPlaylistName)
                        showNewPlaylistPopover = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("new_playlist_create_button")
                .accessibilityLabel("new_playlist_create_button")
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
                    PlaylistsGridCard(
                        playlist: playlist,
                        viewModel: viewModel,
                        availableSyncProfiles: availableSyncProfiles,
                        selectedPlaylist: $selectedPlaylist,
                        showFailedTracksWhenOpened: $showFailedTracksWhenOpened,
                        pendingDeletion: $pendingDeletion
                    )
                }
            }
            .padding(16)
        }
        // The grid's background: a new playlist from dropped tracks (D-PL-SELECTION-TO-NEW);
        // the cards take their own drops.
        .dropTarget(.playlistsSection, cornerRadius: 0)
    }

    // MARK: - Empty State

    private func emptyState(_ viewModel: PlaylistViewModel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 48))
                .foregroundColor(.mlmInkMuted)

            if viewModel.playlists.isEmpty {
                Text("No Playlists Yet")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Create your first playlist with ⌘N or the + button above.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            } else if !viewModel.searchQuery.isEmpty
                        || viewModel.sourceFilter != .all
                        || viewModel.incompleteOnly {
                Text("No Playlists Match Your Filters")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Try clearing or adjusting your filters.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
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

    // MARK: - Banners (Phase 36)

    /// 8-pin soft-limit hint banner (D-10, UI-SPEC §"8-pin Soft-Limit Hint UI").
    /// Inline row between the header and the grid; pushes the grid down ~44pt
    /// while visible. Auto-dismiss is owned by `PlaylistViewModel` (3s).
    @ViewBuilder
    private func pinLimitBanner(message: String) -> some View {
        HStack(spacing: 8) {
            // 3pt-wide warning accent bar
            Rectangle()
                .fill(Color.mlmWarning)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.mlmWarning)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlmRaised)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pin_limit_banner")
        .accessibilityLabel("Pin limit reached (8). Unpin one first.")
    }

    // MARK: - Initialization

    private func initializeViewModel() {
        guard viewModel == nil,
              let playlistRepo = container.playlistRepository,
              let sourceRepo = container.sourceRepository else { return }
        viewModel = PlaylistViewModel(
            playlistRepository: playlistRepo,
            sourceRepository: sourceRepo
        )
    }

    private func reloadSyncProfiles() async {
        if let syncVM = container.syncViewModel {
            if syncVM.profiles.isEmpty {
                await syncVM.loadProfiles()
            }
            availableSyncProfiles = syncVM.profiles
        }
    }

}

/// Observes live download activity separately from the grid's large routed
/// view expression, then refreshes only persisted playlist health while a
/// batch is active.
private struct PlaylistDownloadHealthObserver: View {
    let viewModel: PlaylistViewModel

    @Environment(\.container) private var container
    @State private var observationTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                startObservation(isDownloading: container.downloadViewModel?.isDownloading == true)
            }
            .onChange(of: container.downloadViewModel?.isDownloading) { _, isDownloading in
                startObservation(isDownloading: isDownloading == true)
            }
            .onDisappear {
                observationTask?.cancel()
                observationTask = nil
            }
    }

    private func startObservation(isDownloading: Bool) {
        observationTask?.cancel()
        guard isDownloading else {
            observationTask = Task {
                await viewModel.refreshDownloadHealth()
            }
            return
        }

        let downloadViewModel = container.downloadViewModel
        observationTask = Task {
            repeat {
                await viewModel.refreshDownloadHealth()
                guard !Task.isCancelled, downloadViewModel?.isDownloading == true else { break }
                try? await Task.sleep(for: .milliseconds(250))
            } while !Task.isCancelled
        }
    }
}

/// Helper view to avoid Swift compiler timeout by breaking up complex nested grid card layout.
private struct PlaylistsGridCard: View {
    let playlist: Playlist
    @Bindable var viewModel: PlaylistViewModel
    let availableSyncProfiles: [SyncProfile]
    @Binding var selectedPlaylist: Playlist?
    @Binding var showFailedTracksWhenOpened: Bool
    @Binding var pendingDeletion: Playlist?

    @Environment(\.container) private var container

    var body: some View {
        PlaylistCard(
            playlist: playlist,
            source: viewModel.source(for: playlist),
            trackCount: viewModel.trackCounts[playlist.id ?? 0] ?? 0,
            downloadStatus: viewModel.downloadStatus(for: playlist),
            isRenaming: viewModel.renamingPlaylistID == playlist.id,
            renameText: Binding(
                get: { viewModel.renameText },
                set: { viewModel.renameText = $0 }
            ),
            onTap: {
                showFailedTracksWhenOpened = false
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
                // Pinning is retired (DEC-003); the grid is rebuilt in this package.
            },
            onDelete: {
                pendingDeletion = playlist
            },
            onSpringLoad: {
                showFailedTracksWhenOpened = false
                selectedPlaylist = playlist
            },
            onResetCover: {
                guard let pid = playlist.id else { return }
                Task {
                    await container.playlistCoverService?.resetToAuto(playlistId: pid)
                }
            },
            availableSyncProfiles: availableSyncProfiles,
            onAddToSyncProfile: { profile, playlistId in
                Task {
                    container.syncViewModel?.selectedProfile = profile
                    await container.syncViewModel?.addPlaylists([playlistId])
                }
            },
            onDownloadMissing: {
                guard let playlistID = playlist.id,
                      let playlistRepository = container.playlistRepository,
                      let downloadViewModel = container.downloadViewModel else { return }
                let tracks = (try? await playlistRepository.fetchTracks(playlistId: playlistID)) ?? []
                let missingTracks = tracks.filter { $0.availability() == .notDownloaded }
                await downloadViewModel.downloadTracks(
                    missingTracks,
                    preferredSource: viewModel.source(for: playlist)?.playlistSourceIdentity.downloadPin ?? .auto,
                    context: .playlist(playlistID, name: playlist.name)  // W3-ACT
                )
            },
            onShowFailedTracks: {
                showFailedTracksWhenOpened = true
                selectedPlaylist = playlist
            }
        )
    }

}
