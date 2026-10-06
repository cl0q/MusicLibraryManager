import SwiftUI

/// The playlist page (V-PLD, DEC-022/023, UC-LAYOUT-01/06) — the same from every entry
/// (sidebar row, card, search). In the content scaffold, top to bottom: the drive banner, the
/// detail header (160 pt cover — drop target, `Choose Cover…` —, kind label, editable title,
/// facts line `44 tracks · 2 h 51 min · Linked to SoundCloud`, `Play` · `Shuffle` · `More`),
/// one status sentence only when the playlist isn't healthy (§15.5, with its fix), the scope
/// bar `All · Download failed (n)` only when something failed, the shared track table with
/// `#`, the selection bar and the status bar. Back is the toolbar's (⌘[); there is no in-page
/// back button, no row of header buttons, no failed-tracks disclosure and no "Sync".
struct PlaylistDetailView: View {
    let playlist: Playlist
    /// Open in the `Download failed` scope (Show Failed Downloads).
    var initiallyShowFailedTracks = false
    var onBack: () -> Void = {}
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @Environment(\.container) private var container
    @Environment(\.openSettings) private var openSettings
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(SidebarModel.self) private var sidebar: SidebarModel?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    private enum Scope: Hashable { case all, failed }

    @State private var viewModel: PlaylistDetailViewModel?
    @State private var scope = Scope.all
    @State private var coverImage: NSImage?
    @State private var coverRevision = 0
    @State private var coverRefusal: String?
    @State private var isEditingTitle = false
    @State private var titleText = ""
    @State private var titleError: String?
    @FocusState private var titleFocused: Bool
    /// A failed header action (refresh), with its one fix (UC-SHEET-21).
    @State private var actionError: String?

    private var actions: PlaylistActions {
        PlaylistActions(container: container, shell: shell, navigation: navigation, statusBar: statusBar, undo: undo)
    }

