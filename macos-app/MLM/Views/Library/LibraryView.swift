import SwiftUI

/// Library browser container — toolbar with Local/Remote picker, search,
/// re-scan button, and the sortable `LibraryTable` for the actual rows.
struct LibraryView: View {
    @Environment(\.container) private var container

    /// Callback when a track is double-clicked.
    var onTrackDoubleClick: ((Track) -> Void)?

    @State private var viewModel: LibraryViewModel?
    @State private var importViewModel: ImportViewModel?
    @State private var availablePlaylists: [Playlist] = []
    @State private var isRescanning = false
    @FocusState private var isSearchFocused: Bool

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
            initializeViewModel()
            await viewModel?.loadTracks()
            await reloadPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await viewModel?.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isSearchFocused = true
        }
    }

    // MARK: - Content

    private func libraryContent(_ viewModel: LibraryViewModel) -> some View {
        VStack(spacing: 0) {
            libraryHeader(viewModel)
            Divider()
            LibraryTable(
                viewModel: viewModel,
                onDoubleClick: onTrackDoubleClick,
                availablePlaylists: availablePlaylists
            )
        }
        .searchable(
            text: Bindable(viewModel).searchQuery,
            placement: .toolbar,
            prompt: "Search library"
        )
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await rescan() }
                } label: {
                    if isRescanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Re-scan Library", systemImage: "arrow.clockwise")
                    }
                }
                .help("Re-scan the library folder for changes")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isRescanning)
            }

            ToolbarItem(placement: .automatic) {
                Text("\(viewModel.displayedTracks.count) tracks")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Detail-pane header: title on the left, then the Local/Remote
    /// segment control. The window toolbar's `.principal` slot stays
    /// reserved for the PlayerBar — putting the tab control here keeps
    /// it associated with the Library view rather than the global player.
    private func libraryHeader(_ viewModel: LibraryViewModel) -> some View {
        HStack(spacing: 12) {
            Text("Library")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Picker("Source", selection: Bindable(viewModel).selectedTab) {
                ForEach(LibraryTab.allCases) { tab in
                    Text("\(tab.label) (\(countFor(tab, viewModel: viewModel)))")
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .labelsHidden()

            Spacer()
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
        await importVM.importLibrary()
        await viewModel?.refresh()
        isRescanning = false
    }

    private func reloadPlaylists() async {
        guard let repo = container.playlistRepository else { return }
        availablePlaylists = (try? await repo.fetchAll()) ?? []
    }

    // MARK: - Initialization

    private func initializeViewModel() {
        guard viewModel == nil,
              let trackRepo = container.trackRepository else { return }
        viewModel = LibraryViewModel(trackRepository: trackRepo)
    }

    private func ensureImportViewModel() {
        guard importViewModel == nil,
              let importService = container.importService,
              let configRepo = container.configRepository else { return }
        importViewModel = ImportViewModel(
            importService: importService,
            configRepository: configRepo
        )
    }
}
