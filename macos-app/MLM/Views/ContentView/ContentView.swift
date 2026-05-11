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

/// Allows spacebar preview to know which track is selected in the active view.
struct SelectedTrackKey: FocusedValueKey {
    typealias Value = Track?
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

    var selectedTrack: Track?? {
        get { self[SelectedTrackKey.self] }
        set { self[SelectedTrackKey.self] = newValue }
    }
}

// MARK: - Root content view

/// Root content view with full window layout.
///
/// Layout (top → bottom):
/// ```
/// ┌────────┬──────────────────────┐
/// │Sidebar │  Detail content      │  NavigationSplitView
/// │        │                      │
/// ├────────┴──────────────────────┤
/// │ ▶ No track playing     —:—   │  MiniPlayerView (36px)
/// ├───────────────────────────────┤
/// │ ▼ Activity                    │  ActivityPanel (36px collapsed)
/// └───────────────────────────────┘
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

            // Separator
            Rectangle()
                .fill(Color.mlmEdge)
                .frame(height: 1)

            // Persistent mini player bar
            MiniPlayerView()

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
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case library
    case playlists
    case folders
    case sync
    case sources

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .folders: "Folders"
        case .sync: "Sync"
        case .sources: "Sources"
        }
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .playlists: "list.bullet"
        case .folders: "folder"
        case .sync: "arrow.triangle.2.circlepath"
        case .sources: "globe"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .library: "1"
        case .playlists: "2"
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
