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
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @Environment(\.container) private var container
    @Environment(\.openSettings) private var openSettings
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?
    @State private var viewModel: PlaylistDetailViewModel?
    @State private var showM3UImporter = false
    @State private var showAddFromLibrary = false
    @State private var failureDisclosureExpanded = false

    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []

    // WP4 — Ingest preview sheet state
    @State private var ingestVM: PlaylistIngestViewModel?
    @State private var pendingIngestURL: URL?
    @State private var showIngestPreview = false
    @State private var ingestSuccessMessage: String?
    @State private var coverImage: NSImage?
    /// A refused cover drop's sentence, in the header for 5 s (UC-SURF-04, W2-H).
    @State private var coverRefusal: String?
    /// Bumped when the cover service rewrote this playlist's picture (same file name).
    @State private var coverRevision = 0

    // Source-linking sheet state
    @State private var showLinkSheet = false
    @State private var linkURLText = ""
    @State private var showLinkMismatchAlert = false
    @State private var linkSuccessMessage: String?
    @State private var lastValidatedPhase: PlaylistDetailViewModel.LinkCheckPhase?

    var body: some View {
        Group {
            if let viewModel {
                VStack(spacing: 0) {
                    headerBar(viewModel)

                    Divider()
                        .background(Color.mlmEdge)

                    if viewModel.displayedTracks.isEmpty && !viewModel.isLoading {
                        emptyState(viewModel)
                            // Drop targets stay active on an empty state (UC-EMPTY-01): what
                            // lands here is added like on the playlist's sidebar row.
                            .dropTarget(.sidebarPlaylist(id: playlist.id ?? -1, name: viewModel.playlist.name),
                                           cornerRadius: 0)
                    } else {
                        trackList(viewModel)
                    }
                }
                .background(Color.mlmBase)
                // Track ▸ Refresh from ‹Source› ⌘R for a linked playlist (W1-2, UC-KEY-15).
                .focusedSceneValue(\.playlistSourceRefresh, sourceRefresh)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            initializeViewModel()
            viewModel?.searchFilter = container.searchCoordinator.filter(for: .playlist(playlist.id ?? -1))
            failureDisclosureExpanded = initiallyShowFailedTracks
            // Run track loading and sidebar data fetches concurrently —
            // the table doesn't depend on playlists/profiles, so loading
            // them sequentially added ~100-200ms of fixed latency.
            async let loadTracks: () = viewModel?.loadTracks() ?? ()
            async let loadPlaylists: () = loadPlaylistsAndProfiles()
            _ = await (loadTracks, loadPlaylists)
        }
        // In-place filter (W2-I): this playlist's own filter, text and tokens.
        .onChange(of: container.searchCoordinator.filter(for: .playlist(playlist.id ?? -1))) { _, filter in
            guard filter != viewModel?.searchFilter else { return }
            viewModel?.searchFilter = filter
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            // A new picture under the same file name (custom cover, its undo): reload it.
            if (note.userInfo?["origin"] as? String) == "coverService",
               note.userInfo?["playlistId"] as? Int64 == playlist.id {
                coverRevision += 1
            }
            // Cover-revalidation noise (tagged by PlaylistDetailView.onAppear /
            // PlaylistsView.onAppear / PlaylistCoverService) must NOT trigger a
            // track refetch. Only real mutations (untagged or with a playlistId
            // matching this playlist) invalidate the cache and refresh.
            if let userInfo = note.userInfo {
                if userInfo["coverRevalidation"] != nil { return }
                if (userInfo["origin"] as? String) == "coverService" { return }
            }
            if let userInfo = note.userInfo,
               let notifiedId = userInfo["playlistId"] as? Int64,
               let selfId = playlist.id,
               notifiedId != selfId {
                return
            }
            Task {
                if let selfId = playlist.id {
                    container.playlistTableCache?.invalidate(playlistId: selfId)
                } else {
                    container.playlistTableCache?.invalidateAll()
                }
                await viewModel?.refresh()
            }
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
            // Tagged coverRevalidation so PlaylistDetailView's own track-refresh
            // receiver (and other detail views) skip this noise.
            guard let pid = playlist.id else { return }
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": pid, "coverRevalidation": pid]
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
                // WP4: Route through the ingest engine for diff preview
                Task { await startIngestPreview(for: url) }
            }
        }
        .sheet(isPresented: $showIngestPreview) {
            if let ingestVM, let preview = ingestVM.preview, let url = pendingIngestURL {
                IngestPreviewView(
                    preview: preview,
                    sourceFileName: url.lastPathComponent,
                    onApply: {
                        Task {
                            // Use sentinel profileId -1 for standalone imports (no profile context)
                            // The engine treats this as "diff against empty snapshot" → append behavior
                            let playlistId = await ingestVM.apply(url: url, profileId: -1)
                            if playlistId != nil {
                                showIngestPreview = false
                                ingestSuccessMessage = "Imported \(preview.added.count) track\(preview.added.count == 1 ? "" : "s")"
                                await viewModel?.refresh()
                                NotificationCenter.default.post(
                                    name: .playlistDidChange,
                                    object: nil,
                                    userInfo: ["playlistId": playlistId!]
                                )
                            }
                        }
                    },
                    onCancel: {
                        ingestVM.cancel()
                        showIngestPreview = false
                    },
                    isApplying: ingestVM.isApplying,
                    applyError: ingestVM.errorMessage
                )
            }
        }
        .alert("Import Complete", isPresented: Binding(
            get: { ingestSuccessMessage != nil },
            set: { if !$0 { ingestSuccessMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                ingestSuccessMessage = nil
            }
        } message: {
            Text(ingestSuccessMessage ?? "")
        }
        .sheet(isPresented: $showLinkSheet) {
            linkSourceSheet
        }
        .alert("Different tracks", isPresented: $showLinkMismatchAlert) {
            Button("Cancel", role: .cancel) {
                viewModel?.cancelLinkCheck()
            }
            Button("Link Anyway") {
                Task {
                    if let vm = viewModel, await vm.commitPendingLink() {
                        showLinkSheet = false
                        if case .validated(let title, _, _) = lastValidatedPhase {
                            linkSuccessMessage = "Linked to \(title)"
                        }
                    }
                }
            }
        } message: {
            if case .validated(_, _, let diff) = viewModel?.linkCheckPhase {
                Text("The remote playlist has \(diff.remoteOnly) track(s) this playlist doesn't, and this playlist has \(diff.localOnly) track(s) the remote doesn't. Linking only changes where Sync pulls new tracks from — nothing is added or removed now.")
            }
        }
        .alert("Link Updated", isPresented: linkSuccessBinding) {
            Button("OK", role: .cancel) {
                linkSuccessMessage = nil
            }
        } message: {
            Text(linkSuccessMessage ?? "")
        }
        .onChange(of: linkURLText) { _, _ in
            viewModel?.cancelLinkCheck()
        }
        .onChange(of: viewModel?.linkCheckPhase) { _, newPhase in
            if case .validated(_, _, let diff) = newPhase {
                lastValidatedPhase = newPhase
                if !diff.hasDifferences {
                    Task {
                        if let vm = viewModel, await vm.commitPendingLink() {
                            showLinkSheet = false
                            if case .validated(let title, _, _) = newPhase {
                                linkSuccessMessage = "Linked to \(title)"
                            }
                        }
                    }
                } else {
                    showLinkMismatchAlert = true
                }
            }
        }
        .task(id: playlist.id) {
            coverImage = nil
        }
        .task(id: "\(playlist.coverImagePath ?? "")#\(coverRevision)") {
            let path = playlist.coverImagePath
            let coversDir = PlaylistCard.coversDirectory
            let cgImage: CGImage? = try? await Task.detached(priority: .userInitiated) {
                PlaylistCard.loadCoverCGImage(coverImagePath: path, coversDir: coversDir)
            }.value
            guard !Task.isCancelled, let cgImage else {
                coverImage = nil
                return
            }
            coverImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    // MARK: - Link Source Sheet

    private var linkSourceSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundColor(.mlmAccent)
                    Text("Link Playlist Source")
                        .font(MLMFont.title3)
                        .foregroundColor(.mlmInk)
                }
                Text("Paste a YouTube or SoundCloud playlist URL to link this playlist to a remote source.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }

            Divider()

            TextField("https://youtube.com/playlist?list=… or https://soundcloud.com/…/sets/…", text: $linkURLText)
                .textFieldStyle(.roundedBorder)
                .disabled(isLinkChecking)

            phaseView

            Spacer(minLength: 0)

            Divider()

            HStack {
                Button("Cancel") {
                    viewModel?.cancelLinkCheck()
                    showLinkSheet = false
                }
                .disabled(isLinkChecking)

                Spacer()

                if isLinkChecking {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }

                Button("Check") {
                    Task { await viewModel?.checkPlaylistLink(url: linkURLText) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mlmAccent)
                .disabled(isLinkChecking || linkURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: 520, minHeight: 240, maxHeight: 340)
    }

    private var isLinkChecking: Bool {
        if case .checking = viewModel?.linkCheckPhase { return true }
        return false
    }

    private var linkSuccessBinding: Binding<Bool> {
        Binding(
            get: { linkSuccessMessage != nil },
            set: { if !$0 { linkSuccessMessage = nil } }
        )
    }

    @ViewBuilder
    private var phaseView: some View {
        if let phase = viewModel?.linkCheckPhase {
            switch phase {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking link…")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmError)
            case .validated(let remoteTitle, let remoteTrackCount, let diff):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote playlist “\(remoteTitle)” · \(remoteTrackCount) tracks")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInk)
                    if diff.hasDifferences {
                        Text("Differs: \(diff.remoteOnly) track(s) only remote, \(diff.localOnly) only local.")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmAttention)
                    } else {
                        Text("Matches the tracks in this playlist.")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                    }
                }
            }
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
                    if let coverImage {
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
                // The header cover takes an image (D-PLD-COVER-TO-HEADER): one undo step; a
                // refused file says so in the header for 5 s (UC-SURF-04).
                .dropTarget(.playlistCover(id: playlist.id ?? -1, name: viewModel.playlist.name),
                               cornerRadius: 6, sayRefusal: { coverRefusal = $0 })

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
                    if let coverRefusal {
                        Label {
                            Text(coverRefusal)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        .font(.callout)
                        .task(id: coverRefusal) {
                            try? await Task.sleep(for: .seconds(5))
                            if !Task.isCancelled { self.coverRefusal = nil }
                        }
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

    /// The page's `Sync` (refresh from the linked source) for the menu bar's ⌘R.
    private var sourceRefresh: PlaylistSourceRefresh? {
        guard let viewModel, viewModel.canSync, let id = playlist.id else { return nil }
        return PlaylistSourceRefresh(
            playlistID: id,
            sourceName: viewModel.source?.playlistSourceIdentity.displayName,
            isRunning: viewModel.isSyncingSource,
            perform: { Task { await viewModel.syncSource() } }
        )
    }

    // MARK: - Action Buttons

    private func actionButtons(_ viewModel: PlaylistDetailViewModel) -> some View {
        HStack(spacing: 8) {
            if let firstLocalTrack = viewModel.playableTracks.first {
                // Nothing plays while the library's disk is away (§15.5, W2-A review S7).
                let cantPlay = TrackTableLiveState.drive(container).cantPlayReason
                Button {
                    onTrackDoubleClick?(firstLocalTrack, viewModel.displayedTracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(cantPlay != nil)
                .help(cantPlay ?? "")

                Button {
                    Task {
                        if let pvm = container.playbackViewModel {
                            await pvm.playShuffled(viewModel.playableTracks)
                        }
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .help(cantPlay ?? "Shuffle play playlist")
                .disabled(viewModel.displayedTracks.isEmpty || cantPlay != nil)
                .accessibilityIdentifier("playlist_shuffle_button")
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

            // Link Source button
            if viewModel.canLinkSource {
                Button {
                    linkURLText = viewModel.linkedSourceURL ?? ""
                    viewModel.cancelLinkCheck()
                    showLinkSheet = true
                } label: {
                    Label(viewModel.playlist.sourceId != nil ? "Change Link…" : "Link Source…", systemImage: "link")
                        .font(MLMFont.body)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("playlist_link_source_button")
            }

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
        // The shared track table (W2-A): ⌫ / Remove from Playlist is one undo step there.
        PlaylistTable(
            playlist: playlist,
            viewModel: viewModel,
            onTrackDoubleClick: onTrackDoubleClick
        )
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
                                openSettings(tab: .sources)
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

    @ViewBuilder
    private func emptyState(_ viewModel: PlaylistDetailViewModel) -> some View {
        if !viewModel.searchFilter.isEmpty {
            // Filtered-empty (UC-EMPTY-02, UC-SEARCH-07): the search variant, never an empty playlist.
            ContentUnavailableView {
                Label("No Results for “\(viewModel.searchFilter.displayText)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                Button("Clear Filters") { search?.clear() }
                Button("Search the Library") { search?.focus(scope: .library) }
                Button("Search Online") { search?.focus(scope: .online) }
            }
        } else {
            unfilteredEmptyState(viewModel)
        }
    }

    private func unfilteredEmptyState(_ viewModel: PlaylistDetailViewModel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundColor(.mlmInkMuted)

            if viewModel.searchFilter.isEmpty {
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

    // WP4 — Start the ingest preview flow for an m3u8 file
    private func startIngestPreview(for url: URL) async {
        guard let ingestService = container.playlistIngestService else {
            viewModel?.setErrorMessage("Ingest service unavailable — please restart the app")
            return
        }

        let vm = PlaylistIngestViewModel(ingestService: ingestService)
        ingestVM = vm
        pendingIngestURL = url

        await vm.loadPreview(url: url, profileId: -1)

        if vm.preview != nil {
            showIngestPreview = true
        } else if let error = vm.errorMessage {
            // Preview failed — surface via the existing error mechanism
            viewModel?.setErrorMessage(error)
        }
    }

    /// Removing from the playlist is one undo step, without a question (UC-UNDO-06): the
    /// same `PlaylistTrackRemoval` as ⌫ and the context menu (W2-A review).
    private func requestTrackRemoval(_ trackIDs: Set<Int64>, using viewModel: PlaylistDetailViewModel) {
        guard !trackIDs.isEmpty, let playlistID = viewModel.playlist.id else { return }
        PlaylistTrackRemoval.remove(trackIDs, fromPlaylist: playlistID, name: viewModel.playlist.name, undo: undo)
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
            configRepository: container.configRepository,
            tableCache: container.playlistTableCache
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
