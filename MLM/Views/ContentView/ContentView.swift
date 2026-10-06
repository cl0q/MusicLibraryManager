import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shell state

/// Everything one main window's shell owns, created once per window and handed to the
/// views through the environment and to the menu bar through focused values.
@MainActor
final class ShellState {
    let navigation = NavigationModel()
    let trailing = TrailingColumnState()
    let statusBar = StatusBarCenter()
    let undo: UndoCenter
    let sidebar = SidebarModel()
    let drivePlayback = DriveLossPlayback()
    let search: ToolbarSearchModel
    /// The `Library` and `Online` scopes' results (W2-I); kept while the window lives.
    let libraryResults = LibrarySearchModel()
    let onlineResults = OnlineSearchModel()
    let actions: ShellActions

    init(container: DependencyContainer) {
        search = ToolbarSearchModel(coordinator: container.searchCoordinator)
        // One center per open library, outliving this window (DEC-049: restorable until quit).
        undo = UndoCenter.main
        actions = ShellActions(
            container: container,
            navigation: navigation,
            sidebar: sidebar,
            statusBar: statusBar,
            undo: undo
        )
    }
}

// MARK: - Root content view

/// The main window (V-MAIN-LAYOUT): launch states until a library is open, then the shell —
/// sidebar · content column (`NavigationStack` of the selected destination, in the content
/// scaffold) · trailing column (`.inspector`, Info | Queue) under the constant toolbar.
///
/// The pieces live in `MLM/Views/Shell/` (navigation model, toolbar, scaffold, status bar,
/// trailing column, destinations) and `MLM/Views/Sidebar/`; this file composes them.
struct ContentView: View {
    @Environment(\.container) private var container
    /// Chooses the library at launch (A3); its screens show until a library is open.
    private var launch: LibraryLaunchCoordinator { LibraryLaunchCoordinator.shared }

    @State private var shell = ShellState(container: .shared)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showFirstRunWizard = false

    @State private var reviewFocusTrackID: Int64?

