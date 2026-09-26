import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

// MARK: - FocusedValues for ⌘1–7 navigation shortcuts

/// Allows CommandMenu in MLMApp to write the sidebar selection.
struct SelectedSectionKey: FocusedValueKey {
    typealias Value = Binding<SidebarSection>
}

/// Allows Playback CommandMenu to access the PlaybackViewModel.
struct PlaybackViewModelKey: FocusedValueKey {
    typealias Value = PlaybackViewModel
}

extension FocusedValues {
    var selectedSection: Binding<SidebarSection>? {
        get { self[SelectedSectionKey.self] }
        set { self[SelectedSectionKey.self] = newValue }
    }

    var playbackViewModel: PlaybackViewModel? {
        get { self[PlaybackViewModelKey.self] }
        set { self[PlaybackViewModelKey.self] = newValue }
    }
}

// MARK: - Root content view

/// Root content view with full window layout.
///
/// Layout (top → bottom):
/// ```
/// ┌─────────────────────────────────────────────────┐
/// │ 🔴🟡🟢  [play]  ♪ Title · Artist  │  Toolbar (PlayerBar)
/// ├────────┬────────────────────────────────────────┤
/// │Sidebar │  Detail content                        │  NavigationSplitView
/// │        │                                        │
/// ├────────┴────────────────────────────────────────┤
/// │ ▼ Activity                                      │  ActivityPanel (36px collapsed)
/// └─────────────────────────────────────────────────┘
/// ```
struct ContentView: View {
    @Environment(\.container) private var container

    @State private var selectedSection: SidebarSection = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showFirstRunWizard = false
    @State private var showUniversalSearch = false
    @FocusState private var isGlobalSearchFocused: Bool

    /// Track selected for detail panel (via double-click or "More Info").
    @State private var selectedTrackForDetail: Track?
    @State private var reviewFocusTrackID: Int64?

    /// Selection-based sheet states
    @State private var playlistSelectionContainer: TrackSelectionContainer? = nil
    @State private var syncProfileSelectionContainer: TrackSelectionContainer? = nil

