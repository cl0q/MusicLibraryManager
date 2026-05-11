import SwiftUI

/// Folder browser — split pane with disk tree (left) and tracks (right).
struct FoldersView: View {
    @Environment(\.container) private var container
    @State private var viewModel: FolderViewModel?

    var onTrackDoubleClick: ((Track) -> Void)?

    var body: some View {
        Group {
            if let viewModel {
                foldersContent(viewModel)
            } else {
                ProgressView("Ordner werden geladen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            await viewModel?.loadRootFolders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in
            Task { await viewModel?.refresh() }
        }
    }

    // MARK: - Content

    private func foldersContent(_ viewModel: FolderViewModel) -> some View {
        VStack(spacing: 0) {
            headerBar(viewModel)

            Divider()
                .background(Color.mlmEdge)

            if viewModel.isDriveNotMounted {
                driveNotMountedState
            } else if viewModel.isLoading && viewModel.rootNodes.isEmpty {
                loadingState
            } else if viewModel.rootNodes.isEmpty {
                emptyState(viewModel)
            } else {
                splitPane(viewModel)
            }
        }
        .background(Color.mlmBase)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("\(viewModel.folderCount) Ordner")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
        }
    }

    // MARK: - Header

    private func headerBar(_ viewModel: FolderViewModel) -> some View {
        HStack(spacing: 8) {
            Text("Ordner")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)

            Text("\(viewModel.folderCount)")
                .font(MLMFont.badge)
                .foregroundColor(.mlmInkMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.mlmRaised)
                .clipShape(Capsule())

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.mlmInkMuted)

                TextField("Ordner filtern…", text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(MLMFont.body)
                .frame(width: 180)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.mlmInkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.mlmRaised)
            .cornerRadius(6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Split Pane

    private func splitPane(_ viewModel: FolderViewModel) -> some View {
        HSplitView {
            FolderTreeView(viewModel: viewModel)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)

            folderTracksPane(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tracks Pane

    @ViewBuilder
    private func folderTracksPane(_ viewModel: FolderViewModel) -> some View {
        @Bindable var viewModel = viewModel
        if let selectedPath = viewModel.selectedFolderPath {
            VStack(spacing: 0) {
                folderBreadcrumb(selectedPath, viewModel: viewModel)

                Divider()
                    .background(Color.mlmEdge)

                if viewModel.tracksInFolder.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Tracks in diesem Ordner", systemImage: "music.note")
                    } description: {
                        Text("Tracks können in Unterordnern liegen.")
                    }
                } else {
                    FolderTracksTable(
                        tracks: viewModel.tracksInFolder,
                        selectedTrackIDs: $viewModel.selectedTrackIDs,
                        onDoubleClick: onTrackDoubleClick
                    )
                }
            }
            .background(Color.mlmBase)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 36))
                    .foregroundColor(.mlmInkMuted)
                Text("Ordner auswählen")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                Text("Wähle einen Ordner aus dem Baum links, um die enthaltenen Tracks zu sehen.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mlmBase)
        }
    }

    // MARK: - Breadcrumb

    private func folderBreadcrumb(_ path: String, viewModel: FolderViewModel) -> some View {
        let relPath = viewModel.relativePath(for: path)
        let segments = relPath.split(separator: "/").map(String.init)
        let rootPath = viewModel.libraryRootURL?.path ?? ""
        let rootPrefix = rootPath.isEmpty ? "" : (rootPath.hasSuffix("/") ? rootPath : rootPath + "/")

        return HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(.accentColor)

            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.mlmInkMuted)
                }

                let relPart = segments.prefix(index + 1).joined(separator: "/")
                let fullSegPath = rootPrefix + relPart

                Button {
                    viewModel.selectedFolderPath = fullSegPath
                } label: {
                    Text(segment)
                        .font(MLMFont.body)
                        .foregroundColor(
                            index == segments.count - 1 ? .mlmInk : .mlmInkSecondary
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("\(viewModel.tracksInFolder.count) Tracks")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)

            Button {
                viewModel.revealInFinder()
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.mlmInkSecondary)
            }
            .buttonStyle(.plain)
            .help("In Finder anzeigen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.mlmSurface)
    }

    // MARK: - States

    private var driveNotMountedState: some View {
        ContentUnavailableView {
            Label("Laufwerk nicht verbunden", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text("Die externe Festplatte mit der Musikbibliothek ist nicht eingehängt.")
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Ordnerstruktur wird geladen…")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ viewModel: FolderViewModel) -> some View {
        Group {
            if viewModel.searchQuery.isEmpty {
                ContentUnavailableView {
                    Label("Keine Ordner", systemImage: "folder")
                } description: {
                    Text("Musik importieren, um die Ordnerstruktur zu sehen.")
                }
            } else {
                ContentUnavailableView.search(text: viewModel.searchQuery)
            }
        }
    }

    // MARK: - Helpers

    private func initializeViewModel() {
        guard viewModel == nil,
              let trackRepo = container.trackRepository,
              let configRepo = container.configRepository else { return }
        viewModel = FolderViewModel(trackRepository: trackRepo, configRepository: configRepo)
    }
}

// MARK: - Folder Tracks Table

struct FolderTracksTable: View {
    let tracks: [Track]
    @Binding var selectedTrackIDs: Set<Int64>
    var onDoubleClick: ((Track) -> Void)?

    @Environment(\.container) private var container

    private struct TrackRow: Identifiable {
        let id: Int64
        let track: Track
    }

    @State private var sortOrder: [KeyPathComparator<TrackRow>] = [
        KeyPathComparator(\.track.title, order: .forward)
    ]

    private var rows: [TrackRow] {
        tracks
            .compactMap { t in t.id.map { TrackRow(id: $0, track: t) } }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selectedTrackIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.track.title) { row in
                HStack(spacing: 6) {
                    if isNowPlaying(row.track) {
                        Image(systemName: "speaker.wave.2.fill")
                            .imageScale(.small)
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor, isActive: true)
                    }
                    Text(row.track.title).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 260)

            TableColumn("Album", value: \.track.album) { row in
                Text(row.track.album).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Time", value: \.track.durationSortKey) { row in
                Text(row.track.formattedDuration)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(54)

            TableColumn("Format", value: \.track.format) { row in
                Text(row.track.format.uppercased())
                    .foregroundStyle(.secondary)
            }
            .width(60)

            TableColumn("kbps", value: \.track.bitrateSortKey) { row in
                Text(row.track.bitrate.map { "\($0)" } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(48)

            TableColumn("Energy", value: \.track.energySortKey) { row in
                EnergyBars(level: row.track.energyBucket)
            }
            .width(56)
        }
        .contextMenu(forSelectionType: Int64.self) { selectedIDs in
            TrackContextMenu(
                selectedTrackIDs: selectedIDs,
                tracks: tracks,
                availablePlaylists: []
            )
        } primaryAction: { selectedIDs in
            if let trackID = selectedIDs.first,
               let track = tracks.first(where: { $0.id == trackID }) {
                onDoubleClick?(track)
            }
        }
    }

    private func isNowPlaying(_ track: Track) -> Bool {
        guard let playbackVM = container.playbackViewModel,
              let currentTrack = playbackVM.currentTrack,
              let currentID = currentTrack.id,
              let trackID = track.id else {
            return false
        }
        return currentID == trackID && playbackVM.isPlaying
    }
}
