import SwiftUI

/// The results of a wider search scope, drawn over the current place only while the user chose
/// `Library` or `Online` in the scope bar (UC-SEARCH-02, V-SEARCH.E03/E09). `This view` never
/// shows this: it filters the place itself. The window title names what was searched where.
struct SearchResultsView: View {
    let search: ToolbarSearchModel
    let library: LibrarySearchModel
    let online: OnlineSearchModel
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container

    private var coordinator: SearchCoordinator { container.searchCoordinator }

    var body: some View {
        let filter = coordinator.activeFilter
        Group {
            switch coordinator.scope {
            case .library, .thisView:
                LibrarySearchResultsView(search: search, model: library, filter: filter, onTrackActivated: onTrackActivated)
            case .online:
                OnlineSearchResultsView(search: search, model: online, filter: filter)
            }
        }
        .navigationTitle(Self.title(filter: filter, scope: coordinator.scope))
        .navigationSubtitle(coordinator.scope == .online ? "Online" : LibraryFooter.libraryName(LibraryLaunchCoordinator.shared))
    }

    /// `“overmono” in your library` / `“overmono” online`; `Search` before anything is typed.
    static func title(filter: SearchFilter, scope: SearchScope) -> String {
        let query = filter.displayText
        guard !query.isEmpty, !filter.isLink else { return "Search" }
        return scope == .online ? "“\(query)” online" : "“\(query)” in your library"
    }
}

// MARK: - Library scope

/// Grouped results (V-SEARCH.E09): Tracks (the shared track table: Status, sorting, selection,
/// context menu, Space preview, Return plays), Playlists, Folders — each with its first few
/// hits and `Show All`, which shows the full list in its own place with the query applied.
/// Sections without hits are left out; Albums wait for W4.
struct LibrarySearchResultsView: View {
    let search: ToolbarSearchModel
    let model: LibrarySearchModel
    let filter: SearchFilter
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedRow: LibraryResultRow?

    var body: some View {
        content
            .task(id: filter) { model.search(filter) }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        let query = filter.displayText
        if filter.isEmpty || filter.isLink {
            ContentUnavailableView {
                Label("Search your library", systemImage: "magnifyingglass")
            } description: {
                Text("Type to find tracks, playlists and folders anywhere in “\(LibraryFooter.libraryName(LibraryLaunchCoordinator.shared))”.")
            }
        } else if let failure = model.failure {
            ContentUnavailableView {
                Label("Can’t search the library", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. Your music and your library file are not affected.")
            } actions: {
                Button("Try Again") { model.refresh() }
                DisclosureGroup("Details") {
                    Text(failure)
                        .textSelection(.enabled)
                }
            }
        } else if let results = model.results, model.searchedFilter == filter {
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No Results for “\(query)”", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing in your library matches.")
                } actions: {
                    Button("Search Online") { search.focus(scope: .online) }
                }
            } else {
                sections(results)
            }
        } else if let results = model.results {
            // A newer query is on its way: the previous results stay (UC-TABLE-09).
            sections(results)
        } else {
            Color.clear
        }
    }

    private func sections(_ results: LibrarySearchResults) -> some View {
        VStack(spacing: 0) {
            if results.trackTotal > 0 {
                sectionHeader("Tracks", total: results.trackTotal, showsAll: results.trackTotal > results.tracks.count) {
                    search.show(filter, in: .allTracks)
                }
                TrackListTable(model: model.tracks, configuration: .searchResults { track, queue in
                    // ⌘L returns to All Tracks, where every result lives (W2-C origin).
                    container.playbackViewModel?.willActivate(track.id, from: .allTracks)
                    onTrackActivated(track, queue)
                }) {
                    EmptyView()
                }
                .frame(height: LibrarySearchMetrics.tableHeight(rows: results.tracks.count))
                if results.playlistTotal > 0 || results.folderTotal > 0 {
                    Divider()
                }
            }
            if results.playlistTotal > 0 || results.folderTotal > 0 {
                namedSections(results)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func namedSections(_ results: LibrarySearchResults) -> some View {
        List(selection: $selectedRow) {
            if results.playlistTotal > 0 {
                Section {
                    ForEach(results.playlists) { playlist in
                        if let id = playlist.id {
                            Label(playlist.name, systemImage: "music.note.list")
                                .tag(LibraryResultRow.playlist(id))
                        }
                    }
                } header: {
                    listHeader("Playlists", total: results.playlistTotal, showsAll: results.playlistTotal > results.playlists.count) {
                        search.show(SearchFilter(text: filter.parsed.freeText), in: .allPlaylists)
                    }
                }
            }
            if results.folderTotal > 0 {
                Section {
                    ForEach(results.folders) { folder in
                        HStack(spacing: Spacing.s) {
                            Label(folder.name, systemImage: "folder")
                            Text(folder.location)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(LibraryResultRow.folder(folder.id))
                    }
                } header: {
                    listHeader("Folders", total: results.folderTotal, showsAll: results.folderTotal > results.folders.count) {
                        search.show(SearchFilter(text: filter.parsed.freeText), in: .folders)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: LibraryResultRow.self) { rows in
            if rows.count == 1, let row = rows.first {
                Button("Open") { open(row) }
            }
        } primaryAction: { rows in
            if let row = rows.first { open(row) }
        }
    }

    /// Double-click / Return on a playlist or folder hit: go there (UC-PRIM-05).
    private func open(_ row: LibraryResultRow) {
        switch row {
        case .playlist(let id):
            search.scope = .thisView
            navigation.select(.playlist(id))
        case .folder(let path):
            search.scope = .thisView
            FolderOpenRequest.shared.open(path)
            navigation.select(.folders)
        }
    }

    private func sectionHeader(_ title: String, total: Int, showsAll: Bool, showAll: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(total, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            if showsAll {
                Button("Show All", action: showAll)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.xs)
    }

    private func listHeader(_ title: String, total: Int, showsAll: Bool, showAll: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(title)
            Text(total, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            if showsAll {
                Button("Show All", action: showAll)
                    .buttonStyle(.link)
            }
        }
    }
}

/// A playlist or folder row of the Library results.
enum LibraryResultRow: Hashable {
    case playlist(Int64)
    case folder(String)
}

/// Fixed metrics of the grouped results (UC-SPACE-03 style: from the mockup's ~28 pt rows).
enum LibrarySearchMetrics {
    static let rowHeight: CGFloat = 28
    /// The Tracks section shows its rows without scrolling: header + rows.
    static func tableHeight(rows: Int) -> CGFloat {
        rowHeight * CGFloat(max(1, rows) + 1) + Spacing.xxs
    }
}

/// A folder chosen in the Library results: Folders opens it (taken once).
@MainActor
@Observable
final class FolderOpenRequest {
    static let shared = FolderOpenRequest()

    private(set) var path: String?

    func open(_ path: String) { self.path = path }

    func take() -> String? {
        defer { path = nil }
        return path
    }
}
