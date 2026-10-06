import SwiftUI

/// **A genre** (V-GENRED, pushed from Genres, UC-LAYOUT-05/06): header (kind label `Genre`, the
/// name — click to rename, one undoable tag edit —, facts, `Play` · `Shuffle` · `More`), the
/// genre's tracks in the shared track table (Space previews, Return plays, ⌫ removes from the
/// genre — undoable), and docked below the `Suggested tracks` section with its staging bar.
///
/// Staged suggestions live in `GenreWorkbench` (the session), so they survive going back,
/// switching places and closing the window; only `Discard` or `Save n Changes` end them.
struct GenreDetailView: View {
    /// `TrackListConfiguration.persistenceKey` of a genre's track table (also the playback
    /// origin's `listKey`, ⌘L).
    static let persistenceKey = "genre"

    /// The route's name (`DetailRoute.genre`); the genre is found by its key.
    let name: String
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?

    @State private var genre: GenreSummary?
    @State private var genreTracks: [Track] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var list = TrackListModel(sortOrder: TrackSortOrder(column: .added, ascending: false))
    @State private var writesTags = false
    @State private var isEditingTitle = false
    @State private var titleText = ""
    @State private var titleError: String?
    @FocusState private var titleFocused: Bool

    private var key: String { GenreName.key(name) ?? name.lowercased() }
    private var displayName: String { genre?.name ?? name }
    private var workbench: GenreWorkbench { GenreWorkbench.shared }
    private var filter: SearchFilter { container.searchCoordinator.filter(for: .genre(name)) }

    private var actions: GenreActions {
        GenreActions(container: container, shell: shell, statusBar: statusBar, undo: undo)
    }