    var body: some View {
        let model = viewModel
        ContentScaffold(showsDriveBanner: true) {
            if let model {
                content(model)
                    .windowCount(StatusBarText.tracks(model.summary.totalTracks))
            } else {
                Color.clear
            }
        } header: {
            if let model {
                VStack(spacing: 0) {
                    header(model)
                    if let actionError { errorLine(actionError, model) }
                    statusSentence(model)
                }
            }
        } scopeBar: {
            if let model, model.summary.failedTracks > 0 || scope == .failed {
                ScopeBar(
                    items: [
                        ScopeBarItem(id: Scope.all, title: "All", count: model.summary.totalTracks),
                        ScopeBarItem(id: Scope.failed, title: "Download failed", count: model.summary.failedTracks, hidesWhenEmpty: true),
                    ],
                    selection: $scope,
                    countNoun: .tracks
                )
            }
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
        .focusedSceneValue(\.playlistSourceRefresh, sourceRefresh)
        .focusedSceneValue(\.playlistPage, pageCommands)
        .task {
            if viewModel == nil, let playlists = container.playlistRepository, let tracks = container.trackRepository,
               let sources = container.sourceRepository {
                viewModel = PlaylistDetailViewModel(playlist: playlist, playlistRepository: playlists, trackRepository: tracks,
                                                    sourceRepository: sources, tableCache: container.playlistTableCache)
            }
            scope = initiallyShowFailedTracks ? .failed : .all
            viewModel?.searchFilter = container.searchCoordinator.filter(for: .playlist(playlist.id ?? -1))
            await viewModel?.loadTracks()
        }
        // In-place filter (W2-I): this playlist's own filter, text and tokens.
        .onChange(of: container.searchCoordinator.filter(for: .playlist(playlist.id ?? -1))) { _, filter in
            guard filter != viewModel?.searchFilter else { return }
            viewModel?.searchFilter = filter
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            if (note.userInfo?["origin"] as? String) == "coverService" {
                if note.userInfo?["playlistId"] as? Int64 == playlist.id { coverRevision += 1 }
                return
            }
            if note.userInfo?["coverRevalidation"] != nil { return }
            if let changed = note.userInfo?["playlistId"] as? Int64, changed != playlist.id { return }
            Task {
                if let id = playlist.id { container.playlistTableCache?.invalidate(playlistId: id) }
                await viewModel?.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await viewModel?.refresh() }
        }
        // Rows and the status sentence follow a running download (W3-PL review S6).
        .onChange(of: ActivityCenter.shared.downloadProgressKey) { _, _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in
            Task { await viewModel?.refreshAvailabilitySnapshot() }
        }
        .task(id: "\(viewModel?.playlist.coverImagePath ?? playlist.coverImagePath ?? "")#\(coverRevision)") {
            coverImage = await PlaylistCard.loadCover(viewModel?.playlist.coverImagePath ?? playlist.coverImagePath)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: PlaylistDetailViewModel) -> some View {
        if model.isMissing {
            PlaylistNotFoundView()
        } else if model.hasLoaded, model.tracks.isEmpty {
            ContentUnavailableView {
                Label("No tracks yet", systemImage: "music.note.list")
            } description: {
                Text("This playlist is empty. Drag tracks here or use Add to Playlist.")
            } actions: {
                Button("Go to All Tracks") { navigation?.select(.allTracks) }
                Button(PlaylistMenuModel.title(.importM3U)) { actions.importM3U(into: model.playlist) }
            }
            // The whole pane is a drop target on an empty playlist (V-PLD.E28, UC-EMPTY-01).
            .dropTarget(.sidebarPlaylist(id: playlist.id ?? -1, name: model.playlist.name), cornerRadius: 0)
        } else {
            PlaylistTable(playlist: model.playlist, viewModel: model, onTrackDoubleClick: onTrackDoubleClick,
                          failedOnly: scope == .failed)
        }
    }

    // MARK: - Header (UC-LAYOUT-06)

    private func header(_ model: PlaylistDetailViewModel) -> some View {
        HStack(alignment: .bottom, spacing: Spacing.l) {
            cover(model)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(PlaylistFacts.kindLabel(model.playlist))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                title(model)
                Text(PlaylistFacts.line(trackCount: model.summary.totalTracks, totalSeconds: model.summary.totalSeconds,
                                        sourceName: model.sourceDisplayName))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(model.sourceDisplayName.map { "Linked to \($0)" } ?? "Local playlist")
                buttons(model)
                    .padding(.top, Spacing.s)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .background(.background)
    }

    private func cover(_ model: PlaylistDetailViewModel) -> some View {
        ZStack {
            if let coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: model.playlist.isLiked == 1 ? "heart" : "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 160, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // UC-GLASS-02: the playlist header artwork extends under the sidebar.
        .backgroundExtensionEffect()
        .contextMenu {
            PlaylistMenu(playlists: [model.playlist], place: .cover)
        }
        // D-PLD-COVER-TO-HEADER: an image sets the cover (undoable); a refusal says so here.
        .dropTarget(.playlistCover(id: playlist.id ?? -1, name: model.playlist.name),
                    cornerRadius: 9, sayRefusal: { coverRefusal = $0 })
        .inPlaceRefusal($coverRefusal)
        .accessibilityLabel("Cover of “\(model.playlist.name)”")
    }

    @ViewBuilder
    private func title(_ model: PlaylistDetailViewModel) -> some View {
        if isEditingTitle {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit { commitTitle(model) }
                    .onExitCommand { isEditingTitle = false; titleError = nil }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused, isEditingTitle { commitTitle(model) }
                    }
                if let titleError {
                    Text(titleError).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(model.playlist.name)
                .font(.title.bold())
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Click to rename")
                .onTapGesture { startTitleEdit(model) }
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func startTitleEdit(_ model: PlaylistDetailViewModel) {
        titleText = model.playlist.name
        titleError = nil
        isEditingTitle = true
    }

    /// UC-KEY-20: Return commits, Esc reverts; a failure keeps the field open with one
    /// sentence under it (UC-SHEET-17); undoable through the same rename as the sidebar.
    private func commitTitle(_ model: PlaylistDetailViewModel) {
        let name = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = model.playlist.id, !name.isEmpty, name != model.playlist.name, let edits = shell?.edits else {
            isEditingTitle = false
            return
        }
        let oldName = model.playlist.name
        Task {
            do {
                try await edits.renamePlaylist(id, from: oldName, to: name)
                isEditingTitle = false
                titleError = nil
            } catch {
                titleError = ShellEdits.renameFailure(error, kind: "playlist")
                titleFocused = true
            }
        }
    }

    private func buttons(_ model: PlaylistDetailViewModel) -> some View {
        let reason = cantPlayReason(model)
        return HStack(spacing: Spacing.s) {
            Button {
                actions.play(model.playlist)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(reason != nil)
            .help(reason ?? "Play “\(model.playlist.name)”")
            Button {
                actions.play(model.playlist, shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(reason != nil)
            .help(reason ?? "Shuffle “\(model.playlist.name)”")
            Menu {
                PlaylistMenu(playlists: [model.playlist], place: .more) { startTitleEdit(model) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            if let reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Play and Shuffle are always present; disabled with the reason when nothing can play.
    private func cantPlayReason(_ model: PlaylistDetailViewModel) -> String? {
        if let drive = TrackTableLiveState.drive(container).cantPlayReason { return drive }
        guard model.hasLoaded else { return nil }
        if model.summary.totalTracks == 0 { return "This playlist is empty" }
        guard model.summary.localTracks == 0 else { return nil }
        if case .importing = status(model) { return "Nothing to play yet — the first tracks are still downloading" }
        return "Nothing to play yet — no track is downloaded"
    }

    // MARK: - Status sentence (§15.5, exact; one, only when not healthy)

    private func status(_ model: PlaylistDetailViewModel) -> PlaylistStatus {
        guard let id = model.playlist.id else { return .healthy }
        return PlaylistStatus.make(
            summary: model.summary,
            echo: ActivityCenter.shared.echo(for: .playlist(id, name: model.playlist.name)),
            expiredSignIn: PlaylistStatus.expiredSignIn(
                sourceName: model.source?.name,
                unusable: container.tokenAccessStatus?.inaccessibleServices ?? []
            )
        )
    }

    @ViewBuilder
    private func statusSentence(_ model: PlaylistDetailViewModel) -> some View {
        let status = status(model)
        // With the drive away the window banner speaks; the playlist adds nothing (§15.5).
        if let words = status.text, !LibraryDriveState.current(container).isOffline {
            HStack(spacing: Spacing.s) {
                if case .importing(_, let fraction) = status {
                    if let fraction {
                        ProgressView(value: fraction).frame(width: 180)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if let symbol = status.systemImage {
                    Image(systemName: symbol)
                        .foregroundStyle(status.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                Text(words).fontWeight(.semibold).monospacedDigit()
                if case .signInExpired = status {
                    let blocked = model.summary.failedTracks + model.summary.notDownloadedTracks
                    Text("\(StatusBarText.count(blocked, "track can’t", "tracks can’t")) be downloaded and Refresh is paused until you sign in again.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                switch status {
                case .signInExpired:
                    Button("Reconnect") { openSettings(tab: .sources) }
                case .importing:
                    Button("Show in Activity") { ActivityRouter.shared.showPopover() }
                case .incomplete:
                    Button("Retry All") { actions.retryFailed(model.playlist) }
                    Button("Show") { scope = .failed }
                case .notDownloaded:
                    Button("Download All") { actions.downloadMissing(model.playlist) }
                case .healthy:
                    EmptyView()
                }
            }
            .font(.callout)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xs)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }

    /// UC-SHEET-21: a failed header action, with its one fix; clears with ✕ or the next success.
    private func errorLine(_ message: String, _ model: PlaylistDetailViewModel) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Button("Try Again") {
                actionError = nil
                refresh(model)
            }
            Button {
                actionError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
        .background {
            ZStack {
                Rectangle().fill(.background)
                Rectangle().fill(.quaternary)
            }
        }
    }

    // MARK: - Commands

    private func refresh(_ model: PlaylistDetailViewModel) {
        let source = model.sourceDisplayName ?? "its source"
        actionError = nil
        actions.refresh(model.playlist) { cause in
            actionError = "Couldn’t refresh from \(source) — \(cause). The playlist is unchanged."
        }
    }

    /// Track ▸ Refresh from ‹Source› ⌘R for a linked playlist (UC-KEY-15).
    private var sourceRefresh: PlaylistSourceRefresh? {
        guard let model = viewModel, PlaylistRefreshService.canRefresh(model.playlist, sourceName: model.source?.name), let id = model.playlist.id else { return nil }
        return PlaylistSourceRefresh(
            playlistID: id,
            sourceName: model.sourceDisplayName,
            isRunning: PlaylistRefreshRegistry.shared.running.contains(id),
            perform: { refresh(model) }
        )
    }

    private var pageCommands: PlaylistPageCommands? {
        guard let model = viewModel, !model.isMissing else { return nil }
        let canPlay = cantPlayReason(model) == nil && model.summary.localTracks > 0
        let playlist = model.playlist
        let actions = self.actions
        return PlaylistPageCommands(
            playlist: playlist,
            notDownloaded: model.summary.notDownloadedTracks,
            canPlay: canPlay,
            play: { actions.play(playlist) },
            shuffle: { actions.play(playlist, shuffled: true) },
            downloadAll: { actions.downloadMissing(playlist) }
        )
    }
}

/// V-PLD.N03: the open playlist was deleted elsewhere, or its creation was undone.
struct PlaylistNotFoundView: View {
    @Environment(NavigationModel.self) private var navigation: NavigationModel?

    var body: some View {
        ContentUnavailableView {
            Label("This playlist no longer exists", systemImage: "music.note.list")
        } description: {
            Text("It was deleted, or its creation was undone. Its tracks are still in the library.")
        } actions: {
            Button("Show All Playlists") { navigation?.select(.allPlaylists) }
                .buttonStyle(.borderedProminent)
        }
    }
}
