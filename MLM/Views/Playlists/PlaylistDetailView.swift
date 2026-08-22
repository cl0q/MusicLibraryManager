import SwiftUI
import UniformTypeIdentifiers

/// Playlist detail view — track list with drag-and-drop reorder,
/// search, add/remove tracks, and M3U import.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │  ← Back    My Playlist    18 tracks     🔍 Search   [+ Add] │  Header
/// ├──────────────────────────────────────────────────────────────┤
/// │  # │ Title        │ Artist     │ Album      │ Duration       │  Table
/// │  1 │ Track One    │ Artist A   │ Album X    │ 3:24           │
/// │  2 │ Track Two    │ Artist B   │ Album Y    │ 4:01           │
/// │  ⋮ │ (drag to reorder)                                      │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// Phase 6 implementation. Drag-and-drop uses `onMove` for SwiftUI List
/// reordering with fractional positions persisted to the database.
struct PlaylistDetailView: View {
    let playlist: Playlist
    var initiallyShowFailedTracks = false
    var onBack: () -> Void
    var onTrackDoubleClick: ((Track) -> Void)?

    @Environment(\.container) private var container
    @State private var viewModel: PlaylistDetailViewModel?
    @State private var showM3UImporter = false
    @State private var showAddFromLibrary = false
    @State private var tracksPendingRemoval: Set<Int64> = []
    @State private var showingRemoveTracksConfirmation = false
    @State private var failureDisclosureExpanded = false

    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []

