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
            RemotePlaylistDetailView(viewModel: vm)
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

private struct RemotePlaylistDetailView: View {
    let viewModel: RemotePlaylistsViewModel

    @State private var mode: SelectionMode = .all
    @State private var count: Int = 50
    @State private var countText: String = "50"
    /// The exact tracks that will be downloaded — what the list shows.
    @State private var previewTracks: [Track] = []

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

    /// Recompute the preview list from the current mode + count. Random is
    /// shuffled once here (not per render) so the preview stays stable and
    /// matches exactly what gets downloaded.
    private func recomputePreview() {
        let all = viewModel.selectedTracks
        switch mode {
        case .all:
            previewTracks = all
        case .firstN:
            previewTracks = Array(all.prefix(max(0, count)))
        case .randomN:
            previewTracks = Array(all.shuffled().prefix(max(0, count)))
        }
    }

    private var previewDurationSeconds: Int {
        previewTracks.reduce(0) { $0 + ($1.duration ?? 0) }
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
                Text("\(previewTracks.count) von \(viewModel.selectedTracks.count) Titeln · \(durationText)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let note = viewModel.downloadNote {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                selectionControls

                List(previewTracks, id: \.id) { track in
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
                    Task { await viewModel.download(tracks: previewTracks) }
                } label: {
                    Label("\(previewTracks.count) herunterladen", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewTracks.isEmpty)
            }
        }
        .padding(16)
        .onAppear { recomputePreview() }
        .onChange(of: mode) { _ in recomputePreview() }
        .onChange(of: count) { _ in recomputePreview() }
        .onChange(of: viewModel.selectedTracks.count) { _ in
            // Clamp N to the newly loaded track count and refresh.
            let maxN = max(1, viewModel.selectedTracks.count)
            if count > maxN { count = maxN; countText = "\(maxN)" }
            recomputePreview()
        }
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
                HStack(spacing: 4) {
                    TextField("N", text: $countText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { commitCountText() }
                        .onChange(of: countText) { _ in commitCountText() }

                    Stepper("") {
                        setCount(count + 1)
                    } onDecrement: {
                        setCount(count - 1)
                    }
                    .labelsHidden()
                }
                .fixedSize()
            }
        }
    }

    /// Parse and clamp the typed N, then refresh the preview.
    private func commitCountText() {
        let digits = countText.filter(\.isNumber)
        let parsed = Int(digits) ?? 0
        setCount(parsed)
    }

    private func setCount(_ value: Int) {
        let maxN = max(1, viewModel.selectedTracks.count)
        let clamped = min(max(1, value), maxN)
        if clamped != count { count = clamped }
        let text = "\(clamped)"
        if countText != text { countText = text }
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
