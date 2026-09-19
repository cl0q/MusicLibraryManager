import SwiftUI

/// Which streaming source the remote-playlist browser targets.
enum RemotePlaylistSource: Equatable {
    case soundcloud
    case spotify
    case youtube
}

extension RemotePlaylistSource {
    var windowTitle: String {
        switch self {
        case .soundcloud: "SoundCloud Playlists"
        case .spotify:    "Spotify Playlists"
        case .youtube:    "Import YouTube Playlist"
        }
    }
}

/// Remote-playlist browser for SoundCloud, Spotify, and YouTube. Playlist
/// metadata stays staged until the review screen's Save or Download action.
struct RemotePlaylistsView: View {
    let source: RemotePlaylistSource
    var onRequestClose: (() -> Void)? = nil

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RemotePlaylistsViewModel?
    @State private var urlInput = ""
    @State private var showsPersistedPlaylist = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520, minHeight: 460)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onRequestClose {
                            onRequestClose()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(source.windowTitle)
        }
        .task {
            initialize()
            await viewModel?.loadPlaylists()
        }
    }

    @ViewBuilder
    private func content(_ vm: RemotePlaylistsViewModel) -> some View {
        if showsPersistedPlaylist, let playlistID = vm.importResult?.playlistID {
            PlaylistDetailViewLoader(
                playlistId: playlistID,
                onBack: { showsPersistedPlaylist = false },
                onTrackDoubleClick: { _, _ in }
            )
        } else if vm.preview != nil {
            RemotePlaylistDetailView(
                viewModel: vm,
                onOpenPlaylist: { showsPersistedPlaylist = true },
                onDone: {
                    if let onRequestClose { onRequestClose() } else { dismiss() }
                }
            )
        } else {
            browseView(vm)
        }
    }

    /// Combined browse screen — shows the URL bar (when the source supports it)
    /// above the playlist list (when the source supports it). SoundCloud gets
    /// both at once; YouTube gets URL only; Spotify gets list only.
    @ViewBuilder
    private func browseView(_ vm: RemotePlaylistsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.showsURLField {
                urlBar(vm)
                Divider().background(Color.mlmEdge)
            }
            if vm.showsPlaylistList {
                playlistList(vm)
            } else if !vm.showsURLField {
                // Neither surface — should not happen, but show a fallback
                Text("No import method available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Compact URL-import bar pinned above the playlist list. For YouTube
    /// (.urlOnly, no list) this gets the full height; for SoundCloud it sits
    /// above the list without pushing it off-screen.
    @ViewBuilder
    private func urlBar(_ vm: RemotePlaylistsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(urlPlaceholder, text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                Button("Load") {
                    Task { await vm.importFromURL(urlInput) }
                }
                .disabled(
                    vm.isPreviewLoading ||
                        urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                if vm.isPreviewLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let error = vm.errorMessage {
                HStack(spacing: 6) {
                    Text(error)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmError)
                    if vm.shouldOfferSettings {
                        Button("Open Settings") {
                            AppDelegate.shared?.showSettingsWindow()
                        }
                        .font(MLMFont.muted)
                    }
                }
            }
        }
        .padding(12)
    }

    private var urlPlaceholder: String {
        switch source {
        case .youtube:    "https://www.youtube.com/playlist?list=…"
        case .soundcloud: "https://soundcloud.com/…/sets/…"
        case .spotify:    "https://open.spotify.com/playlist/…"
        }
    }

    @ViewBuilder
    private func playlistList(_ vm: RemotePlaylistsViewModel) -> some View {
        if vm.isLoading || vm.isPreviewLoading {
            ProgressView("Loading playlist…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(error).multilineTextAlignment(.center)
                settingsAction(vm)
                Button("Retry") { Task { await vm.loadPlaylists() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.playlists.isEmpty {
            Text("No playlists found")
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
                            HStack(spacing: 4) {
                                Text("\(playlist.trackCount) tracks")
                                if playlist.isPrivate {
                                    Label("Private", systemImage: "lock.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(MLMFont.muted)
                                        .foregroundColor(.mlmInkSecondary)
                                }
                            }
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

    @ViewBuilder
    private func settingsAction(_ vm: RemotePlaylistsViewModel) -> some View {
        if vm.shouldOfferSettings {
            Button("Open Settings") {
                AppDelegate.shared?.showSettingsWindow()
            }
        }
    }
}

// MARK: - Playlist Detail

private struct RemotePlaylistDetailView: View {
    let viewModel: RemotePlaylistsViewModel
    let onOpenPlaylist: () -> Void
    let onDone: () -> Void

    @State private var mode: SelectionMode = .all
    @State private var count: Int = 50
    @State private var countText: String = "50"
    @State private var previewTracks: [RemotePlaylistTrack] = []
    @State private var showsFailedTracks = false

    private enum SelectionMode: String, CaseIterable, Identifiable {
        case all = "All"
        case firstN = "First N"
        case randomN = "Random N"
        var id: String { rawValue }
    }

    /// Recompute the preview list from the current selection. Random is
    /// shuffled once here rather than per render, so this exact list is what
    /// both commit actions receive.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isPersisting {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isDownloading {
                downloadProgress
            } else if let result = viewModel.importResult {
                resultView(result)
            } else {
                review
            }
        }
        .padding(16)
        .onAppear { recomputePreview() }
        .onChange(of: mode) { recomputePreview() }
        .onChange(of: count) { recomputePreview() }
        .onChange(of: viewModel.selectedTracks.count) {
            let maxN = max(1, viewModel.selectedTracks.count)
            if count > maxN {
                count = maxN
                countText = "\(maxN)"
            }
            recomputePreview()
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    viewModel.closePlaylist()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text("\"\(viewModel.selectedTitle ?? "")\" · \(viewModel.selectedTracks.count) tracks · from \(viewModel.displayName)")
                .font(.title2.bold())

            Text("Metadata completes after download")
                .font(.caption)
                .foregroundColor(.secondary)

            if let note = viewModel.downloadNote {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            selectionControls

            List(Array(previewTracks.enumerated()), id: \.element.id) { index, track in
                Text("\(index + 1)  \(track.title)")
            }
            .frame(minHeight: 160)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                if mode == .all {
                    Button("Download All (\(previewTracks.count) tracks)") {
                        Task { await viewModel.downloadAll() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(previewTracks.isEmpty)
                } else {
                    Button("Download \(previewTracks.count) tracks") {
                        Task { await viewModel.download(tracks: previewTracks) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(previewTracks.isEmpty)
                }

                Button("Save without downloading") {
                    Task { await viewModel.save(tracks: previewTracks) }
                }
                .disabled(previewTracks.isEmpty)
            }
        }
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading… \(viewModel.downloadCompletedCount) of \(viewModel.downloadTotalCount)")
                .font(.headline)
            ProgressView(value: viewModel.downloadProgress)
            Button("Cancel") {
                viewModel.cancelDownload()
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: RemotePlaylistImportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.didDownload {
                Text("\(result.downloadedCount) downloaded · \(result.failedCount) failed")
                    .font(.headline)
                if result.failedCount > 0 {
                    Button("Show failed") {
                        showsFailedTracks.toggle()
                    }
                    if showsFailedTracks {
                        failedTracks
                    }
                }
            } else {
                Text("Nothing downloaded yet")
                    .font(.headline)
            }

            HStack {
                Button("Open playlist") {
                    onOpenPlaylist()
                }
                Button("Done") {
                    onDone()
                }
            }
        }
    }

    private var failedTracks: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.failedDownloadItems) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(viewModel.userFacingDownloadFailure(for: item))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 12) {
            Picker("Select:", selection: $mode) {
                ForEach(SelectionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
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
                        .onChange(of: countText) { commitCountText() }

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

    private func commitCountText() {
        let digits = countText.filter(\.isNumber)
        setCount(Int(digits) ?? 0)
    }

    private func setCount(_ value: Int) {
        let maxN = max(1, viewModel.selectedTracks.count)
        let clamped = min(max(1, value), maxN)
        if clamped != count { count = clamped }
        let text = "\(clamped)"
        if countText != text { countText = text }
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
            provider = SoundCloudPlaylistProvider(
                client: client,
                trackRepository: trackRepo,
                sourceRepository: sourceRepo,
                playlistRepository: playlistRepo
            )
        case .spotify:
            let client = SpotifyClient(
                tokenStorage: tokenStorage,
                oauthManager: oauth,
                trackRepository: trackRepo,
                sourceRepository: sourceRepo,
                playlistRepository: playlistRepo
            )
            provider = SpotifyPlaylistProvider(
                client: client,
                trackRepository: trackRepo,
                sourceRepository: sourceRepo,
                playlistRepository: playlistRepo
            )
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
            downloadViewModel: downloadVM
        )
    }
}
