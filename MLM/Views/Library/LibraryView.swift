import SwiftUI

/// All Tracks (V-LIB, THOUGHTS §7.2): one table of every track — a pure table, no header
/// buttons (DEC-048). The availability scope bar above it (`AllTracksScopeBar`, in the
/// scaffold's scope-bar slot) and the toolbar's in-place filter decide the rows; Play /
/// Shuffle All Tracks live in the Playback menu, Scan Library Folder on ⌘R and in the Library
/// menu. Hosted in the shell's content scaffold, which shows the drive banner; rows refresh in
/// place.
struct LibraryView: View {
    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

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
            viewModel?.searchFilter = container.searchCoordinator.filter(for: .allTracks)
            await viewModel?.loadTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryFilesDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in
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
        TrackListTable(model: viewModel.list, configuration: configuration(viewModel)) {
            emptyState(viewModel)
        }
        .overlay {
            if !viewModel.isLoaded, viewModel.errorMessage != nil {
                LibraryLoadErrorView(details: viewModel.errorMessage ?? "") {
                    Task { await viewModel.refresh() }
                }
            }
        }
        // In-place filter (W2-I): All Tracks applies its own place's filter, text and tokens.
        .onChange(of: container.searchCoordinator.filter(for: .allTracks)) { _, filter in
            guard filter != viewModel.searchFilter else { return }
            viewModel.searchFilter = filter
        }
    }

    /// The shared table in its All Tracks context: totals of the scope and filter from SQL
    /// (status bar), the failure reason as the second line only in `Download failed`
    /// (UC-TABLE-13).
    private func configuration(_ viewModel: LibraryViewModel) -> TrackListConfiguration {
        var configuration = TrackListConfiguration.allTracks(activate: onTrackDoubleClick, totals: viewModel.totals)
        configuration.showsFailureDetail = viewModel.scope == .downloadFailed
        return configuration
    }

    /// UC §18: empty library → what fills it; filtered → the system search variant with
    /// `Clear Filters`; an empty scope → what that scope means. The scope bar stays above.
    @ViewBuilder
    private func emptyState(_ viewModel: LibraryViewModel) -> some View {
        let query = viewModel.searchFilter.displayText
        if viewModel.isLibraryEmpty {
            ContentUnavailableView {
                Label("No tracks yet", systemImage: "music.note")
            } description: {
                Text("Import music from a folder, or import a playlist from SoundCloud, YouTube or Spotify.")
            } actions: {
                Button("Import Files or Folder…") { shell?.chooseImportFolder() }
                Button("Import Playlist from Source…") { shell?.showSources() }
            }
        } else if !query.isEmpty {
            ContentUnavailableView {
                Label("No Results for “\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                Button("Clear Filters") { clearFilters() }
                // UC-SEARCH-07: the two ways to look further (same as the scope bar).
                Button("Search the Library") { search?.focus(scope: .library) }
                Button("Search Online") { search?.focus(scope: .online) }
            }
        } else if let empty = AllTracksScopeEmptyState(scope: viewModel.scope) {
            ContentUnavailableView {
                Label(empty.title, systemImage: empty.systemImage)
            } actions: {
                Button("Show All") { viewModel.scope = .all }
            }
        }
    }

    /// `Clear Filters`: empties the toolbar field (text and tokens, W2-I); the scope stays.
    private func clearFilters() {
        if let search, search.place.key == .allTracks {
            search.clear()
        } else {
            container.searchCoordinator.commit(.empty, for: .allTracks)
        }
        viewModel?.searchFilter = SearchFilter()
    }
}

// MARK: - Scope bar

/// The All Tracks scope bar (V-LIB.E02, DEC-011): `All · Local · Not downloaded · Download
/// failed · File missing`, each with its live count for the current filter. The scope is
/// remembered per window (UC-SCOPE-05). Lives in the scaffold's scope-bar slot
/// (`ContentView`'s All Tracks host); hidden while the library has no tracks (the empty state
/// says what fills it). View ▸ Filter follows it while All Tracks is the visible place.
struct AllTracksScopeBar: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @SceneStorage("allTracks.scope") private var storedScope = TrackAvailabilityScope.all.rawValue

    var body: some View {
        if let viewModel = container.libraryViewModel {
            Group {
                if !viewModel.isLibraryEmpty {
                    ScopeBar(
                        items: Self.items(counts: viewModel.counts),
                        selection: Bindable(viewModel).scope,
                        countNoun: .tracks,
                        publishesMenu: isVisiblePlace
                    )
                }
            }
            .task {
                // Restore before (or right after) the first load; the load follows the scope.
                if let stored = TrackAvailabilityScope(rawValue: storedScope), viewModel.scope != stored {
                    viewModel.scope = stored
                }
            }
            .onChange(of: viewModel.scope) { _, scope in
                storedScope = scope.rawValue
            }
        }
    }

    /// The five scopes in the order of UC-SCOPE-02, with their counts (`nil` before the first
    /// load). All five always show, zero included.
    static func items(counts: TrackAvailabilityCounts?) -> [ScopeBarItem<TrackAvailabilityScope>] {
        TrackAvailabilityScope.allCases.map { scope in
            ScopeBarItem(id: scope, title: scope.title, count: counts?.count(for: scope))
        }
    }

    /// The kept-alive All Tracks host stays in the window while another place shows.
    private var isVisiblePlace: Bool {
        (navigation?.isAllTracksVisible ?? true) && !container.searchCoordinator.isPresented
    }
}

/// What an empty scope says (no filter active) — pure, unit-tested. `All` is never empty
/// here: an empty library has its own view.
struct AllTracksScopeEmptyState: Equatable {
    let title: String
    let systemImage: String

    init?(scope: TrackAvailabilityScope) {
        switch scope {
        case .all: return nil
        case .local: (title, systemImage) = ("No local tracks", "music.note")
        case .notDownloaded: (title, systemImage) = ("Every track is downloaded", "icloud")
        case .downloadFailed: (title, systemImage) = ("No tracks with failed downloads", "exclamationmark.arrow.circlepath")
        case .fileMissing: (title, systemImage) = ("No missing files", "doc.questionmark")
        }
    }
}

// MARK: - Load error (V-LIB.E21, UC-EMPTY-05)

/// The first load failed: what couldn't be done, the cause, what is safe, `Try Again`,
/// `Show Logs` and the raw text behind `Details` (UC-COPY-11).
private struct LibraryLoadErrorView: View {
    let details: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can’t load the tracks", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The library database didn’t answer. Your music and your library file are not affected.")
        } actions: {
            Button("Try Again", action: retry)
            Button("Show Logs") {
                ActivityRouter.shared.showLogs(for: nil)
                ActivityRouter.shared.requestWindow(tab: .logs)
            }
            DisclosureGroup("Details") {
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .frame(maxWidth: 360)
        }
        .background(.background)
    }
}

// MARK: - File check phase

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
