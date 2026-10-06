import AppKit
import SwiftUI

/// Albums (V-ALB, DEC-019/021, UC-LAYOUT, UC-SEL-04): a cover grid of every album that has two
/// or more tracks or a known tracklist (IMP-069) — and one quiet footer line for the tracks that
/// have no album (no fake album, IMP-070).
///
/// Single click selects, double-click / Return opens (pushed, Back ⌘[), arrows move, a typed
/// title selects, ⌘ / ⇧ extend. Scope bar `All · Complete · Incomplete · Compilations` with live
/// counts that follow the in-place filter (title, album artist, year, `artist:` `album:` `year:`),
/// the sort control beside it (IMP-077). A card is a drag source (its tracks in album order, to a
/// playlist, a sync profile, the player, Finder) and a drop target: tracks join the album, an
/// image sets its cover. No toolbar items.
///
/// First load shows placeholder cards; later reloads (`.trackMetadataDidChange`,
/// `.libraryDidImport`, `.libraryDidDeleteTracks`, `.trackAvailabilityDidChange`) replace the data
/// in place.
struct AlbumsView: View {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    /// UC-SCOPE-05: remembered per window.
    @SceneStorage("albums.sort") private var sortRaw = AlbumSort.artist.rawValue
    @SceneStorage("albums.scope") private var scopeRaw = AlbumScope.all.rawValue

    @State private var selection: Set<Int64> = []
    @State private var anchor: Int64?
    @State private var refusals: [Int64: String] = [:]
    @State private var columnCount = 1
    @State private var typeSelect = AlbumTypeSelect()
    /// The album whose info sheet is open (`Get Info`, CM-ALB-CARD.N06).
    @State private var infoAlbumID: Int64?
    @FocusState private var gridFocused: Bool

    private var sort: AlbumSort { AlbumSort(rawValue: sortRaw) ?? .artist }
    private var scope: AlbumScope { AlbumScope(rawValue: scopeRaw) ?? .all }
    private var filter: SearchFilter { container.searchCoordinator.filter(for: .albums) }

    private var actions: AlbumActions {
        AlbumActions(container: container, shell: shell, navigation: navigation, statusBar: statusBar, undo: undo)
    }

    /// `Find Albums…` leads to Review ▸ Albums, which W4-3 builds (its menu item is pending too).
    private var findAlbumsReason: String? {
        MenuCommand.findAlbums.isPending ? MenuCommand.findAlbums.pendingReason : nil
    }

    // MARK: Body

