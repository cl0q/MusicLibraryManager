import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// All Tracks — header with the Local/Remote picker, Shuffle and Scan Library Folder, and
/// the sortable `LibraryTable` for the rows. Hosted in the shell's content scaffold.
struct LibraryView: View {
    @Environment(\.container) private var container

    /// Callback when a track is double-clicked.
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @State private var viewModel: LibraryViewModel?
    @State private var importViewModel: ImportViewModel?
    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []
    @State private var isRescanning = false
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
                ProgressView("Initializing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard !usesPreloadedModel else { return }
            initializeViewModel()
            viewModel?.searchQuery = container.searchCoordinator.query
            // Run track loading and sidebar data fetches concurrently —
            // the table doesn't depend on playlists/profiles, so loading
            // them sequentially added ~100-200ms of fixed latency.
            async let loadTracks: () = viewModel?.loadTracks() ?? ()
            async let loadPlaylists: () = reloadPlaylists()
            async let loadProfiles: () = reloadSyncProfiles()
            _ = await (loadTracks, loadPlaylists, loadProfiles)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in
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
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
            Task { await reloadSyncProfiles() }
        }
    }

    // MARK: - Content

    private func libraryContent(_ viewModel: LibraryViewModel) -> some View {
        // The drive-not-connected banner is the shell's (ContentScaffold, UC-LAYOUT-02);
        // the view's own "Library drive is disconnected" strip is gone.
        VStack(spacing: 0) {
            libraryHeader(viewModel)
            Divider()
            LibraryTable(
                viewModel: viewModel,
                onDoubleClick: onTrackDoubleClick,
                availablePlaylists: availablePlaylists,
                availableSyncProfiles: availableSyncProfiles
            )
        }
        .onChange(of: container.searchCoordinator.query) { _, q in
            guard q != viewModel.searchQuery else { return }
            viewModel.searchQuery = q
        }
    }

    /// Content header: the Local/Remote segment control, then the view's own actions —
    /// `Shuffle` and `Scan Library Folder` ⌘R moved here from the window toolbar, which is
    /// constant in every place (UC-TB-02, DEC-048). The place's name is the window title.
    private func libraryHeader(_ viewModel: LibraryViewModel) -> some View {
        HStack(spacing: 12) {
            Picker("Source", selection: Bindable(viewModel).selectedTab) {
                ForEach(LibraryTab.allCases) { tab in
                    Text("\(tab.label) (\(countFor(tab, viewModel: viewModel)))")
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
                        await pvm.playShuffled(viewModel.displayedTracks)
                    }
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .help("Shuffle play library")
            .disabled(viewModel.displayedTracks.isEmpty)
            .accessibilityIdentifier("library_shuffle_button")

            Button {
                Task { await rescan() }
            } label: {
                if isRescanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Scan Library Folder", systemImage: "arrow.clockwise")
                }
            }
            .help("Scan the library folder for changes ⌘R")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isRescanning)
            .accessibilityIdentifier("rescan_button")
            .accessibilityLabel("rescan_button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func countFor(_ tab: LibraryTab, viewModel: LibraryViewModel) -> Int {
        switch tab {
        case .local: viewModel.localCount
        case .remote: viewModel.remoteCount
        }
    }

    // MARK: - Actions

    private func rescan() async {
        guard !isRescanning else { return }
        ensureImportViewModel()
        guard let importVM = importViewModel else { return }

        isRescanning = true
        // The import view model only knows the library folder after loading it; without
        // this the scan always stopped with "No library root configured".
        await importVM.loadLibraryRoot()
        await importVM.importLibrary()
        await viewModel?.refresh()
        isRescanning = false
    }

    private func reloadPlaylists() async {
        guard let repo = container.playlistRepository else { return }
        availablePlaylists = (try? await repo.fetchAll()) ?? []
    }

    private func reloadSyncProfiles() async {
        if let syncVM = container.syncViewModel {
            if syncVM.profiles.isEmpty {
                await syncVM.loadProfiles()
            }
            availableSyncProfiles = syncVM.profiles
        }
    }

    // MARK: - Initialization

    private func initializeViewModel() {
        guard viewModel == nil else { return }
        viewModel = container.libraryViewModel
    }

    private func ensureImportViewModel() {
        guard importViewModel == nil,
              let importService = container.importService,
              let configRepo = container.configRepository else { return }
        importViewModel = ImportViewModel(
            importService: importService,
            configRepository: configRepo,
            activityViewModel: container.activityViewModel
        )
    }

}