    /// Selection-based sheet state
    @State private var syncProfileSelectionContainer: TrackSelectionContainer? = nil

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        notificationHandlers(
            rootContent
                .modifier(LibraryFilePresentation(launch: launch))
                // Remove from Library… — one confirmation for the Track menu and context menus.
                .modifier(LibraryRemovalAlert())
                .installsMainWindowPresenter()
                .environment(shell.navigation)
                .environment(shell.trailing)
                .environment(shell.statusBar)
                .environment(shell.sidebar)
                .environment(shell.actions)
                .environment(shell.search)
                .focusedSceneValue(\.navigationModel, container.isInitialized ? shell.navigation : nil)
                .focusedSceneValue(\.trailingColumn, container.isInitialized ? shell.trailing : nil)
                .focusedSceneValue(\.statusBarCenter, container.isInitialized ? shell.statusBar : nil)
                .focusedSceneValue(\.shellActions, container.isInitialized ? shell.actions : nil)
                .focusedSceneValue(\.playbackViewModel, container.playbackViewModel)
                // Edit ▸ Find (⌘F, main window only) and Go ▸ Playlists (W1-2).
                .focusedSceneValue(\.toolbarSearch, container.isInitialized ? shell.search : nil)
                .focusedSceneValue(\.sidebarModel, container.isInitialized ? shell.sidebar : nil)
                .modifier(UndoCenterInstallation(shell: shell, isLibraryOpen: container.isInitialized,
                                                 libraryID: container.activeLibrary?.libraryId))
        )
    }

    /// Launch states until a library is open, then the shell (UC-WIN-07: launch states
    /// have no sidebar, player or search).
    @ViewBuilder
    private var rootContent: some View {
        Group {
            if container.isInitialized {
                ZStack {
                    initializedView

                    // First-run wizard overlay when no library root configured
                    if showFirstRunWizard {
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()
                            .transition(.opacity)

                        FirstRunWizard {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showFirstRunWizard = false
                                container.hasLibraryRoot = true
                            }
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .onAppear {
                    showFirstRunWizard = !container.hasLibraryRoot
                }
            } else if let error = container.initializationError {
                errorView(error)
            } else if launch.screen == .offerAdoption {
                // Pre-A3 install found: offer the library file before anything opens.
                Color.mlmBase
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .sheet(isPresented: .constant(true)) {
                        LibraryAdoptionSheet(
                            state: launch.adoptionState,
                            onCreate: { name in Task { await launch.adoptLegacyLibrary(named: name) } },
                            onNotNow: { Task { await launch.declineAdoption() } },
                            onDone: { Task { await launch.finishAdoption() } }
                        )
                    }
            } else if launch.screen != .resolving, launch.screen != .opened {
                // No library open yet (A3): first run, picker placeholder, or a problem.
                LibraryLaunchStateView(
                    screen: launch.screen,
                    onNewLibrary: { launch.requestNewLibrary() },
                    onOpenLibrary: { url in Task { await launch.open(packageAt: url) } },
                    onOpenAsSeparateLibrary: { url in Task { await launch.openAsSeparateLibrary(url) } },
                    onRetry: { Task { await launch.retry() } },
                    onDismissProblem: { launch.dismissProblem() }
                )
            } else {
                loadingView
            }
        }
        // Launch states show only the title and the Activity item (UC-WIN-07, UC-JOB-04).
        .toolbar {
            if !container.isInitialized {
                ToolbarItem(placement: .primaryAction) {
                    ActivityToolbarItem()
                }
            }
        }
        // Activity's status-bar messages (UC-JOB-08) and window requests (status-bar `Show`).
        .onAppear { connectActivity() }
        // The Activity item's text collapse follows the window width (UC-TB-03).
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ActivityRouter.shared.mainWindowWidth = $0 }
        .onChange(of: ActivityRouter.shared.windowRequest) { _, _ in
            openWindow(id: ActivityWindow.id)
        }
    }

    /// The main window's status bar shows Activity's start and end messages; `Show` opens the
    /// popover — an explicit action; a finished job itself never opens anything (UC-JOB-12).
    private func connectActivity() {
        let statusBar = shell.statusBar
        ActivityCenter.shared.messageSink = { message in
            let actions = message.actionTitle.map { title in
                [StatusAction(title) { ActivityRouter.shared.showPopover() }]
            } ?? []
            statusBar.post(message.text, actions: actions)
        }
    }

    /// Cross-view requests that arrive as notifications (unchanged contracts).
    private func notificationHandlers<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidUnmount)) { _ in
                libraryDriveDidUnmount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidMount)) { _ in
                libraryDriveDidMount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerNewPlaylistFromSelection)) { notification in
                // Track context menus (until they call TrackCommandActions): no sheet, one undo step.
                if let trackIds = extractTrackIds(from: notification.userInfo) {
                    shell.actions.newPlaylistFromSelection(trackIDs: trackIds)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerNewSyncProfileFromSelection)) { notification in
                if let trackIds = extractTrackIds(from: notification.userInfo) {
                    syncProfileSelectionContainer = TrackSelectionContainer(trackIds: Set(trackIds))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToCreateSyncProfile)) { _ in
                shell.actions.newSyncProfile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showReview)) { notification in
                if let trackID = notification.userInfo?["trackId"] as? Int64 {
                    reviewFocusTrackID = trackID
                } else if let trackID = notification.userInfo?["trackId"] as? NSNumber {
                    reviewFocusTrackID = trackID.int64Value
                } else {
                    reviewFocusTrackID = nil
                }
                shell.navigation.select(.review)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTrackDetailForTrack)) { notification in
                openTrackDetail(notification.userInfo)
            }
            .sheet(item: $syncProfileSelectionContainer) { selection in
                NewSyncProfileFromSelectionSheet(trackIds: selection.trackIds)
            }
            .onChange(of: searchPlace) { _, _ in
                // The query belongs to the view: keep the outgoing place's, restore this one's.
                shell.search.placeDidChange()
            }
    }

    private func extractTrackIds(from userInfo: [AnyHashable: Any]?) -> [Int64]? {
        guard let raw = userInfo?["trackIds"] else { return nil }
        if let array = raw as? [Int64] {
            return array
        }
        if let nsArray = raw as? [NSNumber] {
            return nsArray.map { $0.int64Value }
        }
        if let array = raw as? [Int] {
            return array.map { Int64($0) }
        }
        return nil
    }

    // MARK: - Initialized layout

    private var initializedView: some View {
        @Bindable var trailing = shell.trailing
        @Bindable var actions = shell.actions
        return VStack(spacing: 0) {
            SearchableShell(model: shell.search) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(
                            min: ShellMetrics.sidebarMinWidth,
                            ideal: ShellMetrics.sidebarIdealWidth
                        )
                } detail: {
                    detailColumn
                        .inspector(isPresented: $trailing.isPresented) {
                            TrailingColumnView()
                                .inspectorColumnWidth(
                                    min: ShellMetrics.trailingMinWidth,
                                    ideal: ShellMetrics.trailingIdealWidth,
                                    max: ShellMetrics.trailingMaxWidth
                                )
                        }
                }
                .toolbar(id: "mlm.main") {
                    ShellToolbar(playbackViewModel: container.playbackViewModel)
                }
            }

        }
        // Window-wide Esc for a preview, playback's status-bar notes, Locate File… (W2-C).
        .playbackWindowSupport()
        .fileImporter(isPresented: $actions.isChoosingImportFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                shell.actions.importFolder(url)
            }
        }
        .fileDialogMessage("Choose a folder. MLM imports the music files inside it into the library.")
        .sheet(isPresented: $actions.isCreatingSyncProfile) {
            NewSyncProfileSheet { profile in
                if let id = profile.id {
                    shell.navigation.select(.syncProfile(id))
                }
            }
        }
        .onAppear {
            configureSearch()
            shell.actions.activateTrack = handleTrackDoubleClick
        }
        // ⌘F is Edit ▸ Find ▸ Search, a menu key of this window (W1-2); no app-wide key monitor.
    }

    // MARK: - Content column

    /// The visible place as search sees it (its key; the name follows).
    private var searchPlace: SearchPlaceKey { SearchPlace(shell.navigation).key }

    /// Wires the toolbar search field, its scopes' results and the link hand-off (W2-I).
    private func configureSearch() {
        let search = shell.search
        let navigation = shell.navigation
        let sidebar = shell.sidebar
        let statusBar = shell.statusBar
        search.navigation = navigation
        search.placeProvider = {
            SearchPlace(navigation, names: PlaceNames(playlist: { sidebar.playlistName($0) }))
        }
        search.suggestionProvider = LiveSearchSuggestionProvider()
        search.recentStore = RecentSearchStore(libraryID: { DependencyContainer.shared.activeLibrary?.libraryId })
        search.moveFocusToResults = { SearchFocusHandoff.moveToResults() }
        search.openLink = { [weak search] link in
            QuickAddRouter.shared.open(link, lookup: search?.linkLookup)
        }
        search.postHint = { statusBar.post($0) }
        search.placeDidChange()

        shell.libraryResults.trackSearch = { filter, limit in
            guard let queries = await TrackSearchQueries.current() else { return ([], 0) }
            return try await queries.matchingTracks(filter: filter, limit: limit)
        }
        shell.libraryResults.playlists = { sidebar.playlists }
        shell.libraryResults.folderSearch = { text in await LibraryFolderSearch.folders(matching: text) }
        shell.onlineResults.providers = { LiveOnlineSearchProviders.make() }
        shell.onlineResults.libraryMatches = { results in
            guard let queries = await TrackSearchQueries.current() else { return [:] }
            return (try? await queries.libraryTrackIDs(for: results)) ?? [:]
        }

        QuickAddRouter.shared.interim = QuickAddRouter.Interim(
            lookUp: { link in await LiveSearchSuggestionProvider().lookUp(link) },
            download: { link, metadata in
                guard let service = SearchDownloadService.live() else { return .failed("no library is open") }
                return await service.download(link, metadata: metadata)
            },
            revealInLibrary: { [weak search] id in
                if let search { SearchReveal.showInAllTracks(id, search: search) }
            },
            importPlaylist: { source, url in
                let remote: RemotePlaylistSource = switch source {
                case .youtube: .youtube
                case .soundcloud: .soundcloud
                case .spotify: .spotify
                }
                if source != .spotify { RemotePlaylistLinkRequest.shared.request(url, source: source) }
                AppDelegate.shared?.showRemotePlaylistsWindow(source: remote)
                return source != .spotify
            },
            post: { statusBar.post($0) }
        )
    }

    private var isAllTracks: Bool {
        shell.navigation.selection == .allTracks
    }

    /// The content column: the destination's `NavigationStack`, with the search results pane
    /// drawn above it, so search shows the same on a destination and on a pushed detail.
    private var detailColumn: some View {
        let searching = container.searchCoordinator.isPresented
        return ZStack {
            navigationStack
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)

            if searching {
                // `Library` / `Online` results, only on request (UC-SEARCH-02); `This view`
                // filters the place below in place.
                ContentScaffold(showsDriveBanner: container.searchCoordinator.scope == .library) {
                    SearchResultsView(
                        search: shell.search,
                        library: shell.libraryResults,
                        online: shell.onlineResults,
                        onTrackActivated: handleTrackDoubleClick
                    )
                } selectionBar: {
                    TrackSelectionBar(host: .searchResults)
                }
                .hostsTrackSelectionBar()
                .modifier(WindowTitleModifier())
            }
        }
        .background {
            PlaybackChangeObserver(drivePlayback: shell.drivePlayback)
        }
    }

    private var navigationStack: some View {
        @Bindable var navigation = shell.navigation
        return NavigationStack(path: Binding(
            get: { navigation.path },
            set: { navigation.setPath($0) }
        )) {
            ZStack {
                // All Tracks stays alive across switches: rebuilding its ~12,000-row
                // Table ↔ NSTableView bridge costs ~0.5 s. Hidden when another place shows.
                // Its Scan command is gated by `NavigationModel.isAllTracksVisible`, read only
                // by that button, so the kept-alive subtree is not re-disabled on every switch.
                AllTracksHost(onTrackActivated: handleTrackDoubleClick)
                    .opacity(isAllTracks ? 1 : 0)
                    .allowsHitTesting(isAllTracks)
                    .accessibilityHidden(!isAllTracks)

                if !isAllTracks {
                    DestinationView(
                        destination: shell.navigation.selection,
                        reviewFocusTrackID: reviewFocusTrackID,
                        onTrackActivated: handleTrackDoubleClick
                    )
                    .id(shell.navigation.selection)
                }
            }
            .navigationDestination(for: DetailRoute.self) { route in
                RouteView(route: route, onTrackActivated: handleTrackDoubleClick)
            }
        }
    }

    // MARK: - Track activation and Info

    /// Double-click / Return on a track: play it with the visible rows as the queue. Never opens
    /// the trailing column and never changes what Info shows — Info follows the selection
    /// (DEC-008, UC-TRAIL-02/03; fixes PP-INSPECTOR-01/03).
    private func handleTrackDoubleClick(_ track: Track, queue: [Track]) {
        if track.isLocal, let playbackVM = container.playbackViewModel {
            Task {
                await playbackVM.playTrack(track, queue: queue)
            }
        }
    }

    /// `.openTrackDetailForTrack` — Get Info from a track's context menu and `Show Details` /
    /// double-click on a failed sync row. `play` plays without opening anything; otherwise Info
    /// opens for the selection, or for this track when it isn't selected in a track list (a sync
    /// row): Info shows what was asked for, never the playing track.
    private func openTrackDetail(_ userInfo: [AnyHashable: Any]?) {
        let trackId: Int64?
        if let raw = userInfo?["trackId"] as? Int64 {
            trackId = raw
        } else if let ns = userInfo?["trackId"] as? NSNumber {
            trackId = ns.int64Value
        } else {
            trackId = nil
        }
        let play = userInfo?["play"] as? Bool ?? false
        guard let trackId else { return }
        if play {
            Task {
                guard let track = try? await container.trackRepository?.fetchTrack(id: trackId) else { return }
                if track.isLocal, let playbackVM = container.playbackViewModel {
                    await playbackVM.playTrack(track)
                }
            }
            return
        }
        let selection = InspectedTrackSelection.shared.trackIDs
        if !selection.contains(trackId) {
            InfoTrackRequest.shared.show([trackId], over: selection)
        }
        if !shell.trailing.isShowing(.info) {
            shell.trailing.toggle(.info)
        }
    }

    // MARK: - Library drive

    private func libraryDriveDidUnmount() {
        container.isLibraryDriveMounted = false
        let drive = LibraryDriveState.current(container)
        if let name = drive.volumeName {
            DriveBanner.announceDisconnected(name)
        }
        guard let playbackVM = container.playbackViewModel else { return }
        // One decision (W2-C): a running preview ends first without resuming the main track;
        // a main track that was playing under it counts as playing.
        let mainPlayedUnderPreview = playbackVM.endPreviewForDiskLoss()
        if let message = shell.drivePlayback.driveDidDisconnect(
            volumeName: drive.volumeName,
            isPlaying: mainPlayedUnderPreview || playbackVM.isMainPlaying,
            position: playbackVM.formattedPosition,
            pause: { playbackVM.pause() }
        ) {
            shell.statusBar.post(message)
        }
    }

    /// A real mount event, and `Try Again` on the banner when the disk is back.
    private func libraryDriveDidMount() {
        container.isLibraryDriveMounted = true
        let name = LibraryDriveState.current(container).volumeName
        guard let result = shell.drivePlayback.driveDidConnect(volumeName: name) else { return }
        if result.offersResume, let playbackVM = container.playbackViewModel {
            shell.statusBar.post(result.message, actions: [
                StatusAction("Resume") { playbackVM.play() },
            ])
        } else {
            shell.statusBar.post(result.message)
        }
    }

    // MARK: - Error state

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.mlmError)
            Text("Failed to Initialize")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)
            Text(error.localizedDescription)
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }

    // MARK: - Loading state

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Library...")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }
}