    var body: some View {
        let model = AlbumsModelStore.shared.model(for: container, sort: sort)
        let filter = self.filter
        let shown = model.shown(scope: scope, filter: filter)
        let counts = model.counts(filter: filter)
        ContentScaffold(showsDriveBanner: false) {
            content(model: model, shown: shown, filter: filter)
                .windowCount(model.phase == .loaded ? AlbumText.statusText(shown: shown.count, total: model.all.count, isFiltered: !filter.isEmpty || scope != .all) : nil)
                .statusBarText(statusText(model: model, shown: shown, filter: filter))
        } scopeBar: {
            if model.phase == .loaded, !model.all.isEmpty {
                ScopeBar(
                    items: AlbumScope.allCases.map { scope in
                        ScopeBarItem(id: scope, title: scope.title, count: counts[scope])
                    },
                    selection: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }),
                    countNoun: .albums
                ) {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(AlbumSort.allCases, id: \.rawValue) { sort in
                            Text(sort.title).tag(sort.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Sort the albums")
                }
            }
        }
        .modifier(WindowTitleModifier())
        .sheet(isPresented: Binding(get: { infoAlbumID != nil }, set: { if !$0 { infoAlbumID = nil } })) {
            if let infoAlbumID { AlbumInfoSheet(albumID: infoAlbumID) }
        }
        .task {
            model.setSort(sort)
            TrackMenuSources.shared.loadIfNeeded(container: container)
            await model.reload()
        }
        .onChange(of: sortRaw) { _, _ in model.setSort(sort) }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in Task { await model.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in Task { await model.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in Task { await model.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in Task { await model.reload() } }
    }

    // MARK: Content

    @ViewBuilder
    private func content(model: AlbumsModel, shown: [AlbumListing], filter: SearchFilter) -> some View {
        switch model.phase {
        case .failed:
            ContentUnavailableView {
                Label("Can’t load the albums", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. Your music and your library file are not affected.")
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
            }
        case .loading:
            AlbumsPlaceholderGrid()
        case .loaded where model.all.isEmpty:
            AlbumsEmptyContent(
                noAlbumCount: model.noAlbumCount,
                findAlbumsReason: findAlbumsReason,
                findAlbums: showAlbumSuggestions,
                importFiles: { shell?.chooseImportFolder() }
            )
        case .loaded where shown.isEmpty:
            filteredEmpty(filter: filter)
        case .loaded:
            grid(model: model, shown: shown)
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(model: model) }
        }
    }

    private func filteredEmpty(filter: SearchFilter) -> some View {
        VStack(spacing: Spacing.m) {
            if filter.isEmpty {
                ContentUnavailableView("No albums found", systemImage: "magnifyingglass",
                                       description: Text(AlbumText.filteredEmptyText(hasQuery: false, scope: scope)))
            } else {
                ContentUnavailableView.search(text: filter.displayText)
            }
            Button("Clear Filters") {
                scopeRaw = AlbumScope.all.rawValue
                search?.clear()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The tracks without an album (V-ALB.N08): one quiet line and the two ways forward.
    @ViewBuilder
    private func footer(model: AlbumsModel) -> some View {
        if model.noAlbumCount > 0 {
            HStack(spacing: Spacing.s) {
                Text(AlbumText.noAlbumLine(model.noAlbumCount))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // `is: no album` in All Tracks — the same predicate as the count (IMP-072).
                Button("Show") { search?.show(SearchFilter(tokens: [.availability(.noAlbum)]), in: .allTracks) }
                    .buttonStyle(.link)
                    .disabled(search == nil)
                Button("Find Albums…", action: showAlbumSuggestions)
                    .buttonStyle(.link)
                    .disabled(findAlbumsReason != nil)
                    .help(findAlbumsReason ?? "")
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xs)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// `Find Albums…`: Review ▸ Albums (the tab arrives with W4-3; it reads `ReviewTabRequest`).
    private func showAlbumSuggestions() {
        ReviewTabRequest.shared.pending = .albums
        navigation.select(.review)
    }

    private func grid(model: AlbumsModel, shown: [AlbumListing]) -> some View {
        let orderedIDs = shown.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView {
                AlbumGrid(listings: shown) { listing in
                    card(listing, model: model, orderedIDs: orderedIDs)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                            columnCount = Self.columns(forWidth: width)
                        }
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard selection.count == 1, let id = selection.first else { return .ignored }
                actions.open(id)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selection.isEmpty else { return .ignored }
                selection = []
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                let step: Int
                switch press.key {
                case .leftArrow: step = -1
                case .rightArrow: step = 1
                case .upArrow: step = -columnCount
                default: step = columnCount
                }
                return move(step, in: orderedIDs, extending: press.modifiers.contains(.shift), proxy: proxy)
            }
            .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                return select(typed: press.characters, in: shown, proxy: proxy)
            }
        }
    }

    /// How many cards a row holds: the adaptive grid fits as many as the minimum width allows.
    static func columns(forWidth width: CGFloat) -> Int {
        let available = width - 2 * Spacing.xl
        return max(1, Int((available + Spacing.l) / (AlbumGrid<EmptyView>.minimumWidth + Spacing.l)))
    }

    private func card(_ listing: AlbumListing, model: AlbumsModel, orderedIDs: [Int64]) -> some View {
        let id = listing.id
        let title = listing.album.title
        return AlbumCard(listing: listing, cover: model.cover(for: listing), isSelected: selection.contains(id))
            .inPlaceRefusal(Binding(get: { refusals[id] }, set: { refusals[id] = $0 }))
            .gesture(TapGesture(count: 2).onEnded { actions.open(id) })
            .simultaneousGesture(TapGesture().onEnded { select(id, in: orderedIDs) })
            .contextMenu {
                let subjects = selection.contains(id) && selection.count > 1
                    ? orderedIDs.filter(selection.contains).compactMap { subject($0, model: model) }
                    : [subject(id, model: model)].compactMap { $0 }
                AlbumMenu(albums: subjects, place: .card, missing: model.missingCount(subjects.map(\.id)),
                          showInfo: { infoAlbumID = subjects.first?.id })
            }
            // Tracks join the album, an image sets its cover (D-ALB-CARD).
            .dropTarget(.albumCard(id: id, name: title), cornerRadius: 9, sayRefusal: { refusals[id] = $0 })
            .draggable(TrackDragItem.album(id, libraryId: container.activeLibrary?.libraryId))
            .dragConfiguration(TrackDragConfiguration.rows)
    }

    private func subject(_ id: Int64, model: AlbumsModel) -> AlbumMenuSubject? {
        model.all.first { $0.id == id }.map {
            AlbumMenuSubject(id: $0.id, title: $0.album.title, albumArtist: $0.album.albumArtist, isCompilation: $0.isCompilation)
        }
    }

    // MARK: Selection (UC-SEL-01/04)

    private func select(_ id: Int64, in ordered: [Int64]) {
        gridFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let from = ordered.firstIndex(of: anchor), let to = ordered.firstIndex(of: id) {
            selection = Set(ordered[min(from, to)...max(from, to)])
        } else {
            selection = [id]
            anchor = id
        }
    }

    private func move(_ step: Int, in ordered: [Int64], extending: Bool, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !ordered.isEmpty else { return .ignored }
        let current = anchor.flatMap { ordered.firstIndex(of: $0) }
        let next = min(max((current ?? (step > 0 ? -1 : ordered.count)) + step, 0), ordered.count - 1)
        if extending, let current {
            selection = Set(ordered[min(current, next)...max(current, next)])
        } else {
            selection = [ordered[next]]
            anchor = ordered[next]
        }
        proxy.scrollTo(ordered[next])
        return .handled
    }

    private func select(typed characters: String, in shown: [AlbumListing], proxy: ScrollViewProxy) -> KeyPress.Result {
        let prefix = typeSelect.type(characters, at: .now)
        let titles = shown.map { (id: $0.id, title: $0.album.title) }
        guard let id = AlbumTypeSelect.match(prefix, in: titles, after: anchor) else { return .handled }
        selection = [id]
        anchor = id
        proxy.scrollTo(id)
        return .handled
    }

    // MARK: Status bar (UC-STATUS-02)

    private func statusText(model: AlbumsModel, shown: [AlbumListing], filter: SearchFilter) -> String? {
        guard model.phase == .loaded else { return nil }
        let chosen = shown.filter { selection.contains($0.id) }
        if let text = AlbumText.selectedText(chosen) { return text }
        return AlbumText.statusText(shown: shown.count, total: model.all.count, isFiltered: !filter.isEmpty || scope != .all)
    }
}

// MARK: - The model outlives the page

/// The Albums model of the open library, kept while the user is elsewhere so a return shows the
/// grid at once and refreshes in place (only the very first load shows placeholders, UC-EMPTY-04).
@MainActor
final class AlbumsModelStore {
    static let shared = AlbumsModelStore()

    private var model: AlbumsModel?
    private var libraryID: String?

    func model(for container: DependencyContainer, sort: AlbumSort) -> AlbumsModel {
        let id = container.activeLibrary?.libraryId
        if let model, libraryID == id { return model }
        let fresh = AlbumsModel(albums: container.albumRepository, scopeQueries: TrackScopeQueries.current(container), sort: sort)
        model = fresh
        libraryID = id
        return fresh
    }
}