    var body: some View {
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
                .sheet(isPresented: $showUniversalSearch) {
                    UniversalSearchView(
                        onDismiss: { showUniversalSearch = false },
                        onDownload: { result in
                            handleUniversalDownload(result: result)
                        }
                    )
                }
            } else if let error = container.initializationError {
                errorView(error)
            } else {
                loadingView
            }
        }
        .focusedSceneValue(\.selectedSection, $selectedSection)
        .focusedSceneValue(\.playbackViewModel, container.playbackViewModel)
        // Handle library drive unmount — pause playback
        .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidUnmount)) { _ in
            container.isLibraryDriveMounted = false
            // Pause playback when the drive is ejected
            if let playbackVM = container.playbackViewModel, playbackVM.isPlaying {
                playbackVM.pause()
            }
        }
        // Handle library drive remount — restore state
        .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidMount)) { _ in
            container.isLibraryDriveMounted = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerNewPlaylistFromSelection)) { notification in
            if let trackIds = extractTrackIds(from: notification.userInfo) {
                playlistSelectionContainer = TrackSelectionContainer(trackIds: Set(trackIds))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerNewSyncProfileFromSelection)) { notification in
            if let trackIds = extractTrackIds(from: notification.userInfo) {
                syncProfileSelectionContainer = TrackSelectionContainer(trackIds: Set(trackIds))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            if let selected = selectedTrackForDetail, let id = selected.id {
                Task {
                    if let freshTrack = try? await container.trackRepository?.fetchTrack(id: id) {
                        await MainActor.run {
                            self.selectedTrackForDetail = freshTrack
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchCommandTriggered)) { _ in
            isGlobalSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showReview)) { notification in
            if let trackID = notification.userInfo?["trackId"] as? Int64 {
                reviewFocusTrackID = trackID
            } else if let trackID = notification.userInfo?["trackId"] as? NSNumber {
                reviewFocusTrackID = trackID.int64Value
            } else {
                reviewFocusTrackID = nil
            }
            selectedSection = .review
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTrackDetailForTrack)) { notification in
            let trackId: Int64?
            if let raw = notification.userInfo?["trackId"] as? Int64 {
                trackId = raw
            } else if let ns = notification.userInfo?["trackId"] as? NSNumber {
                trackId = ns.int64Value
            } else {
                trackId = nil
            }
            let play = notification.userInfo?["play"] as? Bool ?? false
            guard let trackId else { return }
            Task {
                guard let track = try? await container.trackRepository?.fetchTrack(id: trackId) else { return }
                await MainActor.run {
                    selectedTrackForDetail = track
                }
                if play, track.isLocal, let playbackVM = container.playbackViewModel {
                    Task { await playbackVM.playTrack(track) }
                }
            }
        }
        .sheet(item: $playlistSelectionContainer) { selection in
            NewPlaylistFromSelectionSheet(trackIds: selection.trackIds)
        }
        .sheet(item: $syncProfileSelectionContainer) { selection in
            NewSyncProfileFromSelectionSheet(trackIds: selection.trackIds)
        }
        .onChange(of: selectedSection) { _, newSection in
            // [navperf] temporary instrumentation — remove after measurement
            print("[navperf] onchange-section-start \(newSection) \(Date().timeIntervalSince1970)")
            container.searchCoordinator.dismiss()
            container.searchCoordinator.query = ""
            isGlobalSearchFocused = false
            switch newSection {
            case .library:
                container.searchCoordinator.context = .library
            case .playlistDetail(let id):
                container.searchCoordinator.context = .playlist(id)
            default:
                container.searchCoordinator.context = .other
            }
            // [navperf] temporary instrumentation — remove after measurement
            print("[navperf] onchange-section-end \(newSection) \(Date().timeIntervalSince1970)")
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
        VStack(spacing: 0) {
            // Main content — NavigationSplitView fills available space
            HSplitView {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(selectedSection: $selectedSection)
                        .frame(minWidth: 192)
                } detail: {
                    detailView
                }
                .onChange(of: container.playbackViewModel?.currentTrack) { _, newTrack in
                    // Follow the now-playing track only when the detail pane is already open.
                    // Never force-open the inspector on a track change, and never clear it on stop.
                    guard newTrack != nil, selectedTrackForDetail != nil else { return }
                    selectedTrackForDetail = newTrack
                }

                if let track = selectedTrackForDetail {
                    TrackDetailView(track: track, onClose: {
                        selectedTrackForDetail = nil
                    })
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let vm = container.playbackViewModel {
                        PlayerBar(viewModel: vm)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    GlobalSearchField(
                        isFocused: $isGlobalSearchFocused,
                        hasLocalTable: {
                            switch selectedSection {
                            case .library, .playlistDetail: return true
                            default: return false
                            }
                        }
                    )
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showUniversalSearch = true
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help("Universal Search — paste a URL to download")
                }
            }

            // Separator
            Rectangle()
                .fill(Color.mlmEdge)
                .frame(height: 1)

            // Collapsible activity panel
            ActivityPanel()
        }
        .background(Color.mlmBase)
        .onAppear { installCmdFMonitor() }
        .onDisappear { removeCmdFMonitor() }
    }

    // MARK: - Cmd+F via NSEvent local monitor

    @State private var cmdFMonitor: Any?

    private func installCmdFMonitor() {
        cmdFMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isCmdF = event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.option) &&
                !event.modifierFlags.contains(.control) &&
                !event.modifierFlags.contains(.shift) &&
                event.charactersIgnoringModifiers == "f"
            if isCmdF {
                isGlobalSearchFocused = true
                return nil
            }
            return event
        }
    }

    private func removeCmdFMonitor() {
        if let monitor = cmdFMonitor {
            NSEvent.removeMonitor(monitor)
            cmdFMonitor = nil
        }
    }

    // MARK: - Detail view router

    /// Maps the coordinator's search context onto the merger context so the
    /// pane ranks the current section's tracks first.
    private var searchMergerContext: SearchResultsMerger.Context {
        switch container.searchCoordinator.context {
        case .library: .library
        case .playlist(let id): .playlist(id)
        case .other: .other
        }
    }

    @ViewBuilder
    private var detailView: some View {
        // [navperf] temporary instrumentation — remove after measurement
        let _ = print("[navperf] detailview-body isPresented=\(container.searchCoordinator.isPresented) \(Date().timeIntervalSince1970)")
        if container.searchCoordinator.isPresented {
            GlobalSearchPresentationView(
                query: Bindable(container.searchCoordinator).query,
                onExit: {
                    container.searchCoordinator.dismiss()
                    container.searchCoordinator.query = ""
                    isGlobalSearchFocused = false
                },
                context: searchMergerContext,
                onTrackDoubleClick: { track, queue in
                    handleTrackDoubleClick(track, queue: queue)
                }
            )
        } else {
            // LibraryView is kept alive across section switches to avoid the ~0.5 s
            // teardown/rebuild cost of its ~12 000-row Table ↔ NSTableView bridge.
            // It is hidden via opacity + allowsHitTesting when another section is active.
            // LibraryHost's Equatable conformance is only honoured when the call site
            // applies `.equatable()`; without it SwiftUI ignores `==` and re-evaluates
            // the body on every parent re-render.
            ZStack {
                LibraryHost(onTrackDoubleClick: { track, queue in
                    handleTrackDoubleClick(track, queue: queue)
                })
                .equatable()
                .opacity(selectedSection == .library ? 1 : 0)
                .allowsHitTesting(selectedSection == .library)

                // [navperf] temporary instrumentation — remove after measurement
                let _ = print("[navperf] zstack-switch \(selectedSection) \(Date().timeIntervalSince1970)")
                switch selectedSection {
                case .library:
                    Color.clear
                case .playlists:
                    PlaylistsView(onTrackDoubleClick: { track, queue in
                        handleTrackDoubleClick(track, queue: queue)
                    })
                case .playlistDetail(let id):
                    PlaylistDetailViewLoader(
                        playlistId: id,
                        onBack: { selectedSection = .playlists },
                        onTrackDoubleClick: { track, queue in
                            handleTrackDoubleClick(track, queue: queue)
                        }
                    )
                case .folders:
                    FoldersView(onTrackDoubleClick: { track, queue in
                        handleTrackDoubleClick(track, queue: queue)
                    })
                case .sync:
                    SyncView()
                case .sources:
                    SourcesView()
                case .review:
                    ReviewQueueView(focusTrackID: reviewFocusTrackID)
                case .discover:
                    DiscoverView()
                case .queue:
                    PlaybackQueueView()
                }
            }
        }
    }

    // MARK: - Track Detail

    /// Handle double-click on a track — play it and show the detail panel.
    ///
    /// `queue` is the visible table order at the click site; WP1 wires it
    /// into the playback queue so track-end advances to the row below.
    private func handleTrackDoubleClick(_ track: Track, queue: [Track]) {
        // Show detail inspector
        selectedTrackForDetail = track

        // Play the track
        if track.isLocal, let playbackVM = container.playbackViewModel {
            Task {
                await playbackVM.playTrack(track, queue: queue)
            }
        }
    }

    /// Handle a download request from the universal search panel.
    /// Inserts the track into the DB with resolved metadata, then downloads.
    private func handleUniversalDownload(result: UniversalSearchResult) {
        guard let downloadVM = container.downloadViewModel,
              let trackRepo = container.trackRepository,
              let sourceRepo = container.sourceRepository else { return }

        let source = result.source
        let url = result.url

        // Determine preferred source for the download orchestrator
        let preferred: DownloadOrchestrator.PreferredSource
        switch source {
        case .soundcloud: preferred = .soundcloud
        case .youtube: preferred = .youtube
        default: preferred = .auto
        }

        // Album = source name, artist = resolved uploader/artist
        let albumName: String
        switch source {
        case .youtube: albumName = "YouTube"
        case .soundcloud: albumName = "SoundCloud"
        case .directAudio: albumName = "Downloads"
        case .genericWeb: albumName = "Web"
        }

        Task {
            // 1. Insert track into DB with resolved metadata
            var track = Track(
                artist: result.artist ?? "Unknown Artist",
                album: albumName,
                title: result.title ?? "Unknown Title",
                format: source == .directAudio ? "audio" : "youtube",
                originalPath: url
            )
            let inserted = try await trackRepo.insert(track)
            guard let trackId = inserted.id else { return }

            // 2. Link to source
            if let src = try? await sourceRepo.upsert(name: sourceLabel(source), userId: ""),
               let sourceId = src.id {
                try? await sourceRepo.linkTrackToSource(
                    trackId: trackId,
                    sourceId: sourceId,
                    externalId: url
                )
            }

            // 3. Re-fetch and download (with artwork for embedding)
            if let fullTrack = try? await trackRepo.fetchTrack(id: trackId) {
                await downloadVM.downloadTracks(
                    [fullTrack],
                    preferredSource: preferred,
                    artworkURL: result.artworkURL
                )
            }
        }
    }

    private func sourceLabel(_ source: ArtworkResolver.Source) -> String {
        switch source {
        case .youtube: return "YouTube"
        case .soundcloud: return "SoundCloud"
        case .directAudio: return "Direct"
        case .genericWeb: return "Web"
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
        // [navperf] temporary instrumentation — remove after measurement
        let _ = print("[navperf] libraryhost-body \(Date().timeIntervalSince1970)")
        LibraryView(onTrackDoubleClick: stored)
            .onAppear {
                if stored == nil { stored = initialCallback }
            }
    }

    static func == (_: LibraryHost, _: LibraryHost) -> Bool { true }
}