    var body: some View {
        Group {
            if let viewModel {
                VStack(spacing: 0) {
                    headerBar(viewModel)

                    Divider()
                        .background(Color.mlmEdge)

                    if viewModel.displayedTracks.isEmpty && !viewModel.isLoading {
                        emptyState(viewModel)
                    } else {
                        trackList(viewModel)
                    }
                }
                .background(Color.mlmBase)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            failureDisclosureExpanded = initiallyShowFailedTracks
            await viewModel?.loadTracks()
            await loadPlaylistsAndProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadStateDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in
            Task { await viewModel?.refreshAvailabilitySnapshot() }
        }
        .onAppear {
            // Revalidate the detail playlist's cover when the view becomes visible.
            // Handles the case where backfill ran while navigated away.
            guard let pid = playlist.id else { return }
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": pid]
            )
        }
        .fileImporter(
            isPresented: $showM3UImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "m3u") ?? .plainText,
                UTType(filenameExtension: "m3u8") ?? .plainText
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await viewModel?.importM3U(url) }
            }
        }
        .alert("Remove tracks", isPresented: $showingRemoveTracksConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                viewModel?.selectedTrackIDs = tracksPendingRemoval
                tracksPendingRemoval = []
                Task { await viewModel?.removeSelectedTracks() }
            }
        } message: {
            Text("Remove \(tracksPendingRemoval.count) tracks from this playlist? This does not delete any files.")
        }
    }

    // MARK: - Header

    private func headerBar(_ viewModel: PlaylistDetailViewModel) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Back button
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Playlists")
                            .font(MLMFont.body)
                    }
                    .foregroundColor(.mlmAccent)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            HStack(alignment: .bottom, spacing: 12) {
                // Playlist cover / icon
                ZStack {
                    if let coverImage = loadCoverImage() {
                        Image(nsImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: categoryGradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)

                        Image(systemName: categoryIcon)
                            .font(.system(size: 24))
                            .foregroundColor(playlist.isLiked == 1 || playlist.isSmart == 1 || playlist.sourceId != nil ? .white.opacity(0.9) : .mlmAccent)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Playlist name
                    Text(viewModel.playlist.name)
                        .font(MLMFont.heroTitle)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)

                    // Playlist provenance is sourced from the linked source row.
                    HStack(spacing: 8) {
                        Text(provenanceLine(for: viewModel))
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInkSecondary)
                            .help(provenanceHelp(for: viewModel))
                            .accessibilityIdentifier("playlist_detail_provenance_help")
                            .accessibilityLabel(provenanceHelp(for: viewModel))
                    }
                }

                Spacer()

                // Actions
                actionButtons(viewModel)
            }

            if let error = viewModel.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.mlmError)
                        .font(MLMFont.muted)
                    Spacer()
                }
                .padding(.top, 4)
            }

            playlistDownloadStatus(viewModel)

            if !viewModel.failedTracks.isEmpty {
                failedTracksDisclosure(viewModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Action Buttons

    private func actionButtons(_ viewModel: PlaylistDetailViewModel) -> some View {
        HStack(spacing: 8) {
            if let firstLocalTrack = viewModel.playableTracks.first {
                Button {
                    onTrackDoubleClick?(firstLocalTrack)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.downloadStatus.missingTracks > 0 {
                Button {
                    Task { await downloadMissingTracks(viewModel) }
                } label: {
                    Label(
                        "Download missing (\(viewModel.downloadStatus.missingTracks))",
                        systemImage: "arrow.down.circle"
                    )
                }
                .buttonStyle(.bordered)
            }

            // Sync button
            if viewModel.canSync {
                Button {
                    Task { await viewModel.syncSource() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(viewModel.isSyncingSource ? 360 : 0))
                            .animation(viewModel.isSyncingSource ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isSyncingSource)
                        Text(viewModel.isSyncingSource ? "Syncing…" : "Sync")
                    }
                    .font(MLMFont.body)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSyncingSource)
            }

            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.mlmInkMuted)
                TextField("Search tracks…", text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .frame(width: 140)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Import M3U
            Button {
                showM3UImporter = true
            } label: {
                Label("Import M3U…", systemImage: "doc.badge.plus")
                    .font(MLMFont.body)
            }
            .buttonStyle(.bordered)

            // Remove selected
            if !viewModel.selectedTrackIDs.isEmpty {
                Button(role: .destructive) {
                    requestTrackRemoval(viewModel.selectedTrackIDs, using: viewModel)
                } label: {
                    Label("Remove \(viewModel.selectedTrackIDs.count)", systemImage: "minus.circle")
                        .font(MLMFont.body)
                }
                .buttonStyle(.bordered)
                .tint(.mlmError)
            }
        }
    }

    // MARK: - Track List

    private func trackList(_ viewModel: PlaylistDetailViewModel) -> some View {
        PlaylistTable(
            playlist: playlist,
            viewModel: viewModel,
            availablePlaylists: availablePlaylists,
            availableSyncProfiles: availableSyncProfiles,
            onTrackDoubleClick: onTrackDoubleClick,
            onRemoveTracks: { ids in
                requestTrackRemoval(ids, using: viewModel)
            }
        )
        .background(Color.mlmBase)
    }

    @ViewBuilder
    private func playlistDownloadStatus(_ viewModel: PlaylistDetailViewModel) -> some View {
        let status = viewModel.downloadStatus
        if status.isImporting {
            HStack(spacing: 8) {
                StatusChip(
                    text: "Downloading · \(status.localTracks) of \(status.totalTracks)",
                    systemImage: "arrow.down.circle",
                    tint: .mlmActive
                )
                ProgressView(value: Double(status.localTracks), total: Double(max(status.totalTracks, 1)))
                    .frame(maxWidth: 180)
                Spacer()
            }
        } else if status.isIncomplete {
            HStack(spacing: 8) {
                StatusChip(
                    text: "\(status.failedTracks) of \(status.totalTracks) tracks failed to download",
                    systemImage: "exclamationmark.triangle",
                    tint: .mlmAttention
                )
                Button("Show") {
                    failureDisclosureExpanded = true
                }
                Button("Retry all") {
                    Task { await retryFailedTracks(using: viewModel) }
                }
                Spacer()
            }
        }
    }

    private func failedTracksDisclosure(_ viewModel: PlaylistDetailViewModel) -> some View {
        let failedTracks = viewModel.failedTracks
        let indexedTracks = Array(failedTracks.enumerated())
        return DisclosureGroup(
            "Failed tracks (\(failedTracks.count))",
            isExpanded: $failureDisclosureExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(indexedTracks, id: \.offset) { _, track in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(track.artist) — \(track.title)")
                                .font(MLMFont.body)
                            Text(track.downloadFailureRecord?.reason ?? "Download failed")
                                .font(MLMFont.muted)
                                .foregroundStyle(Color.mlmInkSecondary)
                            Text(DownloadRetryBudget.remainingText(for: track.downloadFailureRecord))
                                .font(MLMFont.muted)
                                .foregroundStyle(Color.mlmInkMuted)
                        }
                        Spacer()
                        if track.downloadFailureRecord?.reason.localizedCaseInsensitiveContains("open Settings") == true {
                            Button("Open Settings") {
                                Task { @MainActor in AppDelegate.shared?.showSettingsWindow() }
                            }
                        }
                        if track.id != nil {
                            Button("Retry") {
                                Task { await retryFailedTrack(track, using: viewModel) }
                            }
                        }
                        Button("Remove", role: .destructive) {
                            guard let trackID = track.id else { return }
                            requestTrackRemoval([trackID], using: viewModel)
                        }
                    }
                }

                HStack {
                    Button("Retry all") {
                        Task { await retryFailedTracks(using: viewModel) }
                    }
                    Button("Remove failed tracks from playlist", role: .destructive) {
                        requestTrackRemoval(
                            Set(viewModel.failedTracks.compactMap(\.id)),
                            using: viewModel
                        )
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Empty State

    private func emptyState(_ viewModel: PlaylistDetailViewModel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundColor(.mlmInkMuted)

            if viewModel.searchQuery.isEmpty {
                Text("No Tracks")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Add tracks from the Library via right-click → Add to Playlist,\nor import an M3U playlist file.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                Button {
                    showM3UImporter = true
                } label: {
                    Label("Import M3U…", systemImage: "doc.badge.plus")
                        .font(MLMFont.bodyBold)
                }
                .buttonStyle(.bordered)
            } else {
                Text("No matching tracks")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func requestTrackRemoval(_ trackIDs: Set<Int64>, using viewModel: PlaylistDetailViewModel) {
        guard !trackIDs.isEmpty else { return }

        guard trackIDs.count > 1 else {
            if let trackID = trackIDs.first {
                Task { await viewModel.removeTrack(trackID) }
            }
            return
        }

        tracksPendingRemoval = trackIDs
        showingRemoveTracksConfirmation = true
    }

    private func downloadMissingTracks(_ viewModel: PlaylistDetailViewModel) async {
        let missingTracks = viewModel.notDownloadedTracks
        guard !missingTracks.isEmpty else { return }
        await container.downloadViewModel?.downloadTracks(
            missingTracks,
            preferredSource: viewModel.downloadPin
        )
    }

    private func retryFailedTracks(using viewModel: PlaylistDetailViewModel) async {
        let failedTracks = viewModel.failedTracks
        guard !failedTracks.isEmpty else { return }
        await container.downloadViewModel?.downloadTracks(
            failedTracks,
            preferredSource: viewModel.downloadPin
        )
    }

    private func retryFailedTrack(_ track: Track, using viewModel: PlaylistDetailViewModel) async {
        guard case .failed = viewModel.availability(for: track) else { return }
        await container.downloadViewModel?.downloadTracks(
            [track],
            preferredSource: viewModel.downloadPin
        )
    }

    private func formatColor(_ format: String) -> Color {
        switch format.lowercased() {
        case "flac", "alac": return .mlmSuccess
        case "mp3": return .mlmActive
        case "aac", "m4a": return .mlmWarning
        case "ogg": return .mlmAccent
        default: return .mlmInkMuted
        }
    }

    private func initializeViewModel() {
        guard viewModel == nil,
              let playlistRepo = container.playlistRepository,
              let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository else { return }
        viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepo,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo,
            configRepository: container.configRepository
        )
    }

    private func provenanceLine(for viewModel: PlaylistDetailViewModel) -> String {
        let trackCount = viewModel.tracks.count
        var components = ["\(trackCount) track\(trackCount == 1 ? "" : "s")"]

        if let source = viewModel.source {
            components.append("Linked to \(source.playlistSourceIdentity.displayName)")
            if let importedDate = formattedImportDate(viewModel.playlist.dateCreated) {
                components.append("imported \(importedDate)")
            }
        }

        return components.joined(separator: " · ")
    }

    private func provenanceHelp(for viewModel: PlaylistDetailViewModel) -> String {
        guard let source = viewModel.source else { return "Local playlist" }
        return "Linked to \(source.playlistSourceIdentity.displayName)"
    }

    private func formattedImportDate(_ dateString: String?) -> String? {
        guard let dateString else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: dateString) {
            return Self.importDateFormatter.string(from: date)
        }

        let sqliteFormatter = DateFormatter()
        sqliteFormatter.locale = Locale(identifier: "en_US_POSIX")
        sqliteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = sqliteFormatter.date(from: dateString) else { return nil }
        return Self.importDateFormatter.string(from: date)
    }

    private static let importDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private func loadPlaylistsAndProfiles() async {
        if let repo = container.playlistRepository {
            availablePlaylists = (try? await repo.fetchAll()) ?? []
        }
        if let syncVM = container.syncViewModel {
            if syncVM.profiles.isEmpty {
                await syncVM.loadProfiles()
            }
            availableSyncProfiles = syncVM.profiles
        }
    }

    // MARK: - Header Artwork & Fallbacks

    private func loadCoverImage() -> NSImage? {
        guard let relPath = playlist.coverImagePath else { return nil }
        let fileName = (relPath as NSString).lastPathComponent
        let url = coversDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private var coversDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.musiclibrary.app")
            .appendingPathComponent("playlist-covers")
    }

    private var categoryIcon: String {
        if playlist.isLiked == 1 {
            return "heart.fill"
        }
        if playlist.isSmart == 1 {
            return "wand.and.stars"
        }
        switch playlist.category {
        case "regular": return "music.note.list"
        case "liked": return "heart.fill"
        case "album": return "opticaldisc"
        default: return "music.note.list"
        }
    }

    private var categoryGradient: [Color] {
        if playlist.isLiked == 1 {
            return [Color.mlmError.opacity(0.6), Color.mlmError.opacity(0.3)]
        }
        if playlist.isSmart == 1 {
            return [Color.mlmActive.opacity(0.6), Color.mlmActive.opacity(0.3)]
        }
        if playlist.sourceId != nil {
            return [Color.mlmAccent.opacity(0.4), Color.mlmAccent.opacity(0.2)]
        }
        return [Color.mlmRaised, Color.mlmSurface]
    }
}
