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
    @State private var availableSyncProfiles: [SyncProfile] = []

    /// Callback when a track is double-clicked in the detail view.
    var onTrackDoubleClick: ((Track) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)
    ]

    var body: some View {
        Group {
            if let selectedPlaylist, viewModel != nil {
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
            await reloadSyncProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
            Task { await reloadSyncProfiles() }
        }
        .onAppear {
            // Revalidate covers for all displayed playlists when the grid becomes visible.
            // This catches the case where artwork backfill ran while the view was not shown
            // (e.g., user was in LibraryView during Maintenance → Refresh embedded artwork).
            // Post one notification per displayed playlist so PlaylistCoverService can
            // coalesce via inFlight. No origin tag — these are explicit user-triggered events.
            guard let vm = viewModel else { return }
            for playlist in vm.displayedPlaylists {
                guard let pid = playlist.id else { continue }
                NotificationCenter.default.post(
                    name: .playlistDidChange,
                    object: nil,
                    userInfo: ["playlistId": pid]
                )
            }
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

            // UI-SPEC line 174: drop-rejected banner — appears when a non-image
            // payload is dropped on a card; auto-clears after 4s.
            if let dropError = viewModel.coverDropErrorMessage {
                coverDropErrorBanner(message: dropError)
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.coverDropErrorMessage)
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
                    PlaylistsGridCard(
                        playlist: playlist,
                        viewModel: viewModel,
                        availableSyncProfiles: availableSyncProfiles,
                        selectedPlaylist: $selectedPlaylist
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
                Text("Unpin one playlist before pinning another. (Maximum: 8)")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlmRaised)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pin limit reached. Maximum eight pinned playlists. Unpin one to free a slot.")
    }

    /// Drop-rejected banner (UI-SPEC line 174). Same visual structure as the
    /// pin-limit banner, single line of body, octagon-X glyph. Auto-dismiss
    /// is owned by `PlaylistViewModel.flagCoverDropRejected` (4s).
    @ViewBuilder
    private func coverDropErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.mlmWarning)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 14))
                .foregroundColor(.mlmWarning)
                .padding(.leading, 4)

            Text(message)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlmRaised)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cover drop rejected. \(message)")
    }

    // MARK: - Initialization

    private func initializeViewModel() {
        guard viewModel == nil,
              let playlistRepo = container.playlistRepository else { return }
        viewModel = PlaylistViewModel(playlistRepository: playlistRepo)
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

/// Helper view to avoid Swift compiler timeout by breaking up complex nested grid card layout.
private struct PlaylistsGridCard: View {
    let playlist: Playlist
    @Bindable var viewModel: PlaylistViewModel
    let availableSyncProfiles: [SyncProfile]
    @Binding var selectedPlaylist: Playlist?

    @Environment(\.container) private var container

    var body: some View {
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
            },
            onSpringLoad: {
                selectedPlaylist = playlist
            },
            onCoverDropped: { url in
                guard let pid = playlist.id else { return }
                await container.playlistCoverService?.setCustomCover(
                    playlistId: pid,
                    sourceURL: url
                )
            },
            onResetCover: {
                guard let pid = playlist.id else { return }
                Task {
                    await container.playlistCoverService?.resetToAuto(playlistId: pid)
                }
            },
            onCoverDropRejected: {
                viewModel.flagCoverDropRejected()
            },
            availableSyncProfiles: availableSyncProfiles,
            onAddToSyncProfile: { profile, playlistId in
                Task {
                    container.syncViewModel?.selectedProfile = profile
                    await container.syncViewModel?.addPlaylists([playlistId])
                }
            },
            onTracksDropped: { trackIds in
                guard let pid = playlist.id,
                      let playlistRepo = container.playlistRepository else { return }
                do {
                    let existingTracks = try await playlistRepo.fetchTracks(playlistId: pid)
                    let lastPos = existingTracks.last?.playlistPosition
                    let nextPos = FractionalIndexer.positionBetween(left: lastPos, right: nil)
                    
                    try await playlistRepo.addTracks(
                        playlistId: pid,
                        trackIds: trackIds,
                        startPosition: nextPos
                    )
                    
                    NotificationCenter.default.post(
                        name: .playlistDidChange,
                        object: nil,
                        userInfo: ["playlistId": pid]
                    )
                    
                    await viewModel.loadPlaylists()
                } catch {
                    AppLogger.shared.error("Failed to add dropped tracks: \(error.localizedDescription)", source: "PlaylistsView")
                }
            }
        )
    }
}