    var body: some View {
        ContentScaffold(showsDriveBanner: true) {
            content
        } header: {
            header
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
        .task(id: key) {
            workbench.use(libraryID: container.activeLibrary?.libraryId)
            writesTags = await TagWriteSetting.isEnabled(container.configRepository)
            await load()
        }
        .onChange(of: filter) { _, _ in Task { await showTracks() } }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .pendingTagWritesDidChange)) { _ in
            Task { writesTags = await TagWriteSetting.isEnabled(container.configRepository) }
        }
    }

    // MARK: Loading

    private func load() async {
        guard let repository = GenreRepository.live(container) else { return }
        do {
            let overview = try await repository.overview()
            genre = overview.genres.first { $0.key == key }
            genreTracks = try await repository.tracks(genreKeys: [key])
            loadFailed = false
        } catch {
            AppLogger.shared.error("Genre “\(name)” couldn’t load: \(error)", source: "Genres")
            loadFailed = true
        }
        hasLoaded = true
        await showTracks()
    }

    /// The table shows the genre's tracks, filtered in place by this page's search (W2-I).
    private func showTracks() async {
        let filter = self.filter
        let visible: Set<Int64>? = filter.isEmpty
            ? nil
            : Set(genreTracks.filter { filter.matches($0) }.compactMap(\.id))
        await list.setTracks(genreTracks, visibleIDs: visible)
    }

    // MARK: Header (UC-LAYOUT-06)

    private var header: some View {
        HStack(alignment: .bottom, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Genre")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                title
                Text(GenreText.facts(trackCount: genreTracks.count,
                                     duration: genreTracks.reduce(0) { $0 + max($1.duration ?? 0, 0) },
                                     bpms: genreTracks.compactMap(\.bpm)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                buttons
                    .padding(.top, Spacing.s)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .background(.background)
    }

    @ViewBuilder
    private var title: some View {
        if isEditingTitle {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Genre name", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit { commitTitle() }
                    .onExitCommand { isEditingTitle = false; titleError = nil }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused, isEditingTitle { commitTitle() }
                    }
                if let titleError {
                    Text(titleError).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(displayName)
                .font(.title.bold())
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Click to rename")
                .onTapGesture { startTitleEdit() }
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var buttons: some View {
        let reason = cantPlayReason
        let subjects = genre.map { [$0] } ?? []
        return HStack(spacing: Spacing.s) {
            Button {
                actions.play(subjects)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(reason != nil || subjects.isEmpty)
            .help(reason ?? "Play “\(displayName)”")
            Button {
                actions.play(subjects, shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(reason != nil || subjects.isEmpty)
            .help(reason ?? "Shuffle “\(displayName)”")
            Menu {
                if !subjects.isEmpty {
                    GenreMenu(genres: subjects, place: .more, actions: actions,
                              rename: { _ in startTitleEdit() },
                              mergeWithAnother: mergeWithAnother)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(subjects.isEmpty)
            .help("More")
            .accessibilityLabel("More")
            if let reason {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// Play and Shuffle are always there; disabled with the reason when nothing can play.
    private var cantPlayReason: String? {
        if let drive = TrackTableLiveState.drive(container).cantPlayReason { return drive }
        guard hasLoaded else { return nil }
        if genreTracks.isEmpty { return "No track has this genre" }
        guard !genreTracks.contains(where: \.isLocal) else { return nil }
        return "Nothing to play yet — no track is downloaded"
    }

    private func startTitleEdit() {
        guard genre != nil else { return }
        titleText = displayName
        titleError = nil
        isEditingTitle = true
    }

    /// Rename Genre (inline, UC-KEY-20): one undoable tag edit over the genre's tracks; the
    /// page then shows the genre under its new name (its staged tracks move along).
    private func commitTitle() {
        guard let genre, let newName = GenreName.cleaned(titleText), newName != genre.name,
              let edits = GenreEdits.live(undo: undo, container: container) else {
            isEditingTitle = false
            return
        }
        Task {
            do {
                try await edits.rename(genre, to: newName, reportsFailure: false)
                isEditingTitle = false
                titleError = nil
                if let newKey = GenreName.key(newName) { workbench.move(from: genre.key, to: newKey) }
                navigation.setPath(Array(navigation.path.dropLast()) + [.genre(newName)])
            } catch {
                titleError = "Couldn’t rename this genre — the library database didn’t answer. Try Again"
                titleFocused = true
            }
        }
    }

    /// `Merge with Another Genre…`: back to the list with this genre selected (V-GENRES).
    private func mergeWithAnother(_ genre: GenreSummary) {
        GenreRequests.shared.listSelection = [genre.key]
        if navigation.selection == .genres { navigation.popToRoot() } else { navigation.select(.genres) }
        statusBar?.post("Select the other genres to merge with “\(genre.name)”, then choose Merge Genres…")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loadFailed && !hasLoaded {
            ContentUnavailableView {
                Label("Can’t load “\(name)”", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. Your music and your library file are not affected.")
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            VStack(spacing: 0) {
                TrackListTable(model: list, configuration: configuration) {
                    ContentUnavailableView {
                        Label(filter.isEmpty ? "No tracks in “\(displayName)”" : "No tracks match", systemImage: "guitars")
                    } description: {
                        Text(filter.isEmpty
                             ? "No track has this genre any more. Drag tracks here or add suggestions below."
                             : "No track of this genre matches the search.")
                    }
                }
                GenreSuggestionsSection(
                    genreKey: key,
                    genreName: displayName,
                    genreTracks: genreTracks,
                    genreSelection: { list.selectedRows().map(\.track) },
                    writesTags: writesTags,
                    onTrackActivated: onTrackActivated
                )
            }
        }
    }

    private var configuration: TrackListConfiguration {
        let key = self.key
        let name = displayName
        return TrackListConfiguration(
            listContext: .genre(key: key, name: name),
            persistenceKey: Self.persistenceKey,
            defaultSort: TrackSortOrder(column: .added, ascending: false),
            accessibilityID: "genre_track_table",
            activate: onTrackActivated,
            removeFromContainer: { ids in removeFromGenre(ids) },
            // Suggestions dragged onto the genre's table are staged (D-STUDIO-TRACK-TO-GENRE).
            onInsert: { _, providers, _ in stageDropped(providers) },
            menuExtras: TrackMenuExtrasProvider(
                items: { rows in
                    rows.count == 1
                        ? TrackMenuExtras(info: [TrackMenuExtra(id: Self.useAsReferenceID, title: "Use as Reference for Suggestions")])
                        : .none
                },
                perform: { id, rows in
                    guard id == Self.useAsReferenceID, let track = rows.first?.track else { return }
                    useAsReference(track)
                }
            )
        )
    }

    private static let useAsReferenceID = "genre.useAsReference"

    private func useAsReference(_ track: Track) {
        guard let repository = GenreRepository.live(container), let source = GenreSimilaritySource.live(container) else { return }
        workbench.isSuggestionsExpanded = true
        workbench.setReference(track, genreKey: key, genreName: displayName, repository: repository, source: source)
    }

    /// ⌫ / Remove from “‹Genre›”: the tracks get no genre (one undoable tag edit, UC-KEY-17).
    private func removeFromGenre(_ ids: Set<Int64>) {
        guard !ids.isEmpty, let edits = GenreEdits.live(undo: undo, container: container) else { return }
        let ordered = list.rows.map(\.id).filter(ids.contains)
        let name = displayName
        Task { _ = try? await edits.remove(ordered, fromGenre: name) }
    }

    private func stageDropped(_ providers: [NSItemProvider]) {
        let key = self.key
        let name = displayName
        Task {
            guard let content = await DropLoader.load(providers) else { return }
            let decision = DropRules.decide(content, onto: .genreTable(key: key, name: name), context: DropContext.current(container))
            if case .stageForGenre = decision { workbench.isSuggestionsExpanded = true }
            DropPerformer(container: container, shell: shell, statusBar: statusBar, undo: undo ?? .main).perform(decision)
        }
    }
}
