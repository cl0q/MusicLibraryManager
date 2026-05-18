import SwiftUI

// MARK: - FocusedValues for ⌘1–5 navigation shortcuts

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
/// │ 🔴🟡🟢  [prev] [play] [next]  ♪ Title · Artist  │  Toolbar (PlayerBar)
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

    /// Track selected for detail panel (via double-click or "More Info").
    @State private var selectedTrackForDetail: Track?

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
                // Phase 38: Sync indicator visible across all routes (D-11)
                ToolbarItem(placement: .primaryAction) {
                    SyncToolbarIndicator(selectedSection: $selectedSection)
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

/// Navigation sections matching the Tauri app sidebar.
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

    var id: String {
        switch self {
        case .library: return "library"
        case .playlists: return "playlists"
        case .playlistDetail(let pid): return "playlistDetail-\(pid)"
        case .folders: return "folders"
        case .sync: return "sync"
        case .sources: return "sources"
        }
    }

    /// Manual replacement for synthesised `CaseIterable.allCases`.
    /// Sidebar iterates these for top-level rows; `.playlistDetail` cases are
    /// produced dynamically inside `PinnedPlaylistsDisclosure` (Plan 36-04).
    static let topLevelCases: [SidebarSection] = [
        .library, .playlists, .folders, .sync, .sources
    ]

    var label: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .playlistDetail: ""   // never displayed at top-level; disclosure children render the playlist name directly
        case .folders: "Folders"
        case .sync: "Sync"
        case .sources: "Sources"
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
        }
    }

    /// `nil` for `.playlistDetail` — those rows are not bound to a global ⌘1–5 shortcut.
    var keyboardShortcut: KeyEquivalent? {
        switch self {
        case .library: "1"
        case .playlists: "2"
        case .playlistDetail: nil
        case .folders: "3"
        case .sync: "4"
        case .sources: "5"
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
