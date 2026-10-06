import SwiftUI

/// **Genres** (V-GENRES, ⌘3, DEC-025, §10 Q9): every genre of the library in a native table —
/// track count and time from SQL (`GROUP BY genre`), sortable by name and count, multi-selection
/// (the argument of `Merge Genres…`), type-select, the in-place filter by name, the genre menu
/// (CM-GENRE-ROW), Return / double-click opens the genre (V-GENRED, pushed). A row is a drop
/// target for tracks: dropping sets their genre (one undoable tag edit, D-SET-GW-TRACK-TO-GENRE).
///
/// Replaces the old genre tools' card grid in Settings ▸ Advanced (ST-STUDIO-GRID / ST-ADV).
struct GenresView: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    @State private var overview: GenreOverview?
    @State private var loadFailed = false
    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<GenreSummary>] = [KeyPathComparator(\.trackCount, order: .reverse)]
    @State private var renamingKey: String?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var mergeGenres: GenreMergeRequest?
    @FocusState private var renameFocused: Bool

    private var workbench: GenreWorkbench { GenreWorkbench.shared }
    private var filter: SearchFilter { container.searchCoordinator.filter(for: .genres) }

    private var actions: GenreActions {
        GenreActions(container: container, shell: shell, statusBar: statusBar, undo: undo)
    }

    private var genres: [GenreSummary] { overview?.genres ?? [] }

    private var shown: [GenreSummary] {
        let filter = self.filter
        return genres.filter { filter.matchesName($0.name) }.sorted(using: sortOrder)
    }

    private func selected(_ keys: Set<String>) -> [GenreSummary] {
        genres.filter { keys.contains($0.key) }
    }

    // MARK: Body

    var body: some View {
        let shown = self.shown
        ContentScaffold(showsDriveBanner: false) {
            content(shown: shown)
                .windowCount(overview == nil ? nil : (filter.isEmpty ? GenreText.genres(genres.count) : "\(shown.count.formatted(.number)) of \(GenreText.genres(genres.count))"))
                .statusBarText(statusText(shown: shown))
        } header: {
            if !genres.isEmpty { commandBar }
        }
        .modifier(WindowTitleModifier())
        .sheet(item: $mergeGenres) { request in
            GenreMergeSheet(genres: request.genres) { mergedKey in
                selection = [mergedKey]
            }
        }
        .task { await load() }
        .task(id: container.activeLibrary?.libraryId) { workbench.use(libraryID: container.activeLibrary?.libraryId) }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in Task { await load() } }
        .onAppear { takeRequestedSelection() }
        .onChange(of: GenreRequests.shared.listSelection) { _, _ in takeRequestedSelection() }
    }

    private func load() async {
        guard let repository = GenreRepository.live(container) else { return }
        do {
            let loaded = try await repository.overview()
            overview = loaded
            loadFailed = false
            // The selection keeps only genres that still exist (UC-TABLE-08).
            let keys = Set(loaded.genres.map(\.key))
            if !selection.isSubset(of: keys) { selection = selection.intersection(keys) }
        } catch {
            AppLogger.shared.error("Genres couldn’t load: \(error)", source: "Genres")
            loadFailed = true
        }
    }

    private func takeRequestedSelection() {
        guard let keys = GenreRequests.shared.listSelection else { return }
        selection = keys
        GenreRequests.shared.listSelection = nil
    }

    // MARK: Command bar (Merge Genres… · More)

    private var commandBar: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)
            Button("Merge Genres…") { mergeGenres = GenreMergeRequest(genres: selected(selection)) }
                .disabled(selection.count < 2)
                .help(selection.count < 2 ? "Select two or more genres to merge them" : "Merge the selected genres into one")
            Menu {
                Button("Export Create ML Training Set…") { GenreRequests.shared.showsExportSheet = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(shown: [GenreSummary]) -> some View {
        if loadFailed && overview == nil {
            ContentUnavailableView {
                Label("Can’t load the genres", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. Your music and your library file are not affected.")
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
            }
        } else if let overview, overview.genres.isEmpty {
            ContentUnavailableView {
                Label("No genres yet", systemImage: "guitars")
            } description: {
                Text("Genres come from the tags of imported files, or from the Genre field in Info. No track in this library has a genre.")
            } actions: {
                Button("Show All Tracks") { navigation.select(.allTracks) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            table(shown: shown)
                .overlay {
                    if overview != nil, shown.isEmpty {
                        ContentUnavailableView {
                            Label("No genres match", systemImage: "magnifyingglass")
                        } description: {
                            Text("No genre matches the search.")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
    }

    private func table(shown: [GenreSummary]) -> some View {
        let hints = GenreLookalikes.hints(genres)
        let rows = overview == nil ? GenrePlaceholders.rows : shown
        return Table(of: GenreSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Genre", value: \GenreSummary.name) { genre in
                nameCell(genre)
            }
            .width(min: 140, ideal: 260)
            TableColumn("Tracks", value: \GenreSummary.trackCount) { genre in
                Text(genre.trackCount, format: .number).monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 110)
            .alignment(.numeric)
            TableColumn("Time") { (genre: GenreSummary) in
                Text(TrackDurationText.total(genre.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90, max: 120)
            .alignment(.numeric)
            TableColumn("") { (genre: GenreSummary) in
                hintCell(genre, lookalike: hints[genre.key])
            }
            .width(min: 120, ideal: 280)
        } rows: {
            ForEach(rows) { genre in
                TableRow(genre)
                    // Tracks dropped on a genre get it (one undoable tag edit, UC-DND matrix).
                    .dropDestination(for: TrackDragItem.self) { items in
                        drop(items, on: genre)
                    }
            }
        }
        .contextMenu(forSelectionType: String.self) { keys in
            let subjects = selected(keys)
            if !subjects.isEmpty {
                GenreMenu(genres: subjects, place: .row, actions: actions,
                          open: open, rename: startRename,
                          merge: { mergeGenres = GenreMergeRequest(genres: $0) })
            }
        } primaryAction: { keys in
            if keys.count == 1, let genre = selected(keys).first { open(genre) }
        }
        .alternatingRowBackgrounds()
        .redacted(reason: overview == nil ? .placeholder : [])
        .allowsHitTesting(overview != nil)
        .accessibilityIdentifier("genre_table")
    }

    @ViewBuilder
    private func nameCell(_ genre: GenreSummary) -> some View {
        if renamingKey == genre.key {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Genre name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onAppear { renameFocused = true }
                    .onSubmit { commitRename(genre) }
                    .onExitCommand { endRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, renamingKey == genre.key { commitRename(genre) }
                    }
                if let renameError {
                    Text(renameError).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            Label {
                Text(genre.name).lineLimit(1)
            } icon: {
                Image(systemName: "tag").foregroundStyle(.secondary)
            }
            .typeSelectEquivalent(genre.name)
        }
    }

    @ViewBuilder
    private func hintCell(_ genre: GenreSummary, lookalike: GenreSummary?) -> some View {
        let staged = workbench.stagedCount(genre.key)
        if staged > 0 {
            // V-GENRES.N15: staged suggestions are kept; the list says so in words.
            Text(staged == 1 ? "1 change not saved" : "\(staged.formatted(.number)) changes not saved")
                .foregroundStyle(.secondary)
        } else if let lookalike {
            HStack(spacing: Spacing.xs) {
                Text("Looks like “\(lookalike.name)”").foregroundStyle(.secondary).lineLimit(1)
                Button("Merge…") {
                    let group = GenreLookalikes.group(of: genre, in: genres)
                    selection = Set(group.map(\.key))
                    mergeGenres = GenreMergeRequest(genres: group)
                }
                .buttonStyle(.link)
            }
        }
    }

    /// `1,968 tracks have no genre · Show` (V-GENRES.N04/N05): All Tracks with `is: no genre`.
    @ViewBuilder
    private var footer: some View {
        if let overview, overview.tracksWithoutGenre > 0 {
            HStack(spacing: Spacing.s) {
                Text(overview.tracksWithoutGenre == 1
                     ? "1 track has no genre"
                     : "\(overview.tracksWithoutGenre.formatted(.number)) tracks have no genre")
                    .monospacedDigit()
                Button("Show") {
                    search?.show(SearchFilter(tokens: [.availability(.noGenre)]), in: .allTracks)
                }
                .buttonStyle(.link)
                .disabled(search == nil)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xs)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// `48 genres · 10,967 tracks with a genre` · `3 genres selected · 1,204 tracks` ·
    /// `12 of 48 genres` while filtered (UC-STATUS-02).
    private func statusText(shown: [GenreSummary]) -> String? {
        guard let overview else { return nil }
        let picked = selected(selection)
        if !picked.isEmpty {
            let tracks = picked.reduce(0) { $0 + $1.trackCount }
            return "\(StatusBarText.count(picked.count, "genre", "genres")) selected · \(StatusBarText.tracks(tracks))"
        }
        if !filter.isEmpty {
            return "\(shown.count.formatted(.number)) of \(GenreText.genres(overview.genres.count))"
        }
        return "\(GenreText.genres(overview.genres.count)) · \(StatusBarText.tracks(overview.tracksWithGenre)) with a genre"
    }

    // MARK: Commands

    private func open(_ genre: GenreSummary) {
        navigation.push(.genre(genre.name))
    }

    private func drop(_ items: [TrackDragItem], on genre: GenreSummary) {
        let decision = DropRules.decide(.tracks(TrackDragPayload(items: items)), onto: .genreRow(key: genre.key, name: genre.name),
                                        context: DropContext.current(container))
        DropPerformer(container: container, shell: shell, statusBar: statusBar, undo: undo ?? .main).perform(decision)
    }

    private func startRename(_ genre: GenreSummary) {
        selection = [genre.key]
        renameText = genre.name
        renameError = nil
        renamingKey = genre.key
    }

    private func endRename() {
        renamingKey = nil
        renameError = nil
    }

    /// Return commits, Esc reverts (UC-KEY-20); a failure keeps the field open with a sentence
    /// under it (UC-SHEET-17). One undoable tag edit over the genre's tracks.
    private func commitRename(_ genre: GenreSummary) {
        guard renamingKey == genre.key else { return }
        guard let name = GenreName.cleaned(renameText), name != genre.name else {
            endRename()
            return
        }
        guard let edits = GenreEdits.live(undo: undo, container: container) else { return }
        Task {
            do {
                try await edits.rename(genre, to: name, reportsFailure: false)
                endRename()
                if let newKey = GenreName.key(name) {
                    workbench.move(from: genre.key, to: newKey)
                    selection = [newKey]
                }
            } catch {
                renameError = "Couldn’t rename this genre — the library database didn’t answer. Try Again"
                renameFocused = true
            }
        }
    }
}

/// The genres of one `Merge Genres…` sheet.
struct GenreMergeRequest: Identifiable {
    let id = UUID()
    let genres: [GenreSummary]
}

/// Redacted rows of the first load (UC-TABLE-09).
enum GenrePlaceholders {
    static let rows: [GenreSummary] = (1...14).map { index in
        GenreSummary(key: "placeholder-\(index)", name: "Placeholder genre \(index)",
                     trackCount: 100, duration: 3_600, spellings: [])
    }
}