// MARK: - Navigation sections

/// Navigation sections in the native macOS sidebar.
///
/// The `.playlistDetail(Int64)` associated-value case is produced dynamically
/// inside the pinned-playlists DisclosureGroup (see `PinnedPlaylistsDisclosure`)
/// and routed by `ContentView.detailView` straight to `PlaylistDetailViewLoader`.
/// Once an associated value is present, Swift cannot synthesise `CaseIterable`,
/// so call sites iterate `SidebarSection.topLevelCases` instead.
enum SidebarSection: Hashable, Identifiable {
    case library
    case playlists
    case playlistDetail(Int64)
    case folders
    case sync
    case sources
    case review
    case discover
    case queue

    var id: String {
        switch self {
        case .library: return "library"
        case .playlists: return "playlists"
        case .playlistDetail(let pid): return "playlistDetail-\(pid)"
        case .folders: return "folders"
        case .sync: return "sync"
        case .sources: return "sources"
        case .review: return "review"
        case .discover: return "discover"
        case .queue: return "queue"
        }
    }

    /// Top-level rows in the LIBRARY sidebar group.
    static let libraryCases: [SidebarSection] = [
        .library, .playlists, .folders, .sync, .sources
    ]

    /// Top-level rows in the WORK sidebar group.
    static let workCases: [SidebarSection] = [
        .review, .discover
    ]

