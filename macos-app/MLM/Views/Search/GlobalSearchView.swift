import SwiftUI

/// Global cross-source search — one query, results from SoundCloud, Spotify,
/// YouTube and DAB, each downloadable via its preferred source.
struct GlobalSearchView: View {
    @Environment(\.container) private var container
    @State private var viewModel: GlobalSearchViewModel?
    @State private var mode: Mode = .search
    @State private var linkInput = ""

    private enum Mode: String, CaseIterable, Identifiable {
        case search = "Suche"
        case link = "Link"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView("Lade…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task { initialize() }
    }

    @ViewBuilder
    private func content(_ vm: GlobalSearchViewModel) -> some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if mode == .search {
                searchBar(vm)
            } else {
                linkBar(vm)
            }

            Divider().background(Color.mlmEdge)

            if vm.isSearching {
                ProgressView(mode == .search ? "Suche über alle Quellen…" : "Link wird analysiert…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.results.isEmpty {
                Text(error)
                    .foregroundColor(.mlmInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.results.isEmpty {
                Text(mode == .search
                     ? "Suche ein Lied über alle Quellen hinweg."
                     : "Füge einen Link ein (SoundCloud, YouTube …) für Download-Optionen.")
                    .foregroundColor(.mlmInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList(vm)
            }
        }
        .background(Color.mlmBase)
    }

    private func linkBar(_ vm: GlobalSearchViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundColor(.mlmInkMuted)
            TextField(
                "URL einfügen (z. B. SoundCloud- oder YouTube-Link)…",
                text: $linkInput
            )
            .textFieldStyle(.plain)
            .onSubmit { Task { await vm.resolveLink(linkInput) } }

            Button("Analysieren") { Task { await vm.resolveLink(linkInput) } }
                .disabled(linkInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func searchBar(_ vm: GlobalSearchViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.mlmInkMuted)
            TextField(
                "Künstler oder Titel suchen…",
                text: Binding(get: { vm.query }, set: { vm.query = $0 })
            )
            .textFieldStyle(.plain)
            .onSubmit { Task { await vm.search() } }

            Button("Suchen") { Task { await vm.search() } }
                .disabled(vm.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func resultsList(_ vm: GlobalSearchViewModel) -> some View {
        List(vm.results) { result in
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
                        Text("·")
                        Text(result.source.rawValue)
                        if let d = result.durationSeconds {
                            Text("·")
                            Text(durationText(d))
                        }
                    }
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                }

                Spacer()

                if vm.downloading.contains(result.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await vm.download(result) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Herunterladen über \(result.source.rawValue)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func durationText(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func initialize() {
        guard viewModel == nil,
              let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository,
              let downloadVM = container.downloadViewModel else { return }

        var scClient: SoundCloudClient?
        var spClient: SpotifyClient?
        if let tokenStorage = container.tokenStorage, let oauth = container.oauthManager {
            if tokenStorage.hasCredentials(service: .soundcloud) {
                scClient = SoundCloudClient(
                    tokenStorage: tokenStorage,
                    oauthManager: oauth,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo,
                    playlistRepository: container.playlistRepository
                )
            }
            if tokenStorage.hasCredentials(service: .spotify) {
                spClient = SpotifyClient(
                    tokenStorage: tokenStorage,
                    oauthManager: oauth,
                    trackRepository: trackRepo,
                    sourceRepository: sourceRepo,
                    playlistRepository: container.playlistRepository
                )
            }
        }

        let dab = container.tokenStorage.map { DABClient(tokenStorage: $0) }

        viewModel = GlobalSearchViewModel(
            soundCloudClient: scClient,
            spotifyClient: spClient,
            youtubeDownloader: YouTubeDownloader(),
            dabClient: dab,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo,
            downloadViewModel: downloadVM
        )
    }
}
