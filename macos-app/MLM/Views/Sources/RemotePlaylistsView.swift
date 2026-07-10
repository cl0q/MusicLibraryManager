import SwiftUI

/// Which streaming source the remote-playlist browser targets.
enum RemotePlaylistSource {
    case soundcloud
    case spotify
    case youtube
}

/// Remote-playlist browser for SoundCloud / Spotify / YouTube — lists the
/// user's playlists (or accepts a URL for YouTube), previews a playlist's
/// tracks, and downloads a chosen slice (all / first N / random N).
struct RemotePlaylistsView: View {
    let source: RemotePlaylistSource

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RemotePlaylistsViewModel?
    @State private var urlInput = ""

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel)
                } else {
                    ProgressView("Lade…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520, minHeight: 460)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .navigationTitle("\(viewModel?.displayName ?? "") Playlists")
        }
        .task {
            initialize()
            await viewModel?.loadPlaylists()
        }
    }

    @ViewBuilder
    private func content(_ vm: RemotePlaylistsViewModel) -> some View {
        if vm.selectedTitle != nil {
            PlaylistDetailView(viewModel: vm)
        } else if vm.allowsURLImport {
            urlImport(vm)
        } else {
            playlistList(vm)
        }
    }

    @ViewBuilder
    private func urlImport(_ vm: RemotePlaylistsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlist-URL einfügen")
                .font(.headline)
            HStack {
                TextField("https://www.youtube.com/playlist?list=…", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                Button("Laden") {
                    Task { await vm.importFromURL(urlInput) }
                }
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if vm.isImporting {
                ProgressView("Playlist wird geladen…")
            }
            if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private func playlistList(_ vm: RemotePlaylistsViewModel) -> some View {
        if vm.isLoading {
            ProgressView("Playlists werden geladen…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(error).multilineTextAlignment(.center)
                Button("Erneut versuchen") { Task { await vm.loadPlaylists() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.playlists.isEmpty {
            Text("Keine Playlists gefunden.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(vm.playlists) { playlist in
                Button {
                    Task { await vm.openPlaylist(playlist) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.title)
                                .font(.body)
                            Text("\(playlist.trackCount) Titel")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Playlist Detail

private struct PlaylistDetailView: View {
    let viewModel: RemotePlaylistsViewModel

    @State private var mode: SelectionMode = .all
    @State private var count: Int = 50

    private enum SelectionMode: String, CaseIterable, Identifiable {
        case all = "Alle"
        case firstN = "Erste N"
        case randomN = "N zufällig"
        var id: String { rawValue }
    }

    private var selection: RemotePlaylistSelection {
        switch mode {
        case .all: return .all
        case .firstN: return .firstN(count)
        case .randomN: return .randomN(count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    viewModel.closePlaylist()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text(viewModel.selectedTitle ?? "")
                .font(.title2).bold()

            if viewModel.isImporting {
                ProgressView("Playlist wird geladen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("\(viewModel.selectedTracks.count) Titel · \(durationText)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let note = viewModel.downloadNote {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                selectionControls

                List(viewModel.selectedTracks, id: \.id) { track in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.body)
                        Text(track.artist).font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(minHeight: 160)

                if let error = viewModel.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                Button {
                    Task { await viewModel.download(selection: selection) }
                } label: {
                    Label("Herunterladen", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedTracks.isEmpty)
            }
        }
        .padding(16)
    }

    private var selectionControls: some View {
        HStack(spacing: 12) {
            Picker("Auswahl", selection: $mode) {
                ForEach(SelectionMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode != .all {
                Stepper(value: $count, in: 1...max(1, viewModel.selectedTracks.count)) {
                    Text("\(count)")
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .fixedSize()
            }
        }
    }

    private var durationText: String {
        let total = viewModel.selectedTotalDurationSeconds
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) Std \(minutes) Min" }
        return "\(minutes) Min"
    }
}

// MARK: - Init helper

extension RemotePlaylistsView {
    private func initialize() {
        guard viewModel == nil,
              let tokenStorage = container.tokenStorage,
              let oauth = container.oauthManager,
              let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository,
              let playlistRepo = container.playlistRepository,
              let downloadVM = container.downloadViewModel else { return }

        let provider: RemotePlaylistProvider
        switch source {
        case .soundcloud:
            let client = SoundCloudClient(
                tokenStorage: tokenStorage,
                oauthManager: oauth,
                trackRepository: trackRepo,
                sourceRepository: sourceRepo,
                playlistRepository: playlistRepo
            )
            provider = SoundCloudPlaylistProvider(client: client)
        case .spotify:
            let client = SpotifyClient(
                tokenStorage: tokenStorage,
                oauthManager: oauth,
                trackRepository: trackRepo,
                sourceRepository: sourceRepo,
                playlistRepository: playlistRepo
            )
            provider = SpotifyPlaylistProvider(client: client)
        case .youtube:
            provider = YouTubePlaylistProvider(
                downloader: YouTubeDownloader(),
                trackRepository: trackRepo,
                sourceRepository: sourceRepo,
                playlistRepository: playlistRepo
            )
        }

        viewModel = RemotePlaylistsViewModel(
            provider: provider,
            playlistRepository: playlistRepo,
            downloadViewModel: downloadVM
        )
    }
}
