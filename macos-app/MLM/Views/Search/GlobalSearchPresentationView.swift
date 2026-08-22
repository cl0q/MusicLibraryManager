import SwiftUI

/// Search results presented in the detail area while the toolbar search field
/// has focus. The toolbar remains the only general-purpose search entry point.
struct GlobalSearchPresentationView: View {
    @Environment(\.container) private var container
    @Binding var query: String
    let onExit: () -> Void

    @State private var viewModel: GlobalSearchPresentationViewModel?
    @State private var scope: GlobalSearchPresentationViewModel.Scope = .library
    @State private var mode: GlobalSearchPresentationViewModel.Mode = .search

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView("Preparing search…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.mlmBase)
        .task { initialize() }
        .onExitCommand(perform: onExit)
    }

    private func content(_ viewModel: GlobalSearchPresentationViewModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Search")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)

                Spacer()

                if viewModel.canSearchAllSources {
                    Picker("Search scope", selection: $scope) {
                        ForEach(GlobalSearchPresentationViewModel.Scope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                Picker("Search mode", selection: $mode) {
                    ForEach(GlobalSearchPresentationViewModel.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if mode == .link {
                Text("Paste a supported link in the search field to resolve download options.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if viewModel.isSearching {
                ProgressView(scope == .allSources ? "Searching sources…" : "Searching library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Search library",
                    systemImage: "magnifyingglass",
                    description: Text("Type in the toolbar search field to search your library.")
                )
            } else {
                results(viewModel)
            }
        }
        .task(id: requestID) {
            if scope == .allSources, mode == .search {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await viewModel.search(query: query, scope: scope, mode: mode)
        }
    }

    private var requestID: String {
        "\(query)|\(scope.rawValue)|\(mode.rawValue)"
    }

    @ViewBuilder
    private func results(_ viewModel: GlobalSearchPresentationViewModel) -> some View {
        if let errorMessage = viewModel.errorMessage {
            searchNotice(errorMessage, color: .mlmError)
        }

        if !viewModel.sourceFailures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                searchNotice(
                    "\(viewModel.sourceFailures.count) sources unreachable — results incomplete",
                    color: .mlmAttention
                )
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

        if viewModel.localResults.isEmpty && viewModel.remoteResults.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                if !viewModel.localResults.isEmpty {
                    Section("Library") {
                        ForEach(viewModel.localResults) { track in
                            localResultRow(track)
                        }
                    }
                }

                ForEach(RemoteSearchResult.Source.allCases, id: \.rawValue) { source in
                    let sourceResults = viewModel.remoteResults.filter { $0.source == source }
                    if !sourceResults.isEmpty {
                        Section(source.rawValue) {
                            ForEach(sourceResults) { result in
                                remoteResultRow(result, viewModel: viewModel)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func searchNotice(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(MLMFont.muted)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    private func localResultRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                Text("\(track.artist) · \(track.album)")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if track.isLocal, let playbackViewModel = container.playbackViewModel {
                Button("Play") {
                    Task { await playbackViewModel.playTrack(track) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func remoteResultRow(
        _ result: RemoteSearchResult,
        viewModel: GlobalSearchPresentationViewModel
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.source.icon)
                .foregroundColor(.mlmInkSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                HStack(spacing: 6) {
                    Text(result.artist)
                    if let duration = result.durationSeconds {
                        Text("·")
                        Text(durationText(duration))
                    }
                }
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)
            }

            Spacer()

            if viewModel.downloading.contains(result.id) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await viewModel.download(result) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Download from \(result.source.rawValue)")
            }
        }
        .padding(.vertical, 2)
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func initialize() {
        guard viewModel == nil,
              let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository,
              let downloadViewModel = container.downloadViewModel else { return }

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
        viewModel = GlobalSearchPresentationViewModel(
            soundCloudClient: soundCloudClient,
            spotifyClient: spotifyClient,
            youtubeDownloader: YouTubeDownloader(),
            dabClient: dabClient,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo,
            downloadViewModel: downloadViewModel
        )
    }
}
