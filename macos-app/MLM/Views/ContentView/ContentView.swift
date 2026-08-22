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
    @State private var globalSearchQuery = ""
    @State private var isGlobalSearchPresented = false
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
            isGlobalSearchPresented = true
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
        .sheet(item: $playlistSelectionContainer) { selection in
            NewPlaylistFromSelectionSheet(trackIds: selection.trackIds)
        }
        .sheet(item: $syncProfileSelectionContainer) { selection in
            NewSyncProfileFromSelectionSheet(trackIds: selection.trackIds)
        }
        .onChange(of: selectedSection) { _, _ in
            isGlobalSearchPresented = false
            isGlobalSearchFocused = false
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
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selectedSection: $selectedSection)
                    .frame(minWidth: 192)
            } detail: {
                detailView
            }
            .inspector(isPresented: showDetailInspector) {
                if let track = selectedTrackForDetail {
                    TrackDetailView(track: track, onClose: {
                        selectedTrackForDetail = nil
                    })
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let vm = container.playbackViewModel {
                        PlayerBar(viewModel: vm)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search library…", text: $globalSearchQuery)
                            .textFieldStyle(.plain)
                            .focused($isGlobalSearchFocused)
                            .onChange(of: isGlobalSearchFocused) { _, isFocused in
                                if isFocused {
                                    isGlobalSearchPresented = true
                                }
                            }
                            .onChange(of: globalSearchQuery) { _, query in
                                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    isGlobalSearchPresented = true
                                    isGlobalSearchFocused = true
                                } else if !isGlobalSearchFocused {
                                    isGlobalSearchPresented = false
                                }
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 240)
                    .background(Color.mlmSurface, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("search_field")
                    .accessibilityLabel("Search library")
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
    }

    // MARK: - Detail view router

    @ViewBuilder
    private var detailView: some View {
        if isGlobalSearchPresented {
            GlobalSearchPresentationView(query: $globalSearchQuery) {
                isGlobalSearchPresented = false
                isGlobalSearchFocused = false
                globalSearchQuery = ""
            }
        } else {
            switch selectedSection {
            case .library:
                LibraryView(onTrackDoubleClick: { track in
                    handleTrackDoubleClick(track)
                })
            case .playlists:
                PlaylistsView(onTrackDoubleClick: { track in
                    handleTrackDoubleClick(track)
                })
            case .playlistDetail(let id):
                PlaylistDetailViewLoader(
                    playlistId: id,
                    onBack: { selectedSection = .playlists },
                    onTrackDoubleClick: { track in
                        handleTrackDoubleClick(track)
                    }
                )
            case .folders:
                FoldersView(onTrackDoubleClick: { track in
                    handleTrackDoubleClick(track)
                })
            case .sync:
                SyncView()
            case .sources:
                SourcesView()
            case .review:
                ReviewQueueView(focusTrackID: reviewFocusTrackID)
            case .discover:
                DiscoverView()
            }
        }
    }

    // MARK: - Track Detail Inspector

    /// Whether the detail inspector should be shown.
    private var showDetailInspector: Binding<Bool> {
        Binding(
            get: { selectedTrackForDetail != nil },
            set: { if !$0 { selectedTrackForDetail = nil } }
        )
    }

    /// Handle double-click on a track — play it and show the detail panel.
    private func handleTrackDoubleClick(_ track: Track) {
        // Show detail inspector
        selectedTrackForDetail = track

        // Play the track
        if track.isLocal, let playbackVM = container.playbackViewModel {
            Task {
                await playbackVM.playTrack(track)
            }
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
    static let topLevelCases: [SidebarSection] = libraryCases + workCases

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
