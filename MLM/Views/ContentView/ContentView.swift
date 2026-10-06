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

    @State private var reviewFocusTrackID: Int64?

    /// Selection-based sheet state
    @State private var syncProfileSelectionContainer: TrackSelectionContainer? = nil

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        notificationHandlers(
            rootContent
                // The window as the last drop target: files, links, .mlibm, .m3u (W2-H).
                .mainWindowDrops()
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
                .focusedSceneValue(\.navigationModel, isShellVisible ? shell.navigation : nil)
                .focusedSceneValue(\.trailingColumn, isShellVisible ? shell.trailing : nil)
                .focusedSceneValue(\.statusBarCenter, isShellVisible ? shell.statusBar : nil)
                .focusedSceneValue(\.shellActions, isShellVisible ? shell.actions : nil)
                .focusedSceneValue(\.playbackViewModel, container.playbackViewModel)
                // Edit ▸ Find (⌘F, main window only) and Go ▸ Playlists (W1-2).
                .focusedSceneValue(\.toolbarSearch, isShellVisible ? shell.search : nil)
                .focusedSceneValue(\.sidebarModel, isShellVisible ? shell.sidebar : nil)
                .modifier(UndoCenterInstallation(shell: shell, isLibraryOpen: isShellVisible,
                                                 libraryID: container.activeLibrary?.libraryId))
        )
    }

    /// The shell once a library is open and its setup is done; until then the launch states
    /// (W3-LAUNCH: picker, setup, opening, failed, invalid — UC-WIN-07: no sidebar, player or
    /// search).
    private var isShellVisible: Bool { container.isInitialized && launch.setup == nil }

    @ViewBuilder
    private var rootContent: some View {
        Group {
            if isShellVisible {
                initializedView
            } else {
                LaunchRootView(launch: launch)
            }
        }
        // Launch states show only the title and the Activity item (UC-WIN-07, UC-JOB-04).
        .toolbar {
            if !isShellVisible {
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
        // Import Files or Folder… takes files and folders (W3-ADD; UC-SHEET-25 message).
        .fileImporter(isPresented: $actions.isChoosingImportFolder, allowedContentTypes: [.folder, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                shell.actions.importChosen(urls)
            }
        }
        .fileDialogMessage("Choose audio files or a folder to import.")
        // Add from Link… and Import Playlist from Source… (W3-ADD).
        .importSheets(shell.actions.imports, search: shell.search)
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
        // Links go to the Add menu's sheets (`QuickAddRouter.shared.presenter`, installed by
        // `.importSheets`, W3-ADD).
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