    /// Manual replacement for synthesised `CaseIterable.allCases`.
    /// `.playlistDetail` cases are produced dynamically inside
    /// `PinnedPlaylistsDisclosure`.
    static let topLevelCases: [SidebarSection] = libraryCases + workCases + [.queue]

    var label: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .playlistDetail: ""   // never displayed at top-level; disclosure children render the playlist name directly
        case .folders: "Folders"
        case .sync: "Sync"
        case .sources: "Sources"
        case .review: "Review"
        case .discover: "Discover"
        case .queue: "Queue"
        }
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .playlists: "list.bullet"
        case .playlistDetail: "music.note.list"
        case .folders: "folder"
        case .sync: "arrow.triangle.2.circlepath"
        case .sources: "globe"
        case .review: "doc.on.doc"
        case .discover: "sparkles"
        case .queue: "list.number"
        }
    }

    /// `nil` for `.playlistDetail` — those rows are not bound to a global shortcut.
    var keyboardShortcut: KeyEquivalent? {
        switch self {
        case .library: "1"
        case .playlists: "2"
        case .playlistDetail: nil
        case .folders: "3"
        case .sync: "4"
        case .sources: "5"
        case .review: "6"
        case .discover: "7"
        case .queue: "8"
        }
    }
}

// MARK: - Placeholder view

/// Placeholder view for sections not yet implemented.
struct PlaceholderView: View {
    let title: String
    let icon: String
    let description: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.mlmInkMuted)
            Text(title)
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)
            Text(description)
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }
}

// MARK: - Debounced global search leaf view

/// Isolates per-keystroke observation: the TextField binds to local `text`,
/// so typing only re-renders this tiny leaf. The shared `SearchCoordinator.query`
/// is updated only after a 100 ms debounce (or immediately on Enter/clear),
/// preventing per-keystroke fan-out to LibraryView, PlaylistDetailView, and
/// the global search presentation.
private struct GlobalSearchField: View {
    @Environment(\.container) private var container
    @State private var text = ""
    @FocusState.Binding var isFocused: Bool
    let hasLocalTable: () -> Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    if text != container.searchCoordinator.query {
                        commit()
                    }
                    container.searchCoordinator.submit()
                }
                .onChange(of: container.searchCoordinator.query) { _, newQuery in
                    if text != newQuery {
                        text = newQuery
                    }
                }
                .task(id: text) {
                    guard !text.isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    guard text != container.searchCoordinator.query else { return }
                    commit()
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    container.searchCoordinator.dismiss()
                    container.searchCoordinator.query = ""
                    isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.mlmInkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search_clear_button")
                .accessibilityLabel("search_clear_button")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 240)
        .background(Color.mlmSurface, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("search_field")
        .accessibilityLabel("Search library")
    }

    private func commit() {
        container.searchCoordinator.query = text
        let hasLocal = hasLocalTable()
        container.searchCoordinator.queryChanged(hasLocalTable: hasLocal)
    }
}
