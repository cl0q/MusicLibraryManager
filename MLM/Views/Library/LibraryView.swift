import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// All Tracks — header with the Local/Remote picker (until W2-B's scope bar), Shuffle and Scan
/// Library Folder, and the shared track table (`TrackListTable`). Hosted in the shell's
/// content scaffold, which shows the drive banner; rows refresh in place.
struct LibraryView: View {
    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?

    /// Play a track with the visible rows as queue context (the window's activation).
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @State private var viewModel: LibraryViewModel?
    private let usesPreloadedModel: Bool

    init(
        onTrackDoubleClick: ((Track, [Track]) -> Void)? = nil,
        initialViewModel: LibraryViewModel? = nil
    ) {
        self.onTrackDoubleClick = onTrackDoubleClick
        self._viewModel = State(initialValue: initialViewModel)
        self.usesPreloadedModel = initialViewModel != nil
    }

    var body: some View {
        Group {
            if let viewModel {
                libraryContent(viewModel)
            } else {
                // A frame at most: the model exists from launch. Never a full-pane spinner.
                Color.clear
            }
        }
        .task {
            guard !usesPreloadedModel else { return }
            if viewModel == nil { viewModel = container.libraryViewModel }
            viewModel?.searchQuery = container.searchCoordinator.query
            await viewModel?.loadTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { note in
            if let ids = note.userInfo?["removedIds"] as? [Int64] {
                viewModel?.removeTracks(ids: Set(ids))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await viewModel?.refresh() }
        }
        .background {
            AvailabilityCheckStatus()
        }
    }

    // MARK: - Content

    private func libraryContent(_ viewModel: LibraryViewModel) -> some View {
        VStack(spacing: 0) {
            libraryHeader(viewModel)
            Divider()
            TrackListTable(
                model: viewModel.list,
                configuration: .allTracks(activate: onTrackDoubleClick, totals: viewModel.totals)
            ) {
                emptyState(viewModel)
            }
        }
        .onChange(of: container.searchCoordinator.query) { _, q in
            guard q != viewModel.searchQuery else { return }
            viewModel.searchQuery = q
        }
    }

    @ViewBuilder
    private func emptyState(_ viewModel: LibraryViewModel) -> some View {
        if !viewModel.searchQuery.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchQuery)
        } else if viewModel.selectedTab == .local {
            ContentUnavailableView {
                Label("No tracks yet", systemImage: "music.note")
            } description: {
                Text("Import music from a folder, or import a playlist from SoundCloud, YouTube or Spotify.")
            } actions: {
                Button("Import Files or Folder…") { shell?.chooseImportFolder() }
                Button("Import Playlist from Source…") { shell?.showSources() }
            }
        } else {
            ContentUnavailableView("Every track is downloaded", systemImage: "checkmark.circle")
        }
    }

    /// Content header: the Local/Remote segment control, then the view's own actions —
    /// `Shuffle` and `Scan Library Folder` ⌘R (UC-TB-02, DEC-048). Counts come from SQL.
    private func libraryHeader(_ viewModel: LibraryViewModel) -> some View {
        HStack(spacing: Spacing.m) {
            Picker("Source", selection: Bindable(viewModel).selectedTab) {
                ForEach(LibraryTab.allCases) { tab in
                    Text("\(tab.label) (\(countFor(tab, viewModel: viewModel).formatted(.number)))")
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .labelsHidden()
            .accessibilityIdentifier("library_source_picker")
            .accessibilityLabel("library_source_picker")

            Spacer()

            Button {
                Task {
                    if let pvm = container.playbackViewModel {
                        await pvm.playShuffled(viewModel.displayedTracks.filter { $0.availability() == .local })
                    }
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .help("Shuffle All Tracks")
            .disabled(!viewModel.list.hasPlayableRows || LibraryDriveState.current(container).isOffline)
            .accessibilityIdentifier("library_shuffle_button")

            ScanLibraryFolderButton()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private func countFor(_ tab: LibraryTab, viewModel: LibraryViewModel) -> Int {
        switch tab {
        case .local: viewModel.localCount
        case .remote: viewModel.remoteCount
        }
    }
}

/// The file check's status-bar phase (UC-STATUS-06): `Checking files…` with the small
/// spinner after 300 ms while `LibraryAvailabilityMonitor` runs. Lives in All Tracks, which
/// stays alive, so the phase shows in every place's status bar.
private struct AvailabilityCheckStatus: View {
    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(\.openSettings) private var openSettings
    @State private var token: StatusBarCenter.LoadingToken?

    var body: some View {
        let checking = container.availabilityMonitor?.isChecking ?? false
        let suspiciousStops = container.availabilityMonitor?.suspiciousStops ?? 0
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // A check that stopped because most files weren't found says so once (S3).
            .onChange(of: suspiciousStops) { old, new in
                guard new > old else { return }
                let folder = container.availabilityMonitor?.suspiciousFolder ?? ""
                statusBar?.post(LibraryAvailabilityMonitor.suspiciousStopMessage(folder: folder), actions: [
                    StatusAction("Open Settings") { openSettings(tab: .library) },
                ])
            }
            .onChange(of: checking, initial: true) { _, running in
                if running, token == nil {
                    token = statusBar?.beginLoading(LibraryAvailabilityMonitor.loadingPhase)
                } else if !running, let current = token {
                    statusBar?.endLoading(current)
                    token = nil
                }
            }
    }
}

/// `Scan Library Folder` — the shell's scan (`ShellActions.scanLibraryFolder()`), also in the
/// Library menu and on ⌘R (Track ▸ Refresh from Source, the only ⌘R; UC-KEY-15/39). All Tracks
/// stays alive while hidden, so the button is enabled only while All Tracks is the visible
/// place; only this small view reads that, so switching places doesn't re-render the table.
private struct ScanLibraryFolderButton: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(ShellActions.self) private var actions: ShellActions?

    private var isRescanning: Bool { actions?.isScanningLibraryFolder ?? false }

    private var isVisiblePlace: Bool {
        (navigation?.isAllTracksVisible ?? true) && !container.searchCoordinator.isPresented
    }

    var body: some View {
        Button {
            actions?.scanLibraryFolder()
        } label: {
            if isRescanning {
                ProgressView().controlSize(.small)
            } else {
                Label("Scan Library Folder", systemImage: "arrow.clockwise")
            }
        }
        .help("Scan the library folder for changes ⌘R")
        .disabled(actions == nil || isRescanning || !isVisiblePlace)
        .accessibilityIdentifier("rescan_button")
        .accessibilityLabel("rescan_button")
    }
}