// MARK: - Undo

/// The library's `UndoCenter` in the environment and as a focused value, attached to this
/// window's `UndoManager` and status bar; undo closures reach this window's models through
/// `ShellWindowModels.main`. Steps outlive the window and end when another library opens
/// (UC-UNDO-01, DEC-049, W2-F).
private struct UndoCenterInstallation: ViewModifier {
    let shell: ShellState
    let isLibraryOpen: Bool
    let libraryID: String?

    func body(content: Content) -> some View {
        content
            .environment(shell.undo)
            .focusedSceneValue(\.undoCenter, isLibraryOpen ? shell.undo : nil)
            .undoCenter(shell.undo, statusBar: shell.statusBar, scope: libraryID)
            .onAppear {
                ShellWindowModels.main.use(navigation: shell.navigation, sidebar: shell.sidebar, statusBar: shell.statusBar)
            }
    }
}

// MARK: - Playback changes (drive-loss bookkeeping)

/// Tells `DriveLossPlayback` when playback changes for another reason, so a later reconnect
/// doesn't offer a stale `Resume`. A leaf, so playback ticks don't re-render the window.
private struct PlaybackChangeObserver: View {
    let drivePlayback: DriveLossPlayback
    @Environment(\.container) private var container

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: container.playbackViewModel?.isPlaying) { _, isPlaying in
                drivePlayback.playbackDidChange(isPlaying: isPlaying == true)
            }
            .onChange(of: container.playbackViewModel?.currentTrack?.id) { _, _ in
                drivePlayback.trackDidChange()
            }
            .accessibilityHidden(true)
    }
}

