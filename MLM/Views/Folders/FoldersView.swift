import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// Folder browser — split pane with disk tree (left) and tracks (right).
struct FoldersView: View {
    @Environment(\.container) private var container
    @State private var viewModel: FolderViewModel?
    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    var body: some View {
        Group {
            if let viewModel {
                foldersContent(viewModel)
            } else {
                ProgressView("Loading folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            await viewModel?.loadRootFolders()
            applySearch(container.searchCoordinator.filter(for: .folders))
            openRequestedFolder()
            await reloadPlaylists()
            await reloadSyncProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { note in
            if let ids = note.userInfo?["removedIds"] as? [Int64] {
                viewModel?.removeTracks(ids: Set(ids))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
            Task { await reloadSyncProfiles() }
        }
        // In-place filter (W2-I): the toolbar field filters the folders by name; the view's
        // own filter field is gone (one search field, UC-SEARCH-01).
        .onChange(of: container.searchCoordinator.filter(for: .folders)) { _, filter in
            applySearch(filter)
        }
        // A folder chosen in the search field's Library results.
        .onChange(of: FolderOpenRequest.shared.path) { _, _ in
            openRequestedFolder()
        }
        .onChange(of: viewModel?.selectedFolderPath) { _, _ in
            viewModel?.persistLastSelection()
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
        // The folder count moved from the window toolbar (P-TOOLBAR.E05) to the status bar.
        .statusBarText(StatusBarText.folders(viewModel.folderCount))
    }

    // MARK: - Header

    private func headerBar(_ viewModel: FolderViewModel) -> some View {
        HStack(spacing: 8) {
            Text("Folders")
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

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Search (W2-I)

    private func applySearch(_ filter: SearchFilter) {
        let text = filter.parsed.freeText
        guard let viewModel, viewModel.searchQuery != text else { return }
        viewModel.searchQuery = text
    }

    private func openRequestedFolder() {
        guard let viewModel, let path = FolderOpenRequest.shared.take() else { return }
        Task {
            await viewModel.ensureAncestorsLoaded(for: path)
            viewModel.selectedFolderPath = path
        }
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

    @ViewBuilder
    private func folderTracksPane(_ viewModel: FolderViewModel) -> some View {
        @Bindable var viewModel = viewModel
        
        if !viewModel.searchQuery.isEmpty {
            let results = viewModel.searchResults
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text("Search results for \"\(viewModel.searchQuery)\"")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                    
                    if viewModel.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 4)
                    }
                    
                    Spacer()
                    Text("\(results.count) folders found")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.mlmSurface)
                
                Divider()
                    .background(Color.mlmEdge)
                
                if results.isEmpty && !viewModel.isSearching {
                    VStack {
                        Spacer()
                        ContentUnavailableView.search(text: viewModel.searchQuery)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty && viewModel.isSearching {
                    VStack {
                        Spacer()
                        ProgressView("Searching…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FolderSearchResultsTable(
                        results: results,
                        viewModel: viewModel,
                        onDoubleClick: { node in
                            viewModel.selectedFolderPath = node.id
                            // Opening a found folder ends the filter (the field clears too).
                            search?.clear()
                            viewModel.searchQuery = ""
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.mlmBase)
        } else if let selectedPath = viewModel.selectedFolderPath {
            let selectedNode = viewModel.findNode(for: selectedPath)
            let subfolders = (selectedNode?.children ?? []).filter { !$0.id.hasSuffix("/__placeholder__") }
            let tracks = viewModel.tracksInFolder
            let hasSubfolders = !(selectedNode?.children.isEmpty ?? true)

            VStack(spacing: 0) {
                folderBreadcrumb(selectedPath, viewModel: viewModel)

                Divider()
                    .background(Color.mlmEdge)

                if viewModel.unindexedAudioFileCount > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.mlmAttention)
                        Text("\(viewModel.unindexedAudioFileCount) files in this folder are not in the library")
                            .font(MLMFont.muted)
                            .foregroundStyle(Color.mlmInkSecondary)
                        Spacer()
                        Button("Import") {
                            Task { await importUnindexedFiles(from: selectedPath, viewModel: viewModel) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("folder_import_banner_button")
                        .accessibilityLabel("folder_import_banner_button")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.mlmAttention.opacity(0.1))
                }

                if !hasSubfolders && tracks.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView {
                            Label("Folder is empty", systemImage: "folder")
                        } description: {
                            Text("This folder contains no music tracks or subfolders.")
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasSubfolders && !tracks.isEmpty {
                    VSplitView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text("Subfolders")
                                    .font(MLMFont.sectionHeader)
                                    .foregroundColor(.mlmInk)
                                Text("\(subfolders.count)")
                                    .font(MLMFont.badge)
                                    .foregroundColor(.mlmInkMuted)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.mlmRaised)
                                    .clipShape(Capsule())
                                
                                if viewModel.loadingNodePaths.contains(selectedPath) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            
                            Divider()
                                .background(Color.mlmEdge)

                            FolderSubfoldersTable(
                                subfolders: subfolders,
                                viewModel: viewModel,
                                onDoubleClick: { node in
                                    viewModel.selectedFolderPath = node.id
                                }
                            )
                        }
                        .frame(minHeight: 120, idealHeight: 200, maxHeight: .infinity)

                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Tracks")
                                    .font(MLMFont.sectionHeader)
                                    .foregroundColor(.mlmInk)
                                Text("\(tracks.count)")
                                    .font(MLMFont.badge)
                                    .foregroundColor(.mlmInkMuted)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.mlmRaised)
                                    .clipShape(Capsule())
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            
                            Divider()
                                .background(Color.mlmEdge)

                            FolderTracksTable(
                                tracks: tracks,
                                availabilityByTrackID: viewModel.availabilityByTrackID,
                                selectedTrackIDs: $viewModel.selectedTrackIDs,
                                availablePlaylists: availablePlaylists,
                                availableSyncProfiles: availableSyncProfiles,
                                onDoubleClick: onTrackDoubleClick
                            )
                        }
                        .frame(minHeight: 120, idealHeight: 300, maxHeight: .infinity)
                    }
                } else if hasSubfolders {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text("Subfolders")
                                .font(MLMFont.sectionHeader)
                                .foregroundColor(.mlmInk)
                            Text("\(subfolders.count)")
                                .font(MLMFont.badge)
                                .foregroundColor(.mlmInkMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.mlmRaised)
                                .clipShape(Capsule())
                            
                            if viewModel.loadingNodePaths.contains(selectedPath) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        
                        Divider()
                            .background(Color.mlmEdge)

                        FolderSubfoldersTable(
                            subfolders: subfolders,
                            viewModel: viewModel,
                            onDoubleClick: { node in
                                viewModel.selectedFolderPath = node.id
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Tracks")
                                .font(MLMFont.sectionHeader)
                                .foregroundColor(.mlmInk)
                            Text("\(tracks.count)")
                                .font(MLMFont.badge)
                                .foregroundColor(.mlmInkMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.mlmRaised)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        
                        Divider()
                            .background(Color.mlmEdge)

                        FolderTracksTable(
                            tracks: tracks,
                            availabilityByTrackID: viewModel.availabilityByTrackID,
                            selectedTrackIDs: $viewModel.selectedTrackIDs,
                            availablePlaylists: availablePlaylists,
                            availableSyncProfiles: availableSyncProfiles,
                            onDoubleClick: onTrackDoubleClick
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.mlmBase)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 36))
                    .foregroundColor(.mlmInkMuted)
                Text("Select a folder")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                Text("Select a folder from the tree on the left to view its tracks.")
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
            .help("Show in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.mlmSurface)
    }

    // MARK: - States

    private var driveNotMountedState: some View {
        ContentUnavailableView {
            Label("Drive not connected", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text("The external drive containing the music library is not connected.")
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading folder structure…")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ viewModel: FolderViewModel) -> some View {
        Group {
            if viewModel.searchQuery.isEmpty {
                ContentUnavailableView {
                    Label("No folders", systemImage: "folder")
                } description: {
                    Text("Import music to view the folder structure.")
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

    private func importUnindexedFiles(from path: String, viewModel: FolderViewModel) async {
        guard let importService = container.importService, let config = container.configRepository else { return }
        // W3-ACT: through the registered import — `Scan “‹folder›”` with progress, Cancel and its
        // result in Activity (was silent, errors swallowed). It posts the import notifications.
        let importer = ImportViewModel(importService: importService, configRepository: config, activity: .shared)
        await importer.importFromDirectory(URL(fileURLWithPath: path))
        await viewModel.refresh()
    }

}

// MARK: - Folder Tracks Table

struct FolderTracksTable: View {
    let tracks: [Track]
    let availabilityByTrackID: [Int64: TrackAvailability]
    @Binding var selectedTrackIDs: Set<Int64>
    var availablePlaylists: [Playlist]
    var availableSyncProfiles: [SyncProfile]
    var onDoubleClick: ((Track, [Track]) -> Void)?

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
        Table(selection: $selectedTrackIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.track.title) { row in
                HStack(spacing: 6) {
                    if isNowPlaying(row.track) {
                        Image(systemName: "speaker.wave.2.fill")
                            .imageScale(.small)
                            .foregroundStyle(Color.mlmAccent)
                            .symbolEffect(.variableColor, isActive: true)
                    }
                    Text(row.track.title)
                        .lineLimit(1)
                        .foregroundStyle(isNowPlaying(row.track) ? Color.mlmAccent : Color.mlmInk)
                }
            }
            .width(min: 140, ideal: 260)

            TableColumn("Artist", value: \.track.artist) { row in
                TrackMetadataText(row.track.artist, secondary: true)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Album", value: \.track.album) { row in
                TrackMetadataText(row.track.album, secondary: true)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Time", value: \.track.durationSortKey) { row in
                Text(row.track.formattedDuration)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(54)

            TableColumn("Format", value: \.track.format) { row in
                Text(displayFormat(for: row.track))
                    .foregroundStyle(.secondary)
            }
            .width(60)

            TableColumn("Source") { row in
                Text(TrackMetadataPresentation.sourceName(for: row.track))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(100)

            TableColumn("Status") { row in
                if let trackID = row.track.id,
                   let availability = availabilityByTrackID[trackID],
                   let statusChip = StatusChip(availability: availability) {
                    statusChip
                }
            }
            .width(90)

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

            TableColumn("Dance", value: \.track.danceabilitySortKey) { row in
                DanceabilitySteps(score: row.track.danceability)
            }
            .width(56)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    // The shared track payload: ids + the local file (W2-H, D-FOLD-TRACKS-OUT).
                    .draggable(TrackDragContext.current(.shared).item(for: row.track)
                        ?? TrackDragItem(trackId: row.id, libraryId: nil))
            }
        }
        .contextMenu(forSelectionType: Int64.self) { selectedIDs in
            TrackContextMenu(
                selectedTrackIDs: selectedIDs,
                tracks: tracks,
                availablePlaylists: availablePlaylists,
                availableSyncProfiles: availableSyncProfiles,
                addToSyncProfile: { profile in
                    Task {
                        container.syncViewModel?.selectedProfile = profile
                        await container.syncViewModel?.addTracks(Array(selectedIDs))
                    }
                }
            )
        } primaryAction: { selectedIDs in
            if let trackID = selectedIDs.first,
               let track = tracks.first(where: { $0.id == trackID }) {
                onDoubleClick?(track, rows.map(\.track))
            }
        }
        .accessibilityIdentifier("folders_tracks_table")
        .accessibilityLabel("folders_tracks_table")
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

    private func displayFormat(for track: Track) -> String {
        let format = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
        return format.isEmpty ? "—" : format.uppercased()
    }
}

// MARK: - Folder Subfolders Table

struct FolderSubfoldersTable: View {
    let subfolders: [DiskFolderNode]
    let viewModel: FolderViewModel
    var onDoubleClick: (DiskFolderNode) -> Void

    private struct FolderRow: Identifiable {
        let id: String
        let node: DiskFolderNode
    }

    @State private var selectedFolderID: String?
    @State private var sortOrder: [KeyPathComparator<FolderRow>] = [
        KeyPathComparator(\.node.name, order: .forward)
    ]

    private var rows: [FolderRow] {
        subfolders
            .map { FolderRow(id: $0.id, node: $0) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(selection: $selectedFolderID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.node.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                        .imageScale(.medium)
                    Text(row.node.name)
                        .lineLimit(1)
                }
            }
            .width(min: 150, ideal: 300)

            TableColumn("Subfolders", value: \.node.children.count.description) { row in
                Text(row.node.children.isEmpty ? "—" : "\(row.node.children.count)")
                    .foregroundColor(.secondary)
            }
            .width(100)

            TableColumn("Path", value: \.node.id) { row in
                Text(viewModel.relativePath(for: row.node.id))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 300)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let firstID = selectedIDs.first {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: firstID)
                }
            }
        } primaryAction: { selectedIDs in
            if let firstID = selectedIDs.first,
               let node = subfolders.first(where: { $0.id == firstID }) {
                onDoubleClick(node)
            }
        }
        .accessibilityIdentifier("folders_subfolders_table")
        .accessibilityLabel("folders_subfolders_table")
    }
}

// MARK: - Folder Search Results Table

struct FolderSearchResultsTable: View {
    let results: [DiskFolderNode]
    let viewModel: FolderViewModel
    var onDoubleClick: (DiskFolderNode) -> Void

    private struct FolderRow: Identifiable {
        let id: String
        let node: DiskFolderNode
    }

    @State private var selectedFolderID: String?
    @State private var sortOrder: [KeyPathComparator<FolderRow>] = [
        KeyPathComparator(\.node.name, order: .forward)
    ]

    private var rows: [FolderRow] {
        results
            .map { FolderRow(id: $0.id, node: $0) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(selection: $selectedFolderID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.node.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                        .imageScale(.medium)
                    Text(row.node.name)
                        .lineLimit(1)
                }
            }
            .width(min: 150, ideal: 300)

            TableColumn("Subfolders", value: \.node.children.count.description) { row in
                Text(row.node.children.isEmpty ? "—" : "\(row.node.children.count)")
                    .foregroundColor(.secondary)
            }
            .width(100)

            TableColumn("Path", value: \.node.id) { row in
                Text(viewModel.relativePath(for: row.node.id))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .width(min: 200, ideal: 400)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let firstID = selectedIDs.first {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: firstID)
                }
            }
        } primaryAction: { selectedIDs in
            if let firstID = selectedIDs.first,
               let node = results.first(where: { $0.id == firstID }) {
                onDoubleClick(node)
            }
        }
    }
}
