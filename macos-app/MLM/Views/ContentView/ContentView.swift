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

    /// Library repair alert states
    @State private var showingRepairAlert = false
    @State private var repairRunning = false
    @State private var repairResult: String = ""

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
        // Handle library repair trigger from main menu
        .onReceive(NotificationCenter.default.publisher(for: .triggerLibraryRepair)) { _ in
            runGlobalLibraryRepair()
        }
        .alert("Stale Pfade reparieren", isPresented: $showingRepairAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repairResult)
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
            if selectedSection == .folders {
                NotificationCenter.default.post(name: .focusFolderSearchField, object: nil)
            } else {
                selectedSection = .library
                NotificationCenter.default.post(name: .focusSearchField, object: nil)
            }
        }
        .sheet(item: $playlistSelectionContainer) { selection in
            NewPlaylistFromSelectionSheet(trackIds: selection.trackIds)
        }
        .sheet(item: $syncProfileSelectionContainer) { selection in
            NewSyncProfileFromSelectionSheet(trackIds: selection.trackIds)
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
                    SyncTurboToggle()
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
        case .duplicates:
            ReviewQueueView()
        case .discoveryInbox:
            DiscoveryInboxView()
        case .grooveStudio:
            GrooveStudioView()
        case .sync:
            SyncView()
        case .sources:
            SourcesView()
        case .reelsInbox:
            ReelsInboxView()
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

    /// Triggered from the main menu CommandMenu to repair database organized_path columns.
    private func runGlobalLibraryRepair() {
        guard let trackRepo = container.trackRepository,
              let configRepo = container.configRepository else { return }
        
        repairRunning = true
        repairResult = "Die Reparatur verwaister Pfade wurde im Hintergrund gestartet. Bitte warten..."
        showingRepairAlert = true
        
        Task {
            let service = LibraryRepairService(
                trackRepository: trackRepo,
                configRepository: configRepo
            )
            do {
                let r = try await service.repairStaleOrganizedPaths()
                repairResult = """
                    Stale Pfade repariert!
                    
                    Geprüft: \(r.inspected)
                    Intakt: \(r.alreadyValid)
                    Repariert: \(r.repaired)
                    Demoted to Remote: \(r.demotedToRemote)
                    Nicht reparierbar: \(r.unrepairable)
                    """
            } catch {
                repairResult = "Fehler bei der Reparatur: \(error.localizedDescription)"
            }
            repairRunning = false
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
    case duplicates
    case discoveryInbox
    case grooveStudio
    case sync
    case sources
    case reelsInbox

    var id: String {
        switch self {
        case .library: return "library"
        case .playlists: return "playlists"
        case .playlistDetail(let pid): return "playlistDetail-\(pid)"
        case .folders: return "folders"
        case .duplicates: return "duplicates"
        case .discoveryInbox: return "discoveryInbox"
        case .grooveStudio: return "grooveStudio"
        case .sync: return "sync"
        case .sources: return "sources"
        case .reelsInbox: return "reelsInbox"
        }
    }

    /// Manual replacement for synthesised `CaseIterable.allCases`.
    /// Sidebar iterates these for top-level rows; `.playlistDetail` cases are
    /// produced dynamically inside `PinnedPlaylistsDisclosure` (Plan 36-04).
    static let topLevelCases: [SidebarSection] = [
        .library, .playlists, .folders, .duplicates, .discoveryInbox, .reelsInbox, .grooveStudio, .sync, .sources
    ]

    var label: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .playlistDetail: ""   // never displayed at top-level; disclosure children render the playlist name directly
        case .folders: "Folders"
        case .duplicates: "Duplicates"
        case .discoveryInbox: "Discovery Inbox"
        case .grooveStudio: "Groove Studio"
        case .sync: "Sync"
        case .sources: "Sources"
        case .reelsInbox: "Reels Inbox"
        }
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .playlists: "list.bullet"
        case .playlistDetail: "music.note.list"
        case .folders: "folder"
        case .duplicates: "doc.on.doc"
        case .discoveryInbox: "sparkles"
        case .grooveStudio: "waveform"
        case .sync: "arrow.triangle.2.circlepath"
        case .sources: "globe"
        case .reelsInbox: "play.rectangle.on.rectangle"
        }
    }

    /// `nil` for `.playlistDetail` — those rows are not bound to a global ⌘1–5 shortcut.
    var keyboardShortcut: KeyEquivalent? {
        switch self {
        case .library: "1"
        case .playlists: "2"
        case .playlistDetail: nil
        case .folders: "3"
        case .duplicates: "6"
        case .discoveryInbox: nil
        case .grooveStudio: nil
        case .sync: "4"
        case .sources: "5"
        case .reelsInbox: "7"
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