// MARK: - All Tracks host (kept alive)

/// All Tracks in its scaffold. The library view inside is frozen by `LibraryHost`, so the
/// scaffold's status bar and banner can update without re-evaluating the table.
private struct AllTracksHost: View {
    let onTrackActivated: TrackActivation

    var body: some View {
        // The status-bar text (counts, selection) is declared by the track table (W2-A); the
        // availability scope bar sits in the scaffold's slot (W2-B).
        ContentScaffold(showsDriveBanner: true) {
            LibraryHost(onTrackDoubleClick: onTrackActivated)
                .equatable()
        } scopeBar: {
            AllTracksScopeBar()
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
    }
}

// MARK: - Library host (prevents hidden LibraryView re-evaluation)

/// Wraps `LibraryView` and freezes the double-click callback after the first
/// render.  `Equatable` conformance always returns `true` so SwiftUI skips
/// re-evaluating the body on subsequent parent re-renders — the expensive
/// `LibraryView` (≈12 000-row Table ↔ NSTableView bridge) is therefore never
/// re-evaluated when the user switches to another sidebar section.
///
/// The frozen callback remains valid because `DependencyContainer` is a
/// `final class` singleton (reference type) and `@State` mutations use
/// reference-based storage.
private struct LibraryHost: View, Equatable {
    let initialCallback: ((Track, [Track]) -> Void)?
    @State private var stored: ((Track, [Track]) -> Void)?

