import SwiftUI

/// Search results presented in the detail area while the toolbar search field
/// has focus. The toolbar remains the only general-purpose search entry point.
struct GlobalSearchPresentationView: View {
    @Environment(\.container) private var container
    @Binding var query: String
    let onExit: () -> Void

    var context: SearchResultsMerger.Context = .library
    var onTrackDoubleClick: ((Track, [Track]) -> Void)? = nil

    @State private var viewModel: GlobalSearchPresentationViewModel?
    @State private var scope: GlobalSearchPresentationViewModel.Scope = .library
    @State private var selection: Set<Int64> = []
    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView("Preparing search…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color.mlmBase)
        .task { initialize() }
        .onExitCommand(perform: onExit)
    }

    private func content(_ viewModel: GlobalSearchPresentationViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)

                Spacer()

                Picker("", selection: $scope) {
                    ForEach(GlobalSearchPresentationViewModel.Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            contentArea(viewModel)
        }
        .task(id: requestID) {
            await viewModel.search(query: query, scope: scope)
        }
        .task {
            await reloadPlaylists()
            await reloadSyncProfiles()
        }
    }

    private var requestID: String {
        "\(query)|\(scope.rawValue)"
    }

    @ViewBuilder
    private func contentArea(_ viewModel: GlobalSearchPresentationViewModel) -> some View {
        if viewModel.isSearching {
            ProgressView(scope == .allSources ? "Searching sources…" : "Searching library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search library",
                systemImage: "magnifyingglass",
                description: Text("Type in the toolbar search field to search your library.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            resultsContent(viewModel)
        }
    }

    @ViewBuilder
    private func resultsContent(_ viewModel: GlobalSearchPresentationViewModel) -> some View {
        VStack(spacing: 0) {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if !viewModel.sourceFailures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "\(viewModel.sourceFailures.count) sources unreachable — results incomplete",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmAttention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                    DisclosureGroup("Details") {
                        ForEach(viewModel.sourceFailures) { failure in
                            Text("\(failure.source): \(failure.message)")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                        }
                    }
                    .font(MLMFont.muted)
                    .padding(.horizontal, 16)
                }
            }

            TrackTable(
                rows: viewModel.results.compactMap { track in
                    track.id.map { TrackTable.Row(id: $0, track: track) }
                },
                selection: $selection,
                onDoubleClick: { track, queue in
                    if let onTrackDoubleClick {
                        onTrackDoubleClick(track, queue)
                    } else {
                        defaultPlay(track, queue: queue)
                    }
                },
                availablePlaylists: availablePlaylists,
                availableSyncProfiles: availableSyncProfiles,
                isLoading: viewModel.isSearching,
                emptyContent: {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                },
                accessibilityID: "search_results_table"
            )
        }
    }

    private func defaultPlay(_ track: Track, queue: [Track]) {
        guard let playbackViewModel = container.playbackViewModel else { return }
        Task {
            await playbackViewModel.playTrack(track, queue: queue)
        }
    }

    private func reloadPlaylists() async {
        guard let repo = container.playlistRepository else { return }
        availablePlaylists = (try? await repo.fetchAll()) ?? []
    }

    private func reloadSyncProfiles() async {
        if let syncVM = container.syncViewModel {
            if syncVM.profiles.isEmpty {
                await syncVM.loadProfiles()
            }
            availableSyncProfiles = syncVM.profiles
        }
    }

    private func initialize() {
        guard viewModel == nil,
              let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository else { return }

        var soundCloudClient: SoundCloudClient?
        var spotifyClient: SpotifyClient?
        if let tokenStorage = container.tokenStorage, let oauthManager = container.oauthManager {
            if tokenStorage.hasCredentials(service: .soundcloud) {
                soundCloudClient = SoundCloudClient(
                    tokenStorage: tokenStorage,
                    oauthManager: oauthManager,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo,
                    playlistRepository: container.playlistRepository
                )
            }
            if tokenStorage.hasCredentials(service: .spotify) {
                spotifyClient = SpotifyClient(
                    tokenStorage: tokenStorage,
                    oauthManager: oauthManager,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo,
                    playlistRepository: container.playlistRepository
                )
            }
        }

        let dabClient = container.tokenStorage.map { DABClient(tokenStorage: $0) }
        let vm = GlobalSearchPresentationViewModel(
            soundCloudClient: soundCloudClient,
            spotifyClient: spotifyClient,
            youtubeDownloader: YouTubeDownloader(),
            dabClient: dabClient,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo,
            playlistRepository: container.playlistRepository
        )
        vm.context = context
        if case .playlist(let playlistID) = context {
            vm.contextPlaylistID = playlistID
        }
        viewModel = vm
    }
}