    init(onTrackDoubleClick: ((Track, [Track]) -> Void)?) {
        self.initialCallback = onTrackDoubleClick
    }

    var body: some View {
        LibraryView(onTrackDoubleClick: stored)
            .onAppear {
                if stored == nil { stored = initialCallback }
            }
    }

    static func == (_: LibraryHost, _: LibraryHost) -> Bool { true }
}

// MARK: - Library files (A3)

/// `New Library` sheet, `Switch to "‹name›"?` and problems with a library chosen while
/// another one is open. Copy: UI-GROUNDTRUTH §3.17.
private struct LibraryFilePresentation: ViewModifier {
    let launch: LibraryLaunchCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { launch.newLibraryRequest }, set: { if $0 == nil { launch.cancelNewLibrary() } })) { request in
                NewLibrarySheet(
                    defaultName: request.defaultName,
                    onCreate: { name in Task { await launch.createLibrary(named: name) } },
                    onCancel: { launch.cancelNewLibrary() }
                )
            }
            .alert(
                "Switch to \"\(launch.pendingSwitch?.name ?? "")\"?",
                isPresented: Binding(get: { launch.pendingSwitch != nil }, set: { if !$0 { launch.cancelSwitch() } })
            ) {
                Button("Relaunch") { launch.confirmSwitch() }
                Button("Cancel", role: .cancel) { launch.cancelSwitch() }
            } message: {
                Text("MLM relaunches to open this library. Finish active downloads and syncs first.")
            }
            .alert(
                problemTitle,
                isPresented: Binding(get: { launch.switchProblem != nil }, set: { if !$0 { launch.dismissProblem() } })
            ) {
                problemButtons
            } message: {
                problemMessage
            }
    }

    private var problemTitle: String {
        switch launch.switchProblem {
        case .unavailable(let entry, _): return "\"\(entry.displayName)\" can't be opened"
        case .mismatch(let name, _): return "\"\(name)\" can't be opened"
        case .invalid(let name): return "\"\(name)\" isn't a valid library file."
        case .duplicateCopy(let name, let originalName, _): return "\"\(name)\" is a copy of \"\(originalName)\""
        default: return ""
        }
    }

    @ViewBuilder
    private var problemMessage: some View {
        switch launch.switchProblem {
        case .unavailable(_, .notConnected):
            Text("The library file is on a disk that isn't connected. Connect the disk, then try again.")
        case .unavailable:
            Text("The library file isn't where MLM last found it. Open it from its new location, or create a new library.")
        case .mismatch:
            Text("The library file and its database don't belong together. This can happen when files inside a library file were replaced. MLM didn't change anything.")
        case .duplicateCopy(_, let originalName, _):
            Text("To open it, MLM makes the copy a separate library. \"\(originalName)\" is not changed.")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var problemButtons: some View {
        switch launch.switchProblem {
        case .mismatch(_, let packageURL):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([packageURL]) }
            Button("OK", role: .cancel) { launch.dismissProblem() }
        case .duplicateCopy(_, _, let packageURL):
            Button("Open as separate library") { Task { await launch.openAsSeparateLibrary(packageURL) } }
            Button("Cancel", role: .cancel) { launch.dismissProblem() }
        case .unavailable:
            Button("Open Library…") {
                launch.dismissProblem()
                if let url = LibraryFilePanel.chooseLibraryFile() { Task { await launch.handleOpen(url) } }
            }
            Button("New Library…") {
                launch.dismissProblem()
                launch.requestNewLibrary()
            }
            Button("Cancel", role: .cancel) { launch.dismissProblem() }
        default:
            Button("OK", role: .cancel) { launch.dismissProblem() }
        }
    }
}
